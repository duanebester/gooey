//! Text placement: shaped text to glyph quads in the glyph atlas.
//!
//! `placeText` computes device positions without the cache lock, then
//! batch-resolves all glyphs under one lock per batch, eliminating the N-1
//! lock/unlock pairs of per-glyph locking, and places each glyph into the
//! caller's sink without the lock.

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

/// Matches `ShapedRunCache.MAX_GLYPHS_PER_ENTRY`.
const MAX_GLYPHS_PER_RUN: u32 = ShapedRunCache.MAX_GLYPHS_PER_ENTRY;

// The run's shaped-glyph buffer and the four batch buffers in `placeBatches`
// are sized at MAX_GLYPHS_PER_RUN; keep their combined footprint within the
// WASM stack budget even in deep call chains (tick → emit → placeText).
comptime {
    const frame_bytes = MAX_GLYPHS_PER_RUN * (@sizeOf(ShapedGlyph) + @sizeOf(f32) + @sizeOf(f32) + @sizeOf(u8) + @sizeOf(CachedGlyph));
    std.debug.assert(frame_bytes <= 16384);
}

/// Where a shaped run starts, and how its base-size advances scale.
const RunOrigin = struct {
    x: f32,
    baseline_y: f32,
    size_scale: f32,
    scale_factor: f32,
};

/// Resolve `glyphs` and hand them to `sink.batch` in batches of at most
/// `MAX_GLYPHS_PER_RUN`, the size of the stack buffers, carrying the pen
/// across batches. A run of any length is placed exactly as one batch would
/// place it, and the glyph cache lock is taken once per batch. Shaping is
/// not split, so kerning and ligatures across a batch edge are kept.
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

/// `placeText`'s batches go to its caller's sink one glyph at a time.
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

/// Compute device-pixel coordinates and subpixel X offsets for each glyph,
/// returning the pen after the last advance, where the next batch starts.
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

/// One glyph `placeText` placed: its quad in logical pixels and its glyph
/// atlas rectangle, each UV edge in the normalized 0..1 range.
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

/// The placement of one resolved glyph, or null for an empty region
/// (spaces, zero-width characters). Snaps to the device pixel grid, adds the
/// raster offset, and converts back to logical pixels, as GPUI does:
/// floor(device_pos) + raster_offset.
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

/// Shape `text` and hand each placed glyph to `sink.glyph(placed)`, in
/// order, returning its width. A text past one shaping run is placed run by
/// run (`text_system.runLength`), each starting where the last one's advance
/// ended, so it lands as one run would; the bound is the shapers' detail.
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
    // Each run takes at least one byte, so the bytes bound the runs.
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

/// One shaping run of `placeText`, or its first `kept` bytes: the glyphs
/// before the first whose cluster starts at or past `kept`, placed from the
/// whole run's shaping so they keep its kerning. Returns the placed width.
/// The glyph cache may rasterize on a miss; the shaped run is copied into a
/// stack buffer, so only a shape-cache miss uses the text system's allocator.
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
    // Each family scales by its own regular face (`loadMonoFont`).
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

/// The glyphs of a left-to-right run before the first whose cluster starts
/// at or past byte `kept`.
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

/// Where a line cut for an ellipsis ends (`measureCut`): the bytes it keeps
/// and their width, or `whole` when the line fits and is drawn uncut.
pub const Cut = struct {
    length: u32,
    width: f32,
    whole: bool,
};

/// The widths a line is cut against: the kept bytes must fit `kept_max`
/// (the cut width less the ellipsis); the whole line is drawn uncut when it
/// fits `whole_max`, which is negative when the line must end in an
/// ellipsis whatever its width.
pub const CutWidths = struct {
    kept_max: f32,
    whole_max: f32,
};

/// Find where `text`, one left-to-right line, is cut: the longest start
/// that fits `widths.kept_max`, ending before an advancing glyph that starts
/// a cluster and after a byte that is not a space or tab, so the cut never
/// splits a UTF-8 sequence or ligature, never strands an accent (a glyph
/// with no advance) from its base, and drops trailing whitespace. Widths
/// are the shaped advances, kerning included, that `placeTextPrefix` draws.
/// Walks the line's shaping runs only until the pen passes both widths, so
/// a long paragraph costs the runs its width covers plus one.
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
    // Each run takes at least one byte, so the bytes bound the runs.
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
        // The whole line fits beside the ellipsis: a clamped line that ends
        // short of its width keeps every byte up to its trailing whitespace.
        const last = if (text.len > 0) text[text.len - 1] else ' ';
        if (walk.pen <= widths.kept_max and last != ' ' and last != '\t') {
            walk.best = .{ .length = @intCast(text.len), .width = walk.pen, .whole = false };
        }
    }
    std.debug.assert(walk.best.width <= @max(0, widths.kept_max));
    return walk.best;
}

/// `measureCut`'s pen across a line's runs, and the best cut so far.
const CutWalk = struct {
    text: []const u8,
    kept_max: f32,
    stop: f32,
    pen: f32 = 0,
    /// One past the furthest cluster start seen: a cut is only taken before
    /// a glyph that starts past every earlier glyph's cluster, so the kept
    /// glyphs are exactly those of the kept bytes.
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

/// Place the first `kept` bytes of `text` as `placeText` places the whole:
/// runs before the cut whole, and the run the cut falls in up to the glyph
/// `measureCut` stopped before, from that run's own shaping (a shape-cache
/// hit after `measureCut`). Returns the placed width.
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
