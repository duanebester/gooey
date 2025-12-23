// SVG rendering shader - samples from RGBA atlas
// R channel = fill alpha, G channel = stroke alpha
// Port of gooey/src/platform/mac/metal/svg_pipeline.zig

struct SvgInstance {
    pos_x: f32,
    pos_y: f32,
    size_x: f32,
    size_y: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
    // Fill color (HSLA) - 4 floats
    fill_h: f32,
    fill_s: f32,
    fill_l: f32,
    fill_a: f32,
    // Stroke color (HSLA) - 4 floats
    stroke_h: f32,
    stroke_s: f32,
    stroke_l: f32,
    stroke_a: f32,
    // Clip bounds
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
    @location(1) fill_color: vec4<f32>,
    @location(2) stroke_color: vec4<f32>,
    @location(3) clip_bounds: vec4<f32>,
    @location(4) screen_pos: vec2<f32>,
}

@group(0) @binding(0) var<storage, read> svgs: array<SvgInstance>;
@group(0) @binding(1) var<uniform> uniforms: Uniforms;
@group(0) @binding(2) var svg_atlas: texture_2d<f32>;
@group(0) @binding(3) var svg_sampler: sampler;

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

fn hsla_to_rgba(h: f32, s: f32, l: f32, a: f32) -> vec4<f32> {
    let hue = h * 6.0;
    let c = (1.0 - abs(2.0 * l - 1.0)) * s;
    let x = c * (1.0 - abs(hue % 2.0 - 1.0));
    let m = l - c / 2.0;
    var rgb: vec3<f32>;
    if hue < 1.0 { rgb = vec3<f32>(c, x, 0.0); }
    else if hue < 2.0 { rgb = vec3<f32>(x, c, 0.0); }
    else if hue < 3.0 { rgb = vec3<f32>(0.0, c, x); }
    else if hue < 4.0 { rgb = vec3<f32>(0.0, x, c); }
    else if hue < 5.0 { rgb = vec3<f32>(x, 0.0, c); }
    else { rgb = vec3<f32>(c, 0.0, x); }
    return vec4<f32>(rgb + m, a);
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> VertexOutput {
    let unit = get_unit_vertex(vid);
    let s = svgs[iid];
    let viewport = vec2<f32>(uniforms.viewport_width, uniforms.viewport_height);

    let pos = vec2<f32>(s.pos_x, s.pos_y) + unit * vec2<f32>(s.size_x, s.size_y);
    let ndc = pos / viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    let uv = vec2<f32>(
        mix(s.uv_left, s.uv_right, unit.x),
        mix(s.uv_top, s.uv_bottom, unit.y)
    );

    var out: VertexOutput;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.tex_coord = uv;
    out.fill_color = hsla_to_rgba(s.fill_h, s.fill_s, s.fill_l, s.fill_a);
    out.stroke_color = hsla_to_rgba(s.stroke_h, s.stroke_s, s.stroke_l, s.stroke_a);
    out.clip_bounds = vec4<f32>(s.clip_x, s.clip_y, s.clip_width, s.clip_height);
    out.screen_pos = pos;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Clip test
    let clip_min = in.clip_bounds.xy;
    let clip_max = clip_min + in.clip_bounds.zw;
    if in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
       in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y {
        discard;
    }

    let sample = textureSample(svg_atlas, svg_sampler, in.tex_coord);

    // Threshold to eliminate linear filtering bleed between channels
    let fill_alpha = select(0.0, sample.r, sample.r > 0.02);
    let stroke_alpha = select(0.0, sample.g, sample.g > 0.02);

    // Composite: stroke shows only where fill isn't
    let visible_stroke = stroke_alpha * (1.0 - fill_alpha);

    // Blend colors
    let rgb = in.fill_color.rgb * in.fill_color.a * fill_alpha
            + in.stroke_color.rgb * in.stroke_color.a * visible_stroke;
    let alpha = in.fill_color.a * fill_alpha + in.stroke_color.a * visible_stroke;

    if alpha < 0.001 { discard; }
    return vec4<f32>(rgb, alpha);
}
