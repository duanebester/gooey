//! Grand Central Dispatch based task dispatcher
//! Similar to GPUI's trampoline system for running Zig callbacks via GCD

const std = @import("std");
const c = @cImport({
    @cInclude("dispatch/dispatch.h");
});

/// A task that can be dispatched to GCD
pub const Task = struct {
    callback: *const fn (*anyopaque) void,
    context: *anyopaque,

    pub fn init(callback: *const fn (*anyopaque) void, context: *anyopaque) Task {
        return .{
            .callback = callback,
            .context = context,
        };
    }
};

/// Trampoline function that GCD calls, which then invokes our Zig callback
fn trampoline(context: ?*anyopaque) callconv(.c) void { // lowercase .c
    if (context) |ctx| {
        const task: *Task = @ptrCast(@alignCast(ctx));
        task.callback(task.context);
    }
}

pub const Dispatcher = struct {
    const Self = @This();

    /// Dispatch a task to a background queue
    pub fn dispatch(task: *Task) void {
        const queue = c.dispatch_get_global_queue(c.DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        c.dispatch_async_f(queue, task, trampoline);
    }

    /// Dispatch a task to the main thread
    pub fn dispatchOnMainThread(task: *Task) void {
        const queue = c.dispatch_get_main_queue();
        c.dispatch_async_f(queue, task, trampoline);
    }

    /// Dispatch a task after a delay
    pub fn dispatchAfter(delay_ns: u64, task: *Task) void {
        const queue = c.dispatch_get_global_queue(c.DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        const when = c.dispatch_time(c.DISPATCH_TIME_NOW, @intCast(delay_ns));
        c.dispatch_after_f(when, queue, task, trampoline);
    }

    /// Check if we're on the main thread
    pub fn isMainThread() bool {
        return c.dispatch_queue_get_label(c.DISPATCH_CURRENT_QUEUE_LABEL) ==
            c.dispatch_queue_get_label(c.dispatch_get_main_queue());
    }
};

/// Higher-level async utilities using the dispatcher
pub fn spawn(comptime callback: fn () void) void {
    const S = struct {
        fn run(_: *anyopaque) void {
            callback();
        }
    };

    var task = Task.init(S.run, undefined);
    Dispatcher.dispatch(&task);
}

/// Run a callback on the main thread
pub fn runOnMainThread(comptime callback: fn () void) void {
    const S = struct {
        fn run(_: *anyopaque) void {
            callback();
        }
    };

    var task = Task.init(S.run, undefined);
    Dispatcher.dispatchOnMainThread(&task);
}
