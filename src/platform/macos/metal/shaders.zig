//! The Metal shader library for the packed frame (contract §9): one source,
//! compiled once at init, with one vertex and one fragment function per
//! `packed_frame.Pipeline`.
//!
//! The structs mirror `packed_frame.zig` field for field, so `Renderer.draw`
//! copies each instance array into its buffer unchanged. Colours arrive as
//! straight RGBA. Every fragment function discards pixels whose centre lies
//! outside its draw's clip rectangle (fragment `buffer(0)`), edges inclusive.
//!
//! The coverage, SDF, edge, and falloff math is the 0.3.1 Metal shaders'
//! unchanged, so frames match `main` within rounding; only colour conversion
//! (HSLA is gone) and the clip source moved. Shadows now take their draw's
//! clip like every other instance.
//!
//! Bindings, shared by every pipeline so `draw` binds each buffer once per frame:
//! vertex buffers 0 quads, 1 sprites, 2 mesh points, 3 triangle edge modes,
//! 4 the current mesh (32 B inline), 5 the viewport in logical pixels;
//! fragment buffer 0 the clip rectangle; fragment textures 0 glyph, 1 SVG,
//! 2 image atlas.

const std = @import("std");
const packed_frame = @import("../../../core/packed_frame.zig");
const mesh_edges = @import("../../mesh_edges.zig");

const assert = std.debug.assert;

pub const buffer_quads: u32 = 0;
pub const buffer_sprites: u32 = 1;
pub const buffer_points: u32 = 2;
pub const buffer_edge_modes: u32 = 3;
pub const buffer_mesh: u32 = 4;
pub const buffer_viewport: u32 = 5;
pub const fragment_buffer_clip: u32 = 0;
pub const texture_glyph: u32 = 0;
pub const texture_svg: u32 = 1;
pub const texture_image: u32 = 2;

/// Draw vertices per triangle: the triangle, then a fringe quad per edge.
pub const triangle_draw_vertex_count: u32 = 21;
/// Vertices per quad, sprite, line segment, or point instance.
pub const instance_vertex_count: u32 = 6;

comptime {
    // The source hard-codes these layouts and counts.
    assert(mesh_edges.triangle_draw_vertex_count == triangle_draw_vertex_count);
    assert(@sizeOf(packed_frame.Quad) == 96);
    assert(@offsetOf(packed_frame.Quad, "offset") == 84);
    assert(@sizeOf(packed_frame.Sprite) == 96);
    assert(@offsetOf(packed_frame.Sprite, "opacity") == 84);
    assert(@sizeOf(packed_frame.Mesh) == 32);
    assert(@offsetOf(packed_frame.Mesh, "edge_first") == 28);
    assert(@sizeOf(packed_frame.MeshPoint) == 8);
}

pub const source = common ++ quad ++ sprite_text ++ sprite_svg ++ sprite_image ++
    triangles ++ polyline ++ point_cloud;

const common =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// packed_frame.Quad (96 B). A shadow is a quad with blur > 0.
    \\struct Quad {
    \\    float4 bounds;
    \\    float4 fill;
    \\    float4 border_color;
    \\    float4 corners;
    \\    float4 border_widths;
    \\    float blur;
    \\    float offset_x;
    \\    float offset_y;
    \\    float _pad;
    \\};
    \\
    \\// packed_frame.Sprite (96 B).
    \\struct Sprite {
    \\    float4 bounds;
    \\    float4 uv;
    \\    float4 tint;
    \\    float4 secondary;
    \\    float4 corners;
    \\    float grayscale;
    \\    float opacity;
    \\    float _pad0;
    \\    float _pad1;
    \\};
    \\
    \\// packed_frame.Mesh (32 B).
    \\struct Mesh {
    \\    float4 fill;
    \\    uint first;
    \\    uint count;
    \\    float width;
    \\    uint edge_first;
    \\};
    \\
    \\constant float2 unit_vertices[6] = {
    \\    float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
    \\    float2(1.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0),
    \\};
    \\
    \\// One logical pixel is at least one device pixel at every supported scale.
    \\constant float aa_fringe = 1.0;
    \\
    \\float4 to_clip_space(float2 pos, float2 viewport) {
    \\    float2 ndc = pos / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\    return float4(ndc, 0.0, 1.0);
    \\}
    \\
    \\// The draw's clip rectangle (x, y, width, height), edges inclusive.
    \\bool outside_clip(float2 pos, float4 clip) {
    \\    float2 clip_min = clip.xy;
    \\    float2 clip_max = clip_min + clip.zw;
    \\    return pos.x < clip_min.x || pos.x > clip_max.x ||
    \\        pos.y < clip_min.y || pos.y > clip_max.y;
    \\}
    \\
    \\// Share of a pixel's extent along one axis inside [0, size]: the overlap of
    \\// [pos - pixel/2, pos + pixel/2] with the rectangle, where `pos` is the
    \\// pixel centre and `pixel` one device pixel, both in logical pixels. Exact
    \\// for a box filter, including rectangles thinner than a pixel.
    \\// Interpolation leaves float noise in `pos`, so a pixel within 1/1000 of
    \\// full or empty counts as such: pixel-aligned sides give exactly 1 or 0.
    \\float axis_coverage(float pos, float size, float pixel) {
    \\    float low = max(pos - 0.5 * pixel, 0.0);
    \\    float high = min(pos + 0.5 * pixel, size);
    \\    float coverage = clamp((high - low) / max(pixel, 1e-6), 0.0, 1.0);
    \\    if (coverage > 0.999) return 1.0;
    \\    if (coverage < 0.001) return 0.0;
    \\    return coverage;
    \\}
    \\
;

const quad =
    \\float rounded_rect_sdf(float2 pos, float2 half_size, float radius) {
    \\    float2 d = abs(pos) - half_size + radius;
    \\    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
    \\}
    \\
    \\float pick_corner_radius(float2 pos, float4 radii) {
    \\    if (pos.x < 0.0) {
    \\        return pos.y < 0.0 ? radii.x : radii.w;
    \\    } else {
    \\        return pos.y < 0.0 ? radii.y : radii.z;
    \\    }
    \\}
    \\
    \\float shadow_falloff(float distance, float blur) {
    \\    return 1.0 - smoothstep(-blur * 0.5, blur * 1.5, distance);
    \\}
    \\
    \\struct QuadOut {
    \\    float4 position [[position]];
    \\    uint is_shadow [[flat]];
    \\    float4 color;
    \\    float4 border_color;
    \\    float2 quad_coord;
    \\    float2 quad_size;
    \\    float4 corner_radii;
    \\    float4 border_widths;
    \\    float2 screen_pos;
    \\    float2 content_size;
    \\    float2 local_pos;
    \\    float blur_radius;
    \\};
    \\
    \\vertex QuadOut quad_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    device const Quad *quads [[buffer(0)]],
    \\    constant float2 &viewport [[buffer(5)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    Quad q = quads[iid];
    \\    QuadOut out;
    \\    out.is_shadow = q.blur > 0.0 ? 1u : 0u;
    \\    out.color = q.fill;
    \\    out.border_color = q.border_color;
    \\    out.corner_radii = q.corners;
    \\    out.border_widths = q.border_widths;
    \\    out.blur_radius = q.blur;
    \\    float2 origin = q.bounds.xy;
    \\    float2 size = q.bounds.zw;
    \\    if (out.is_shadow == 0u) {
    \\        // One sample per pixel: grow the quad by one logical pixel so pixels
    \\        // the rectangle only partly covers are rasterized; the fragment
    \\        // shader weights them by that coverage. Empty quads stay empty.
    \\        float fringe = (size.x > 0.0 && size.y > 0.0) ? 1.0 : 0.0;
    \\        float2 pos = origin - fringe + unit * (size + 2.0 * fringe);
    \\        out.position = to_clip_space(pos, viewport);
    \\        // Quad-local position in logical pixels; outside [0, size] in the fringe.
    \\        out.quad_coord = pos - origin;
    \\        out.quad_size = size;
    \\        out.screen_pos = pos;
    \\        out.content_size = size;
    \\        out.local_pos = float2(0, 0);
    \\    } else {
    \\        float expand = q.blur * 2.0;
    \\        float2 offset = float2(q.offset_x, q.offset_y);
    \\        float2 shadow_origin = origin + offset - expand;
    \\        float2 shadow_size = size + expand * 2.0;
    \\        float2 pos = shadow_origin + unit * shadow_size;
    \\        out.position = to_clip_space(pos, viewport);
    \\        out.quad_coord = unit;
    \\        out.quad_size = shadow_size;
    \\        out.screen_pos = pos;
    \\        out.content_size = size;
    \\        out.local_pos = (unit * shadow_size) - (shadow_size / 2.0) - offset;
    \\    }
    \\    return out;
    \\}
    \\
    \\float4 quad_color(QuadOut in, float2 pixel) {
    \\    float2 size = in.quad_size;
    \\    float2 half_size = size / 2.0;
    \\    float2 pos = in.quad_coord;
    \\    float2 centered = pos - half_size;
    \\    // The pixel's coverage by the quad's rectangle. Pixels inside the
    \\    // rectangle, including rounded corners, are fully covered.
    \\    float rect_coverage = axis_coverage(pos.x, size.x, pixel.x) *
    \\        axis_coverage(pos.y, size.y, pixel.y);
    \\    float radius = pick_corner_radius(centered, in.corner_radii);
    \\    float outer_dist = rounded_rect_sdf(centered, half_size, radius);
    \\    float4 bw = in.border_widths;
    \\    bool has_border = bw.x > 0.0 || bw.y > 0.0 || bw.z > 0.0 || bw.w > 0.0;
    \\    float4 color = in.color;
    \\    if (has_border) {
    \\        // bw: x=top, y=right, z=bottom, w=left. The inner rounded rect
    \\        // insets each side independently, with per-corner inner radii
    \\        // reduced by the larger of the two adjacent border widths.
    \\        float2 inner_min = float2(-half_size.x + bw.w, -half_size.y + bw.x);
    \\        float2 inner_max = float2(half_size.x - bw.y, half_size.y - bw.z);
    \\        float2 inner_center = (inner_min + inner_max) * 0.5;
    \\        float2 inner_half_size = max(float2(0.0), (inner_max - inner_min) * 0.5);
    \\        float2 inner_pos = centered - inner_center;
    \\        float4 cr = in.corner_radii;
    \\        float4 inner_radii = float4(
    \\            max(0.0, cr.x - max(bw.x, bw.w)),
    \\            max(0.0, cr.y - max(bw.x, bw.y)),
    \\            max(0.0, cr.z - max(bw.z, bw.y)),
    \\            max(0.0, cr.w - max(bw.z, bw.w))
    \\        );
    \\        float inner_radius = pick_corner_radius(inner_pos, inner_radii);
    \\        float inner_dist = rounded_rect_sdf(inner_pos, inner_half_size, inner_radius);
    \\        float border_blend = smoothstep(-0.5, 0.5, inner_dist);
    \\        color = mix(in.color, in.border_color, border_blend);
    \\    }
    \\    float alpha = (1.0 - smoothstep(-0.5, 0.5, outer_dist)) * rect_coverage;
    \\    return color * float4(1.0, 1.0, 1.0, alpha);
    \\}
    \\
    \\fragment float4 quad_fragment(
    \\    QuadOut in [[stage_in]],
    \\    constant float4 &clip [[buffer(0)]]
    \\) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    // quad_coord is affine, so these are logical pixels per device pixel.
    \\    float2 pixel = float2(length(float2(dfdx(in.quad_coord.x), dfdy(in.quad_coord.x))),
    \\                          length(float2(dfdx(in.quad_coord.y), dfdy(in.quad_coord.y))));
    \\    if (outside_clip(in.screen_pos, clip)) discard_fragment();
    \\    if (in.is_shadow == 0u) {
    \\        float4 color = quad_color(in, pixel);
    \\        if (color.a <= 0.0) discard_fragment();
    \\        return color;
    \\    }
    \\    float2 half_size = in.content_size / 2.0;
    \\    float radius = pick_corner_radius(in.local_pos, in.corner_radii);
    \\    float dist = rounded_rect_sdf(in.local_pos, half_size, radius);
    \\    float alpha = shadow_falloff(dist, in.blur_radius);
    \\    return float4(in.color.rgb, in.color.a * alpha);
    \\}
    \\
;

const sprite_text =
    \\struct TextOut {
    \\    float4 position [[position]];
    \\    float2 tex_coord;
    \\    float4 color;
    \\    float2 screen_pos;
    \\};
    \\
    \\vertex TextOut text_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    device const Sprite *sprites [[buffer(1)]],
    \\    constant float2 &viewport [[buffer(5)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    Sprite g = sprites[iid];
    \\    float2 pos = g.bounds.xy + unit * g.bounds.zw;
    \\    TextOut out;
    \\    out.position = to_clip_space(pos, viewport);
    \\    out.tex_coord = float2(mix(g.uv.x, g.uv.z, unit.x), mix(g.uv.y, g.uv.w, unit.y));
    \\    out.color = g.tint;
    \\    out.screen_pos = pos;
    \\    return out;
    \\}
    \\
    \\fragment float4 text_fragment(
    \\    TextOut in [[stage_in]],
    \\    constant float4 &clip [[buffer(0)]],
    \\    texture2d<float> atlas [[texture(0)]]
    \\) {
    \\    if (outside_clip(in.screen_pos, clip)) discard_fragment();
    \\    constexpr sampler s(mag_filter::linear, min_filter::linear);
    \\    float alpha = atlas.sample(s, in.tex_coord).r;
    \\    return float4(in.color.rgb, in.color.a * alpha);
    \\}
    \\
;

const sprite_svg =
    \\struct IconOut {
    \\    float4 position [[position]];
    \\    float2 tex_coord;
    \\    float4 fill_color;
    \\    float4 stroke_color;
    \\    float2 screen_pos;
    \\    // Position from the icon's origin in logical pixels; outside
    \\    // [0, size] in the fringe.
    \\    float2 local_pos;
    \\    float2 size;
    \\};
    \\
    \\vertex IconOut svg_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    device const Sprite *sprites [[buffer(1)]],
    \\    constant float2 &viewport [[buffer(5)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    Sprite icon = sprites[iid];
    \\    // One sample per pixel: grow the quad by one logical pixel so pixels the
    \\    // icon's rectangle only partly covers are rasterized; the fragment
    \\    // shader weights them by that coverage. Atlas coordinates extrapolate
    \\    // linearly, so every pixel samples where it would without the fringe.
    \\    float2 origin = icon.bounds.xy;
    \\    float2 size = icon.bounds.zw;
    \\    float fringe = (size.x > 0.0 && size.y > 0.0) ? 1.0 : 0.0;
    \\    float2 local = unit * (size + 2.0 * fringe) - fringe;
    \\    float2 pos = origin + local;
    \\    float2 t = local / max(size, float2(1e-6));
    \\    IconOut out;
    \\    out.position = to_clip_space(pos, viewport);
    \\    out.tex_coord = float2(mix(icon.uv.x, icon.uv.z, t.x), mix(icon.uv.y, icon.uv.w, t.y));
    \\    out.fill_color = icon.tint;
    \\    out.stroke_color = icon.secondary;
    \\    out.screen_pos = pos;
    \\    out.local_pos = local;
    \\    out.size = size;
    \\    return out;
    \\}
    \\
    \\fragment float4 svg_fragment(
    \\    IconOut in [[stage_in]],
    \\    constant float4 &clip [[buffer(0)]],
    \\    texture2d<float> atlas [[texture(1)]]
    \\) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    float2 pixel = float2(length(float2(dfdx(in.local_pos.x), dfdy(in.local_pos.x))),
    \\                          length(float2(dfdx(in.local_pos.y), dfdy(in.local_pos.y))));
    \\    float rect_coverage = axis_coverage(in.local_pos.x, in.size.x, pixel.x) *
    \\        axis_coverage(in.local_pos.y, in.size.y, pixel.y);
    \\    if (outside_clip(in.screen_pos, clip)) discard_fragment();
    \\    constexpr sampler s(mag_filter::linear, min_filter::linear);
    \\    float4 sample = atlas.sample(s, in.tex_coord);
    \\    // Threshold to eliminate linear filtering bleed between channels.
    \\    float fill_alpha = sample.r > 0.02 ? sample.r : 0.0;
    \\    float stroke_alpha = sample.g > 0.02 ? sample.g : 0.0;
    \\    // Stroke shows only where fill does not.
    \\    float visible_stroke = stroke_alpha * (1.0 - fill_alpha);
    \\    float3 rgb = in.fill_color.rgb * in.fill_color.a * fill_alpha
    \\               + in.stroke_color.rgb * in.stroke_color.a * visible_stroke;
    \\    float alpha = in.fill_color.a * fill_alpha + in.stroke_color.a * visible_stroke;
    \\    // Premultiplied output: coverage scales colour and alpha alike.
    \\    rgb *= rect_coverage;
    \\    alpha *= rect_coverage;
    \\    if (alpha < 0.001) discard_fragment();
    \\    return float4(rgb, alpha);
    \\}
    \\
;

const sprite_image =
    \\struct ImageOut {
    \\    float4 position [[position]];
    \\    float2 tex_coord;
    \\    float4 tint_rgba;
    \\    float2 screen_pos;
    \\    float2 image_origin;
    \\    float2 size;
    \\    float4 corner_radii;
    \\    float grayscale;
    \\    float opacity;
    \\};
    \\
    \\vertex ImageOut image_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    device const Sprite *sprites [[buffer(1)]],
    \\    constant float2 &viewport [[buffer(5)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    Sprite img = sprites[iid];
    \\    // The same one-pixel fringe and uv extrapolation as svg_vertex.
    \\    float2 origin = img.bounds.xy;
    \\    float2 size = img.bounds.zw;
    \\    float fringe = (size.x > 0.0 && size.y > 0.0) ? 1.0 : 0.0;
    \\    float2 local = unit * (size + 2.0 * fringe) - fringe;
    \\    float2 pos = origin + local;
    \\    float2 t = local / max(size, float2(1e-6));
    \\    ImageOut out;
    \\    out.position = to_clip_space(pos, viewport);
    \\    out.tex_coord = float2(mix(img.uv.x, img.uv.z, t.x), mix(img.uv.y, img.uv.w, t.y));
    \\    out.tint_rgba = img.tint;
    \\    out.screen_pos = pos;
    \\    out.image_origin = origin;
    \\    out.size = size;
    \\    out.corner_radii = img.corners;
    \\    out.grayscale = img.grayscale;
    \\    out.opacity = img.opacity;
    \\    return out;
    \\}
    \\
    \\float image_rounded_rect_sdf(float2 pos, float2 half_size, float4 radii) {
    \\    float r = pos.x > 0.0
    \\        ? (pos.y > 0.0 ? radii.z : radii.y)
    \\        : (pos.y > 0.0 ? radii.w : radii.x);
    \\    float2 q = abs(pos) - half_size + r;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    \\}
    \\
    \\fragment float4 image_fragment(
    \\    ImageOut in [[stage_in]],
    \\    constant float4 &clip [[buffer(0)]],
    \\    texture2d<float> atlas [[texture(2)]]
    \\) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    float2 pixel = float2(length(float2(dfdx(in.screen_pos.x), dfdy(in.screen_pos.x))),
    \\                          length(float2(dfdx(in.screen_pos.y), dfdy(in.screen_pos.y))));
    \\    float2 rect_pos = in.screen_pos - in.image_origin;
    \\    float rect_coverage = axis_coverage(rect_pos.x, in.size.x, pixel.x) *
    \\        axis_coverage(rect_pos.y, in.size.y, pixel.y);
    \\    if (outside_clip(in.screen_pos, clip)) discard_fragment();
    \\    float corner_alpha = 1.0;
    \\    float max_radius = max(max(in.corner_radii.x, in.corner_radii.y),
    \\                           max(in.corner_radii.z, in.corner_radii.w));
    \\    if (max_radius > 0.0) {
    \\        float2 half_size = in.size * 0.5;
    \\        float2 local_pos = in.screen_pos - in.image_origin - half_size;
    \\        float dist = image_rounded_rect_sdf(local_pos, half_size, in.corner_radii);
    \\        corner_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
    \\        if (corner_alpha < 0.001) discard_fragment();
    \\    }
    \\    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    \\    float4 color = atlas.sample(s, in.tex_coord);
    \\    if (in.grayscale > 0.0) {
    \\        float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    \\        color.rgb = mix(color.rgb, float3(gray), in.grayscale);
    \\    }
    \\    color *= in.tint_rgba;
    \\    color.a *= corner_alpha * in.opacity * rect_coverage;
    \\    if (color.a < 0.001) discard_fragment();
    \\    return color;
    \\}
    \\
;

const triangles =
    \\// A sharp corner's offset point is clamped; tips sharper than about 14
    \\// degrees lose part of their fade band instead of producing long slivers.
    \\constant float miter_max = 4.0 * aa_fringe;
    \\constant uint triangle_draw_vertex_count = 21;
    \\constant uint fringe_vertex_count = 6;
    \\
    \\struct TriangleOut {
    \\    float4 position [[position]];
    \\    float4 fill_color;
    \\    float2 screen_pos;
    \\    // Signed distances in logical pixels to the three original edges,
    \\    // positive inside. Affine in screen space, so interpolation is exact.
    \\    float3 edge_distance;
    \\    uint edge_modes [[flat]];
    \\};
    \\
    \\// Offset of a corner on edges with inward unit normals n0 and n1: the
    \\// intersection of the two edges' offset lines, each pushed outward by its
    \\// offset. Every fringe vertex at a corner calls this with the same inputs,
    \\// so neighbouring quads share their common side exactly.
    \\float2 corner_shift(float2 n0, float2 n1, float offset0, float offset1) {
    \\    float det = n0.x * n1.y - n0.y * n1.x;
    \\    float2 shift;
    \\    if (abs(det) > 1e-4) {
    \\        shift = float2(-offset0 * n1.y + offset1 * n0.y,
    \\                       -offset1 * n0.x + offset0 * n1.x) / det;
    \\    } else {
    \\        // Nearly straight corner: the two offset lines coincide.
    \\        shift = -max(offset0, offset1) * n0;
    \\    }
    \\    float shift_length = length(shift);
    \\    if (shift_length > miter_max) shift *= miter_max / shift_length;
    \\    return shift;
    \\}
    \\
    \\// Draw vertex `slot` of a triangle: its exact corner k (slots 0-2), or a
    \\// vertex of the fringe quad on edge (slot - 3) / 6, whose outer side
    \\// joins the two corners' offset points. Interior edges get no quad: their
    \\// six vertices collapse onto one point. See mesh_edges.zig.
    \\uint fringe_corner(uint slot, uint modes, bool degenerate, thread bool &outer) {
    \\    outer = false;
    \\    if (slot < 3) return slot;
    \\    uint edge = (slot - 3) / fringe_vertex_count;
    \\    uint quad_vertex = slot - 3 - edge * fringe_vertex_count;
    \\    if (degenerate || ((modes >> (2 * edge)) & 3) == 0) return edge;
    \\    // Quad (inner start, inner end, outer end), (inner start, outer end, outer start).
    \\    bool at_end = quad_vertex == 1 || quad_vertex == 2 || quad_vertex == 4;
    \\    outer = quad_vertex == 2 || quad_vertex == 4 || quad_vertex == 5;
    \\    return at_end ? (edge + 1) % 3 : edge;
    \\}
    \\
    \\// `vertexStart` is the mesh's `edge_first` × 21, so `vid / 21` is the
    \\// triangle's index in the frame's edge modes.
    \\vertex TriangleOut triangle_vertex(
    \\    uint vid [[vertex_id]],
    \\    device const float2 *points [[buffer(2)]],
    \\    device const uint *edge_modes [[buffer(3)]],
    \\    constant Mesh &mesh [[buffer(4)]],
    \\    constant float2 &viewport [[buffer(5)]]
    \\) {
    \\    uint triangle = vid / triangle_draw_vertex_count;
    \\    uint slot = vid - triangle * triangle_draw_vertex_count;
    \\    uint first = mesh.first + (triangle - mesh.edge_first) * 3;
    \\    float2 corners[3] = { points[first], points[first + 1], points[first + 2] };
    \\    uint modes = edge_modes[triangle];
    \\    float area = (corners[1].x - corners[0].x) * (corners[2].y - corners[0].y) -
    \\        (corners[1].y - corners[0].y) * (corners[2].x - corners[0].x);
    \\    float2 normals[3];
    \\    float lengths[3];
    \\    for (uint edge = 0; edge < 3; edge++) {
    \\        float2 direction = corners[(edge + 1) % 3] - corners[edge];
    \\        lengths[edge] = length(direction);
    \\        normals[edge] = float2(-direction.y, direction.x) * sign(area) /
    \\            max(lengths[edge], 1e-12);
    \\    }
    \\    float shortest = min(lengths[0], min(lengths[1], lengths[2]));
    \\    bool degenerate = abs(area) < 1e-6 || shortest < 1e-6;
    \\    bool outer;
    \\    uint k = fringe_corner(slot, modes, degenerate, outer);
    \\    float2 pos = corners[k];
    \\    float3 distances = float3(1e4);
    \\    if (!degenerate) {
    \\        if (outer) {
    \\            // Corner k lies on edge k (k -> k+1) and edge k-1 (k-1 -> k).
    \\            uint before = (k + 2) % 3;
    \\            float offset_k = ((modes >> (2 * k)) & 3) != 0 ? aa_fringe : 0.0;
    \\            float offset_before = ((modes >> (2 * before)) & 3) != 0 ? aa_fringe : 0.0;
    \\            pos += corner_shift(normals[k], normals[before], offset_k, offset_before);
    \\        }
    \\        for (uint edge = 0; edge < 3; edge++) {
    \\            distances[edge] = dot(pos - corners[edge], normals[edge]);
    \\        }
    \\    }
    \\    TriangleOut out;
    \\    out.position = to_clip_space(pos, viewport);
    \\    out.fill_color = mesh.fill;
    \\    out.screen_pos = pos;
    \\    out.edge_distance = distances;
    \\    // A degenerate triangle covers no pixel samples: unfaded, without quads.
    \\    out.edge_modes = degenerate ? 0u : modes;
    \\    return out;
    \\}
    \\
    \\// Coverage of the fragment's pixel from the analytic edges. `pixel` is one
    \\// device pixel measured in edge-distance units per component.
    \\float edge_coverage(float3 distance, float3 pixel, uint modes) {
    \\    float3 distance_px = distance / max(pixel, float3(1e-6));
    \\    float coverage = 1.0;
    \\    for (uint edge = 0; edge < 3; edge++) {
    \\        uint mode = (modes >> (2 * edge)) & 3;
    \\        if (mode == 1) {
    \\            coverage *= clamp(distance_px[edge] + 0.5, 0.0, 1.0);
    \\        } else if (mode == 2 && distance_px[edge] < -0.5) {
    \\            coverage = 0.0;
    \\        }
    \\    }
    \\    return coverage;
    \\}
    \\
    \\fragment float4 triangle_fragment(
    \\    TriangleOut in [[stage_in]],
    \\    constant float4 &clip [[buffer(0)]]
    \\) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    float3 edge_dx = dfdx(in.edge_distance);
    \\    float3 edge_dy = dfdy(in.edge_distance);
    \\    float3 edge_pixel = sqrt(edge_dx * edge_dx + edge_dy * edge_dy);
    \\    if (outside_clip(in.screen_pos, clip)) discard_fragment();
    \\    float4 color = in.fill_color;
    \\    float coverage = edge_coverage(in.edge_distance, edge_pixel, in.edge_modes);
    \\    if (coverage <= 0.0) discard_fragment();
    \\    color.a *= coverage;
    \\    if (color.a < 0.001) discard_fragment();
    \\    return float4(color.rgb * color.a, color.a);
    \\}
    \\
;

const polyline =
    \\// Quad corner of each vertex of triangles 0-1-2 and 0-2-3, as (along,
    \\// across) signs: corner 0 is start+perp, 1 start-perp, 2 end-perp, 3 end+perp.
    \\constant float2 segment_corners[6] = {
    \\    float2(-1.0, 1.0), float2(-1.0, -1.0), float2(1.0, -1.0),
    \\    float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    \\};
    \\
    \\struct LineOut {
    \\    float4 position [[position]];
    \\    float4 color;
    \\    float2 screen_pos;
    \\    // Signed distances in logical pixels to the segment's two sides and its
    \\    // start and end, positive inside. Affine, so interpolation is exact.
    \\    float4 edge_distance;
    \\    // Two bits per distance; 1 fades across that edge (mesh_edges.EdgeMode).
    \\    uint edge_modes [[flat]];
    \\};
    \\
    \\// One instance per segment: a butt-ended quad from point `segment` to the
    \\// next, half the width either side, grown by `aa_fringe` across both sides
    \\// so their fade is rasterized. Only the line's first start cap and last
    \\// end cap extend and fade; interior joints stay hard, so consecutive
    \\// segments overlap without a seam.
    \\vertex LineOut polyline_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint segment [[instance_id]],
    \\    device const float2 *points [[buffer(2)]],
    \\    constant Mesh &mesh [[buffer(4)]],
    \\    constant float2 &viewport [[buffer(5)]]
    \\) {
    \\    float half_width = mesh.width * 0.5;
    \\    uint segment_count = mesh.count - 1;
    \\    float2 start = points[mesh.first + segment];
    \\    float2 end = points[mesh.first + segment + 1];
    \\    float2 direction = end - start;
    \\    float distance = length(direction);
    \\    // Zero-length segments keep their degenerate quad: they cover no pixels.
    \\    float2 along_unit = float2(1.0, 0.0);
    \\    float2 across_unit = float2(0.0, 1.0);
    \\    bool has_length = distance > 0.0001;
    \\    if (has_length) {
    \\        along_unit = direction / distance;
    \\        across_unit = float2(-along_unit.y, along_unit.x);
    \\    }
    \\    bool cap_start = has_length && segment == 0;
    \\    bool cap_end = has_length && segment + 1 == segment_count;
    \\    float2 corner = segment_corners[vid];
    \\    float across = corner.y * (half_width + aa_fringe);
    \\    float along = corner.x < 0.0 ? (cap_start ? -aa_fringe : 0.0) :
    \\        distance + (cap_end ? aa_fringe : 0.0);
    \\    float2 pos = start + along_unit * along + across_unit * across;
    \\    LineOut out;
    \\    out.position = to_clip_space(pos, viewport);
    \\    out.color = mesh.fill;
    \\    out.screen_pos = pos;
    \\    out.edge_distance = float4(half_width + across, half_width - across,
    \\                               along, distance - along);
    \\    out.edge_modes = 1u | (1u << 2) | (cap_start ? 1u << 4 : 0u) |
    \\        (cap_end ? 1u << 6 : 0u);
    \\    return out;
    \\}
    \\
    \\fragment float4 polyline_fragment(
    \\    LineOut in [[stage_in]],
    \\    constant float4 &clip [[buffer(0)]]
    \\) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    float4 edge_dx = dfdx(in.edge_distance);
    \\    float4 edge_dy = dfdy(in.edge_distance);
    \\    float4 edge_pixel = sqrt(edge_dx * edge_dx + edge_dy * edge_dy);
    \\    if (outside_clip(in.screen_pos, clip)) discard_fragment();
    \\    // Fade across every flagged edge over one device pixel centred on it.
    \\    float4 distance_px = in.edge_distance / max(edge_pixel, float4(1e-6));
    \\    float coverage = 1.0;
    \\    for (uint edge = 0; edge < 4; edge++) {
    \\        if (((in.edge_modes >> (2 * edge)) & 3) == 1) {
    \\            coverage *= clamp(distance_px[edge] + 0.5, 0.0, 1.0);
    \\        }
    \\    }
    \\    float alpha = in.color.a * coverage;
    \\    if (alpha < 0.001) discard_fragment();
    \\    return float4(in.color.rgb * alpha, alpha);
    \\}
    \\
;

const point_cloud =
    \\// SDF uv corner of each vertex of triangles 0-1-2 and 0-2-3 of the quad
    \\// (-1,-1)--(1,-1) over (-1,1)--(1,1).
    \\constant float2 point_corners[6] = {
    \\    float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    \\    float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0),
    \\};
    \\
    \\struct PointOut {
    \\    float4 position [[position]];
    \\    float4 color;
    \\    float2 screen_pos;
    \\    float2 uv;
    \\};
    \\
    \\// One instance per point. The quad reaches one logical pixel past the
    \\// radius so the falloff can straddle the circle's edge; uv stays 1.0 at
    \\// the radius. Multiplying by a +-1 corner is exact, so even a fused
    \\// multiply-add yields `position +- extent` correctly rounded.
    \\vertex PointOut point_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint point [[instance_id]],
    \\    device const float2 *points [[buffer(2)]],
    \\    constant Mesh &mesh [[buffer(4)]],
    \\    constant float2 &viewport [[buffer(5)]]
    \\) {
    \\    float radius = mesh.width;
    \\    float2 corner = point_corners[vid];
    \\    float extent = radius + 1.0;
    \\    float2 pos = points[mesh.first + point] + corner * extent;
    \\    PointOut out;
    \\    out.position = to_clip_space(pos, viewport);
    \\    out.color = mesh.fill;
    \\    out.screen_pos = pos;
    \\    out.uv = corner * (extent / radius);
    \\    return out;
    \\}
    \\
    \\fragment float4 point_fragment(
    \\    PointOut in [[stage_in]],
    \\    constant float4 &clip [[buffer(0)]]
    \\) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    float uv_pixel = length(float2(dfdx(in.uv.x), dfdy(in.uv.x)));
    \\    if (outside_clip(in.screen_pos, clip)) discard_fragment();
    \\    // Shared point falloff (cpu/mesh.zig `pointFalloff`, Vulkan mesh.frag).
    \\    // From a 6.7 device pixel radius up it is the falloff over the outer
    \\    // 15% of the radius. Smaller points get a one-pixel band that moves
    \\    // outward to straddle the edge, so a sub-pixel dot keeps about its area.
    \\    float radius_px = 1.0 / max(uv_pixel, 1e-6);
    \\    float dist = length(in.uv);
    \\    float alpha;
    \\    if (radius_px >= 1.0 / 0.15) {
    \\        alpha = 1.0 - smoothstep(0.85, 1.0, dist);
    \\    } else {
    \\        float end_px = radius_px + 0.5 * (1.0 - 0.15 * radius_px);
    \\        alpha = 1.0 - smoothstep(end_px - 1.0, end_px, dist * radius_px);
    \\    }
    \\    if (alpha < 0.001) discard_fragment();
    \\    float4 color = in.color;
    \\    color.a *= alpha;
    \\    return float4(color.rgb * color.a, color.a);
    \\}
    \\
;
