// Shared std430 contract: vk_types.MeshHeader, then tightly packed float payload.
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

// Triangle-list expansion avoids geometry shaders and device point-size limits.
vec2 corner(uint vertex) {
    const vec2 corners[6] = vec2[6](
        vec2(-1, -1), vec2(1, -1), vec2(-1, 1),
        vec2(1, -1), vec2(1, 1), vec2(-1, 1));
    return corners[vertex];
}
