//! One drawable acquired ahead of each frame, off the main thread.
//!
//! Frames are built and encoded on the main thread, and `-[CAMetalLayer nextDrawable]` can
//! sleep there for most of a refresh interval: Core Animation paces acquisition to the
//! compositor. Measured on macOS 26 with the console locked, a layer drawn at 120 Hz slept
//! 3.5-6.5 ms in every call, stalling input and every other window behind it.
//!
//! No client-visible state predicts that sleep, so a "skip the tick when no drawable is
//! free" check cannot be written against it. At the moment of each blocking call the layer
//! had 0 command buffers in flight (completed handlers), 0 drawables awaiting presentation
//! (presented handlers), 0 live drawable objects, and every pool surface reported not in
//! use (`IOSurfaceIsInUse`). Instead the reserve moves the wait to a worker: it keeps one
//! drawable acquired in advance, and the main thread only ever takes it. A tick that finds
//! none ready yet is skipped and the window stays dirty for the next tick.
//!
//! ## Protocol
//!
//! `state` moves `empty -> acquiring` (main thread, `request`), then `acquiring -> ready`
//! or `acquiring -> empty` (worker, `acquire`), then `ready -> empty` (main thread, `take`
//! or `drop`). Each side writes only in its own states, so `drawable` needs no lock: the
//! worker writes it before publishing `ready`, and the main thread reads it only after
//! observing `ready`. At most one acquisition is ever in flight.
//!
//! ## Lifetime
//!
//! The worker receives a pointer to the reserve, so the reserve must not move between its
//! first `request` and `deinit`; it lives inside the renderer of a heap-allocated window.
//! `deinit` waits on the serial queue for any in-flight acquisition, so no worker can touch
//! freed memory. That wait is bounded by `nextDrawable`'s own one-second timeout, which
//! `init` asserts is enabled.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - One serial user-interactive dispatch queue per window, created at init.
//! - Per presented frame: one `dispatch_async_f` work item and one `nextDrawable` call, both
//!   on the worker. The main thread does an atomic load, two size reads, and the async call.
//! - Drawables held: at most one in reserve, out of the layer's `maximumDrawableCount` (3):
//!   one on screen, one being rendered, one in reserve. libdispatch and Core Animation
//!   manage their own internal storage for the work item and the drawable.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");

const mtl = @import("api.zig");

pub const DrawableReserve = struct {
    /// Borrowed; the window's view keeps the layer alive until after `deinit`.
    layer: objc.Object,
    /// Owned serial queue that runs `acquire`.
    queue: *anyopaque,
    state: std.atomic.Value(State),
    /// The reserved `CAMetalDrawable`, retained +1, while `state == .ready`; otherwise null.
    drawable: ?*anyopaque,

    pub const State = enum(u8) { empty, acquiring, ready };

    const Self = @This();

    pub fn init(layer: objc.Object) !Self {
        assert(layer.value != null);
        assert(isMainThread());
        // A worker blocked in `nextDrawable` gives up after one second, which bounds the
        // wait in `deinit`.
        assert(layer.msgSend(bool, "allowsNextDrawableTimeout", .{}));

        const attributes = dispatch_queue_attr_make_with_qos_class(
            null,
            qos_class_user_interactive,
            0,
        );
        const queue = dispatch_queue_create("com.gooey.drawable-reserve", attributes) orelse
            return error.DispatchQueueCreationFailed;
        return .{ .layer = layer, .queue = queue, .state = .init(.empty), .drawable = null };
    }

    /// Wait for any in-flight acquisition, then give a reserved drawable back to the pool.
    /// Main thread only, after the window's last frame.
    pub fn deinit(self: *Self) void {
        assert(isMainThread());
        // The queue is serial, so this returns only after every queued `acquire` has run.
        dispatch_sync_f(self.queue, null, deinitDrain);
        assert(self.state.load(.acquire) != .acquiring);

        if (self.state.load(.acquire) == .ready) self.drop();
        assert(self.drawable == null);
        dispatch_release(self.queue);
        self.* = undefined;
    }

    /// Whether a drawable that fits the layer's current size is reserved. When none is,
    /// starts acquiring one (unless an acquisition is already in flight) and returns false.
    /// Never waits. Main thread only.
    pub fn ready(self: *Self) bool {
        assert(isMainThread());
        switch (self.state.load(.acquire)) {
            .acquiring => return false,
            .empty => {
                self.request();
                return false;
            },
            .ready => {
                assert(self.drawable != null);
                if (fitsLayer(objc.Object.fromId(self.drawable.?), self.layer)) return true;

                // Acquired before a resize: give it back to the pool, acquire a fresh one.
                self.drop();
                self.request();
                return false;
            },
        }
    }

    /// Hand over the reserved drawable, retained +1 for the caller to release, and start
    /// acquiring the next one so it is ready by the next tick. Precondition: `ready()`
    /// returned true and the layer has not been resized since. Main thread only.
    pub fn take(self: *Self) objc.Object {
        assert(isMainThread());
        assert(self.state.load(.acquire) == .ready);
        const drawable = objc.Object.fromId(self.drawable.?);
        assert(fitsLayer(drawable, self.layer));

        self.drawable = null;
        self.state.store(.empty, .monotonic);
        self.request();
        return drawable;
    }

    /// Acquire a drawable on the main thread, waiting if the layer has none free, retained
    /// +1 for the caller to release. Only for synchronous frames (live resize), which must
    /// present at the window's new size inside the current transaction. A reserved drawable
    /// is given back first: it has the old size, and holding it would leave one fewer.
    pub fn acquireWaiting(self: *Self) ?objc.Object {
        assert(isMainThread());
        if (self.state.load(.acquire) == .ready) self.drop();

        const drawable = self.layer.msgSend(?*anyopaque, "nextDrawable", .{}) orelse
            return null;
        return objc.Object.fromId(objc_retain(drawable).?);
    }

    fn drop(self: *Self) void {
        assert(self.state.load(.acquire) == .ready);
        objc.Object.fromId(self.drawable.?).release();
        self.drawable = null;
        self.state.store(.empty, .monotonic);
    }

    fn request(self: *Self) void {
        assert(self.state.load(.monotonic) == .empty);
        assert(self.drawable == null);
        // `dispatch_async_f` publishes this store, and the pointer, to the worker.
        self.state.store(.acquiring, .monotonic);
        dispatch_async_f(self.queue, self, acquire);
    }

    /// Worker thread. The only place an asynchronous frame's drawable is acquired.
    fn acquire(context: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(context.?));
        assert(self.state.load(.acquire) == .acquiring);
        assert(self.drawable == null);

        // `nextDrawable` returns an autoreleased object; worker threads have no pool.
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        if (self.layer.msgSend(?*anyopaque, "nextDrawable", .{})) |drawable| {
            self.drawable = objc_retain(drawable).?;
            self.state.store(.ready, .release);
        } else {
            // Timed out, or the layer has no size yet: the next dirty tick asks again.
            self.state.store(.empty, .release);
        }
    }

    fn deinitDrain(_: ?*anyopaque) callconv(.c) void {}
};

/// The layer truncates `drawableSize` to whole pixels when it is set, so a drawable fits
/// exactly when its texture has those dimensions.
fn fitsLayer(drawable: objc.Object, layer: objc.Object) bool {
    assert(drawable.value != null);
    const size = layer.msgSend(mtl.CGSize, "drawableSize", .{});
    assert(size.width >= 0);
    assert(size.height >= 0);
    const texture = drawable.msgSend(objc.Object, "texture", .{});
    if (texture.msgSend(c_ulong, "width", .{}) != @as(c_ulong, @intFromFloat(size.width))) {
        return false;
    }
    return texture.msgSend(c_ulong, "height", .{}) == @as(c_ulong, @intFromFloat(size.height));
}

fn isMainThread() bool {
    return pthread_main_np() != 0;
}

const qos_class_user_interactive: c_uint = 0x21;

extern "c" fn dispatch_queue_attr_make_with_qos_class(
    attributes: ?*anyopaque,
    qos_class: c_uint,
    relative_priority: c_int,
) ?*anyopaque;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attributes: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_async_f(
    queue: *anyopaque,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
extern "c" fn dispatch_sync_f(
    queue: *anyopaque,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
extern "c" fn dispatch_release(object: *anyopaque) void;
extern "c" fn objc_retain(object: ?*anyopaque) ?*anyopaque;
extern "c" fn pthread_main_np() c_int;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// Goal: walk the state machine against a real (window-less) layer. The first ask starts an
// acquisition off the main thread; `take` hands over a drawable of the layer's size and
// starts the next one; a resize makes the reserved drawable stale, so it is dropped and
// replaced; a synchronous acquisition gives the reserve back first; and `deinit` with an
// acquisition in flight waits it out. Skipped where no Metal device exists.
test "DrawableReserve: acquire ahead, take, resize, synchronous, tear down in flight" {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice() orelse
        return error.SkipZigTest);
    defer device.release();
    const layer = objc.getClass("CAMetalLayer").?.msgSend(objc.Object, "layer", .{});
    layer.msgSend(void, "setDevice:", .{device.value});
    layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{ .width = 64, .height = 32 }});

    var reserve = try DrawableReserve.init(layer);
    try testing.expect(!reserve.ready());
    try testing.expect(reserve.state.load(.acquire) != .empty);
    try testing.expect(testWaitReady(&reserve));

    const first = reserve.take();
    try testing.expect(fitsLayer(first, layer));
    first.release();
    try testing.expect(reserve.state.load(.acquire) != .empty);
    try testing.expect(testWaitReady(&reserve));

    layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{ .width = 48, .height = 48 }});
    try testing.expect(!reserve.ready());
    try testing.expect(testWaitReady(&reserve));
    const resized = reserve.take();
    const texture = resized.msgSend(objc.Object, "texture", .{});
    try testing.expectEqual(@as(c_ulong, 48), texture.msgSend(c_ulong, "width", .{}));
    resized.release();

    try testing.expect(testWaitReady(&reserve));
    const waited = reserve.acquireWaiting().?;
    try testing.expect(reserve.state.load(.acquire) == .empty);
    waited.release();

    // `take` requests the next drawable, so this tears down with an acquisition in flight
    // (or just completed); `deinit` must wait for it and release whatever it reserved.
    try testing.expect(testWaitReady(&reserve));
    reserve.take().release();
    reserve.deinit();
}

/// Poll `ready` for up to one second, the bound of `nextDrawable`'s own timeout.
fn testWaitReady(reserve: *DrawableReserve) bool {
    const poll_count_max: u32 = 200;
    var poll_count: u32 = 0;
    while (poll_count < poll_count_max) : (poll_count += 1) {
        if (reserve.ready()) return true;
        var interval: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&interval, null);
    }
    return false;
}
