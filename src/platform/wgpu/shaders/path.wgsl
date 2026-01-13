// Path rendering shader - renders triangulated path meshes
// Supports solid color fills and gradient fills (linear/radial)
// Port of gooey/src/platform/mac/metal/path_pipeline.zig

// Maximum gradient stops (must match GradientUniforms)
const MAX_STOPS: u32 = 16u;

// Epsilon for gradient range comparisons (avoids division by zero)
// Must match Metal shader constant for consistency
const GRADIENT_RANGE_EPSILON: f32 = 0.0001;

struct PathVertex {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
}

// PathInstance (112 bytes)
struct PathInstance {
    offset_x: f32,
    offset_y: f32,
    scale_x: f32,
    scale_y: f32,
    // Fill color (HSLA) - 4 floats
    fill_h: f32,
    fill_s: f32,
    fill_l: f32,
    fill_a: f32,
    // Clip bounds
    clip_x: f32,
    clip_y: f32,
    clip_width: f32,
    clip_height: f32,
    // Gradient fields
    gradient_type: u32,      // 0=none, 1=linear, 2=radial
    gradient_stop_count: u32,
    _grad_pad0: u32,
    _grad_pad1: u32,
    // Gradient params: linear(start_x, start_y, end_x, end_y) / radial(center_x, center_y, radius, inner_radius)
    grad_param0: f32,
    grad_param1: f32,
    grad_param2: f32,
    grad_param3: f32,
}

// GradientUniforms (352 bytes)
// Note: Arrays use vec4<f32> for 16-byte alignment required by uniform storage
// Each vec4 holds 4 consecutive stop values, so 4 vec4s = 16 stops
struct GradientUniforms {
    gradient_type: u32,
    stop_count: u32,
    _pad0: u32,
    _pad1: u32,
    param0: f32,  // linear: start_x / radial: center_x
    param1: f32,  // linear: start_y / radial: center_y
    param2: f32,  // linear: end_x / radial: radius
    param3: f32,  // linear: end_y / radial: inner_radius
    stop_offsets: array<vec4<f32>, 4>,
    stop_h: array<vec4<f32>, 4>,
    stop_s: array<vec4<f32>, 4>,
    stop_l: array<vec4<f32>, 4>,
    stop_a: array<vec4<f32>, 4>,
}

// Helper to access packed gradient arrays (index 0-15 -> vec4 array)
fn get_stop_offset(i: u32) -> f32 {
    return gradient.stop_offsets[i / 4u][i % 4u];
}
fn get_stop_h(i: u32) -> f32 {
    return gradient.stop_h[i / 4u][i % 4u];
}
fn get_stop_s(i: u32) -> f32 {
    return gradient.stop_s[i / 4u][i % 4u];
}
fn get_stop_l(i: u32) -> f32 {
    return gradient.stop_l[i / 4u][i % 4u];
}
fn get_stop_a(i: u32) -> f32 {
    return gradient.stop_a[i / 4u][i % 4u];
}

struct Uniforms {
    viewport_width: f32,
    viewport_height: f32,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) fill_color: vec4<f32>,
    @location(2) clip_bounds: vec4<f32>,
    @location(3) screen_pos: vec2<f32>,
    @location(4) @interpolate(flat) gradient_type: u32,
    @location(5) grad_params: vec4<f32>,
}

@group(0) @binding(0) var<storage, read> vertices: array<PathVertex>;
@group(0) @binding(1) var<uniform> instance: PathInstance;
@group(0) @binding(2) var<uniform> uniforms: Uniforms;
@group(0) @binding(3) var<uniform> gradient: GradientUniforms;

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

// Sample gradient at position t [0, 1]
fn sample_gradient(t_in: f32) -> vec4<f32> {
    let t = clamp(t_in, 0.0, 1.0);
    let count = gradient.stop_count;
    if count < 2u { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }

    // Find the two stops to interpolate between
    var i0: u32 = 0u;
    var i1: u32 = 1u;
    for (var i: u32 = 0u; i < count - 1u; i = i + 1u) {
        if t >= get_stop_offset(i) && t <= get_stop_offset(i + 1u) {
            i0 = i;
            i1 = i + 1u;
            break;
        }
    }

    // Calculate interpolation factor
    let offset0 = get_stop_offset(i0);
    let offset1 = get_stop_offset(i1);
    let range = offset1 - offset0;
    var factor: f32;
    if range > GRADIENT_RANGE_EPSILON {
        factor = (t - offset0) / range;
    } else {
        factor = 0.0;
    }

    // Get HSLA values for both stops
    var h0 = get_stop_h(i0);
    var h1 = get_stop_h(i1);
    let s0 = get_stop_s(i0);
    let s1 = get_stop_s(i1);
    let l0 = get_stop_l(i0);
    let l1 = get_stop_l(i1);
    let a0 = get_stop_a(i0);
    let a1 = get_stop_a(i1);

    // Handle hue wrapping (shortest path around color wheel)
    if abs(h1 - h0) > 0.5 {
        if h0 < h1 {
            h0 = h0 + 1.0;
        } else {
            h1 = h1 + 1.0;
        }
    }

    // Interpolate
    let h = (h0 + (h1 - h0) * factor) % 1.0;
    let s = s0 + (s1 - s0) * factor;
    let l = l0 + (l1 - l0) * factor;
    let a = a0 + (a1 - a0) * factor;

    return hsla_to_rgba(h, s, l, a);
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOutput {
    let v = vertices[vid];
    let viewport = vec2<f32>(uniforms.viewport_width, uniforms.viewport_height);

    // Apply transform: scale then translate
    let pos = vec2<f32>(
        v.x * instance.scale_x + instance.offset_x,
        v.y * instance.scale_y + instance.offset_y
    );

    // Convert to NDC
    let ndc = pos / viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);

    var out: VertexOutput;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.uv = vec2<f32>(v.u, v.v);
    out.fill_color = hsla_to_rgba(instance.fill_h, instance.fill_s, instance.fill_l, instance.fill_a);
    out.clip_bounds = vec4<f32>(instance.clip_x, instance.clip_y, instance.clip_width, instance.clip_height);
    out.screen_pos = pos;
    out.gradient_type = instance.gradient_type;
    out.grad_params = vec4<f32>(instance.grad_param0, instance.grad_param1, instance.grad_param2, instance.grad_param3);
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

    var color: vec4<f32>;

    if in.gradient_type == 1u {
        // Linear gradient
        let start = in.grad_params.xy;
        let end = in.grad_params.zw;
        let dir = end - start;
        let len_sq = dot(dir, dir);

        // Project UV onto gradient line
        var t: f32;
        if len_sq < 0.0001 {
            t = 0.0;
        } else {
            let p = in.uv;
            t = dot(p - start, dir) / len_sq;
        }

        color = sample_gradient(t);
    } else if in.gradient_type == 2u {
        // Radial gradient
        let center = in.grad_params.xy;
        let radius = in.grad_params.z;
        let inner_radius = in.grad_params.w;

        // Calculate distance from center in UV space
        let dist = length(in.uv - center);

        // Normalize to [0, 1] range
        var t: f32;
        if radius <= inner_radius {
            t = 1.0;
        } else {
            t = (dist - inner_radius) / (radius - inner_radius);
        }

        color = sample_gradient(t);
    } else {
        // Solid color fill
        color = in.fill_color;
    }

    if color.a < 0.001 { discard; }

    // Output premultiplied alpha
    return vec4<f32>(color.rgb * color.a, color.a);
}
