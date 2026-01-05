//! SVG Instance - GPU-ready data for rendering atlas-cached SVG icons

const std = @import("std");
const scene = @import("scene.zig");

pub const SvgInstance = extern struct {
    // Draw order for z-index interleaving
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0, // Maintain 8-byte alignment

    // Screen position (top-left, logical pixels)
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    // Size (logical pixels)
    size_x: f32 = 0,
    size_y: f32 = 0,
    // Atlas UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Padding to align color (float4) to 16-byte boundary
    // Without this, color is at offset 40; Metal requires float4 at 16-byte aligned offset (48)
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    // Fill color (HSLA) - must be at 16-byte aligned offset for Metal float4
    color: scene.Hsla = scene.Hsla.black,
    // Stroke color (HSLA)
    stroke_color: scene.Hsla = scene.Hsla.transparent,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    pub fn init(
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        uv_left: f32,
        uv_top: f32,
        uv_right: f32,
        uv_bottom: f32,
        fill_color: scene.Hsla,
        stroke_color_arg: scene.Hsla,
    ) SvgInstance {
        // Assert valid size: dimensions must be non-negative
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        // Assert valid UV coordinates: must be in normalized range [0, 1]
        std.debug.assert(uv_left >= 0 and uv_left <= 1);
        std.debug.assert(uv_top >= 0 and uv_top <= 1);
        std.debug.assert(uv_right >= 0 and uv_right <= 1);
        std.debug.assert(uv_bottom >= 0 and uv_bottom <= 1);
        return .{
            .pos_x = x,
            .pos_y = y,
            .size_x = width,
            .size_y = height,
            .uv_left = uv_left,
            .uv_top = uv_top,
            .uv_right = uv_right,
            .uv_bottom = uv_bottom,
            .color = fill_color,
            .stroke_color = stroke_color_arg,
        };
    }

    pub fn withClipBounds(self: SvgInstance, clip: scene.ContentMask.ClipBounds) SvgInstance {
        var s = self;
        s.clip_x = clip.x;
        s.clip_y = clip.y;
        s.clip_width = clip.width;
        s.clip_height = clip.height;
        return s;
    }

    pub fn withClip(self: SvgInstance, clip_x: f32, clip_y: f32, clip_w: f32, clip_h: f32) SvgInstance {
        var s = self;
        s.clip_x = clip_x;
        s.clip_y = clip_y;
        s.clip_width = clip_w;
        s.clip_height = clip_h;
        return s;
    }
};

comptime {
    if (@sizeOf(SvgInstance) != 96) {
        @compileError(std.fmt.comptimePrint(
            "SvgInstance must be 96 bytes, got {}",
            .{@sizeOf(SvgInstance)},
        ));
    }
    // Verify color is at 16-byte aligned offset for Metal float4
    if (@offsetOf(SvgInstance, "color") != 48) {
        @compileError(std.fmt.comptimePrint(
            "SvgInstance.color must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(SvgInstance, "color")},
        ));
    }
}
