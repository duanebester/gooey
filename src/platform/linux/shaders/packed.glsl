// The packed frame (src/core/packed_frame.zig) as every Vulkan pipeline reads it.
//
// The renderer copies each instance array into its storage buffer as is, so
// these structs are the Zig `extern` structs field for field: std430 places
// every vec4 at a 16-byte boundary and the trailing scalars after it, which
// is the Zig layout (asserted in vk_types.zig). `Quad.offset` sits at byte 80,
// so std430's 8-byte vec2 alignment places it where Zig does.
//
// Colours are straight RGBA and positions are logical pixels from the top
// left; `viewport.size` is the framebuffer in logical pixels. Clipping is the
// draw's scissor rectangle, so no shader tests a clip.
//
// One descriptor set serves every pipeline (vk_descriptors.zig):
//   0 quads, 1 sprites, 2 meshes, 3 mesh points, 4 triangle edge modes,
//   5 viewport uniform, 6 glyph atlas, 7 SVG atlas, 8 image atlas, 9 sampler.
// Mesh pipelines take their mesh index as a push constant.

struct Quad {
    vec4 bounds;
    vec4 fill;
    vec4 border_color;
    vec4 corners;       // top left, top right, bottom right, bottom left
    vec4 border_widths; // top, right, bottom, left
    vec2 offset;        // a shadow's offset from bounds
    float blur;         // > 0: a shadow
    float pad;
};

struct Sprite {
    vec4 bounds;
    vec4 uv;            // left, top, right, bottom
    vec4 tint;
    vec4 secondary;     // SVG stroke colour
    vec4 corners;       // image radii
    float grayscale;
    float opacity;
    float pad0;
    float pad1;
};

struct Mesh {
    vec4 fill;
    uint first;         // into mesh_points
    uint count;
    float width;        // strip: full width; points: radius
    uint edge_first;    // triangles: into triangle_edge_modes, one per triangle
};

layout(std430, set = 0, binding = 0) readonly buffer Quads { Quad quads[]; };
layout(std430, set = 0, binding = 1) readonly buffer Sprites { Sprite sprites[]; };
layout(std430, set = 0, binding = 2) readonly buffer Meshes { Mesh meshes[]; };
layout(std430, set = 0, binding = 3) readonly buffer MeshPoints { vec2 mesh_points[]; };
layout(std430, set = 0, binding = 4) readonly buffer EdgeModes { uint triangle_edge_modes[]; };
layout(set = 0, binding = 5) uniform Viewport { vec2 size; } viewport;
layout(push_constant) uniform Draw { uint mesh; } draw;

// Six vertices per instance: two triangles over the unit square.
vec2 unit_vertex(uint vertex) {
    const vec2 corners[6] = vec2[6](
        vec2(0, 0), vec2(1, 0), vec2(0, 1),
        vec2(1, 0), vec2(1, 1), vec2(0, 1));
    return corners[vertex];
}

// Vulkan NDC is Y-down like logical pixels, so there is no flip.
vec4 clip_position(vec2 position) {
    return vec4(position / viewport.size * 2.0 - 1.0, 0.0, 1.0);
}
