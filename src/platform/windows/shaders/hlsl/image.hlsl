// Image shader — HLSL port of shaders/image.vert/.frag
// (src/platform/linux/shaders, GLSL 450). Keep the two in sync. D3D11
// adaptations: StructuredBuffer t0 (ImageInstance), cbuffer b0 (Uniforms,
// 16 bytes matching vk_types.Uniforms), SV_VertexID unit-quad expansion,
// Y-up NDC flip. The image atlas is RGBA8 full color. Compiled at renderer
// init via D3DCompile (see dx11_renderer.zig).

// Image instance data — 96 bytes, 24 floats, matches
// src/platform/linux/vk_types.zig GpuImage exactly.
struct ImageInstance {
    // Position and size
    float pos_x;
    float pos_y;
    float dest_width;
    float dest_height;
    // UV coordinates
    float uv_left;
    float uv_top;
    float uv_right;
    float uv_bottom;
    // Tint color (HSLA)
    float tint_h;
    float tint_s;
    float tint_l;
    float tint_a;
    // Clip bounds
    float clip_x;
    float clip_y;
    float clip_width;
    float clip_height;
    // Corner radii
    float corner_tl;
    float corner_tr;
    float corner_br;
    float corner_bl;
    // Effects
    float grayscale;
    float opacity;
    float _pad0;
    float _pad1;
};

StructuredBuffer<ImageInstance> image_buffer : register(t0);

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

// Image atlas texture (RGBA format).
Texture2D image_atlas : register(t1);
SamplerState image_sampler : register(s0);

struct VSOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
    float4 tint_rgba : COLOR0;
    float4 clip_bounds : TEXCOORD1;
    float2 screen_pos : TEXCOORD2;
    float2 image_origin : TEXCOORD3;
    float2 size : TEXCOORD4;
    float4 corner_radii : TEXCOORD5;
    float grayscale : TEXCOORD6;
    float opacity : TEXCOORD7;
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
    ImageInstance img = image_buffer[iid];
    float2 viewport_size = float2(viewport_width, viewport_height);

    // Calculate screen position
    float2 pos = float2(img.pos_x, img.pos_y) + unit * float2(img.dest_width, img.dest_height);

    float2 ndc = pos / viewport_size * 2.0 - 1.0;

    // Interpolate UV coordinates
    float2 uv = float2(
        lerp(img.uv_left, img.uv_right, unit.x),
        lerp(img.uv_top, img.uv_bottom, unit.y)
    );

    // D3D11 NDC is Y-up, scene pixels are Y-down: flip in Y.
    o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.tex_coord = uv;
    o.tint_rgba = hsla_to_rgba(float4(img.tint_h, img.tint_s, img.tint_l, img.tint_a));
    o.clip_bounds = float4(img.clip_x, img.clip_y, img.clip_width, img.clip_height);
    o.screen_pos = pos;
    o.image_origin = float2(img.pos_x, img.pos_y);
    o.size = float2(img.dest_width, img.dest_height);
    o.corner_radii = float4(img.corner_tl, img.corner_tr, img.corner_br, img.corner_bl);
    o.grayscale = img.grayscale;
    o.opacity = img.opacity;
    return o;
}

struct PSIn {
    // Must be present even though the PS never reads it: a PS input
    // signature without SV_Position breaks VS→PS register remapping on
    // some drivers (varyings read back as 0). See unified.hlsl header.
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
    float4 tint_rgba : COLOR0;
    float4 clip_bounds : TEXCOORD1;
    float2 screen_pos : TEXCOORD2;
    float2 image_origin : TEXCOORD3;
    float2 size : TEXCOORD4;
    float4 corner_radii : TEXCOORD5;
    float grayscale : TEXCOORD6;
    float opacity : TEXCOORD7;
};

// Signed distance function for rounded rectangle
float roundedRectSDF(float2 pos, float2 half_size, float4 radii) {
    // Select correct corner radius based on quadrant
    // radii: x=TL, y=TR, z=BR, w=BL
    float r;
    if (pos.x > 0.0) {
        r = (pos.y > 0.0) ? radii.z : radii.y;  // BR : TR
    } else {
        r = (pos.y > 0.0) ? radii.w : radii.x;  // BL : TL
    }

    float2 q = abs(pos) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

float4 ps_main(PSIn i) : SV_Target {
    // Clip test
    float2 clip_min = i.clip_bounds.xy;
    float2 clip_max = clip_min + i.clip_bounds.zw;
    if (i.screen_pos.x < clip_min.x || i.screen_pos.x > clip_max.x ||
        i.screen_pos.y < clip_min.y || i.screen_pos.y > clip_max.y) {
        discard;
    }

    // Rounded corners with anti-aliasing
    float corner_alpha = 1.0;
    float max_radius = max(max(i.corner_radii.x, i.corner_radii.y),
                          max(i.corner_radii.z, i.corner_radii.w));
    if (max_radius > 0.0) {
        float2 half_size = i.size * 0.5;
        // Compute position relative to image center
        float2 local_pos = i.screen_pos - i.image_origin - half_size;

        float dist = roundedRectSDF(local_pos, half_size, i.corner_radii);
        // Smooth anti-aliased edge (1px transition)
        corner_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
        if (corner_alpha < 0.001) {
            discard;
        }
    }

    // Sample texture
    float4 color = image_atlas.Sample(image_sampler, i.tex_coord);

    // Apply grayscale effect
    if (i.grayscale > 0.0) {
        float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
        color.rgb = lerp(color.rgb, float3(gray, gray, gray), i.grayscale);
    }

    // Apply tint (multiply blend)
    color *= i.tint_rgba;

    // Apply corner anti-aliasing and opacity
    color.a *= corner_alpha * i.opacity;

    if (color.a < 0.001) {
        discard;
    }

    return color;
}
