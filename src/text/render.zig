const std = @import("std");
const platform = @import("../platform/mod.zig");
const text_system_mod = @import("text_system.zig");
const TextSystem = text_system_mod.TextSystem;
const ShapedRunCache = text_system_mod.ShapedRunCache;
const CachedGlyph = text_system_mod.CachedGlyph;
const ShapedGlyph = types.ShapedGlyph;
const types = @import("types.zig");
const FontVariant = types.FontVariant;
const FontFamily = types.FontFamily;

const is_wasm = platform.is_wasm;

const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;
const SUBPIXEL_VARIANTS_F: f32 = @floatFromInt(SUBPIXEL_VARIANTS_X);

const MAX_GLYPHS_PER_RUN: u32 = ShapedRunCache.MAX_GLYPHS_PER_ENTRY;

comptime {
    const frame_bytes = MAX_GLYPHS_PER_RUN * (@sizeOf(ShapedGlyph) + @sizeOf(f32) + @sizeOf(f32) + @sizeOf(u8) + @sizeOf(CachedGlyph));
    std.debug.assert(frame_bytes <= 16384);
}

const RunOrigin = struct {
    x: f32,
    baseline_y: f32,
    size_scale: f32,
    scale_factor: f32,
};

fn placeBatches(
    text_system: *TextSystem,
    family: FontFamily,
    variant: FontVariant,
    font_size: f32,
    glyphs: []const ShapedGlyph,
    origin: RunOrigin,
    sink: anytype,
) !void {
    std.debug.assert(glyphs.len > 0);
    std.debug.assert(origin.scale_factor > 0);
    var device_x: [MAX_GLYPHS_PER_RUN]f32 = undefined;
    var device_y: [MAX_GLYPHS_PER_RUN]f32 = undefined;
    var subpixel_x: [MAX_GLYPHS_PER_RUN]u8 = undefined;
    var cached: [MAX_GLYPHS_PER_RUN]CachedGlyph = undefined;
    const batch_count = @divFloor(glyphs.len - 1, MAX_GLYPHS_PER_RUN) + 1;
    var pen_x = origin.x;
    var start: usize = 0;
    for (0..batch_count) |_| {
        const end = @min(glyphs.len, start + MAX_GLYPHS_PER_RUN);
        const batch = glyphs[start..end];
        const count = batch.len;
        std.debug.assert(count > 0);
        std.debug.assert(count <= MAX_GLYPHS_PER_RUN);
        pen_x = computeGlyphDevicePositions(
            batch,
            pen_x,
            origin.baseline_y,
            origin.size_scale,
            origin.scale_factor,
            device_x[0..count],
            device_y[0..count],
            subpixel_x[0..count],
        );
        try text_system.resolveGlyphBatch(
            family,
            batch,
            variant,
            font_size,
            subpixel_x[0..count],
            cached[0..count],
        );
        try sink.batch(cached[0..count], device_x[0..count], device_y[0..count]);
        start = end;
    }
    std.debug.assert(start == glyphs.len);
}

fn GlyphSink(comptime Sink: type) type {
    return struct {
        sink: Sink,
        scale_factor: f32,

        fn batch(
            self: *const @This(),
            glyphs: []const CachedGlyph,
            xs: []const f32,
            ys: []const f32,
        ) !void {
            std.debug.assert(glyphs.len == xs.len);
            std.debug.assert(glyphs.len == ys.len);
            const scale_factor = self.scale_factor;
            for (glyphs, xs, ys) |glyph, dx, dy| {
                const placed = placeGlyph(glyph, dx, dy, scale_factor) orelse continue;
                self.sink.glyph(placed);
            }
        }
    };
}

fn computeGlyphDevicePositions(
    shaped_glyphs: []const ShapedGlyph,
    start_x: f32,
    baseline_y: f32,
    size_scale: f32,
    scale_factor: f32,
    out_device_x: []f32,
    out_device_y: []f32,
    out_subpixel_x: []u8,
) f32 {
    std.debug.assert(shaped_glyphs.len > 0);
    std.debug.assert(shaped_glyphs.len == out_device_x.len);
    std.debug.assert(shaped_glyphs.len == out_device_y.len);
    std.debug.assert(shaped_glyphs.len == out_subpixel_x.len);
    std.debug.assert(scale_factor > 0);
    std.debug.assert(size_scale > 0);

    var pen_x = start_x;
    for (shaped_glyphs, 0..) |glyph, index| {
        const scaled_x_offset = glyph.x_offset * size_scale;
        const scaled_y_offset = glyph.y_offset * size_scale;
        const scaled_advance = glyph.x_advance * size_scale;

        const device_x = (pen_x + scaled_x_offset) * scale_factor;
        const device_y = (baseline_y + scaled_y_offset) * scale_factor;

        const fractional_x = device_x - @floor(device_x);

        out_device_x[index] = device_x;
        out_device_y[index] = device_y;
        out_subpixel_x[index] = @intFromFloat(@floor(fractional_x * SUBPIXEL_VARIANTS_F));

        pen_x += scaled_advance;
    }
    return pen_x;
}

pub const PlacedGlyph = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
};

fn placeGlyph(cached: CachedGlyph, device_x: f32, device_y: f32, scale_factor: f32) ?PlacedGlyph {
    std.debug.assert(scale_factor > 0);
    if (cached.region.width == 0 or cached.region.height == 0) return null;

    const uv = cached.uv();
    std.debug.assert(uv.u0 >= 0);
    std.debug.assert(uv.u0 <= 1);
    std.debug.assert(uv.v0 >= 0);
    std.debug.assert(uv.v0 <= 1);
    std.debug.assert(uv.u1 >= 0);
    std.debug.assert(uv.u1 <= 1);
    std.debug.assert(uv.v1 >= 0);
    std.debug.assert(uv.v1 <= 1);
    const placed = PlacedGlyph{
        .x = (@floor(device_x) + @as(f32, @floatFromInt(cached.offset_x))) / scale_factor,
        .y = (@floor(device_y) - @as(f32, @floatFromInt(cached.offset_y))) / scale_factor,
        .width = @as(f32, @floatFromInt(cached.region.width)) / scale_factor,
        .height = @as(f32, @floatFromInt(cached.region.height)) / scale_factor,
        .uv_left = uv.u0,
        .uv_top = uv.v0,
        .uv_right = uv.u1,
        .uv_bottom = uv.v1,
    };
    std.debug.assert(placed.width > 0);
    std.debug.assert(placed.height > 0);
    return placed;
}

pub fn placeText(
    text_system: *TextSystem,
    text: []const u8,
    x: f32,
    baseline_y: f32,
    scale_factor: f32,
    font_size: f32,
    family: FontFamily,
    variant: FontVariant,
    sink: anytype,
) !f32 {
    std.debug.assert(font_size > 0);
    std.debug.assert(scale_factor > 0);
    var width: f32 = 0;
    var rest = text;
    var run_count: usize = 0;
    while (rest.len > 0) : (run_count += 1) {
        std.debug.assert(run_count < text.len);
        const length = text_system_mod.runLength(rest);
        std.debug.assert(length <= rest.len);
        const run = rest[0..length];
        width += try placeRun(text_system, run, run.len, x + width, baseline_y, .{
            .scale_factor = scale_factor,
            .font_size = font_size,
            .family = family,
            .variant = variant,
        }, sink);
        rest = rest[length..];
    }
    std.debug.assert(width >= 0);
    return width;
}

const RunStyle = struct {
    scale_factor: f32,
    font_size: f32,
    family: FontFamily,
    variant: FontVariant,
};

fn placeRun(
    text_system: *TextSystem,
    text: []const u8,
    kept: usize,
    x: f32,
    baseline_y: f32,
    style: RunStyle,
    sink: anytype,
) !f32 {
    const font_size = style.font_size;
    const scale_factor = style.scale_factor;
    const family = style.family;
    const variant = style.variant;
    std.debug.assert(text.len > 0);
    std.debug.assert(kept > 0);
    std.debug.assert(kept <= text.len);
    std.debug.assert(text_system_mod.runLength(text) == text.len);
    if (text_system.getMetrics() == null) return error.NoFontLoaded;
    const metrics = text_system.getMetricsFor(family);
    const size_scale = font_size / metrics.point_size;

    var glyph_buf: [MAX_GLYPHS_PER_RUN]ShapedGlyph = undefined;
    var shaped = try text_system.shapeTextInto(family, text, variant, null, &glyph_buf);
    defer if (shaped.owned) shaped.deinit(text_system.run_allocator);
    const whole = kept == text.len;
    const glyph_count = if (whole) shaped.glyphs.len else keptGlyphCount(shaped.glyphs, kept);
    const glyphs = shaped.glyphs[0..glyph_count];
    const width = if (whole) shaped.width * size_scale else advanceSum(glyphs) * size_scale;
    if (glyphs.len == 0) return width;
    const batch_sink = GlyphSink(@TypeOf(sink)){ .sink = sink, .scale_factor = scale_factor };
    try placeBatches(text_system, family, variant, font_size, glyphs, .{
        .x = x,
        .baseline_y = baseline_y,
        .size_scale = size_scale,
        .scale_factor = scale_factor,
    }, &batch_sink);
    std.debug.assert(width >= 0);
    return width;
}

fn keptGlyphCount(glyphs: []const ShapedGlyph, kept: usize) usize {
    std.debug.assert(kept > 0);
    for (glyphs, 0..) |glyph, index| {
        if (glyph.cluster >= kept) return index;
    }
    return glyphs.len;
}

fn advanceSum(glyphs: []const ShapedGlyph) f32 {
    var sum: f32 = 0;
    for (glyphs) |glyph| sum += glyph.x_advance;
    std.debug.assert(sum >= 0);
    return sum;
}

pub const Cut = struct {
    length: u32,
    width: f32,
    whole: bool,
};

pub const CutWidths = struct {
    kept_max: f32,
    whole_max: f32,
};

pub fn measureCut(
    text_system: *TextSystem,
    text: []const u8,
    font_size: f32,
    family: FontFamily,
    variant: FontVariant,
    widths: CutWidths,
) !Cut {
    std.debug.assert(font_size > 0);
    std.debug.assert(text.len <= std.math.maxInt(u32));
    if (text_system.getMetrics() == null) return error.NoFontLoaded;
    const size_scale = font_size / text_system.getMetricsFor(family).point_size;
    const stop = @max(widths.kept_max, widths.whole_max);
    var walk: CutWalk = .{ .text = text, .kept_max = widths.kept_max, .stop = stop };
    var offset: usize = 0;
    var run_count: usize = 0;
    while (offset < text.len and !walk.stopped) : (run_count += 1) {
        std.debug.assert(run_count < text.len);
        const length = text_system_mod.runLength(text[offset..]);
        std.debug.assert(length > 0);
        const run = text[offset..][0..length];
        var glyph_buf: [MAX_GLYPHS_PER_RUN]ShapedGlyph = undefined;
        var shaped = try text_system.shapeTextInto(family, run, variant, null, &glyph_buf);
        defer if (shaped.owned) shaped.deinit(text_system.run_allocator);
        walk.run(shaped.glyphs, offset, size_scale);
        offset += length;
    }
    if (!walk.stopped) {
        if (walk.pen <= widths.whole_max) {
            return .{ .length = @intCast(text.len), .width = walk.pen, .whole = true };
        }
        const last = if (text.len > 0) text[text.len - 1] else ' ';
        if (walk.pen <= widths.kept_max and last != ' ' and last != '\t') {
            walk.best = .{ .length = @intCast(text.len), .width = walk.pen, .whole = false };
        }
    }
    std.debug.assert(walk.best.width <= @max(0, widths.kept_max));
    return walk.best;
}

const CutWalk = struct {
    text: []const u8,
    kept_max: f32,
    stop: f32,
    pen: f32 = 0,
    cluster_end: usize = 0,
    best: Cut = .{ .length = 0, .width = 0, .whole = false },
    stopped: bool = false,

    fn run(self: *CutWalk, glyphs: []const ShapedGlyph, offset: usize, size_scale: f32) void {
        std.debug.assert(size_scale > 0);
        std.debug.assert(offset <= self.text.len);
        for (glyphs) |glyph| {
            const cluster = offset + glyph.cluster;
            std.debug.assert(cluster < self.text.len);
            const starts = cluster >= self.cluster_end;
            if (starts and glyph.x_advance > 0 and cluster > 0 and self.pen <= self.kept_max) {
                const before = self.text[cluster - 1];
                if (before != ' ' and before != '\t') {
                    self.best = .{ .length = @intCast(cluster), .width = self.pen, .whole = false };
                }
            }
            if (starts) self.cluster_end = cluster + 1;
            self.pen += glyph.x_advance * size_scale;
            if (self.pen > self.stop) {
                self.stopped = true;
                return;
            }
        }
    }
};

pub fn placeTextPrefix(
    text_system: *TextSystem,
    text: []const u8,
    kept: u32,
    x: f32,
    baseline_y: f32,
    scale_factor: f32,
    font_size: f32,
    family: FontFamily,
    variant: FontVariant,
    sink: anytype,
) !f32 {
    std.debug.assert(kept <= text.len);
    std.debug.assert(font_size > 0);
    var width: f32 = 0;
    var offset: usize = 0;
    var run_count: usize = 0;
    while (offset < kept) : (run_count += 1) {
        std.debug.assert(run_count < text.len);
        const length = text_system_mod.runLength(text[offset..]);
        std.debug.assert(length > 0);
        const run = text[offset..][0..length];
        const run_kept = @min(length, kept - offset);
        width += try placeRun(text_system, run, run_kept, x + width, baseline_y, .{
            .scale_factor = scale_factor,
            .font_size = font_size,
            .family = family,
            .variant = variant,
        }, sink);
        offset += length;
    }
    std.debug.assert(width >= 0);
    return width;
}
