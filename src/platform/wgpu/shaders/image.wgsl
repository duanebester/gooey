// Image rendering shader - textured quads with effects
// Samples from RGBA atlas texture
// Supports tint, opacity, grayscale, and rounded corners

// ImageInstance struct (112 bytes, matches Zig extern struct)
struct ImageInstance {
    // Draw order (offset 0)
    order: u32,
    _pad0: u32,

    // Position and size (offset 8)
    pos_x: f32,
    pos_y: f32,
    dest_width: f32,
    dest_height: f32,

    // UV coordinates (offset 24)
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,

    // Padding for tint alignment (offset 40)
    _pad1: u32,
    _pad2: u32,

    // Tint color HSLA (offset 48, 16-byte aligned)
    tint_h: f32,
    tint_s: f32,
    tint_l: f32,
    tint_a: f32,

    // Clip bounds (offset 64)
    clip_x: f32,
    clip_y: f32,
    clip_width: f32,
    clip_height: f32,

    // Corner radii (offset 80)
    corner_tl: f32,
    corner_tr: f32,
    corner_br: f32,
    corner_bl: f32,

    // Effects (offset 96)
    grayscale: f32,
    opacity: f32,
    _pad3: f32,
    _pad4: f32,
}

struct Uniforms {
    viewport_width: f32,
    viewport_height: f32,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) tex_coord: vec2<f32>,
    @location(1) local_pos: vec2<f32>,
    @location(2) local_size: vec2<f32>,
    @location(3) corner_radii: vec4<f32>,
    @location(4) clip_bounds: vec4<f32>,
    @location(5) screen_pos: vec2<f32>,
    @location(6) tint: vec4<f32>,
    @location(7) effects: vec2<f32>,
}

@group(0) @binding(0) var<storage, read> images: array<ImageInstance>;
@group(0) @binding(1) var<uniform> uniforms: Uniforms;
@group(0) @binding(2) var image_atlas: texture_2d<f32>;
@group(0) @binding(3) var image_sampler: sampler;

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

// Signed distance function for rounded rectangle
fn rounded_rect_sdf(pos: vec2<f32>, size: vec2<f32>, radii: vec4<f32>) -> f32 {
    // Determine which corner radius to use based on quadrant
    var radius: f32;
    if pos.x < size.x * 0.5 {
        if pos.y < size.y * 0.5 {
            radius = radii.x; // top-left
        } else {
            radius = radii.w; // bottom-left
        }
    } else {
        if pos.y < size.y * 0.5 {
            radius = radii.y; // top-right
        } else {
            radius = radii.z; // bottom-right
        }
    }

    // Clamp radius to half the minimum dimension
    let max_radius = min(size.x, size.y) * 0.5;
    radius = min(radius, max_radius);

    // Calculate distance from rounded rect edge
    let half_size = size * 0.5;
    let center = half_size;
    let q = abs(pos - center) - half_size + radius;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> VertexOutput {
    let unit = get_unit_vertex(vid);
    let img = images[iid];
    let viewport = vec2<f32>(uniforms.viewport_width, uniforms.viewport_height);

    // Screen position
    let size = vec2<f32>(img.dest_width, img.dest_height);
    let pos = vec2<f32>(img.pos_x, img.pos_y) + unit * size;

    // Convert to NDC
    let ndc = pos / viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);

    // Interpolate UVs
    let uv = vec2<f32>(
        mix(img.uv_left, img.uv_right, unit.x),
        mix(img.uv_top, img.uv_bottom, unit.y)
    );

    // Local position within the quad (for rounded corners)
    let local = unit * size;

    var out: VertexOutput;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.tex_coord = uv;
    out.local_pos = local;
    out.local_size = size;
    out.corner_radii = vec4<f32>(img.corner_tl, img.corner_tr, img.corner_br, img.corner_bl);
    out.clip_bounds = vec4<f32>(img.clip_x, img.clip_y, img.clip_width, img.clip_height);
    out.screen_pos = pos;
    out.tint = hsla_to_rgba(img.tint_h, img.tint_s, img.tint_l, img.tint_a);
    out.effects = vec2<f32>(img.grayscale, img.opacity);
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

    // Rounded corner test
    let has_corners = in.corner_radii.x > 0.0 || in.corner_radii.y > 0.0 ||
                      in.corner_radii.z > 0.0 || in.corner_radii.w > 0.0;
    var corner_alpha = 1.0;
    if has_corners {
        let dist = rounded_rect_sdf(in.local_pos, in.local_size, in.corner_radii);
        if dist > 0.5 { discard; }
        // Anti-alias the edge
        corner_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
    }

    // Sample texture
    var color = textureSample(image_atlas, image_sampler, in.tex_coord);

    // Apply grayscale effect
    let grayscale_amount = in.effects.x;
    if grayscale_amount > 0.0 {
        let gray = dot(color.rgb, vec3<f32>(0.299, 0.587, 0.114));
        color = vec4<f32>(mix(color.rgb, vec3<f32>(gray), grayscale_amount), color.a);
    }

    // Apply tint (multiply blend)
    color = vec4<f32>(color.rgb * in.tint.rgb, color.a * in.tint.a);

    // Apply opacity
    let opacity = in.effects.y;
    color.a *= opacity;

    // Apply corner anti-aliasing
    color.a *= corner_alpha;

    if color.a < 0.001 { discard; }

    // Premultiply alpha for correct blending
    color = vec4<f32>(color.rgb * color.a, color.a);
    return color;
}
