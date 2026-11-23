#include "packed.glsl"

const float aa_fringe = 1.0;

vec2 corner(uint vertex) {
    const vec2 corners[6] = vec2[6](
        vec2(-1, -1), vec2(1, -1), vec2(-1, 1),
        vec2(1, -1), vec2(1, 1), vec2(-1, 1));
    return corners[vertex];
}
