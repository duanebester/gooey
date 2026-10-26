#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec2 screen_pos;
layout(location = 3) flat out uint circle;

void main() {
    uint stride = mesh.colored == 0u ? 2u : 6u;
    uint offset = uint(gl_InstanceIndex) * stride;
    vec2 center = vec2(mesh.data[offset], mesh.data[offset + 1u]);
    uv = corner(uint(gl_VertexIndex));
    screen_pos = center + uv * mesh.radius;
    gl_Position = vec4(screen_pos / viewport.size * 2.0 - 1.0, 0, 1);
    vec4 hsla = mesh.color;
    if (mesh.colored != 0u) {
        hsla = vec4(mesh.data[offset + 2u], mesh.data[offset + 3u],
            mesh.data[offset + 4u], mesh.data[offset + 5u]);
    }
    color = hsla_to_rgba(hsla);
    circle = 1u;
}
