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
const FontRun = types.FontRun;

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

/// The fonts of one line of a text: `runs` partition the whole text (`types.FontRun`), the
/// line starts at byte `start` of it, and `first` is the run holding that byte (`runAt`).
/// A plain text is one run over the line with `start` 0.
pub const LineFonts = struct {
    runs: []const FontRun,
    start: u32,
    first: u32,
};

/// Returns the index of the run holding byte `offset`: the first run whose end is past it.
/// O(log n) in the number of runs.
pub fn runAt(runs: []const FontRun, offset: u32) u32 {
    std.debug.assert(runs.len > 0);
    std.debug.assert(offset < runs[runs.len - 1].end);
    var low: u32 = 0;
    var high: u32 = @intCast(runs.len - 1);
    var step_count: u32 = 0;
    while (low < high) : (step_count += 1) {
        std.debug.assert(step_count < 32);
        const middle = low + @divFloor(high - low, 2);
        if (runs[middle].end > offset) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    std.debug.assert(runs[low].end > offset);
    if (low > 0) std.debug.assert(runs[low - 1].end <= offset);
    return low;
}

pub fn measureCut(
    text_system: *TextSystem,
    text: []const u8,
    fonts: LineFonts,
    font_size: f32,
    widths: CutWidths,
) !Cut {
    std.debug.assert(font_size > 0);
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert(fonts.first < fonts.runs.len);
    if (text_system.getMetrics() == null) return error.NoFontLoaded;
    const stop = @max(widths.kept_max, widths.whole_max);
    var walk: CutWalk = .{ .text = text, .kept_max = widths.kept_max, .stop = stop };
    var offset: u32 = 0;
    var index = fonts.first;
    while (offset < text.len and !walk.stopped) : (index += 1) {
        std.debug.assert(index < fonts.runs.len);
        const run = fonts.runs[index];
        std.debug.assert(run.end > fonts.start + offset);
        const end: u32 = @intCast(@min(run.end - fonts.start, text.len));
        try walkCutSegment(text_system, &walk, .{
            .start = offset,
            .end = end,
            .font_size = font_size,
            .font_id = run.font_id,
        });
        offset = end;
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

const CutSegment = struct { start: u32, end: u32, font_size: f32, font_id: u16 };

/// Shapes one segment of a cut line, in the shaping runs `placeTextPrefix` draws it in,
/// and feeds its clusters to the walk at their offsets in the line.
fn walkCutSegment(text_system: *TextSystem, walk: *CutWalk, segment: CutSegment) !void {
    std.debug.assert(segment.start < segment.end);
    std.debug.assert(segment.end <= walk.text.len);
    const family = FontFamily.fromFontId(segment.font_id);
    const variant = FontFamily.variantFromFontId(segment.font_id);
    const size_scale = segment.font_size / text_system.getMetricsFor(family).point_size;
    std.debug.assert(size_scale > 0);
    var offset: usize = segment.start;
    var run_count: usize = 0;
    while (offset < segment.end and !walk.stopped) : (run_count += 1) {
        std.debug.assert(run_count < walk.text.len);
        const length = text_system_mod.runLength(walk.text[offset..segment.end]);
        std.debug.assert(length > 0);
        const run = walk.text[offset..][0..length];
        var glyph_buf: [MAX_GLYPHS_PER_RUN]ShapedGlyph = undefined;
        var shaped = try text_system.shapeTextInto(family, run, variant, null, &glyph_buf);
        defer if (shaped.owned) shaped.deinit(text_system.run_allocator);
        walk.run(shaped.glyphs, offset, size_scale);
        offset += length;
    }
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

const TestGlyphSink = struct {
    count: u32 = 0,
    first_x: f32 = 0,

    fn glyph(self: *TestGlyphSink, placed: PlacedGlyph) void {
        std.debug.assert(placed.width > 0);
        if (self.count == 0) self.first_x = placed.x;
        self.count += 1;
    }
};

test "a tab draws no glyph and the next glyph sits at the tab's advance" {
    const testing = std.testing;
    var uploads: @import("atlas.zig").AtlasUploads = undefined;
    try uploads.init(testing.allocator, testing.io, .{
        .storage = .cpu_texture,
        .upload_bytes_frame_max = 1 << 20,
        .consumer_count_max = 1,
    });
    defer uploads.deinit();

    const text_system = try testing.allocator.create(TextSystem);
    defer testing.allocator.destroy(text_system);
    const limits = &text_system_mod.TextLimits.standard;
    try text_system.initInPlace(testing.allocator, 1.0, testing.io, limits, .{
        .size = 512,
        .uploads = &uploads,
    });
    defer text_system.deinit();
    try text_system.loadSystemFont(.sans_serif, 16);

    var plain: TestGlyphSink = .{};
    _ = try placeText(text_system, "A", 0, 20, 1.0, 16, .app, .regular, &plain);
    try testing.expectEqual(@as(u32, 1), plain.count);

    var tabbed: TestGlyphSink = .{};
    const width = try placeText(text_system, "\tA", 0, 20, 1.0, 16, .app, .regular, &tabbed);
    const tab_advance = try text_system.measureText(.app, "\t", .regular);
    try testing.expect(tab_advance > 0);
    try testing.expectEqual(@as(u32, 1), tabbed.count);
    try testing.expectApproxEqAbs(plain.first_x + tab_advance, tabbed.first_x, 1.0);
    const letter_advance = try text_system.measureText(.app, "A", .regular);
    try testing.expectApproxEqAbs(tab_advance, width - letter_advance, 0.01);
}
test "runAt finds the run that holds an offset on both sides of every boundary" {
    // Runs end at 3, 4, and 9: offset 3 is the first byte of the second run, not the last
    // of the first, and the one-byte run at 3 is found from either neighbour.
    const testing = std.testing;
    const runs = [_]FontRun{
        .{ .end = 3, .font_id = 0 },
        .{ .end = 4, .font_id = 1 },
        .{ .end = 9, .font_id = 0 },
    };
    const expected = [_]u32{ 0, 0, 0, 1, 2, 2, 2, 2, 2 };
    for (expected, 0..) |run_index, offset| {
        try testing.expectEqual(run_index, runAt(&runs, @intCast(offset)));
    }
    const single = [_]FontRun{.{ .end = 1, .font_id = 0 }};
    try testing.expectEqual(@as(u32, 0), runAt(&single, 0));
}
