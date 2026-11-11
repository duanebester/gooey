#version 450
#extension GL_GOOGLE_include_directive : require
#include "packed.glsl"

// The quad pipeline: SDF quads, and shadows (quads with blur > 0).
layout(location = 0) flat out uint out_shadow;
layout(location = 1) out vec4 out_color;
layout(location = 2) out vec4 out_border_color;
layout(location = 3) out vec2 out_quad_coord;
layout(location = 4) out vec2 out_quad_size;
layout(location = 5) out vec4 out_corner_radii;
layout(location = 6) out vec4 out_border_widths;
layout(location = 7) out vec2 out_content_size;
layout(location = 8) out vec2 out_local_pos;
layout(location = 9) out float out_blur_radius;

void main() {
    uint vid = uint(gl_VertexIndex) % 6u;
    uint iid = uint(gl_VertexIndex) / 6u;
    vec2 unit = unit_vertex(vid);
    Quad q = quads[iid];

    out_shadow = q.blur > 0.0 ? 1u : 0u;
    out_color = q.fill;
    out_border_color = q.border_color;
    out_corner_radii = q.corners;
    out_border_widths = q.border_widths;
    out_blur_radius = q.blur;

    vec2 origin = q.bounds.xy;
    vec2 size = q.bounds.zw;
    if (out_shadow == 0u) {
        // The fragment shader fades across [-0.5, +0.5] px of the edge. With one
        // sample per pixel the geometry must cover the outer half too, so grow
        // the quad by one logical pixel; empty quads stay empty.
        float fringe = (size.x > 0.0 && size.y > 0.0) ? 1.0 : 0.0;
        vec2 pos = origin - fringe + unit * (size + 2.0 * fringe);
        gl_Position = clip_position(pos);
        // Quad-local position in pixels; outside [0, size] within the fringe.
        out_quad_coord = pos - origin;
        out_quad_size = size;
        out_content_size = size;
        out_local_pos = vec2(0.0);
    } else {
        float expand = q.blur * 2.0;
        vec2 offset = vec2(q.offset_x, q.offset_y);
        vec2 shadow_size = size + expand * 2.0;
        vec2 pos = origin + offset - expand + unit * shadow_size;
        gl_Position = clip_position(pos);
        out_quad_coord = unit;
        out_quad_size = shadow_size;
        out_content_size = size;
        out_local_pos = (unit * shadow_size) - (shadow_size / 2.0) - offset;
    }
}
