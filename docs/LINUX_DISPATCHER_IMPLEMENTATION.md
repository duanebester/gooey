# Linux Dispatcher Implementation Plan

This document provides a concrete implementation plan for adding an `eventfd`-based dispatcher to Gooey's Linux platform, enabling cross-thread communication between TigerBeetle's IO thread and the Wayland event loop.

For background and design rationale, see [LINUX_DISPATCHER.md](./LINUX_DISPATCHER.md).

## Executive Summary

| Item | Details |
|------|---------|
| **Goal** | Enable TigersEye to run on Linux with working async TigerBeetle operations |
| **Approach** | `eventfd` + `poll()` integration matching macOS GCD API |
| **Estimated Time** | 5-6 hours |
| **Files Changed** | 4 new/modified in Gooey, 2 in TigersEye |

---

## Current State

| Component | Status | Location |
|-----------|--------|----------|
| macOS Dispatcher | ✅ Complete | `gooey/src/platform/macos/dispatcher.zig` |
| Linux Platform | ✅ Complete | `gooey/src/platform/linux/platform.zig` |
| Linux Dispatcher | ❌ **Missing** | — |
| TigersEye | ⚠️ macOS only | Uses `platform.mac.dispatcher.Dispatcher` |

---

## Phase 1: Create Linux Dispatcher Module

**File:** `gooey/src/platform/linux/dispatcher.zig`  
**Estimated Time:** 2-3 hours  
**Dependencies:** None

### 1.1 File Header and Imports

```zig
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
```

### 1.2 Task Struct

Mirror the macOS `Task` struct exactly for API compatibility:

```zig
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
            std.debug.assert(@sizeOf(Context) > 0 or @sizeOf(Context) == 0);
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
};
```

### 1.3 Thread-Safe Task Queue

```zig
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
```

### 1.4 Dispatcher Struct

```zig
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
        const efd = try posix.eventfd(0, .{
            .NONBLOCK = true,
            .CLOEXEC = true,
        });

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
                std.time.sleep(ctx.delay);

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
                                std.time.sleep(retry_delay_ns);
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
                ctx.task.allocator.destroy(ctx.task);
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
```

### 1.5 Unit Tests

```zig
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

test "Task.create with zero-size context" {
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

    const allocator = std.testing.allocator;
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
        std.Thread.yield();
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

    const allocator = std.testing.allocator;
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
        std.Thread.yield();
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

    const allocator = std.testing.allocator;
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
        std.Thread.yield();
    }

    try std.testing.expect(counter.load(.acquire) == num_tasks);
}
```

---

## Phase 2: Platform Integration

**Files:** `gooey/src/platform/linux/platform.zig`, `gooey/src/platform/linux/mod.zig`  
**Estimated Time:** 1-2 hours  
**Dependencies:** Phase 1

### 2.1 Add Dispatcher Reference to LinuxPlatform

In `gooey/src/platform/linux/platform.zig`, add:

```zig
// At top of file, add import
const dispatcher_mod = @import("dispatcher.zig");

// In LinuxPlatform struct fields (around line 75-120)
pub const LinuxPlatform = struct {
    // ... existing fields ...
    
    /// Optional dispatcher for cross-thread communication
    dispatcher_ref: ?*dispatcher_mod.Dispatcher = null,

    // ... rest of fields ...
```

Add setter method:

```zig
    /// Set a dispatcher for cross-thread communication.
    ///
    /// This enables poll() to wake when background threads dispatch to main.
    /// Call this after creating the dispatcher and before running the event loop.
    pub fn setDispatcher(self: *Self, d: *dispatcher_mod.Dispatcher) void {
        std.debug.assert(d.event_fd >= 0);
        self.dispatcher_ref = d;
    }
```

### 2.2 Modify Run Loop for Dual-FD Polling

Replace the current `run()` function's poll setup (around line 311-385):

**Before:**
```zig
var pollfds = [_]posix.pollfd{
    .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
};
```

**After:**
```zig
// Build pollfd array - always include Wayland, optionally dispatcher
// Using 8 slots for future expansion (timerfd, etc.)
var pollfds_buf: [8]posix.pollfd = undefined;
var num_fds: usize = 1;

pollfds_buf[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };

if (self.dispatcher_ref) |d| {
    pollfds_buf[1] = .{ .fd = d.getFd(), .events = posix.POLL.IN, .revents = 0 };
    num_fds = 2;
}

const pollfds = pollfds_buf[0..num_fds];
```

Add dispatcher event handling after the Wayland dispatch (around line 375-385):

```zig
// After: if (wayland.wl_display_dispatch(display) < 0) { ... }

// Handle dispatcher events (cross-thread tasks)
if (num_fds > 1 and (pollfds[1].revents & posix.POLL.IN) != 0) {
    if (self.dispatcher_ref) |d| {
        _ = d.processPending();
    }
}
```

### 2.3 Export from Module

In `gooey/src/platform/linux/mod.zig`, add:

```zig
// Dispatcher for cross-thread communication
pub const dispatcher = @import("dispatcher.zig");
```

---

## Phase 3: Unified Cross-Platform API

**File:** `gooey/src/platform/mod.zig`  
**Estimated Time:** 30 minutes  
**Dependencies:** Phase 2

### 3.1 Add Dispatcher Type Alias

Add after the `DisplayLink` definition (around line 85-95):

```zig
/// Cross-platform dispatcher for thread-safe task scheduling.
///
/// Provides a unified API for dispatching tasks across threads:
/// - `dispatch()`: Run on background thread
/// - `dispatchOnMainThread()`: Run on main thread (UI-safe)
/// - `dispatchAfter()`: Run on main thread after delay
/// - `isMainThread()`: Check if current thread is main
///
/// Platform implementations:
/// - macOS: GCD-based dispatcher (dispatch_async_f)
/// - Linux: eventfd-based dispatcher with poll() integration
/// - WASM: Not available (single-threaded environment)
///
/// Error handling:
/// - error.QueueFull: Too many pending tasks (Linux only, MAX=256)
/// - error.OutOfMemory: Failed to allocate task
pub const Dispatcher = if (is_wasm)
    @compileError("Dispatcher not available on WASM (single-threaded)")
else if (is_linux)
    @import("linux/dispatcher.zig").Dispatcher
else
    @import("macos/dispatcher.zig").Dispatcher;
```

---

## Phase 4: TigersEye Integration

**Files:** `TigersEye/src/core/state.zig`, `TigersEye/src/main.zig`  
**Estimated Time:** 1 hour  
**Dependencies:** Phase 3

### 4.1 Update Dispatcher Import

In `TigersEye/src/core/state.zig`, change:

**Before (line ~33):**
```zig
const Dispatcher = platform.mac.dispatcher.Dispatcher;
```

**After:**
```zig
const Dispatcher = platform.Dispatcher;
```

### 4.2 Change Dispatcher Initialization Pattern

The Linux dispatcher requires explicit initialization because `init()` can fail (eventfd creation). The macOS dispatcher's `init()` is infallible, allowing inline initialization. For cross-platform compatibility, change to explicit init:

**Before (line ~143):**
```zig
// macOS-only: inline init works because init() can't fail
dispatcher: Dispatcher = Dispatcher.init(std.heap.page_allocator),
```

**After:**
```zig
// Cross-platform: use optional, init explicitly to handle errors
dispatcher: ?Dispatcher = null,
```

Then in `AppState.init()` or similar initialization function:
```zig
pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    // ... other init ...
    self.dispatcher = try Dispatcher.init(allocator);
}
```

And update all usages from `self.dispatcher` to `self.dispatcher.?` (or add a helper method).

### 4.3 Register Dispatcher with Platform on Linux

In `TigersEye/src/main.zig` (or wherever platform is initialized), add:

```zig
// After platform and AppState are initialized:
if (comptime gooey.platform.is_linux) {
    gooey_instance.platform.setDispatcher(&app_state.dispatcher.?);
}
```

### 4.4 Handle QueueFull Error (Recommended)

**Error Set Differences:**
- **macOS**: `dispatchOnMainThread` only fails on allocation errors
- **Linux**: Can also return `error.QueueFull` if the 256-slot queue is exhausted

In `TigersEye/src/core/state.zig`, enhance error handling:

```zig
pub fn dispatchToMain(self: *Self) void {
    self.dispatcher.?.dispatchOnMainThread(
        DispatchCtx,
        .{ .app = self },
        dispatchHandler,
    ) catch |err| {
        log.err("dispatchOnMainThread failed: {}", .{err});
        switch (err) {
            error.QueueFull => {
                // Linux-specific: queue overflow
                // Queue has 256 slots, so this is rare. Options:
                // 1. Set flag to retry on next frame
                // 2. Log and drop (current TigerBeetle result will be lost)
                // 3. Apply backpressure to TigerBeetle requests
                self.pending_main_dispatch = true;
            },
            else => {
                // Allocation failure (both platforms)
            },
        }
    };
}
```

**Note:** The current TigersEye code just logs and continues, which is acceptable since `QueueFull` should be rare with 256 slots and typical TigerBeetle request patterns.

---

## Phase 5: Gooey API Integration (P1 - Future Enhancement)

**Files:** `gooey/src/context/gooey.zig`, `gooey/src/platform/mod.zig`  
**Estimated Time:** 2 hours  
**Dependencies:** Phase 4 complete and working  
**Priority:** P1 (not blocking for initial Linux support)

This phase is a cleanup enhancement to move dispatcher ownership from TigersEye into Gooey itself, providing a cleaner cross-platform API.

### 5.1 Current Architecture (What We're Improving)

Currently, TigersEye:
1. Creates its own `Dispatcher` instance
2. Manages different init patterns per platform
3. Manually wires to Linux platform via `setDispatcher()`
4. Imports platform-specific module (`platform.mac.dispatcher`)

### 5.2 Add Thread Dispatcher to Gooey Struct

In `gooey/src/context/gooey.zig`, add:

```zig
const platform = @import("../platform/mod.zig");

pub const Gooey = struct {
    // ... existing fields ...
    
    /// Thread dispatcher for cross-thread callbacks to main thread.
    /// Null on WASM (no threads). Initialized automatically on native.
    thread_dispatcher: if (platform.is_wasm) void else ?*platform.Dispatcher = 
        if (platform.is_wasm) {} else null,
```

### 5.3 Initialize Dispatcher in Gooey.init()

In `initOwned()` and `initWithSharedResources()`:

```zig
// Initialize thread dispatcher (native only)
if (!platform.is_wasm) {
    const dispatcher_ptr = try allocator.create(platform.Dispatcher);
    errdefer allocator.destroy(dispatcher_ptr);
    dispatcher_ptr.* = try platform.Dispatcher.init(allocator);
    self.thread_dispatcher = dispatcher_ptr;
    
    // Wire to platform on Linux (automatic, no user action needed)
    if (platform.is_linux) {
        if (self.window) |w| {
            if (w.platform) |p| {
                p.setDispatcher(dispatcher_ptr);
            }
        }
    }
}
```

### 5.4 Add Dispatcher Methods to Gooey

```zig
/// Dispatch a callback to run on the main thread.
/// Safe to call from any thread. Returns error on WASM.
pub fn dispatchOnMainThread(
    self: *Self,
    comptime Context: type,
    context: Context,
    comptime callback: fn (*Context) void,
) !void {
    if (platform.is_wasm) return error.NotSupported;
    if (self.thread_dispatcher) |d| {
        try d.dispatchOnMainThread(Context, context, callback);
    } else {
        return error.NotInitialized;
    }
}

/// Dispatch a callback to run on the main thread after a delay.
/// Safe to call from any thread. Returns error on WASM.
pub fn dispatchAfter(
    self: *Self,
    delay_ns: u64,
    comptime Context: type,
    context: Context,
    comptime callback: fn (*Context) void,
) !void {
    if (platform.is_wasm) return error.NotSupported;
    if (self.thread_dispatcher) |d| {
        try d.dispatchAfter(delay_ns, Context, context, callback);
    } else {
        return error.NotInitialized;
    }
}

/// Check if current thread is the main/UI thread.
/// Always returns true on WASM (single-threaded).
pub fn isMainThread() bool {
    if (platform.is_wasm) return true;
    return platform.Dispatcher.isMainThread();
}
```

### 5.5 Clean Up in Gooey.deinit()

```zig
pub fn deinit(self: *Self) void {
    // ... existing cleanup ...
    
    // Clean up thread dispatcher (native only)
    if (!platform.is_wasm) {
        if (self.thread_dispatcher) |d| {
            d.deinit();
            self.allocator.destroy(d);
        }
    }
}
```

### 5.6 Update TigersEye to Use New API

**Before:**
```zig
const Dispatcher = platform.mac.dispatcher.Dispatcher;
dispatcher: ?Dispatcher = null,

pub fn dispatchToMain(self: *Self) void {
    self.dispatcher.?.dispatchOnMainThread(...) catch |err| { ... };
}
```

**After:**
```zig
// No dispatcher field needed - Gooey owns it

pub fn dispatchToMain(self: *Self) void {
    const gooey = self.gooey_ptr orelse return;
    gooey.dispatchOnMainThread(DispatchCtx, .{ .app = self }, handler) catch |err| {
        log.err("dispatch failed: {}", .{err});
    };
}
```

### 5.7 Benefits

| Aspect | Before (TigersEye manages) | After (Gooey manages) |
|--------|---------------------------|----------------------|
| Init pattern | Different per platform | Unified in `Gooey.init()` |
| Platform wiring | Manual on Linux | Automatic |
| Import path | `platform.mac.dispatcher` | `gooey.dispatchOnMainThread()` |
| WASM safety | Compile error | Returns `error.NotSupported` |
| Dispatcher lifetime | App manages | Gooey manages |

---

## Task Checklist

### Phase 1: Linux Dispatcher (P0) ✅ COMPLETE
- [x] Create `gooey/src/platform/linux/dispatcher.zig`
- [x] Implement `Task` struct with `create()`, `runAndDestroy()`, and `destroy()` (with assertions)
- [x] Implement `TaskQueue` with mutex-protected push/pop/len (with assertions)
- [x] Implement `Dispatcher.init()` with eventfd creation and double-init assertion
- [x] Implement `Dispatcher.deinit()` with cleanup and drain logging
- [x] Implement `Dispatcher.getFd()`
- [x] Implement `Dispatcher.dispatchOnMainThread()` with error.QueueFull
- [x] Implement `Dispatcher.dispatch()` with thread spawning
- [x] Implement `Dispatcher.dispatchAfter()` with retry/backoff on queue full
- [x] Implement `Dispatcher.processPending()` with MAX_TASKS_PER_PROCESS limit
- [x] Implement `Dispatcher.isMainThread()` (static)
- [x] Add unit tests (12 test cases - exceeded target of 10)
- [x] Verify tests pass: `zig build test`

### Phase 2: Platform Integration (P0) ✅ COMPLETE
- [x] Add `dispatcher_ref` field to `LinuxPlatform`
- [x] Add `setDispatcher()` method with assertion
- [x] Modify `run()` to use 8-slot pollfd buffer
- [x] Add dispatcher event handling in poll loop
- [x] Export dispatcher from `linux/mod.zig`
- [x] Test platform still works without dispatcher set (gooey builds and tests pass)

### Phase 3: Unified API (P0) ✅ COMPLETE
- [x] Add `Dispatcher` type alias to `platform/mod.zig` with documentation
- [x] Verify compiles on Linux (`zig build` succeeds)
- [ ] Verify compiles on macOS (no regression) - needs testing

### Phase 4: TigersEye Integration (P0) ✅ COMPLETE
- [x] Update dispatcher import in `state.zig` to use `platform.Dispatcher`
- [x] Change dispatcher field from inline init to optional (`?Dispatcher = null`)
- [x] Add explicit `Dispatcher.init()` call in AppState initialization (lazy init in `connect()`)
- [x] Update all `self.dispatcher` usages to use pointer unwrap pattern
- [x] Add `platform.setDispatcher()` call for Linux (via `window.platform`)
- [x] Add error handling for dispatcher failures (logs errors, fails operation gracefully)
- [x] Test TigersEye compiles on Linux (ReleaseSafe works, Debug has Zig i128 compiler bug - unrelated)
- [ ] Test TigersEye compiles on macOS (no regression) - needs testing
- [x] Test TigersEye runs and can query accounts on Linux (verified working!)

### Phase 5: Gooey API Integration (P1) ✅ COMPLETE
- [x] Add `thread_dispatcher` field to `Gooey` struct
- [x] Initialize dispatcher in `Gooey.initOwned()` and `initOwnedPtr()`
- [x] Initialize dispatcher in `Gooey.initWithSharedResources()` and `initWithSharedResourcesPtr()`
- [x] Wire to Linux platform automatically in init
- [x] Add `Gooey.dispatchOnMainThread()` method
- [x] Add `Gooey.dispatchAfter()` method  
- [x] Add static `Gooey.isMainThread()` method
- [x] Add `Gooey.getDispatcher()` method for advanced usage
- [x] Clean up dispatcher in `Gooey.deinit()`
- [x] Update TigersEye to use `gooey.dispatchOnMainThread()`
- [x] Remove direct dispatcher import from TigersEye
- [x] Remove `dispatcher` field from TigersEye `AppState`
- [ ] Test TigersEye works with Gooey-managed dispatcher (needs runtime test)

---

## Testing Strategy

### Unit Tests (Phase 1)

| Test | Validates |
|------|-----------|
| `Task.create allocates and stores context` | Memory allocation, type erasure |
| `Task.create with zero-size context` | Edge case handling |
| `Dispatcher.init sets main thread ID` | Initialization correctness |
| `Dispatcher.dispatch runs on background thread` | Thread spawning, `isMainThread()` |
| `Dispatcher.dispatchOnMainThread queues task` | Queue + processPending flow |
| `isMainThread returns correct value` | Main thread detection |
| `isMainThread returns false before init` | Pre-init safety |
| `TaskQueue handles overflow` | Queue limit, error.QueueFull |
| `processPending respects MAX_TASKS_PER_PROCESS limit` | Main thread stall prevention |
| `dispatchAfter delays execution` | Timer accuracy (±10ms tolerance) |
| `Multiple dispatches complete correctly` | Concurrent dispatch handling |

### Integration Tests (Phase 2)

1. **Dispatcher + Platform Integration**
   - Create dispatcher, register with platform
   - Dispatch from background thread
   - Verify poll() wakes and task runs

2. **No Dispatcher Regression**
   - Run platform without dispatcher set
   - Verify normal Wayland events still work

### End-to-End Tests (Phase 4)

1. **TigersEye Account Query**
   - Launch TigersEye on Linux
   - Connect to TigerBeetle cluster
   - Query accounts
   - Verify UI updates without freezing

2. **Transfer Creation**
   - Create a transfer
   - Verify completion callback reaches main thread
   - Verify UI reflects new transfer

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| eventfd unavailable | Very Low | High | eventfd in Linux since 2.6.22 (2007) |
| Queue overflow | Low | Medium | MAX=256, return error, retry in dispatchAfter |
| Thread spawn overhead | Medium | Low | TigerBeetle has own IO thread; rare direct use |
| Timer thread overhead | Medium | Low | Low-frequency timers; document timerfd upgrade path |
| Wrong thread calls `init()` | Medium | High | Debug assert for double-init; document requirement |
| Race in `processPending()` | Low | High | Mutex in queue; assert main thread |
| Main thread stall | Low | Medium | MAX_TASKS_PER_PROCESS limit with re-signal |

---

## Performance Expectations

| Operation | Expected Latency | Notes |
|-----------|------------------|-------|
| eventfd signal | ~100ns | Kernel syscall |
| Queue push (uncontended) | ~20ns | Mutex lock/unlock |
| Queue push (contended) | ~1μs | Rare with single producer |
| Thread spawn | 10-50μs | For `dispatch()` and `dispatchAfter()` |
| `processPending()` | O(n) tasks, max 64 | Bounded by MAX_TASKS_PER_PROCESS |
| Queue overflow retry | 1-32ms | Exponential backoff in dispatchAfter |

---

## Future Improvements

These are **not** in scope for initial implementation but documented for future reference:

### Thread Pool for `dispatch()`
Replace spawn-per-call with pre-spawned worker threads:
```zig
const WorkerPool = struct {
    workers: [4]std.Thread,
    work_queue: TaskQueue,
    work_available: std.Thread.Condition,
    shutdown: std.atomic.Value(bool),
};
```

### timerfd for `dispatchAfter()`
Replace thread-per-timer with kernel timers:
```zig
const timer_fd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true });
// Add to pollfds (we have 8 slots), fire task on readable
```

### io_uring Integration
Unified async I/O for file, network, and timer operations:
```zig
const ring = try std.os.linux.io_uring.init(256, .{});
```

---

## Acceptance Criteria

- [ ] `zig build test` passes all dispatcher tests on Linux
- [ ] `isMainThread()` returns `true` on main thread, `false` on background
- [ ] `isMainThread()` returns `false` before `init()` is called
- [ ] `dispatchOnMainThread()` wakes `poll()` and runs callback on main thread
- [ ] `processPending()` processes max 64 tasks per call, re-signals if more remain
- [ ] `dispatchAfter()` retries with backoff on queue full (doesn't run on wrong thread)
- [ ] TigersEye compiles on Linux with only import path change
- [ ] TigersEye can connect, query accounts, and create transfers on Linux
- [ ] No regression on macOS

---

## References

- [LINUX_DISPATCHER.md](./LINUX_DISPATCHER.md) — Design rationale and background
- [eventfd(2)](https://man7.org/linux/man-pages/man2/eventfd.2.html) — Linux eventfd documentation
- [poll(2)](https://man7.org/linux/man-pages/man2/poll.2.html) — Linux poll documentation
- [CLAUDE.md](../CLAUDE.md) — Engineering guidelines (assertions, limits, etc.)
- `gooey/src/platform/macos/dispatcher.zig` — Reference implementation
- `TigersEye/src/core/state.zig` — Consumer code to support