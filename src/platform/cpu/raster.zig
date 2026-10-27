//! Pixel-level rasterization for Gooey's CPU renderer.
//!
//! Every function writes into a caller-owned `Target` and nothing allocates.
//! Coordinates arriving here are already physical (device) pixels; the scene
//! walk in `renderer.zig` owns the logical-to-device conversion.
//!
//! ## Pixel format
//!
//! One `u32` per pixel holding `0xAARRGGBB` in native byte order. On the
//! little-endian hosts Gooey targets, the bytes in memory are B, G, R, A, which
//! is Wayland's `WL_SHM_FORMAT_XRGB8888` and the common 32 bpp fbdev layout.
//! Alpha is always written as 0xFF because the surface is opaque.
//!
//! ## Blending
//!
//! The Vulkan backend renders into a UNORM swapchain, so its fixed-function
//! blend runs on sRGB-encoded values without linearization. This file does
//! the same. Sources are converted to premultiplied 8-bit color first, so one
//! source-over blend serves both the straight-alpha pipelines (`SRC_ALPHA`)
//! and the premultiplied SVG pipeline (`ONE`).
//!
//! ## Coverage
//!
//! Shapes reproduce the Vulkan fragment shaders: rounded rectangles use the
//! same signed distance function and `smoothstep(-0.5, 0.5, d)` edge ramp,
//! shadows use the same falloff, and textured quads sample their atlas with
//! bilinear filtering at pixel centers. Interior spans that the distance
//! function would shade at full coverage are filled directly instead, which
//! is where nearly all pixels of a typical UI frame are written.

const std = @import("std");
const geometry = @import("../../core/geometry.zig");

const assert = std.debug.assert;
const Color = geometry.Color;

/// Caller-owned pixel storage, one `u32` per pixel (see the file comment).
pub const Target = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    /// Distance between row starts, in pixels. At least `width`.
    stride: u32,

    /// The visible pixels of row `y`.
    pub fn row(self: Target, y: u32) []u32 {
        assert(y < self.height);
        assert(self.width <= self.stride);
        const start = @as(usize, y) * self.stride;
        assert(start + self.width <= self.pixels.len);
        return self.pixels[start..][0..self.width];
    }
};

/// Premultiplied 8-bit color. Every color channel is at most `a`.
pub const Premul = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent = Premul{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

/// Rectangle in device pixels.
pub const DeviceRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Corner radii in device pixels.
pub const Radii = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    fn maxTop(self: Radii) f32 {
        return @max(self.top_left, self.top_right);
    }

    fn maxBottom(self: Radii) f32 {
        return @max(self.bottom_left, self.bottom_right);
    }
};

/// Border widths in device pixels.
pub const Borders = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

/// Half-open range of pixel indices.
pub const Span = struct {
    start: u32,
    end: u32,

    pub const empty = Span{ .start = 0, .end = 0 };

    pub fn isEmpty(self: Span) bool {
        return self.end <= self.start;
    }

    pub fn intersect(self: Span, other: Span) Span {
        const start = @max(self.start, other.start);
        const end = @min(self.end, other.end);
        if (start < end) return .{ .start = start, .end = end };
        return empty;
    }
};

/// A rounded rectangle quad with optional per-side borders.
pub const QuadShape = struct {
    bounds: DeviceRect,
    clip: DeviceRect,
    radii: Radii,
    borders: Borders,
    background: Color,
    border_color: Color,
};

/// A blurred rounded rectangle drawn behind content.
pub const ShadowShape = struct {
    content: DeviceRect,
    offset_x: f32,
    offset_y: f32,
    blur: f32,
    radii: Radii,
    color: Color,
};

/// Read-only view of a square texture atlas.
pub const AtlasView = struct {
    data: []const u8,
    /// Width and height in texels.
    size: u32,
    /// 1 for coverage (R8) atlases, 4 for RGBA atlases.
    bytes_per_pixel: u8,
};

/// Destination rectangle and atlas sub-rectangle of a textured quad.
pub const TexturedRect = struct {
    bounds: DeviceRect,
    clip: DeviceRect,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
};

/// Per-image effects applied after sampling, mirroring `image.frag`.
pub const ImageEffects = struct {
    tint: Color,
    radii: Radii,
    grayscale: f32,
    opacity: f32,
};

// =============================================================================
// Color and blending
// =============================================================================

/// Round a unit-interval value to a byte, clamping out-of-range input.
pub fn unitToByte(value: f32) u8 {
    assert(!std.math.isNan(value));
    const clamped = std.math.clamp(value, 0.0, 1.0);
    const scaled = @round(clamped * 255.0);
    assert(scaled >= 0.0 and scaled <= 255.0);
    return @intFromFloat(scaled);
}

/// Convert a straight-alpha color to premultiplied 8-bit color.
pub fn premulFromStraight(color: Color) Premul {
    assert(!std.math.isNan(color.a));
    const alpha = std.math.clamp(color.a, 0.0, 1.0);
    const result = Premul{
        .r = unitToByte(color.r * alpha),
        .g = unitToByte(color.g * alpha),
        .b = unitToByte(color.b * alpha),
        .a = unitToByte(alpha),
    };
    // Rounding is monotonic and each channel is at most 1, so no channel can
    // round above alpha. The blend relies on this to stay within a byte.
    assert(result.r <= result.a and result.g <= result.a and result.b <= result.a);
    return result;
}

/// `round(a * b / 255)` for byte operands, without a division.
pub fn mul255(a: u32, b: u32) u32 {
    assert(a <= 255);
    assert(b <= 255);
    const product = a * b + 128;
    const result = (product + (product >> 8)) >> 8;
    assert(result <= 255);
    return result;
}

/// Scale a premultiplied color by a coverage byte.
pub fn premulScale(color: Premul, coverage: u8) Premul {
    assert(color.r <= color.a);
    assert(color.b <= color.a);
    if (coverage == 255) return color;
    return .{
        .r = @intCast(mul255(color.r, coverage)),
        .g = @intCast(mul255(color.g, coverage)),
        .b = @intCast(mul255(color.b, coverage)),
        .a = @intCast(mul255(color.a, coverage)),
    };
}

/// Pack an opaque color into the target pixel format.
pub fn packOpaque(color: Premul) u32 {
    assert(color.a == 255);
    const packed_color = 0xFF00_0000 | (@as(u32, color.r) << 16) |
        (@as(u32, color.g) << 8) | @as(u32, color.b);
    assert(packed_color >> 24 == 0xFF);
    return packed_color;
}

/// Source-over blend of a premultiplied source onto an opaque pixel.
pub fn blendPixel(target_pixel: u32, source: Premul) u32 {
    assert(source.r <= source.a);
    assert(source.g <= source.a);
    const inverse: u32 = 255 - @as(u32, source.a);
    const r = @as(u32, source.r) + mul255((target_pixel >> 16) & 0xFF, inverse);
    const g = @as(u32, source.g) + mul255((target_pixel >> 8) & 0xFF, inverse);
    const b = @as(u32, source.b) + mul255(target_pixel & 0xFF, inverse);
    // `source.c <= source.a` and `mul255(x, inverse) <= inverse`, so each sum
    // is at most `a + (255 - a)`.
    assert(r <= 255 and g <= 255 and b <= 255);
    return 0xFF00_0000 | (r << 16) | (g << 8) | b;
}

/// Fill every pixel of `pixels` with one source color.
pub fn fillSpan(pixels: []u32, source: Premul) void {
    assert(source.r <= source.a);
    assert(pixels.len <= std.math.maxInt(u32));
    if (source.a == 0) return;
    if (source.a == 255) {
        @memset(pixels, packOpaque(source));
        return;
    }
    for (pixels) |*pixel| {
        pixel.* = blendPixel(pixel.*, source);
    }
}

/// Fill the visible area of the whole target with an opaque color.
///
/// A translucent clear color is composited over black, because the surface
/// has no alpha channel to carry it to the compositor.
pub fn clear(target: Target, color: Color) void {
    assert(target.width <= target.stride);
    assert(@as(usize, target.stride) * target.height <= target.pixels.len);
    const premul = premulFromStraight(color);
    const opaque_color = packOpaque(.{ .r = premul.r, .g = premul.g, .b = premul.b, .a = 255 });
    var y: u32 = 0;
    while (y < target.height) : (y += 1) {
        @memset(target.row(y), opaque_color);
    }
}

// =============================================================================
// Pixel ranges
// =============================================================================

/// Clamp an integral float to `[0, limit]` and convert it.
fn clampIndex(value: f32, limit: u32) u32 {
    assert(!std.math.isNan(value));
    assert(@floor(value) == value or std.math.isInf(value));
    if (value <= 0.0) return 0;
    const limit_f: f32 = @floatFromInt(limit);
    if (value >= limit_f) return limit;
    return @intFromFloat(value);
}

/// Pixels whose centers lie in the closed interval `[low, high]`.
///
/// Matches the fragment shaders' clip test, which discards only centers
/// strictly outside the clip rectangle.
pub fn centerSpanClosed(low: f32, high: f32, limit: u32) Span {
    assert(!std.math.isNan(low));
    assert(!std.math.isNan(high));
    const start = clampIndex(@ceil(low - 0.5), limit);
    const end = clampIndex(@floor(high - 0.5) + 1.0, limit);
    if (start < end) return .{ .start = start, .end = end };
    return Span.empty;
}

/// Pixels whose centers lie in the half-open interval `[low, high)`.
///
/// This is the rasterization rule the GPU applies to a primitive's geometry.
pub fn centerSpanHalfOpen(low: f32, high: f32, limit: u32) Span {
    assert(!std.math.isNan(low));
    assert(!std.math.isNan(high));
    const start = clampIndex(@ceil(low - 0.5), limit);
    const end = clampIndex(@ceil(high - 0.5), limit);
    if (start < end) return .{ .start = start, .end = end };
    return Span.empty;
}

/// Pixels that `[low, high)` touches at all.
///
/// Anti-aliased shapes use this so partially covered edge pixels are shaded.
pub fn touchedSpan(low: f32, high: f32, limit: u32) Span {
    assert(!std.math.isNan(low));
    assert(!std.math.isNan(high));
    const start = clampIndex(@floor(low), limit);
    const end = clampIndex(@ceil(high), limit);
    if (start < end) return .{ .start = start, .end = end };
    return Span.empty;
}

fn clipRows(clip: DeviceRect, limit: u32) Span {
    assert(clip.height >= 0);
    assert(limit > 0);
    return centerSpanClosed(clip.y, clip.y + clip.height, limit);
}

fn clipColumns(clip: DeviceRect, limit: u32) Span {
    assert(clip.width >= 0);
    assert(limit > 0);
    return centerSpanClosed(clip.x, clip.x + clip.width, limit);
}

// =============================================================================
// Distance functions
// =============================================================================

pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    assert(edge0 < edge1);
    assert(!std.math.isNan(x));
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Signed distance from a point to a rounded rectangle centered at the origin.
pub fn roundedRectSdf(x: f32, y: f32, half_width: f32, half_height: f32, radius: f32) f32 {
    assert(half_width >= 0);
    assert(half_height >= 0);
    const dx = @abs(x) - half_width + radius;
    const dy = @abs(y) - half_height + radius;
    const outside_x = @max(dx, 0.0);
    const outside_y = @max(dy, 0.0);
    const outside = @sqrt(outside_x * outside_x + outside_y * outside_y);
    return outside + @min(@max(dx, dy), 0.0) - radius;
}

/// The radius of the corner whose quadrant contains the point.
pub fn pickCornerRadius(x: f32, y: f32, radii: Radii) f32 {
    assert(radii.top_left >= 0 and radii.top_right >= 0);
    assert(radii.bottom_left >= 0 and radii.bottom_right >= 0);
    if (x < 0.0) {
        if (y < 0.0) return radii.top_left;
        return radii.bottom_left;
    }
    if (y < 0.0) return radii.top_right;
    return radii.bottom_right;
}

fn coverageFromDistance(distance: f32) f32 {
    assert(!std.math.isNan(distance));
    const coverage = 1.0 - smoothstep(-0.5, 0.5, distance);
    assert(coverage >= 0.0 and coverage <= 1.0);
    return coverage;
}

fn mixColor(a: Color, b: Color, t: f32) Color {
    assert(t >= 0.0 and t <= 1.0);
    assert(!std.math.isNan(a.a) and !std.math.isNan(b.a));
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

// =============================================================================
// Quads
// =============================================================================

/// Values `quad.frag` derives per fragment that are constant per quad.
const QuadGeometry = struct {
    center_x: f32,
    center_y: f32,
    half_width: f32,
    half_height: f32,
    radii: Radii,
    has_border: bool,
    inner_center_x: f32,
    inner_center_y: f32,
    inner_half_width: f32,
    inner_half_height: f32,
    inner_radii: Radii,
    background: Color,
    border_color: Color,
    /// Rows whose centers lie in `[straight_top, straight_bottom]` meet no
    /// rounded corner, so their interior shades exactly to `background`.
    straight_top: f32,
    straight_bottom: f32,
    /// Columns that straight rows fill with `background` directly.
    solid_columns: Span,
    /// Columns whose shade in a corner row depends on the row alone.
    ///
    /// They lie at least `max radius + 0.5` inside both the outer and inner
    /// rectangles horizontally. There, either the vertical term alone sets
    /// the distance (the corner circle is not reached) or the horizontal term
    /// is at most -0.5, where coverage is 1 and the border blend is 0, so it
    /// cannot change the result. One shaded pixel stands for the whole span.
    corner_columns: Span,

    fn init(shape: *const QuadShape, columns: Span) QuadGeometry {
        assert(shape.bounds.width >= 0 and shape.bounds.height >= 0);
        assert(!columns.isEmpty());
        const bounds = shape.bounds;
        const borders = shape.borders;
        const half_width = bounds.width * 0.5;
        const half_height = bounds.height * 0.5;
        // Inner rectangle in quad-centered coordinates, inset per side.
        const inner_min_x = -half_width + borders.left;
        const inner_min_y = -half_height + borders.top;
        const inner_max_x = half_width - borders.right;
        const inner_max_y = half_height - borders.bottom;
        const radii = shape.radii;
        const radius_max = @max(radii.maxTop(), radii.maxBottom());
        const solid = centerSpanClosed(
            bounds.x + borders.left + 0.5,
            bounds.x + bounds.width - borders.right - 0.5,
            columns.end,
        );
        const corner = centerSpanClosed(
            bounds.x + borders.left + radius_max + 0.5,
            bounds.x + bounds.width - borders.right - radius_max - 0.5,
            columns.end,
        );
        return .{
            .center_x = bounds.x + half_width,
            .center_y = bounds.y + half_height,
            .half_width = half_width,
            .half_height = half_height,
            .radii = radii,
            .has_border = borders.top > 0 or borders.right > 0 or
                borders.bottom > 0 or borders.left > 0,
            .inner_center_x = (inner_min_x + inner_max_x) * 0.5,
            .inner_center_y = (inner_min_y + inner_max_y) * 0.5,
            .inner_half_width = @max(0.0, (inner_max_x - inner_min_x) * 0.5),
            .inner_half_height = @max(0.0, (inner_max_y - inner_min_y) * 0.5),
            .inner_radii = innerRadii(radii, borders),
            .background = shape.background,
            .border_color = shape.border_color,
            .straight_top = bounds.y + borders.top + radii.maxTop() + 0.5,
            .straight_bottom = bounds.y + bounds.height - borders.bottom -
                radii.maxBottom() - 0.5,
            .solid_columns = solid.intersect(columns),
            .corner_columns = corner.intersect(columns),
        };
    }

    /// Shade one pixel center exactly as `quad.frag` does.
    fn shade(self: *const QuadGeometry, pixel_x: f32, pixel_y: f32) Premul {
        assert(self.half_width >= 0 and self.half_height >= 0);
        assert(self.inner_half_width >= 0 and self.inner_half_height >= 0);
        const x = pixel_x - self.center_x;
        const y = pixel_y - self.center_y;
        const radius = pickCornerRadius(x, y, self.radii);
        const outer = roundedRectSdf(x, y, self.half_width, self.half_height, radius);
        const coverage = coverageFromDistance(outer);
        if (coverage <= 0.0) return Premul.transparent;

        var color = self.background;
        if (self.has_border) {
            const inner_x = x - self.inner_center_x;
            const inner_y = y - self.inner_center_y;
            const inner_radius = pickCornerRadius(inner_x, inner_y, self.inner_radii);
            const inner = roundedRectSdf(
                inner_x,
                inner_y,
                self.inner_half_width,
                self.inner_half_height,
                inner_radius,
            );
            color = mixColor(self.background, self.border_color, smoothstep(-0.5, 0.5, inner));
        }
        color.a *= coverage;
        return premulFromStraight(color);
    }
};

/// Inner radii shrink by the wider of the two borders meeting at a corner.
fn innerRadii(radii: Radii, borders: Borders) Radii {
    assert(borders.top >= 0 and borders.bottom >= 0);
    assert(borders.left >= 0 and borders.right >= 0);
    return .{
        .top_left = @max(0.0, radii.top_left - @max(borders.top, borders.left)),
        .top_right = @max(0.0, radii.top_right - @max(borders.top, borders.right)),
        .bottom_right = @max(0.0, radii.bottom_right - @max(borders.bottom, borders.right)),
        .bottom_left = @max(0.0, radii.bottom_left - @max(borders.bottom, borders.left)),
    };
}

fn shadeQuadRange(row: []u32, columns: Span, pixel_y: f32, quad: *const QuadGeometry) void {
    assert(columns.end <= row.len);
    assert(!std.math.isNan(pixel_y));
    var x = columns.start;
    while (x < columns.end) : (x += 1) {
        const source = quad.shade(@as(f32, @floatFromInt(x)) + 0.5, pixel_y);
        if (source.a != 0) row[x] = blendPixel(row[x], source);
    }
}

/// Draw a rounded, optionally bordered quad.
pub fn drawQuad(target: Target, shape: *const QuadShape) void {
    assert(shape.bounds.width >= 0 and shape.bounds.height >= 0);
    assert(shape.clip.width >= 0 and shape.clip.height >= 0);
    if (target.width == 0 or target.height == 0) return;
    const bounds = shape.bounds;
    const rows = touchedSpan(bounds.y, bounds.y + bounds.height, target.height)
        .intersect(clipRows(shape.clip, target.height));
    const columns = touchedSpan(bounds.x, bounds.x + bounds.width, target.width)
        .intersect(clipColumns(shape.clip, target.width));
    if (rows.isEmpty() or columns.isEmpty()) return;

    const quad = QuadGeometry.init(shape, columns);
    const solid_color = premulFromStraight(quad.background);
    var y = rows.start;
    while (y < rows.end) : (y += 1) {
        const pixel_y = @as(f32, @floatFromInt(y)) + 0.5;
        const row = target.row(y);
        const straight = pixel_y >= quad.straight_top and pixel_y <= quad.straight_bottom;
        const fill = if (straight) quad.solid_columns else quad.corner_columns;
        if (fill.isEmpty()) {
            shadeQuadRange(row, columns, pixel_y, &quad);
            continue;
        }
        const fill_color = if (straight) solid_color else quad.shade(
            @as(f32, @floatFromInt(fill.start)) + 0.5,
            pixel_y,
        );
        shadeQuadRange(row, .{ .start = columns.start, .end = fill.start }, pixel_y, &quad);
        fillSpan(row[fill.start..fill.end], fill_color);
        shadeQuadRange(row, .{ .start = fill.end, .end = columns.end }, pixel_y, &quad);
    }
}

// =============================================================================
// Shadows
// =============================================================================

/// Draw a drop shadow.
///
/// Both GPU backends place the distance function's center at the content
/// center plus *twice* the offset while bounding the geometry by one offset
/// (`local = unit * size - size / 2 - offset`). The CPU path reproduces that
/// exactly so a shadow looks the same on every renderer.
pub fn drawShadow(target: Target, shape: *const ShadowShape) void {
    assert(shape.content.width >= 0 and shape.content.height >= 0);
    assert(shape.blur >= 0);
    if (target.width == 0 or target.height == 0) return;
    const content = shape.content;
    const expand = shape.blur * 2.0;
    const left = content.x + shape.offset_x - expand;
    const top = content.y + shape.offset_y - expand;
    const rows = centerSpanHalfOpen(top, top + content.height + expand * 2.0, target.height);
    const columns = centerSpanHalfOpen(left, left + content.width + expand * 2.0, target.width);
    if (rows.isEmpty() or columns.isEmpty()) return;

    const falloff = ShadowFalloff.init(shape);
    const base = premulFromStraight(shape.color);
    if (base.a == 0) return;
    // Straight rows share one per-column color profile. 16 KiB of stack at
    // the ceiling; wider spans (larger than any presenter's target) shade
    // every row through the general path instead.
    var profile_storage: [shadow_profile_columns_max]Premul = undefined;
    const profile: ?[]const Premul = if (columns.end - columns.start <= shadow_profile_columns_max)
        falloff.straightRowProfile(profile_storage[0 .. columns.end - columns.start], columns, base)
    else
        null;
    const middle = falloff.middleColumns(columns);
    var y = rows.start;
    while (y < rows.end) : (y += 1) {
        const local_y = @as(f32, @floatFromInt(y)) + 0.5 - falloff.center_y;
        const row = target.row(y);
        if (profile) |colors| {
            if (falloff.isStraightRow(local_y)) {
                blendColors(row[columns.start..columns.end], colors);
                continue;
            }
        }
        if (middle.isEmpty()) {
            shadeShadowRange(row, columns, local_y, &falloff, base);
            continue;
        }
        const middle_color = premulScale(base, unitToByte(falloff.coverage(0, local_y)));
        const left_edge = Span{ .start = columns.start, .end = middle.start };
        const right_edge = Span{ .start = middle.end, .end = columns.end };
        shadeShadowRange(row, left_edge, local_y, &falloff, base);
        fillSpan(row[middle.start..middle.end], middle_color);
        shadeShadowRange(row, right_edge, local_y, &falloff, base);
    }
}

/// Widest shadow, in device pixels, that uses the straight-row profile.
/// Matches the largest framebuffer dimension any presenter reserves.
const shadow_profile_columns_max: u32 = 4096;

/// Blend a row of per-pixel source colors, skipping transparent ones.
fn blendColors(pixels: []u32, colors: []const Premul) void {
    assert(pixels.len == colors.len);
    assert(pixels.len <= shadow_profile_columns_max);
    for (pixels, colors) |*pixel, color| {
        if (color.a != 0) pixel.* = blendPixel(pixel.*, color);
    }
}

const ShadowFalloff = struct {
    center_x: f32,
    center_y: f32,
    half_width: f32,
    half_height: f32,
    radii: Radii,
    edge0: f32,
    edge1: f32,

    fn init(shape: *const ShadowShape) ShadowFalloff {
        assert(shape.blur >= 0);
        assert(shape.content.width >= 0);
        // `shadow_falloff` is `1 - smoothstep(-blur / 2, blur * 1.5, d)`. The
        // GLSL result is undefined for a zero blur, so a sharp shadow falls
        // back to the one-pixel ramp every other shape uses.
        const sharp = shape.blur * 2.0 < 1.0;
        const content = shape.content;
        return .{
            .center_x = content.x + content.width * 0.5 + shape.offset_x * 2.0,
            .center_y = content.y + content.height * 0.5 + shape.offset_y * 2.0,
            .half_width = content.width * 0.5,
            .half_height = content.height * 0.5,
            .radii = shape.radii,
            .edge0 = if (sharp) -0.5 else -shape.blur * 0.5,
            .edge1 = if (sharp) 0.5 else shape.blur * 1.5,
        };
    }

    /// A straight row meets no corner circle and lies where the vertical
    /// term alone gives full coverage. Its distance is then `|x| - hw` or a
    /// value at most `edge0`, where coverage is 1 either way, so its coverage
    /// depends on the column alone.
    fn isStraightRow(self: *const ShadowFalloff, local_y: f32) bool {
        assert(self.edge0 < 0);
        assert(!std.math.isNan(local_y));
        const radius = @max(self.radii.maxTop(), self.radii.maxBottom());
        if (@abs(local_y) > self.half_height - radius) return false;
        return @abs(local_y) - self.half_height <= self.edge0;
    }

    /// Source colors of a straight row, one per column of `columns`.
    fn straightRowProfile(
        self: *const ShadowFalloff,
        storage: []Premul,
        columns: Span,
        base: Premul,
    ) []const Premul {
        assert(storage.len == columns.end - columns.start);
        assert(self.edge0 < self.edge1);
        for (storage, columns.start..) |*color, x| {
            const local_x = @as(f32, @floatFromInt(x)) + 0.5 - self.center_x;
            const distance = @abs(local_x) - self.half_width;
            color.* = premulScale(base, unitToByte(1.0 - smoothstep(self.edge0, self.edge1, distance)));
        }
        return storage;
    }

    /// Columns whose coverage depends on the row alone, in every row.
    ///
    /// They lie within `max(radius, -edge0)` of the box horizontally: either
    /// the corner circle is not reached and the vertical term sets the
    /// distance, or the horizontal term is at most `edge0` and cannot lower
    /// full coverage. Same argument as `QuadGeometry.corner_columns`.
    fn middleColumns(self: *const ShadowFalloff, columns: Span) Span {
        assert(self.edge0 < 0);
        assert(!columns.isEmpty());
        const radius = @max(self.radii.maxTop(), self.radii.maxBottom());
        const reach = self.half_width - @max(radius, -self.edge0);
        if (reach < 0) return Span.empty;
        return centerSpanClosed(self.center_x - reach, self.center_x + reach, columns.end)
            .intersect(columns);
    }

    fn coverage(self: *const ShadowFalloff, local_x: f32, local_y: f32) f32 {
        assert(self.edge0 < self.edge1);
        assert(!std.math.isNan(local_x));
        const radius = pickCornerRadius(local_x, local_y, self.radii);
        const distance = roundedRectSdf(
            local_x,
            local_y,
            self.half_width,
            self.half_height,
            radius,
        );
        return 1.0 - smoothstep(self.edge0, self.edge1, distance);
    }
};

fn shadeShadowRange(
    row: []u32,
    columns: Span,
    local_y: f32,
    falloff: *const ShadowFalloff,
    base: Premul,
) void {
    assert(columns.end <= row.len);
    assert(base.r <= base.a);
    var x = columns.start;
    while (x < columns.end) : (x += 1) {
        const local_x = @as(f32, @floatFromInt(x)) + 0.5 - falloff.center_x;
        const coverage = unitToByte(falloff.coverage(local_x, local_y));
        if (coverage != 0) row[x] = blendPixel(row[x], premulScale(base, coverage));
    }
}

// =============================================================================
// Textured quads
// =============================================================================

/// Bilinear sample of `channels` bytes per texel at texel-space coordinates,
/// where integer coordinates address texel centers. Coordinates are clamped
/// to the atlas edge, matching `CLAMP_TO_EDGE`.
fn sampleBilinear(comptime channels: u8, atlas: AtlasView, tx: f32, ty: f32) [channels]f32 {
    assert(atlas.bytes_per_pixel == channels);
    assert(atlas.data.len >= @as(usize, atlas.size) * atlas.size * channels);
    const limit: f32 = @floatFromInt(atlas.size - 1);
    const x = std.math.clamp(tx, 0.0, limit);
    const y = std.math.clamp(ty, 0.0, limit);
    const x0: u32 = @intFromFloat(@floor(x));
    const y0: u32 = @intFromFloat(@floor(y));
    const x1 = @min(x0 + 1, atlas.size - 1);
    const y1 = @min(y0 + 1, atlas.size - 1);
    const fx = x - @floor(x);
    const fy = y - @floor(y);

    var result: [channels]f32 = undefined;
    inline for (0..channels) |c| {
        const top = lerp(texel(atlas, x0, y0, c), texel(atlas, x1, y0, c), fx);
        const bottom = lerp(texel(atlas, x0, y1, c), texel(atlas, x1, y1, c), fx);
        result[c] = lerp(top, bottom, fy);
    }
    return result;
}

fn texel(atlas: AtlasView, x: u32, y: u32, channel: u32) f32 {
    assert(x < atlas.size and y < atlas.size);
    assert(channel < atlas.bytes_per_pixel);
    const index = (@as(usize, y) * atlas.size + x) * atlas.bytes_per_pixel + channel;
    return @floatFromInt(atlas.data[index]);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    assert(t >= 0.0 and t <= 1.0);
    assert(!std.math.isNan(a) and !std.math.isNan(b));
    return a + (b - a) * t;
}

/// Maps device pixel centers inside a textured quad to atlas texel space.
const TexelMapping = struct {
    rows: Span,
    columns: Span,
    origin_x: f32,
    origin_y: f32,
    step_x: f32,
    step_y: f32,
    /// Set when every covered pixel center lands exactly on a texel center
    /// inside the atlas, as for pixel-snapped glyphs rasterized at device
    /// scale. The bilinear weights are then zero, so reading the one texel
    /// directly gives the identical result without the filtering work.
    aligned: ?TexelOffset,

    /// Null when the quad covers no pixel center inside the clip.
    fn init(target: Target, rect: *const TexturedRect, atlas: AtlasView) ?TexelMapping {
        assert(rect.bounds.width >= 0 and rect.bounds.height >= 0);
        assert(atlas.size > 0);
        const bounds = rect.bounds;
        if (bounds.width <= 0 or bounds.height <= 0) return null;
        const rows = centerSpanHalfOpen(bounds.y, bounds.y + bounds.height, target.height)
            .intersect(clipRows(rect.clip, target.height));
        const columns = centerSpanHalfOpen(bounds.x, bounds.x + bounds.width, target.width)
            .intersect(clipColumns(rect.clip, target.width));
        if (rows.isEmpty() or columns.isEmpty()) return null;

        const size: f32 = @floatFromInt(atlas.size);
        const step_x = (rect.uv_right - rect.uv_left) * size / bounds.width;
        const step_y = (rect.uv_bottom - rect.uv_top) * size / bounds.height;
        var mapping = TexelMapping{
            .rows = rows,
            .columns = columns,
            // Texel coordinate of device x = 0, shifted so texel centers land
            // on integers: `u * size - 0.5`.
            .origin_x = rect.uv_left * size - bounds.x * step_x - 0.5,
            .origin_y = rect.uv_top * size - bounds.y * step_y - 0.5,
            .step_x = step_x,
            .step_y = step_y,
            .aligned = null,
        };
        mapping.aligned = mapping.alignedOffset(atlas.size);
        return mapping;
    }

    fn alignedOffset(self: *const TexelMapping, atlas_size: u32) ?TexelOffset {
        assert(!self.rows.isEmpty() and !self.columns.isEmpty());
        assert(atlas_size > 0);
        // UVs are stored as `f32` fractions of the atlas, so allow a sliver of
        // rounding error before declaring the mapping one-to-one.
        const tolerance: f32 = 1.0 / 256.0;
        if (@abs(self.step_x - 1.0) > tolerance or @abs(self.step_y - 1.0) > tolerance) return null;
        const first_x = self.texelX(self.columns.start);
        const first_y = self.texelY(self.rows.start);
        if (@abs(first_x - @round(first_x)) > tolerance) return null;
        if (@abs(first_y - @round(first_y)) > tolerance) return null;
        const offset = TexelOffset{
            .x = @as(i64, @intFromFloat(@round(first_x))) - self.columns.start,
            .y = @as(i64, @intFromFloat(@round(first_y))) - self.rows.start,
        };
        // Every texel read must be inside the atlas; edge clamping is the
        // bilinear path's job.
        if (self.columns.start + offset.x < 0 or self.columns.end - 1 + offset.x >= atlas_size) return null;
        if (self.rows.start + offset.y < 0 or self.rows.end - 1 + offset.y >= atlas_size) return null;
        return offset;
    }

    /// The atlas value pixel `(x, y)` takes, `ty` being `texelY(y)`.
    fn sample(
        self: *const TexelMapping,
        comptime channels: u8,
        atlas: AtlasView,
        x: u32,
        y: u32,
        ty: f32,
    ) [channels]f32 {
        assert(x >= self.columns.start and x < self.columns.end);
        assert(y >= self.rows.start and y < self.rows.end);
        const offset = self.aligned orelse return sampleBilinear(channels, atlas, self.texelX(x), ty);
        const texel_x: u32 = @intCast(x + offset.x);
        const texel_y: u32 = @intCast(y + offset.y);
        var result: [channels]f32 = undefined;
        inline for (0..channels) |c| result[c] = texel(atlas, texel_x, texel_y, c);
        return result;
    }

    fn texelX(self: *const TexelMapping, x: u32) f32 {
        assert(x < self.columns.end);
        return self.origin_x + (@as(f32, @floatFromInt(x)) + 0.5) * self.step_x;
    }

    fn texelY(self: *const TexelMapping, y: u32) f32 {
        assert(y < self.rows.end);
        return self.origin_y + (@as(f32, @floatFromInt(y)) + 0.5) * self.step_y;
    }
};

const TexelOffset = struct {
    x: i64,
    y: i64,
};

/// Draw a glyph from a coverage (R8) atlas in a straight-alpha color.
pub fn drawGlyph(target: Target, rect: *const TexturedRect, atlas: AtlasView, color: Color) void {
    assert(atlas.bytes_per_pixel == 1);
    assert(!std.math.isNan(color.a));
    const mapping = TexelMapping.init(target, rect, atlas) orelse return;
    const base = premulFromStraight(color);
    if (base.a == 0) return;
    var y = mapping.rows.start;
    while (y < mapping.rows.end) : (y += 1) {
        const ty = mapping.texelY(y);
        const row = target.row(y);
        var x = mapping.columns.start;
        while (x < mapping.columns.end) : (x += 1) {
            const sample = mapping.sample(1, atlas, x, y, ty)[0];
            const coverage: u8 = @intFromFloat(@round(sample));
            if (coverage != 0) row[x] = blendPixel(row[x], premulScale(base, coverage));
        }
    }
}

/// Draw an SVG icon from an RGBA atlas: red holds fill coverage and green
/// holds stroke coverage, composited as in `svg.frag`.
pub fn drawSvg(
    target: Target,
    rect: *const TexturedRect,
    atlas: AtlasView,
    fill: Color,
    stroke: Color,
) void {
    assert(atlas.bytes_per_pixel == 4);
    assert(!std.math.isNan(fill.a) and !std.math.isNan(stroke.a));
    const mapping = TexelMapping.init(target, rect, atlas) orelse return;
    var y = mapping.rows.start;
    while (y < mapping.rows.end) : (y += 1) {
        const ty = mapping.texelY(y);
        const row = target.row(y);
        var x = mapping.columns.start;
        while (x < mapping.columns.end) : (x += 1) {
            const sample = mapping.sample(4, atlas, x, y, ty);
            const source = shadeSvg(sample[0] / 255.0, sample[1] / 255.0, fill, stroke);
            if (source.a != 0) row[x] = blendPixel(row[x], source);
        }
    }
}

fn shadeSvg(fill_sample: f32, stroke_sample: f32, fill: Color, stroke: Color) Premul {
    assert(fill_sample >= 0.0 and fill_sample <= 1.0);
    assert(stroke_sample >= 0.0 and stroke_sample <= 1.0);
    // The threshold removes filtering bleed between the packed channels.
    const fill_alpha = if (fill_sample > 0.02) fill_sample else 0.0;
    const stroke_alpha = if (stroke_sample > 0.02) stroke_sample else 0.0;
    const visible_stroke = stroke_alpha * (1.0 - fill_alpha);
    const fill_weight = fill.a * fill_alpha;
    const stroke_weight = stroke.a * visible_stroke;
    const alpha = fill_weight + stroke_weight;
    if (alpha < 0.001) return Premul.transparent;
    const result = Premul{
        .r = unitToByte(fill.r * fill_weight + stroke.r * stroke_weight),
        .g = unitToByte(fill.g * fill_weight + stroke.g * stroke_weight),
        .b = unitToByte(fill.b * fill_weight + stroke.b * stroke_weight),
        .a = unitToByte(alpha),
    };
    // Rounding can lift a color channel one step above alpha; clamp so the
    // blend's no-overflow invariant holds.
    return .{
        .r = @min(result.r, result.a),
        .g = @min(result.g, result.a),
        .b = @min(result.b, result.a),
        .a = result.a,
    };
}

/// Draw a raster image from a straight-alpha RGBA atlas.
pub fn drawImage(
    target: Target,
    rect: *const TexturedRect,
    atlas: AtlasView,
    effects: *const ImageEffects,
) void {
    assert(atlas.bytes_per_pixel == 4);
    assert(effects.opacity >= 0.0 and effects.opacity <= 1.0);
    const mapping = TexelMapping.init(target, rect, atlas) orelse return;
    const bounds = rect.bounds;
    const half_width = bounds.width * 0.5;
    const half_height = bounds.height * 0.5;
    const rounded = @max(effects.radii.maxTop(), effects.radii.maxBottom()) > 0.0;
    var y = mapping.rows.start;
    while (y < mapping.rows.end) : (y += 1) {
        const ty = mapping.texelY(y);
        const local_y = @as(f32, @floatFromInt(y)) + 0.5 - bounds.y - half_height;
        const row = target.row(y);
        var x = mapping.columns.start;
        while (x < mapping.columns.end) : (x += 1) {
            var corner: f32 = 1.0;
            if (rounded) {
                const local_x = @as(f32, @floatFromInt(x)) + 0.5 - bounds.x - half_width;
                const radius = pickCornerRadius(local_x, local_y, effects.radii);
                const distance = roundedRectSdf(local_x, local_y, half_width, half_height, radius);
                corner = coverageFromDistance(distance);
                if (corner < 0.001) continue;
            }
            const sample = mapping.sample(4, atlas, x, y, ty);
            const source = shadeImage(sample, effects, corner);
            if (source.a != 0) row[x] = blendPixel(row[x], source);
        }
    }
}

fn shadeImage(sample: [4]f32, effects: *const ImageEffects, corner: f32) Premul {
    assert(corner >= 0.0 and corner <= 1.0);
    assert(effects.grayscale >= 0.0 and effects.grayscale <= 1.0);
    var color = Color{
        .r = sample[0] / 255.0,
        .g = sample[1] / 255.0,
        .b = sample[2] / 255.0,
        .a = sample[3] / 255.0,
    };
    if (effects.grayscale > 0.0) {
        const gray = color.r * 0.299 + color.g * 0.587 + color.b * 0.114;
        color.r += (gray - color.r) * effects.grayscale;
        color.g += (gray - color.g) * effects.grayscale;
        color.b += (gray - color.b) * effects.grayscale;
    }
    color.r *= effects.tint.r;
    color.g *= effects.tint.g;
    color.b *= effects.tint.b;
    color.a *= effects.tint.a * corner * effects.opacity;
    if (color.a < 0.001) return Premul.transparent;
    return premulFromStraight(color);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const test_background: u32 = 0xFF00_0000;

fn testTarget(pixels: []u32, width: u32, height: u32) Target {
    assert(pixels.len == @as(usize, width) * height);
    assert(width > 0 and height > 0);
    @memset(pixels, test_background);
    return .{ .pixels = pixels, .width = width, .height = height, .stride = width };
}

fn testPixel(target: Target, x: u32, y: u32) u32 {
    return target.row(y)[x];
}

fn testQuad(bounds: DeviceRect, color: Color) QuadShape {
    return .{
        .bounds = bounds,
        .clip = .{ .x = -1e9, .y = -1e9, .width = 2e9, .height = 2e9 },
        .radii = .{},
        .borders = .{},
        .background = color,
        .border_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
}

const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
const green = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };

test "mul255 equals round(a * b / 255) for every byte pair" {
    // Goal: the shift trick replaces a division in every blended pixel, so
    // prove it exhaustively against an independent integer reference rather
    // than spot-checking easy values.
    var a: u32 = 0;
    while (a <= 255) : (a += 1) {
        var b: u32 = 0;
        while (b <= 255) : (b += 1) {
            const expected = (a * b * 2 + 255) / (255 * 2);
            try testing.expectEqual(expected, mul255(a, b));
        }
    }
}

test "translucent source blends over the target pixel" {
    // Goal: pin source-over arithmetic with distinct channels so a swapped
    // channel or a missing inverse-alpha term changes the result. Expected
    // values are worked by hand: alpha 0.5 rounds to 128, so each channel is
    // 128 + round(target * 127 / 255).
    const source = premulFromStraight(.{ .r = 1, .g = 1, .b = 1, .a = 0.5 });
    try testing.expectEqual(@as(u8, 128), source.a);
    try testing.expectEqual(@as(u32, 0xFFA0_C0E0), blendPixel(0xFF40_80C0, source));
    try testing.expectEqual(@as(u32, 0xFF40_80C0), blendPixel(0xFF40_80C0, Premul.transparent));
}

test "opaque quad covers exactly the pixels inside its edges" {
    // Goal: integer-aligned edges must neither bleed into the neighboring
    // pixel nor lose the last covered pixel; check both sides of each edge.
    var pixels: [6 * 6]u32 = undefined;
    const target = testTarget(&pixels, 6, 6);
    drawQuad(target, &testQuad(.{ .x = 1, .y = 1, .width = 4, .height = 4 }, red));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 1, 1));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 4, 4));
    try testing.expectEqual(test_background, testPixel(target, 0, 1));
    try testing.expectEqual(test_background, testPixel(target, 5, 4));
    try testing.expectEqual(test_background, testPixel(target, 4, 0));
    try testing.expectEqual(test_background, testPixel(target, 1, 5));
}

test "fractional quad edges follow the shader's smoothstep ramp" {
    // Goal: edge pixels use `1 - smoothstep(-0.5, 0.5, d)`, not a linear or
    // binary coverage. Edges at 1.25 and 3.25 put the pixel centers 0.25
    // inside and 0.25 outside: coverage 0.84375 and 0.15625, i.e. red bytes
    // 215 and 40 over black.
    var pixels: [5 * 1]u32 = undefined;
    const target = testTarget(&pixels, 5, 1);
    drawQuad(target, &testQuad(.{ .x = 1.25, .y = 0, .width = 2, .height = 1 }, red));
    try testing.expectEqual(test_background, testPixel(target, 0, 0));
    try testing.expectEqual(@as(u32, 0xFFD7_0000), testPixel(target, 1, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 2, 0));
    try testing.expectEqual(@as(u32, 0xFF28_0000), testPixel(target, 3, 0));
    try testing.expectEqual(test_background, testPixel(target, 4, 0));
}

test "clip keeps pixel centers that lie exactly on its edge" {
    // Goal: the shaders discard only centers strictly outside the clip, so a
    // clip ending at 2.5 keeps pixel 2 (center 2.5) and drops pixel 3.
    var pixels: [5 * 1]u32 = undefined;
    const target = testTarget(&pixels, 5, 1);
    var shape = testQuad(.{ .x = 0, .y = 0, .width = 5, .height = 1 }, red);
    shape.clip = .{ .x = 0.5, .y = 0, .width = 2, .height = 1 };
    drawQuad(target, &shape);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 0, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 2, 0));
    try testing.expectEqual(test_background, testPixel(target, 3, 0));
}

test "corner radius applies only to the corners that set it" {
    // Goal: a top-left-only radius must round that corner and leave the
    // other three square, catching a swapped or uniform radius lookup.
    var pixels: [10 * 10]u32 = undefined;
    const target = testTarget(&pixels, 10, 10);
    var shape = testQuad(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, red);
    shape.radii = .{ .top_left = 4 };
    drawQuad(target, &shape);
    try testing.expectEqual(test_background, testPixel(target, 0, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 9, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 0, 9));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 9, 9));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 4, 4));
}

test "a bottom-only border paints only the bottom edge" {
    // Goal: per-side borders must map top/right/bottom/left correctly and the
    // interior fast path must not overwrite the border rows.
    var pixels: [6 * 6]u32 = undefined;
    const target = testTarget(&pixels, 6, 6);
    var shape = testQuad(.{ .x = 0, .y = 0, .width = 6, .height = 6 }, red);
    shape.borders = .{ .bottom = 2 };
    shape.border_color = green;
    drawQuad(target, &shape);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 0, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 5, 3));
    try testing.expectEqual(@as(u32, 0xFF00_FF00), testPixel(target, 0, 4));
    try testing.expectEqual(@as(u32, 0xFF00_FF00), testPixel(target, 5, 5));
}

test "shadow distance center sits at twice the offset, inside one-offset geometry" {
    // Goal: pin parity with both GPU shaders. Content spans x [2, 6) with a
    // one-pixel x offset and no blur, so the geometry spans [3, 7) while the
    // shaded box spans [4, 8): pixel 3 is inside the geometry but outside the
    // box, pixels 4-6 are fully shaded, and pixel 7 is outside the geometry.
    var pixels: [9 * 6]u32 = undefined;
    const target = testTarget(&pixels, 9, 6);
    @memset(&pixels, 0xFFFF_FFFF);
    drawShadow(target, &.{
        .content = .{ .x = 2, .y = 1, .width = 4, .height = 4 },
        .offset_x = 1,
        .offset_y = 0,
        .blur = 0,
        .radii = .{},
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    });
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), testPixel(target, 3, 2));
    try testing.expectEqual(@as(u32, 0xFF00_0000), testPixel(target, 4, 2));
    try testing.expectEqual(@as(u32, 0xFF00_0000), testPixel(target, 6, 2));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), testPixel(target, 7, 2));
}

test "glyph samples its atlas texels one-to-one when aligned" {
    // Goal: an aligned glyph must reproduce atlas texels exactly. A half-texel
    // mapping error would blend neighbors and change every value below.
    var atlas_data: [16]u8 = @splat(0);
    atlas_data[1 * 4 + 1] = 255;
    atlas_data[1 * 4 + 2] = 128;
    atlas_data[2 * 4 + 1] = 64;
    const atlas = AtlasView{ .data = &atlas_data, .size = 4, .bytes_per_pixel = 1 };
    var pixels: [5 * 5]u32 = undefined;
    const target = testTarget(&pixels, 5, 5);
    drawGlyph(target, &.{
        .bounds = .{ .x = 2, .y = 2, .width = 2, .height = 2 },
        .clip = .{ .x = 0, .y = 0, .width = 5, .height = 5 },
        .uv_left = 0.25,
        .uv_top = 0.25,
        .uv_right = 0.75,
        .uv_bottom = 0.75,
    }, atlas, white);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), testPixel(target, 2, 2));
    try testing.expectEqual(@as(u32, 0xFF80_8080), testPixel(target, 3, 2));
    try testing.expectEqual(@as(u32, 0xFF40_4040), testPixel(target, 2, 3));
    try testing.expectEqual(test_background, testPixel(target, 3, 3));
    try testing.expectEqual(test_background, testPixel(target, 1, 2));
}

test "svg fill covers stroke and stroke shows where fill is absent" {
    // Goal: red carries fill coverage and green carries stroke coverage; the
    // stroke must be hidden under full fill and visible without it.
    const atlas_data = [_]u8{ 255, 255, 0, 255, 0, 255, 0, 255 };
    const atlas = AtlasView{ .data = &atlas_data, .size = 1, .bytes_per_pixel = 4 };
    var pixels: [1 * 1]u32 = undefined;
    const target = testTarget(&pixels, 1, 1);
    const rect = TexturedRect{
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .uv_left = 0,
        .uv_top = 0,
        .uv_right = 1,
        .uv_bottom = 1,
    };
    // The 1x1 atlas view reads only the first texel: fill and stroke both set.
    drawSvg(target, &rect, atlas, red, green);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), testPixel(target, 0, 0));

    const stroke_only = AtlasView{ .data = atlas_data[4..], .size = 1, .bytes_per_pixel = 4 };
    drawSvg(target, &rect, stroke_only, red, green);
    try testing.expectEqual(@as(u32, 0xFF00_FF00), testPixel(target, 0, 0));
}

test "image tint and opacity multiply the sampled texel" {
    // Goal: tint multiplies color and opacity scales alpha, so a white texel
    // tinted red at half opacity lands as red byte 128 over black.
    const atlas_data = [_]u8{ 255, 255, 255, 255 };
    const atlas = AtlasView{ .data = &atlas_data, .size = 1, .bytes_per_pixel = 4 };
    var pixels: [1 * 1]u32 = undefined;
    const target = testTarget(&pixels, 1, 1);
    drawImage(target, &.{
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .uv_left = 0,
        .uv_top = 0,
        .uv_right = 1,
        .uv_bottom = 1,
    }, atlas, &.{ .tint = red, .radii = .{}, .grayscale = 0, .opacity = 0.5 });
    try testing.expectEqual(@as(u32, 0xFF80_0000), testPixel(target, 0, 0));
}

test "clear writes visible pixels only and leaves row padding untouched" {
    // Goal: a target whose stride exceeds its width (a presenter's padded
    // rows) must keep the padding bytes as they were.
    var pixels: [3 * 2]u32 = @splat(0x1234_5678);
    const target = Target{ .pixels = &pixels, .width = 2, .height = 2, .stride = 3 };
    clear(target, .{ .r = 0, .g = 0, .b = 1, .a = 1 });
    try testing.expectEqual(@as(u32, 0xFF00_00FF), pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF00_00FF), pixels[4]);
    try testing.expectEqual(@as(u32, 0x1234_5678), pixels[2]);
    try testing.expectEqual(@as(u32, 0x1234_5678), pixels[5]);
}

test "span fast paths match per-pixel shading exactly" {
    // Goal: quads fill interior and corner-row spans, and shadows reuse a
    // straight-row profile, on the strength of an invariance argument rather
    // than by evaluating each pixel. Render many random shapes both ways —
    // fast path versus shading every touched pixel through the same distance
    // functions — and require identical pixels. Asymmetric radii, borders,
    // fractional edges, blur, and offsets exercise each boundary.
    var prng = std.Random.DefaultPrng.init(0x6007_E7);
    const random = prng.random();
    var fast_pixels: [64 * 48]u32 = undefined;
    var slow_pixels: [64 * 48]u32 = undefined;
    var iteration: u32 = 0;
    while (iteration < 300) : (iteration += 1) {
        const fast = testTarget(&fast_pixels, 64, 48);
        const slow = testTarget(&slow_pixels, 64, 48);
        const quad = randomQuad(random);
        drawQuad(fast, &quad);
        drawQuadReference(slow, &quad);
        const shadow = randomShadow(random);
        drawShadow(fast, &shadow);
        drawShadowReference(slow, &shadow);
        try testing.expectEqualSlices(u32, &slow_pixels, &fast_pixels);
    }
}

fn randomUnit(random: std.Random) f32 {
    return random.float(f32);
}

fn randomQuad(random: std.Random) QuadShape {
    const width = 4 + randomUnit(random) * 50;
    const height = 4 + randomUnit(random) * 40;
    const radius_max = @min(width, height) * 0.5;
    return .{
        .bounds = .{
            .x = randomUnit(random) * 20 - 4,
            .y = randomUnit(random) * 16 - 4,
            .width = width,
            .height = height,
        },
        .clip = .{ .x = randomUnit(random) * 10, .y = 0, .width = 50, .height = 40 },
        .radii = .{
            .top_left = randomUnit(random) * radius_max,
            .top_right = randomUnit(random) * radius_max,
            .bottom_right = randomUnit(random) * radius_max,
            .bottom_left = randomUnit(random) * radius_max,
        },
        .borders = .{
            .top = @floor(randomUnit(random) * 4),
            .right = randomUnit(random) * 3,
            .bottom = @floor(randomUnit(random) * 2),
            .left = randomUnit(random) * 5,
        },
        .background = .{ .r = randomUnit(random), .g = 0.3, .b = 0.6, .a = 0.4 + randomUnit(random) * 0.6 },
        .border_color = .{ .r = 0.1, .g = randomUnit(random), .b = 0.2, .a = 1 },
    };
}

fn randomShadow(random: std.Random) ShadowShape {
    const width = 2 + randomUnit(random) * 30;
    const height = 2 + randomUnit(random) * 20;
    const radius = randomUnit(random) * @min(width, height) * 0.5;
    return .{
        .content = .{ .x = 8 + randomUnit(random) * 20, .y = 6 + randomUnit(random) * 10, .width = width, .height = height },
        .offset_x = randomUnit(random) * 4 - 2,
        .offset_y = randomUnit(random) * 4,
        .blur = randomUnit(random) * 6,
        .radii = .{ .top_left = radius, .top_right = radius * 0.5, .bottom_right = radius, .bottom_left = 0 },
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.2 + randomUnit(random) * 0.8 },
    };
}

fn drawQuadReference(target: Target, shape: *const QuadShape) void {
    const bounds = shape.bounds;
    const rows = touchedSpan(bounds.y, bounds.y + bounds.height, target.height)
        .intersect(clipRows(shape.clip, target.height));
    const columns = touchedSpan(bounds.x, bounds.x + bounds.width, target.width)
        .intersect(clipColumns(shape.clip, target.width));
    if (rows.isEmpty() or columns.isEmpty()) return;
    const quad = QuadGeometry.init(shape, columns);
    var y = rows.start;
    while (y < rows.end) : (y += 1) {
        shadeQuadRange(target.row(y), columns, @as(f32, @floatFromInt(y)) + 0.5, &quad);
    }
}

fn drawShadowReference(target: Target, shape: *const ShadowShape) void {
    const content = shape.content;
    const expand = shape.blur * 2.0;
    const left = content.x + shape.offset_x - expand;
    const top = content.y + shape.offset_y - expand;
    const rows = centerSpanHalfOpen(top, top + content.height + expand * 2.0, target.height);
    const columns = centerSpanHalfOpen(left, left + content.width + expand * 2.0, target.width);
    if (rows.isEmpty() or columns.isEmpty()) return;
    const falloff = ShadowFalloff.init(shape);
    const base = premulFromStraight(shape.color);
    var y = rows.start;
    while (y < rows.end) : (y += 1) {
        const local_y = @as(f32, @floatFromInt(y)) + 0.5 - falloff.center_y;
        shadeShadowRange(target.row(y), columns, local_y, &falloff, base);
    }
}
