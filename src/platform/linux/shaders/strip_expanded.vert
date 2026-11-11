#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec2 screen_pos;
layout(location = 3) flat out uint circle;
layout(location = 4) out vec4 edge_distance;
layout(location = 5) flat out uint edge_modes;

// Segments are independent butt-ended quads, like Metal's. The sides of every
// segment fade; only the line's first start cap and last end cap fade, so the
// hard joints of consecutive segments still overlap without a seam.
// Segment `i` (the instance) joins the mesh's points i and i + 1; `width`
// is the line's full width.
void main() {
    Mesh mesh = meshes[draw.mesh];
    uint segment = uint(gl_InstanceIndex);
    uint segment_count = mesh.count - 1u;
    float radius = mesh.width * 0.5;
    vec2 start = mesh_points[mesh.first + segment];
    vec2 end = mesh_points[mesh.first + segment + 1u];
    vec2 direction = end - start;
    float distance = length(direction);
    // Zero-length segments keep their degenerate quad: they cover no pixels.
    vec2 along_unit = vec2(1, 0);
    vec2 across_unit = vec2(0, 1);
    bool has_length = distance > 0.0001;
    if (has_length) {
        along_unit = direction / distance;
        across_unit = vec2(-along_unit.y, along_unit.x);
    }
    bool cap_start = has_length && segment == 0u;
    bool cap_end = has_length && segment + 1u == segment_count;
    vec2 unit = corner(uint(gl_VertexIndex));
    float across = unit.y * (radius + aa_fringe);
    float along = unit.x < 0.0 ? (cap_start ? -aa_fringe : 0.0) :
        distance + (cap_end ? aa_fringe : 0.0);
    screen_pos = start + along_unit * along + across_unit * across;
    gl_Position = clip_position(screen_pos);
    uv = vec2(0);
    color = mesh.fill;
    circle = 0u;
    edge_distance = vec4(radius + across, radius - across, along, distance - along);
    edge_modes = 1u | (1u << 2u) | (cap_start ? 1u << 4u : 0u) | (cap_end ? 1u << 6u : 0u);
}
