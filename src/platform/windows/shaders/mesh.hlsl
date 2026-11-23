
#include "common.hlsl"

StructuredBuffer<Mesh> meshes : register(t0);
StructuredBuffer<float2> mesh_points : register(t1);
StructuredBuffer<uint> edge_modes_buffer : register(t2);

static const float aa_fringe = 1.0;

struct Varyings {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
    nointerpolation uint circle : CIRCLE;
    float4 edge_distance : EDGE_DISTANCE;
    nointerpolation uint edge_modes : EDGE_MODES;
};

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


static const uint triangle_draw_vertex_count = 21;
static const uint fringe_vertex_count = 6;
static const float miter_max = 4.0 * aa_fringe;

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
        shift = -max(offset_k, offset_before) * n0;
    }
    float shift_length = length(shift);
    if (shift_length > miter_max) {
        shift *= miter_max / shift_length;
    }
    return shift;
}

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

    uint k = slot;
    bool outer = false;
    if (slot >= 3) {
        uint fringe_edge = (slot - 3) / fringe_vertex_count;
        uint quad_vertex = slot - 3 - fringe_edge * fringe_vertex_count;
        bool at_end = quad_vertex == 1 || quad_vertex == 2 || quad_vertex == 4;
        k = at_end ? (fringe_edge + 1) % 3 : fringe_edge;
        outer = quad_vertex == 2 || quad_vertex == 4 || quad_vertex == 5;
        if (degenerate || ((modes >> (2 * fringe_edge)) & 3) == 0) {
            k = fringe_edge;
            outer = false;
        }
    }
    if (degenerate) {
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


Varyings vs_strip(uint vid : SV_VertexID, uint instance : INSTANCE_INDEX) {
    Mesh mesh = meshes[instance];
    uint segment = vid / 6;
    uint segment_count = mesh.count - 1;
    float radius = mesh.width * 0.5;
    float2 start = mesh_points[mesh.first + segment];
    float2 end = mesh_points[mesh.first + segment + 1];
    float2 direction = end - start;
    float distance = length(direction);
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
    float extent = radius > 0.0 ? radius + aa_fringe : 0.0;
    float2 unit = corner(vid - point_index * 6);

    Varyings o;
    o.uv = unit * extent / max(radius, 1e-6);
    o.position = pixel_to_clip(center + unit * extent);
    o.color = mesh.fill;
    o.circle = 1;
    o.edge_distance = float4(1e4, 1e4, 1e4, 1e4);
    o.edge_modes = 0;
    return o;
}


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
    float4 edge_pixel = sqrt(ddx(i.edge_distance) * ddx(i.edge_distance) +
        ddy(i.edge_distance) * ddy(i.edge_distance));
    float uv_pixel = length(float2(ddx(i.uv.x), ddy(i.uv.x)));
    float4 result = i.color;
    if (i.circle != 0) {
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
