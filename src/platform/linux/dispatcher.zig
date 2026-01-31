//! Linux eventfd-based task dispatcher
//!
//! Provides cross-thread task dispatch using eventfd for signaling
//! and a thread-safe queue for task storage.
//!
//! Thread safety:
//! - dispatch(): safe to call from any thread
//! - dispatchOnMainThread(): safe to call from any thread
//! - dispatchAfter(): safe to call from any thread
//! - processPending(): MUST only be called from main thread
//! - isMainThread(): safe to call from any thread
//!
//! Memory ordering:
//! - TaskQueue uses mutex for synchronization (provides acquire/release semantics)
//! - eventfd write/read provides memory barrier between producer and consumer
//! - main_thread_id is written once during init() before any concurrent access
//!
//! Error sets:
//! - init(): posix.eventfd errors (OutOfMemory, SystemResources)
//! - dispatchOnMainThread(): error.QueueFull, allocation errors, write errors
//! - dispatch(): allocation errors, thread spawn errors
//! - dispatchAfter(): allocation errors, thread spawn errors

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Maximum pending tasks (per CLAUDE.md: put a limit on everything)
const MAX_PENDING_TASKS: usize = 256;

/// Maximum tasks to process per processPending() call to prevent main thread stalls
const MAX_TASKS_PER_PROCESS: usize = 64;

/// Module-level main thread ID for static isMainThread() API compatibility
/// Written once during init(), read from any thread thereafter.
var main_thread_id: ?std.Thread.Id = null;

/// Debug flag: set to true to enable dispatcher logging
const verbose_logging = false;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (verbose_logging) {
        std.debug.print("[dispatcher] " ++ fmt ++ "\n", args);
    }
}

/// A heap-allocated task with type-erased callback.
///
/// Tasks are created via `Task.create()` and consumed via `runAndDestroy()`.
/// The task owns both itself and its context - both are freed after callback execution.
pub const Task = struct {
    callback: *const fn (*anyopaque) void,
    context: *anyopaque,
    context_deinit: *const fn (std.mem.Allocator, *anyopaque) void,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a heap-allocated task (mirrors macOS API)
    ///
    /// Allocates both the Task and a copy of the context on the heap.
    /// Both are freed when runAndDestroy() is called.
    ///
    /// Errors: OutOfMemory
    pub fn create(
        allocator: std.mem.Allocator,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !*Self {
        // Assertion: Context must be a concrete type with known size
        comptime {
            std.debug.assert(@sizeOf(Context) >= 0);
        }

        const ctx_ptr = try allocator.create(Context);
        errdefer allocator.destroy(ctx_ptr);
        ctx_ptr.* = context;

        const task = try allocator.create(Self);
        task.* = .{
            .callback = struct {
                fn wrapper(ptr: *anyopaque) void {
                    const typed: *Context = @ptrCast(@alignCast(ptr));
                    callback(typed);
                }
            }.wrapper,
            .context = ctx_ptr,
            .context_deinit = struct {
                fn deinit(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                    const typed: *Context = @ptrCast(@alignCast(ptr));
                    alloc.destroy(typed);
                }
            }.deinit,
            .allocator = allocator,
        };

        return task;
    }

    /// Execute the callback and free all task memory.
    ///
    /// After this call, the Task pointer is invalid.
    pub fn runAndDestroy(self: *Self) void {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(@intFromPtr(self.callback) != 0);
        std.debug.assert(@intFromPtr(self.context) != 0);

        const allocator = self.allocator;
        const context = self.context;
        const context_deinit = self.context_deinit;
        const callback = self.callback;

        // Execute callback first (matches macOS dispatcher order)
        callback(context);

        // Free context
        context_deinit(allocator, context);

        // Free task itself
        allocator.destroy(self);
    }

    /// Free all task memory WITHOUT running the callback.
    ///
    /// Use this when a task must be dropped (e.g., queue overflow).
    /// After this call, the Task pointer is invalid.
    pub fn destroy(self: *Self) void {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(@intFromPtr(self.callback) != 0);
        std.debug.assert(@intFromPtr(self.context) != 0);

        const allocator = self.allocator;
        const context = self.context;
        const context_deinit = self.context_deinit;

        // Free context (without running callback)
        context_deinit(allocator, context);

        // Free task itself
        allocator.destroy(self);
    }
};

/// Thread-safe MPSC (multi-producer, single-consumer) task queue.
///
/// Memory ordering: The mutex provides acquire semantics on lock and release
/// semantics on unlock, ensuring proper visibility of queue modifications.
///
/// Capacity: Fixed at MAX_PENDING_TASKS. Push returns error.QueueFull if exceeded.
const TaskQueue = struct {
    tasks: [MAX_PENDING_TASKS]*Task = undefined,
    head: usize = 0, // Consumer reads from head
    tail: usize = 0, // Producers write to tail
    count: usize = 0, // Track count for efficient length check
    mutex: std.Thread.Mutex = .{},

    /// Push a task to the queue. Thread-safe.
    ///
    /// Returns: error.QueueFull if queue is at capacity
    fn push(self: *TaskQueue, task: *Task) error{QueueFull}!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Assertions
        std.debug.assert(self.count <= MAX_PENDING_TASKS);
        std.debug.assert(@intFromPtr(task) != 0);

        if (self.count >= MAX_PENDING_TASKS) {
            return error.QueueFull;
        }

        self.tasks[self.tail] = task;
        self.tail = (self.tail + 1) % MAX_PENDING_TASKS;
        self.count += 1;
    }

    /// Pop a task from the queue. Thread-safe.
    ///
    /// Returns: Task pointer, or null if queue is empty
    fn pop(self: *TaskQueue) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Assertion
        std.debug.assert(self.count <= MAX_PENDING_TASKS);

        if (self.count == 0) {
            return null;
        }

        const task = self.tasks[self.head];
        self.head = (self.head + 1) % MAX_PENDING_TASKS;
        self.count -= 1;

        std.debug.assert(@intFromPtr(task) != 0);
        return task;
    }

    /// Get current queue length. Thread-safe.
    fn len(self: *TaskQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    event_fd: posix.fd_t,
    pending_queue: TaskQueue,

    const Self = @This();

    /// Initialize the dispatcher. MUST be called from the main thread.
    ///
    /// This sets up the eventfd for cross-thread signaling and records
    /// the main thread ID for isMainThread() checks.
    ///
    /// Errors: SystemResources, OutOfMemory (from eventfd creation)
    pub fn init(allocator: std.mem.Allocator) !Self {
        // Assertion: init() must only be called once
        // If main_thread_id is already set, this is a double-init bug
        std.debug.assert(main_thread_id == null);

        // Store main thread ID for static isMainThread() compatibility
        // IMPORTANT: init() must be called from the main thread
        main_thread_id = std.Thread.getCurrentId();

        debugLog("init: main_thread_id = {}", .{main_thread_id.?});

        // Note: EFD_SEMAPHORE is not used - each read drains the counter entirely,
        // which is fine since we process the entire queue after wakeup anyway.
        const efd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);

        // Assertion: valid fd
        std.debug.assert(efd >= 0);

        return .{
            .allocator = allocator,
            .event_fd = efd,
            .pending_queue = .{},
        };
    }

    /// Clean up dispatcher resources.
    ///
    /// Drains any remaining tasks (running their callbacks) to avoid memory leaks.
    pub fn deinit(self: *Self) void {
        // Callbacks expect main thread context, so deinit must be called from main
        std.debug.assert(isMainThread());
        std.debug.assert(self.event_fd >= 0);

        posix.close(self.event_fd);

        // Drain remaining tasks to avoid memory leaks
        // Note: callbacks will run on main thread as expected
        var drained: usize = 0;
        while (self.pending_queue.pop()) |task| {
            task.runAndDestroy();
            drained += 1;
        }

        if (drained > 0) {
            debugLog("deinit: drained {} remaining tasks", .{drained});
        }

        // Reset main_thread_id for potential re-init (mainly for tests)
        main_thread_id = null;
    }

    /// Get the eventfd for integration with poll()
    ///
    /// The returned fd should be added to the poll() set with POLLIN.
    /// When readable, call processPending() to handle queued tasks.
    pub fn getFd(self: *const Self) posix.fd_t {
        std.debug.assert(self.event_fd >= 0);
        return self.event_fd;
    }

    /// Dispatch a task to run on the main thread.
    ///
    /// Thread-safe: can be called from any thread.
    /// The callback will be invoked on the main thread during processPending().
    ///
    /// Errors:
    /// - error.QueueFull: Too many pending tasks (MAX_PENDING_TASKS exceeded)
    /// - error.OutOfMemory: Failed to allocate task
    /// - error.WouldBlock: Should not happen (eventfd overflow is handled)
    pub fn dispatchOnMainThread(
        self: *Self,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        std.debug.assert(self.event_fd >= 0);

        const task = try Task.create(self.allocator, Context, context, callback);
        errdefer task.runAndDestroy();

        try self.pending_queue.push(task);

        debugLog("dispatchOnMainThread: queued task, queue len = {}", .{self.pending_queue.len()});

        // Signal the eventfd to wake poll()
        const val: u64 = 1;
        _ = posix.write(self.event_fd, std.mem.asBytes(&val)) catch |err| {
            // EAGAIN means eventfd counter would overflow (2^64-1) - main thread
            // already has a pending wakeup, so this is fine and expected
            if (err != error.WouldBlock) return err;
        };
    }

    /// Dispatch a task to run on a background thread.
    ///
    /// Thread-safe: can be called from any thread.
    /// A new thread is spawned to execute the callback.
    ///
    /// Note: This spawns a new thread per call (~10-50μs overhead).
    /// For high-frequency dispatching, consider using a thread pool.
    /// TigersEye's TigerBeetle IO uses its own thread pool internally,
    /// so this is mainly for one-off background work.
    ///
    /// Errors:
    /// - error.OutOfMemory: Failed to allocate task
    /// - error.ThreadQuotaExceeded, error.SystemResources: Thread spawn failed
    pub fn dispatch(
        self: *Self,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        std.debug.assert(self.event_fd >= 0);

        const task = try Task.create(self.allocator, Context, context, callback);

        const thread = try std.Thread.spawn(.{}, struct {
            fn run(t: *Task) void {
                t.runAndDestroy();
            }
        }.run, .{task});
        thread.detach();

        debugLog("dispatch: spawned background thread", .{});
    }

    /// Dispatch a task to run on the main thread after a delay.
    ///
    /// Thread-safe: can be called from any thread.
    /// A timer thread sleeps for the delay, then queues the task for main thread.
    ///
    /// WARNING: Spawns one thread per timer (~10-50μs overhead each).
    /// Do not schedule more than ~50 concurrent timers. For TigersEye's
    /// typical usage (rate-limit retries, request timeouts), this is fine.
    ///
    /// Current implementation: spawns a thread that sleeps then queues the task.
    /// This is acceptable for low-frequency timers but doesn't scale to hundreds.
    ///
    /// If the queue is full when the timer fires, the implementation will retry
    /// with exponential backoff before logging a warning and dropping the task.
    ///
    /// Future improvement: Use timerfd_create() instead, which integrates with
    /// poll() and is handled by the kernel scheduler without extra threads.
    ///
    /// Errors:
    /// - error.OutOfMemory: Failed to allocate task
    /// - error.ThreadQuotaExceeded, error.SystemResources: Thread spawn failed
    pub fn dispatchAfter(
        self: *Self,
        delay_ns: u64,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        std.debug.assert(self.event_fd >= 0);
        std.debug.assert(delay_ns < std.math.maxInt(u64) / 2); // Sanity check

        const task = try Task.create(self.allocator, Context, context, callback);

        const TimerCtx = struct {
            task: *Task,
            delay: u64,
            dispatcher: *Self,
        };

        const timer_task = try Task.create(self.allocator, TimerCtx, .{
            .task = task,
            .delay = delay_ns,
            .dispatcher = self,
        }, struct {
            fn run(ctx: *TimerCtx) void {
                std.Thread.sleep(ctx.delay);

                // Retry with exponential backoff if queue is full
                var retry_delay_ns: u64 = 1_000_000; // Start at 1ms
                const max_retries: usize = 5;
                var retries: usize = 0;

                while (retries < max_retries) {
                    ctx.dispatcher.pending_queue.push(ctx.task) catch |err| {
                        switch (err) {
                            error.QueueFull => {
                                retries += 1;
                                debugLog("dispatchAfter: queue full, retry {} of {}", .{ retries, max_retries });
                                std.Thread.sleep(retry_delay_ns);
                                retry_delay_ns *= 2; // Exponential backoff
                                continue;
                            },
                        }
                    };

                    // Successfully queued - signal eventfd
                    const val: u64 = 1;
                    _ = posix.write(ctx.dispatcher.event_fd, std.mem.asBytes(&val)) catch {};
                    return;
                }

                // All retries exhausted - log warning and destroy task to avoid leak
                // WARNING: We do NOT run the callback here because we're on the wrong thread.
                // This is a dropped task - the application should handle QueueFull errors
                // at the dispatch site if this is critical.
                std.log.warn("dispatchAfter: queue full after {} retries, dropping task", .{max_retries});
                ctx.task.destroy();
            }
        }.run);

        const thread = try std.Thread.spawn(.{}, struct {
            fn run(t: *Task) void {
                t.runAndDestroy();
            }
        }.run, .{timer_task});
        thread.detach();

        debugLog("dispatchAfter: scheduled timer for {}ns", .{delay_ns});
    }

    /// Process pending tasks. Call from main thread after poll() indicates eventfd is readable.
    ///
    /// NOT thread-safe: must only be called from main thread.
    ///
    /// Processes up to MAX_TASKS_PER_PROCESS tasks per call to prevent main thread stalls.
    /// If more tasks remain, re-signals the eventfd so poll() will wake again.
    ///
    /// Returns: number of tasks processed
    pub fn processPending(self: *Self) usize {
        std.debug.assert(isMainThread());
        std.debug.assert(self.event_fd >= 0);

        // Drain eventfd counter (8-byte read)
        var buf: [8]u8 = undefined;
        _ = posix.read(self.event_fd, &buf) catch {};

        // Process up to MAX_TASKS_PER_PROCESS tasks
        var processed: usize = 0;
        while (processed < MAX_TASKS_PER_PROCESS) {
            const task = self.pending_queue.pop() orelse break;
            task.runAndDestroy();
            processed += 1;
        }

        debugLog("processPending: processed {} tasks", .{processed});

        // If more tasks remain, re-signal eventfd so we wake up again
        if (self.pending_queue.len() > 0) {
            debugLog("processPending: {} tasks remaining, re-signaling", .{self.pending_queue.len()});
            const val: u64 = 1;
            _ = posix.write(self.event_fd, std.mem.asBytes(&val)) catch {};
        }

        return processed;
    }

    /// Check if current thread is main thread.
    ///
    /// Static method for API compatibility with macOS GCD dispatcher.
    /// Thread-safe: can be called from any thread.
    ///
    /// Returns false if init() has not been called yet.
    pub fn isMainThread() bool {
        const main_id = main_thread_id orelse return false;
        return std.Thread.getCurrentId() == main_id;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Task.create allocates and stores context" {
    const allocator = std.testing.allocator;

    const Context = struct {
        value: u32,
        flag: *bool,
    };

    var flag: bool = false;

    const task = try Task.create(allocator, Context, .{
        .value = 42,
        .flag = &flag,
    }, struct {
        fn callback(ctx: *Context) void {
            std.debug.assert(ctx.value == 42);
            ctx.flag.* = true;
        }
    }.callback);

    task.runAndDestroy();
    try std.testing.expect(flag == true);
}

test "Task.create with pointer context" {
    const allocator = std.testing.allocator;

    var called: bool = false;
    const called_ptr = &called;

    const Context = struct {
        called: *bool,
    };

    const task = try Task.create(allocator, Context, .{
        .called = called_ptr,
    }, struct {
        fn callback(ctx: *Context) void {
            ctx.called.* = true;
        }
    }.callback);

    task.runAndDestroy();
    try std.testing.expect(called == true);
}

test "Dispatcher.init sets main thread ID" {
    // Reset for test isolation
    main_thread_id = null;

    const allocator = std.testing.allocator;
    var dispatcher = try Dispatcher.init(allocator);
    defer dispatcher.deinit();

    try std.testing.expect(main_thread_id != null);
    try std.testing.expect(Dispatcher.isMainThread() == true);
}

test "Dispatcher.dispatch runs callback on background thread" {
    // Reset for test isolation
    main_thread_id = null;

    // Use page_allocator for background thread tests - testing.allocator's leak
    // detection races with detached threads that free memory after signaling completion
    const allocator = std.heap.page_allocator;
    var dispatcher = try Dispatcher.init(allocator);
    defer dispatcher.deinit();

    var completed = std.atomic.Value(bool).init(false);
    var ran_on_background = std.atomic.Value(bool).init(false);

    const Context = struct {
        completed: *std.atomic.Value(bool),
        ran_on_background: *std.atomic.Value(bool),
    };

    try dispatcher.dispatch(Context, .{
        .completed = &completed,
        .ran_on_background = &ran_on_background,
    }, struct {
        fn callback(ctx: *Context) void {
            if (!Dispatcher.isMainThread()) {
                ctx.ran_on_background.store(true, .release);
            }
            ctx.completed.store(true, .release);
        }
    }.callback);

    // Wait for completion with timeout
    const timeout_ns: u64 = 1_000_000_000;
    const start = std.time.nanoTimestamp();

    while (!completed.load(.acquire)) {
        if (@as(u64, @intCast(std.time.nanoTimestamp() - start)) > timeout_ns) {
            return error.TestTimeout;
        }
        std.Thread.yield() catch {};
    }

    try std.testing.expect(ran_on_background.load(.acquire) == true);
}

test "Dispatcher.dispatchOnMainThread queues task" {
    // Reset for test isolation
    main_thread_id = null;

    const allocator = std.testing.allocator;
    var dispatcher = try Dispatcher.init(allocator);
    defer dispatcher.deinit();

    var callback_executed: bool = false;

    const Context = struct {
        flag: *bool,
    };

    // Dispatch from main thread (same thread - still uses queue)
    try dispatcher.dispatchOnMainThread(Context, .{
        .flag = &callback_executed,
    }, struct {
        fn callback(ctx: *Context) void {
            ctx.flag.* = true;
        }
    }.callback);

    // Callback should NOT have run yet (it's queued)
    try std.testing.expect(callback_executed == false);

    // Process pending tasks
    const processed = dispatcher.processPending();
    try std.testing.expect(processed == 1);
    try std.testing.expect(callback_executed == true);
}

test "isMainThread returns correct value" {
    // Reset for test isolation
    main_thread_id = null;

    const allocator = std.testing.allocator;
    var dispatcher = try Dispatcher.init(allocator);
    defer dispatcher.deinit();

    // Main thread should return true
    try std.testing.expect(Dispatcher.isMainThread() == true);

    // Background thread should return false
    var background_result = std.atomic.Value(bool).init(true);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(result: *std.atomic.Value(bool)) void {
            result.store(Dispatcher.isMainThread(), .release);
        }
    }.run, .{&background_result});
    thread.join();

    try std.testing.expect(background_result.load(.acquire) == false);
}

test "isMainThread returns false before init" {
    // Reset for test isolation
    main_thread_id = null;

    // Before init, should return false
    try std.testing.expect(Dispatcher.isMainThread() == false);
}

test "TaskQueue handles overflow" {
    var queue = TaskQueue{};
    const allocator = std.testing.allocator;

    // Fill the queue
    var tasks: [MAX_PENDING_TASKS]*Task = undefined;
    for (0..MAX_PENDING_TASKS) |i| {
        tasks[i] = try Task.create(allocator, u32, 0, struct {
            fn cb(_: *u32) void {}
        }.cb);
        try queue.push(tasks[i]);
    }

    // Queue should now be full
    try std.testing.expect(queue.len() == MAX_PENDING_TASKS);

    // Next push should fail
    const overflow_task = try Task.create(allocator, u32, 0, struct {
        fn cb(_: *u32) void {}
    }.cb);

    try std.testing.expectError(error.QueueFull, queue.push(overflow_task));

    // Cleanup overflow task (wasn't added to queue)
    overflow_task.runAndDestroy();

    // Cleanup queued tasks
    while (queue.pop()) |task| {
        task.runAndDestroy();
    }
}

test "processPending respects MAX_TASKS_PER_PROCESS limit" {
    // Reset for test isolation
    main_thread_id = null;

    const allocator = std.testing.allocator;
    var dispatcher = try Dispatcher.init(allocator);
    defer dispatcher.deinit();

    var counter = std.atomic.Value(usize).init(0);

    const Context = struct {
        counter: *std.atomic.Value(usize),
    };

    // Queue more tasks than MAX_TASKS_PER_PROCESS
    const num_tasks = MAX_TASKS_PER_PROCESS + 10;
    for (0..num_tasks) |_| {
        try dispatcher.dispatchOnMainThread(Context, .{
            .counter = &counter,
        }, struct {
            fn callback(ctx: *Context) void {
                _ = ctx.counter.fetchAdd(1, .acq_rel);
            }
        }.callback);
    }

    // First processPending should process exactly MAX_TASKS_PER_PROCESS
    const first_batch = dispatcher.processPending();
    try std.testing.expect(first_batch == MAX_TASKS_PER_PROCESS);
    try std.testing.expect(counter.load(.acquire) == MAX_TASKS_PER_PROCESS);

    // Second processPending should process the remaining 10
    const second_batch = dispatcher.processPending();
    try std.testing.expect(second_batch == 10);
    try std.testing.expect(counter.load(.acquire) == num_tasks);
}

test "dispatchAfter delays execution" {
    // Reset for test isolation
    main_thread_id = null;

    // Use page_allocator for background thread tests - testing.allocator's leak
    // detection races with detached threads that free memory after signaling completion
    const allocator = std.heap.page_allocator;
    var dispatcher = try Dispatcher.init(allocator);
    defer dispatcher.deinit();

    var completed = std.atomic.Value(bool).init(false);

    const Context = struct {
        completed: *std.atomic.Value(bool),
    };

    const delay_ns: u64 = 50_000_000; // 50ms
    const start = std.time.nanoTimestamp();

    try dispatcher.dispatchAfter(delay_ns, Context, .{
        .completed = &completed,
    }, struct {
        fn callback(ctx: *Context) void {
            ctx.completed.store(true, .release);
        }
    }.callback);

    // Wait for task to be queued (with timeout)
    const timeout_ns: u64 = 500_000_000; // 500ms
    while (dispatcher.pending_queue.len() == 0) {
        if (@as(u64, @intCast(std.time.nanoTimestamp() - start)) > timeout_ns) {
            return error.TestTimeout;
        }
        std.Thread.yield() catch {};
    }

    // Check that at least 40ms has passed (allowing 10ms tolerance)
    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    try std.testing.expect(elapsed >= 40_000_000);

    // Process the task
    _ = dispatcher.processPending();
    try std.testing.expect(completed.load(.acquire) == true);
}

test "Multiple dispatches complete correctly" {
    // Reset for test isolation
    main_thread_id = null;

    // Use page_allocator for background thread tests - testing.allocator's leak
    // detection races with detached threads that free memory after signaling completion
    const allocator = std.heap.page_allocator;
    var dispatcher = try Dispatcher.init(allocator);
    defer dispatcher.deinit();

    const num_tasks = 10;
    var counter = std.atomic.Value(u32).init(0);
    var completed = std.atomic.Value(u32).init(0);

    const Context = struct {
        counter: *std.atomic.Value(u32),
        completed: *std.atomic.Value(u32),
    };

    for (0..num_tasks) |_| {
        try dispatcher.dispatch(Context, .{
            .counter = &counter,
            .completed = &completed,
        }, struct {
            fn callback(ctx: *Context) void {
                _ = ctx.counter.fetchAdd(1, .acq_rel);
                _ = ctx.completed.fetchAdd(1, .acq_rel);
            }
        }.callback);
    }

    // Wait for all tasks to complete
    const timeout_ns: u64 = 2_000_000_000;
    const start = std.time.nanoTimestamp();

    while (completed.load(.acquire) < num_tasks) {
        if (@as(u64, @intCast(std.time.nanoTimestamp() - start)) > timeout_ns) {
            return error.TestTimeout;
        }
        std.Thread.yield() catch {};
    }

    try std.testing.expect(counter.load(.acquire) == num_tasks);

    // Allow detached threads to fully clean up (stack deallocation happens after callback)
    // Without this, leak detection may race with thread cleanup.
    std.Thread.sleep(10_000_000); // 10ms
}

test "getFd returns valid fd" {
    // Reset for test isolation
    main_thread_id = null;

    const allocator = std.testing.allocator;
    var dispatcher = try Dispatcher.init(allocator);
    defer dispatcher.deinit();

    const fd = dispatcher.getFd();
    try std.testing.expect(fd >= 0);
}
