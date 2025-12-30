#version 450

// Image instance data (storage buffer)
// Must match GpuImage layout exactly (96 bytes, 24 floats)
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

layout(set = 0, binding = 0) readonly buffer ImageBuffer {
    ImageInstance images[];
};

layout(set = 0, binding = 1) uniform Uniforms {
    float viewport_width;
    float viewport_height;
};

// Outputs to fragment shader
layout(location = 0) out vec2 out_tex_coord;
layout(location = 1) out vec4 out_tint_rgba;
layout(location = 2) out vec4 out_clip_bounds;
layout(location = 3) out vec2 out_screen_pos;
layout(location = 4) out vec2 out_image_origin;
layout(location = 5) out vec2 out_size;
layout(location = 6) out vec4 out_corner_radii;
layout(location = 7) out float out_grayscale;
layout(location = 8) out float out_opacity;

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
    ImageInstance img = images[iid];
    vec2 viewport_size = vec2(viewport_width, viewport_height);

    // Calculate screen position
    vec2 pos = vec2(img.pos_x, img.pos_y) + unit * vec2(img.dest_width, img.dest_height);

    // Convert to NDC (Y flipped for Vulkan)
    vec2 ndc = pos / viewport_size * vec2(2.0, -2.0) + vec2(-1.0, 1.0);

    // Interpolate UV coordinates
    vec2 uv = vec2(
        mix(img.uv_left, img.uv_right, unit.x),
        mix(img.uv_top, img.uv_bottom, unit.y)
    );

    gl_Position = vec4(ndc, 0.0, 1.0);
    out_tex_coord = uv;
    out_tint_rgba = hsla_to_rgba(vec4(img.tint_h, img.tint_s, img.tint_l, img.tint_a));
    out_clip_bounds = vec4(img.clip_x, img.clip_y, img.clip_width, img.clip_height);
    out_screen_pos = pos;
    out_image_origin = vec2(img.pos_x, img.pos_y);
    out_size = vec2(img.dest_width, img.dest_height);
    out_corner_radii = vec4(img.corner_tl, img.corner_tr, img.corner_br, img.corner_bl);
    out_grayscale = img.grayscale;
    out_opacity = img.opacity;
}
