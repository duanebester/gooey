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
//   The faded band of every edge with a non-zero mode reaches `aa_fringe`
//   logical pixels outward: triangles.vert adds a fringe quad outside each
//   such edge and never moves a triangle's corners; strip and point vertex
//   shaders grow their quads.
// Mesh draws read `meshes[draw.mesh]` (packed.glsl): its points from
// `mesh_points` and, for triangles, one edge-modes word per triangle from
// `triangle_edge_modes`, which pack classified for the whole frame.
#include "packed.glsl"

// One logical pixel is at least one device pixel at every supported scale.
const float aa_fringe = 1.0;

// Triangle-list expansion avoids geometry shaders and device point-size limits.
vec2 corner(uint vertex) {
    const vec2 corners[6] = vec2[6](
        vec2(-1, -1), vec2(1, -1), vec2(-1, 1),
        vec2(1, -1), vec2(1, 1), vec2(-1, 1));
    return corners[vertex];
}
