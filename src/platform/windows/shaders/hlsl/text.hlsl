// Text glyph shader — HLSL port of shaders/text.vert/.frag
// (src/platform/linux/shaders, GLSL 450). Keep the two in sync. D3D11
// adaptations: StructuredBuffer t0 (GlyphInstance), cbuffer b0 (Uniforms,
// 16 bytes matching vk_types.Uniforms), SV_VertexID unit-quad expansion,
// Y-up NDC flip. The atlas is R8_UNORM (coverage in the red channel),
// sampled with a separate sampler state. Compiled at renderer init via
// D3DCompile (see dx11_renderer.zig).

// Glyph instance data — 64 bytes, 16 floats, matches
// src/platform/linux/vk_types.zig GpuGlyph exactly.
struct GlyphInstance {
    float pos_x;
    float pos_y;
    float size_x;
    float size_y;
    float uv_left;
    float uv_top;
    float uv_right;
    float uv_bottom;
    float color_h;
    float color_s;
    float color_l;
    float color_a;
    float clip_x;
    float clip_y;
    float clip_width;
    float clip_height;
};

StructuredBuffer<GlyphInstance> glyph_buffer : register(t0);

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

// Atlas texture (R8 format — single channel alpha). Separate SRV + sampler
// registers because the D3D11 renderer binds them independently
// (dx11_scene_renderer.zig).
Texture2D atlas_texture : register(t1);
SamplerState atlas_sampler : register(s0);

struct VSOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
    float4 color : COLOR0;
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
    GlyphInstance g = glyph_buffer[iid];
    float2 viewport_size = float2(viewport_width, viewport_height);

    float2 pos = float2(g.pos_x, g.pos_y) + unit * float2(g.size_x, g.size_y);
    float2 ndc = pos / viewport_size * 2.0 - 1.0;
    float2 uv = float2(
        lerp(g.uv_left, g.uv_right, unit.x),
        lerp(g.uv_top, g.uv_bottom, unit.y)  // Match macOS Metal shader - no flip
    );

    // D3D11 NDC is Y-up, scene pixels are Y-down: flip in Y.
    o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.tex_coord = uv;
    o.color = hsla_to_rgba(float4(g.color_h, g.color_s, g.color_l, g.color_a));
    o.clip_bounds = float4(g.clip_x, g.clip_y, g.clip_width, g.clip_height);
    o.screen_pos = pos;
    return o;
}

struct PSIn {
    // Must be present even though the PS never reads it: a PS input
    // signature without SV_Position breaks VS→PS register remapping on
    // some drivers (varyings read back as 0). See unified.hlsl header.
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
    float4 color : COLOR0;
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

    // Sample alpha from atlas (R8 texture — alpha in red channel)
    float alpha = atlas_texture.Sample(atlas_sampler, i.tex_coord).r;

    // Output color with sampled alpha
    return float4(i.color.rgb, i.color.a * alpha);
}
