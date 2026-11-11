#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec2 screen_pos;
layout(location = 3) flat out uint circle;
layout(location = 4) out vec4 edge_distance;
layout(location = 5) flat out uint edge_modes;

// Point `i` (the instance) is a circle of radius `width` around the mesh's
// point i.
void main() {
    Mesh mesh = meshes[draw.mesh];
    vec2 center = mesh_points[mesh.first + uint(gl_InstanceIndex)];
    float radius = mesh.width;
    // The quad reaches `aa_fringe` past the radius so mesh.frag's falloff can
    // straddle the circle's edge; uv stays 1.0 at the radius. Zero-radius
    // points keep a degenerate quad and draw nothing.
    float extent = radius > 0.0 ? radius + aa_fringe : 0.0;
    vec2 unit = corner(uint(gl_VertexIndex));
    uv = unit * extent / max(radius, 1e-6);
    screen_pos = center + unit * extent;
    gl_Position = clip_position(screen_pos);
    color = mesh.fill;
    circle = 1u;
    // The circular falloff in mesh.frag anti-aliases points; no straight edges.
    edge_distance = vec4(1e4);
    edge_modes = 0u;
}
