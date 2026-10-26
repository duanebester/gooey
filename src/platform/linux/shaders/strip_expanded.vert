#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec2 screen_pos;
layout(location = 3) flat out uint circle;

void main() {
    uint offset = uint(gl_InstanceIndex) * 2u;
    vec2 start = vec2(mesh.data[offset], mesh.data[offset + 1u]);
    vec2 end = vec2(mesh.data[offset + 2u], mesh.data[offset + 3u]);
    vec2 direction = end - start;
    float distance = length(direction);
    // Match Metal's independent butt-ended segments, including zero length.
    vec2 perpendicular = vec2(0, mesh.radius);
    if (distance > 0.0001) {
        perpendicular = vec2(-direction.y, direction.x) / distance * mesh.radius;
    }
    vec2 unit = corner(uint(gl_VertexIndex));
    screen_pos = mix(start, end, (unit.x + 1.0) * 0.5) + unit.y * perpendicular;
    gl_Position = vec4(screen_pos / viewport.size * 2.0 - 1.0, 0, 1);
    uv = vec2(0);
    color = hsla_to_rgba(mesh.color);
    circle = 0u;
}
