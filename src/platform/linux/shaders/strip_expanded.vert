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
void main() {
    uint segment = uint(gl_InstanceIndex);
    uint segment_count = uint(mesh.params.x + 0.5);
    uint offset = segment * 2u;
    vec2 start = vec2(mesh.data[offset], mesh.data[offset + 1u]);
    vec2 end = vec2(mesh.data[offset + 2u], mesh.data[offset + 3u]);
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
    float across = unit.y * (mesh.radius + aa_fringe);
    float along = unit.x < 0.0 ? (cap_start ? -aa_fringe : 0.0) :
        distance + (cap_end ? aa_fringe : 0.0);
    screen_pos = start + along_unit * along + across_unit * across;
    gl_Position = vec4(screen_pos / viewport.size * 2.0 - 1.0, 0, 1);
    uv = vec2(0);
    color = hsla_to_rgba(mesh.color);
    circle = 0u;
    edge_distance = vec4(mesh.radius + across, mesh.radius - across, along, distance - along);
    edge_modes = 1u | (1u << 2u) | (cap_start ? 1u << 4u : 0u) | (cap_end ? 1u << 6u : 0u);
}
