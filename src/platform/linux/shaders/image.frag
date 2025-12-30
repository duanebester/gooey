#version 450

// Inputs from vertex shader
layout(location = 0) in vec2 in_tex_coord;
layout(location = 1) in vec4 in_tint_rgba;
layout(location = 2) in vec4 in_clip_bounds;
layout(location = 3) in vec2 in_screen_pos;
layout(location = 4) in vec2 in_image_origin;
layout(location = 5) in vec2 in_size;
layout(location = 6) in vec4 in_corner_radii;
layout(location = 7) in float in_grayscale;
layout(location = 8) in float in_opacity;

// Image atlas texture (RGBA format)
layout(set = 0, binding = 2) uniform texture2D image_atlas;
layout(set = 0, binding = 3) uniform sampler image_sampler;

// Output color
layout(location = 0) out vec4 out_color;

// Signed distance function for rounded rectangle
float roundedRectSDF(vec2 pos, vec2 half_size, vec4 radii) {
    // Select correct corner radius based on quadrant
    // radii: x=TL, y=TR, z=BR, w=BL
    float r;
    if (pos.x > 0.0) {
        r = (pos.y > 0.0) ? radii.z : radii.y;  // BR : TR
    } else {
        r = (pos.y > 0.0) ? radii.w : radii.x;  // BL : TL
    }

    vec2 q = abs(pos) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    // Clip test
    vec2 clip_min = in_clip_bounds.xy;
    vec2 clip_max = clip_min + in_clip_bounds.zw;
    if (in_screen_pos.x < clip_min.x || in_screen_pos.x > clip_max.x ||
        in_screen_pos.y < clip_min.y || in_screen_pos.y > clip_max.y) {
        discard;
    }

    // Rounded corners with anti-aliasing
    float corner_alpha = 1.0;
    float max_radius = max(max(in_corner_radii.x, in_corner_radii.y),
                          max(in_corner_radii.z, in_corner_radii.w));
    if (max_radius > 0.0) {
        vec2 half_size = in_size * 0.5;
        // Compute position relative to image center
        vec2 local_pos = in_screen_pos - in_image_origin - half_size;

        float dist = roundedRectSDF(local_pos, half_size, in_corner_radii);
        // Smooth anti-aliased edge (1px transition)
        corner_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
        if (corner_alpha < 0.001) {
            discard;
        }
    }

    // Sample texture
    vec4 color = texture(sampler2D(image_atlas, image_sampler), in_tex_coord);

    // Apply grayscale effect
    if (in_grayscale > 0.0) {
        float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));
        color.rgb = mix(color.rgb, vec3(gray), in_grayscale);
    }

    // Apply tint (multiply blend)
    color *= in_tint_rgba;

    // Apply corner anti-aliasing and opacity
    color.a *= corner_alpha * in_opacity;

    if (color.a < 0.001) {
        discard;
    }

    out_color = color;
}
