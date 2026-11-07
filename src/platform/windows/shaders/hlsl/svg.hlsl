// SVG shader — HLSL port of shaders/svg.vert/.frag
// (src/platform/linux/shaders, GLSL 450). Keep the two in sync. D3D11
// adaptations: StructuredBuffer t0 (SvgInstance), cbuffer b0 (Uniforms,
// 16 bytes matching vk_types.Uniforms), SV_VertexID unit-quad expansion,
// Y-up NDC flip. The SVG atlas is RGBA8: R = fill alpha, G = stroke alpha.
// Blend state for this pipeline is premultiplied-alpha
// (src=ONE, dst=ONE_MINUS_SRC_ALPHA — see vk_pipelines.zig BlendMode),
// which dx11_scene_renderer.zig mirrors. Compiled at renderer init via
// D3DCompile (see dx11_renderer.zig).

// SVG instance data — 80 bytes, 20 floats, matches
// src/platform/linux/vk_types.zig GpuSvg exactly.
struct SvgInstance {
    // Position and size
    float pos_x;
    float pos_y;
    float size_x;
    float size_y;
    // UV coordinates
    float uv_left;
    float uv_top;
    float uv_right;
    float uv_bottom;
    // Fill color (HSLA)
    float fill_h;
    float fill_s;
    float fill_l;
    float fill_a;
    // Stroke color (HSLA)
    float stroke_h;
    float stroke_s;
    float stroke_l;
    float stroke_a;
    // Clip bounds
    float clip_x;
    float clip_y;
    float clip_width;
    float clip_height;
};

StructuredBuffer<SvgInstance> svg_buffer : register(t0);

cbuffer Uniforms : register(b0) {
    float viewport_width;
    float viewport_height;
    float _pad0;
    float _pad1;
};

cbuffer DrawBase : register(b1) {
    uint base_iid;
    uint _padb1_0;
    uint _padb1_1;
    uint _padb1_2;
};

// SVG atlas texture (RGBA format): R = fill alpha, G = stroke alpha.
Texture2D svg_atlas : register(t1);
SamplerState svg_sampler : register(s0);

struct VSOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
    float4 fill_color : COLOR0;
    float4 stroke_color : COLOR1;
    float4 clip_bounds : TEXCOORD1;
    float2 screen_pos : TEXCOORD2;
};

// Unit quad vertices (6 vertices for 2 triangles)
float2 get_unit_vertex(uint vid) {
    switch (vid) {
        case 0: return float2(0.0, 0.0);
        case 1: return float2(1.0, 0.0);
        case 2: return float2(0.0, 1.0);
        case 3: return float2(1.0, 0.0);
        case 4: return float2(1.0, 1.0);
        case 5: return float2(0.0, 1.0);
        default: return float2(0.0, 0.0);
    }
}

float4 hsla_to_rgba(float4 hsla) {
    float h = hsla.x * 6.0;
    float s = hsla.y;
    float l = hsla.z;
    float a = hsla.w;

    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
    float m = l - c / 2.0;

    float3 rgb;
    if (h < 1.0) {
        rgb = float3(c, x, 0.0);
    } else if (h < 2.0) {
        rgb = float3(x, c, 0.0);
    } else if (h < 3.0) {
        rgb = float3(0.0, c, x);
    } else if (h < 4.0) {
        rgb = float3(0.0, x, c);
    } else if (h < 5.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }

    return float4(rgb + m, a);
}

VSOut vs_main(uint vertex_index : SV_VertexID) {
    VSOut o;
    uint vid = vertex_index % 6;
    // base_iid comes from b1: SV_VertexID does not include the draw's
    // StartVertexLocation on all drivers, so batch ranges are passed explicitly.
    uint iid = base_iid + vertex_index / 6;

    float2 unit = get_unit_vertex(vid);
    SvgInstance s = svg_buffer[iid];
    float2 viewport_size = float2(viewport_width, viewport_height);

    // Calculate screen position
    float2 pos = float2(s.pos_x, s.pos_y) + unit * float2(s.size_x, s.size_y);

    float2 ndc = pos / viewport_size * 2.0 - 1.0;

    // Interpolate UV coordinates
    float2 uv = float2(
        lerp(s.uv_left, s.uv_right, unit.x),
        lerp(s.uv_top, s.uv_bottom, unit.y)
    );

    // D3D11 NDC is Y-up, scene pixels are Y-down: flip in Y.
    o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.tex_coord = uv;
    o.fill_color = hsla_to_rgba(float4(s.fill_h, s.fill_s, s.fill_l, s.fill_a));
    o.stroke_color = hsla_to_rgba(float4(s.stroke_h, s.stroke_s, s.stroke_l, s.stroke_a));
    o.clip_bounds = float4(s.clip_x, s.clip_y, s.clip_width, s.clip_height);
    o.screen_pos = pos;
    return o;
}

struct PSIn {
    // Must be present even though the PS never reads it: a PS input
    // signature without SV_Position breaks VS→PS register remapping on
    // some drivers (varyings read back as 0). See unified.hlsl header.
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
    float4 fill_color : COLOR0;
    float4 stroke_color : COLOR1;
    float4 clip_bounds : TEXCOORD1;
    float2 screen_pos : TEXCOORD2;
};

float4 ps_main(PSIn i) : SV_Target {
    // Clip test
    float2 clip_min = i.clip_bounds.xy;
    float2 clip_max = clip_min + i.clip_bounds.zw;
    if (i.screen_pos.x < clip_min.x || i.screen_pos.x > clip_max.x ||
        i.screen_pos.y < clip_min.y || i.screen_pos.y > clip_max.y) {
        discard;
    }

    // Sample from RGBA atlas
    float4 sample_value = svg_atlas.Sample(svg_sampler, i.tex_coord);

    // Threshold to eliminate linear filtering bleed between channels
    float fill_alpha = sample_value.r > 0.02 ? sample_value.r : 0.0;
    float stroke_alpha = sample_value.g > 0.02 ? sample_value.g : 0.0;

    // Composite: stroke shows only where fill isn't
    float visible_stroke = stroke_alpha * (1.0 - fill_alpha);

    // Blend colors with their respective alphas
    float3 rgb = i.fill_color.rgb * i.fill_color.a * fill_alpha
               + i.stroke_color.rgb * i.stroke_color.a * visible_stroke;
    float alpha = i.fill_color.a * fill_alpha + i.stroke_color.a * visible_stroke;

    // Discard fully transparent pixels
    if (alpha < 0.001) {
        discard;
    }

    return float4(rgb, alpha);
}
