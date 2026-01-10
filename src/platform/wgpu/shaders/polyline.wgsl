// Polyline rendering shader - renders line strips as expanded quads
// Optimized for chart data visualization with thousands of connected points
// Port of gooey/src/platform/mac/metal/polyline_pipeline.zig

struct PolylineVertex {
    x: f32,
    y: f32,
}

struct PolylineUniforms {
    color_h: f32,
    color_s: f32,
    color_l: f32,
    color_a: f32,
    clip_x: f32,
    clip_y: f32,
    clip_width: f32,
    clip_height: f32,
}

struct ViewportUniforms {
    viewport_width: f32,
    viewport_height: f32,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) clip_bounds: vec4<f32>,
    @location(2) screen_pos: vec2<f32>,
}

@group(0) @binding(0) var<storage, read> vertices: array<PolylineVertex>;
@group(0) @binding(1) var<uniform> uniforms: PolylineUniforms;
@group(0) @binding(2) var<uniform> viewport: ViewportUniforms;

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
fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOutput {
    let v = vertices[vid];
    let viewport_size = vec2<f32>(viewport.viewport_width, viewport.viewport_height);

    let pos = vec2<f32>(v.x, v.y);

    // Convert to NDC
    let ndc = pos / viewport_size * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);

    var out: VertexOutput;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.color = hsla_to_rgba(uniforms.color_h, uniforms.color_s, uniforms.color_l, uniforms.color_a);
    out.clip_bounds = vec4<f32>(uniforms.clip_x, uniforms.clip_y, uniforms.clip_width, uniforms.clip_height);
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

    if in.color.a < 0.001 { discard; }

    // Output premultiplied alpha
    return vec4<f32>(in.color.rgb * in.color.a, in.color.a);
}
