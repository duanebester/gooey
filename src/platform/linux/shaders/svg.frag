#version 450

// Inputs from vertex shader
layout(location = 0) in vec2 in_tex_coord;
layout(location = 1) in vec4 in_fill_color;
layout(location = 2) in vec4 in_stroke_color;

// SVG atlas texture (RGBA format)
// R channel = fill alpha, G channel = stroke alpha
layout(set = 0, binding = 7) uniform texture2D svg_atlas;
layout(set = 0, binding = 9) uniform sampler svg_sampler;

// Output color
layout(location = 0) out vec4 out_color;

void main() {
    // Sample from RGBA atlas
    vec4 sample_value = texture(sampler2D(svg_atlas, svg_sampler), in_tex_coord);

    // Threshold to eliminate linear filtering bleed between channels
    float fill_alpha = sample_value.r > 0.02 ? sample_value.r : 0.0;
    float stroke_alpha = sample_value.g > 0.02 ? sample_value.g : 0.0;

    // Composite: stroke shows only where fill isn't
    float visible_stroke = stroke_alpha * (1.0 - fill_alpha);

    // Blend colors with their respective alphas
    vec3 rgb = in_fill_color.rgb * in_fill_color.a * fill_alpha
             + in_stroke_color.rgb * in_stroke_color.a * visible_stroke;
    float alpha = in_fill_color.a * fill_alpha + in_stroke_color.a * visible_stroke;

    // Discard fully transparent pixels
    if (alpha < 0.001) {
        discard;
    }

    out_color = vec4(rgb, alpha);
}
