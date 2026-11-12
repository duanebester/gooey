// Meshes: the HLSL twins of the Vulkan renderer's triangles.vert,
// strip_expanded.vert, point_instanced.vert, and mesh.frag
// (src/platform/linux/shaders), reading packed-frame meshes. Keep them in
// step. The renderer draws one mesh per draw call, with the mesh's index as
// INSTANCE_INDEX and SV_VertexID counting that mesh's expanded vertices.
//
// Analytic anti-aliasing contract (src/platform/mesh_edges.zig), one sample
// per pixel. Every vertex shader writes:
//   edge_distance: signed distances in logical pixels from the fragment to up
//     to four straight edges, positive inside. They are affine in screen
//     space, so interpolation is exact, and the pixel shader converts them to
//     device pixels with screen-space derivatives.
//   edge_modes: two bits per distance, from mesh_edges.EdgeMode:
//     0 interior: no coverage change; the edge is drawn by the rasterizer.
//     1 fade:     coverage *= clamp(distance_px + 0.5, 0, 1).
//     2 underlap: full coverage up to half a pixel outside, discard beyond.
// The faded band of every edge with a non-zero mode reaches aa_fringe
// logical pixels outward: triangles add a fringe quad outside each such edge
// and never move a triangle's corners; strips and points grow their quads.
// Fills are straight RGBA; the pixel shader writes premultiplied colour.
// Clipping is the scissor rectangle the renderer sets per draw.
// Rebuild the DXBC after editing: zig build compile-hlsl.

#include "common.hlsl"

StructuredBuffer<Mesh> meshes : register(t0);
StructuredBuffer<float2> mesh_points : register(t1);
StructuredBuffer<uint> edge_modes_buffer : register(t2);

// One logical pixel is at least one device pixel at every supported scale.
static const float aa_fringe = 1.0;

struct Varyings {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0; // Points: offset from the centre in radii.
    float4 color : COLOR0;
    nointerpolation uint circle : CIRCLE;
    float4 edge_distance : EDGE_DISTANCE;
    nointerpolation uint edge_modes : EDGE_MODES;
};

// Triangle-list expansion avoids geometry shaders and device point-size limits.
float2 corner(uint vid) {
    switch (vid) {
        case 0: return float2(-1.0, -1.0);
        case 1: return float2(1.0, -1.0);
        case 2: return float2(-1.0, 1.0);
        case 3: return float2(1.0, -1.0);
        case 4: return float2(1.0, 1.0);
        case 5: return float2(-1.0, 1.0);
        default: return float2(0.0, 0.0);
    }
}

// =============================================================================
// Triangles
// =============================================================================

// Draw vertices per triangle (mesh_edges.triangle_draw_vertex_count): the
// triangle at its exact corners (0-2), then one fringe quad of two triangles
// for each of its three edges (3-20).
static const uint triangle_draw_vertex_count = 21;
static const uint fringe_vertex_count = 6;
// A sharp corner's offset point is clamped; tips sharper than about 14 degrees
// lose part of their fade band instead of producing long slivers.
static const float miter_max = 4.0 * aa_fringe;

// Offset of corner k, which lies on edge k (k -> k+1) and edge k-1: the
// intersection of the two edges' offset lines, each pushed outward by
// aa_fringe when its mode is not interior. Every fringe vertex at corner k
// calls this with the same inputs, so neighbouring quads share their common
// side exactly.
float2 corner_shift(uint k, uint modes, float2 normals[3]) {
    uint before = (k + 2) % 3;
    float offset_k = ((modes >> (2 * k)) & 3) != 0 ? aa_fringe : 0.0;
    float offset_before = ((modes >> (2 * before)) & 3) != 0 ? aa_fringe : 0.0;
    float2 n0 = normals[k];
    float2 n1 = normals[before];
    float det = n0.x * n1.y - n0.y * n1.x;
    float2 shift = float2(0.0, 0.0);
    if (abs(det) > 1e-4) {
        shift = float2(-offset_k * n1.y + offset_before * n0.y,
            -offset_before * n0.x + offset_k * n1.x) / det;
    } else {
        // Nearly straight corner: the two offset lines coincide.
        shift = -max(offset_k, offset_before) * n0;
    }
    float shift_length = length(shift);
    if (shift_length > miter_max) {
        shift *= miter_max / shift_length;
    }
    return shift;
}

// The triangle itself is drawn at its exact corners, so every edge it shares
// with another triangle has bit-identical endpoints in both draws and the
// rasterization rule covers each pixel on it exactly once. Each fade or
// underlap edge adds a quad outside it, whose inner side is that same edge
// and whose outer side joins the two corners' offset points. Interior edges
// get no quad: their six vertices collapse onto one point.
Varyings vs_triangles(uint vid : SV_VertexID, uint instance : INSTANCE_INDEX) {
    Mesh mesh = meshes[instance];
    uint triangle_index = vid / triangle_draw_vertex_count;
    uint slot = vid - triangle_index * triangle_draw_vertex_count;
    uint first = mesh.first + triangle_index * 3;
    float2 corners[3] = { mesh_points[first], mesh_points[first + 1], mesh_points[first + 2] };
    uint modes = edge_modes_buffer[mesh.edge_first + triangle_index];

    Varyings o;
    o.color = mesh.fill;
    o.circle = 0;
    o.uv = float2(0.0, 0.0);
    o.edge_modes = modes;

    float area = (corners[1].x - corners[0].x) * (corners[2].y - corners[0].y) -
        (corners[1].y - corners[0].y) * (corners[2].x - corners[0].x);
    float2 normals[3];
    float lengths[3];
    [unroll] for (uint edge = 0; edge < 3; ++edge) {
        float2 direction = corners[(edge + 1) % 3] - corners[edge];
        lengths[edge] = length(direction);
        normals[edge] = float2(-direction.y, direction.x) * sign(area) /
            max(lengths[edge], 1e-12);
    }
    float shortest = min(lengths[0], min(lengths[1], lengths[2]));
    bool degenerate = abs(area) < 1e-6 || shortest < 1e-6;

    // Corner k this vertex sits on, and whether it is the corner's offset
    // point (a fringe quad's outer side).
    uint k = slot;
    bool outer = false;
    if (slot >= 3) {
        uint fringe_edge = (slot - 3) / fringe_vertex_count;
        uint quad_vertex = slot - 3 - fringe_edge * fringe_vertex_count;
        // Quad (inner start, inner end, outer end), (inner start, outer end,
        // outer start).
        bool at_end = quad_vertex == 1 || quad_vertex == 2 || quad_vertex == 4;
        k = at_end ? (fringe_edge + 1) % 3 : fringe_edge;
        outer = quad_vertex == 2 || quad_vertex == 4 || quad_vertex == 5;
        if (degenerate || ((modes >> (2 * fringe_edge)) & 3) == 0) {
            k = fringe_edge;
            outer = false;
        }
    }
    if (degenerate) {
        // Covers no pixel samples: draw it at its corners, unfaded.
        o.position = pixel_to_clip(corners[k]);
        o.edge_distance = float4(1e4, 1e4, 1e4, 1e4);
        o.edge_modes = 0;
        return o;
    }

    float2 screen_pos = corners[k];
    if (outer) {
        screen_pos += corner_shift(k, modes, normals);
    }
    o.position = pixel_to_clip(screen_pos);
    float3 distances;
    [unroll] for (uint e = 0; e < 3; ++e) {
        distances[e] = dot(screen_pos - corners[e], normals[e]);
    }
    o.edge_distance = float4(distances, 1e4);
    return o;
}

// =============================================================================
// Strips and points
// =============================================================================

// Segments are independent butt-ended quads, like Metal's. The sides of every
// segment fade; only the line's first start cap and last end cap fade, so the
// hard joints of consecutive segments still overlap without a seam.
Varyings vs_strip(uint vid : SV_VertexID, uint instance : INSTANCE_INDEX) {
    Mesh mesh = meshes[instance];
    uint segment = vid / 6;
    uint segment_count = mesh.count - 1;
    float radius = mesh.width * 0.5;
    float2 start = mesh_points[mesh.first + segment];
    float2 end = mesh_points[mesh.first + segment + 1];
    float2 direction = end - start;
    float distance = length(direction);
    // Zero-length segments keep their degenerate quad: they cover no pixels.
    float2 along_unit = float2(1.0, 0.0);
    float2 across_unit = float2(0.0, 1.0);
    bool has_length = distance > 0.0001;
    if (has_length) {
        along_unit = direction / distance;
        across_unit = float2(-along_unit.y, along_unit.x);
    }
    bool cap_start = has_length && segment == 0;
    bool cap_end = has_length && segment + 1 == segment_count;
    float2 unit = corner(vid - segment * 6);
    float across = unit.y * (radius + aa_fringe);
    float along = unit.x < 0.0 ? (cap_start ? -aa_fringe : 0.0) :
        distance + (cap_end ? aa_fringe : 0.0);

    Varyings o;
    float2 screen_pos = start + along_unit * along + across_unit * across;
    o.position = pixel_to_clip(screen_pos);
    o.uv = float2(0.0, 0.0);
    o.color = mesh.fill;
    o.circle = 0;
    o.edge_distance = float4(radius + across, radius - across, along, distance - along);
    o.edge_modes = 1 | (1 << 2) | (cap_start ? 1 << 4 : 0) | (cap_end ? 1 << 6 : 0);
    return o;
}

Varyings vs_points(uint vid : SV_VertexID, uint instance : INSTANCE_INDEX) {
    Mesh mesh = meshes[instance];
    uint point_index = vid / 6;
    float2 center = mesh_points[mesh.first + point_index];
    float radius = mesh.width;
    // The quad reaches aa_fringe past the radius so the pixel shader's
    // falloff can straddle the circle's edge; uv stays 1.0 at the radius.
    // Zero-radius points keep a degenerate quad and draw nothing.
    float extent = radius > 0.0 ? radius + aa_fringe : 0.0;
    float2 unit = corner(vid - point_index * 6);

    Varyings o;
    o.uv = unit * extent / max(radius, 1e-6);
    o.position = pixel_to_clip(center + unit * extent);
    o.color = mesh.fill;
    o.circle = 1;
    // The circular falloff anti-aliases points; no straight edges.
    o.edge_distance = float4(1e4, 1e4, 1e4, 1e4);
    o.edge_modes = 0;
    return o;
}

// =============================================================================
// Pixel shader
// =============================================================================

// Coverage of the fragment's pixel from the analytic edges. `pixel` is one
// device pixel measured in edge-distance units per component.
float edge_coverage(float4 edge_distance, uint modes, float4 pixel) {
    float4 distance_px = edge_distance / max(pixel, float4(1e-6, 1e-6, 1e-6, 1e-6));
    float coverage = 1.0;
    [unroll] for (uint edge = 0; edge < 4; ++edge) {
        uint mode = (modes >> (2 * edge)) & 3;
        if (mode == 1) {
            coverage *= saturate(distance_px[edge] + 0.5);
        } else {
            if (mode == 2 && distance_px[edge] < -0.5) {
                coverage = 0.0;
            }
        }
    }
    return coverage;
}

float4 ps_mesh(Varyings i) : SV_Target {
    // Derivatives first: they are undefined after a non-uniform discard.
    float4 edge_pixel = sqrt(ddx(i.edge_distance) * ddx(i.edge_distance) +
        ddy(i.edge_distance) * ddy(i.edge_distance));
    float uv_pixel = length(float2(ddx(i.uv.x), ddy(i.uv.x)));
    float4 result = i.color;
    if (i.circle != 0) {
        // Shared point falloff (cpu/mesh.zig pointFalloff, Metal's point
        // shaders). From a 6.7 device pixel radius up it is the falloff over
        // the outer 15% of the radius; smaller points get a one-pixel band
        // that moves outward to straddle the edge, so a sub-pixel dot keeps
        // about its area instead of vanishing.
        float radius_px = 1.0 / max(uv_pixel, 1e-6);
        float uv_distance = length(i.uv);
        if (radius_px >= 1.0 / 0.15) {
            result.a *= 1.0 - smoothstep(0.85, 1.0, uv_distance);
        } else {
            float end_px = radius_px + 0.5 * (1.0 - 0.15 * radius_px);
            result.a *= 1.0 - smoothstep(end_px - 1.0, end_px, uv_distance * radius_px);
        }
    } else {
        float coverage = edge_coverage(i.edge_distance, i.edge_modes, edge_pixel);
        if (coverage <= 0.0) {
            discard;
        }
        result.a *= coverage;
    }
    if (result.a < 0.001) {
        discard;
    }
    return float4(result.rgb * result.a, result.a);
}
