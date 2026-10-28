// Shared std430 contract: vk_types.MeshHeader, then tightly packed float payload.
//
// Analytic anti-aliasing contract (the render pass has one sample per pixel).
// Every mesh vertex shader writes, besides uv, color and screen_pos:
//   edge_distance: signed distances in logical pixels from the fragment to up
//     to four straight edges, positive inside. They are affine in screen
//     space, so interpolation is exact and mesh.frag converts them to device
//     pixels with screen-space derivatives.
//   edge_modes: two bits per distance (bits 2i..2i+1 for component i), values
//     from mesh_edges.EdgeMode (src/platform/mesh_edges.zig):
//     0 interior: no coverage change; the edge is drawn by the rasterizer.
//     1 fade:     coverage *= clamp(distance_px + 0.5, 0, 1).
//     2 underlap: full coverage up to half a pixel outside, discard beyond.
//   Vertex shaders push every edge with a non-zero mode `aa_fringe` logical
//   pixels outward so the faded band is rasterized.
// Triangle records are { x, y, u, v, edge_modes } with the three edge modes of
// the triangle (v0->v1, v1->v2, v2->v0) as an integral float. Polyline strips
// carry their segment count in params.x so only the line's ends are capped.
layout(std430, set = 0, binding = 0) readonly buffer Mesh {
    vec4 transform;
    vec4 color;
    vec4 clip;
    vec4 params;
    uint gradient_type;
    uint stop_count;
    float radius;
    uint colored;
    float stop_offsets[16];
    float stop_h[16];
    float stop_s[16];
    float stop_l[16];
    float stop_a[16];
    float data[];
} mesh;

layout(set = 0, binding = 1) uniform Viewport { vec2 size; } viewport;

vec4 hsla_to_rgba(vec4 hsla) {
    float h = hsla.x * 6.0;
    float c = (1.0 - abs(2.0 * hsla.z - 1.0)) * hsla.y;
    float x = c * (1.0 - abs(mod(h, 2.0) - 1.0));
    vec3 rgb;
    if (h < 1.0) { rgb = vec3(c, x, 0); }
    else {
        if (h < 2.0) { rgb = vec3(x, c, 0); }
        else {
            if (h < 3.0) { rgb = vec3(0, c, x); }
            else {
                if (h < 4.0) { rgb = vec3(0, x, c); }
                else {
                    if (h < 5.0) { rgb = vec3(x, 0, c); }
                    else { rgb = vec3(c, 0, x); }
                }
            }
        }
    }
    return vec4(rgb + hsla.z - c * 0.5, hsla.w);
}

// One logical pixel is at least one device pixel at every supported scale.
const float aa_fringe = 1.0;

// Triangle-list expansion avoids geometry shaders and device point-size limits.
vec2 corner(uint vertex) {
    const vec2 corners[6] = vec2[6](
        vec2(-1, -1), vec2(1, -1), vec2(-1, 1),
        vec2(1, -1), vec2(1, 1), vec2(-1, 1));
    return corners[vertex];
}
