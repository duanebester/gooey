#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec2 screen_pos;
layout(location = 3) flat out uint circle;

void main() {
    uint offset = uint(gl_VertexIndex) * 4u;
    vec2 position = vec2(mesh.data[offset], mesh.data[offset + 1u]);
    screen_pos = position * mesh.transform.zw + mesh.transform.xy;
    // Vulkan's positive-height viewport is Y-down, unlike Metal and WebGPU.
    gl_Position = vec4(screen_pos / viewport.size * 2.0 - 1.0, 0, 1);
    uv = vec2(mesh.data[offset + 2u], mesh.data[offset + 3u]);
    color = hsla_to_rgba(mesh.color);
    circle = 0u;
}
