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
            // Distance from each edge (positive = inside the rect)
            float d_top = centered.y + half_size.y;
            float d_bottom = half_size.y - centered.y;
            float d_left = centered.x + half_size.x;
            float d_right = half_size.x - centered.x;

            // For each side, compute border blend (1.0 = in border, 0.0 = not in border)
            // Only active for sides with non-zero border width
            float b_top = (1.0 - smoothstep(bw.x - 0.5, bw.x + 0.5, d_top)) * step(0.001, bw.x);
            float b_right = (1.0 - smoothstep(bw.y - 0.5, bw.y + 0.5, d_right)) * step(0.001, bw.y);
            float b_bottom = (1.0 - smoothstep(bw.z - 0.5, bw.z + 0.5, d_bottom)) * step(0.001, bw.z);
            float b_left = (1.0 - smoothstep(bw.w - 0.5, bw.w + 0.5, d_left)) * step(0.001, bw.w);

            float border_blend = max(max(b_top, b_right), max(b_bottom, b_left));
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
