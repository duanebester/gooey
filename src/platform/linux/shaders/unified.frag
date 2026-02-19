#version 450

// Constants
const uint PRIM_QUAD = 0u;
const uint PRIM_SHADOW = 1u;

// Inputs from vertex shader
layout(location = 0) flat in uint in_primitive_type;
layout(location = 1) in vec4 in_color;
layout(location = 2) in vec4 in_border_color;
layout(location = 3) in vec2 in_quad_coord;
layout(location = 4) in vec2 in_quad_size;
layout(location = 5) in vec4 in_corner_radii;
layout(location = 6) in vec4 in_border_widths;
layout(location = 7) in vec4 in_clip_bounds;
layout(location = 8) in vec2 in_screen_pos;
layout(location = 9) in vec2 in_content_size;
layout(location = 10) in vec2 in_local_pos;
layout(location = 11) in float in_blur_radius;

// Output color
layout(location = 0) out vec4 out_color;

float rounded_rect_sdf(vec2 pos, vec2 half_size, float radius) {
    vec2 d = abs(pos) - half_size + radius;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

float pick_corner_radius(vec2 pos, vec4 radii) {
    if (pos.x < 0.0) {
        if (pos.y < 0.0) { return radii.x; }  // top-left
        else { return radii.w; }               // bottom-left
    } else {
        if (pos.y < 0.0) { return radii.y; }  // top-right
        else { return radii.z; }               // bottom-right
    }
}

float shadow_falloff(float distance, float blur) {
    return 1.0 - smoothstep(-blur * 0.5, blur * 1.5, distance);
}

void main() {
    if (in_primitive_type == PRIM_QUAD) {
        // Clip test
        vec2 clip_min = in_clip_bounds.xy;
        vec2 clip_max = clip_min + in_clip_bounds.zw;
        if (in_screen_pos.x < clip_min.x || in_screen_pos.x > clip_max.x ||
            in_screen_pos.y < clip_min.y || in_screen_pos.y > clip_max.y) {
            discard;
        }

        vec2 size = in_quad_size;
        vec2 half_size = size / 2.0;
        vec2 pos = in_quad_coord * size;
        vec2 centered = pos - half_size;

        float radius = pick_corner_radius(centered, in_corner_radii);
        float outer_dist = rounded_rect_sdf(centered, half_size, radius);

        vec4 bw = in_border_widths;
        bool has_border = bw.x > 0.0 || bw.y > 0.0 || bw.z > 0.0 || bw.w > 0.0;

        vec4 color = in_color;
        if (has_border) {
            // bw: x=top, y=right, z=bottom, w=left
            // Construct inner rounded rect by insetting each side independently.
            // This handles both per-side borders (e.g. bottom-only navbar) and
            // uniform borders on rounded corners correctly.
            vec2 inner_min = vec2(-half_size.x + bw.w, -half_size.y + bw.x);
            vec2 inner_max = vec2(half_size.x - bw.y, half_size.y - bw.z);
            vec2 inner_center = (inner_min + inner_max) * 0.5;
            vec2 inner_half_size = max(vec2(0.0), (inner_max - inner_min) * 0.5);
            vec2 inner_pos = centered - inner_center;

            // Per-corner inner radii: reduce by the max of the two adjacent border widths.
            vec4 cr = in_corner_radii;
            vec4 inner_radii = vec4(
                max(0.0, cr.x - max(bw.x, bw.w)),
                max(0.0, cr.y - max(bw.x, bw.y)),
                max(0.0, cr.z - max(bw.z, bw.y)),
                max(0.0, cr.w - max(bw.z, bw.w))
            );
            float inner_radius = pick_corner_radius(inner_pos, inner_radii);

            float inner_dist = rounded_rect_sdf(inner_pos, inner_half_size, inner_radius);
            float border_blend = smoothstep(-0.5, 0.5, inner_dist);
            color = mix(in_color, in_border_color, border_blend);
        }

        float alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);
        out_color = color * vec4(1.0, 1.0, 1.0, alpha);
    } else {
        // Shadow primitive
        vec2 half_size = in_content_size / 2.0;
        float radius = pick_corner_radius(in_local_pos, in_corner_radii);
        float dist = rounded_rect_sdf(in_local_pos, half_size, radius);
        float alpha = shadow_falloff(dist, in_blur_radius);
        out_color = vec4(in_color.rgb, in_color.a * alpha);
    }
}
