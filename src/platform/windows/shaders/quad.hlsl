// Quads and shadows: the HLSL twin of the Vulkan renderer's unified.vert and
// unified.frag (src/platform/linux/shaders), reading packed-frame quads. The
// SDF math is a line-by-line translation; keep the two in step. A quad with
// blur > 0 is a shadow. Colours arrive straight, so the output is straight
// alpha for source-over blending with SRC_ALPHA.
// Clipping is the scissor rectangle the renderer sets per draw, so these
// shaders test no clip.
// Analytic anti-aliasing, not MSAA: the pixel shader fades each edge across
// one pixel, and the vertex shader grows each quad by a one-pixel fringe so
// the outer half of the fade is rasterized.
// The pixel shader's input repeats SV_Position: some drivers misassign the
// varyings of a pixel shader whose input signature lacks it.
// Rebuild the DXBC after editing: zig build compile-hlsl.

#include "common.hlsl"

StructuredBuffer<Quad> quads : register(t0);

struct Varyings {
    float4 position : SV_Position;
    nointerpolation uint shadow : SHADOW;
    float4 color : COLOR0;
    float4 border_color : COLOR1;
    float2 quad_coord : QUAD_COORD;
    float2 quad_size : QUAD_SIZE;
    float4 corner_radii : CORNER_RADII;
    float4 border_widths : BORDER_WIDTHS;
    float2 content_size : CONTENT_SIZE;
    float2 local_pos : LOCAL_POS;
    float blur_radius : BLUR_RADIUS;
};

Varyings vs_main(uint vid : SV_VertexID, uint instance : INSTANCE_INDEX) {
    float2 unit = unit_vertex(vid);
    Quad q = quads[instance];

    Varyings o;
    o.shadow = q.blur > 0.0 ? 1 : 0;
    o.color = q.fill;
    o.border_color = q.border_color;
    o.corner_radii = q.corners;
    o.border_widths = q.border_widths;
    o.blur_radius = q.blur;

    float2 origin = q.bounds.xy;
    float2 size = q.bounds.zw;
    if (o.shadow == 0) {
        // The fade spans [-0.5, +0.5] px of the edge; with one sample per
        // pixel the geometry must cover the outer half, so grow the quad by
        // one logical pixel. Empty quads stay empty.
        float fringe = (size.x > 0.0 && size.y > 0.0) ? 1.0 : 0.0;
        float2 pos = origin - fringe + unit * (size + 2.0 * fringe);
        o.position = pixel_to_clip(pos);
        o.quad_coord = pos - origin; // Outside [0, size] within the fringe.
        o.quad_size = size;
        o.content_size = size;
        o.local_pos = float2(0.0, 0.0);
    } else {
        float expand = q.blur * 2.0;
        float2 shadow_origin = origin + q.offset - expand;
        float2 shadow_size = size + expand * 2.0;
        float2 pos = shadow_origin + unit * shadow_size;
        o.position = pixel_to_clip(pos);
        o.quad_coord = unit;
        o.quad_size = shadow_size;
        o.content_size = size;
        o.local_pos = (unit * shadow_size) - (shadow_size / 2.0) - q.offset;
    }
    return o;
}

float rounded_rect_sdf(float2 pos, float2 half_size, float radius) {
    float2 d = abs(pos) - half_size + radius;
    return length(max(d, float2(0.0, 0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

float pick_corner_radius(float2 pos, float4 radii) {
    if (pos.x < 0.0) {
        return (pos.y < 0.0) ? radii.x : radii.w;
    }
    return (pos.y < 0.0) ? radii.y : radii.z;
}

float shadow_falloff(float distance, float blur) {
    return 1.0 - smoothstep(-blur * 0.5, blur * 1.5, distance);
}

float4 quad_color(Varyings i) {
    float2 half_size = i.quad_size / 2.0;
    float2 centered = i.quad_coord - half_size;
    float radius = pick_corner_radius(centered, i.corner_radii);
    float outer_dist = rounded_rect_sdf(centered, half_size, radius);

    float4 bw = i.border_widths;
    float4 color = i.color;
    if (bw.x > 0.0 || bw.y > 0.0 || bw.z > 0.0 || bw.w > 0.0) {
        // Inset each side independently, so per-side borders and uniform
        // borders on rounded corners share one inner rounded rect.
        float2 inner_min = float2(-half_size.x + bw.w, -half_size.y + bw.x);
        float2 inner_max = float2(half_size.x - bw.y, half_size.y - bw.z);
        float2 inner_center = (inner_min + inner_max) * 0.5;
        float2 inner_half_size = max(float2(0.0, 0.0), (inner_max - inner_min) * 0.5);
        float2 inner_pos = centered - inner_center;

        // Each inner radius shrinks by the wider of its two adjacent borders.
        float4 cr = i.corner_radii;
        float4 inner_radii = float4(
            max(0.0, cr.x - max(bw.x, bw.w)),
            max(0.0, cr.y - max(bw.x, bw.y)),
            max(0.0, cr.z - max(bw.z, bw.y)),
            max(0.0, cr.w - max(bw.z, bw.w)));
        float inner_radius = pick_corner_radius(inner_pos, inner_radii);
        float inner_dist = rounded_rect_sdf(inner_pos, inner_half_size, inner_radius);
        color = lerp(i.color, i.border_color, smoothstep(-0.5, 0.5, inner_dist));
    }

    float alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);
    if (alpha <= 0.0) {
        discard;
    }
    return color * float4(1.0, 1.0, 1.0, alpha);
}

float4 shadow_color(Varyings i) {
    float2 half_size = i.content_size / 2.0;
    float radius = pick_corner_radius(i.local_pos, i.corner_radii);
    float dist = rounded_rect_sdf(i.local_pos, half_size, radius);
    float alpha = shadow_falloff(dist, i.blur_radius);
    return float4(i.color.rgb, i.color.a * alpha);
}

float4 ps_main(Varyings i) : SV_Target {
    if (i.shadow == 0) {
        return quad_color(i);
    }
    return shadow_color(i);
}
