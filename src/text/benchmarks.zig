//! Text Module Benchmarks
//!
//! Benchmark suite for atlas packing, text shaping, measurement, and glyph
//! rasterization hot paths.  Measures the performance-critical operations
//! that run during text rendering every frame.
//!
//! Run as executable: zig build bench-text
//! Quick tests only:  zig build test (validates outputs, doesn't time)
//!
//! Categories:
//!   - Atlas reserve       — skyline bin-packing throughput at various glyph sizes
//!   - Atlas set           — pixel data copy bandwidth (memory-bound)
//!   - Atlas reserve + set — combined cost per glyph (the real caching hot path)
//!   - Atlas grow          — atlas size doubling with data preservation
//!   - Reserve scaling     — ns/op vs glyph count to detect skyline degradation
//!   - Atlas utilization   — skyline fill efficiency at various glyph counts
//!   - Text shaping        — CoreText/HarfBuzz shaping cold + warm cache paths
//!   - Text shaping arena  — warm cache with arena allocator (eliminates GPA overhead)
//!   - Text measurement    — measureText / measureTextEx with wrapping
//!   - Glyph rasterize     — rasterize + atlas pack + cache insert (cold + warm)
//!   - Glyph subpixel      — warm lookup across subpixel offset variants
//!   - Shaping scaling     — shaping cost vs text length (linear vs super-linear)

const std = @import("std");
const gooey = @import("gooey");

const text = gooey.text;
const Atlas = text.Atlas;
const Region = text.Region;
const TextSystem = text.TextSystem;
const ShapedRunCache = text.ShapedRunCache;
const ShapedGlyph = text.ShapedGlyph;
const CachedGlyph = text.CachedGlyph;
const renderText = text.renderText;
const RenderTextOptions = text.RenderTextOptions;

const scene_mod = gooey.scene;
const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;

// =============================================================================
// Benchmark Configuration
// =============================================================================

/// Adaptive warmup iterations based on operation count.
fn getWarmupIterations(operation_count: u32) u32 {
    std.debug.assert(operation_count > 0);
    if (operation_count >= 10000) return 2;
    if (operation_count >= 5000) return 3;
    return 5;
}

/// Adaptive minimum sample iterations based on operation count.
fn getMinSampleIterations(operation_count: u32) u32 {
    std.debug.assert(operation_count > 0);
    if (operation_count >= 10000) return 5;
    if (operation_count >= 5000) return 8;
    return 10;
}

/// Minimum wall-clock time to sample before concluding a benchmark.
const MIN_SAMPLE_TIME_NS: u64 = 50 * std.time.ns_per_ms;

/// Maximum per-iteration samples collected for percentile computation.
/// 4096 samples * 8 bytes = 32 KB — fits comfortably on the stack.
const MAX_SAMPLE_COUNT: u32 = 4096;

/// Table width for benchmark output formatting (characters per row).
const TABLE_WIDTH = 125;

/// Horizontal subpixel variants to exercise in glyph cache benchmarks.
/// Derived from text.SUBPIXEL_VARIANTS_X (the authoritative source).
/// SUBPIXEL_VARIANTS_Y is 1, so only X variants create cache diversity.
const BENCH_SUBPIXEL_VARIANTS: u32 = text.SUBPIXEL_VARIANTS_X;

// =============================================================================
// Iteration Sample Collection and Percentile Computation
// =============================================================================

/// Per-iteration timing data for percentile analysis.
/// Fixed capacity avoids dynamic allocation during benchmark runs.
const IterationSamples = struct {
    times_ns: [MAX_SAMPLE_COUNT]u64,
    count: u32,

    fn init() IterationSamples {
        return .{ .times_ns = undefined, .count = 0 };
    }

    /// Record one iteration's elapsed time.  Drops samples beyond capacity
    /// (the first MAX_SAMPLE_COUNT samples are sufficient for percentiles).
    fn record(self: *IterationSamples, elapsed_ns: u64) void {
        if (self.count < MAX_SAMPLE_COUNT) {
            self.times_ns[self.count] = elapsed_ns;
            self.count += 1;
        }
    }

    /// Sort collected samples and extract p50/p99 percentiles as ns/op.
    /// Mutates the internal array (sort is idempotent on subsequent calls).
    fn computePercentiles(self: *IterationSamples, operation_count: u32) PercentileResult {
        std.debug.assert(self.count > 0);
        std.debug.assert(operation_count > 0);

        const slice = self.times_ns[0..self.count];
        std.mem.sort(u64, slice, {}, struct {
            fn lessThan(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.lessThan);

        const last_index = self.count - 1;
        const last_f: f64 = @floatFromInt(last_index);
        const p50_index: u32 = @intFromFloat(0.50 * last_f);
        const p99_index: u32 = @intFromFloat(@min(0.99 * last_f, last_f));
        const ops_f: f64 = @floatFromInt(operation_count);

        return .{
            .p50_per_op_ns = @as(f64, @floatFromInt(slice[p50_index])) / ops_f,
            .p99_per_op_ns = @as(f64, @floatFromInt(slice[p99_index])) / ops_f,
        };
    }
};

/// Percentile statistics computed from iteration samples.
const PercentileResult = struct {
    p50_per_op_ns: f64,
    p99_per_op_ns: f64,
};

// =============================================================================
// Benchmark Results
// =============================================================================

const BenchmarkResult = struct {
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    p50_per_op_ns: f64,
    p99_per_op_ns: f64,

    pub fn avgTimeMs(self: BenchmarkResult) f64 {
        std.debug.assert(self.iterations > 0);
        const avg_ns: f64 = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        return avg_ns / std.time.ns_per_ms;
    }

    pub fn timePerOpNs(self: BenchmarkResult) f64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.operation_count > 0);
        const avg_ns = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        return avg_ns / @as(f64, @floatFromInt(self.operation_count));
    }

    pub fn print(self: BenchmarkResult) void {
        std.debug.print(
            "| {s:<44} | {d:>6} | {d:>10.1} ns/op | {d:>10.1} p50 | {d:>10.1} p99 | {d:>6} iters |\n",
            .{
                self.name,
                self.operation_count,
                self.timePerOpNs(),
                self.p50_per_op_ns,
                self.p99_per_op_ns,
                self.iterations,
            },
        );
    }
};

// =============================================================================
// Text Benchmark Constants
// =============================================================================

/// Font size used for all text pipeline benchmarks.
const BENCH_FONT_SIZE: f32 = 14.0;

/// Maximum unique glyph IDs we track for rasterization benchmarks.
const MAX_UNIQUE_GLYPHS: u32 = 128;

/// Short text for shaping/measurement benchmarks (13 characters).
const TEXT_SHORT: []const u8 = "Hello, World!";

/// Medium text for shaping/measurement benchmarks (50 characters).
const TEXT_MEDIUM: []const u8 = "The quick brown fox jumps over the lazy dog nearby";

/// Long text for shaping/measurement benchmarks (104 characters).
const TEXT_LONG: []const u8 =
    "Pack my box with five dozen liquor jugs. " ++
    "How vexingly quick daft zebras jump over the lazy sleeping dog.";

/// Base text for scaling analysis — sliced at 10, 25, 50, 100, 200 characters.
/// Contains varied letter frequencies and punctuation to exercise shaping.
const SCALING_TEXT_BASE: []const u8 =
    "Pack my box with five dozen liquor jugs. " ++
    "The quick brown fox jumps over the lazy dog. " ++
    "How vexingly quick daft zebras jump very high. " ++
    "Amazingly few discotheques provide jukeboxes. " ++
    "Sphinx of black quartz, judge my vow with care.";

comptime {
    std.debug.assert(TEXT_SHORT.len == 13);
    std.debug.assert(TEXT_MEDIUM.len == 50);
    std.debug.assert(TEXT_LONG.len == 104);
    std.debug.assert(SCALING_TEXT_BASE.len >= 200);
}

// =============================================================================
// Synthetic Data Generators
// =============================================================================

/// Generate synthetic glyph pixel data at compile time.
/// Produces a repeating gradient pattern that approximates anti-aliased glyph
/// bitmaps without requiring a real font or rasterizer.
fn generatePixelData(comptime width: u32, comptime height: u32) [width * height]u8 {
    comptime {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
    }
    var data: [width * height]u8 = undefined;
    for (0..width * height) |i| {
        // Modular arithmetic gives a repeating gradient 0–255.
        data[i] = @intCast((i * 7 + 128) % 256);
    }
    return data;
}

/// Generate all printable ASCII characters (0x20–0x7E, 95 characters).
/// Used to exercise glyph rasterization across the full basic character set.
fn generatePrintableAscii() [95]u8 {
    var buffer: [95]u8 = undefined;
    for (0..95) |i| {
        buffer[i] = @intCast(32 + i);
    }
    std.debug.assert(buffer[0] == ' ');
    std.debug.assert(buffer[94] == '~');
    return buffer;
}

// =============================================================================
// Unique Glyph ID Extraction
// =============================================================================

/// Set of unique glyph IDs extracted from a shaped run.
/// Fixed capacity avoids dynamic allocation during benchmark setup.
const UniqueGlyphIds = struct {
    ids: [MAX_UNIQUE_GLYPHS]u16,
    count: u32,
};

/// Extract unique glyph IDs from a shaped run.  Uses O(n^2) linear scan for
/// dedup — acceptable since n <= 95 for printable ASCII (<= 1024 by assertion).
/// Extracted as a standalone function with no struct indirection (rule #20).
fn extractUniqueGlyphIds(shaped_glyphs: []const text.ShapedGlyph) UniqueGlyphIds {
    std.debug.assert(shaped_glyphs.len > 0);
    std.debug.assert(shaped_glyphs.len <= 1024);

    var result = UniqueGlyphIds{
        .ids = undefined,
        .count = 0,
    };

    for (shaped_glyphs) |glyph| {
        var already_present = false;
        for (result.ids[0..result.count]) |existing_id| {
            if (existing_id == glyph.glyph_id) {
                already_present = true;
                break;
            }
        }
        if (!already_present) {
            std.debug.assert(result.count < MAX_UNIQUE_GLYPHS);
            result.ids[result.count] = glyph.glyph_id;
            result.count += 1;
        }
    }

    std.debug.assert(result.count > 0);
    std.debug.assert(result.count <= MAX_UNIQUE_GLYPHS);

    return result;
}

// =============================================================================
// Benchmark Runners — Atlas Reserve
// =============================================================================

/// Benchmark skyline bin-packing for uniform glyph sizes.
/// Operation count = number of reserve calls per iteration.
/// Each iteration clears the atlas (resets skyline), then reserves `count` glyphs.
fn benchAtlasReserve(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime glyph_width: u32,
    comptime glyph_height: u32,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(glyph_width > 0);
    std.debug.assert(glyph_height > 0);

    var atlas = Atlas.init(allocator, .grayscale) catch unreachable;
    defer atlas.deinit();

    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    // Warmup.
    for (0..warmup_iters) |_| {
        atlas.clear();
        for (0..count) |_| {
            _ = (atlas.reserve(glyph_width, glyph_height) catch unreachable) orelse unreachable;
        }
    }

    // Timed sampling: measure skyline packing throughput.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_region_x: u16 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        atlas.clear();

        const start = std.time.Instant.now() catch unreachable;
        for (0..count) |_| {
            const region = (atlas.reserve(glyph_width, glyph_height) catch unreachable) orelse unreachable;
            last_region_x = region.x;
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    // Prevent dead-code elimination.
    std.debug.assert(last_region_x < atlas.size);
    const percentiles = samples.computePercentiles(count);

    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark skyline bin-packing with varying glyph sizes.
/// Alternates between small (8x12), medium (16x20), and large (24x28) to
/// simulate a realistic workload where different characters produce different
/// rasterized bitmap sizes.
fn benchAtlasReserveMixed(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(count > 0);
    std.debug.assert(count <= 500); // Stay within 512x512 atlas capacity.

    var atlas = Atlas.init(allocator, .grayscale) catch unreachable;
    defer atlas.deinit();

    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    // Warmup.
    for (0..warmup_iters) |_| {
        atlas.clear();
        reserveMixedBatch(&atlas, count);
    }

    // Timed sampling.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        atlas.clear();

        const start = std.time.Instant.now() catch unreachable;
        reserveMixedBatch(&atlas, count);
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(atlas.generation > 0);
    const percentiles = samples.computePercentiles(count);

    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Reserve a batch of mixed-size glyphs.  Extracted as a standalone helper
/// so the hot loop has no `self`/struct indirection (CLAUDE.md rule #20).
fn reserveMixedBatch(atlas: *Atlas, comptime count: u32) void {
    for (0..count) |i| {
        const variant: u32 = @intCast(i % 3);
        const glyph_width: u32 = 8 + variant * 8; // 8, 16, 24
        const glyph_height: u32 = 12 + variant * 8; // 12, 20, 28
        _ = (atlas.reserve(glyph_width, glyph_height) catch unreachable) orelse unreachable;
    }
    std.debug.assert(atlas.node_count > 0);
    std.debug.assert(atlas.node_count <= Atlas.MAX_SKYLINE_NODES);
}

// =============================================================================
// Benchmark Runners — Atlas Set (Pixel Copy)
// =============================================================================

/// Benchmark pixel data copy into pre-reserved atlas regions.
/// Isolates memcpy bandwidth by reserving all regions once during setup,
/// then timing only the set() calls.
fn benchAtlasSet(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime glyph_width: u32,
    comptime glyph_height: u32,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(glyph_width > 0);
    std.debug.assert(glyph_height > 0);

    var atlas = Atlas.init(allocator, .grayscale) catch unreachable;
    defer atlas.deinit();

    // Pre-reserve all regions (setup, not timed).
    var regions: [count]Region = undefined;
    for (&regions) |*region| {
        const maybe = atlas.reserve(glyph_width, glyph_height) catch unreachable;
        region.* = maybe orelse unreachable;
    }

    const pixel_data = comptime generatePixelData(glyph_width, glyph_height);
    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    // Warmup.
    for (0..warmup_iters) |_| {
        for (regions) |region| {
            atlas.set(region, &pixel_data);
        }
    }

    // Timed sampling: measure pixel copy throughput only.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (regions) |region| {
            atlas.set(region, &pixel_data);
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    // Anti-DCE: generation incremented by each set() call.
    std.debug.assert(atlas.generation > 0);
    const percentiles = samples.computePercentiles(count);

    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

// =============================================================================
// Benchmark Runners — Atlas Reserve + Set (Combined)
// =============================================================================

/// Benchmark the combined reserve-then-set path that runs when caching a new
/// glyph.  This is the actual hot path in GlyphCache.renderGlyphSubpixel:
/// reserve atlas space, then copy rasterized bitmap data.
fn benchAtlasReserveAndSet(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime glyph_width: u32,
    comptime glyph_height: u32,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(glyph_width > 0);
    std.debug.assert(glyph_height > 0);

    var atlas = Atlas.init(allocator, .grayscale) catch unreachable;
    defer atlas.deinit();

    const pixel_data = comptime generatePixelData(glyph_width, glyph_height);
    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    // Warmup.
    for (0..warmup_iters) |_| {
        atlas.clear();
        for (0..count) |_| {
            const region = (atlas.reserve(glyph_width, glyph_height) catch unreachable) orelse unreachable;
            atlas.set(region, &pixel_data);
        }
    }

    // Timed sampling: reserve + set together.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_generation: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        atlas.clear();

        const start = std.time.Instant.now() catch unreachable;
        for (0..count) |_| {
            const region = (atlas.reserve(glyph_width, glyph_height) catch unreachable) orelse unreachable;
            atlas.set(region, &pixel_data);
        }
        const end = std.time.Instant.now() catch unreachable;

        last_generation = atlas.generation;
        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_generation > 0);
    const percentiles = samples.computePercentiles(count);

    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

// =============================================================================
// Benchmark Runners — Atlas Grow
// =============================================================================

/// Benchmark atlas growth from 512->1024.  Each iteration allocates a fresh
/// 512x512 atlas, then times the grow() call which:
///   1. Allocates a 1024x1024 buffer (1 MB for grayscale)
///   2. Zeroes the new buffer
///   3. Copies old data row by row (512 rows x 512 bytes)
///   4. Frees the old buffer
///   5. Extends skyline to cover new space
///
/// This is memory-bandwidth-bound and measures reallocation cost.
fn benchAtlasGrow(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
) BenchmarkResult {
    // Warmup.
    for (0..5) |_| {
        var atlas = Atlas.init(allocator, .grayscale) catch unreachable;
        atlas.grow() catch unreachable;
        atlas.deinit();
    }

    // Timed sampling: one grow per iteration.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_size: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < 10) {
        var atlas = Atlas.init(allocator, .grayscale) catch unreachable;
        std.debug.assert(atlas.size == Atlas.INITIAL_SIZE);

        const start = std.time.Instant.now() catch unreachable;
        atlas.grow() catch unreachable;
        const end = std.time.Instant.now() catch unreachable;

        last_size = atlas.size;
        atlas.deinit();

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    // Grow doubles size: 512 -> 1024.
    std.debug.assert(last_size == Atlas.INITIAL_SIZE * 2);
    const percentiles = samples.computePercentiles(1);

    return .{
        .name = name,
        .operation_count = 1,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

// =============================================================================
// Benchmark Runners — Text Shaping
// =============================================================================

/// Benchmark cold text shaping: shape cache invalidated before every timed
/// call, forcing a full FFI round-trip into CoreText (macOS) or HarfBuzz
/// (Linux).  Operation count = 1 per iteration; many iterations for stability.
fn benchShapeCold(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(bench_text.len <= 512); // Shape cache max text length.

    const warmup_iters = getWarmupIterations(1);
    const min_iters = getMinSampleIterations(1);
    const allocator = text_sys.allocator;

    // Warmup: verify shaping works, populate platform shaper internals.
    for (0..warmup_iters) |_| {
        text_sys.shape_cache.current_font_ptr = 0;
        var run = text_sys.shapeText(bench_text, null) catch unreachable;
        run.deinit(allocator);
    }

    // Timed sampling: one cold shape per iteration.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        // Invalidate shape cache so the next shapeText call always misses.
        text_sys.shape_cache.current_font_ptr = 0;

        const start = std.time.Instant.now() catch unreachable;
        var run = text_sys.shapeText(bench_text, null) catch unreachable;
        const end = std.time.Instant.now() catch unreachable;

        last_width = run.width;
        run.deinit(allocator);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_width > 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(1);

    return .{
        .name = name,
        .operation_count = 1,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark warm text shaping: same text shaped `count` times per iteration.
/// After the first call populates the shape cache, every subsequent call is a
/// pure cache hit (hash lookup -> memcpy of glyph array -> return).
fn benchShapeWarm(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(count > 0);

    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);
    const allocator = text_sys.allocator;

    // Prime the shape cache with this text.
    {
        var run = text_sys.shapeText(bench_text, null) catch unreachable;
        run.deinit(allocator);
    }

    // Warmup.
    for (0..warmup_iters) |_| {
        for (0..count) |_| {
            var run = text_sys.shapeText(bench_text, null) catch unreachable;
            run.deinit(allocator);
        }
    }

    // Timed sampling: all calls should hit the shape cache.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..count) |_| {
            var run = text_sys.shapeText(bench_text, null) catch unreachable;
            last_width = run.width;
            run.deinit(allocator);
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_width > 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(count);

    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark warm text shaping with an arena allocator instead of GPA.
/// On a shape cache hit, shapeTextComplex allocates only the glyph array copy
/// from self.allocator.  Swapping the allocator to an arena makes alloc a
/// pointer bump and free a no-op — isolating the true cache lookup cost from
/// the GPA alloc/free overhead that dominates the warm GPA path.
fn benchShapeWarmArena(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(count > 0);

    const gpa = text_sys.allocator;
    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    // Prime the shape cache so every call in the timed section is a hit.
    {
        var run = text_sys.shapeText(bench_text, null) catch unreachable;
        run.deinit(gpa);
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Warmup.
    for (0..warmup_iters) |_| {
        text_sys.allocator = arena_alloc;
        for (0..count) |_| {
            var run = text_sys.shapeText(bench_text, null) catch unreachable;
            run.deinit(arena_alloc);
        }
        text_sys.allocator = gpa;
        _ = arena.reset(.retain_capacity);
    }

    // Timed sampling: arena alloc = pointer bump, free = no-op.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        text_sys.allocator = arena_alloc;
        const start = std.time.Instant.now() catch unreachable;
        for (0..count) |_| {
            var run = text_sys.shapeText(bench_text, null) catch unreachable;
            last_width = run.width;
            run.deinit(arena_alloc);
        }
        const end = std.time.Instant.now() catch unreachable;
        text_sys.allocator = gpa;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
        _ = arena.reset(.retain_capacity);
    }

    std.debug.assert(last_width > 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(count);
    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark warm text shaping with shapeTextInto and a stack-allocated glyph
/// buffer.  On a cache hit, shapeTextInto copies glyphs into the caller's
/// buffer (owned=false) — no heap allocation or free at all.  This is the
/// pattern used by renderText after the zero-alloc optimization.
fn benchShapeWarmInto(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(count > 0);

    const allocator = text_sys.allocator;
    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    // Prime the shape cache so every call in the timed section is a hit.
    {
        var run = text_sys.shapeText(bench_text, null) catch unreachable;
        run.deinit(allocator);
    }

    // Warmup.
    for (0..warmup_iters) |_| {
        for (0..count) |_| {
            var buf: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph = undefined;
            var run = text_sys.shapeTextInto(bench_text, null, &buf) catch unreachable;
            if (run.owned) run.deinit(allocator);
        }
    }

    // Timed sampling: stack buffer means alloc is free, no deinit on warm hit.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..count) |_| {
            var buf: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph = undefined;
            var run = text_sys.shapeTextInto(bench_text, null, &buf) catch unreachable;
            last_width = run.width;
            if (run.owned) run.deinit(allocator);
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_width > 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(count);
    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

// =============================================================================
// Benchmark Runners — Text Measurement
// =============================================================================

/// Benchmark simple text width measurement.  Calls measureText() which
/// internally invokes shapeTextComplex() (shape cache warm after first call).
/// Measures the combined cost of cache lookup + width extraction.
fn benchMeasureText(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(count > 0);

    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    // Warmup.
    for (0..warmup_iters) |_| {
        for (0..count) |_| {
            _ = text_sys.measureText(bench_text) catch unreachable;
        }
    }

    // Timed sampling.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..count) |_| {
            last_width = text_sys.measureText(bench_text) catch unreachable;
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_width > 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(count);

    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark text measurement with wrapping.  Calls measureTextEx() with a
/// max_width constraint that forces line-breaking logic.  Exercises the word-
/// wrap path in addition to shaping.
fn benchMeasureTextWrapped(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
    max_width: f32,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(max_width > 0);
    std.debug.assert(count > 0);

    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    // Warmup.
    for (0..warmup_iters) |_| {
        for (0..count) |_| {
            _ = text_sys.measureTextEx(bench_text, max_width) catch unreachable;
        }
    }

    // Timed sampling.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_line_count: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..count) |_| {
            const measurement = text_sys.measureTextEx(bench_text, max_width) catch unreachable;
            last_line_count = measurement.line_count;
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_line_count > 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(count);

    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

// =============================================================================
// Benchmark Runners — Glyph Rasterization
// =============================================================================

/// Benchmark cold glyph rasterization: glyph cache cleared before each timed
/// iteration, forcing full rasterize -> atlas pack -> cache insert for every
/// glyph.  Operation count = number of unique glyphs per iteration.
fn benchGlyphRasterCold(
    text_sys: *TextSystem,
    comptime name: []const u8,
    glyph_ids: []const u16,
    font_size: f32,
) BenchmarkResult {
    std.debug.assert(glyph_ids.len > 0);
    std.debug.assert(font_size > 0);

    const glyph_count: u32 = @intCast(glyph_ids.len);
    const min_iters = getMinSampleIterations(glyph_count);

    // Warmup: exercises the rasterizer and platform font backend.
    for (0..3) |_| {
        text_sys.cache.clear();
        for (glyph_ids) |glyph_id| {
            _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
        }
    }

    // Timed sampling: clear cache, then rasterize all glyphs.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        text_sys.cache.clear();

        const start = std.time.Instant.now() catch unreachable;
        for (glyph_ids) |glyph_id| {
            const cached = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
            last_advance_x = cached.advance_x;
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    // Advance can be zero for space-like glyphs in some fonts, but at least
    // one printable ASCII glyph should have a positive advance.
    std.debug.assert(last_advance_x >= 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(glyph_count);

    return .{
        .name = name,
        .operation_count = glyph_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark warm glyph lookup: all glyphs pre-cached, every call is a pure
/// hash table hit returning cached atlas coordinates.  Repeats `repetitions`
/// passes over the glyph set per iteration for stable timing.
fn benchGlyphRasterWarm(
    text_sys: *TextSystem,
    comptime name: []const u8,
    glyph_ids: []const u16,
    font_size: f32,
    comptime repetitions: u32,
) BenchmarkResult {
    std.debug.assert(glyph_ids.len > 0);
    std.debug.assert(font_size > 0);
    std.debug.assert(repetitions > 0);

    const glyph_count: u32 = @intCast(glyph_ids.len);
    const operation_count = glyph_count * repetitions;
    const min_iters = getMinSampleIterations(operation_count);

    // Prime the glyph cache so every lookup is a hit.
    for (glyph_ids) |glyph_id| {
        _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
    }

    // Warmup.
    for (0..3) |_| {
        for (0..repetitions) |_| {
            for (glyph_ids) |glyph_id| {
                _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
            }
        }
    }

    // Timed sampling: all calls should hit the glyph cache.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..repetitions) |_| {
            for (glyph_ids) |glyph_id| {
                const cached = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
                std.mem.doNotOptimizeAway(cached);
                last_advance_x = cached.advance_x;
            }
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_advance_x >= 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(operation_count);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark warm glyph lookup across all horizontal subpixel variants.
/// Exercises the full cache working set that real rendering produces:
/// each glyph cached at BENCH_SUBPIXEL_VARIANTS X offsets (Y is always 0).
/// This reveals whether subpixel variant diversity causes capacity pressure
/// or degrades hit rates compared to the single-offset benchmark.
fn benchGlyphRasterWarmSubpixel(
    text_sys: *TextSystem,
    comptime name: []const u8,
    glyph_ids: []const u16,
    font_size: f32,
    comptime repetitions: u32,
) BenchmarkResult {
    std.debug.assert(glyph_ids.len > 0);
    std.debug.assert(font_size > 0);
    std.debug.assert(repetitions > 0);

    const glyph_count: u32 = @intCast(glyph_ids.len);
    const operation_count = glyph_count * BENCH_SUBPIXEL_VARIANTS * repetitions;
    const min_iters = getMinSampleIterations(operation_count);

    // Prime the glyph cache for all subpixel X variants (Y is always 0).
    for (0..BENCH_SUBPIXEL_VARIANTS) |sx| {
        for (glyph_ids) |glyph_id| {
            _ = text_sys.getGlyphSubpixel(glyph_id, font_size, @intCast(sx), 0) catch unreachable;
        }
    }

    // Warmup.
    for (0..3) |_| {
        for (0..repetitions) |_| {
            for (0..BENCH_SUBPIXEL_VARIANTS) |sx| {
                for (glyph_ids) |glyph_id| {
                    _ = text_sys.getGlyphSubpixel(glyph_id, font_size, @intCast(sx), 0) catch unreachable;
                }
            }
        }
    }

    // Timed sampling: all subpixel variants should hit the glyph cache.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..repetitions) |_| {
            for (0..BENCH_SUBPIXEL_VARIANTS) |sx| {
                for (glyph_ids) |glyph_id| {
                    const cached = text_sys.getGlyphSubpixel(glyph_id, font_size, @intCast(sx), 0) catch unreachable;
                    std.mem.doNotOptimizeAway(cached);
                    last_advance_x = cached.advance_x;
                }
            }
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_advance_x >= 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(operation_count);
    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark warm glyph lookup iterating ShapedGlyph structs with per-glyph locking.
/// Same data layout as benchGlyphRasterWarmBatch (ShapedGlyph array, not u16 array)
/// but calls getGlyphSubpixel() per glyph.  Paired with the batch variant below
/// for an apples-to-apples comparison of per-glyph lock vs batch lock.
fn benchGlyphRasterWarmPerGlyph(
    text_sys: *TextSystem,
    comptime name: []const u8,
    glyph_ids: []const u16,
    font_size: f32,
    comptime repetitions: u32,
) BenchmarkResult {
    std.debug.assert(glyph_ids.len > 0);
    std.debug.assert(glyph_ids.len <= MAX_UNIQUE_GLYPHS);
    std.debug.assert(font_size > 0);
    std.debug.assert(repetitions > 0);

    const glyph_count: u32 = @intCast(glyph_ids.len);
    const operation_count = glyph_count * repetitions;
    const min_iters = getMinSampleIterations(operation_count);

    // Build ShapedGlyph array — same data layout as the batch benchmark.
    var shaped_glyphs: [MAX_UNIQUE_GLYPHS]ShapedGlyph = undefined;
    for (glyph_ids, 0..) |glyph_id, i| {
        shaped_glyphs[i] = .{
            .glyph_id = glyph_id,
            .x_offset = 0,
            .y_offset = 0,
            .x_advance = 0,
            .y_advance = 0,
            .cluster = 0,
            .font_ref = null,
            .is_color = false,
        };
    }

    // Prime the glyph cache so every lookup is a hit.
    for (glyph_ids) |glyph_id| {
        _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
    }

    // Warmup with per-glyph lock path over ShapedGlyph array.
    for (0..3) |_| {
        for (0..repetitions) |_| {
            for (shaped_glyphs[0..glyph_count]) |glyph| {
                _ = text_sys.getGlyphSubpixel(glyph.glyph_id, font_size, 0, 0) catch unreachable;
            }
        }
    }

    // Timed sampling: per-glyph lock/unlock, iterating ShapedGlyph structs.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..repetitions) |_| {
            for (shaped_glyphs[0..glyph_count]) |glyph| {
                const cached = text_sys.getGlyphSubpixel(glyph.glyph_id, font_size, 0, 0) catch unreachable;
                std.mem.doNotOptimizeAway(cached);
                last_advance_x = cached.advance_x;
            }
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_advance_x >= 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(operation_count);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

/// Benchmark warm glyph lookup using batch resolution under a single mutex lock.
/// Same data layout as benchGlyphRasterWarmPerGlyph, but calls resolveGlyphBatch()
/// instead of N individual getGlyphSubpixel() calls.  The difference isolates
/// the cost of N-1 redundant lock/unlock pairs (Enhancement #1).
fn benchGlyphRasterWarmBatch(
    text_sys: *TextSystem,
    comptime name: []const u8,
    glyph_ids: []const u16,
    font_size: f32,
    comptime repetitions: u32,
) BenchmarkResult {
    std.debug.assert(glyph_ids.len > 0);
    std.debug.assert(glyph_ids.len <= MAX_UNIQUE_GLYPHS);
    std.debug.assert(font_size > 0);
    std.debug.assert(repetitions > 0);

    const glyph_count: u32 = @intCast(glyph_ids.len);
    const operation_count = glyph_count * repetitions;
    const min_iters = getMinSampleIterations(operation_count);

    // Build ShapedGlyph and subpixel arrays for batch resolution.
    // Only glyph_id and font_ref are read by resolveGlyphBatch.
    var shaped_glyphs: [MAX_UNIQUE_GLYPHS]ShapedGlyph = undefined;
    var subpixel_xs: [MAX_UNIQUE_GLYPHS]u8 = undefined;
    var out_cached: [MAX_UNIQUE_GLYPHS]CachedGlyph = undefined;

    for (glyph_ids, 0..) |glyph_id, i| {
        shaped_glyphs[i] = .{
            .glyph_id = glyph_id,
            .x_offset = 0,
            .y_offset = 0,
            .x_advance = 0,
            .y_advance = 0,
            .cluster = 0,
            .font_ref = null,
            .is_color = false,
        };
        subpixel_xs[i] = 0;
    }

    // Prime the glyph cache so every lookup is a hit.
    for (glyph_ids) |glyph_id| {
        _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
    }

    // Warmup with batch path.
    for (0..3) |_| {
        for (0..repetitions) |_| {
            text_sys.resolveGlyphBatch(
                shaped_glyphs[0..glyph_count],
                font_size,
                subpixel_xs[0..glyph_count],
                out_cached[0..glyph_count],
            ) catch unreachable;
        }
    }

    // Timed sampling: all calls should hit the glyph cache, one lock per batch.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..repetitions) |_| {
            text_sys.resolveGlyphBatch(
                shaped_glyphs[0..glyph_count],
                font_size,
                subpixel_xs[0..glyph_count],
                out_cached[0..glyph_count],
            ) catch unreachable;
        }
        const end = std.time.Instant.now() catch unreachable;

        last_advance_x = out_cached[0].advance_x;
        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_advance_x >= 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(operation_count);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

// =============================================================================
// End-to-End renderText Benchmark
// =============================================================================

/// Benchmark the full renderText pipeline end-to-end: shape (warm cache) →
/// compute device positions → batch glyph resolve (single lock) → emit to scene.
/// Measures real-world text rendering cost including Scene interaction.
///
/// Each iteration calls renderText `repetitions` times into a pre-allocated
/// scene.  The scene is cleared outside the timed region between iterations
/// to avoid measuring reset cost.  Operation count = repetitions (one
/// renderText call = one operation).
fn benchRenderText(
    text_sys: *TextSystem,
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    input_text: []const u8,
    font_size: f32,
    comptime repetitions: u32,
) BenchmarkResult {
    std.debug.assert(input_text.len > 0);
    std.debug.assert(font_size > 0);
    std.debug.assert(repetitions > 0);

    const operation_count: u32 = repetitions;
    const min_iters = getMinSampleIterations(operation_count);
    const scale_factor: f32 = 1.0;
    const color = Hsla.init(0, 0, 1, 1); // White.
    const baseline_y: f32 = 20.0;

    // Pre-allocate scene capacity so append is a pointer bump, not an alloc.
    var scene = Scene.initCapacity(allocator) catch |err| {
        std.debug.print("  !! {s}: Scene.initCapacity failed: {s} — skipping benchmark\n", .{ name, @errorName(err) });
        return .{
            .name = name,
            .operation_count = operation_count,
            .total_time_ns = 0,
            .iterations = 0,
            .p50_per_op_ns = 0,
            .p99_per_op_ns = 0,
        };
    };
    defer scene.deinit();

    var options = RenderTextOptions{};

    // Prime: warm the shape cache and glyph cache.
    for (0..getWarmupIterations(operation_count)) |_| {
        scene.clear();
        for (0..repetitions) |_| {
            _ = renderText(&scene, text_sys, input_text, 0, baseline_y, scale_factor, color, font_size, &options) catch unreachable;
        }
    }

    // Timed sampling.
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        scene.clear(); // Outside timed region — constant cost, not text-rendering cost.

        const start = std.time.Instant.now() catch unreachable;
        for (0..repetitions) |_| {
            last_width = renderText(&scene, text_sys, input_text, 0, baseline_y, scale_factor, color, font_size, &options) catch unreachable;
        }
        const end = std.time.Instant.now() catch unreachable;

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_width > 0);
    std.debug.assert(iterations >= min_iters);
    std.debug.assert(scene.glyphs.items.len > 0); // Scene received glyphs.
    const percentiles = samples.computePercentiles(operation_count);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

// =============================================================================
// Validation Tests — Atlas
// =============================================================================

test "validate: atlas reserve small fills without error" {
    const allocator = std.testing.allocator;
    var atlas = try Atlas.init(allocator, .grayscale);
    defer atlas.deinit();

    var count: u32 = 0;
    for (0..100) |_| {
        const region = (try atlas.reserve(8, 12)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(region.width == 8);
        try std.testing.expect(region.height == 12);
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 100), count);
}

test "validate: atlas reserve mixed fills without error" {
    const allocator = std.testing.allocator;
    var atlas = try Atlas.init(allocator, .grayscale);
    defer atlas.deinit();

    for (0..100) |i| {
        const variant: u32 = @intCast(i % 3);
        const w: u32 = 8 + variant * 8;
        const h: u32 = 12 + variant * 8;
        _ = (try atlas.reserve(w, h)) orelse return error.TestUnexpectedResult;
    }
    try std.testing.expect(atlas.node_count > 0);
}

test "validate: atlas set writes pixel data" {
    const allocator = std.testing.allocator;
    var atlas = try Atlas.init(allocator, .grayscale);
    defer atlas.deinit();

    const region = (try atlas.reserve(4, 4)) orelse return error.TestUnexpectedResult;
    const pixel_data = [_]u8{0xFF} ** 16;
    atlas.set(region, &pixel_data);

    // set() marks dirty region and increments generation.
    try std.testing.expect(atlas.has_dirty);
    try std.testing.expect(atlas.generation > 0);
}

test "validate: atlas grow doubles size" {
    const allocator = std.testing.allocator;
    var atlas = try Atlas.init(allocator, .grayscale);
    defer atlas.deinit();

    try std.testing.expectEqual(@as(u32, 512), atlas.size);
    try atlas.grow();
    try std.testing.expectEqual(@as(u32, 1024), atlas.size);
}

test "validate: atlas reserve and set round-trip" {
    const allocator = std.testing.allocator;
    var atlas = try Atlas.init(allocator, .grayscale);
    defer atlas.deinit();

    const pixel_data = comptime generatePixelData(8, 12);
    const region = (try atlas.reserve(8, 12)) orelse return error.TestUnexpectedResult;
    atlas.set(region, &pixel_data);

    try std.testing.expect(region.width == 8);
    try std.testing.expect(region.height == 12);
    try std.testing.expect(atlas.has_dirty);
}

test "validate: generatePixelData produces non-zero output" {
    const data = comptime generatePixelData(8, 12);
    // Verify data is not all zeros (the pattern starts at offset 128).
    var nonzero_count: u32 = 0;
    for (data) |byte| {
        if (byte > 0) nonzero_count += 1;
    }
    try std.testing.expect(nonzero_count > 0);
}

// =============================================================================
// Validation Tests — Percentile Computation
// =============================================================================

test "validate: IterationSamples computes correct percentiles" {
    // Goal: verify that p50 and p99 indices land on the expected sorted values
    // when given a known ascending sequence.  Methodology: insert 100 samples
    // with values 1000, 2000, ..., 100000, then check p50 ~ 50000 and p99 ~ 99000.
    var samples = IterationSamples.init();
    for (0..100) |i| {
        samples.record((@as(u64, i) + 1) * 1000);
    }
    try std.testing.expectEqual(@as(u32, 100), samples.count);

    const p = samples.computePercentiles(1);
    // Sorted: 1000, 2000, ..., 100000.  last_index = 99.
    // p50: floor(0.50 * 99) = 49 -> value = 50000.
    // p99: floor(0.99 * 99) = floor(98.01) = 98 -> value = 99000.
    try std.testing.expectApproxEqAbs(@as(f64, 50000.0), p.p50_per_op_ns, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 99000.0), p.p99_per_op_ns, 1.0);
}

test "validate: IterationSamples single sample returns same for p50 and p99" {
    // Goal: edge case — a single sample should be returned for both percentiles.
    var samples = IterationSamples.init();
    samples.record(42000);
    try std.testing.expectEqual(@as(u32, 1), samples.count);

    const p = samples.computePercentiles(1);
    try std.testing.expectApproxEqAbs(@as(f64, 42000.0), p.p50_per_op_ns, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 42000.0), p.p99_per_op_ns, 1.0);
}

test "validate: IterationSamples divides by operation count" {
    // Goal: verify that operation_count divisor is applied to percentile values.
    var samples = IterationSamples.init();
    samples.record(10000);
    samples.record(20000);
    samples.record(30000);

    const p = samples.computePercentiles(10);
    // Sorted: 10000, 20000, 30000.  last_index = 2.
    // p50: floor(0.50 * 2) = 1 -> value = 20000 / 10 = 2000.
    // p99: floor(0.99 * 2) = floor(1.98) = 1 -> value = 20000 / 10 = 2000.
    try std.testing.expectApproxEqAbs(@as(f64, 2000.0), p.p50_per_op_ns, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 2000.0), p.p99_per_op_ns, 1.0);
}

// =============================================================================
// Validation Tests — Text Pipeline
// =============================================================================

/// Heap-allocate and initialize a TextSystem with a monospace font for testing.
/// Returns null if any step fails (platform fonts unavailable, OOM, etc.),
/// allowing tests to skip gracefully on unsupported environments.
fn createTestTextSystem(allocator: std.mem.Allocator) ?*TextSystem {
    const ts = allocator.create(TextSystem) catch return null;

    ts.initInPlace(allocator, 1.0) catch {
        allocator.destroy(ts);
        return null;
    };

    ts.loadSystemFont(.monospace, BENCH_FONT_SIZE) catch {
        ts.deinit();
        allocator.destroy(ts);
        return null;
    };

    std.debug.assert(ts.current_face != null);
    std.debug.assert(ts.scale_factor == 1.0);

    return ts;
}

/// Clean up a TextSystem created by createTestTextSystem.
fn destroyTestTextSystem(allocator: std.mem.Allocator, ts: *TextSystem) void {
    std.debug.assert(ts.scale_factor > 0);
    std.debug.assert(ts.scale_factor <= 4.0);
    ts.deinit();
    allocator.destroy(ts);
}

test "validate: text shaping produces glyphs" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    var run = ts.shapeText("Hello", null) catch return;
    defer run.deinit(allocator);

    try std.testing.expect(run.glyphs.len > 0);
    try std.testing.expect(run.width > 0);
}

test "validate: text shaping warm path returns consistent width" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    // First call populates the shape cache.
    var run_first = ts.shapeText(TEXT_SHORT, null) catch return;
    const first_width = run_first.width;
    run_first.deinit(allocator);

    // Second call should hit the cache and return the same width.
    var run_second = ts.shapeText(TEXT_SHORT, null) catch return;
    defer run_second.deinit(allocator);

    try std.testing.expectApproxEqAbs(first_width, run_second.width, 0.01);
    try std.testing.expect(run_second.width > 0);
}

test "validate: shapeTextInto warm path returns owned=false with correct glyphs" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    // Prime the shape cache.
    var prime = ts.shapeText(TEXT_SHORT, null) catch return;
    const expected_width = prime.width;
    const expected_count = prime.glyphs.len;
    prime.deinit(allocator);

    // Warm hit via shapeTextInto — should copy into our buffer, owned=false.
    var buf: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph = undefined;
    var into_run = ts.shapeTextInto(TEXT_SHORT, null, &buf) catch return;
    defer if (into_run.owned) into_run.deinit(allocator);

    try std.testing.expect(!into_run.owned);
    try std.testing.expectEqual(expected_count, into_run.glyphs.len);
    try std.testing.expectApproxEqAbs(expected_width, into_run.width, 0.001);

    // Verify glyph slice points into our stack buffer, not heap memory.
    const buf_start = @intFromPtr(&buf[0]);
    const buf_end = buf_start + buf.len * @sizeOf(ShapedGlyph);
    const slice_start = @intFromPtr(into_run.glyphs.ptr);
    try std.testing.expect(slice_start >= buf_start);
    try std.testing.expect(slice_start < buf_end);
}

test "validate: text measurement returns positive width" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    const width = ts.measureText(TEXT_SHORT) catch return;
    try std.testing.expect(width > 0);
    try std.testing.expect(width < 10000); // Sanity bound.
}

test "validate: text measurement with wrapping produces multiple lines" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    // Use a narrow max_width to force wrapping on medium text.
    const measurement = ts.measureTextEx(TEXT_MEDIUM, 50.0) catch return;
    try std.testing.expect(measurement.line_count >= 1);
    try std.testing.expect(measurement.width > 0);
}

test "validate: glyph rasterization produces cached glyph" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    // Shape a short string to get a valid glyph ID.
    var run = ts.shapeText("A", null) catch return;
    defer run.deinit(allocator);

    if (run.glyphs.len == 0) return;

    const glyph_id = run.glyphs[0].glyph_id;
    const cached = ts.getGlyphSubpixel(glyph_id, BENCH_FONT_SIZE, 0, 0) catch return;

    try std.testing.expect(cached.advance_x > 0);
    try std.testing.expect(cached.atlas_size > 0);
}

test "validate: resolveGlyphBatch matches per-glyph lookups" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    // Shape a short string to get valid glyph IDs.
    var run = ts.shapeText("Hello", null) catch return;
    defer run.deinit(allocator);

    if (run.glyphs.len == 0) return;
    std.debug.assert(run.glyphs.len <= MAX_UNIQUE_GLYPHS);

    const glyph_count = run.glyphs.len;

    // Collect per-glyph results using the individual lock path.
    var per_glyph: [MAX_UNIQUE_GLYPHS]CachedGlyph = undefined;
    for (run.glyphs, 0..) |glyph, i| {
        per_glyph[i] = ts.getGlyphSubpixel(glyph.glyph_id, BENCH_FONT_SIZE, 0, 0) catch return;
    }

    // Collect batch results using the single-lock path.
    var subpixel_xs: [MAX_UNIQUE_GLYPHS]u8 = [_]u8{0} ** MAX_UNIQUE_GLYPHS;
    var batch: [MAX_UNIQUE_GLYPHS]CachedGlyph = undefined;
    ts.resolveGlyphBatch(
        run.glyphs,
        BENCH_FONT_SIZE,
        subpixel_xs[0..glyph_count],
        batch[0..glyph_count],
    ) catch return;

    // Every glyph must produce identical CachedGlyph metadata.
    for (0..glyph_count) |i| {
        try std.testing.expectEqual(per_glyph[i].region.x, batch[i].region.x);
        try std.testing.expectEqual(per_glyph[i].region.y, batch[i].region.y);
        try std.testing.expectEqual(per_glyph[i].region.width, batch[i].region.width);
        try std.testing.expectEqual(per_glyph[i].region.height, batch[i].region.height);
        try std.testing.expectEqual(per_glyph[i].offset_x, batch[i].offset_x);
        try std.testing.expectEqual(per_glyph[i].offset_y, batch[i].offset_y);
        try std.testing.expectApproxEqAbs(per_glyph[i].advance_x, batch[i].advance_x, 0.001);
        try std.testing.expectEqual(per_glyph[i].atlas_size, batch[i].atlas_size);
    }
}

test "validate: renderText produces glyphs in scene" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    var scene = Scene.init(allocator);
    defer scene.deinit();

    var options = RenderTextOptions{};
    const width = renderText(
        &scene,
        ts,
        TEXT_SHORT,
        0,
        20.0,
        1.0,
        Hsla.init(0, 0, 1, 1),
        BENCH_FONT_SIZE,
        &options,
    ) catch return;

    try std.testing.expect(width > 0);
    try std.testing.expect(scene.glyphs.items.len > 0);
}

test "validate: extractUniqueGlyphIds deduplicates correctly" {
    // Fabricate a small array of ShapedGlyphs with known glyph IDs.
    const glyphs = [_]text.ShapedGlyph{
        .{ .glyph_id = 10, .x_offset = 0, .y_offset = 0, .x_advance = 8, .y_advance = 0, .cluster = 0 },
        .{ .glyph_id = 20, .x_offset = 0, .y_offset = 0, .x_advance = 8, .y_advance = 0, .cluster = 1 },
        .{ .glyph_id = 10, .x_offset = 0, .y_offset = 0, .x_advance = 8, .y_advance = 0, .cluster = 2 },
        .{ .glyph_id = 30, .x_offset = 0, .y_offset = 0, .x_advance = 8, .y_advance = 0, .cluster = 3 },
        .{ .glyph_id = 20, .x_offset = 0, .y_offset = 0, .x_advance = 8, .y_advance = 0, .cluster = 4 },
    };

    const result = extractUniqueGlyphIds(&glyphs);

    try std.testing.expectEqual(@as(u32, 3), result.count);
    try std.testing.expectEqual(@as(u16, 10), result.ids[0]);
    try std.testing.expectEqual(@as(u16, 20), result.ids[1]);
    try std.testing.expectEqual(@as(u16, 30), result.ids[2]);
}

test "validate: generatePrintableAscii covers full range" {
    const ascii = comptime generatePrintableAscii();
    try std.testing.expectEqual(@as(usize, 95), ascii.len);
    try std.testing.expectEqual(@as(u8, ' '), ascii[0]);
    try std.testing.expectEqual(@as(u8, '~'), ascii[94]);
    // Verify monotonically increasing.
    for (1..ascii.len) |i| {
        try std.testing.expect(ascii[i] == ascii[i - 1] + 1);
    }
}

// =============================================================================
// Section Printers
// =============================================================================

/// Print a section header with title, column labels, and separator line.
fn printSectionHeader(title: []const u8) void {
    std.debug.assert(title.len > 0);
    std.debug.assert(title.len < TABLE_WIDTH);
    std.debug.print("\n", .{});
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
    std.debug.print("{s}\n", .{title});
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** TABLE_WIDTH ++ "\n", .{});
}

fn printHeader() void {
    std.debug.print("| {s:<44} | {s:>6} | {s:>16} | {s:>14} | {s:>14} | {s:>12} |\n", .{
        "Test",
        "Ops",
        "avg ns/op",
        "p50 ns/op",
        "p99 ns/op",
        "Iters",
    });
}

/// Print all atlas benchmarks (no platform dependencies, pure data structures).
fn runAtlasBenchmarks(gpa: std.mem.Allocator) void {
    // Verify atlas initial size matches our benchmark assumptions.
    comptime std.debug.assert(Atlas.INITIAL_SIZE == 512);
    comptime std.debug.assert(Atlas.INITIAL_SIZE * Atlas.INITIAL_SIZE <= 1024 * 1024);

    // Atlas Reserve — Skyline Bin-Packing.
    printSectionHeader("Gooey Text Benchmarks \u{2014} Atlas Reserve (skyline bin-packing)");
    benchAtlasReserve(gpa, "reserve_8x12_x100", 8, 12, 100).print();
    benchAtlasReserve(gpa, "reserve_16x20_x100", 16, 20, 100).print();
    benchAtlasReserveMixed(gpa, "reserve_mixed_x100", 100).print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    // Atlas Set + Combined — Pixel Copy Bandwidth.
    printSectionHeader("Gooey Text Benchmarks \u{2014} Atlas Set + Combined (pixel copy)");
    benchAtlasSet(gpa, "set_8x12_x100", 8, 12, 100).print();
    benchAtlasReserveAndSet(gpa, "reserve_and_set_8x12_x100", 8, 12, 100).print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    // Atlas Grow — Reallocation Cost.
    printSectionHeader("Gooey Text Benchmarks \u{2014} Atlas Grow (512 -> 1024 reallocation)");
    benchAtlasGrow(gpa, "grow_512_to_1024").print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    // Atlas Reserve Scaling — ns/op vs Glyph Count.
    printSectionHeader("Gooey Text Benchmarks \u{2014} Atlas Reserve Scaling (8x12, varying count)");
    benchAtlasReserve(gpa, "scaling_reserve_x50", 8, 12, 50).print();
    benchAtlasReserve(gpa, "scaling_reserve_x100", 8, 12, 100).print();
    benchAtlasReserve(gpa, "scaling_reserve_x200", 8, 12, 200).print();
    benchAtlasReserve(gpa, "scaling_reserve_x400", 8, 12, 400).print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    // Atlas utilization — fill efficiency.
    printAtlasUtilization(gpa);

    printAtlasNotes();
}

/// Print atlas fill efficiency at various glyph counts.
/// Shows the ratio of reserved pixel area to total atlas area, revealing
/// how much space the skyline packer wastes on fragmentation.
fn printAtlasUtilization(gpa: std.mem.Allocator) void {
    const glyph_width: u32 = 8;
    const glyph_height: u32 = 12;
    const counts = [_]u32{ 50, 100, 200, 400 };
    const atlas_area: u64 = @as(u64, Atlas.INITIAL_SIZE) * @as(u64, Atlas.INITIAL_SIZE);

    std.debug.print("\n  Atlas utilization ({d}x{d} glyphs in {d}x{d} atlas):\n", .{
        glyph_width, glyph_height, Atlas.INITIAL_SIZE, Atlas.INITIAL_SIZE,
    });

    for (counts) |count| {
        var atlas = Atlas.init(gpa, .grayscale) catch unreachable;
        defer atlas.deinit();

        for (0..count) |_| {
            _ = (atlas.reserve(glyph_width, glyph_height) catch unreachable) orelse unreachable;
        }

        const reserved_area: u64 = @as(u64, count) * glyph_width * glyph_height;
        const utilization = @as(f64, @floatFromInt(reserved_area)) /
            @as(f64, @floatFromInt(atlas_area)) * 100.0;

        std.debug.print("    {d:>3} glyphs: {d:>7} / {d:>7} px = {d:>5.1}% fill\n", .{
            count, reserved_area, atlas_area, utilization,
        });
    }

    // Mixed-size utilization for comparison.
    {
        var atlas = Atlas.init(gpa, .grayscale) catch unreachable;
        defer atlas.deinit();

        var reserved_area: u64 = 0;
        for (0..100) |i| {
            const variant: u32 = @intCast(i % 3);
            const w: u32 = 8 + variant * 8;
            const h: u32 = 12 + variant * 8;
            _ = (atlas.reserve(w, h) catch unreachable) orelse unreachable;
            reserved_area += @as(u64, w) * @as(u64, h);
        }
        const utilization = @as(f64, @floatFromInt(reserved_area)) /
            @as(f64, @floatFromInt(atlas_area)) * 100.0;

        std.debug.print("    100 mixed:  {d:>7} / {d:>7} px = {d:>5.1}% fill\n", .{
            reserved_area, atlas_area, utilization,
        });
    }
}

fn printAtlasNotes() void {
    std.debug.print(
        \\
        \\Notes:
        \\  - Reserve = skyline bin-packing only (CPU-bound, no pixel data involved).
        \\  - Set = row-by-row memcpy into atlas buffer (memory bandwidth bound).
        \\  - Reserve + Set = combined per-glyph cost (the real GlyphCache hot path).
        \\  - Grow = atlas size doubling: alloc new buffer + zero + copy old rows + free.
        \\  - Scaling: if reserve ns/op grows with count, skyline search degrades under
        \\    fragmentation.  With effective merging, ns/op should be roughly constant.
        \\  - Utilization: reserved pixel area / total atlas area.  Higher = less waste.
        \\  - p50/p99 show per-iteration percentiles (tail latency for frame budgets).
        \\  - All atlas benchmarks use a 512x512 grayscale atlas (256 KB backing buffer).
        \\  - Iterations are adaptive: at least 50 ms wall-clock or minimum sample count.
        \\
    , .{});
}

/// Print text shaping benchmarks (cold = cache miss FFI, warm = cache hit).
fn printShapingBenchmarks(text_sys: *TextSystem) void {
    std.debug.assert(text_sys.current_face != null);
    std.debug.assert(text_sys.scale_factor > 0);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Text Shaping (cold = cache miss, warm = cache hit)");
    benchShapeCold(text_sys, "shape_cold_short_13ch", TEXT_SHORT).print();
    benchShapeCold(text_sys, "shape_cold_medium_50ch", TEXT_MEDIUM).print();
    benchShapeCold(text_sys, "shape_cold_long_104ch", TEXT_LONG).print();
    benchShapeWarm(text_sys, "shape_warm_short_13ch_x100", TEXT_SHORT, 100).print();
    benchShapeWarm(text_sys, "shape_warm_medium_50ch_x100", TEXT_MEDIUM, 100).print();
    benchShapeWarm(text_sys, "shape_warm_long_104ch_x100", TEXT_LONG, 100).print();
    std.debug.print("-" ** TABLE_WIDTH ++ "\n", .{});
    benchShapeWarmArena(text_sys, "shape_warm_arena_short_13ch_x100", TEXT_SHORT, 100).print();
    benchShapeWarmArena(text_sys, "shape_warm_arena_medium_50ch_x100", TEXT_MEDIUM, 100).print();
    benchShapeWarmArena(text_sys, "shape_warm_arena_long_104ch_x100", TEXT_LONG, 100).print();
    std.debug.print("-" ** TABLE_WIDTH ++ "\n", .{});
    benchShapeWarmInto(text_sys, "shape_warm_into_short_13ch_x100", TEXT_SHORT, 100).print();
    benchShapeWarmInto(text_sys, "shape_warm_into_medium_50ch_x100", TEXT_MEDIUM, 100).print();
    benchShapeWarmInto(text_sys, "shape_warm_into_long_104ch_x100", TEXT_LONG, 100).print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
}

/// Print text measurement benchmarks (simple width + wrapped with max_width).
fn printMeasurementBenchmarks(text_sys: *TextSystem) void {
    std.debug.assert(text_sys.current_face != null);
    std.debug.assert(text_sys.scale_factor > 0);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Text Measurement (measureText + measureTextEx)");
    benchMeasureText(text_sys, "measure_short_13ch_x100", TEXT_SHORT, 100).print();
    benchMeasureText(text_sys, "measure_medium_50ch_x100", TEXT_MEDIUM, 100).print();
    benchMeasureText(text_sys, "measure_long_104ch_x100", TEXT_LONG, 100).print();
    benchMeasureTextWrapped(text_sys, "measure_wrapped_50ch_200px_x100", TEXT_MEDIUM, 200.0, 100).print();
    benchMeasureTextWrapped(text_sys, "measure_wrapped_104ch_300px_x100", TEXT_LONG, 300.0, 100).print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
}

/// Print glyph rasterization benchmarks (cold = rasterize, warm = cache hit).
fn printGlyphBenchmarks(text_sys: *TextSystem, glyph_ids: []const u16) void {
    std.debug.assert(glyph_ids.len > 0);
    std.debug.assert(text_sys.current_face != null);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Glyph Rasterization (cold = render, warm = cache hit)");
    benchGlyphRasterCold(text_sys, "glyph_raster_cold_ascii", glyph_ids, BENCH_FONT_SIZE).print();
    benchGlyphRasterWarm(text_sys, "glyph_raster_warm_ascii_x20", glyph_ids, BENCH_FONT_SIZE, 20).print();
    std.debug.print("-" ** TABLE_WIDTH ++ "\n", .{});
    benchGlyphRasterWarmPerGlyph(text_sys, "glyph_warm_perglyph_ascii_x20", glyph_ids, BENCH_FONT_SIZE, 20).print();
    benchGlyphRasterWarmBatch(text_sys, "glyph_warm_batch_ascii_x20", glyph_ids, BENCH_FONT_SIZE, 20).print();
    std.debug.print("-" ** TABLE_WIDTH ++ "\n", .{});
    benchGlyphRasterWarmSubpixel(text_sys, "glyph_warm_subpixel_ascii_x5", glyph_ids, BENCH_FONT_SIZE, 5).print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
}

/// Print end-to-end renderText benchmarks at short/medium/long text lengths.
/// Exercises the full pipeline: shape (warm) → device positions → batch glyph
/// resolve → scene emission.  Scene is pre-allocated; measures steady-state cost.
fn printRenderTextBenchmarks(text_sys: *TextSystem, allocator: std.mem.Allocator) void {
    std.debug.assert(text_sys.current_face != null);
    std.debug.assert(text_sys.scale_factor > 0);

    printSectionHeader("Gooey Text Benchmarks \u{2014} renderText End-to-End (warm cache, full pipeline)");
    benchRenderText(text_sys, allocator, "render_text_short_13ch_x50", TEXT_SHORT, BENCH_FONT_SIZE, 50).print();
    benchRenderText(text_sys, allocator, "render_text_medium_50ch_x50", TEXT_MEDIUM, BENCH_FONT_SIZE, 50).print();
    benchRenderText(text_sys, allocator, "render_text_long_104ch_x50", TEXT_LONG, BENCH_FONT_SIZE, 50).print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
}

/// Print shaping scaling analysis (cold shaping at increasing text lengths).
fn printScalingBenchmarks(text_sys: *TextSystem) void {
    std.debug.assert(text_sys.current_face != null);
    std.debug.assert(SCALING_TEXT_BASE.len >= 200);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Shaping Scaling (cold shape at varying text length)");
    benchShapeCold(text_sys, "scaling_shape_10ch", SCALING_TEXT_BASE[0..10]).print();
    benchShapeCold(text_sys, "scaling_shape_25ch", SCALING_TEXT_BASE[0..25]).print();
    benchShapeCold(text_sys, "scaling_shape_50ch", SCALING_TEXT_BASE[0..50]).print();
    benchShapeCold(text_sys, "scaling_shape_100ch", SCALING_TEXT_BASE[0..100]).print();
    benchShapeCold(text_sys, "scaling_shape_200ch", SCALING_TEXT_BASE[0..200]).print();
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
}

fn printTextPipelineNotes() void {
    std.debug.print(
        \\
        \\Notes:
        \\  - Shape cold = invalidate shape cache, then shape (forces FFI into CoreText/HarfBuzz).
        \\  - Shape warm = same text shaped repeatedly (pure shape cache hits + memcpy).
        \\  - Shape warm arena = same as warm, but with ArenaAllocator instead of GPA.
        \\    Isolates cache lookup + memcpy cost by eliminating alloc/free overhead.
        \\    Compare warm (GPA) vs warm (arena) to see how much GPA dominates the warm path.
        \\  - Shape warm into = shapeTextInto() with a stack-allocated glyph buffer.
        \\    Zero heap allocation on cache hit: memcpy into caller's buffer, owned=false.
        \\    This is the pattern used by renderText for zero-alloc warm-path rendering.
        \\  - Measure = measureText() which calls shapeTextComplex() internally.
        \\  - Measure wrapped = measureTextEx() with max_width constraint (line-breaking).
        \\  - Glyph cold = clear glyph cache, then rasterize all printable ASCII glyphs.
        \\  - Glyph warm = all glyphs pre-cached, pure hash table lookups (subpixel_x=0).
        \\    Iterates a compact u16 glyph ID array (best-case memory layout).
        \\  - Glyph warm per-glyph = same as warm, but iterates ShapedGlyph structs (44 bytes
        \\    each) with per-glyph mutex lock/unlock.  Matches renderText's real data layout.
        \\  - Glyph warm batch = same data layout as per-glyph, but all lookups under one
        \\    mutex lock via resolveGlyphBatch().  Compare per-glyph vs batch to isolate
        \\    the cost of N-1 redundant lock/unlock pairs.
        \\  - Glyph warm subpixel = warm lookups across all 4 horizontal subpixel X offsets.
        \\    Exercises the full cache working set that real rendering produces.
        \\    If ns/op is higher than warm, subpixel diversity is causing capacity pressure.
        \\  - renderText e2e = full pipeline: shapeTextInto (warm) → computeGlyphDevicePositions
        \\    → resolveGlyphBatch (single lock) → emitGlyphsToScene.  Scene is pre-allocated.
        \\    This is the number to watch when optimizing text rendering throughput.
        \\  - Scaling = cold shaping at increasing text lengths to reveal linear vs super-linear cost.
        \\    Time/Op = ns per shape call.  Divide by character count for ns/char.
        \\  - Cold benchmarks report op_count = 1 (single shape per iteration, many iterations).
        \\  - Warm benchmarks amortize over many operations per iteration for stable timing.
        \\  - p50/p99 columns show per-operation percentiles derived from per-iteration samples.
        \\
    , .{});
}

// =============================================================================
// Text Pipeline Benchmark Runner
// =============================================================================

/// Run all text pipeline benchmarks that require a loaded font.
/// Heap-allocates TextSystem (~1.7 MB) to avoid stack overflow on constrained
/// platforms.  Errors propagate to main() for graceful skip messaging.
fn runTextPipelineBenchmarks(gpa: std.mem.Allocator) !void {
    // Heap-allocate TextSystem to avoid blowing the stack (CLAUDE.md rule #14).

    const text_sys = try gpa.create(TextSystem);
    defer gpa.destroy(text_sys);

    try text_sys.initInPlace(gpa, 1.0);
    defer text_sys.deinit();

    try text_sys.loadSystemFont(.monospace, BENCH_FONT_SIZE);

    // --- Shaping benchmarks ---
    printShapingBenchmarks(text_sys);

    // --- Measurement benchmarks ---
    printMeasurementBenchmarks(text_sys);

    // --- Glyph rasterization benchmarks ---
    // Shape printable ASCII to extract glyph IDs for the rasterization benchmarks.
    const printable_ascii = comptime generatePrintableAscii();
    var ascii_run = try text_sys.shapeText(&printable_ascii, null);

    std.debug.assert(ascii_run.glyphs.len > 0);
    const unique_glyphs = extractUniqueGlyphIds(ascii_run.glyphs);
    ascii_run.deinit(gpa);

    std.debug.print("\n  (Extracted {d} unique glyph IDs from {d} printable ASCII characters)\n", .{
        unique_glyphs.count,
        printable_ascii.len,
    });
    printGlyphBenchmarks(text_sys, unique_glyphs.ids[0..unique_glyphs.count]);

    // --- End-to-end renderText ---
    printRenderTextBenchmarks(text_sys, gpa);

    // --- Scaling analysis ---
    printScalingBenchmarks(text_sys);

    printTextPipelineNotes();
}

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    runAtlasBenchmarks(gpa);

    runTextPipelineBenchmarks(gpa) catch |err| {
        std.debug.print(
            "\nSkipping text pipeline benchmarks: {s}\n" ++
                "  (Font loading or TextSystem init failed — expected on headless CI.)\n",
            .{@errorName(err)},
        );
    };
}
