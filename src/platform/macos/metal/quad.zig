//! Quad shader and pipeline for rendering rectangles
//! Supports: solid colors, rounded corners, borders

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const scene = @import("../../../scene/mod.zig");

/// Metal Shading Language source for quad rendering
pub const quad_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Quad {
    \\    uint order;
    \\    uint _pad0;
    \\    float bounds_origin_x;
    \\    float bounds_origin_y;
    \\    float bounds_size_width;
    \\    float bounds_size_height;
    \\    float clip_origin_x;
    \\    float clip_origin_y;
    \\    float clip_size_width;
    \\    float clip_size_height;
    \\    uint _pad1;
    \\    uint _pad2;
    \\    float4 background;
    \\    float4 border_color;
    \\    float4 corner_radii;
    \\    float4 border_widths;
    \\};
    \\
    \\struct QuadVertexOutput {
    \\    float4 position [[position]];
    \\    float4 color;
    \\    float4 border_color;
    \\    float2 quad_coord;
    \\    float2 quad_size;
    \\    float4 corner_radii;
    \\    float4 border_widths;
    \\    float4 clip_bounds;   // x, y, width, height
    \\    float2 screen_pos;    // screen position for clip test
    \\};
    \\
    \\float4 hsla_to_rgba(float4 hsla) {
    \\    float h = hsla.x * 6.0;
    \\    float s = hsla.y;
    \\    float l = hsla.z;
    \\    float a = hsla.w;
    \\
    \\    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    \\    float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
    \\    float m = l - c / 2.0;
    \\
    \\    float3 rgb;
    \\    if (h < 1.0) rgb = float3(c, x, 0);
    \\    else if (h < 2.0) rgb = float3(x, c, 0);
    \\    else if (h < 3.0) rgb = float3(0, c, x);
    \\    else if (h < 4.0) rgb = float3(0, x, c);
    \\    else if (h < 5.0) rgb = float3(x, 0, c);
    \\    else rgb = float3(c, 0, x);
    \\
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
    \\vertex QuadVertexOutput quad_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    constant float2 *unit_vertices [[buffer(0)]],
    \\    constant Quad *quads [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    Quad q = quads[iid];
    \\
    \\    float2 origin = float2(q.bounds_origin_x, q.bounds_origin_y);
    \\    float2 size = float2(q.bounds_size_width, q.bounds_size_height);
    \\    float2 pos = origin + unit * size;
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    QuadVertexOutput out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(q.background);
    \\    out.border_color = hsla_to_rgba(q.border_color);
    \\    out.quad_coord = unit;
    \\    out.quad_size = size;
    \\    out.corner_radii = q.corner_radii;
    \\    out.border_widths = q.border_widths;
    \\    out.clip_bounds = float4(q.clip_origin_x, q.clip_origin_y, q.clip_size_width, q.clip_size_height);
    \\    out.screen_pos = pos;
    \\    return out;
    \\}
    \\
    \\fragment float4 quad_fragment(QuadVertexOutput in [[stage_in]]) {
    \\    // Discard pixels outside clip bounds
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\
    \\    float2 size = in.quad_size;
    \\    float2 half_size = size / 2.0;
    \\    float2 pos = in.quad_coord * size;
    \\    float2 centered = pos - half_size;
    \\
    \\    float radius = pick_corner_radius(centered, in.corner_radii);
    \\    float outer_dist = rounded_rect_sdf(centered, half_size, radius);
    \\
    \\    float4 bw = in.border_widths;
    \\    bool has_border = bw.x > 0.0 || bw.y > 0.0 || bw.z > 0.0 || bw.w > 0.0;
    \\
    \\    float4 color = in.color;
    \\
    \\    if (has_border) {
    \\        // bw: x=top, y=right, z=bottom, w=left
    \\        // Construct inner rounded rect by insetting each side independently.
    \\        // Per-side insets handle both uniform borders on rounded corners
    \\        // and single-side borders on wide/tall rects.
    \\        float2 inner_min = float2(-half_size.x + bw.w, -half_size.y + bw.x);
    \\        float2 inner_max = float2(half_size.x - bw.y, half_size.y - bw.z);
    \\        float2 inner_center = (inner_min + inner_max) * 0.5;
    \\        float2 inner_half_size = max(float2(0.0), (inner_max - inner_min) * 0.5);
    \\        float2 inner_pos = centered - inner_center;
    \\        // Per-corner inner radii: reduce by the max of the two adjacent border widths.
    \\        float4 cr = in.corner_radii;
    \\        float4 inner_radii = float4(
    \\            max(0.0, cr.x - max(bw.x, bw.w)),
    \\            max(0.0, cr.y - max(bw.x, bw.y)),
    \\            max(0.0, cr.z - max(bw.z, bw.y)),
    \\            max(0.0, cr.w - max(bw.z, bw.w))
    \\        );
    \\        float inner_radius = pick_corner_radius(inner_pos, inner_radii);
    \\        float inner_dist = rounded_rect_sdf(inner_pos, inner_half_size, inner_radius);
    \\        float border_blend = smoothstep(-0.5, 0.5, inner_dist);
    \\        color = mix(in.color, in.border_color, border_blend);
    \\    }
    \\
    \\    float alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);
    \\    return color * float4(1.0, 1.0, 1.0, alpha);
    \\}
;

/// Unit quad vertices (two triangles forming a quad)
pub const unit_vertices = [_][2]f32{
    .{ 0.0, 0.0 },
    .{ 1.0, 0.0 },
    .{ 0.0, 1.0 },
    .{ 1.0, 0.0 },
    .{ 1.0, 1.0 },
    .{ 0.0, 1.0 },
};
