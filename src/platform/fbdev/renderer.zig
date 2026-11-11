//! FbdevRenderer - the fbdev backend's contract `Renderer` (contract §9).
//!
//! Draws each packed frame with the CPU renderer into a panel-sized back
//! buffer, draws the software cursor over it, and copies the result to the
//! panel (`Framebuffer.present`). Atlas records arrive through `uploadAtlas`
//! and land in the CPU renderer's own atlases; the renderer draws on the
//! caller's thread, so an upload never races a frame that samples the atlas.
//!
//! The panel's size is fixed by the hardware, so `resize` only ever restates
//! it; the window budget is checked against it before initialization.
//!
//! ## Memory (CLAUDE.md §2)
//!
//! `initInPlace` reserves the back buffer (4 B per panel pixel) from fresh
//! pages, and the CPU renderer's raster scratch and atlases at the window's
//! `RenderLimits`. Nothing is allocated afterwards.

const std = @import("std");
const backend = @import("../../core/backend.zig");
const reservation = @import("../../core/reservation.zig");
const PackedFrame = @import("../../core/packed_frame.zig").PackedFrame;
const cpu = @import("../cpu/renderer.zig");
const Framebuffer = @import("framebuffer.zig").Framebuffer;

const assert = std.debug.assert;

/// The software cursor drawn over each frame, in logical pixels.
pub const Cursor = struct {
    visible: bool = false,
    x: f64 = 0,
    y: f64 = 0,
};

pub const FbdevRenderer = struct {
    /// `Surface.native`; the panel outlives the renderer.
    framebuffer: ?*Framebuffer = null,
    /// One frame in the renderer's pixel format, panel-sized.
    back_buffer: []u32 = &.{},
    renderer: cpu.Renderer = undefined,
    /// The panel's size, restated by every `resize`; `draw` asserts it.
    size_px: backend.SizePx = .{ .width = 0, .height = 0 },
    /// Set by the window before each `draw`.
    cursor: Cursor = .{},

    const Self = @This();

    comptime {
        backend.verifyRenderer(Self);
    }

    /// `surface.native` points at the platform's `Framebuffer`, whose panel
    /// size `surface.size_px` must be.
    pub fn initInPlace(
        self: *Self,
        surface: *const backend.Surface,
        limits: *const backend.RenderLimits,
    ) !void {
        assert(self.framebuffer == null);
        assert(surface.scale_factor > 0);
        const framebuffer: *Framebuffer = @ptrCast(@alignCast(surface.native.?));
        assert(surface.size_px.width == framebuffer.width);
        assert(surface.size_px.height == framebuffer.height);
        assert(framebuffer.width <= limits.window.framebuffer_width_max);
        assert(framebuffer.height <= limits.window.framebuffer_height_max);

        const pixel_count = @as(u64, framebuffer.width) * framebuffer.height;
        assert(pixel_count <= std.math.maxInt(u32));
        self.back_buffer = try reservation.reserve(u32, @intCast(pixel_count));
        errdefer reservation.release(u32, self.back_buffer, self.back_buffer.len);

        try self.renderer.initInPlace(limits);
        self.framebuffer = framebuffer;
        self.size_px = surface.size_px;
        self.cursor = .{};
    }

    /// The back buffer is rewritten every frame, so all of it counts as used.
    pub fn deinit(self: *Self) void {
        if (self.framebuffer == null) return;
        assert(self.back_buffer.len == @as(usize, self.size_px.width) * self.size_px.height);
        self.renderer.deinit();
        reservation.release(u32, self.back_buffer, self.back_buffer.len);
        self.back_buffer = &.{};
        self.framebuffer = null;
    }

    pub fn uploadAtlas(
        self: *Self,
        kind: backend.AtlasKind,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) void {
        assert(self.framebuffer != null);
        assert(pixels.len > 0);
        self.renderer.uploadAtlas(kind, dirty, pixels);
    }

    /// The panel never changes size; a resize restates it.
    pub fn resize(self: *Self, size_px: backend.SizePx) void {
        const framebuffer = self.framebuffer.?;
        assert(size_px.width == framebuffer.width);
        assert(size_px.height == framebuffer.height);
        self.size_px = size_px;
    }

    pub fn capabilities(self: *const Self) backend.Capabilities {
        assert(self.framebuffer != null);
        assert(self.back_buffer.len > 0);
        return self.renderer.capabilities();
    }

    /// Rasterize `frame` into the back buffer, draw the cursor over it, and
    /// copy the result to the panel.
    pub fn draw(
        self: *Self,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
        clear: backend.Color,
    ) void {
        const framebuffer = self.framebuffer.?;
        assert(std.meta.eql(viewport.size_px, self.size_px));
        assert(self.back_buffer.len == @as(usize, self.size_px.width) * self.size_px.height);
        const target = cpu.raster.Target{
            .pixels = self.back_buffer,
            .width = self.size_px.width,
            .height = self.size_px.height,
            .stride = self.size_px.width,
        };
        _ = self.renderer.draw(target, frame, .{ .scale_factor = viewport.scale_factor }, clear);
        if (self.cursor.visible) {
            drawCursor(target, self.cursor.x, self.cursor.y, viewport.scale_factor);
        }
        framebuffer.present(target);
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
fn drawCursor(target: cpu.raster.Target, x: f64, y: f64, scale_factor: f32) void {
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
