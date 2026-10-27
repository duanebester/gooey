#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec2 screen_pos;
layout(location = 3) flat out uint circle;
layout(location = 4) out vec4 edge_distance;
layout(location = 5) flat out uint edge_modes;

const uint triangle_stride = 5u;
// A sharp corner's offset point is clamped; tips sharper than about 14 degrees
// lose part of their fade band instead of producing long slivers.
const float miter_max = 4.0 * aa_fringe;

vec2 triangle_position(uint vertex) {
    uint offset = vertex * triangle_stride;
    return vec2(mesh.data[offset], mesh.data[offset + 1u]) * mesh.transform.zw +
        mesh.transform.xy;
}

vec2 triangle_uv(uint vertex) {
    uint offset = vertex * triangle_stride;
    return vec2(mesh.data[offset + 2u], mesh.data[offset + 3u]);
}

// Each corner moves to the intersection of its two edges' offset lines, so the
// expanded triangle is the original grown by `aa_fringe` across every faded
// or underlapping edge and unchanged across interior edges. Distances to the
// original edges and barycentric uv extrapolation keep shading identical.
void main() {
    uint first = uint(gl_VertexIndex) / 3u * 3u;
    uint k = uint(gl_VertexIndex) - first;
    vec2 corners[3] = vec2[3](triangle_position(first), triangle_position(first + 1u),
        triangle_position(first + 2u));
    uint modes = uint(mesh.data[first * triangle_stride + 4u] + 0.5);
    edge_modes = modes;
    color = hsla_to_rgba(mesh.color);
    circle = 0u;

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
    if (abs(area) < 1e-6 || shortest < 1e-6) {
        // Degenerate: covers no pixel samples. Draw it unexpanded and unfaded.
        screen_pos = corners[k];
        gl_Position = vec4(screen_pos / viewport.size * 2.0 - 1.0, 0, 1);
        uv = triangle_uv(first + k);
        edge_distance = vec4(1e4);
        edge_modes = 0u;
        return;
    }

    // Corner k lies on edge k (k -> k+1) and edge k-1 (k-1 -> k).
    uint before = (k + 2u) % 3u;
    float offset_k = ((modes >> (2u * k)) & 3u) != 0u ? aa_fringe : 0.0;
    float offset_before = ((modes >> (2u * before)) & 3u) != 0u ? aa_fringe : 0.0;
    vec2 n0 = normals[k];
    vec2 n1 = normals[before];
    float det = n0.x * n1.y - n0.y * n1.x;
    vec2 shift = vec2(0);
    if (abs(det) > 1e-4) {
        // Solve dot(shift, n0) = -offset_k and dot(shift, n1) = -offset_before.
        shift = vec2(-offset_k * n1.y + offset_before * n0.y,
            -offset_before * n0.x + offset_k * n1.x) / det;
    } else {
        // Nearly straight corner: the two offset lines coincide.
        shift = -max(offset_k, offset_before) * n0;
    }
    float shift_length = length(shift);
    if (shift_length > miter_max) { shift *= miter_max / shift_length; }
    screen_pos = corners[k] + shift;
    gl_Position = vec4(screen_pos / viewport.size * 2.0 - 1.0, 0, 1);

    vec3 distances;
    for (uint edge = 0u; edge < 3u; ++edge) {
        distances[edge] = dot(screen_pos - corners[edge], normals[edge]);
    }
    edge_distance = vec4(distances, 1e4);
    // Barycentric weight of corner j is the distance to its opposite edge
    // (edge j+1) divided by the triangle's height over that edge.
    vec3 weights;
    for (uint j = 0u; j < 3u; ++j) {
        uint opposite = (j + 1u) % 3u;
        float height = abs(area) / lengths[opposite];
        weights[j] = distances[opposite] / height;
    }
    uv = weights.x * triangle_uv(first) + weights.y * triangle_uv(first + 1u) +
        weights.z * triangle_uv(first + 2u);
}
