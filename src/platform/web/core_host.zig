//! Runs a 0.4.0 core app in the browser (contract decision 9).
//!
//! The browser gives the app one thread, so each `requestAnimationFrame`
//! callback runs both sides of the tick in sequence: forward input from the
//! JavaScript rings into the core's queue, then `core/tick.tick` drains,
//! builds, lays out, emits, packs, draws, and swaps. The `built` and
//! `presented` frames still swap at the end of a frame, so the core code is
//! the same as on the native hosts; only this host has no render thread.
//!
//! JavaScript calls three exports, generated per app by `Exports`: `init`
//! once the WebGPU device exists, `frame` from each animation frame, and
//! `resize`, which is a no-op because `frame` polls the canvas size.
//!
//! Resource sketch: everything is reserved in `init` from the app's guard,
//! the renderer and platform window included; the guard panics on any later
//! allocation. Per frame at most `forward_count_max` (82) ring entries are
//! read and at most the queue's free slots are pushed: a burst larger than
//! the queue stays in its ring for the next frame, which bounds both storage
//! and latency. The core then does at most one tick of bounded work.

const std = @import("std");
const imports = @import("imports.zig");
const clipboard = @import("clipboard.zig");
const io_mod = @import("io.zig");
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const renderer_mod = @import("renderer.zig");
const key_events = @import("key_events.zig");
const mouse_events = @import("mouse_events.zig");
const scroll_events = @import("scroll_events.zig");
const text_buffer = @import("text_buffer.zig");
const composition_buffer = @import("composition_buffer.zig");
const scene_mod = @import("../../scene/mod.zig");
const core_window = @import("../../core/window.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const records = @import("../../core/records.zig");
const ResourceLimits = @import("../../core/limits.zig").ResourceLimits;

const assert = std.debug.assert;

const WebPlatform = platform_mod.WebPlatform;
const WebWindow = window_mod.WebWindow;
const WebRenderer = renderer_mod.WebRenderer;

/// Every ring entry one frame can find: keys, one text chunk, one
/// composition update, scrolls, and mouse events.
const forward_count_max: u32 = key_events.RING_SIZE + 1 + 1 + scroll_events.RING_SIZE +
    mouse_events.RING_SIZE;

comptime {
    assert(forward_count_max == 82);
    // Text and composition bytes always fit the smallest event text budget.
    assert(text_buffer.BUFFER_SIZE + composition_buffer.BUFFER_SIZE <= 4 * 1024);
}

/// The browser exports for one app type. `gooey.App` references this on
/// WASM, which analyzes the `@export` block below.
pub fn Exports(comptime App: type) type {
    return struct {
        var app: ?*App = null;
        var host: ?*Host = null;

        fn init() callconv(.c) void {
            initApp() catch |err| imports.err("gooey init failed: {}", .{err});
        }

        /// In place and `noinline`: `App` and the renderer are far larger
        /// than the WASM stack can hold as temporaries (CLAUDE.md §14).
        noinline fn initApp() !void {
            assert(app == null);
            const backing = std.heap.wasm_allocator;
            const self = try backing.create(App);
            self.beginInit(backing);
            const gpa = self.guard.allocator();
            const created = try gpa.create(Host);
            try created.initInPlace(gpa, &.{
                .title = App.title,
                .width = App.width,
                .height = App.height,
                .limits = App.limits,
            });
            try self.initCore(io_mod.browser, @floatCast(created.window.scale_factor));
            created.bind(&self.window);
            self.finishInit();
            app = self;
            host = created;
            created.platform.run();
        }

        fn frame(timestamp_ms: f64) callconv(.c) void {
            const self = app orelse return;
            const active = host.?;
            const now_ns = active.beginFrame(timestamp_ms);
            self.tick(now_ns);
            active.endFrame();
        }

        fn resize(width: u32, height: u32) callconv(.c) void {
            // `frame` re-reads the canvas size and scale every time.
            _ = width;
            _ = height;
        }

        comptime {
            @export(&init, .{ .name = "init" });
            @export(&frame, .{ .name = "frame" });
            @export(&resize, .{ .name = "resize" });
        }
    };
}

pub const Host = struct {
    platform: WebPlatform,
    window: *WebWindow,
    renderer: *WebRenderer,
    core: *core_window.Window,
    query: core_router.Query,
    /// The core clock: rAF timestamps, never moving backwards.
    now_ns: u64,
    /// The size last pushed as a `resized` event, in logical pixels.
    width: f64,
    height: f64,
    scale_factor: f64,
    /// The caret rect last handed to the browser's hidden input.
    ime_rect: ?records.Rect,

    pub const Options = struct {
        title: []const u8,
        width: u32,
        height: u32,
        limits: ResourceLimits,
    };

    /// Reserve the platform, the canvas window, and the renderer. The host
    /// must stay at this address: the platform registers it and the core's
    /// presenter points at it.
    pub fn initInPlace(self: *Host, gpa: std.mem.Allocator, options: *const Options) !void {
        assert(options.width > 0);
        assert(options.height > 0);
        try self.platform.initInPlace(gpa);
        self.window = try WebWindow.init(gpa, &self.platform, &.{
            .title = options.title,
            .width = @floatFromInt(options.width),
            .height = @floatFromInt(options.height),
            .limits = options.limits,
        });
        self.renderer = try gpa.create(WebRenderer);
        self.renderer.initInPlace(gpa);
        self.now_ns = 0;
        self.width = self.window.size.width;
        self.height = self.window.size.height;
        self.scale_factor = self.window.scale_factor;
        self.ime_rect = null;
        assert(self.scale_factor > 0);
    }

    /// Bind the core window: atlases, the presenter, and the IME query. The
    /// core starts at the canvas's real size, so no resize is pending.
    pub fn bind(self: *Host, core: *core_window.Window) void {
        assert(core.presenter == null);
        self.core = core;
        self.query = .{ .window = core };
        const resources = core.resources;
        const key = @intFromPtr(self.window);
        resources.registerAtlasConsumer(key);
        core.atlas_consumer_key = key;
        self.renderer.initAtlases(.{
            .uploads = resources.atlas_uploads,
            .key = key,
            .text_size = core.limits.atlas.text_size,
            .svg_size = core.limits.atlas.svg_size,
            .image_size = core.limits.atlas.image_size,
        });
        core.width = @floatCast(self.width);
        core.height = @floatCast(self.height);
        core.presenter = .{ .context = self, .draw = draw };
        core.bindScreenReader(null, null);
        // Paste arrives as text input from the browser's paste event, as in
        // 0.3.1, so the service only writes.
        core.clipboard.service = .{
            .context = self,
            .read = clipboardRead,
            .write = clipboardWrite,
        };
        assert(core.file_dialog == null); // Web dialogs complete asynchronously.
    }

    /// Before the tick: advance the clock, then queue a resize and the input
    /// the rings hold, as far as the queue has room.
    pub fn beginFrame(self: *Host, timestamp_ms: f64) u64 {
        assert(self.core.phase == .idle);
        const timestamp_ns = @max(0, timestamp_ms) * std.time.ns_per_ms;
        self.now_ns = @max(self.now_ns, @as(u64, @intFromFloat(timestamp_ns)));
        self.queueResize();
        self.forwardInput();
        return self.now_ns;
    }

    /// After the tick: place the browser's IME candidate window from the
    /// rendered frame, then schedule the next animation frame.
    pub fn endFrame(self: *Host) void {
        assert(self.core.phase == .idle);
        // Answered synchronously from the rendered frame; the browser needs
        // the rect before composition starts, so it moves with the caret.
        const rect = self.query.imeCursorRect();
        if (!std.meta.eql(rect, self.ime_rect)) {
            self.ime_rect = rect;
            if (rect) |caret| {
                self.window.setImeCursorRect(caret.x, caret.y, caret.width, caret.height);
            }
        }
        if (self.core.quit_requested) self.platform.quit();
        if (self.platform.isRunning()) imports.requestAnimationFrame();
    }

    /// Size the drawing buffer before the tick builds, so the frame built
    /// for a new size is the one presented. Resizing clears the canvas, so a
    /// changed buffer queues a render even when the logical size is unchanged
    /// (a ratio change). Polled every frame: the browser has no resize event
    /// that arrives before the next animation frame.
    fn queueResize(self: *Host) void {
        if (!hasRoom(&self.core.queue)) return; // Next frame polls again.
        const buffer_resized = imports.syncCanvasSize();
        self.window.updateSize();
        const size = self.window.size;
        const scale = self.window.scale_factor;
        const same_size = size.width == self.width and size.height == self.height;
        if (same_size and scale == self.scale_factor and !buffer_resized) return;
        self.width = size.width;
        self.height = size.height;
        self.scale_factor = scale;
        self.core.queue.push(.{ .window = .{ .resized = .{
            .width = @floatCast(size.width),
            .height = @floatCast(size.height),
            .scale_factor = @floatCast(scale),
        } } });
    }

    /// Keys, text, composition, scrolls, then the mouse: 0.3.1's order.
    fn forwardInput(self: *Host) void {
        const queue = &self.core.queue;
        forwardRing(queue, &key_events.g_key_ring, key_events.toInputEvent);
        if (hasRoom(queue)) {
            const buffer: *volatile text_buffer.TextInputBuffer = &text_buffer.g_text_buffer;
            if (buffer.hasText()) {
                queue.push(.{ .input = .{ .text_input = .{ .text = buffer.getText() } } });
                buffer.clear();
            }
        }
        if (hasRoom(queue)) {
            const buffer: *volatile composition_buffer.CompositionBuffer =
                &composition_buffer.g_composition_buffer;
            if (buffer.hasPending()) {
                queue.push(.{ .input = .{ .composition = .{ .text = buffer.getText() } } });
                buffer.pending = 0;
            }
        }
        forwardRing(queue, &scroll_events.g_scroll_ring, scroll_events.toInputEvent);
        forwardRing(queue, &mouse_events.g_mouse_ring, mouse_events.toInputEvent);
    }
};

/// Move ring entries into the queue while it has room; the rest wait.
fn forwardRing(queue: *core_events.EventQueue, ring: anytype, comptime convert: anytype) void {
    const Ring = @typeInfo(@TypeOf(ring)).pointer.child;
    const volatile_ring: *volatile Ring = ring;
    var forwarded: u32 = 0;
    while (forwarded < forward_count_max) : (forwarded += 1) {
        if (!hasRoom(queue)) return;
        const raw = volatile_ring.pop() orelse return;
        queue.push(.{ .input = convert(raw) });
    }
}

fn hasRoom(queue: *const core_events.EventQueue) bool {
    assert(queue.count <= queue.events.len);
    return queue.count < queue.events.len;
}

/// The core's presenter, inside `tick` on the browser's one thread: upload
/// what the build placed in the atlases, then draw the packed scene.
fn draw(
    context: *anyopaque,
    scene: *const scene_mod.Scene,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.viewport_width >= 0);
    assert(frame.viewport_height >= 0);
    host.renderer.uploadAtlasRegions();
    host.renderer.render(
        scene,
        frame.viewport_width,
        frame.viewport_height,
        clear.r,
        clear.g,
        clear.b,
        clear.a,
    );
}

fn clipboardRead(_: *anyopaque, out: []u8) u32 {
    assert(out.len > 0);
    return 0;
}

fn clipboardWrite(_: *anyopaque, text: []const u8) void {
    assert(text.len > 0);
    _ = clipboard.setText(text);
}
