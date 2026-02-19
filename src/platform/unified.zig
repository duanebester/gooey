//! Unified shader primitives for GPU rendering
//!
//! Converts gooey's scene.Quad and scene.Shadow into a single GPU primitive type
//! for efficient single-pass rendering with one draw call.
//!
//! Used by all platforms: Metal (macOS), Vulkan (Linux), WebGPU (Web)
//!
//! The flat field layout (individual floats instead of nested structs) is required
//! for WGSL and SPIR-V compatibility. Metal can consume either format.

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
            .primitive_type = @intFromEnum(PrimitiveType.quad),
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
            .primitive_type = @intFromEnum(PrimitiveType.shadow),
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
            .primitive_type = @intFromEnum(PrimitiveType.quad),
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
// Metal Shader Source
// =============================================================================

/// Metal Shading Language source for unified quad/shadow rendering
pub const metal_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\constant uint PRIM_QUAD = 0;
    \\constant uint PRIM_SHADOW = 1;
    \\
    \\struct Primitive {
    \\    uint order;
    \\    uint primitive_type;
    \\    float bounds_origin_x;
    \\    float bounds_origin_y;
    \\    float bounds_size_width;
    \\    float bounds_size_height;
    \\    float blur_radius;
    \\    float offset_x;
    \\    float4 background;
    \\    float4 border_color;
    \\    float4 corner_radii;
    \\    float4 border_widths;
    \\    float clip_origin_x;
    \\    float clip_origin_y;
    \\    float clip_size_width;
    \\    float clip_size_height;
    \\    float offset_y;
    \\    float _pad1;
    \\    float _pad2;
    \\    float _pad3;
    \\};
    \\
    \\struct VertexOutput {
    \\    float4 position [[position]];
    \\    uint primitive_type;
    \\    float4 color;
    \\    float4 border_color;
    \\    float2 quad_coord;
    \\    float2 quad_size;
    \\    float4 corner_radii;
    \\    float4 border_widths;
    \\    float4 clip_bounds;
    \\    float2 screen_pos;
    \\    float2 content_size;
    \\    float2 local_pos;
    \\    float blur_radius;
    \\};
    \\
    \\float4 hsla_to_rgba(float4 hsla) {
    \\    float h = hsla.x * 6.0;
    \\    float s = hsla.y;
    \\    float l = hsla.z;
    \\    float a = hsla.w;
    \\    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    \\    float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
    \\    float m = l - c / 2.0;
    \\    float3 rgb;
    \\    if (h < 1.0) rgb = float3(c, x, 0);
    \\    else if (h < 2.0) rgb = float3(x, c, 0);
    \\    else if (h < 3.0) rgb = float3(0, c, x);
    \\    else if (h < 4.0) rgb = float3(0, x, c);
    \\    else if (h < 5.0) rgb = float3(x, 0, c);
    \\    else rgb = float3(c, 0, x);
    \\    return float4(rgb + m, a);
    \\}
    \\
    \\float rounded_rect_sdf(float2 pos, float2 half_size, float radius) {
    \\    float2 d = abs(pos) - half_size + radius;
    \\    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
    \\}
    \\
    \\float pick_corner_radius(float2 pos, float4 radii) {
    \\    if (pos.x < 0.0) {
    \\        return pos.y < 0.0 ? radii.x : radii.w;
    \\    } else {
    \\        return pos.y < 0.0 ? radii.y : radii.z;
    \\    }
    \\}
    \\
    \\float shadow_falloff(float distance, float blur) {
    \\    return 1.0 - smoothstep(-blur * 0.5, blur * 1.5, distance);
    \\}
    \\
    \\vertex VertexOutput unified_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    constant float2 *unit_vertices [[buffer(0)]],
    \\    constant Primitive *primitives [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    Primitive p = primitives[iid];
    \\
    \\    VertexOutput out;
    \\    out.primitive_type = p.primitive_type;
    \\    out.color = hsla_to_rgba(p.background);
    \\    out.border_color = hsla_to_rgba(p.border_color);
    \\    out.corner_radii = p.corner_radii;
    \\    out.border_widths = p.border_widths;
    \\    out.clip_bounds = float4(p.clip_origin_x, p.clip_origin_y, p.clip_size_width, p.clip_size_height);
    \\    out.blur_radius = p.blur_radius;
    \\
    \\    if (p.primitive_type == PRIM_QUAD) {
    \\        float2 origin = float2(p.bounds_origin_x, p.bounds_origin_y);
    \\        float2 size = float2(p.bounds_size_width, p.bounds_size_height);
    \\        float2 pos = origin + unit * size;
    \\        float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\        out.position = float4(ndc, 0.0, 1.0);
    \\        out.quad_coord = unit;
    \\        out.quad_size = size;
    \\        out.screen_pos = pos;
    \\        out.content_size = size;
    \\        out.local_pos = float2(0, 0);
    \\    } else {
    \\        float expand = p.blur_radius * 2.0;
    \\        float2 content_origin = float2(p.bounds_origin_x, p.bounds_origin_y);
    \\        float2 content_size = float2(p.bounds_size_width, p.bounds_size_height);
    \\        float2 offset = float2(p.offset_x, p.offset_y);
    \\        float2 shadow_origin = content_origin + offset - expand;
    \\        float2 shadow_size = content_size + expand * 2.0;
    \\        float2 pos = shadow_origin + unit * shadow_size;
    \\        float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\        float2 local = (unit * shadow_size) - (shadow_size / 2.0) - offset;
    \\        out.position = float4(ndc, 0.0, 1.0);
    \\        out.quad_coord = unit;
    \\        out.quad_size = shadow_size;
    \\        out.screen_pos = pos;
    \\        out.content_size = content_size;
    \\        out.local_pos = local;
    \\    }
    \\    return out;
    \\}
    \\
    \\fragment float4 unified_fragment(VertexOutput in [[stage_in]]) {
    \\    if (in.primitive_type == PRIM_QUAD) {
    \\        float2 clip_min = in.clip_bounds.xy;
    \\        float2 clip_max = clip_min + in.clip_bounds.zw;
    \\        if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\            in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\            discard_fragment();
    \\        }
    \\        float2 size = in.quad_size;
    \\        float2 half_size = size / 2.0;
    \\        float2 pos = in.quad_coord * size;
    \\        float2 centered = pos - half_size;
    \\        float radius = pick_corner_radius(centered, in.corner_radii);
    \\        float outer_dist = rounded_rect_sdf(centered, half_size, radius);
    \\        float4 bw = in.border_widths;
    \\        bool has_border = bw.x > 0.0 || bw.y > 0.0 || bw.z > 0.0 || bw.w > 0.0;
    \\        float4 color = in.color;
    \\        if (has_border) {
    \\            // bw: x=top, y=right, z=bottom, w=left
    \\            // Construct inner rounded rect by insetting each side independently.
    \\            // This handles both per-side borders (e.g. bottom-only navbar) and
    \\            // uniform borders on rounded corners correctly.
    \\            float2 inner_min = float2(-half_size.x + bw.w, -half_size.y + bw.x);
    \\            float2 inner_max = float2(half_size.x - bw.y, half_size.y - bw.z);
    \\            float2 inner_center = (inner_min + inner_max) * 0.5;
    \\            float2 inner_half_size = max(float2(0.0), (inner_max - inner_min) * 0.5);
    \\            float2 inner_pos = centered - inner_center;
    \\            // Per-corner inner radii: reduce by the max of the two adjacent border widths.
    \\            float4 cr = in.corner_radii;
    \\            float4 inner_radii = float4(
    \\                max(0.0, cr.x - max(bw.x, bw.w)),
    \\                max(0.0, cr.y - max(bw.x, bw.y)),
    \\                max(0.0, cr.z - max(bw.z, bw.y)),
    \\                max(0.0, cr.w - max(bw.z, bw.w))
    \\            );
    \\            float inner_radius = pick_corner_radius(inner_pos, inner_radii);
    \\            float inner_dist = rounded_rect_sdf(inner_pos, inner_half_size, inner_radius);
    \\            float border_blend = smoothstep(-0.5, 0.5, inner_dist);
    \\            color = mix(in.color, in.border_color, border_blend);
    \\        }
    \\        float alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);
    \\        return color * float4(1.0, 1.0, 1.0, alpha);
    \\    } else {
    \\        float2 half_size = in.content_size / 2.0;
    \\        float radius = pick_corner_radius(in.local_pos, in.corner_radii);
    \\        float dist = rounded_rect_sdf(in.local_pos, half_size, radius);
    \\        float alpha = shadow_falloff(dist, in.blur_radius);
    \\        return float4(in.color.rgb, in.color.a * alpha);
    \\    }
    \\}
;

// Legacy alias for backwards compatibility during migration
pub const unified_shader_source = metal_shader_source;

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
