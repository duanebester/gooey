//! GPU types and constants for Vulkan shader communication.
//!
//! Pure data — no Vulkan state, no device handles, no side effects.
//! These types define the CPU ↔ GPU interface contract: struct layouts
//! must match the corresponding GLSL shader declarations exactly.

const std = @import("std");
const scene_mod = @import("../../scene/mod.zig");
const svg_instance_mod = @import("../../scene/svg_instance.zig");
const image_instance_mod = @import("../../scene/image_instance.zig");

const SvgInstance = svg_instance_mod.SvgInstance;
const ImageInstance = image_instance_mod.ImageInstance;

// =============================================================================
// Capacity Limits (CLAUDE.md Rule #4 — put a limit on everything)
// =============================================================================

pub const MAX_PRIMITIVES: u32 = 4096;
pub const MAX_GLYPHS: u32 = 8192;
pub const MAX_SVGS: u32 = 2048;
pub const MAX_IMAGES: u32 = 1024;
pub const FRAME_COUNT: u32 = 3;
pub const MAX_SURFACE_FORMATS: u32 = 128;
pub const MAX_PRESENT_MODES: u32 = 16;

// =============================================================================
// GPU Types
// =============================================================================

/// Uniform buffer data pushed once per frame.
/// 16 bytes — single vec4 in std140 layout.
pub const Uniforms = extern struct {
    viewport_width: f32,
    viewport_height: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,

    comptime {
        std.debug.assert(@sizeOf(Uniforms) == 16);
    }
};

/// GPU-ready glyph instance data (matches text shader struct layout).
/// 64 bytes = 16 floats.
pub const GpuGlyph = extern struct {
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    size_x: f32 = 0,
    size_y: f32 = 0,
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    color_h: f32 = 0,
    color_s: f32 = 0,
    color_l: f32 = 1,
    color_a: f32 = 1,
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    comptime {
        std.debug.assert(@sizeOf(GpuGlyph) == 64);
    }

    pub fn fromScene(g: scene_mod.GlyphInstance) GpuGlyph {
        return .{
            .pos_x = g.pos_x,
            .pos_y = g.pos_y,
            .size_x = g.size_x,
            .size_y = g.size_y,
            .uv_left = g.uv_left,
            .uv_top = g.uv_top,
            .uv_right = g.uv_right,
            .uv_bottom = g.uv_bottom,
            .color_h = g.color.h,
            .color_s = g.color.s,
            .color_l = g.color.l,
            .color_a = g.color.a,
            .clip_x = g.clip_x,
            .clip_y = g.clip_y,
            .clip_width = g.clip_width,
            .clip_height = g.clip_height,
        };
    }
};

/// GPU-ready SVG instance data (matches SVG shader struct layout).
/// 80 bytes = 20 floats.
pub const GpuSvg = extern struct {
    // Position and size
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    size_x: f32 = 0,
    size_y: f32 = 0,
    // UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Fill color (HSLA)
    fill_h: f32 = 0,
    fill_s: f32 = 0,
    fill_l: f32 = 0,
    fill_a: f32 = 0,
    // Stroke color (HSLA)
    stroke_h: f32 = 0,
    stroke_s: f32 = 0,
    stroke_l: f32 = 0,
    stroke_a: f32 = 0,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    comptime {
        std.debug.assert(@sizeOf(GpuSvg) == 80);
    }

    pub fn fromScene(s: SvgInstance) GpuSvg {
        return .{
            .pos_x = s.pos_x,
            .pos_y = s.pos_y,
            .size_x = s.size_x,
            .size_y = s.size_y,
            .uv_left = s.uv_left,
            .uv_top = s.uv_top,
            .uv_right = s.uv_right,
            .uv_bottom = s.uv_bottom,
            .fill_h = s.color.h,
            .fill_s = s.color.s,
            .fill_l = s.color.l,
            .fill_a = s.color.a,
            .stroke_h = s.stroke_color.h,
            .stroke_s = s.stroke_color.s,
            .stroke_l = s.stroke_color.l,
            .stroke_a = s.stroke_color.a,
            .clip_x = s.clip_x,
            .clip_y = s.clip_y,
            .clip_width = s.clip_width,
            .clip_height = s.clip_height,
        };
    }
};

/// GPU-ready Image instance data (matches image shader struct layout).
/// 96 bytes = 24 floats.
pub const GpuImage = extern struct {
    // Position and size
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    dest_width: f32 = 0,
    dest_height: f32 = 0,
    // UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Tint color (HSLA)
    tint_h: f32 = 0,
    tint_s: f32 = 0,
    tint_l: f32 = 1,
    tint_a: f32 = 1,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,
    // Corner radii
    corner_tl: f32 = 0,
    corner_tr: f32 = 0,
    corner_br: f32 = 0,
    corner_bl: f32 = 0,
    // Effects
    grayscale: f32 = 0,
    opacity: f32 = 1,
    _pad0: f32 = 0,
    _pad1: f32 = 0,

    comptime {
        std.debug.assert(@sizeOf(GpuImage) == 96);
    }

    pub fn fromScene(img: ImageInstance) GpuImage {
        return .{
            .pos_x = img.pos_x,
            .pos_y = img.pos_y,
            .dest_width = img.dest_width,
            .dest_height = img.dest_height,
            .uv_left = img.uv_left,
            .uv_top = img.uv_top,
            .uv_right = img.uv_right,
            .uv_bottom = img.uv_bottom,
            .tint_h = img.tint.h,
            .tint_s = img.tint.s,
            .tint_l = img.tint.l,
            .tint_a = img.tint.a,
            .clip_x = img.clip_x,
            .clip_y = img.clip_y,
            .clip_width = img.clip_width,
            .clip_height = img.clip_height,
            .corner_tl = img.corner_tl,
            .corner_tr = img.corner_tr,
            .corner_br = img.corner_br,
            .corner_bl = img.corner_bl,
            .grayscale = img.grayscale,
            .opacity = img.opacity,
        };
    }
};
