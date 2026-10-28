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
// Draw vertices per triangle (mesh_edges.triangle_draw_vertex_count): the
// triangle at its exact corners (0-2), then one fringe quad of two triangles
// for each of its three edges (3-20).
const uint triangle_draw_vertex_count = 21u;
const uint fringe_vertex_count = 6u;
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

// Offset of corner k, which lies on edge k (k -> k+1) and edge k-1: the
// intersection of the two edges' offset lines, each pushed outward by
// `aa_fringe` when its mode is not interior. Solves dot(shift, n_k) =
// -offset_k and dot(shift, n_before) = -offset_before. Every fringe vertex at
// corner k calls this with the same inputs, so neighbouring quads share their
// common side exactly.
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
        // Nearly straight corner: the two offset lines coincide.
        shift = -max(offset_k, offset_before) * n0;
    }
    float shift_length = length(shift);
    if (shift_length > miter_max) { shift *= miter_max / shift_length; }
    return shift;
}

// The triangle itself is drawn at its exact corners, so every edge it shares
// with another triangle has bit-identical endpoints in both draws and the
// rasterization rule covers each pixel on it exactly once. Each fade or
// underlap edge adds a quad outside it: its inner side is that same edge, its
// outer side joins the two corners' offset points (`corner_shift`). An
// offset point slides along an interior edge, or sits on the miter of two
// faded edges, so the quads and the triangle together cover exactly the
// triangle grown by `aa_fringe` across those edges. Interior edges get no
// quad: their six vertices collapse onto one point and cover nothing.
// Distances to the original edges and barycentric uv extrapolation keep
// shading identical across the triangle and its quads.
void main() {
    uint triangle = uint(gl_VertexIndex) / triangle_draw_vertex_count;
    uint slot = uint(gl_VertexIndex) - triangle * triangle_draw_vertex_count;
    uint first = triangle * 3u;
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
    bool degenerate = abs(area) < 1e-6 || shortest < 1e-6;

    // Corner k of the triangle this vertex sits on, and whether it is the
    // corner's offset point (a fringe quad's outer side).
    uint k = slot;
    bool outer = false;
    if (slot >= 3u) {
        uint edge = (slot - 3u) / fringe_vertex_count;
        uint quad_vertex = slot - 3u - edge * fringe_vertex_count;
        // Quad (inner start, inner end, outer end), (inner start, outer end, outer start).
        bool at_end = quad_vertex == 1u || quad_vertex == 2u || quad_vertex == 4u;
        k = at_end ? (edge + 1u) % 3u : edge;
        outer = quad_vertex == 2u || quad_vertex == 4u || quad_vertex == 5u;
        if (degenerate || ((modes >> (2u * edge)) & 3u) == 0u) {
            k = edge;
            outer = false;
        }
    }
    if (degenerate) {
        // Covers no pixel samples. Draw it at its corners, unfaded, without quads.
        screen_pos = corners[k];
        gl_Position = vec4(screen_pos / viewport.size * 2.0 - 1.0, 0, 1);
        uv = triangle_uv(first + k);
        edge_distance = vec4(1e4);
        edge_modes = 0u;
        return;
    }

    screen_pos = corners[k];
    if (outer) { screen_pos += corner_shift(k, modes, normals); }
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
