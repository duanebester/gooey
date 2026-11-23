
struct Quad {
    vec4 bounds;
    vec4 fill;
    vec4 border_color;
    vec4 corners;
    vec4 border_widths;
    vec2 offset;
    float blur;
    float pad;
};

struct Sprite {
    vec4 bounds;
    vec4 uv;
    vec4 tint;
    vec4 secondary;
    vec4 corners;
    float grayscale;
    float opacity;
    float pad0;
    float pad1;
};

struct Mesh {
    vec4 fill;
    uint first;
    uint count;
    float width;
    uint edge_first;
};

layout(std430, set = 0, binding = 0) readonly buffer Quads { Quad quads[]; };
layout(std430, set = 0, binding = 1) readonly buffer Sprites { Sprite sprites[]; };
layout(std430, set = 0, binding = 2) readonly buffer Meshes { Mesh meshes[]; };
layout(std430, set = 0, binding = 3) readonly buffer MeshPoints { vec2 mesh_points[]; };
layout(std430, set = 0, binding = 4) readonly buffer EdgeModes { uint triangle_edge_modes[]; };
layout(set = 0, binding = 5) uniform Viewport { vec2 size; } viewport;
layout(push_constant) uniform Draw { uint mesh; } draw;

vec2 unit_vertex(uint vertex) {
    const vec2 corners[6] = vec2[6](
        vec2(0, 0), vec2(1, 0), vec2(0, 1),
        vec2(1, 0), vec2(1, 1), vec2(0, 1));
    return corners[vertex];
}

vec4 clip_position(vec2 position) {
    return vec4(position / viewport.size * 2.0 - 1.0, 0.0, 1.0);
}
