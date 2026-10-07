//! Shared per-display vsync that drives main-thread frames (GPUI design).
//!
//! ## Model
//!
//! - One `CVDisplayLink` per physical display, keyed by `CGDirectDisplayID`,
//!   stored in a fixed-capacity process-wide table. A display's link runs only
//!   while at least one visible window on that display is subscribed.
//! - The CoreVideo callback does no UI work. It calls
//!   `dispatch_source_merge_data(source, 1)` on the display's
//!   `DISPATCH_SOURCE_TYPE_DATA_ADD` source, which targets the main queue.
//!   Ticks that arrive while the main thread is busy merge into one handler
//!   run, so a slow frame never builds a backlog.
//! - The main-queue handler walks the display's subscribers and calls each
//!   window's tick. The window decides whether anything is dirty, then builds,
//!   encodes, and presents on the main thread.
//!
//! ## Why one dispatch source per display, not per window
//!
//! The CV thread reads the source it merges into. If that source belonged to a
//! window, closing the window would release it on the main thread while the CV
//! thread could be about to merge into it, which needs a lock to make safe. A
//! per-display source is created with the link and lives as long as it, so the
//! CV thread only ever reads an immutable, immortal pointer. Subscriber lists
//! are touched only on the main thread: by `subscribe` / `unsubscribe` and by
//! the handler. Unsubscribing before freeing a window therefore guarantees no
//! tick can reach it.
//!
//! ## Why links and sources are never released
//!
//! Zed observed crashes from `CVDisplayLinkRelease` racing the CoreVideo timer
//! thread (zed-industries/zed#32116) and stopped releasing links. Gooey does the
//! same: each entry is created at most once per display for the process
//! lifetime. Storage is the fixed `displays` table; CoreVideo and libdispatch
//! allocate their own objects internally when a display first gains a window.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Displays: at most `display_count_max` (8) entries, each one link and one
//!   source. Subscribers: at most `subscriber_count_max` (the window registry's
//!   ceiling) per display.
//! - Per vsync per display: one CV callback (one merge), at most one main-queue
//!   handler run, and one tick call per subscribed window. An idle window's tick
//!   is a few loads and branches and builds no frame.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const WindowRegistry = @import("../window_registry.zig").WindowRegistry;

/// Physical displays that can hold subscribed windows at once.
pub const display_count_max: u32 = 8;

/// Subscribed windows per display. A window subscribes to at most one display,
/// so the window registry's ceiling bounds every display's list.
pub const subscriber_count_max: u32 = WindowRegistry.MAX_WINDOWS;

/// Called on the main thread once per coalesced vsync tick.
pub const TickFn = *const fn (context: *anyopaque, now_ns: u64) void;

pub const Subscriber = struct {
    context: *anyopaque,
    tick: TickFn,
};

const Display = struct {
    display_id: u32,
    link: CVDisplayLinkRef,
    /// Main-queue DATA_ADD source. Written once before the link first starts
    /// and never changed, so the CV thread can read it without synchronization.
    source: DispatchSource,
    /// Main thread only.
    running: bool,
    /// Main thread only.
    subscriber_count: u32,
    /// Main thread only. Unordered; removal swaps the last entry in.
    subscribers: [subscriber_count_max]Subscriber,
};

/// Process-lifetime table. Entries are appended and never removed, so a
/// `*Display` handed to CoreVideo and libdispatch stays valid forever.
var displays: [display_count_max]Display = undefined;
var display_count: u32 = 0;

pub const SubscribeError = error{DisplayLinkUnavailable};

/// Subscribe a window to its display's ticks. Main thread only.
///
/// Creates and starts the display's link on first use. Fails only if
/// CoreVideo cannot create a link for `display_id`; the window then simply
/// receives no ticks until a later subscription succeeds.
pub fn subscribe(display_id: u32, subscriber: Subscriber) SubscribeError!void {
    assert(isMainThread());
    assert(display_count <= display_count_max);

    const display = try displayFor(display_id);
    assert(display.subscriber_count < subscriber_count_max);
    assert(!isSubscribed(display, subscriber.context));

    display.subscribers[display.subscriber_count] = subscriber;
    display.subscriber_count += 1;
    if (!display.running) {
        const result = CVDisplayLinkStart(display.link);
        if (result != .success) {
            std.log.err("CVDisplayLinkStart failed for display {d}: {d}", .{
                display_id,
                @backingInt(result),
            });
        }
        display.running = true;
    }
    assert(display.subscriber_count <= subscriber_count_max);
}

/// Remove a window from its display's subscribers. Main thread only.
///
/// Stops the display's link when its last subscriber leaves, so displays with
/// no visible Gooey window cost nothing. Must run before the window is freed.
pub fn unsubscribe(display_id: u32, context: *anyopaque) void {
    assert(isMainThread());
    const display = findDisplay(display_id).?;
    assert(display.subscriber_count > 0);

    var index: u32 = 0;
    while (index < display.subscriber_count) : (index += 1) {
        if (display.subscribers[index].context == context) break;
    } else unreachable; // The caller holds a subscription to this display.

    display.subscriber_count -= 1;
    display.subscribers[index] = display.subscribers[display.subscriber_count];
    assert(!isSubscribed(display, context));

    if (display.subscriber_count == 0) {
        // `CVDisplayLinkStop` waits for an in-flight callback, which only merges
        // into the immortal source, so there is nothing to race. A tick merged
        // before the stop runs the handler once more and finds no subscribers.
        _ = CVDisplayLinkStop(display.link);
        display.running = false;
    }
}

/// The `CGDirectDisplayID` of the screen a window is on, or the main display
/// when the window is off-screen and has no screen.
pub fn displayIdForWindow(ns_window: objc.Object) u32 {
    assert(ns_window.value != null);
    const screen = ns_window.msgSend(objc.Object, "screen", .{});
    if (screen.value == null) return CGMainDisplayID();

    const description = screen.msgSend(objc.Object, "deviceDescription", .{});
    const NSString = objc.getClass("NSString").?;
    const key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{
        @as([*:0]const u8, "NSScreenNumber"),
    });
    const number = description.msgSend(objc.Object, "objectForKey:", .{key.value});
    if (number.value == null) return CGMainDisplayID();
    return number.msgSend(u32, "unsignedIntValue", .{});
}

/// Monotonic nanoseconds on the clock CoreVideo and `NSEvent.timestamp` use.
pub fn nowNs() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw);
}

fn findDisplay(display_id: u32) ?*Display {
    assert(display_count <= display_count_max);
    for (displays[0..display_count]) |*display| {
        if (display.display_id == display_id) return display;
    }
    return null;
}

fn isSubscribed(display: *const Display, context: *anyopaque) bool {
    assert(display.subscriber_count <= subscriber_count_max);
    for (display.subscribers[0..display.subscriber_count]) |subscriber| {
        if (subscriber.context == context) return true;
    }
    return false;
}

/// Find the display's entry, creating its link and source on first use.
fn displayFor(display_id: u32) SubscribeError!*Display {
    if (findDisplay(display_id)) |display| return display;
    if (display_count == display_count_max) {
        std.debug.panic(
            "display link table exhausted: capacity {d} displays, {d} in use, " ++
                "1 requested for display {d}",
            .{ display_count_max, display_count, display_id },
        );
    }

    var link: ?CVDisplayLinkRef = null;
    if (CVDisplayLinkCreateWithCGDisplay(display_id, &link) != .success) {
        std.log.err("CVDisplayLinkCreateWithCGDisplay failed for display {d}", .{display_id});
        return error.DisplayLinkUnavailable;
    }

    const display = &displays[display_count];
    const main_queue: *anyopaque = @ptrCast(&_dispatch_main_q);
    display.* = .{
        .display_id = display_id,
        .link = link.?,
        .source = dispatch_source_create(&_dispatch_source_type_data_add, 0, 0, main_queue).?,
        .running = false,
        .subscriber_count = 0,
        .subscribers = undefined,
    };
    dispatch_set_context(display.source, display);
    dispatch_source_set_event_handler_f(display.source, sourceHandler);
    dispatch_resume(display.source);

    // The callback reads only `display.source`, which is final from here on.
    const set_result = CVDisplayLinkSetOutputCallback(display.link, displayLinkOutput, display);
    assert(set_result == .success);
    display_count += 1;
    return display;
}

/// CoreVideo thread. Merging is lock-free and never blocks.
fn displayLinkOutput(
    _: CVDisplayLinkRef,
    _: *const anyopaque,
    _: *const anyopaque,
    _: u64,
    _: *u64,
    user_info: ?*anyopaque,
) callconv(.c) CVReturn {
    const display: *const Display = @ptrCast(@alignCast(user_info.?));
    dispatch_source_merge_data(display.source, 1);
    return .success;
}

/// Main queue, at most once per run of coalesced ticks. Walks the live list:
/// a tick may unsubscribe a window (its own or, via app code, another one).
/// Swap-removal can then skip one window for this tick, which is harmless,
/// and can never visit a removed window.
fn sourceHandler(context: ?*anyopaque) callconv(.c) void {
    assert(isMainThread());
    const display: *Display = @ptrCast(@alignCast(context.?));
    const now_ns = nowNs();

    var index: u32 = 0;
    while (index < display.subscriber_count) : (index += 1) {
        assert(display.subscriber_count <= subscriber_count_max);
        const subscriber = display.subscribers[index];
        subscriber.tick(subscriber.context, now_ns);
    }
}

pub fn isMainThread() bool {
    return pthread_main_np() != 0;
}

// =============================================================================
// CoreVideo, libdispatch, and libc
// =============================================================================

const CVDisplayLinkRef = *opaque {};
const DispatchSource = *opaque {};

const CVReturn = enum(i32) { success = 0, _ };

const CVOutputCallback = *const fn (
    CVDisplayLinkRef,
    *const anyopaque,
    *const anyopaque,
    u64,
    *u64,
    ?*anyopaque,
) callconv(.c) CVReturn;

extern "c" fn CVDisplayLinkCreateWithCGDisplay(display_id: u32, out: *?CVDisplayLinkRef) CVReturn;
extern "c" fn CVDisplayLinkSetOutputCallback(
    link: CVDisplayLinkRef,
    callback: CVOutputCallback,
    user_info: ?*anyopaque,
) CVReturn;
extern "c" fn CVDisplayLinkStart(link: CVDisplayLinkRef) CVReturn;
extern "c" fn CVDisplayLinkStop(link: CVDisplayLinkRef) CVReturn;
extern "c" fn CGMainDisplayID() u32;

extern "c" var _dispatch_main_q: u8;
extern "c" const _dispatch_source_type_data_add: u8;
extern "c" fn dispatch_source_create(
    source_type: *const anyopaque,
    handle: usize,
    mask: usize,
    queue: *anyopaque,
) ?DispatchSource;
extern "c" fn dispatch_set_context(object: DispatchSource, context: ?*anyopaque) void;
extern "c" fn dispatch_source_set_event_handler_f(
    source: DispatchSource,
    handler: *const fn (?*anyopaque) callconv(.c) void,
) void;
extern "c" fn dispatch_resume(object: DispatchSource) void;
extern "c" fn dispatch_source_merge_data(source: DispatchSource, value: usize) void;

const clock_uptime_raw: u32 = 8;
extern "c" fn clock_gettime_nsec_np(clock_id: u32) u64;
extern "c" fn pthread_main_np() c_int;
