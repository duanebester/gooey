// Unified shader for rendering quads and shadows in a single draw call
// Port of gooey/src/platform/mac/metal/unified.zig

const PRIM_QUAD: u32 = 0u;
const PRIM_SHADOW: u32 = 1u;

struct Primitive {
    order: u32,
    primitive_type: u32,
    bounds_origin_x: f32,
    bounds_origin_y: f32,
    bounds_size_width: f32,
    bounds_size_height: f32,
    blur_radius: f32,
    offset_x: f32,
    // float4 background (HSLA)
    background_h: f32,
    background_s: f32,
    background_l: f32,
    background_a: f32,
    // float4 border_color (HSLA)
    border_color_h: f32,
    border_color_s: f32,
    border_color_l: f32,
    border_color_a: f32,
    // float4 corner_radii
    corner_radii_tl: f32,
    corner_radii_tr: f32,
    corner_radii_br: f32,
    corner_radii_bl: f32,
    // float4 border_widths
    border_width_top: f32,
    border_width_right: f32,
    border_width_bottom: f32,
    border_width_left: f32,
    // clip bounds
    clip_origin_x: f32,
    clip_origin_y: f32,
    clip_size_width: f32,
    clip_size_height: f32,
    // remaining
    offset_y: f32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
}

struct Uniforms {
    viewport_width: f32,
    viewport_height: f32,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) primitive_type: u32,
    @location(1) color: vec4<f32>,
    @location(2) border_color: vec4<f32>,
    @location(3) quad_coord: vec2<f32>,
    @location(4) quad_size: vec2<f32>,
    @location(5) corner_radii: vec4<f32>,
    @location(6) border_widths: vec4<f32>,
    @location(7) clip_bounds: vec4<f32>,
    @location(8) screen_pos: vec2<f32>,
    @location(9) content_size: vec2<f32>,
    @location(10) local_pos: vec2<f32>,
    @location(11) blur_radius: f32,
}


@group(0) @binding(0) var<storage, read> primitives: array<Primitive>;
@group(0) @binding(1) var<uniform> uniforms: Uniforms;

// Unit quad vertices inline (6 vertices for 2 triangles)
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
    if h < 1.0 {
        rgb = vec3<f32>(c, x, 0.0);
    } else if h < 2.0 {
        rgb = vec3<f32>(x, c, 0.0);
    } else if h < 3.0 {
        rgb = vec3<f32>(0.0, c, x);
    } else if h < 4.0 {
        rgb = vec3<f32>(0.0, x, c);
    } else if h < 5.0 {
        rgb = vec3<f32>(x, 0.0, c);
    } else {
        rgb = vec3<f32>(c, 0.0, x);
    }

    return vec4<f32>(rgb + m, a);
}

fn rounded_rect_sdf(pos: vec2<f32>, half_size: vec2<f32>, radius: f32) -> f32 {
    let d = abs(pos) - half_size + radius;
    return length(max(d, vec2<f32>(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

fn pick_corner_radius(pos: vec2<f32>, radii: vec4<f32>) -> f32 {
    if pos.x < 0.0 {
        if pos.y < 0.0 { return radii.x; }  // top-left
        else { return radii.w; }             // bottom-left
    } else {
        if pos.y < 0.0 { return radii.y; }  // top-right
        else { return radii.z; }             // bottom-right
    }
}

fn shadow_falloff(distance: f32, blur: f32) -> f32 {
    return 1.0 - smoothstep(-blur * 0.5, blur * 1.5, distance);
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> VertexOutput {
    let unit = get_unit_vertex(vid);
    let p = primitives[iid];
    let viewport_size = vec2<f32>(uniforms.viewport_width, uniforms.viewport_height);

    var out: VertexOutput;
    out.primitive_type = p.primitive_type;
    out.color = hsla_to_rgba(vec4<f32>(p.background_h, p.background_s, p.background_l, p.background_a));
    out.border_color = hsla_to_rgba(vec4<f32>(p.border_color_h, p.border_color_s, p.border_color_l, p.border_color_a));
    out.corner_radii = vec4<f32>(p.corner_radii_tl, p.corner_radii_tr, p.corner_radii_br, p.corner_radii_bl);
    out.border_widths = vec4<f32>(p.border_width_top, p.border_width_right, p.border_width_bottom, p.border_width_left);
    out.clip_bounds = vec4<f32>(p.clip_origin_x, p.clip_origin_y, p.clip_size_width, p.clip_size_height);
    out.blur_radius = p.blur_radius;

    if p.primitive_type == PRIM_QUAD {
        let origin = vec2<f32>(p.bounds_origin_x, p.bounds_origin_y);
        let size = vec2<f32>(p.bounds_size_width, p.bounds_size_height);
        let pos = origin + unit * size;
        let ndc = pos / viewport_size * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);

        out.position = vec4<f32>(ndc, 0.0, 1.0);
        out.quad_coord = unit;
        out.quad_size = size;
        out.screen_pos = pos;
        out.content_size = size;
        out.local_pos = vec2<f32>(0.0, 0.0);
    } else {
        let expand = p.blur_radius * 2.0;
        let content_origin = vec2<f32>(p.bounds_origin_x, p.bounds_origin_y);
        let content_size = vec2<f32>(p.bounds_size_width, p.bounds_size_height);
        let offset = vec2<f32>(p.offset_x, p.offset_y);
        let shadow_origin = content_origin + offset - expand;
        let shadow_size = content_size + expand * 2.0;
        let pos = shadow_origin + unit * shadow_size;
        let ndc = pos / viewport_size * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
        let local = (unit * shadow_size) - (shadow_size / 2.0) - offset;

        out.position = vec4<f32>(ndc, 0.0, 1.0);
        out.quad_coord = unit;
        out.quad_size = shadow_size;
        out.screen_pos = pos;
        out.content_size = content_size;
        out.local_pos = local;
    }

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    if in.primitive_type == PRIM_QUAD {
        let clip_min = in.clip_bounds.xy;
        let clip_max = clip_min + in.clip_bounds.zw;
        if in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
           in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y {
            discard;
        }

        let size = in.quad_size;
        let half_size = size / 2.0;
        let pos = in.quad_coord * size;
        let centered = pos - half_size;

        let radius = pick_corner_radius(centered, in.corner_radii);
        let outer_dist = rounded_rect_sdf(centered, half_size, radius);

        let bw = in.border_widths;
        let has_border = bw.x > 0.0 || bw.y > 0.0 || bw.z > 0.0 || bw.w > 0.0;

        var color = in.color;
        if has_border {
            var border: f32;
            if centered.x < 0.0 { border = bw.w; }
            else { border = bw.y; }
            if abs(centered.y) > abs(centered.x) {
                if centered.y < 0.0 { border = bw.x; }
                else { border = bw.z; }
            }

            let inner_radius = max(0.0, radius - border);
            let inner_half_size = half_size - vec2<f32>(border);
            let inner_dist = rounded_rect_sdf(centered, inner_half_size, inner_radius);
            let border_blend = smoothstep(-0.5, 0.5, inner_dist);
            color = mix(in.color, in.border_color, border_blend);
        }

        let alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);
        return color * vec4<f32>(1.0, 1.0, 1.0, alpha);
    } else {
        let half_size = in.content_size / 2.0;
        let radius = pick_corner_radius(in.local_pos, in.corner_radii);
        let dist = rounded_rect_sdf(in.local_pos, half_size, radius);
        let alpha = shadow_falloff(dist, in.blur_radius);
        return vec4<f32>(in.color.rgb, in.color.a * alpha);
    }
}
