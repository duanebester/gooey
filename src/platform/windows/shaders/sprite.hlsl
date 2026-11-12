// Sprites: the HLSL twins of the Vulkan renderer's text, svg, and image
// shaders (src/platform/linux/shaders), reading packed-frame sprites. One
// vertex shader serves the three atlases; each has its own pixel shader:
//   ps_glyph: R8 coverage times the tint; straight alpha.
//   ps_svg:   R is fill coverage and G stroke coverage; the stroke shows only
//             where the fill does not. Premultiplied output.
//   ps_image: straight RGBA times the tint, with grayscale, opacity, and
//             anti-aliased rounded corners; straight alpha.
// Clipping is the scissor rectangle the renderer sets per draw.
// Rebuild the DXBC after editing: zig build compile-hlsl.

#include "common.hlsl"

StructuredBuffer<Sprite> sprites : register(t0);
Texture2D atlas : register(t3);
SamplerState atlas_sampler : register(s0);

struct Varyings {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
    float4 tint : COLOR0;
    float4 secondary : COLOR1;
    float2 local_pos : LOCAL_POS; // Pixels from the sprite's top left.
    float2 size : SIZE;
    float4 corner_radii : CORNER_RADII;
    float grayscale : GRAYSCALE;
    float opacity : OPACITY;
};

Varyings vs_main(uint vid : SV_VertexID, uint instance : INSTANCE_INDEX) {
    float2 unit = unit_vertex(vid);
    Sprite s = sprites[instance];
    float2 pos = s.bounds.xy + unit * s.bounds.zw;

    Varyings o;
    o.position = pixel_to_clip(pos);
    o.tex_coord = float2(lerp(s.uv.x, s.uv.z, unit.x), lerp(s.uv.y, s.uv.w, unit.y));
    o.tint = s.tint;
    o.secondary = s.secondary;
    o.local_pos = unit * s.bounds.zw;
    o.size = s.bounds.zw;
    o.corner_radii = s.corners;
    o.grayscale = s.grayscale;
    o.opacity = s.opacity;
    return o;
}

float4 ps_glyph(Varyings i) : SV_Target {
    float alpha = atlas.Sample(atlas_sampler, i.tex_coord).r;
    return float4(i.tint.rgb, i.tint.a * alpha);
}

float4 ps_svg(Varyings i) : SV_Target {
    float4 sample_value = atlas.Sample(atlas_sampler, i.tex_coord);
    // Threshold to eliminate linear filtering bleed between channels.
    float fill_alpha = sample_value.r > 0.02 ? sample_value.r : 0.0;
    float stroke_alpha = sample_value.g > 0.02 ? sample_value.g : 0.0;
    float visible_stroke = stroke_alpha * (1.0 - fill_alpha);
    float3 rgb = i.tint.rgb * i.tint.a * fill_alpha +
        i.secondary.rgb * i.secondary.a * visible_stroke;
    float alpha = i.tint.a * fill_alpha + i.secondary.a * visible_stroke;
    if (alpha < 0.001) {
        discard;
    }
    return float4(rgb, alpha);
}

float rounded_rect_sdf(float2 pos, float2 half_size, float4 radii) {
    // radii: x top left, y top right, z bottom right, w bottom left.
    float r;
    if (pos.x > 0.0) {
        r = (pos.y > 0.0) ? radii.z : radii.y;
    } else {
        r = (pos.y > 0.0) ? radii.w : radii.x;
    }
    float2 q = abs(pos) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0, 0.0))) - r;
}

float4 ps_image(Varyings i) : SV_Target {
    // Sampled before any discard: implicit derivatives are undefined after
    // a non-uniform one.
    float4 color = atlas.Sample(atlas_sampler, i.tex_coord);
    float corner_alpha = 1.0;
    float4 r = i.corner_radii;
    if (max(max(r.x, r.y), max(r.z, r.w)) > 0.0) {
        float2 half_size = i.size * 0.5;
        float dist = rounded_rect_sdf(i.local_pos - half_size, half_size, r);
        corner_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
        if (corner_alpha < 0.001) {
            discard;
        }
    }
    if (i.grayscale > 0.0) {
        float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
        color.rgb = lerp(color.rgb, float3(gray, gray, gray), i.grayscale);
    }
    color *= i.tint;
    color.a *= corner_alpha * i.opacity;
    if (color.a < 0.001) {
        discard;
    }
    return color;
}
