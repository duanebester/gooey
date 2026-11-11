#version 450
#extension GL_GOOGLE_include_directive : require
#include "packed.glsl"

// The SVG pipeline: two-colour sprites (fill in red, stroke in green).
layout(location = 0) out vec2 out_tex_coord;
layout(location = 1) out vec4 out_fill_color;
layout(location = 2) out vec4 out_stroke_color;

void main() {
    uint vid = uint(gl_VertexIndex) % 6u;
    uint iid = uint(gl_VertexIndex) / 6u;
    vec2 unit = unit_vertex(vid);
    Sprite s = sprites[iid];
    vec2 pos = s.bounds.xy + unit * s.bounds.zw;
    gl_Position = clip_position(pos);
    out_tex_coord = vec2(mix(s.uv.x, s.uv.z, unit.x), mix(s.uv.y, s.uv.w, unit.y));
    out_fill_color = s.tint;
    out_stroke_color = s.secondary;
}
