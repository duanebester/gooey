//! CPU scene renderer: draws a finished `Scene` into a caller-owned `Target`.
//!
//! This is the software counterpart of `linux/scene_renderer.zig`. It walks
//! the same `BatchIterator` draw-order stream and draws the primitive kinds
//! the Vulkan backend draws: shadows, quads, glyphs, SVG icons, and images.
//! Paths, polylines, and point clouds are skipped exactly as they are on
//! Vulkan today, and counted in `RenderStats.skipped` so the gap is visible.
//!
//! The renderer is stateless: atlases are read in place from their CPU-side
//! storage (no upload step) and the caller owns the pixels, so a presenter can
//! hand over a Wayland shared-memory buffer or an fbdev back buffer directly.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Memory: zero bytes allocated. Resident memory is the caller's target
//!   (4 bytes per pixel) plus the atlases the text, SVG, and image systems
//!   already own.
//! - CPU: one clear pass, then one pass per primitive over its clipped
//!   bounding box. Interior spans of quads and shadows are filled with
//!   `@memset` or a single-color blend; only edge and corner pixels evaluate
//!   the distance function, and textured quads take one bilinear sample per
//!   covered pixel.
//! - Worst case per frame: `width * height * (1 + overdraw)` pixel writes,
//!   bounded by the scene's own primitive capacities and the target size the
//!   presenter reserved at initialization. A 1280x800 frame with 3x overdraw
//!   is roughly 4 M pixel writes, a few milliseconds on one desktop core.
//! - GPU, disk, and network: none.

const std = @import("std");
const geometry = @import("../../core/geometry.zig");
const scene_mod = @import("../../scene/mod.zig");
const batch_iterator = @import("../../scene/batch_iterator.zig");
const text_atlas_mod = @import("../../text/atlas.zig");
const SvgInstance = @import("../../scene/svg_instance.zig").SvgInstance;
const ImageInstance = @import("../../scene/image_instance.zig").ImageInstance;
pub const raster = @import("raster.zig");

const assert = std.debug.assert;
const Atlas = text_atlas_mod.Atlas;
const Target = raster.Target;

/// Device scale factors above this are treated as a programmer error. The
/// bound keeps every logical-to-device product finite and well inside `f32`.
pub const scale_factor_max: f32 = 8.0;

/// Inputs to one frame besides the scene and the target.
pub const RenderOptions = struct {
    /// Device pixels per logical pixel.
    scale_factor: f32,
    clear_color: geometry.Color,
    /// Glyph coverage atlas (grayscale). Glyphs are skipped while it is null.
    text_atlas: ?*const Atlas,
    /// SVG atlas (RGBA). SVG icons are skipped while it is null.
    svg_atlas: ?*const Atlas,
    /// Image atlas (RGBA). Images are skipped while it is null.
    image_atlas: ?*const Atlas,
};

/// Primitives drawn in one frame, for profiling and tests.
pub const RenderStats = struct {
    shadows: u32 = 0,
    quads: u32 = 0,
    glyphs: u32 = 0,
    svgs: u32 = 0,
    images: u32 = 0,
    /// Primitives the CPU renderer does not draw, or could not draw because
    /// their atlas was missing.
    skipped: u32 = 0,
};

/// Clear `target` and draw every supported primitive of `scene` in order.
pub fn renderScene(
    target: Target,
    scene: *const scene_mod.Scene,
    options: *const RenderOptions,
) RenderStats {
    assert(options.scale_factor > 0 and options.scale_factor <= scale_factor_max);
    assert(@as(usize, target.stride) * target.height <= target.pixels.len);
    raster.clear(target, options.clear_color);

    var stats = RenderStats{};
    var iterator = batch_iterator.BatchIterator.init(scene);
    // Each batch is a non-empty run of the scene's arrays, so the batch count
    // is bounded by the scene's total primitive count.
    while (iterator.next()) |batch| {
        assert(batch.len() > 0);
        drawBatch(target, batch, options, &stats);
    }
    return stats;
}

fn drawBatch(
    target: Target,
    batch: batch_iterator.PrimitiveBatch,
    options: *const RenderOptions,
    stats: *RenderStats,
) void {
    assert(batch.len() > 0);
    assert(options.scale_factor > 0);
    const scale = options.scale_factor;
    switch (batch) {
        .shadow => |shadows| for (shadows) |*shadow| {
            raster.drawShadow(target, &shadowShape(shadow, scale));
            stats.shadows += 1;
        },
        .quad => |quads| for (quads) |*quad| {
            raster.drawQuad(target, &quadShape(quad, scale));
            stats.quads += 1;
        },
        .glyph => |glyphs| {
            const atlas = atlasView(options.text_atlas, .grayscale) orelse {
                stats.skipped += @intCast(glyphs.len);
                return;
            };
            for (glyphs) |*glyph| drawGlyph(target, glyph, atlas, scale);
            stats.glyphs += @intCast(glyphs.len);
        },
        .svg => |svgs| {
            const atlas = atlasView(options.svg_atlas, .rgba) orelse {
                stats.skipped += @intCast(svgs.len);
                return;
            };
            for (svgs) |*svg| drawSvg(target, svg, atlas, scale);
            stats.svgs += @intCast(svgs.len);
        },
        .image => |images| {
            const atlas = atlasView(options.image_atlas, .rgba) orelse {
                stats.skipped += @intCast(images.len);
                return;
            };
            for (images) |*image| drawImage(target, image, atlas, scale);
            stats.images += @intCast(images.len);
        },
        .path, .polyline, .point_cloud, .colored_point_cloud => {
            stats.skipped += @intCast(batch.len());
        },
    }
}

fn atlasView(atlas: ?*const Atlas, format: text_atlas_mod.Format) ?raster.AtlasView {
    const present = atlas orelse return null;
    assert(present.format == format);
    assert(present.data.len >= @as(usize, present.size) * present.size *
        format.bytesPerPixel());
    return .{
        .data = present.data,
        .size = present.size,
        .bytes_per_pixel = format.bytesPerPixel(),
    };
}

// =============================================================================
// Logical primitive to device shape
// =============================================================================

fn deviceRect(x: f32, y: f32, width: f32, height: f32, scale: f32) raster.DeviceRect {
    assert(scale > 0);
    assert(!std.math.isNan(x) and !std.math.isNan(y));
    return .{
        .x = x * scale,
        .y = y * scale,
        .width = @max(width, 0.0) * scale,
        .height = @max(height, 0.0) * scale,
    };
}

fn deviceRadii(corners: scene_mod.Corners, scale: f32) raster.Radii {
    assert(scale > 0);
    assert(!std.math.isNan(corners.top_left));
    return .{
        .top_left = @max(corners.top_left, 0.0) * scale,
        .top_right = @max(corners.top_right, 0.0) * scale,
        .bottom_right = @max(corners.bottom_right, 0.0) * scale,
        .bottom_left = @max(corners.bottom_left, 0.0) * scale,
    };
}

fn quadShape(quad: *const scene_mod.Quad, scale: f32) raster.QuadShape {
    assert(scale > 0);
    assert(quad.bounds_size_width >= 0 and quad.bounds_size_height >= 0);
    const borders = quad.border_widths;
    return .{
        .bounds = deviceRect(
            quad.bounds_origin_x,
            quad.bounds_origin_y,
            quad.bounds_size_width,
            quad.bounds_size_height,
            scale,
        ),
        .clip = deviceRect(
            quad.clip_origin_x,
            quad.clip_origin_y,
            quad.clip_size_width,
            quad.clip_size_height,
            scale,
        ),
        .radii = deviceRadii(quad.corner_radii, scale),
        .borders = .{
            .top = @max(borders.top, 0.0) * scale,
            .right = @max(borders.right, 0.0) * scale,
            .bottom = @max(borders.bottom, 0.0) * scale,
            .left = @max(borders.left, 0.0) * scale,
        },
        .background = quad.background.toColor(),
        .border_color = quad.border_color.toColor(),
    };
}

fn shadowShape(shadow: *const scene_mod.Shadow, scale: f32) raster.ShadowShape {
    assert(scale > 0);
    assert(shadow.content_size_width >= 0 and shadow.content_size_height >= 0);
    return .{
        .content = deviceRect(
            shadow.content_origin_x,
            shadow.content_origin_y,
            shadow.content_size_width,
            shadow.content_size_height,
            scale,
        ),
        .offset_x = shadow.offset_x * scale,
        .offset_y = shadow.offset_y * scale,
        .blur = @max(shadow.blur_radius, 0.0) * scale,
        .radii = deviceRadii(shadow.corner_radii, scale),
        .color = shadow.color.toColor(),
    };
}

/// The fields every textured instance shares, gathered by name so glyphs,
/// SVG icons, and images convert through one function.
fn texturedRect(instance: anytype, width: f32, height: f32, scale: f32) raster.TexturedRect {
    assert(scale > 0);
    assert(width >= 0 and height >= 0);
    return .{
        .bounds = deviceRect(instance.pos_x, instance.pos_y, width, height, scale),
        .clip = deviceRect(
            instance.clip_x,
            instance.clip_y,
            instance.clip_width,
            instance.clip_height,
            scale,
        ),
        .uv_left = instance.uv_left,
        .uv_top = instance.uv_top,
        .uv_right = instance.uv_right,
        .uv_bottom = instance.uv_bottom,
    };
}

fn drawGlyph(
    target: Target,
    glyph: *const scene_mod.GlyphInstance,
    atlas: raster.AtlasView,
    scale: f32,
) void {
    assert(glyph.size_x >= 0 and glyph.size_y >= 0);
    assert(atlas.bytes_per_pixel == 1);
    const rect = texturedRect(glyph, glyph.size_x, glyph.size_y, scale);
    raster.drawGlyph(target, &rect, atlas, glyph.color.toColor());
}

fn drawSvg(target: Target, svg: *const SvgInstance, atlas: raster.AtlasView, scale: f32) void {
    assert(svg.size_x >= 0 and svg.size_y >= 0);
    assert(atlas.bytes_per_pixel == 4);
    const rect = texturedRect(svg, svg.size_x, svg.size_y, scale);
    raster.drawSvg(target, &rect, atlas, svg.color.toColor(), svg.stroke_color.toColor());
}

fn drawImage(
    target: Target,
    image: *const ImageInstance,
    atlas: raster.AtlasView,
    scale: f32,
) void {
    assert(image.dest_width >= 0 and image.dest_height >= 0);
    assert(atlas.bytes_per_pixel == 4);
    const rect = texturedRect(image, image.dest_width, image.dest_height, scale);
    const effects = raster.ImageEffects{
        .tint = image.tint.toColor(),
        .radii = .{
            .top_left = @max(image.corner_tl, 0.0) * scale,
            .top_right = @max(image.corner_tr, 0.0) * scale,
            .bottom_right = @max(image.corner_br, 0.0) * scale,
            .bottom_left = @max(image.corner_bl, 0.0) * scale,
        },
        .grayscale = std.math.clamp(image.grayscale, 0.0, 1.0),
        .opacity = std.math.clamp(image.opacity, 0.0, 1.0),
    };
    raster.drawImage(target, &rect, atlas, &effects);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "renderScene scales logical bounds and draws later primitives on top" {
    // Goal: exercise the scene walk end to end. At scale 2 a logical quad at
    // (1, 1) of size 1 covers device pixels 2 and 3 only, and a later quad
    // that overlaps it wins because batches are drawn in insertion order.
    var scene = scene_mod.Scene.init(testing.allocator);
    defer scene.deinit();
    try scene.insertQuad(scene_mod.Quad.filled(1, 1, 1, 1, scene_mod.Hsla.red));
    const blue = scene_mod.Hsla.init(2.0 / 3.0, 1, 0.5, 1);
    try scene.insertQuad(scene_mod.Quad.filled(1.5, 1.5, 1, 1, blue));

    var pixels: [6 * 6]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 6, .height = 6, .stride = 6 };
    const stats = renderScene(target, &scene, &.{
        .scale_factor = 2,
        .clear_color = geometry.Color.rgba(0, 0, 0, 1),
        .text_atlas = null,
        .svg_atlas = null,
        .image_atlas = null,
    });
    try testing.expectEqual(@as(u32, 2), stats.quads);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(1)[1]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(2)[2]);
    try testing.expectEqual(@as(u32, 0xFF00_00FF), target.row(3)[3]);
    try testing.expectEqual(@as(u32, 0xFF00_00FF), target.row(4)[4]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(5)[5]);
}

test "renderScene skips glyphs without an atlas and counts them" {
    // Goal: a frame rendered before the first atlas exists must not touch
    // pixels for glyphs, and must report them rather than drop them silently.
    var scene = scene_mod.Scene.init(testing.allocator);
    defer scene.deinit();
    const white = scene_mod.Hsla.white;
    try scene.insertGlyph(scene_mod.GlyphInstance.init(0, 0, 2, 2, 0, 0, 1, 1, white));

    var pixels: [2 * 2]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 2, .height = 2, .stride = 2 };
    const stats = renderScene(target, &scene, &.{
        .scale_factor = 1,
        .clear_color = geometry.Color.rgba(0, 0, 0, 1),
        .text_atlas = null,
        .svg_atlas = null,
        .image_atlas = null,
    });
    try testing.expectEqual(@as(u32, 0), stats.glyphs);
    try testing.expectEqual(@as(u32, 1), stats.skipped);
    try testing.expectEqual(@as(u32, 0xFF00_0000), pixels[0]);
}
