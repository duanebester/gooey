#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec2 screen_pos;
layout(location = 3) flat out uint circle;
layout(location = 4) out vec4 edge_distance;
layout(location = 5) flat out uint edge_modes;

const uint triangle_draw_vertex_count = 21u;
const uint fringe_vertex_count = 6u;
const float miter_max = 4.0 * aa_fringe;

vec2 corner_shift(uint k, uint modes, vec2 normals[3]) {
    uint before = (k + 2u) % 3u;
    float offset_k = ((modes >> (2u * k)) & 3u) != 0u ? aa_fringe : 0.0;
    float offset_before = ((modes >> (2u * before)) & 3u) != 0u ? aa_fringe : 0.0;
    vec2 n0 = normals[k];
    vec2 n1 = normals[before];
    float det = n0.x * n1.y - n0.y * n1.x;
    vec2 shift = vec2(0);
    if (abs(det) > 1e-4) {
        shift = vec2(-offset_k * n1.y + offset_before * n0.y,
            -offset_before * n0.x + offset_k * n1.x) / det;
    } else {
        shift = -max(offset_k, offset_before) * n0;
    }
    float shift_length = length(shift);
    if (shift_length > miter_max) { shift *= miter_max / shift_length; }
    return shift;
}

void main() {
    Mesh mesh = meshes[draw.mesh];
    uint triangle = uint(gl_VertexIndex) / triangle_draw_vertex_count;
    uint slot = uint(gl_VertexIndex) - triangle * triangle_draw_vertex_count;
    uint first = mesh.first + triangle * 3u;
    vec2 corners[3] = vec2[3](mesh_points[first], mesh_points[first + 1u],
        mesh_points[first + 2u]);
    uint modes = triangle_edge_modes[mesh.edge_first + triangle];
    edge_modes = modes;
    color = mesh.fill;
    circle = 0u;
    uv = vec2(0.0);

    float area = (corners[1].x - corners[0].x) * (corners[2].y - corners[0].y) -
        (corners[1].y - corners[0].y) * (corners[2].x - corners[0].x);
    vec2 normals[3];
    float lengths[3];
    for (uint edge = 0u; edge < 3u; ++edge) {
        vec2 direction = corners[(edge + 1u) % 3u] - corners[edge];
        lengths[edge] = length(direction);
        normals[edge] = vec2(-direction.y, direction.x) * sign(area) /
            max(lengths[edge], 1e-12);
    }
    float shortest = min(lengths[0], min(lengths[1], lengths[2]));
    bool degenerate = abs(area) < 1e-6 || shortest < 1e-6;

    uint k = slot;
    bool outer = false;
    if (slot >= 3u) {
        uint edge = (slot - 3u) / fringe_vertex_count;
        uint quad_vertex = slot - 3u - edge * fringe_vertex_count;
        bool at_end = quad_vertex == 1u || quad_vertex == 2u || quad_vertex == 4u;
        k = at_end ? (edge + 1u) % 3u : edge;
        outer = quad_vertex == 2u || quad_vertex == 4u || quad_vertex == 5u;
        if (degenerate || ((modes >> (2u * edge)) & 3u) == 0u) {
            k = edge;
            outer = false;
        }
    }
    if (degenerate) {
        screen_pos = corners[k];
        gl_Position = clip_position(screen_pos);
        edge_distance = vec4(1e4);
        edge_modes = 0u;
        return;
    }

    screen_pos = corners[k];
    if (outer) { screen_pos += corner_shift(k, modes, normals); }
    gl_Position = clip_position(screen_pos);

    vec3 distances;
    for (uint edge = 0u; edge < 3u; ++edge) {
        distances[edge] = dot(screen_pos - corners[edge], normals[edge]);
    }
    edge_distance = vec4(distances, 1e4);
}
