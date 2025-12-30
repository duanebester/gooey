#version 450

// Glyph instance data (storage buffer)
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

layout(set = 0, binding = 0) readonly buffer GlyphBuffer {
    GlyphInstance glyphs[];
};

layout(set = 0, binding = 1) uniform Uniforms {
    float viewport_width;
    float viewport_height;
};

// Outputs to fragment shader
layout(location = 0) out vec2 out_tex_coord;
layout(location = 1) out vec4 out_color;
layout(location = 2) out vec4 out_clip_bounds;
layout(location = 3) out vec2 out_screen_pos;

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
    GlyphInstance g = glyphs[iid];
    vec2 viewport_size = vec2(viewport_width, viewport_height);

    vec2 pos = vec2(g.pos_x, g.pos_y) + unit * vec2(g.size_x, g.size_y);
    vec2 ndc = pos / viewport_size * vec2(2.0, -2.0) + vec2(-1.0, 1.0);
    vec2 uv = vec2(
        mix(g.uv_left, g.uv_right, unit.x),
        mix(g.uv_top, g.uv_bottom, unit.y)  // Match macOS Metal shader - no flip
    );

    gl_Position = vec4(ndc, 0.0, 1.0);
    out_tex_coord = uv;
    out_color = hsla_to_rgba(vec4(g.color_h, g.color_s, g.color_l, g.color_a));
    out_clip_bounds = vec4(g.clip_x, g.clip_y, g.clip_width, g.clip_height);
    out_screen_pos = pos;
}
