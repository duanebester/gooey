#version 450

layout(location = 0) in vec2 in_tex_coord;
layout(location = 1) in vec4 in_color;

// Glyph coverage atlas (R8): coverage in the red channel.
layout(set = 0, binding = 6) uniform texture2D glyph_atlas;
layout(set = 0, binding = 9) uniform sampler atlas_sampler;

layout(location = 0) out vec4 out_color;

void main() {
    float alpha = texture(sampler2D(glyph_atlas, atlas_sampler), in_tex_coord).r;
    out_color = vec4(in_color.rgb, in_color.a * alpha);
}
