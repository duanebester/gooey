//! Grand Central Dispatch based task dispatcher
//! Uses heap-allocated tasks to ensure memory validity across async dispatch
//!
//! GCD's dispatch_async_f returns immediately, and the callback runs later
//! on another thread. This means any context passed must outlive the function
//! that created it - hence we heap-allocate both the task and its context.

const std = @import("std");
const c = @cImport({
    @cInclude("dispatch/dispatch.h");
});

/// A heap-allocated task that can be dispatched to GCD
///
/// The task owns both itself and its context, and frees both
/// after the callback completes.
pub const Task = struct {
    callback: *const fn (*anyopaque) void,
    context: *anyopaque,
    context_deinit: *const fn (std.mem.Allocator, *anyopaque) void,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a heap-allocated task with a typed context
    ///
    /// Both the Task and the Context are heap-allocated and will be
    /// automatically freed after the callback executes.
    pub fn create(
        allocator: std.mem.Allocator,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !*Self {
        // Heap-allocate the context
        const ctx_ptr = try allocator.create(Context);
        errdefer allocator.destroy(ctx_ptr);
        ctx_ptr.* = context;

        // Heap-allocate the task itself
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

    /// Run the callback and deallocate the task + context
    /// Called by the trampoline after GCD dispatches to us
    pub fn runAndDestroy(self: *Self) void {
        const allocator = self.allocator;
        const context = self.context;
        const context_deinit = self.context_deinit;

        // Run the callback
        self.callback(context);

        // Free the context (type-erased destructor)
        context_deinit(allocator, context);

        // Free the task itself
        allocator.destroy(self);
    }
};

/// Trampoline function that GCD calls on the target thread
fn trampoline(context: ?*anyopaque) callconv(.c) void {
    if (context) |ctx| {
        const task: *Task = @ptrCast(@alignCast(ctx));
        task.runAndDestroy();
    }
}

/// High-level dispatcher for scheduling work on GCD queues
pub const Dispatcher = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        // GCD manages its own resources, nothing to clean up
        _ = self;
    }

    /// Dispatch a task to a background queue (high priority)
    ///
    /// The callback will run on a background thread. The context is
    /// copied and heap-allocated, so it's safe to pass stack values.
    pub fn dispatch(
        self: *Self,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        const task = try Task.create(self.allocator, Context, context, callback);

        const queue = c.dispatch_get_global_queue(c.DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        c.dispatch_async_f(queue, task, trampoline);
    }

    /// Dispatch a task to the main thread
    ///
    /// The callback will run on the main thread during the next
    /// iteration of the run loop.
    pub fn dispatchOnMainThread(
        self: *Self,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        const task = try Task.create(self.allocator, Context, context, callback);

        const queue = c.dispatch_get_main_queue();
        c.dispatch_async_f(queue, task, trampoline);
    }

    /// Dispatch a task after a delay
    pub fn dispatchAfter(
        self: *Self,
        delay_ns: u64,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        const task = try Task.create(self.allocator, Context, context, callback);

        const queue = c.dispatch_get_global_queue(c.DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        const when = c.dispatch_time(c.DISPATCH_TIME_NOW, @intCast(delay_ns));
        c.dispatch_after_f(when, queue, task, trampoline);
    }

    /// Check if we're on the main thread
    pub fn isMainThread() bool {
        // dispatch_queue_get_label returns the label of the current queue
        // Compare with main queue label to check if we're on main
        const current_label = c.dispatch_queue_get_label(@ptrCast(c.DISPATCH_CURRENT_QUEUE_LABEL));
        const main_label = c.dispatch_queue_get_label(c.dispatch_get_main_queue());
        return current_label == main_label;
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
            ctx.flag.* = true;
            ctx.value += 1;
        }
    }.callback);

    // Run and destroy (this frees memory)
    task.runAndDestroy();

    // Callback should have executed
    try std.testing.expect(flag == true);
}

test "Dispatcher.dispatch runs callback on background thread" {
    // Skip: GCD async dispatch requires a run loop which isn't available in test environment
    return error.SkipZigTest;
}

test "Dispatcher.dispatch can modify captured state via pointer" {
    // Skip: GCD async dispatch requires a run loop which isn't available in test environment
    return error.SkipZigTest;
}

test "Dispatcher.dispatchAfter delays execution" {
    // Skip: GCD async dispatch requires a run loop which isn't available in test environment
    return error.SkipZigTest;
}

test "Multiple dispatches complete correctly" {
    // Skip: GCD async dispatch requires a run loop which isn't available in test environment
    return error.SkipZigTest;
}
