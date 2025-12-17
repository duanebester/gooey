// Text/glyph rendering shader
// Port of gooey/src/platform/mac/metal/text.zig

struct GlyphInstance {
    pos_x: f32,
    pos_y: f32,
    size_x: f32,
    size_y: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
    color_h: f32,
    color_s: f32,
    color_l: f32,
    color_a: f32,
    clip_x: f32,
    clip_y: f32,
    clip_width: f32,
    clip_height: f32,
}

struct Uniforms {
    viewport_width: f32,
    viewport_height: f32,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) tex_coord: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) clip_bounds: vec4<f32>,
    @location(3) screen_pos: vec2<f32>,
}

@group(0) @binding(0) var<storage, read> glyphs: array<GlyphInstance>;
@group(0) @binding(1) var<uniform> uniforms: Uniforms;
@group(0) @binding(2) var atlas_texture: texture_2d<f32>;
@group(0) @binding(3) var atlas_sampler: sampler;

fn get_unit_vertex(vid: u32) -> vec2<f32> {
    switch vid {
        case 0u: { return vec2<f32>(0.0, 0.0); }
        case 1u: { return vec2<f32>(1.0, 0.0); }
        case 2u: { return vec2<f32>(0.0, 1.0); }
        case 3u: { return vec2<f32>(1.0, 0.0); }
        case 4u: { return vec2<f32>(1.0, 1.0); }
        case 5u: { return vec2<f32>(0.0, 1.0); }
        default: { return vec2<f32>(0.0, 0.0); }
    }
}

fn hsla_to_rgba(hsla: vec4<f32>) -> vec4<f32> {
    let h = hsla.x * 6.0;
    let s = hsla.y;
    let l = hsla.z;
    let a = hsla.w;
    let c = (1.0 - abs(2.0 * l - 1.0)) * s;
    let x = c * (1.0 - abs(h % 2.0 - 1.0));
    let m = l - c / 2.0;
    var rgb: vec3<f32>;
    if h < 1.0 { rgb = vec3<f32>(c, x, 0.0); }
    else if h < 2.0 { rgb = vec3<f32>(x, c, 0.0); }
    else if h < 3.0 { rgb = vec3<f32>(0.0, c, x); }
    else if h < 4.0 { rgb = vec3<f32>(0.0, x, c); }
    else if h < 5.0 { rgb = vec3<f32>(x, 0.0, c); }
    else { rgb = vec3<f32>(c, 0.0, x); }
    return vec4<f32>(rgb + m, a);
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> VertexOutput {
    let unit = get_unit_vertex(vid);
    let g = glyphs[iid];
    let viewport_size = vec2<f32>(uniforms.viewport_width, uniforms.viewport_height);

    let pos = vec2<f32>(g.pos_x, g.pos_y) + unit * vec2<f32>(g.size_x, g.size_y);
    let ndc = pos / viewport_size * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    let uv = vec2<f32>(
        mix(g.uv_left, g.uv_right, unit.x),
        mix(g.uv_top, g.uv_bottom, unit.y)
    );

    var out: VertexOutput;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.tex_coord = uv;
    out.color = hsla_to_rgba(vec4<f32>(g.color_h, g.color_s, g.color_l, g.color_a));
    out.clip_bounds = vec4<f32>(g.clip_x, g.clip_y, g.clip_width, g.clip_height);
    out.screen_pos = pos;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let clip_min = in.clip_bounds.xy;
    let clip_max = clip_min + in.clip_bounds.zw;
    if in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
       in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y {
        discard;
    }
    let alpha = textureSample(atlas_texture, atlas_sampler, in.tex_coord).r;
    return vec4<f32>(in.color.rgb, in.color.a * alpha);
}
