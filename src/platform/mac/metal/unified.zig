//! Unified shader for rendering quads and shadows in a single draw call
//!
//! This eliminates pipeline switches when quads and shadows are interleaved by draw order.
//! The shader uses a type discriminator to branch between quad and shadow rendering.

const std = @import("std");
const scene = @import("../../../scene/mod.zig");

/// Primitive types for the unified shader
pub const PrimitiveType = enum(u32) {
    quad = 0,
    shadow = 1,
};

/// Unified primitive for GPU rendering - can represent either a quad or shadow.
///
/// Memory layout is carefully designed for Metal alignment:
/// - float4 types (Hsla, Corners, Edges) must be at 16-byte aligned offsets
/// - Total size is 128 bytes (power of 2 for efficient GPU access)
pub const Primitive = extern struct {
    // Offset 0 (8 bytes)
    order: scene.DrawOrder = 0,
    primitive_type: u32 = 0, // 0 = quad, 1 = shadow

    // Offset 8 (16 bytes) - bounds (shared naming)
    bounds_origin_x: f32 = 0,
    bounds_origin_y: f32 = 0,
    bounds_size_width: f32 = 0,
    bounds_size_height: f32 = 0,

    // Offset 24 (8 bytes) - shadow-specific, packed before float4s
    blur_radius: f32 = 0,
    offset_x: f32 = 0,

    // Offset 32 (16 bytes, 16-aligned for float4)
    background: scene.Hsla = scene.Hsla.transparent,

    // Offset 48 (16 bytes, 16-aligned for float4)
    border_color: scene.Hsla = scene.Hsla.transparent,

    // Offset 64 (16 bytes, 16-aligned for float4)
    corner_radii: scene.Corners = scene.Corners.zero,

    // Offset 80 (16 bytes, 16-aligned for float4)
    border_widths: scene.Edges = scene.Edges.zero,

    // Offset 96 (16 bytes) - clip bounds for quads
    clip_origin_x: f32 = -1e9,
    clip_origin_y: f32 = -1e9,
    clip_size_width: f32 = 2e9,
    clip_size_height: f32 = 2e9,

    // Offset 112 (16 bytes) - remaining shadow fields + padding
    offset_y: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
    _pad3: f32 = 0,

    // Total: 128 bytes

    const Self = @This();

    /// Convert a Quad to a unified Primitive
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
            .background = quad.background,
            .border_color = quad.border_color,
            .corner_radii = quad.corner_radii,
            .border_widths = quad.border_widths,
            .clip_origin_x = quad.clip_origin_x,
            .clip_origin_y = quad.clip_origin_y,
            .clip_size_width = quad.clip_size_width,
            .clip_size_height = quad.clip_size_height,
            .offset_y = 0,
        };
    }

    /// Convert a Shadow to a unified Primitive
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
            .background = shadow.color,
            .border_color = scene.Hsla.transparent,
            .corner_radii = shadow.corner_radii,
            .border_widths = scene.Edges.zero,
            .clip_origin_x = -1e9,
            .clip_origin_y = -1e9,
            .clip_size_width = 2e9,
            .clip_size_height = 2e9,
            .offset_y = shadow.offset_y,
        };
    }
};

// Compile-time verification that Primitive is 128 bytes
comptime {
    if (@sizeOf(Primitive) != 128) {
        @compileError(std.fmt.comptimePrint(
            "Primitive size must be 128 bytes, got {} bytes",
            .{@sizeOf(Primitive)},
        ));
    }
}

/// Metal Shading Language source for unified quad/shadow rendering
pub const unified_shader_source =
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
    \\            float border = (centered.x < 0.0) ? bw.w : bw.y;
    \\            if (abs(centered.y) > abs(centered.x)) {
    \\                border = (centered.y < 0.0) ? bw.x : bw.z;
    \\            }
    \\            float inner_radius = max(0.0, radius - border);
    \\            float2 inner_half_size = half_size - float2(border);
    \\            float inner_dist = rounded_rect_sdf(centered, inner_half_size, inner_radius);
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

pub const unit_vertices = [_][2]f32{
    .{ 0.0, 0.0 },
    .{ 1.0, 0.0 },
    .{ 0.0, 1.0 },
    .{ 1.0, 0.0 },
    .{ 1.0, 1.0 },
    .{ 0.0, 1.0 },
};
