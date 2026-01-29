//! Shadow shader for soft drop shadows using SDF-based blur

const std = @import("std");

/// Metal Shading Language source for shadow rendering
pub const shadow_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// Shadow struct - MUST match Zig Shadow extern struct exactly
    \\// float4 requires 16-byte alignment!
    \\struct Shadow {
    \\    uint order;                 // offset 0
    \\    uint _pad0;                 // offset 4
    \\    float content_origin_x;     // offset 8
    \\    float content_origin_y;     // offset 12
    \\    float content_size_width;   // offset 16
    \\    float content_size_height;  // offset 20
    \\    float blur_radius;          // offset 24
    \\    float offset_x;             // offset 28
    \\    float4 corner_radii;        // offset 32 (16-byte aligned)
    \\    float4 color;               // offset 48 (16-byte aligned)
    \\    float offset_y;             // offset 64
    \\    float _pad1;                // offset 68
    \\    float _pad2;                // offset 72
    \\    float _pad3;                // offset 76
    \\};                              // total: 80 bytes
    \\
    \\struct ShadowVertexOutput {
    \\    float4 position [[position]];
    \\    float4 color;
    \\    float2 local_pos;
    \\    float2 content_size;
    \\    float4 corner_radii;
    \\    float blur_radius;
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
    \\float shadow_falloff(float distance, float blur) {
    \\    return 1.0 - smoothstep(-blur * 0.5, blur * 1.5, distance);
    \\}
    \\
    \\vertex ShadowVertexOutput shadow_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    constant float2 *unit_vertices [[buffer(0)]],
    \\    constant Shadow *shadows [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    Shadow s = shadows[iid];
    \\
    \\    float expand = s.blur_radius * 2.0;
    \\    float2 content_origin = float2(s.content_origin_x, s.content_origin_y);
    \\    float2 content_size = float2(s.content_size_width, s.content_size_height);
    \\    float2 offset = float2(s.offset_x, s.offset_y);
    \\
    \\    float2 shadow_origin = content_origin + offset - expand;
    \\    float2 shadow_size = content_size + expand * 2.0;
    \\
    \\    float2 pos = shadow_origin + unit * shadow_size;
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    float2 local = (unit * shadow_size) - (shadow_size / 2.0) - offset;
    \\
    \\    ShadowVertexOutput out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(s.color);
    \\    out.local_pos = local;
    \\    out.content_size = content_size;
    \\    out.corner_radii = s.corner_radii;
    \\    out.blur_radius = s.blur_radius;
    \\    return out;
    \\}
    \\
    \\fragment float4 shadow_fragment(ShadowVertexOutput in [[stage_in]]) {
    \\    float2 half_size = in.content_size / 2.0;
    \\    float radius = pick_corner_radius(in.local_pos, in.corner_radii);
    \\    float dist = rounded_rect_sdf(in.local_pos, half_size, radius);
    \\    float alpha = shadow_falloff(dist, in.blur_radius);
    \\    return float4(in.color.rgb, in.color.a * alpha);
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
