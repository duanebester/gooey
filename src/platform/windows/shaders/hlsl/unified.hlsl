// Unified quad/shadow shader — HLSL port of shaders/unified.vert/.frag
// (src/platform/linux/shaders, GLSL 450). Keep the two in sync: the math is
// a line-by-line translation, with these D3D11 adaptations:
//   - StructuredBuffer t0 replaces the readonly storage buffer (binding 0).
//   - cbuffer b0 replaces the Uniforms UBO (binding 1); 16-byte layout
//     matches vk_types.Uniforms.
//   - SV_VertexID expands the same 6-vertex unit quad; no vertex buffers.
//   - NDC flip: Vulkan NDC is Y-down like scene pixels; D3D11 is Y-up, so
//     positions are negated in Y before output.
//   - PSIn redeclares SV_Position (unused by the PS logic): on some drivers
//     a PS input signature without SV_Position breaks VS→PS register
//     remapping — varyings read back as 0. The compiler keeps system-value
//     PS inputs even when unused, so the declaration alone is the fix.
// Compiled at renderer init via D3DCompile (see dx11_renderer.zig).

// Constants
static const uint PRIM_QUAD = 0;
static const uint PRIM_SHADOW = 1;

// Primitive data (structured buffer) — 128 bytes, flat f32/u32 fields,
// matches src/platform/unified.zig Primitive exactly.
struct Primitive {
    uint order;
    uint primitive_type;
    float bounds_origin_x;
    float bounds_origin_y;
    float bounds_size_width;
    float bounds_size_height;
    float blur_radius;
    float offset_x;
    // background (HSLA)
    float background_h;
    float background_s;
    float background_l;
    float background_a;
    // border_color (HSLA)
    float border_color_h;
    float border_color_s;
    float border_color_l;
    float border_color_a;
    // corner_radii
    float corner_radii_tl;
    float corner_radii_tr;
    float corner_radii_br;
    float corner_radii_bl;
    // border_widths
    float border_width_top;
    float border_width_right;
    float border_width_bottom;
    float border_width_left;
    // clip bounds
    float clip_origin_x;
    float clip_origin_y;
    float clip_size_width;
    float clip_size_height;
    // remaining
    float offset_y;
    float _pad1;
    float _pad2;
    float _pad3;
};

StructuredBuffer<Primitive> primitive_buffer : register(t0);

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

struct VSOut {
    float4 position : SV_Position;
    float4 color : TEXCOORD0;
    float4 border_color : TEXCOORD1;
    float2 quad_coord : TEXCOORD2;
    float2 quad_size : TEXCOORD3;
    float4 corner_radii : TEXCOORD4;
    float4 border_widths : TEXCOORD5;
    float4 clip_bounds : TEXCOORD6;
    float2 screen_pos : TEXCOORD7;
    float2 content_size : TEXCOORD8;
    float2 local_pos : TEXCOORD9;
    float blur_radius : TEXCOORD10;
    nointerpolation uint primitive_type : TEXCOORD11;
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
    Primitive p = primitive_buffer[iid];
    float2 viewport_size = float2(viewport_width, viewport_height);

    o.primitive_type = p.primitive_type;
    o.color = hsla_to_rgba(float4(p.background_h, p.background_s, p.background_l, p.background_a));
    o.border_color = hsla_to_rgba(float4(p.border_color_h, p.border_color_s, p.border_color_l, p.border_color_a));
    o.corner_radii = float4(p.corner_radii_tl, p.corner_radii_tr, p.corner_radii_br, p.corner_radii_bl);
    o.border_widths = float4(p.border_width_top, p.border_width_right, p.border_width_bottom, p.border_width_left);
    o.clip_bounds = float4(p.clip_origin_x, p.clip_origin_y, p.clip_size_width, p.clip_size_height);
    o.blur_radius = p.blur_radius;

    // D3D11 NDC is Y-up, scene pixels are Y-down: flip in Y.
    const float ndc_y_sign = -1.0;

    if (p.primitive_type == PRIM_QUAD) {
        float2 origin = float2(p.bounds_origin_x, p.bounds_origin_y);
        float2 size = float2(p.bounds_size_width, p.bounds_size_height);
        float2 pos = origin + unit * size;
        float2 ndc = pos / max(viewport_size, float2(1.0, 1.0)) * 2.0 - 1.0;

        o.position = float4(ndc.x, ndc.y * ndc_y_sign, 0.0, 1.0);
        o.quad_coord = unit;
        o.quad_size = size;
        o.screen_pos = pos;
        o.content_size = size;
        o.local_pos = float2(0.0, 0.0);
    } else {
        // Shadow primitive
        float expand = p.blur_radius * 2.0;
        float2 content_origin = float2(p.bounds_origin_x, p.bounds_origin_y);
        float2 content_size = float2(p.bounds_size_width, p.bounds_size_height);
        float2 offset = float2(p.offset_x, p.offset_y);
        float2 shadow_origin = content_origin + offset - expand;
        float2 shadow_size = content_size + expand * 2.0;
        float2 pos = shadow_origin + unit * shadow_size;
        float2 ndc = pos / max(viewport_size, float2(1.0, 1.0)) * 2.0 - 1.0;
        float2 local = (unit * shadow_size) - (shadow_size / 2.0) - offset;

        o.position = float4(ndc.x, ndc.y * ndc_y_sign, 0.0, 1.0);
        o.quad_coord = unit;
        o.quad_size = shadow_size;
        o.screen_pos = pos;
        o.content_size = content_size;
        o.local_pos = local;
    }
    return o;
}

struct PSIn {
    // Must be present in the PS input signature even though the PS logic
    // never reads it — see the file-header note on register remapping.
    float4 position : SV_Position;
    float4 color : TEXCOORD0;
    float4 border_color : TEXCOORD1;
    float2 quad_coord : TEXCOORD2;
    float2 quad_size : TEXCOORD3;
    float4 corner_radii : TEXCOORD4;
    float4 border_widths : TEXCOORD5;
    float4 clip_bounds : TEXCOORD6;
    float2 screen_pos : TEXCOORD7;
    float2 content_size : TEXCOORD8;
    float2 local_pos : TEXCOORD9;
    float blur_radius : TEXCOORD10;
    nointerpolation uint primitive_type : TEXCOORD11;
};

float rounded_rect_sdf(float2 pos, float2 half_size, float radius) {
    float2 d = abs(pos) - half_size + radius;
    return length(max(d, float2(0.0, 0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

float pick_corner_radius(float2 pos, float4 radii) {
    if (pos.x < 0.0) {
        if (pos.y < 0.0) { return radii.x; }  // top-left
        else { return radii.w; }              // bottom-left
    } else {
        if (pos.y < 0.0) { return radii.y; }  // top-right
        else { return radii.z; }              // bottom-right
    }
}

float shadow_falloff(float distance, float blur) {
    return 1.0 - smoothstep(-blur * 0.5, blur * 1.5, distance);
}

float4 ps_main(PSIn i) : SV_Target {
    if (i.primitive_type == PRIM_QUAD) {
        // Clip test
        float2 clip_min = i.clip_bounds.xy;
        float2 clip_max = clip_min + i.clip_bounds.zw;
        if (i.screen_pos.x < clip_min.x || i.screen_pos.x > clip_max.x ||
            i.screen_pos.y < clip_min.y || i.screen_pos.y > clip_max.y) {
            discard;
        }

        float2 size = i.quad_size;
        float2 half_size = size / 2.0;
        float2 pos = i.quad_coord * size;
        float2 centered = pos - half_size;

        float radius = pick_corner_radius(centered, i.corner_radii);
        float outer_dist = rounded_rect_sdf(centered, half_size, radius);

        float4 bw = i.border_widths;
        bool has_border = bw.x > 0.0 || bw.y > 0.0 || bw.z > 0.0 || bw.w > 0.0;

        float4 color = i.color;
        if (has_border) {
            // bw: x=top, y=right, z=bottom, w=left. Per-side inset of the
            // inner rounded rect handles per-side borders and rounded
            // corners uniformly (mirrors unified.frag).
            float2 inner_min = float2(-half_size.x + bw.w, -half_size.y + bw.x);
            float2 inner_max = float2(half_size.x - bw.y, half_size.y - bw.z);
            float2 inner_center = (inner_min + inner_max) * 0.5;
            float2 inner_half_size = max(float2(0.0, 0.0), (inner_max - inner_min) * 0.5);
            float2 inner_pos = centered - inner_center;

            // Per-corner inner radii: reduce by the max of the two adjacent
            // border widths.
            float4 cr = i.corner_radii;
            float4 inner_radii = float4(
                max(0.0, cr.x - max(bw.x, bw.w)),
                max(0.0, cr.y - max(bw.x, bw.y)),
                max(0.0, cr.z - max(bw.z, bw.y)),
                max(0.0, cr.w - max(bw.z, bw.w))
            );
            float inner_radius = pick_corner_radius(inner_pos, inner_radii);

            float inner_dist = rounded_rect_sdf(inner_pos, inner_half_size, inner_radius);
            float border_blend = smoothstep(-0.5, 0.5, inner_dist);
            color = lerp(i.color, i.border_color, border_blend);
        }

        float alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);
        return color * float4(1.0, 1.0, 1.0, alpha);
    } else {
        // Shadow primitive
        float2 half_size = i.content_size / 2.0;
        float radius = pick_corner_radius(i.local_pos, i.corner_radii);
        float dist = rounded_rect_sdf(i.local_pos, half_size, radius);
        float alpha = shadow_falloff(dist, i.blur_radius);
        return float4(i.color.rgb, i.color.a * alpha);
    }
}
