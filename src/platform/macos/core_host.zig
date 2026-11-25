const std = @import("std");
const objc = @import("objc");
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const interface = @import("../interface.zig");
const file_dialog = @import("file_dialog.zig");
const clipboard = @import("clipboard.zig");
const appkit = @import("appkit.zig");
const core_window = @import("../../core/window.zig");
const core_backend = @import("../../core/backend.zig");
const core_element = @import("../../core/element.zig");
const core_tick = @import("../../core/tick.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const core_handler = @import("../../core/handler.zig");
const records = @import("../../core/records.zig");
const frame_trace = @import("../../core/frame_trace.zig");

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
extern "c" var _dispatch_main_q: u8;
extern "c" var NSRunLoopCommonModes: objc.c.id;
extern "c" fn CACurrentMediaTime() f64;

const CAFrameRateRange = extern struct { minimum: f32, maximum: f32, preferred: f32 };

const presented_ring_count: u32 = 4;

const qos_class_user_interactive: c_uint = 0x21;

var active_host: std.atomic.Value(?*Host) = .init(null);

pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    app.beginInit(backing);
    const gpa = app.guard.allocator();

    const platform = try gpa.create(MacPlatform);
    defer gpa.destroy(platform);
    try platform.initInPlace();
    defer platform.deinit();

    const window = try PlatformWindow.init(gpa, platform, &.{
        .title = App.title,
        .width = @floatFromInt(App.width),
        .height = @floatFromInt(App.height),
        .background_color = App.theme.bg,
        .min_size = interface.minSize(App.min_width, App.min_height),
        .title_bar = App.title_bar,
        .limits = App.limits_reserved,
        .shaders = App.shaders,
    });
    defer window.deinit();
    try platform.installMainMenu(window.ns_window, std.fmt.comptimePrint("Quit {s}", .{App.title}));

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
    render_loop: std.atomic.Value(?CFRunLoopRef),
    tick_scheduled: std.atomic.Value(bool),
    render_deadline_ns: std.atomic.Value(u64),
    stopping: std.atomic.Value(bool),
    viewport_clamp_logged: bool,
    cursor: core_element.CursorShape,
    theme: ?*const core_element.Theme,
    ime_rect: ?records.Rect,
    ime_owner: ?core_window.ElementId,
    built_frame_number: u64,
    built_marked_length_utf16: c_ulong,
    presented: if (frame_trace.enabled) PresentedRing else void,

    pub const Options = struct {
        platform: *MacPlatform,
        window: *PlatformWindow,
        core: *core_window.Window,
        app: *anyopaque,
        tick_main: *const fn (app: *anyopaque, now_ns: u64) void,
        io: std.Io,
    };

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
        self.render_deadline_ns = .init(core_window.deadline_none);
        self.stopping = .init(false);
        self.viewport_clamp_logged = false;
        self.cursor = .default;
        self.theme = null;
        applyAppearance(self);
        self.ime_rect = null;
        self.ime_owner = null;
        self.built_frame_number = 0;
        self.built_marked_length_utf16 = 0;
        if (frame_trace.enabled) self.presented = .{};
        self.bindWindow();
        errdefer self.unbindWindow();
        self.link = try createLink(self.window);
        errdefer self.link.release();
        active_host.store(self, .release);
        errdefer active_host.store(null, .release);
        self.thread = try std.Thread.spawn(.{}, renderThreadMain, .{self});
        while (self.render_loop.load(.acquire) == null) std.atomic.spinLoopHint();
        assert(self.thread != null);
    }

    fn bindWindow(self: *Host) void {
        const resources = self.core.resources;
        const key = @intFromPtr(self.window);
        resources.registerAtlasConsumer(key);
        self.core.atlas_consumer_key = key;
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
        self.core.bindWake(.{ .context = self, .wake = scheduleTickErased });
        self.core.clipboard.service = .{
            .context = self,
            .read = clipboardRead,
            .write = clipboardWrite,
        };
        self.core.bindScreenReader(self.window.ns_window, self.window.ns_view);
        self.core.bindViewport(.{
            .width = @floatCast(self.window.size.width),
            .height = @floatCast(self.window.size.height),
            .scale_factor = @floatCast(self.window.scale_factor),
        });
        assert(self.window.core != null);
    }

    pub fn deinit(self: *Host) void {
        assert(self.core.presenter.?.context == @as(*anyopaque, self));
        self.stop();
        self.unbindWindow();
    }

    fn unbindWindow(self: *Host) void {
        assert(self.thread == null);
        assert(self.core.atlas_consumer_key == @intFromPtr(self.window));
        self.core.resources.unregisterAtlasConsumer(self.core.atlas_consumer_key);
        self.core.presenter = null;
        self.core.file_dialog = null;
        self.core.bindWake(null);
        self.core.clipboard.service = null;
        self.core.unbindScreenReader();
    }

    pub fn stop(self: *Host) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        const thread = self.thread orelse return;
        CFRunLoopStop(self.render_loop.load(.acquire).?);
        thread.join();
        self.thread = null;
        if (frame_trace.enabled) self.presented.releaseAll();
        self.link.release();
        active_host.store(null, .release);
        assert(self.thread == null);
    }

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

fn mainTick(context: ?*anyopaque) callconv(.c) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    host.tick_scheduled.store(false, .release);
    if (host.stopping.load(.acquire)) return;
    if (host.core.phase != .idle) return;
    host.tick_main(host.app, host.nowNs());
    applyCursor(host);
    applyAppearance(host);
    syncIme(host);
    host.render_deadline_ns.store(host.core.render_deadline_ns, .release);
    if (host.core.quit_requested) {
        host.stop();
        host.platform.quit();
        return;
    }
    const in_flight = host.core.frame_in_flight.load(.acquire);
    const pending = host.core.render_requested or host.core.queue.count > 0;
    if (pending and !in_flight) host.scheduleTick();
}

fn syncIme(host: *Host) void {
    assert(host.core.phase == .idle);
    if (host.core.rendered().frame_number == host.built_frame_number) {
        host.window.rendered_marked_length_utf16 = host.built_marked_length_utf16;
    }
    if (host.core.frame_number != host.built_frame_number) {
        host.built_frame_number = host.core.frame_number;
        host.built_marked_length_utf16 = host.window.marked_length_utf16;
    }
    endStaleComposition(host);
    const rect = host.query.imeCursorRect();
    if (std.meta.eql(rect, host.ime_rect)) return;
    host.ime_rect = rect;
    const context = host.window.ns_view.msgSend(objc.c.id, "inputContext", .{});
    if (context == null) return;
    objc.Object.fromId(context).msgSend(void, "invalidateCharacterCoordinates", .{});
}

fn endStaleComposition(host: *Host) void {
    const owner = host.query.imeOwner();
    if (std.meta.eql(owner, host.ime_owner)) return;
    host.ime_owner = owner;
    if (!host.window.hasMarkedText()) return;
    host.window.clearMarkedText();
    assert(!host.window.hasMarkedText());
    const context = host.window.ns_view.msgSend(objc.c.id, "inputContext", .{});
    if (context == null) return;
    objc.Object.fromId(context).msgSend(void, "discardMarkedText", .{});
}

fn applyCursor(host: *Host) void {
    assert(host.core.phase == .idle);
    if (host.core.cursor == host.cursor) return;
    host.window.setCursorShape(host.core.cursor);
    host.cursor = host.core.cursor;
    assert(host.cursor == host.core.cursor);
}

fn applyAppearance(host: *Host) void {
    assert(host.core.phase == .idle);
    if (host.theme == host.core.theme) return;
    host.window.setAppearance(host.core.theme.isDark());
    host.theme = host.core.theme;
    assert(host.theme.? == host.core.theme);
}

fn onClose(window: *PlatformWindow) bool {
    const host = active_host.load(.acquire) orelse return true;
    assert(host.window == window);
    host.stop();
    host.platform.postWakeEvent();
    return true;
}

fn onLoopTurn(platform: *MacPlatform) void {
    const host = active_host.load(.acquire);
    if (host != null) return;
    if (platform.isRunning()) platform.quit();
}

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
    const target = target_class.msgSend(objc.Object, "new", .{});
    const link = window.ns_view.msgSend(objc.Object, "displayLinkWithTarget:selector:", .{
        target.value,
        objc.sel("tick:").value,
    });
    target.release();
    if (link.value == null) return error.DisplayLinkCreationFailed;
    link.msgSend(void, "setPreferredFrameRateRange:", .{CAFrameRateRange{
        .minimum = 60,
        .maximum = 120,
        .preferred = 120,
    }});
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
    CFRunLoopRun();
    host.link.msgSend(void, "invalidate", .{});
    assert(host.stopping.load(.acquire));
}

fn displayLinkTick(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const host = active_host.load(.acquire) orelse return;
    if (host.stopping.load(.acquire)) return;
    if (!host.core.frame_in_flight.load(.acquire)) {
        const deadline = host.render_deadline_ns.load(.acquire);
        if (deadline == core_window.deadline_none) return;
        if (host.nowNs() >= deadline) host.scheduleTick();
        return;
    }
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    core_tick.presentBuilt(host.core);
    host.scheduleTick();
}

const PresentedRing = struct {
    frame_numbers: [presented_ring_count]u64 = @splat(0),
    drawables: [presented_ring_count]?objc.Object = @splat(null),
    next: u32 = 0,

    fn push(
        self: *PresentedRing,
        trace: *frame_trace.State,
        frame_number: u64,
        drawable: ?objc.Object,
    ) void {
        assert(frame_number > 0);
        assert(self.next < presented_ring_count);
        const slot = self.next;
        self.report(trace, slot);
        self.frame_numbers[slot] = frame_number;
        self.drawables[slot] = drawable;
        if (drawable) |kept| _ = kept.msgSend(objc.Object, "retain", .{});
        self.next = (slot + 1) % presented_ring_count;
    }

    fn report(self: *PresentedRing, trace: *frame_trace.State, slot: u32) void {
        const frame_number = self.frame_numbers[slot];
        if (frame_number == 0) return;
        const drawable = self.drawables[slot] orelse {
            frame_trace.notePresented(trace, frame_number, frame_trace.present_dropped);
            return;
        };
        defer drawable.release();
        self.drawables[slot] = null;
        const presented_s = drawable.msgSend(f64, "presentedTime", .{});
        if (presented_s <= 0) {
            frame_trace.notePresented(trace, frame_number, frame_trace.present_dropped);
            return;
        }
        const now_ns = frame_trace.stamp(trace);
        const age_s = @max(CACurrentMediaTime() - presented_s, 0);
        const age_ns: u64 = @intFromFloat(age_s * std.time.ns_per_s);
        assert(age_ns < now_ns);
        frame_trace.notePresented(trace, frame_number, @max(now_ns - age_ns, 2));
    }

    fn releaseAll(self: *PresentedRing) void {
        for (&self.drawables) |*drawable| {
            if (drawable.*) |kept| kept.release();
            drawable.* = null;
        }
    }
};

fn draw(
    context: *anyopaque,
    packed_frame: *const core_window.PackedFrame,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.scale_factor > 0);
    assert(host.core.atlas_consumer_key == @intFromPtr(host.window));
    const renderer = &host.window.renderer;
    const viewport = window_mod.framebufferViewport(.{
        .width = frame.viewport_width,
        .height = frame.viewport_height,
        .scale_factor = frame.scale_factor,
    }, &renderer.limits.window);
    if (viewport.scale_factor < frame.scale_factor and !host.viewport_clamp_logged) {
        host.viewport_clamp_logged = true;
        std.log.warn("core frame {d}: the window exceeds ResourceLimits.window's " ++
            "framebuffer despite its content size cap (full screen?); drawing at scale " ++
            "{d:.2} instead of {d:.2}.", .{
            frame.frame_number,
            viewport.scale_factor,
            frame.scale_factor,
        });
    }
    const size_px = viewport.size_px;
    if (size_px.width != renderer.size_px.width or size_px.height != renderer.size_px.height) {
        renderer.resize(size_px);
    }
    core_backend.checkCapabilities(renderer.capabilities(), packed_frame);
    const uploads = host.core.resources.atlas_uploads;
    core_backend.uploadPendingAtlases(renderer, uploads, host.core.atlas_consumer_key);
    renderer.draw(packed_frame, viewport, clear);
    if (frame_trace.enabled) {
        host.presented.push(&host.core.trace, frame.frame_number, renderer.last_drawable);
    }
}

fn openDialog(
    context: *anyopaque,
    scratch: std.mem.Allocator,
    request_id: u32,
    request: core_handler.FileDialogRequest,
) ?Outcome {
    const host: *Host = @ptrCast(@alignCast(context));
    _ = request_id;
    assert(host.core.phase == .drain);
    defer host.window.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{
        @as(?*anyopaque, null),
    });
    const paths = switch (request.kind) {
        .open => |options| paths: {
            const prompt = file_dialog.promptForPaths(scratch, options);
            const result = (prompt catch |err| return .{ .failed = err }) orelse return .cancelled;
            assert(result.paths.len > 0);
            if (!options.multiple) assert(result.paths.len == 1);
            break :paths core_events.Paths.join(scratch, result.paths);
        },
        .save => |options| paths: {
            const prompt = file_dialog.promptForNewPath(scratch, options);
            const path = (prompt catch |err| return .{ .failed = err }) orelse return .cancelled;
            break :paths core_events.Paths.join(scratch, &.{path});
        },
    };
    const joined = paths catch return .{ .failed = file_dialog.scratchFull() };
    return .{ .file_selected = joined };
}

fn clipboardRead(_: *anyopaque, out: []u8) u32 {
    return clipboard.readText(out);
}

fn clipboardWrite(_: *anyopaque, text: []const u8) void {
    if (!clipboard.setText(text)) std.log.warn("core host: clipboard write failed", .{});
}
