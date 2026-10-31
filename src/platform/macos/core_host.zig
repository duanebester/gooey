//! Runs a 0.4.0 core app in a macOS window (milestone 1).
//!
//! Two threads, one owner each (contract rule 1, approved decision 5):
//! - The main thread runs AppKit. The window pushes input into the core's
//!   queue and schedules a tick. The tick (drain, build, layout, emit) runs as
//!   a main-queue work item, so it never nests inside an AppKit callback and a
//!   handler's file dialog opens on the main thread between handlers.
//! - The render thread runs a `CADisplayLink` on its own run loop. At each
//!   refresh with a frame in flight it packs and draws that frame, then
//!   schedules a main tick, which makes the frame `rendered` and builds the
//!   next one if a render is pending.
//!
//! They meet only at `frame_in_flight` (see `core/tick.zig`), so no render
//! mutex is taken. The link is created from the window's view on the main
//! thread and added to the render thread's run loop by the render thread
//! itself, because `NSRunLoop` is not thread-safe. The render thread
//! invalidates it before it exits, and `stop` joins the thread before the
//! window is freed.
//!
//! Resource sketch: one thread whose stack the OS maps at init, one link, at
//! most one main-queue work item outstanding (`tick_scheduled`), and one frame
//! in flight. Per refresh the render thread does at most one pack and one
//! draw, and the main thread at most one tick. Every allocation happens
//! before `finishInit`; the core's lifecycle guard panics on any later one,
//! including any from the Metal renderer, which shares the guard.

const std = @import("std");
const objc = @import("objc");
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const file_dialog = @import("file_dialog.zig");
const appkit = @import("appkit.zig");
const geometry = @import("../../geometry/geometry.zig");
const scene_mod = @import("../../scene/mod.zig");
const core_window = @import("../../core/window.zig");
const core_tick = @import("../../core/tick.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const core_handler = @import("../../core/handler.zig");
const records = @import("../../core/records.zig");

const assert = std.debug.assert;

const MacPlatform = platform_mod.MacPlatform;
const PlatformWindow = window_mod.Window;
const Outcome = core_events.Completion.Outcome;

const CFRunLoopRef = *opaque {};
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopRun() void;
extern "c" fn CFRunLoopStop(loop: CFRunLoopRef) void;
extern "c" fn pthread_set_qos_class_self_np(qos: c_uint, relative_priority: c_int) c_int;
extern "c" fn dispatch_async_f(
    queue: *anyopaque,
    context: ?*anyopaque,
    work: *const fn (context: ?*anyopaque) callconv(.c) void,
) void;
/// `dispatch_get_main_queue()` is a macro over this symbol; only its address
/// is used.
extern "c" var _dispatch_main_q: u8;
extern "c" var NSRunLoopCommonModes: objc.c.id;

const CAFrameRateRange = extern struct { minimum: f32, maximum: f32, preferred: f32 };

/// `QOS_CLASS_USER_INTERACTIVE`, the main thread's class.
const qos_class_user_interactive: c_uint = 0x21;

/// The process's one host. The display link's target class has no instance
/// storage, so its callback finds the host here. Milestone 1 runs one window
/// per process; multi-window apps arrive with `WindowLimits` in phase 4.
var active_host: std.atomic.Value(?*Host) = .init(null);

/// Run `App` until the process quits. Everything is reserved before
/// `finishInit`; the core's guard owns every allocation, the platform's too.
pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    app.beginInit(backing);
    const gpa = app.guard.allocator();

    const platform = try gpa.create(MacPlatform);
    defer gpa.destroy(platform);
    try platform.initInPlace(gpa);
    defer platform.deinit();

    const window = try PlatformWindow.init(gpa, platform, &.{
        .title = App.title,
        .width = @floatFromInt(App.width),
        .height = @floatFromInt(App.height),
        .background_color = App.theme.bg,
        .use_display_link = false,
        .limits = App.limits,
    });
    defer window.deinit();

    try app.initCore(io, @floatCast(window.scale_factor));
    defer app.deinit();

    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    try host.initInPlace(.{
        .platform = platform,
        .window = window,
        .core = &app.window,
        .app = app,
        .tick_main = App.tickMainErased,
        .io = io,
    });
    defer host.deinit();

    app.finishInit();
    // Deferred last, so it runs first: the guard leaves `running` before the
    // deferred teardown above frees the host, the window, and the platform.
    defer app.stop();
    assert(app.guard.lifecycle == .running);
    host.scheduleTick();
    platform.run();
}

pub const Host = struct {
    platform: *MacPlatform,
    window: *PlatformWindow,
    core: *core_window.Window,
    app: *anyopaque,
    tick_main: *const fn (app: *anyopaque, now_ns: u64) void,
    io: std.Io,
    start: std.Io.Timestamp,
    query: core_router.Query,
    link: objc.Object,
    thread: ?std.Thread,
    /// Published by the render thread once the link is on its run loop.
    render_loop: std.atomic.Value(?CFRunLoopRef),
    /// A main-queue tick is queued and has not started.
    tick_scheduled: std.atomic.Value(bool),
    stopping: std.atomic.Value(bool),
    /// Renderer errors are logged once; later frames clear and retry.
    render_error_logged: bool,

    pub const Options = struct {
        platform: *MacPlatform,
        window: *PlatformWindow,
        core: *core_window.Window,
        app: *anyopaque,
        tick_main: *const fn (app: *anyopaque, now_ns: u64) void,
        io: std.Io,
    };

    /// Bind the window, the presenter, and the dialog service, then start
    /// the render thread. The host must stay at this address.
    pub fn initInPlace(self: *Host, options: Options) !void {
        assert(active_host.load(.acquire) == null);
        assert(options.core.presenter == null);
        self.platform = options.platform;
        self.window = options.window;
        self.core = options.core;
        self.app = options.app;
        self.tick_main = options.tick_main;
        self.io = options.io;
        self.start = std.Io.Timestamp.now(options.io, .awake);
        self.query = .{ .window = options.core };
        self.thread = null;
        self.render_loop = .init(null);
        self.tick_scheduled = .init(false);
        self.stopping = .init(false);
        self.render_error_logged = false;
        self.bindWindow();
        errdefer self.unbindWindow();
        self.link = try createLink(self.window);
        errdefer self.link.release();
        active_host.store(self, .release);
        errdefer active_host.store(null, .release);
        self.thread = try std.Thread.spawn(.{}, renderThreadMain, .{self});
        // The first tick must not race the link onto its run loop.
        while (self.render_loop.load(.acquire) == null) std.atomic.spinLoopHint();
        assert(self.thread != null);
    }

    fn bindWindow(self: *Host) void {
        const resources = self.core.resources;
        const key = @intFromPtr(self.window);
        resources.registerAtlasConsumer(key);
        self.core.atlas_consumer_key = key;
        self.window.setTextAtlas(resources.text_system.getAtlas());
        self.window.setSvgAtlas(resources.svg_atlas.getAtlas());
        self.window.setImageAtlas(resources.image_atlas.getAtlas());
        self.window.bindCore(.{
            .queue = &self.core.queue,
            .query = &self.query,
            .context = self,
            .schedule_tick = scheduleTickErased,
        });
        self.window.setCloseCallback(onClose);
        self.platform.setLoopTurnCallback(onLoopTurn);
        self.core.presenter = .{ .context = self, .draw = draw };
        self.core.file_dialog = .{ .context = self, .open = openDialog };
        assert(self.window.core != null);
    }

    /// Stop the render thread, then undo `bindWindow`. Runs once, from
    /// `run`'s teardown; a titlebar close only stops the thread.
    pub fn deinit(self: *Host) void {
        self.stop();
        self.unbindWindow();
    }

    /// Undo `bindWindow` once the render thread, the atlas consumer, has
    /// stopped: the shared upload journal requires every consumer to leave
    /// before it is freed.
    fn unbindWindow(self: *Host) void {
        assert(self.thread == null);
        assert(self.core.atlas_consumer_key == @intFromPtr(self.window));
        self.core.resources.unregisterAtlasConsumer(self.core.atlas_consumer_key);
        self.core.presenter = null;
        self.core.file_dialog = null;
    }

    /// Stop the render thread and wait for it: the link is invalidated on
    /// its own thread and no draw can start afterwards. Idempotent.
    pub fn stop(self: *Host) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        const thread = self.thread orelse return;
        CFRunLoopStop(self.render_loop.load(.acquire).?);
        thread.join();
        self.thread = null;
        self.link.release();
        active_host.store(null, .release);
        assert(self.thread == null);
    }

    /// Queue one main-thread tick unless one is already queued. Any thread.
    pub fn scheduleTick(self: *Host) void {
        if (self.tick_scheduled.swap(true, .acq_rel)) return;
        dispatch_async_f(@ptrCast(&_dispatch_main_q), self, mainTick);
    }

    fn scheduleTickErased(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.scheduleTick();
    }

    fn nowNs(self: *const Host) u64 {
        const elapsed = self.start.durationTo(std.Io.Timestamp.now(self.io, .awake));
        const ns = elapsed.toNanoseconds();
        assert(ns >= 0);
        return @intCast(ns);
    }
};

/// The main-queue work item: one main-side tick.
fn mainTick(context: ?*anyopaque) callconv(.c) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    host.tick_scheduled.store(false, .release);
    if (host.stopping.load(.acquire)) return;
    // AppKit services the main queue inside a modal panel's run loop, so a
    // dialog opened by the drain can bring this item back while that tick is
    // still running. The outer tick reschedules below once it returns.
    if (host.core.phase != .idle) return;
    host.tick_main(host.app, host.nowNs());
    if (host.core.quit_requested) {
        host.stop();
        host.platform.quit();
        return;
    }
    // A render requested while a frame was in flight waits for the render
    // thread, which schedules a tick after it presents. Otherwise pending
    // work (a dialog's completion) needs a tick of its own.
    const in_flight = host.core.frame_in_flight.load(.acquire);
    const pending = host.core.render_requested or host.core.queue.count > 0;
    if (pending and !in_flight) host.scheduleTick();
}

fn onClose(window: *PlatformWindow) bool {
    const host = active_host.load(.acquire) orelse return true;
    assert(host.window == window);
    host.stop();
    postWakeEvent(host.platform);
    return true;
}

/// Wake the event loop so `onLoopTurn` runs even when the close did not
/// arrive as an event (`performClose:` from a script or a menu item): the
/// loop blocks in `nextEventMatchingMask:` and turns only after an event.
fn postWakeEvent(platform: *MacPlatform) void {
    const NSEvent = objc.getClass("NSEvent") orelse return;
    const ns_event_type_application_defined: u64 = 15;
    const event = NSEvent.msgSend(
        objc.Object,
        "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:" ++
            "subtype:data1:data2:",
        .{
            ns_event_type_application_defined,
            appkit.NSPoint{ .x = 0, .y = 0 },
            @as(u64, 0),
            @as(f64, 0),
            @as(i64, 0),
            @as(objc.c.id, null),
            @as(i16, 0),
            @as(i64, 0),
            @as(i64, 0),
        },
    );
    assert(event.value != null);
    platform.app.msgSend(void, "postEvent:atStart:", .{ event.value, true });
}

/// After AppKit has unwound a titlebar close, quit: the app has one window.
fn onLoopTurn(platform: *MacPlatform) void {
    const host = active_host.load(.acquire);
    if (host != null) return;
    if (platform.isRunning()) platform.quit();
}

// =============================================================================
// Render thread
// =============================================================================

/// The display link, created from the view on the main thread. It is not on
/// any run loop yet; the render thread adds it to its own.
fn createLink(window: *PlatformWindow) !objc.Object {
    assert(window.ns_view.value != null);
    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;
    const target_class = objc.getClass("GooeyCoreTickTarget") orelse blk: {
        const class = objc.allocateClassPair(NSObject, "GooeyCoreTickTarget") orelse
            return error.ClassNotFound;
        if (!class.addMethod("tick:", displayLinkTick)) return error.MethodAddFailed;
        objc.registerClassPair(class);
        break :blk class;
    };
    // The link retains its target, so the +1 from `new` is the link's.
    const target = target_class.msgSend(objc.Object, "new", .{});
    // NSView's `displayLinkWithTarget:selector:` needs macOS 14 (decision 5).
    const link = window.ns_view.msgSend(objc.Object, "displayLinkWithTarget:selector:", .{
        target.value,
        objc.sel("tick:").value,
    });
    target.release();
    if (link.value == null) return error.DisplayLinkCreationFailed;
    // The range decision 5 measured: up to 120 Hz on ProMotion panels; the
    // link follows a 60 Hz display at 60.
    link.msgSend(void, "setPreferredFrameRateRange:", .{CAFrameRateRange{
        .minimum = 60,
        .maximum = 120,
        .preferred = 120,
    }});
    // Autoreleased: keep it until `stop`.
    _ = link.msgSend(objc.Object, "retain", .{});
    return link;
}

fn renderThreadMain(host: *Host) void {
    _ = pthread_set_qos_class_self_np(qos_class_user_interactive, 0);
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const NSRunLoop = objc.getClass("NSRunLoop").?;
    const loop = NSRunLoop.msgSend(objc.Object, "currentRunLoop", .{});
    host.link.msgSend(void, "addToRunLoop:forMode:", .{ loop.value, NSRunLoopCommonModes });
    host.render_loop.store(CFRunLoopGetCurrent(), .release);
    // Returns when `stop` calls `CFRunLoopStop`; the link keeps it alive.
    CFRunLoopRun();
    host.link.msgSend(void, "invalidate", .{});
    assert(host.stopping.load(.acquire));
}

/// The link's callback, on the render thread: present the frame in flight,
/// then let the main thread make it `rendered` and build the next.
fn displayLinkTick(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const host = active_host.load(.acquire) orelse return;
    if (host.stopping.load(.acquire)) return;
    if (!host.core.frame_in_flight.load(.acquire)) return;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    core_tick.presentBuilt(host.core);
    host.scheduleTick();
}

/// The core's presenter, on the render thread. The frame carries the
/// viewport it was built for; the drawable follows it before the draw.
fn draw(
    context: *anyopaque,
    scene: *const scene_mod.Scene,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.scale_factor > 0);
    const renderer = &host.window.renderer;
    const width: f64 = frame.viewport_width;
    const height: f64 = frame.viewport_height;
    const scale: f64 = frame.scale_factor;
    const resized = renderer.size.width != width or renderer.size.height != height;
    if (resized or renderer.scale_factor != scale) {
        renderer.resize(geometry.Size(f64).init(width, height), scale);
    }
    renderer.renderScene(scene, clear) catch |err| {
        // A frame the GPU could not take (no drawable, command buffer
        // failure) is an operating error: clear, log once, and draw the next.
        if (!host.render_error_logged) {
            std.log.err("core frame {d} not drawn: {s}", .{ frame.frame_number, @errorName(err) });
            host.render_error_logged = true;
        }
        renderer.clear(clear);
    };
}

// =============================================================================
// File dialogs
// =============================================================================

/// The core's file dialog service, on the main thread after the drain.
/// AppKit's panels report cancel and error alike as no selection, so both
/// arrive as `cancelled` until the panel code reports failures separately.
fn openDialog(
    context: *anyopaque,
    scratch: std.mem.Allocator,
    request: core_handler.FileDialogRequest,
) Outcome {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(host.core.phase == .drain);
    switch (request.kind) {
        .open => {
            const result = file_dialog.promptForPaths(scratch, .{
                .files = true,
                .directories = false,
                .multiple = false,
            }) orelse return .cancelled;
            if (result.paths.len == 0) return .cancelled;
            assert(result.paths.len == 1);
            return .{ .file_selected = result.paths[0] };
        },
        .save => {
            const path = file_dialog.promptForNewPath(scratch, .{}) orelse return .cancelled;
            assert(path.len > 0);
            return .{ .file_selected = path };
        },
    }
}
