#version 450
#extension GL_GOOGLE_include_directive : require
#include "mesh.glsl"

layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(location = 2) in vec2 screen_pos;
layout(location = 3) flat in uint circle;
layout(location = 4) in vec4 edge_distance;
layout(location = 5) flat in uint edge_modes;
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

// Coverage of the fragment's pixel from the analytic edges (mesh.glsl).
// `pixel` is one device pixel measured in edge-distance units per component.
float edge_coverage(vec4 pixel) {
    vec4 distance_px = edge_distance / max(pixel, vec4(1e-6));
    float coverage = 1.0;
    for (uint edge = 0u; edge < 4u; ++edge) {
        uint mode = (edge_modes >> (2u * edge)) & 3u;
        if (mode == 1u) { coverage *= clamp(distance_px[edge] + 0.5, 0.0, 1.0); }
        else {
            if (mode == 2u && distance_px[edge] < -0.5) { coverage = 0.0; }
        }
    }
    return coverage;
}

void main() {
    // Derivatives first: they are undefined after a non-uniform discard.
    vec4 edge_pixel = sqrt(dFdx(edge_distance) * dFdx(edge_distance) +
        dFdy(edge_distance) * dFdy(edge_distance));
    float uv_pixel = length(vec2(dFdx(uv.x), dFdy(uv.x)));
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
        // Shared point falloff (cpu/mesh.zig `pointFalloff`, Metal's point
        // shaders). From a 6.7 device pixel radius up it is the historical
        // falloff over the outer 15% of the radius, computed the same way.
        // Smaller points get a one-pixel band that moves outward to straddle
        // the edge, so a sub-pixel dot keeps about its area instead of vanishing.
        float radius_px = 1.0 / max(uv_pixel, 1e-6);
        float uv_distance = length(uv);
        if (radius_px >= 1.0 / 0.15) {
            result.a *= 1.0 - smoothstep(0.85, 1.0, uv_distance);
        } else {
            float end_px = radius_px + 0.5 * (1.0 - 0.15 * radius_px);
            result.a *= 1.0 - smoothstep(end_px - 1.0, end_px, uv_distance * radius_px);
        }
    } else {
        float coverage = edge_coverage(edge_pixel);
        if (coverage <= 0.0) { discard; }
        result.a *= coverage;
    }
    if (result.a < 0.001) { discard; }
    output_color = vec4(result.rgb * result.a, result.a);
}
