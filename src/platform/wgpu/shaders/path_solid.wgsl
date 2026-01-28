// Phase 2: Solid path rendering shader - baked transforms and colors
// No gradient support - solid color only, enables single draw call per clip region
// Port of gooey/src/platform/mac/metal/path_pipeline.zig solid_path_shader_source

// Solid path vertex - transform and color baked in at upload time (32 bytes)
struct SolidPathVertex {
    x: f32,       // Already transformed screen position
    y: f32,
    u: f32,       // UV (preserved for future use)
    v: f32,
    color_h: f32, // HSLA color baked in
    color_s: f32,
    color_l: f32,
    color_a: f32,
}

// Clip bounds shared by entire batch (16 bytes)
struct ClipBounds {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
}

struct Uniforms {
    viewport_width: f32,
    viewport_height: f32,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) fill_color: vec4<f32>,
    @location(1) clip_bounds: vec4<f32>,
    @location(2) screen_pos: vec2<f32>,
}

@group(0) @binding(0) var<storage, read> vertices: array<SolidPathVertex>;
@group(0) @binding(1) var<uniform> clip: ClipBounds;
@group(0) @binding(2) var<uniform> uniforms: Uniforms;

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
    let viewport = vec2<f32>(uniforms.viewport_width, uniforms.viewport_height);

    // Position already transformed at upload time - just convert to NDC
    let pos = vec2<f32>(v.x, v.y);
    let ndc = pos / viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);

    var out: VertexOutput;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.fill_color = hsla_to_rgba(v.color_h, v.color_s, v.color_l, v.color_a);
    out.clip_bounds = vec4<f32>(clip.x, clip.y, clip.width, clip.height);
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

    // Solid color - no gradient sampling needed
    let color = in.fill_color;
    if color.a < 0.001 { discard; }

    // Output premultiplied alpha
    return vec4<f32>(color.rgb * color.a, color.a);
}
