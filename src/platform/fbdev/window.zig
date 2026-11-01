//! FbdevWindow - the single full-screen window of the fbdev backend.
//!
//! The window covers the whole panel: `WindowOptions.width` and `height` are
//! ignored, and the size never changes after initialization. Frames are drawn
//! by the CPU renderer into a back buffer reserved at initialization, a
//! software cursor is drawn on top when a pointing device is attached, and the
//! result is copied to the framebuffer by `Framebuffer.present`.
//!
//! Rendering is on demand, like the macOS backend: input, animations, and
//! state changes call `requestRender`, views that change with the clock arm
//! `requestRenderAfter`, and the platform loop presents at most once per
//! `frame_period_ns_min`.
//!
//! ## Memory (CLAUDE.md §2)
//!
//! The panel's size is fixed by the hardware and known before the window
//! opens. `init` checks it against the app's `ResourceLimits.window` and
//! fails when it does not fit, then reserves the panel-sized back buffer and
//! the CPU renderer's raster scratch. Nothing is allocated afterwards.

const std = @import("std");
const interface_mod = @import("../interface.zig");
const geometry = @import("../../geometry/geometry.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const input = @import("../../input/events.zig");
const core_clipboard = @import("../../core/clipboard.zig");
const cpu = @import("../cpu/renderer.zig");
const fbdev_platform = @import("platform.zig");
const FbdevPlatform = fbdev_platform.FbdevPlatform;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowId = interface_mod.WindowId;
const WindowOptions = interface_mod.WindowOptions;

pub const Window = struct {
    allocator: Allocator,
    platform: *FbdevPlatform,
    window_id: WindowId = .invalid,

    /// Logical size; contract-pinned field read directly by shared code.
    size: geometry.Size(f64),
    /// Contract-pinned field read directly by shared code.
    scale_factor: f64,

    /// One frame in the renderer's pixel format, panel-sized.
    back_buffer: []u32,

    background_color: geometry.Color,
    dark_appearance: bool = false,
    cursor_shape: interface_mod.CursorShape = .default,
    /// Draw a cursor: true when a mouse or tablet is attached.
    cursor_visible: bool,

    needs_redraw: bool = true,
    closed: bool = false,

    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_inside: bool = false,

    scene: ?*const scene_mod.Scene = null,
    text_atlas: ?*const text_mod.Atlas = null,
    svg_atlas: ?*const text_mod.Atlas = null,
    image_atlas: ?*const text_mod.Atlas = null,
    renderer: cpu.Renderer,
    /// Primitive counts of the last presented frame.
    last_stats: cpu.RenderStats = .{},
    /// Earliest time, on `platform.nowMilliseconds`, at which the loop
    /// must request a frame. Frame-scoped like the Wayland window's: cleared
    /// before application code builds a frame, which re-arms what it needs.
    render_deadline_ms: ?i64 = null,

    title_buffer: [title_bytes_max]u8 = undefined,
    title_len: usize = 0,

    // IME state. There is no input method without a display server, but the
    // contract's composition bridge still stores what callers hand it.
    marked_text_buffer: [ime_bytes_max]u8 = undefined,
    marked_text_len: usize = 0,
    ime_cursor_rect: geometry.RectF = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 1, .height = 20 },
    },

    on_input: ?InputCallback = null,
    on_render: ?RenderCallback = null,
    on_close: ?CloseCallback = null,
    on_resize: ?ResizeCallback = null,
    on_post_input: ?PostInputCallback = null,
    user_data: ?*anyopaque = null,

    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;
    pub const RenderCallback = *const fn (*Self) void;
    pub const CloseCallback = *const fn (*Self) bool;
    pub const ResizeCallback = *const fn (*Self, f64, f64) void;
    pub const PostInputCallback = *const fn (*Self) void;

    pub const title_bytes_max: usize = 255;
    pub const ime_bytes_max: usize = 256;

    const Self = @This();

    pub fn init(allocator: Allocator, plat: *FbdevPlatform, options: *const WindowOptions) !*Self {
        assert(options.width > 0);
        assert(options.height > 0);
        assert(options.title.len <= title_bytes_max);
        const panel = &plat.framebuffer;

        assert(options.limits.check() == null);
        const window_limits = &options.limits.window;
        if (panel.width > window_limits.framebuffer_width_max or
            panel.height > window_limits.framebuffer_height_max)
        {
            std.log.err(
                "fbdev: the {d}x{d} panel exceeds ResourceLimits.window ({d}x{d})",
                .{
                    panel.width,
                    panel.height,
                    window_limits.framebuffer_width_max,
                    window_limits.framebuffer_height_max,
                },
            );
            return error.PanelExceedsResourceLimits;
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const back_buffer = try allocator.alloc(u32, @as(usize, panel.width) * panel.height);
        errdefer allocator.free(back_buffer);

        self.* = .{
            .allocator = allocator,
            .platform = plat,
            .size = .{ .width = plat.logicalWidth(), .height = plat.logicalHeight() },
            .scale_factor = plat.scale_factor,
            .back_buffer = back_buffer,
            .renderer = undefined,
            .background_color = options.background_color,
            .cursor_visible = plat.devices.hasPointer(),
            .mouse_x = plat.translator.pointer_x,
            .mouse_y = plat.translator.pointer_y,
            .mouse_inside = plat.devices.hasPointer(),
        };
        self.setTitle(options.title);

        try self.renderer.initInPlace(allocator, &options.limits);
        errdefer self.renderer.deinit(allocator);

        self.window_id = try plat.registerWindow(self);
        plat.window = self;
        plat.setActiveWindowId(self.window_id);
        assert(self.window_id.isValid());
        assert(self.back_buffer.len == @as(usize, panel.width) * panel.height);
        return self;
    }

    pub fn deinit(self: *Self) void {
        assert(@intFromPtr(self) != 0);
        if (self.window_id.isValid()) {
            self.platform.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        if (self.platform.window == self) self.platform.window = null;
        self.renderer.deinit(self.allocator);
        self.allocator.free(self.back_buffer);
        assert(self.platform.window != self);
        self.allocator.destroy(self);
    }

    fn frameTarget(self: *Self) cpu.raster.Target {
        const panel = &self.platform.framebuffer;
        assert(self.back_buffer.len == @as(usize, panel.width) * panel.height);
        return .{
            .pixels = self.back_buffer,
            .width = panel.width,
            .height = panel.height,
            .stride = panel.width,
        };
    }

    /// Build, rasterize, and present one frame. Called by the platform loop.
    pub fn renderFrame(self: *Self) void {
        assert(self.needs_redraw);
        assert(!self.closed);
        // Cleared before application code runs so a render requested while
        // building this frame (an animation step) schedules the next one.
        self.needs_redraw = false;
        self.render_deadline_ms = null;
        if (self.on_render) |callback| callback(self);
        if (self.closed) return;

        const target = self.frameTarget();
        if (self.scene) |scene| {
            self.renderer.bindAtlases(.{
                .text = self.text_atlas,
                .svg = self.svg_atlas,
                .image = self.image_atlas,
            });
            self.last_stats = self.renderer.draw(
                target,
                scene,
                .{ .scale_factor = @floatCast(self.scale_factor) },
                self.getClearColor(),
            );
        } else {
            cpu.raster.clear(target, self.getClearColor());
        }
        if (self.cursor_visible) drawCursor(target, self.mouse_x, self.mouse_y, self.scale_factor);
        self.platform.framebuffer.present(target);
    }

    /// Route one translated input event to the application.
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        assert(!self.closed);
        switch (event) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => |mouse| {
                self.mouse_x = mouse.position.x;
                self.mouse_y = mouse.position.y;
            },
            .touch_down, .touch_moved, .touch_up => |touch| {
                self.mouse_x = touch.position.x;
                self.mouse_y = touch.position.y;
            },
            else => {},
        }
        var handled = false;
        if (self.on_input) |callback| handled = callback(self, event);
        if (self.on_post_input) |callback| callback(self);
        self.requestRender();
        return handled;
    }

    // =========================================================================
    // Geometry
    // =========================================================================

    pub fn width(self: *const Self) u32 {
        assert(self.size.width > 0);
        return @intFromFloat(self.size.width);
    }

    pub fn height(self: *const Self) u32 {
        assert(self.size.height > 0);
        return @intFromFloat(self.size.height);
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return self.size;
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        assert(self.scale_factor > 0);
        return self.scale_factor;
    }

    // =========================================================================
    // Properties
    // =========================================================================

    /// Stored only: the panel has no title bar. Kept so the value remains
    /// observable, as on the other backends.
    pub fn setTitle(self: *Self, title: []const u8) void {
        assert(title.len <= title_bytes_max);
        const len = @min(title.len, title_bytes_max);
        @memcpy(self.title_buffer[0..len], title[0..len]);
        self.title_len = len;
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        assert(color.a >= 0);
        assert(color.a <= 1);
        self.background_color = color;
        self.requestRender();
    }

    pub fn setAppearance(self: *Self, dark: bool) void {
        self.dark_appearance = dark;
        assert(self.dark_appearance == dark);
    }

    /// Stored only: the software cursor is always an arrow.
    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        self.cursor_shape = shape;
        assert(self.cursor_shape == shape);
    }

    /// The surface is opaque, so a translucent color is drawn over black.
    pub fn getClearColor(self: *const Self) geometry.Color {
        assert(self.background_color.a >= 0);
        assert(self.background_color.a <= 1);
        return self.background_color;
    }

    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    pub fn getWindowId(self: *const Self) WindowId {
        return self.window_id;
    }

    pub fn getPlatform(self: *Self) *FbdevPlatform {
        assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    // =========================================================================
    // Host control
    // =========================================================================

    pub fn requestRender(self: *Self) void {
        if (self.closed) return;
        self.needs_redraw = true;
    }

    /// Ask for a frame no later than `delay_ms` from now. Only the earliest
    /// deadline is kept; the frame drawn at it re-arms whatever views still
    /// depend on the clock (see `render_deadline_ms`).
    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        assert(delay_ms <= interface_mod.render_delay_ms_max);
        if (self.closed) return;
        if (delay_ms == 0) {
            self.requestRender();
            return;
        }
        const deadline_ms = fbdev_platform.nowMilliseconds() + delay_ms;
        if (self.render_deadline_ms) |armed_ms| {
            if (armed_ms <= deadline_ms) return;
        }
        self.render_deadline_ms = deadline_ms;
        assert(self.render_deadline_ms.? <= deadline_ms);
    }

    /// Request the frame a passed deadline asked for. Called by the platform
    /// loop once per turn.
    pub fn fireRenderDeadline(self: *Self, now_ms: i64) void {
        assert(now_ms >= 0);
        const deadline_ms = self.render_deadline_ms orelse return;
        if (now_ms < deadline_ms) return;
        self.render_deadline_ms = null;
        self.requestRender();
        if (!self.closed) assert(self.needs_redraw);
    }

    /// The only window always has focus.
    pub fn focus(self: *Self) void {
        assert(!self.closed);
        self.requestRender();
    }

    /// Runs the application's veto, then records the close. The owning `App`
    /// reclaims the window from its loop-turn hook, and the platform loop
    /// ends once no open window remains.
    pub fn close(self: *Self) void {
        if (self.closed) return;
        if (self.on_close) |callback| {
            if (!callback(self)) return;
        }
        self.closed = true;
        self.needs_redraw = false;
        self.render_deadline_ms = null;
        assert(self.isClosed());
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    // =========================================================================
    // Frame handoff
    // =========================================================================

    pub fn setScene(self: *Self, scene: *const scene_mod.Scene) void {
        self.scene = scene;
    }

    pub fn setTextAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        assert(atlas.format == .grayscale);
        self.text_atlas = atlas;
    }

    pub fn setSvgAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        assert(atlas.format == .rgba);
        self.svg_atlas = atlas;
    }

    pub fn setImageAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        assert(atlas.format == .rgba);
        self.image_atlas = atlas;
    }

    // =========================================================================
    // IME bridge
    // =========================================================================

    /// A longer composition is cut at a codepoint boundary, never inside a
    /// UTF-8 sequence.
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        const len = core_clipboard.prefixFitting(text, ime_bytes_max);
        @memcpy(self.marked_text_buffer[0..len], text[0..len]);
        self.marked_text_len = len;
    }

    pub fn clearMarkedText(self: *Self) void {
        self.marked_text_len = 0;
    }

    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text_len > 0;
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        self.ime_cursor_rect = geometry.RectF.init(x, y, w, h);
    }

    // =========================================================================
    // Callbacks
    // =========================================================================

    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        self.on_input = callback;
    }

    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        self.on_render = callback;
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        self.on_close = callback;
    }

    /// Accepted for the contract; the panel never resizes.
    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        self.on_resize = callback;
    }

    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        self.on_post_input = callback;
    }

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        const ptr = self.user_data orelse return null;
        return @ptrCast(@alignCast(ptr));
    }
};

// =============================================================================
// Software cursor
// =============================================================================

/// Arrow cursor, hot spot at the top-left: `X` outline, `o` fill, space clear.
const cursor_rows = [_]*const [12]u8{
    "X           ",
    "XX          ",
    "XoX         ",
    "XooX        ",
    "XoooX       ",
    "XooooX      ",
    "XoooooX     ",
    "XooooooX    ",
    "XoooooooX   ",
    "XooooooooX  ",
    "XoooooooooX ",
    "XooooooXXXXX",
    "XoooXooX    ",
    "XooXXooX    ",
    "XoX  XooX   ",
    "XX   XooX   ",
    "X     XooX  ",
    "      XooX  ",
    "       XX   ",
};

/// Draw the arrow at a logical position, scaled to whole device pixels.
fn drawCursor(target: cpu.raster.Target, x: f64, y: f64, scale_factor: f64) void {
    assert(scale_factor > 0);
    assert(target.width > 0);
    assert(target.height > 0);
    const scale: u32 = @intFromFloat(@max(1.0, @round(scale_factor)));
    const origin_x: i64 = @intFromFloat(@floor(x * scale_factor));
    const origin_y: i64 = @intFromFloat(@floor(y * scale_factor));
    for (cursor_rows, 0..) |pattern, row_index| {
        for (pattern, 0..) |cell, column_index| {
            const color: u32 = switch (cell) {
                'X' => 0xFF00_0000,
                'o' => 0xFFFF_FFFF,
                else => continue,
            };
            const cell_x = origin_x + @as(i64, @intCast(column_index * scale));
            const cell_y = origin_y + @as(i64, @intCast(row_index * scale));
            fillCell(target, cell_x, cell_y, scale, color);
        }
    }
}

fn fillCell(target: cpu.raster.Target, x: i64, y: i64, scale: u32, color: u32) void {
    assert(scale >= 1);
    assert(scale <= 8);
    assert(color >> 24 == 0xFF);
    var dy: u32 = 0;
    while (dy < scale) : (dy += 1) {
        const row_y = y + dy;
        if (row_y < 0 or row_y >= target.height) continue;
        const row = target.row(@intCast(row_y));
        var dx: u32 = 0;
        while (dx < scale) : (dx += 1) {
            const column = x + dx;
            if (column < 0 or column >= target.width) continue;
            row[@intCast(column)] = color;
        }
    }
}
