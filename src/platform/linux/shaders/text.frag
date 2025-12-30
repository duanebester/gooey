#version 450

// Inputs from vertex shader
layout(location = 0) in vec2 in_tex_coord;
layout(location = 1) in vec4 in_color;
layout(location = 2) in vec4 in_clip_bounds;
layout(location = 3) in vec2 in_screen_pos;

// Atlas texture (R8 format - single channel alpha)
layout(set = 0, binding = 2) uniform texture2D atlas_texture;
layout(set = 0, binding = 3) uniform sampler atlas_sampler;

// Output color
layout(location = 0) out vec4 out_color;

void main() {
    // Clip test
    vec2 clip_min = in_clip_bounds.xy;
    vec2 clip_max = clip_min + in_clip_bounds.zw;
    if (in_screen_pos.x < clip_min.x || in_screen_pos.x > clip_max.x ||
        in_screen_pos.y < clip_min.y || in_screen_pos.y > clip_max.y) {
        discard;
    }

    // Sample alpha from atlas (R8 texture - alpha in red channel)
    float alpha = texture(sampler2D(atlas_texture, atlas_sampler), in_tex_coord).r;

    // Output color with sampled alpha
    out_color = vec4(in_color.rgb, in_color.a * alpha);
}
