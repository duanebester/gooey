//! FbdevWindow - the single full-screen window of the fbdev backend.
//!
//! The window covers the whole panel: `WindowOptions.width` and `height` are
//! ignored, and the size never changes after initialization. Frames are drawn
//! by the CPU renderer into a back buffer reserved at initialization, a
//! software cursor is drawn on top when a pointing device is attached, and the
//! result is copied to the framebuffer by `Framebuffer.present`.
//!
//! The core host (`core_host.zig`) owns the loop: it routes input through
//! `handleInput` and presents each frame it packs with `presentScene`.
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

    /// Logical size: the panel at `scale_factor`.
    size: geometry.Size(f64),
    scale_factor: f64,

    /// One frame in the renderer's pixel format, panel-sized.
    back_buffer: []u32,

    /// Draw a cursor: true when a mouse or tablet is attached.
    cursor_visible: bool,
    closed: bool = false,

    mouse_x: f64 = 0,
    mouse_y: f64 = 0,

    text_atlas: ?*const text_mod.Atlas = null,
    svg_atlas: ?*const text_mod.Atlas = null,
    image_atlas: ?*const text_mod.Atlas = null,
    renderer: cpu.Renderer,

    // Written only by the section of 0.3.1 calls below.
    dark_appearance: bool = false,
    needs_redraw: bool = true,
    render_deadline_ms: ?i64 = null,
    title_buffer: [title_bytes_max]u8 = undefined,
    title_len: usize = 0,

    on_input: ?InputCallback = null,
    user_data: ?*anyopaque = null,

    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;

    pub const title_bytes_max: usize = 255;

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
            .cursor_visible = plat.devices.hasPointer(),
            .mouse_x = plat.translator.pointer_x,
            .mouse_y = plat.translator.pointer_y,
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

    /// Rasterize `scene` (or only `clear` without one) into the back buffer,
    /// draw the cursor over it, and copy the frame to the panel. The core
    /// host calls it as its presenter, and again when only the cursor moved.
    pub fn presentScene(self: *Self, scene: ?*const scene_mod.Scene, clear: geometry.Color) void {
        assert(!self.closed);
        assert(clear.a >= 0);
        const target = self.frameTarget();
        if (scene) |frame_scene| {
            self.renderer.bindAtlases(.{
                .text = self.text_atlas,
                .svg = self.svg_atlas,
                .image = self.image_atlas,
            });
            _ = self.renderer.draw(
                target,
                frame_scene,
                .{ .scale_factor = @floatCast(self.scale_factor) },
                clear,
            );
        } else {
            cpu.raster.clear(target, clear);
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
        const callback = self.on_input orelse return false;
        return callback(self, event);
    }

    /// Records the close; the core host's loop ends at its next turn. Reached
    /// from the platform's Ctrl+Q and Alt+F4 chords.
    pub fn close(self: *Self) void {
        if (self.closed) return;
        self.closed = true;
        assert(self.isClosed());
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig` and `cx.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while those files
    // compile, and go when phase 6 deletes them.

    /// Stored only: the panel has no title bar.
    pub fn setTitle(self: *Self, title: []const u8) void {
        assert(title.len <= title_bytes_max);
        const len = @min(title.len, title_bytes_max);
        @memcpy(self.title_buffer[0..len], title[0..len]);
        self.title_len = len;
    }

    pub fn setAppearance(self: *Self, dark: bool) void {
        self.dark_appearance = dark;
        assert(self.dark_appearance == dark);
    }

    pub fn getPlatform(self: *Self) *FbdevPlatform {
        assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn requestRender(self: *Self) void {
        if (self.closed) return;
        self.needs_redraw = true;
    }

    /// Keeps only the earliest deadline.
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

    // =========================================================================
    // Core host binding
    // =========================================================================

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

    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        self.on_input = callback;
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
