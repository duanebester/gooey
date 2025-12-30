#version 450

// Constants
const uint PRIM_QUAD = 0u;
const uint PRIM_SHADOW = 1u;

// Primitive data (storage buffer)
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

layout(set = 0, binding = 0) readonly buffer PrimitiveBuffer {
    Primitive primitives[];
};

layout(set = 0, binding = 1) uniform Uniforms {
    float viewport_width;
    float viewport_height;
};

// Outputs to fragment shader
layout(location = 0) flat out uint out_primitive_type;
layout(location = 1) out vec4 out_color;
layout(location = 2) out vec4 out_border_color;
layout(location = 3) out vec2 out_quad_coord;
layout(location = 4) out vec2 out_quad_size;
layout(location = 5) out vec4 out_corner_radii;
layout(location = 6) out vec4 out_border_widths;
layout(location = 7) out vec4 out_clip_bounds;
layout(location = 8) out vec2 out_screen_pos;
layout(location = 9) out vec2 out_content_size;
layout(location = 10) out vec2 out_local_pos;
layout(location = 11) out float out_blur_radius;

// Unit quad vertices (6 vertices for 2 triangles)
vec2 get_unit_vertex(uint vid) {
    switch (vid) {
        case 0u: return vec2(0.0, 0.0);
        case 1u: return vec2(1.0, 0.0);
        case 2u: return vec2(0.0, 1.0);
        case 3u: return vec2(1.0, 0.0);
        case 4u: return vec2(1.0, 1.0);
        case 5u: return vec2(0.0, 1.0);
        default: return vec2(0.0, 0.0);
    }
}

vec4 hsla_to_rgba(vec4 hsla) {
    float h = hsla.x * 6.0;
    float s = hsla.y;
    float l = hsla.z;
    float a = hsla.w;

    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float x = c * (1.0 - abs(mod(h, 2.0) - 1.0));
    float m = l - c / 2.0;

    vec3 rgb;
    if (h < 1.0) {
        rgb = vec3(c, x, 0.0);
    } else if (h < 2.0) {
        rgb = vec3(x, c, 0.0);
    } else if (h < 3.0) {
        rgb = vec3(0.0, c, x);
    } else if (h < 4.0) {
        rgb = vec3(0.0, x, c);
    } else if (h < 5.0) {
        rgb = vec3(x, 0.0, c);
    } else {
        rgb = vec3(c, 0.0, x);
    }

    return vec4(rgb + m, a);
}

void main() {
    uint vid = gl_VertexIndex % 6u;
    uint iid = gl_VertexIndex / 6u;

    vec2 unit = get_unit_vertex(vid);
    Primitive p = primitives[iid];
    vec2 viewport_size = vec2(viewport_width, viewport_height);

    out_primitive_type = p.primitive_type;
    out_color = hsla_to_rgba(vec4(p.background_h, p.background_s, p.background_l, p.background_a));
    out_border_color = hsla_to_rgba(vec4(p.border_color_h, p.border_color_s, p.border_color_l, p.border_color_a));
    out_corner_radii = vec4(p.corner_radii_tl, p.corner_radii_tr, p.corner_radii_br, p.corner_radii_bl);
    out_border_widths = vec4(p.border_width_top, p.border_width_right, p.border_width_bottom, p.border_width_left);
    out_clip_bounds = vec4(p.clip_origin_x, p.clip_origin_y, p.clip_size_width, p.clip_size_height);
    out_blur_radius = p.blur_radius;

    if (p.primitive_type == PRIM_QUAD) {
        vec2 origin = vec2(p.bounds_origin_x, p.bounds_origin_y);
        vec2 size = vec2(p.bounds_size_width, p.bounds_size_height);
        vec2 pos = origin + unit * size;
        vec2 ndc = pos / viewport_size * vec2(2.0, -2.0) + vec2(-1.0, 1.0);

        gl_Position = vec4(ndc, 0.0, 1.0);
        out_quad_coord = unit;
        out_quad_size = size;
        out_screen_pos = pos;
        out_content_size = size;
        out_local_pos = vec2(0.0, 0.0);
    } else {
        // Shadow primitive
        float expand = p.blur_radius * 2.0;
        vec2 content_origin = vec2(p.bounds_origin_x, p.bounds_origin_y);
        vec2 content_size = vec2(p.bounds_size_width, p.bounds_size_height);
        vec2 offset = vec2(p.offset_x, p.offset_y);
        vec2 shadow_origin = content_origin + offset - expand;
        vec2 shadow_size = content_size + expand * 2.0;
        vec2 pos = shadow_origin + unit * shadow_size;
        vec2 ndc = pos / viewport_size * vec2(2.0, -2.0) + vec2(-1.0, 1.0);
        vec2 local = (unit * shadow_size) - (shadow_size / 2.0) - offset;

        gl_Position = vec4(ndc, 0.0, 1.0);
        out_quad_coord = unit;
        out_quad_size = shadow_size;
        out_screen_pos = pos;
        out_content_size = content_size;
        out_local_pos = local;
    }
}
