#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec2 screen_pos;
layout(location = 3) flat out uint circle;
layout(location = 4) out vec4 edge_distance;
layout(location = 5) flat out uint edge_modes;

void main() {
    uint stride = mesh.colored == 0u ? 2u : 6u;
    uint offset = uint(gl_InstanceIndex) * stride;
    vec2 center = vec2(mesh.data[offset], mesh.data[offset + 1u]);
    // The quad reaches `aa_fringe` past the radius so mesh.frag's falloff can
    // straddle the circle's edge; uv stays 1.0 at the radius. Zero-radius
    // points keep a degenerate quad and draw nothing.
    float extent = mesh.radius > 0.0 ? mesh.radius + aa_fringe : 0.0;
    vec2 unit = corner(uint(gl_VertexIndex));
    uv = unit * extent / max(mesh.radius, 1e-6);
    screen_pos = center + unit * extent;
    gl_Position = vec4(screen_pos / viewport.size * 2.0 - 1.0, 0, 1);
    vec4 hsla = mesh.color;
    if (mesh.colored != 0u) {
        hsla = vec4(mesh.data[offset + 2u], mesh.data[offset + 3u],
            mesh.data[offset + 4u], mesh.data[offset + 5u]);
    }
    color = hsla_to_rgba(hsla);
    circle = 1u;
    // The circular falloff in mesh.frag anti-aliases points; no straight edges.
    edge_distance = vec4(1e4);
    edge_modes = 0u;
}
