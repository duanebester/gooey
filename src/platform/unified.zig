//! Unified shader primitives for GPU rendering
//!
//! Converts gooey's scene.Quad and scene.Shadow into a single GPU primitive type
//! for efficient single-pass rendering with one draw call.
//!
//! Used by Vulkan (Linux) and WebGPU (Web). Metal draws the packed frame
//! (`core/packed_frame.zig`) instead.
//!
//! The flat field layout (individual floats instead of nested structs) is required
//! for WGSL and SPIR-V compatibility.

const std = @import("std");
const scene = @import("../scene/mod.zig");

/// Primitive types for the unified shader
pub const PrimitiveType = enum(u32) {
    quad = 0,
    shadow = 1,
};

/// Unified primitive for GPU rendering - can represent either a quad or shadow.
///
/// Memory layout is carefully designed for GPU alignment:
/// - float4 types are expanded to 4 floats for WGSL/SPIR-V compatibility
/// - Total size is 128 bytes (power of 2 for efficient GPU access)
pub const Primitive = extern struct {
    // Offset 0 (8 bytes)
    order: scene.DrawOrder = 0,
    primitive_type: u32 = 0, // 0 = quad, 1 = shadow

    // Offset 8 (16 bytes) - bounds
    bounds_origin_x: f32 = 0,
    bounds_origin_y: f32 = 0,
    bounds_size_width: f32 = 0,
    bounds_size_height: f32 = 0,

    // Offset 24 (8 bytes) - shadow-specific
    blur_radius: f32 = 0,
    offset_x: f32 = 0,

    // Offset 32 (16 bytes) - background HSLA
    background_h: f32 = 0,
    background_s: f32 = 0,
    background_l: f32 = 0,
    background_a: f32 = 0,

    // Offset 48 (16 bytes) - border_color HSLA
    border_color_h: f32 = 0,
    border_color_s: f32 = 0,
    border_color_l: f32 = 0,
    border_color_a: f32 = 0,

    // Offset 64 (16 bytes) - corner_radii
    corner_radii_tl: f32 = 0,
    corner_radii_tr: f32 = 0,
    corner_radii_br: f32 = 0,
    corner_radii_bl: f32 = 0,

    // Offset 80 (16 bytes) - border_widths
    border_width_top: f32 = 0,
    border_width_right: f32 = 0,
    border_width_bottom: f32 = 0,
    border_width_left: f32 = 0,

    // Offset 96 (16 bytes) - clip bounds
    clip_origin_x: f32 = -1e9,
    clip_origin_y: f32 = -1e9,
    clip_size_width: f32 = 2e9,
    clip_size_height: f32 = 2e9,

    // Offset 112 (16 bytes) - remaining + padding
    offset_y: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
    _pad3: f32 = 0,

    // Total: 128 bytes

    const Self = @This();

    /// Convert a scene.Quad to a unified Primitive
    pub fn fromQuad(quad: scene.Quad) Self {
        return .{
            .order = quad.order,
            .primitive_type = @backingInt(PrimitiveType.quad),
            .bounds_origin_x = quad.bounds_origin_x,
            .bounds_origin_y = quad.bounds_origin_y,
            .bounds_size_width = quad.bounds_size_width,
            .bounds_size_height = quad.bounds_size_height,
            .blur_radius = 0,
            .offset_x = 0,
            .background_h = quad.background.h,
            .background_s = quad.background.s,
            .background_l = quad.background.l,
            .background_a = quad.background.a,
            .border_color_h = quad.border_color.h,
            .border_color_s = quad.border_color.s,
            .border_color_l = quad.border_color.l,
            .border_color_a = quad.border_color.a,
            .corner_radii_tl = quad.corner_radii.top_left,
            .corner_radii_tr = quad.corner_radii.top_right,
            .corner_radii_br = quad.corner_radii.bottom_right,
            .corner_radii_bl = quad.corner_radii.bottom_left,
            .border_width_top = quad.border_widths.top,
            .border_width_right = quad.border_widths.right,
            .border_width_bottom = quad.border_widths.bottom,
            .border_width_left = quad.border_widths.left,
            .clip_origin_x = quad.clip_origin_x,
            .clip_origin_y = quad.clip_origin_y,
            .clip_size_width = quad.clip_size_width,
            .clip_size_height = quad.clip_size_height,
            .offset_y = 0,
        };
    }

    /// Convert a scene.Shadow to a unified Primitive
    pub fn fromShadow(shadow: scene.Shadow) Self {
        return .{
            .order = shadow.order,
            .primitive_type = @backingInt(PrimitiveType.shadow),
            .bounds_origin_x = shadow.content_origin_x,
            .bounds_origin_y = shadow.content_origin_y,
            .bounds_size_width = shadow.content_size_width,
            .bounds_size_height = shadow.content_size_height,
            .blur_radius = shadow.blur_radius,
            .offset_x = shadow.offset_x,
            .background_h = shadow.color.h,
            .background_s = shadow.color.s,
            .background_l = shadow.color.l,
            .background_a = shadow.color.a,
            .border_color_h = 0,
            .border_color_s = 0,
            .border_color_l = 0,
            .border_color_a = 0,
            .corner_radii_tl = shadow.corner_radii.top_left,
            .corner_radii_tr = shadow.corner_radii.top_right,
            .corner_radii_br = shadow.corner_radii.bottom_right,
            .corner_radii_bl = shadow.corner_radii.bottom_left,
            .border_width_top = 0,
            .border_width_right = 0,
            .border_width_bottom = 0,
            .border_width_left = 0,
            .clip_origin_x = -1e9,
            .clip_origin_y = -1e9,
            .clip_size_width = 2e9,
            .clip_size_height = 2e9,
            .offset_y = shadow.offset_y,
        };
    }

    /// Create a simple filled quad (for debugging/testing)
    pub fn filledQuad(x: f32, y: f32, w: f32, h: f32, hue: f32, sat: f32, lit: f32, alpha: f32) Self {
        return .{
            .primitive_type = @backingInt(PrimitiveType.quad),
            .bounds_origin_x = x,
            .bounds_origin_y = y,
            .bounds_size_width = w,
            .bounds_size_height = h,
            .background_h = hue,
            .background_s = sat,
            .background_l = lit,
            .background_a = alpha,
        };
    }

    /// Create a rounded quad (for debugging/testing)
    pub fn roundedQuad(x: f32, y: f32, w: f32, h: f32, hue: f32, sat: f32, lit: f32, alpha: f32, radius: f32) Self {
        var p = filledQuad(x, y, w, h, hue, sat, lit, alpha);
        p.corner_radii_tl = radius;
        p.corner_radii_tr = radius;
        p.corner_radii_br = radius;
        p.corner_radii_bl = radius;
        return p;
    }
};

// Compile-time verification
comptime {
    if (@sizeOf(Primitive) != 128) {
        @compileError(std.fmt.comptimePrint(
            "Primitive size must be 128 bytes, got {} bytes",
            .{@sizeOf(Primitive)},
        ));
    }
}

/// Convert a scene's quads and shadows into a sorted unified primitive buffer.
/// Returns the number of primitives written.
pub fn convertScene(s: *const scene.Scene, out_buffer: []Primitive) u32 {
    const shadow_count = s.shadowCount();
    const quad_count = s.quadCount();
    const total = shadow_count + quad_count;

    if (total == 0) return 0;
    if (total > out_buffer.len) {
        @panic("Primitive buffer overflow");
    }

    var idx: u32 = 0;

    for (s.getShadows()) |shadow| {
        out_buffer[idx] = Primitive.fromShadow(shadow);
        idx += 1;
    }

    for (s.getQuads()) |quad| {
        out_buffer[idx] = Primitive.fromQuad(quad);
        idx += 1;
    }

    // Sort by draw order
    std.mem.sort(Primitive, out_buffer[0..idx], {}, lessThanByOrder);

    return idx;
}

fn lessThanByOrder(_: void, a: Primitive, b: Primitive) bool {
    return a.order < b.order;
}

// =============================================================================
// Unit vertices for instanced quad rendering
// =============================================================================

pub const unit_vertices = [_][2]f32{
    .{ 0.0, 0.0 },
    .{ 1.0, 0.0 },
    .{ 0.0, 1.0 },
    .{ 1.0, 0.0 },
    .{ 1.0, 1.0 },
    .{ 0.0, 1.0 },
};

// =============================================================================
// Tests
// =============================================================================

test "Primitive size is 128 bytes" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Primitive));
}

test "fromQuad converts correctly" {
    const quad = scene.Quad{
        .order = 5,
        .bounds_origin_x = 10,
        .bounds_origin_y = 20,
        .bounds_size_width = 100,
        .bounds_size_height = 50,
        .background = scene.Hsla.init(0.5, 0.8, 0.6, 1.0),
        .corner_radii = scene.Corners.all(8),
    };

    const prim = Primitive.fromQuad(quad);

    try std.testing.expectEqual(@as(u32, 5), prim.order);
    try std.testing.expectEqual(@as(u32, 0), prim.primitive_type);
    try std.testing.expectEqual(@as(f32, 10), prim.bounds_origin_x);
    try std.testing.expectEqual(@as(f32, 0.5), prim.background_h);
    try std.testing.expectEqual(@as(f32, 8), prim.corner_radii_tl);
}

test "fromShadow converts correctly" {
    const shadow = scene.Shadow{
        .order = 3,
        .content_origin_x = 10,
        .content_origin_y = 20,
        .content_size_width = 100,
        .content_size_height = 50,
        .blur_radius = 15,
        .offset_x = 2,
        .offset_y = 4,
        .color = scene.Hsla.init(0, 0, 0, 0.3),
        .corner_radii = scene.Corners.all(8),
    };

    const prim = Primitive.fromShadow(shadow);

    try std.testing.expectEqual(@as(u32, 3), prim.order);
    try std.testing.expectEqual(@as(u32, 1), prim.primitive_type);
    try std.testing.expectEqual(@as(f32, 15), prim.blur_radius);
    try std.testing.expectEqual(@as(f32, 4), prim.offset_y);
}
