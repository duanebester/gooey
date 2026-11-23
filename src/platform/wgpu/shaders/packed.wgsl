
struct Quad {
    bounds: vec4<f32>,
    fill: vec4<f32>,
    border_color: vec4<f32>,
    corners: vec4<f32>,
    border_widths: vec4<f32>,
    offset: vec2<f32>,
    blur: f32,
    pad: f32,
}

struct Sprite {
    bounds: vec4<f32>,
    uv: vec4<f32>,
    tint: vec4<f32>,
    secondary: vec4<f32>,
    corners: vec4<f32>,
    grayscale: f32,
    opacity: f32,
    pad0: f32,
    pad1: f32,
}

struct Mesh {
    fill: vec4<f32>,
    first: u32,
    count: u32,
    width: f32,
    edge_first: u32,
}

struct Viewport {
    size: vec4<f32>,
}

@group(0) @binding(0) var<storage, read> quads: array<Quad>;
@group(0) @binding(1) var<storage, read> sprites: array<Sprite>;
@group(0) @binding(2) var<storage, read> meshes: array<Mesh>;
@group(0) @binding(3) var<storage, read> mesh_points: array<vec2<f32>>;
@group(0) @binding(4) var<storage, read> edge_modes: array<u32>;
@group(0) @binding(5) var<uniform> viewport: Viewport;
@group(0) @binding(6) var glyph_atlas: texture_2d<f32>;
@group(0) @binding(7) var svg_atlas: texture_2d<f32>;
@group(0) @binding(8) var image_atlas: texture_2d<f32>;
@group(0) @binding(9) var atlas_sampler: sampler;

const aa_fringe: f32 = 1.0;

fn unit_vertex(vertex: u32) -> vec2<f32> {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0),
    );
    return corners[vertex];
}

fn to_clip_space(pos: vec2<f32>) -> vec4<f32> {
    let ndc = pos / viewport.size.xy * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    return vec4<f32>(ndc, 0.0, 1.0);
}

fn axis_coverage(pos: f32, size: f32, pixel: f32) -> f32 {
    let low = max(pos - 0.5 * pixel, 0.0);
    let high = min(pos + 0.5 * pixel, size);
    let coverage = clamp((high - low) / max(pixel, 1e-6), 0.0, 1.0);
    if (coverage > 0.999) {
        return 1.0;
    }
    if (coverage < 0.001) {
        return 0.0;
    }
    return coverage;
}

fn pixel_extent(value: vec2<f32>) -> vec2<f32> {
    let dx = dpdx(value);
    let dy = dpdy(value);
    return vec2<f32>(length(vec2<f32>(dx.x, dy.x)), length(vec2<f32>(dx.y, dy.y)));
}


fn rounded_rect_sdf(pos: vec2<f32>, half_size: vec2<f32>, radius: f32) -> f32 {
    let d = abs(pos) - half_size + radius;
    return length(max(d, vec2<f32>(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

fn pick_corner_radius(pos: vec2<f32>, radii: vec4<f32>) -> f32 {
    if (pos.x < 0.0) {
        return select(radii.w, radii.x, pos.y < 0.0);
    }
    return select(radii.z, radii.y, pos.y < 0.0);
}

fn shadow_falloff(distance: f32, blur: f32) -> f32 {
    return 1.0 - smoothstep(-blur * 0.5, blur * 1.5, distance);
}

struct QuadOut {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) is_shadow: u32,
    @location(1) color: vec4<f32>,
    @location(2) border_color: vec4<f32>,
    @location(3) quad_coord: vec2<f32>,
    @location(4) quad_size: vec2<f32>,
    @location(5) corner_radii: vec4<f32>,
    @location(6) border_widths: vec4<f32>,
    @location(7) content_size: vec2<f32>,
    @location(8) local_pos: vec2<f32>,
    @location(9) blur_radius: f32,
}

@vertex
fn quad_vertex(
    @builtin(vertex_index) vertex: u32,
    @builtin(instance_index) instance: u32,
) -> QuadOut {
    let unit = unit_vertex(vertex);
    let q = quads[instance];
    var out: QuadOut;
    out.is_shadow = select(0u, 1u, q.blur > 0.0);
    out.color = q.fill;
    out.border_color = q.border_color;
    out.corner_radii = q.corners;
    out.border_widths = q.border_widths;
    out.blur_radius = q.blur;
    let origin = q.bounds.xy;
    let size = q.bounds.zw;
    if (out.is_shadow == 0u) {
        let fringe = select(0.0, 1.0, size.x > 0.0 && size.y > 0.0);
        let pos = origin - fringe + unit * (size + 2.0 * fringe);
        out.position = to_clip_space(pos);
        out.quad_coord = pos - origin;
        out.quad_size = size;
        out.content_size = size;
        out.local_pos = vec2<f32>(0.0, 0.0);
    } else {
        let expand = q.blur * 2.0;
        let shadow_origin = origin + q.offset - expand;
        let shadow_size = size + expand * 2.0;
        let pos = shadow_origin + unit * shadow_size;
        out.position = to_clip_space(pos);
        out.quad_coord = unit;
        out.quad_size = shadow_size;
        out.content_size = size;
        out.local_pos = (unit * shadow_size) - (shadow_size / 2.0) - q.offset;
    }
    return out;
}

fn quad_color(in: QuadOut, pixel: vec2<f32>) -> vec4<f32> {
    let size = in.quad_size;
    let half_size = size / 2.0;
    let pos = in.quad_coord;
    let centered = pos - half_size;
    let rect_coverage = axis_coverage(pos.x, size.x, pixel.x) *
        axis_coverage(pos.y, size.y, pixel.y);
    let radius = pick_corner_radius(centered, in.corner_radii);
    let outer_dist = rounded_rect_sdf(centered, half_size, radius);
    let bw = in.border_widths;
    let has_border = bw.x > 0.0 || bw.y > 0.0 || bw.z > 0.0 || bw.w > 0.0;
    var color = in.color;
    if (has_border) {
        let inner_min = vec2<f32>(-half_size.x + bw.w, -half_size.y + bw.x);
        let inner_max = vec2<f32>(half_size.x - bw.y, half_size.y - bw.z);
        let inner_center = (inner_min + inner_max) * 0.5;
        let inner_half_size = max(vec2<f32>(0.0), (inner_max - inner_min) * 0.5);
        let inner_pos = centered - inner_center;
        let cr = in.corner_radii;
        let inner_radii = vec4<f32>(
            max(0.0, cr.x - max(bw.x, bw.w)),
            max(0.0, cr.y - max(bw.x, bw.y)),
            max(0.0, cr.z - max(bw.z, bw.y)),
            max(0.0, cr.w - max(bw.z, bw.w)),
        );
        let inner_radius = pick_corner_radius(inner_pos, inner_radii);
        let inner_dist = rounded_rect_sdf(inner_pos, inner_half_size, inner_radius);
        let border_blend = smoothstep(-0.5, 0.5, inner_dist);
        color = mix(in.color, in.border_color, border_blend);
    }
    let alpha = (1.0 - smoothstep(-0.5, 0.5, outer_dist)) * rect_coverage;
    return color * vec4<f32>(1.0, 1.0, 1.0, alpha);
}

@fragment
fn quad_fragment(in: QuadOut) -> @location(0) vec4<f32> {
    let pixel = pixel_extent(in.quad_coord);
    if (in.is_shadow == 0u) {
        let color = quad_color(in, pixel);
        if (color.a <= 0.0) {
            discard;
        }
        return color;
    }
    let half_size = in.content_size / 2.0;
    let radius = pick_corner_radius(in.local_pos, in.corner_radii);
    let dist = rounded_rect_sdf(in.local_pos, half_size, radius);
    let alpha = shadow_falloff(dist, in.blur_radius);
    return vec4<f32>(in.color.rgb, in.color.a * alpha);
}


struct TextOut {
    @builtin(position) position: vec4<f32>,
    @location(0) tex_coord: vec2<f32>,
    @location(1) color: vec4<f32>,
}

@vertex
fn text_vertex(
    @builtin(vertex_index) vertex: u32,
    @builtin(instance_index) instance: u32,
) -> TextOut {
    let unit = unit_vertex(vertex);
    let g = sprites[instance];
    let pos = g.bounds.xy + unit * g.bounds.zw;
    var out: TextOut;
    out.position = to_clip_space(pos);
    out.tex_coord = vec2<f32>(mix(g.uv.x, g.uv.z, unit.x), mix(g.uv.y, g.uv.w, unit.y));
    out.color = g.tint;
    return out;
}

@fragment
fn text_fragment(in: TextOut) -> @location(0) vec4<f32> {
    let alpha = textureSample(glyph_atlas, atlas_sampler, in.tex_coord).r;
    return vec4<f32>(in.color.rgb, in.color.a * alpha);
}

struct IconOut {
    @builtin(position) position: vec4<f32>,
    @location(0) tex_coord: vec2<f32>,
    @location(1) fill_color: vec4<f32>,
    @location(2) stroke_color: vec4<f32>,
    @location(3) local_pos: vec2<f32>,
    @location(4) size: vec2<f32>,
    @location(5) corner_radii: vec4<f32>,
    @location(6) effects: vec2<f32>,
}

@vertex
fn icon_vertex(
    @builtin(vertex_index) vertex: u32,
    @builtin(instance_index) instance: u32,
) -> IconOut {
    let unit = unit_vertex(vertex);
    let s = sprites[instance];
    let origin = s.bounds.xy;
    let size = s.bounds.zw;
    let fringe = select(0.0, 1.0, size.x > 0.0 && size.y > 0.0);
    let local = unit * (size + 2.0 * fringe) - fringe;
    let t = local / max(size, vec2<f32>(1e-6));
    var out: IconOut;
    out.position = to_clip_space(origin + local);
    out.tex_coord = vec2<f32>(mix(s.uv.x, s.uv.z, t.x), mix(s.uv.y, s.uv.w, t.y));
    out.fill_color = s.tint;
    out.stroke_color = s.secondary;
    out.local_pos = local;
    out.size = size;
    out.corner_radii = s.corners;
    out.effects = vec2<f32>(s.grayscale, s.opacity);
    return out;
}

fn rect_coverage(local_pos: vec2<f32>, size: vec2<f32>, pixel: vec2<f32>) -> f32 {
    return axis_coverage(local_pos.x, size.x, pixel.x) *
        axis_coverage(local_pos.y, size.y, pixel.y);
}

@fragment
fn svg_fragment(in: IconOut) -> @location(0) vec4<f32> {
    let coverage = rect_coverage(in.local_pos, in.size, pixel_extent(in.local_pos));
    let sample = textureSample(svg_atlas, atlas_sampler, in.tex_coord);
    let fill_alpha = select(0.0, sample.r, sample.r > 0.02);
    let stroke_alpha = select(0.0, sample.g, sample.g > 0.02);
    let visible_stroke = stroke_alpha * (1.0 - fill_alpha);
    let rgb = in.fill_color.rgb * in.fill_color.a * fill_alpha +
        in.stroke_color.rgb * in.stroke_color.a * visible_stroke;
    let alpha = in.fill_color.a * fill_alpha + in.stroke_color.a * visible_stroke;
    if (alpha * coverage < 0.001) {
        discard;
    }
    return vec4<f32>(rgb * coverage, alpha * coverage);
}

fn image_rounded_rect_sdf(pos: vec2<f32>, half_size: vec2<f32>, radii: vec4<f32>) -> f32 {
    var r = select(radii.x, radii.w, pos.y > 0.0);
    if (pos.x > 0.0) {
        r = select(radii.y, radii.z, pos.y > 0.0);
    }
    let q = abs(pos) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0))) - r;
}

@fragment
fn image_fragment(in: IconOut) -> @location(0) vec4<f32> {
    let coverage = rect_coverage(in.local_pos, in.size, pixel_extent(in.local_pos));
    var color = textureSample(image_atlas, atlas_sampler, in.tex_coord);
    var corner_alpha = 1.0;
    let radii = in.corner_radii;
    if (max(max(radii.x, radii.y), max(radii.z, radii.w)) > 0.0) {
        let half_size = in.size * 0.5;
        let dist = image_rounded_rect_sdf(in.local_pos - half_size, half_size, radii);
        corner_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
    }
    let grayscale = in.effects.x;
    if (grayscale > 0.0) {
        let gray = dot(color.rgb, vec3<f32>(0.299, 0.587, 0.114));
        color = vec4<f32>(mix(color.rgb, vec3<f32>(gray), grayscale), color.a);
    }
    color *= in.fill_color;
    color.a *= corner_alpha * in.effects.y * coverage;
    if (color.a < 0.001) {
        discard;
    }
    return color;
}


struct MeshOut {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) edge_distance: vec4<f32>,
    @location(2) @interpolate(flat) modes: u32,
    @location(3) uv: vec2<f32>,
}

const triangle_draw_vertex_count: u32 = 21u;
const fringe_vertex_count: u32 = 6u;
const miter_max: f32 = 4.0 * aa_fringe;

fn corner_shift(n0: vec2<f32>, n1: vec2<f32>, offset0: f32, offset1: f32) -> vec2<f32> {
    let det = n0.x * n1.y - n0.y * n1.x;
    var shift = -max(offset0, offset1) * n0;
    if (abs(det) > 1e-4) {
        shift = vec2<f32>(-offset0 * n1.y + offset1 * n0.y,
            -offset1 * n0.x + offset0 * n1.x) / det;
    }
    let shift_length = length(shift);
    if (shift_length > miter_max) {
        shift *= miter_max / shift_length;
    }
    return shift;
}

fn fringe_corner(slot: u32, modes: u32, degenerate: bool) -> vec2<u32> {
    if (slot < 3u) {
        return vec2<u32>(slot, 0u);
    }
    let edge = (slot - 3u) / fringe_vertex_count;
    let quad_vertex = slot - 3u - edge * fringe_vertex_count;
    if (degenerate || ((modes >> (2u * edge)) & 3u) == 0u) {
        return vec2<u32>(edge, 0u);
    }
    let at_end = quad_vertex == 1u || quad_vertex == 2u || quad_vertex == 4u;
    let outer = quad_vertex == 2u || quad_vertex == 4u || quad_vertex == 5u;
    return vec2<u32>(select(edge, (edge + 1u) % 3u, at_end), select(0u, 1u, outer));
}

@vertex
fn triangle_vertex(
    @builtin(vertex_index) vertex: u32,
    @builtin(instance_index) mesh_index: u32,
) -> MeshOut {
    let mesh = meshes[mesh_index];
    let triangle = vertex / triangle_draw_vertex_count;
    let slot = vertex - triangle * triangle_draw_vertex_count;
    let first = mesh.first + triangle * 3u;
    var corners = array<vec2<f32>, 3>(
        mesh_points[first], mesh_points[first + 1u], mesh_points[first + 2u],
    );
    let modes = edge_modes[mesh.edge_first + triangle];
    let area = (corners[1].x - corners[0].x) * (corners[2].y - corners[0].y) -
        (corners[1].y - corners[0].y) * (corners[2].x - corners[0].x);
    var normals: array<vec2<f32>, 3>;
    var lengths: array<f32, 3>;
    for (var edge = 0u; edge < 3u; edge++) {
        let direction = corners[(edge + 1u) % 3u] - corners[edge];
        lengths[edge] = length(direction);
        normals[edge] = vec2<f32>(-direction.y, direction.x) * sign(area) /
            max(lengths[edge], 1e-12);
    }
    let shortest = min(lengths[0], min(lengths[1], lengths[2]));
    let degenerate = abs(area) < 1e-6 || shortest < 1e-6;
    let placed = fringe_corner(slot, modes, degenerate);
    let k = placed.x;
    var pos = corners[k];
    var distances = vec4<f32>(1e4);
    if (!degenerate) {
        if (placed.y == 1u) {
            let before = (k + 2u) % 3u;
            let offset_k = select(0.0, aa_fringe, ((modes >> (2u * k)) & 3u) != 0u);
            let offset_before = select(0.0, aa_fringe, ((modes >> (2u * before)) & 3u) != 0u);
            pos += corner_shift(normals[k], normals[before], offset_k, offset_before);
        }
        for (var edge = 0u; edge < 3u; edge++) {
            distances[edge] = dot(pos - corners[edge], normals[edge]);
        }
    }
    var out: MeshOut;
    out.position = to_clip_space(pos);
    out.color = mesh.fill;
    out.edge_distance = distances;
    out.modes = select(modes, 0u, degenerate);
    out.uv = vec2<f32>(0.0);
    return out;
}

fn segment_corner(vertex: u32) -> vec2<f32> {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, 1.0), vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0),
        vec2<f32>(-1.0, 1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
    );
    return corners[vertex];
}

@vertex
fn polyline_vertex(
    @builtin(vertex_index) vertex: u32,
    @builtin(instance_index) mesh_index: u32,
) -> MeshOut {
    let mesh = meshes[mesh_index];
    let segment = vertex / 6u;
    let half_width = mesh.width * 0.5;
    let segment_count = mesh.count - 1u;
    let start = mesh_points[mesh.first + segment];
    let end = mesh_points[mesh.first + segment + 1u];
    let direction = end - start;
    let distance = length(direction);
    var along_unit = vec2<f32>(1.0, 0.0);
    var across_unit = vec2<f32>(0.0, 1.0);
    let has_length = distance > 0.0001;
    if (has_length) {
        along_unit = direction / distance;
        across_unit = vec2<f32>(-along_unit.y, along_unit.x);
    }
    let cap_start = has_length && segment == 0u;
    let cap_end = has_length && segment + 1u == segment_count;
    let corner = segment_corner(vertex - segment * 6u);
    let across = corner.y * (half_width + aa_fringe);
    var along = distance + select(0.0, aa_fringe, cap_end);
    if (corner.x < 0.0) {
        along = select(0.0, -aa_fringe, cap_start);
    }
    let pos = start + along_unit * along + across_unit * across;
    var out: MeshOut;
    out.position = to_clip_space(pos);
    out.color = mesh.fill;
    out.edge_distance = vec4<f32>(half_width + across, half_width - across,
        along, distance - along);
    out.modes = 1u | (1u << 2u) | select(0u, 1u << 4u, cap_start) | select(0u, 1u << 6u, cap_end);
    out.uv = vec2<f32>(0.0);
    return out;
}

fn edge_coverage(distance: vec4<f32>, pixel: vec4<f32>, modes: u32) -> f32 {
    let distance_px = distance / max(pixel, vec4<f32>(1e-6));
    var coverage = 1.0;
    for (var edge = 0u; edge < 4u; edge++) {
        let mode = (modes >> (2u * edge)) & 3u;
        if (mode == 1u) {
            coverage *= clamp(distance_px[edge] + 0.5, 0.0, 1.0);
        } else {
            if (mode == 2u && distance_px[edge] < -0.5) {
                coverage = 0.0;
            }
        }
    }
    return coverage;
}

@fragment
fn edge_fragment(in: MeshOut) -> @location(0) vec4<f32> {
    let dx = dpdx(in.edge_distance);
    let dy = dpdy(in.edge_distance);
    let pixel = sqrt(dx * dx + dy * dy);
    let coverage = edge_coverage(in.edge_distance, pixel, in.modes);
    let alpha = in.color.a * coverage;
    if (alpha < 0.001) {
        discard;
    }
    return vec4<f32>(in.color.rgb * alpha, alpha);
}

fn point_corner(vertex: u32) -> vec2<f32> {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0),
    );
    return corners[vertex];
}

@vertex
fn point_vertex(
    @builtin(vertex_index) vertex: u32,
    @builtin(instance_index) mesh_index: u32,
) -> MeshOut {
    let mesh = meshes[mesh_index];
    let point = vertex / 6u;
    let radius = mesh.width;
    let corner = point_corner(vertex - point * 6u);
    let extent = select(0.0, radius + aa_fringe, radius > 0.0);
    let pos = mesh_points[mesh.first + point] + corner * extent;
    var out: MeshOut;
    out.position = to_clip_space(pos);
    out.color = mesh.fill;
    out.edge_distance = vec4<f32>(1e4);
    out.modes = 0u;
    out.uv = corner * (extent / max(radius, 1e-6));
    return out;
}

@fragment
fn point_fragment(in: MeshOut) -> @location(0) vec4<f32> {
    let uv_pixel = length(vec2<f32>(dpdx(in.uv.x), dpdy(in.uv.x)));
    let radius_px = 1.0 / max(uv_pixel, 1e-6);
    let dist = length(in.uv);
    var alpha = 1.0 - smoothstep(0.85, 1.0, dist);
    if (radius_px < 1.0 / 0.15) {
        let end_px = radius_px + 0.5 * (1.0 - 0.15 * radius_px);
        alpha = 1.0 - smoothstep(end_px - 1.0, end_px, dist * radius_px);
    }
    let result = in.color.a * alpha;
    if (result < 0.001) {
        discard;
    }
    return vec4<f32>(in.color.rgb * result, result);
}
