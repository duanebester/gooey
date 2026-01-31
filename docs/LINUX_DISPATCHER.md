# Linux Dispatcher Integration for TigersEye

This document analyzes how TigersEye uses Gooey's macOS dispatcher and proposes a Linux implementation using `eventfd` to enable cross-thread communication with the Wayland event loop.

## Current Architecture: macOS

### GCD Dispatcher (`gooey/src/platform/macos/dispatcher.zig`)

The macOS platform provides a Grand Central Dispatch (GCD) based dispatcher with three key methods:

```zig
pub const Dispatcher = struct {
    allocator: std.mem.Allocator,

    /// Dispatch to background thread (high priority)
    pub fn dispatch(self, Context, context, callback) !void;

    /// Dispatch to main thread (UI updates)
    pub fn dispatchOnMainThread(self, Context, context, callback) !void;

    /// Dispatch after a delay
    pub fn dispatchAfter(self, delay_ns, Context, context, callback) !void;

    /// Check if current thread is main
    pub fn isMainThread() bool;
};
```

Key characteristics:
- **Heap-allocated tasks**: Both the `Task` and its `Context` are heap-allocated to survive across async dispatch boundaries
- **Type-erased callbacks**: Uses function pointers with `*anyopaque` for generic dispatch
- **Automatic cleanup**: `runAndDestroy()` frees both task and context after callback execution
- **Thread-safe**: GCD handles all synchronization internally

### How TigersEye Uses the Dispatcher

TigersEye (`TigersEye/src/core/state.zig`) uses the dispatcher for:

1. **Cross-thread UI updates**: TigerBeetle's IO thread completes async operations, then dispatches results to the main thread for UI rendering

2. **Rate limiting with delays**: Uses `dispatchAfter` to defer operations (e.g., 50ms settle delay for IO thread)

3. **Timeout handling**: Schedules timeout callbacks to detect stalled requests

Architecture flow:
```
┌─────────────────────────────────────────────────────────────────┐
│  UI Event (button click)                                         │
│    ↓ cx.command(AppState, AppState.refreshAccounts)              │
├─────────────────────────────────────────────────────────────────┤
│  TBClient.queryAccounts(packet, filter)                          │
│    ↓ (async, TigerBeetle IO thread)                              │
├─────────────────────────────────────────────────────────────────┤
│  tbCompletionCallback → dispatcher.dispatchOnMainThread          │
│    ↓ (main thread)                                               │
├─────────────────────────────────────────────────────────────────┤
│  AppState.applyResult() → gooey.requestRender()                  │
└─────────────────────────────────────────────────────────────────┘
```

Critical code pattern from TigersEye:
```zig
// In TigerBeetle completion callback (IO thread)
fn onCompletion(ctx, packet, result, result_size, timestamp) callconv(.c) void {
    const self: *TBClient = @ptrFromInt(ctx);

    // Assert we're NOT on main thread
    std.debug.assert(!Dispatcher.isMainThread());

    // Parse response on IO thread
    const response = parseResponse(packet.operation, result, result_size, timestamp);

    // Dispatch to main thread for UI update
    self.dispatcher.dispatchOnMainThread(CompletionCtx, .{
        .gooey = self.gooey_ctx,
        .request_tag = packet.user_tag,
        .response = response,
    }, handleOnMain);
}

fn handleOnMain(ctx: *CompletionCtx) void {
    // Assert we ARE on main thread
    std.debug.assert(Dispatcher.isMainThread());

    // Safe to update UI
    ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onAccountsLoaded);
}
```

## Linux Challenge: No GCD Equivalent

Linux doesn't have GCD. The Wayland event loop in `gooey/src/platform/linux/platform.zig` uses:

```zig
pub fn run(self: *Self) void {
    const display = self.display orelse return;
    const fd = wayland.displayGetFd(display);

    var pollfds = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };

    while (self.running) {
        // Render frame if needed
        if (self.active_window) |window| {
            window.renderFrame();
        }

        // Flush and poll for events
        _ = wayland.wl_display_flush(display);
        _ = posix.poll(&pollfds, timeout_ms);

        // Dispatch incoming events
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            _ = wayland.wl_display_dispatch(display);
        }
    }
}
```

The problem: **`poll()` only wakes for Wayland events**, not for cross-thread signals from TigerBeetle's IO thread.

## Proposed Solution: eventfd-based Dispatcher

### Design Overview

Use Linux's `eventfd` as a lightweight signaling mechanism that integrates with the `poll()` loop:

```
┌─────────────────────────────────────────────────────────────────┐
│  IO Thread                          │  Main Thread              │
├─────────────────────────────────────┼───────────────────────────┤
│  1. Complete async operation        │                           │
│  2. Queue task (thread-safe)        │                           │
│  3. Write to eventfd (signal)       │                           │
│                                     │  4. poll() wakes up       │
│                                     │  5. Read eventfd (drain)  │
│                                     │  6. Process queued tasks  │
│                                     │  7. Update UI             │
└─────────────────────────────────────┴───────────────────────────┘
```

### Design Analysis & Recommendations

#### Why eventfd is the Right Choice

The `eventfd` + `poll()` integration is the idiomatic Linux mechanism for cross-thread signaling. This matches how other Linux async runtimes (tokio, io_uring-based systems) handle cross-thread wakeups. The overhead is ~100ns per signal—negligible compared to network latency.

#### Performance Comparison: GCD vs eventfd

| Operation | GCD (macOS) | eventfd (Linux) |
|-----------|-------------|-----------------|
| Signal wakeup | ~50-100ns | ~100ns |
| Queue push | lock-free (GCD internal) | mutex (~20ns uncontended) |
| Thread spawn | ~10μs | ~10-50μs |
| Timer scheduling | kernel-backed | timerfd (kernel) or thread |

**Verdict**: Performance will be comparable. The eventfd approach is the standard Linux solution.

### Implementation

#### 1. Linux Dispatcher (`gooey/src/platform/linux/dispatcher.zig`)

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
/// With 256 slots and TigerBeetle's typical request patterns, overflow is unlikely.
/// If hit, dispatchOnMainThread returns error.QueueFull - callers should handle this.
const MAX_PENDING_TASKS = 256;

/// Maximum tasks to process per processPending() call to prevent main thread stalls
const MAX_TASKS_PER_PROCESS: usize = 64;

/// Module-level main thread ID for static isMainThread() API compatibility with macOS
var main_thread_id: ?std.Thread.Id = null;

/// A heap-allocated task with type-erased callback
pub const Task = struct {
    callback: *const fn (*anyopaque) void,
    context: *anyopaque,
    context_deinit: *const fn (std.mem.Allocator, *anyopaque) void,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a heap-allocated task (mirrors macOS API)
    pub fn create(
        allocator: std.mem.Allocator,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !*Self {
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

/// Thread-safe MPSC (multi-producer, single-consumer) task queue.
///
/// Memory ordering: The mutex provides acquire semantics on lock and release
/// semantics on unlock, ensuring proper visibility of queue modifications.
///
/// Capacity: Fixed at MAX_PENDING_TASKS. Push returns error.QueueFull if exceeded.
const TaskQueue = struct {
    tasks: [MAX_PENDING_TASKS]*Task = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},

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

    fn pop(self: *TaskQueue) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();

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

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Assertion: init() must only be called once
        std.debug.assert(main_thread_id == null);

        // Store main thread ID for static isMainThread() compatibility
        // IMPORTANT: init() must be called from the main thread
        main_thread_id = std.Thread.getCurrentId();

        // Note: EFD_SEMAPHORE is not used - each read drains the counter entirely,
        // which is fine since we drain the queue anyway after wakeup.
        const efd = try posix.eventfd(0, .{
            .NONBLOCK = true,
            .CLOEXEC = true,
        });

        std.debug.assert(efd >= 0);

        return .{
            .allocator = allocator,
            .event_fd = efd,
            .pending_queue = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        // Callbacks expect main thread context, so deinit must be called from main
        std.debug.assert(isMainThread());
        std.debug.assert(self.event_fd >= 0);

        posix.close(self.event_fd);

        // Drain remaining tasks to avoid memory leaks
        // Note: callbacks will run on main thread as expected
        while (self.pending_queue.pop()) |task| {
            task.runAndDestroy();
        }
    }

    /// Get the eventfd for integration with poll()
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.event_fd;
    }

    /// Dispatch a task to run on the main thread
    /// Thread-safe: can be called from any thread
    pub fn dispatchOnMainThread(
        self: *Self,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        const task = try Task.create(self.allocator, Context, context, callback);
        errdefer task.runAndDestroy();

        try self.pending_queue.push(task);

        // Signal the eventfd to wake poll()
        const val: u64 = 1;
        _ = posix.write(self.event_fd, std.mem.asBytes(&val)) catch |err| {
            // EAGAIN/EWOULDBLOCK is OK - eventfd counter would overflow,
            // meaning main thread already has a pending wakeup signal
            if (err != error.WouldBlock) return err;
        };
    }

    /// Dispatch to background thread
    /// Thread-safe: can be called from any thread
    ///
    /// Note: This spawns a new thread per call (~10-50μs overhead).
    /// For high-frequency dispatching, consider using a thread pool.
    /// TigersEye's TigerBeetle IO uses its own thread pool internally,
    /// so this is mainly for one-off background work.
    pub fn dispatch(
        self: *Self,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        const task = try Task.create(self.allocator, Context, context, callback);

        const thread = try std.Thread.spawn(.{}, struct {
            fn run(t: *Task) void {
                t.runAndDestroy();
            }
        }.run, .{task});
        thread.detach();
    }

    /// Dispatch after a delay
    /// Thread-safe: can be called from any thread
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
    pub fn dispatchAfter(
        self: *Self,
        delay_ns: u64,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
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
                                std.time.sleep(retry_delay_ns);
                                retry_delay_ns *= 2;
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
                // WARNING: We do NOT run the callback here because we're on the wrong thread
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
    }

    /// Process pending tasks (call from main thread after poll wakes)
    /// NOT thread-safe: must only be called from main thread
    ///
    /// Processes up to MAX_TASKS_PER_PROCESS tasks per call to prevent main thread stalls.
    /// If more tasks remain, re-signals the eventfd so poll() will wake again.
    ///
    /// Returns: number of tasks processed
    pub fn processPending(self: *Self) usize {
        std.debug.assert(isMainThread());
        std.debug.assert(self.event_fd >= 0);

        // Drain eventfd counter
        var buf: [8]u8 = undefined;
        _ = posix.read(self.event_fd, &buf) catch {};

        // Process up to MAX_TASKS_PER_PROCESS tasks
        var processed: usize = 0;
        while (processed < MAX_TASKS_PER_PROCESS) {
            const task = self.pending_queue.pop() orelse break;
            task.runAndDestroy();
            processed += 1;
        }

        // If more tasks remain, re-signal eventfd so we wake up again
        if (self.pending_queue.len() > 0) {
            const val: u64 = 1;
            _ = posix.write(self.event_fd, std.mem.asBytes(&val)) catch {};
        }

        return processed;
    }

    /// Check if current thread is main thread
    /// Static method for API compatibility with macOS GCD dispatcher
    pub fn isMainThread() bool {
        return std.Thread.getCurrentId() == (main_thread_id orelse return false);
    }
};
```

#### 2. Platform Integration (`gooey/src/platform/linux/platform.zig`)

Modify the run loop to poll on both Wayland fd AND the dispatcher's eventfd:

```zig
const dispatcher = @import("dispatcher.zig");

pub const LinuxPlatform = struct {
    // ... existing fields ...
    dispatcher_ref: ?*dispatcher.Dispatcher = null,

    /// Set a dispatcher for cross-thread communication
    pub fn setDispatcher(self: *Self, d: *dispatcher.Dispatcher) void {
        self.dispatcher_ref = d;
    }

    pub fn run(self: *Self) void {
        const display = self.display orelse return;
        const wayland_fd = wayland.displayGetFd(display);

        // Build pollfd array - always include Wayland, optionally dispatcher
        // Using 8 slots for future expansion (timerfd, etc.)
        var pollfds_buf: [8]posix.pollfd = undefined;
        var num_fds: usize = 1;

        pollfds_buf[0] = .{ .fd = wayland_fd, .events = posix.POLL.IN, .revents = 0 };

        if (self.dispatcher_ref) |d| {
            pollfds_buf[1] = .{ .fd = d.getFd(), .events = posix.POLL.IN, .revents = 0 };
            num_fds = 2;
        }

        const pollfds = pollfds_buf[0..num_fds];

        while (self.running) {
            // Render frame if needed
            if (self.active_window) |window| {
                if (window.isClosed()) {
                    self.running = false;
                    break;
                }
                window.renderFrame();
            }

            // Flush Wayland
            _ = wayland.wl_display_flush(display);
            _ = wayland.wl_display_dispatch_pending(display);

            // Calculate timeout
            const timeout_ms: i32 = if (self.active_window) |w|
                if (w.needs_redraw or w.continuous_render) 0 else 16
            else
                16;

            // Poll both fds
            const poll_result = posix.poll(pollfds, timeout_ms) catch {
                self.running = false;
                break;
            };

            if (poll_result > 0) {
                // Handle Wayland events
                if (pollfds[0].revents & posix.POLL.IN != 0) {
                    if (wayland.wl_display_dispatch(display) < 0) {
                        self.running = false;
                        break;
                    }
                }

                // Handle dispatcher events (cross-thread tasks)
                if (num_fds > 1 and pollfds[1].revents & posix.POLL.IN != 0) {
                    if (self.dispatcher_ref) |d| {
                        _ = d.processPending();
                    }
                }
            }
        }
    }
};
```

#### 3. Module Export (`gooey/src/platform/linux/mod.zig`)

```zig
// Add to existing exports
pub const dispatcher = @import("dispatcher.zig");
```

#### 4. Cross-Platform API (`gooey/src/platform/mod.zig`)

Unified dispatcher type for clean cross-platform code:

```zig
pub const Dispatcher = if (is_wasm)
    @compileError("Dispatcher not available on web")
else if (is_linux)
    @import("linux/dispatcher.zig").Dispatcher
else
    @import("macos/dispatcher.zig").Dispatcher;
```

TigersEye can then use:
```zig
const Dispatcher = gooey.platform.Dispatcher;
```

## API Compatibility

The Linux dispatcher API is designed to match macOS exactly:

| Method | macOS (GCD) | Linux (eventfd) | Notes |
|--------|-------------|-----------------|-------|
| `init(allocator)` | ✅ (infallible) | ✅ (can fail) | Linux returns error for eventfd creation |
| `deinit()` | ✅ | ✅ | |
| `dispatch(Context, ctx, callback)` | ✅ | ✅ | |
| `dispatchOnMainThread(Context, ctx, callback)` | ✅ | ✅ | **Linux adds `error.QueueFull`** |
| `dispatchAfter(delay_ns, Context, ctx, callback)` | ✅ | ✅ | |
| `isMainThread()` | ✅ (static) | ✅ (static) | Unified API |

**Error Set Differences**:
- `init()`: macOS cannot fail (GCD is always available). Linux can fail with `posix.eventfd` errors.
- `dispatchOnMainThread()`: macOS only fails on allocation. Linux can also return `error.QueueFull` if the 256-slot queue is exhausted.
- `dispatchAfter()`: Both can fail on allocation/thread spawn. Linux version retries with backoff on queue full, eventually dropping the task (logged as warning).

**API Unification**: The Linux implementation uses a module-level `main_thread_id` variable set during `init()` to provide a static `isMainThread()` method, matching macOS behavior. This allows identical call sites:

```zig
// Works on both platforms
std.debug.assert(!Dispatcher.isMainThread());
```

## Required Changes to TigersEye

1. **Import path**: Change from `platform.mac.dispatcher` to `platform.Dispatcher` (with unified API)

2. **Dispatcher initialization**: The Linux dispatcher requires explicit initialization (returns error for eventfd creation), unlike macOS which can be initialized inline. Change from inline init to explicit:
   ```zig
   // BEFORE (macOS - inline init works because init() can't fail)
   dispatcher: Dispatcher = Dispatcher.init(std.heap.page_allocator),

   // AFTER (cross-platform - explicit init to handle potential errors)
   dispatcher: ?Dispatcher = null,

   // In AppState.init() or similar:
   pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
       self.dispatcher = try Dispatcher.init(allocator);
       // ...
   }
   ```

3. **Platform registration**: Register dispatcher with platform on Linux so `poll()` can wake on cross-thread signals:
   ```zig
   // In main.zig or AppState.init, after dispatcher is initialized
   if (comptime gooey.platform.is_linux) {
       platform.setDispatcher(&self.dispatcher.?);
   }
   ```

4. **Error handling difference**: On Linux, `dispatchOnMainThread` can return `error.QueueFull` (queue capacity is 256). On macOS, it only fails on allocation errors. Handle accordingly:
   ```zig
   self.dispatcher.dispatchOnMainThread(Ctx, ctx, callback) catch |err| {
       std.log.err("dispatch failed: {}", .{err});
       switch (err) {
           error.QueueFull => {
               // Linux-specific: queue overflow, consider retry or backpressure
           },
           else => {
               // Allocation failure (both platforms)
           },
       }
   };
   ```

## Gooey API Integration (Future Enhancement)

Currently, TigersEye creates and manages its own `Dispatcher` instance separately from Gooey. This works but has friction:

1. Different init patterns (macOS infallible, Linux fallible)
2. Manual platform registration on Linux (`platform.setDispatcher()`)
3. TigersEye imports platform-specific module (`platform.mac.dispatcher`)

### Recommended: Gooey Owns the Dispatcher

A cleaner API would have Gooey own and manage the dispatcher internally:

```zig
// In gooey/src/context/gooey.zig
pub const Gooey = struct {
    // ... existing fields ...
    
    /// Thread dispatcher for cross-thread callbacks to main thread.
    /// Null on WASM (no threads). Initialized automatically on native.
    thread_dispatcher: if (platform.is_wasm) void else ?*platform.Dispatcher = null,

    pub fn init(...) !Gooey {
        // ... existing init ...
        
        // Initialize thread dispatcher (native only)
        if (!platform.is_wasm) {
            self.thread_dispatcher = try allocator.create(platform.Dispatcher);
            self.thread_dispatcher.?.* = try platform.Dispatcher.init(allocator);
            
            // Wire to platform on Linux (automatic, no user action needed)
            if (platform.is_linux) {
                plat.setDispatcher(self.thread_dispatcher.?);
            }
        }
    }

    /// Dispatch a callback to run on the main thread.
    /// Safe to call from any thread. Returns error on WASM (no threads).
    pub fn dispatchOnMainThread(
        self: *Gooey,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        if (platform.is_wasm) return error.NotSupported;
        if (self.thread_dispatcher) |d| {
            try d.dispatchOnMainThread(Context, context, callback);
        }
    }

    /// Check if current thread is the main/UI thread.
    pub fn isMainThread() bool {
        if (platform.is_wasm) return true; // WASM is single-threaded
        return platform.Dispatcher.isMainThread();
    }
};
```

### Benefits

| Aspect | Current (TigersEye manages) | Proposed (Gooey manages) |
|--------|---------------------------|-------------------------|
| Init | Different per platform | Unified, handled in `Gooey.init()` |
| Platform wiring | Manual on Linux | Automatic |
| Import path | `platform.mac.dispatcher` | `gooey.dispatchOnMainThread()` |
| Error handling | Platform-specific | Unified `DispatchError` |
| WASM safety | Compile error if imported | Returns `error.NotSupported` |

### TigersEye Would Become

```zig
// Before: Platform-specific dispatcher management
const Dispatcher = platform.mac.dispatcher.Dispatcher;
dispatcher: Dispatcher = Dispatcher.init(allocator),
// ... manual setDispatcher() on Linux ...

pub fn dispatchToMain(self: *Self) void {
    self.dispatcher.dispatchOnMainThread(...) catch |err| { ... };
}

// After: Use Gooey's integrated dispatcher
pub fn dispatchToMain(self: *Self) void {
    const gooey = self.gooey_ptr orelse return;
    gooey.dispatchOnMainThread(DispatchCtx, .{ .app = self }, handler) catch |err| {
        log.err("dispatch failed: {}", .{err});
    };
}
```

### Implementation Priority

This is a **P1 enhancement** - not blocking for initial Linux support. The current approach (TigersEye manages dispatcher) works fine. This cleanup can be done after Linux dispatcher is proven working.

**Checklist for future Gooey integration:**
- [ ] Add `thread_dispatcher` field to `Gooey` struct
- [ ] Initialize in `Gooey.init()` / `initOwned()` / `initWithSharedResources()`
- [ ] Wire to platform automatically on Linux
- [ ] Add `gooey.dispatchOnMainThread()` method
- [ ] Add `gooey.dispatchAfter()` method
- [ ] Add static `Gooey.isMainThread()` method
- [ ] Clean up in `Gooey.deinit()`
- [ ] Update TigersEye to use new API
- [ ] Remove direct dispatcher import from TigersEye

---

## Implementation Plan

### Phase 1: Create Linux Dispatcher
1. Implement `gooey/src/platform/linux/dispatcher.zig`
2. Add tests for task creation, queue operations, and signaling
3. Export from `linux/mod.zig`

### Phase 2: Integrate with Platform
1. Add `dispatcher_ref` field to `LinuxPlatform`
2. Modify `run()` to poll dispatcher's eventfd
3. Add `setDispatcher()` method

### Phase 3: Unified API
1. Add `platform.Dispatcher` type alias in `mod.zig`
2. Ensure API parity between macOS and Linux (static `isMainThread()`)
3. Update documentation

### Phase 4: TigersEye Integration
1. Update dispatcher import to use unified API
2. Register dispatcher with platform on Linux
3. Test with actual TigerBeetle operations

## Testing Strategy

1. **Unit tests** in `dispatcher.zig`:
   - Task creation and destruction
   - Queue push/pop under contention
   - eventfd signaling
   - `isMainThread()` from main and background threads

2. **Integration tests**:
   - Cross-thread dispatch with poll() wakeup
   - Multiple simultaneous dispatches
   - `dispatchAfter` timing accuracy (within ~5ms tolerance)
   - Queue overflow handling

3. **End-to-end**:
   - TigersEye querying accounts on Linux
   - UI responsiveness during async operations

## Future Improvements

### Thread Pool for `dispatch()`

Current implementation spawns a thread per call. For high-frequency dispatching:

```zig
const WorkerPool = struct {
    workers: [4]std.Thread,
    work_queue: TaskQueue,
    work_available: std.Thread.Condition,
    // ...
};
```

**When to implement**: If profiling shows thread spawn overhead is significant.

### timerfd for `dispatchAfter()`

Replace thread-per-timer with kernel timers:

```zig
const TimerRegistry = struct {
    timerfds: [MAX_TIMERS]struct { fd: posix.fd_t, task: *Task },
    count: usize,

    fn scheduleAfter(self: *Self, delay_ns: u64, task: *Task) !void {
        const tfd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        const spec = posix.itimerspec{
            .it_value = .{ .tv_sec = delay_ns / 1_000_000_000, .tv_nsec = delay_ns % 1_000_000_000 },
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        };
        try posix.timerfd_settime(tfd, .{}, &spec, null);
        // Add to registry, include in pollfds
    }
};
```

**When to implement**: If application needs hundreds of concurrent timers.

### io_uring Integration

For truly async background work without thread overhead:

```zig
// Future: Submit work to io_uring, get completion via eventfd
const ring = try std.os.linux.io_uring.init(256, .{});
```

**When to implement**: If `dispatch()` becomes a bottleneck for CPU-bound work.

## References

- [eventfd(2) man page](https://man7.org/linux/man-pages/man2/eventfd.2.html)
- [timerfd_create(2) man page](https://man7.org/linux/man-pages/man2/timerfd_create.2.html)
- [Wayland display dispatch](https://wayland.freedesktop.org/docs/html/apb.html)
- TigersEye integration: `TigersEye/docs/INTEGRATION.md`
- Gooey macOS dispatcher: `gooey/src/platform/macos/dispatcher.zig`
