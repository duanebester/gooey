#version 450
#extension GL_GOOGLE_include_directive : require
#include "packed.glsl"

// The image pipeline: RGBA sprites with tint, rounding, grayscale, opacity.
layout(location = 0) out vec2 out_tex_coord;
layout(location = 1) out vec4 out_tint_rgba;
layout(location = 2) out vec2 out_screen_pos;
layout(location = 3) out vec2 out_image_origin;
layout(location = 4) out vec2 out_size;
layout(location = 5) out vec4 out_corner_radii;
layout(location = 6) out float out_grayscale;
layout(location = 7) out float out_opacity;

void main() {
    uint vid = uint(gl_VertexIndex) % 6u;
    uint iid = uint(gl_VertexIndex) / 6u;
    vec2 unit = unit_vertex(vid);
    Sprite s = sprites[iid];
    vec2 pos = s.bounds.xy + unit * s.bounds.zw;
    gl_Position = clip_position(pos);
    out_tex_coord = vec2(mix(s.uv.x, s.uv.z, unit.x), mix(s.uv.y, s.uv.w, unit.y));
    out_tint_rgba = s.tint;
    out_screen_pos = pos;
    out_image_origin = s.bounds.xy;
    out_size = s.bounds.zw;
    out_corner_radii = s.corners;
    out_grayscale = s.grayscale;
    out_opacity = s.opacity;
}
