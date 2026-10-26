#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(location = 2) in vec2 screen_pos;
layout(location = 3) flat in uint circle;
layout(location = 0) out vec4 output_color;

vec4 gradient_color(float value) {
    float t = clamp(value, 0.0, 1.0);
    uint first = 0u;
    uint second = 1u;
    // Bounded exactly like the Metal/WGSL 16-stop HSLA interpolation contract.
    for (uint i = 0u; i < 15u && i + 1u < mesh.stop_count; ++i) {
        if (t >= mesh.stop_offsets[i] && t <= mesh.stop_offsets[i + 1u]) {
            first = i;
            second = i + 1u;
            break;
        }
    }
    float range = mesh.stop_offsets[second] - mesh.stop_offsets[first];
    float factor = range > 0.0001 ? (t - mesh.stop_offsets[first]) / range : 0.0;
    vec4 a = vec4(mesh.stop_h[first], mesh.stop_s[first],
        mesh.stop_l[first], mesh.stop_a[first]);
    vec4 b = vec4(mesh.stop_h[second], mesh.stop_s[second],
        mesh.stop_l[second], mesh.stop_a[second]);
    if (abs(b.x - a.x) > 0.5) {
        if (a.x < b.x) { a.x += 1.0; }
        else { b.x += 1.0; }
    }
    vec4 hsla = mix(a, b, factor);
    hsla.x = mod(hsla.x, 1.0);
    return hsla_to_rgba(hsla);
}

void main() {
    if (any(lessThan(screen_pos, mesh.clip.xy)) ||
        any(greaterThan(screen_pos, mesh.clip.xy + mesh.clip.zw))) { discard; }
    vec4 result = color;
    if (mesh.gradient_type == 1u) {
        vec2 direction = mesh.params.zw - mesh.params.xy;
        float length_squared = dot(direction, direction);
        float t = length_squared < 0.0001 ? 0.0 :
            dot(uv - mesh.params.xy, direction) / length_squared;
        result = gradient_color(t);
    } else {
        if (mesh.gradient_type == 2u) {
            float radius = mesh.params.z;
            float inner = mesh.params.w;
            float t = radius <= inner ? 1.0 :
                (length(uv - mesh.params.xy) - inner) / (radius - inner);
            result = gradient_color(t);
        }
    }
    if (circle != 0u) {
        result.a *= 1.0 - smoothstep(0.85, 1.0, length(uv));
    }
    if (result.a < 0.001) { discard; }
    output_color = vec4(result.rgb * result.a, result.a);
}
