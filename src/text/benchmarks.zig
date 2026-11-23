const std = @import("std");
const gooey = @import("gooey");
const bench = @import("bench");

const time = struct {
    inline fn benchIo() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    const Instant = struct {
        ts: std.Io.Timestamp,

        inline fn now() Instant {
            return .{ .ts = std.Io.Timestamp.now(benchIo(), .awake) };
        }

        inline fn since(self: Instant, earlier: Instant) u64 {
            const ns: i96 = earlier.ts.durationTo(self.ts).toNanoseconds();
            std.debug.assert(ns >= 0);
            return @intCast(ns);
        }
    };
};

const text = gooey.internals.text;

const bench_text_limits = blk: {
    var value = gooey.ResourceLimits.standard.text;
    value.fonts = text.FontLimits.nano;
    value.measure_slot_count_max = gooey.ResourceLimits.small.text.measure_slot_count_max;
    break :blk value;
};
const Atlas = text.Atlas;
const Region = text.Region;
const TextSystem = text.TextSystem;
const ShapedRunCache = text.ShapedRunCache;
const ShapedGlyph = text.ShapedGlyph;
const CachedGlyph = text.CachedGlyph;

fn getWarmupIterations(operation_count: u32) u32 {
    std.debug.assert(operation_count > 0);
    if (operation_count >= 10000) return 2;
    if (operation_count >= 5000) return 3;
    return 5;
}

fn getMinSampleIterations(operation_count: u32) u32 {
    std.debug.assert(operation_count > 0);
    if (operation_count >= 10000) return 5;
    if (operation_count >= 5000) return 8;
    return 10;
}

const MIN_SAMPLE_TIME_NS: u64 = bench.sample_time_ns_min;

const MAX_SAMPLE_COUNT: u32 = 4096;

const TABLE_WIDTH = 125;

const BENCH_SUBPIXEL_VARIANTS: u32 = text.SUBPIXEL_VARIANTS_X;

const IterationSamples = struct {
    times_ns: [MAX_SAMPLE_COUNT]u64,
    count: u32,

    fn init() IterationSamples {
        return .{ .times_ns = undefined, .count = 0 };
    }

    fn record(self: *IterationSamples, elapsed_ns: u64) void {
        if (self.count < MAX_SAMPLE_COUNT) {
            self.times_ns[self.count] = elapsed_ns;
            self.count += 1;
        }
    }

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
            .min_per_op_ns = @as(f64, @floatFromInt(slice[0])) / ops_f,
            .p50_per_op_ns = @as(f64, @floatFromInt(slice[p50_index])) / ops_f,
            .p99_per_op_ns = @as(f64, @floatFromInt(slice[p99_index])) / ops_f,
        };
    }
};

const PercentileResult = struct {
    min_per_op_ns: f64,
    p50_per_op_ns: f64,
    p99_per_op_ns: f64,
};

const BenchmarkResult = struct {
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    min_per_op_ns: f64,
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

const BENCH_FONT_SIZE: f32 = 14.0;

const MAX_UNIQUE_GLYPHS: u32 = 128;

const TEXT_SHORT: []const u8 = "Hello, World!";

const TEXT_MEDIUM: []const u8 = "The quick brown fox jumps over the lazy dog nearby";

const TEXT_LONG: []const u8 =
    "Pack my box with five dozen liquor jugs. " ++
    "How vexingly quick daft zebras jump over the lazy sleeping dog.";

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

fn generatePixelData(comptime width: u32, comptime height: u32) [width * height]u8 {
    comptime {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
    }
    var data: [width * height]u8 = undefined;
    for (0..width * height) |i| {
        data[i] = @intCast((i * 7 + 128) % 256);
    }
    return data;
}

fn generatePrintableAscii() [95]u8 {
    var buffer: [95]u8 = undefined;
    for (0..95) |i| {
        buffer[i] = @intCast(32 + i);
    }
    std.debug.assert(buffer[0] == ' ');
    std.debug.assert(buffer[94] == '~');
    return buffer;
}

const UniqueGlyphIds = struct {
    ids: [MAX_UNIQUE_GLYPHS]u16,
    count: u32,
};

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

const bench_atlas_size: u32 = 1024;

const BenchAtlas = struct {
    uploads: text.AtlasUploads,
    atlas: Atlas,

    fn init(self: *BenchAtlas, allocator: std.mem.Allocator, storage: text.AtlasStorage) void {
        self.uploads.init(allocator, time.benchIo(), .{
            .storage = storage,
            .upload_bytes_frame_max = 64,
            .consumer_count_max = 1,
        }) catch unreachable;
        self.atlas.init(allocator, .{
            .kind = .text,
            .size = bench_atlas_size,
            .uploads = &self.uploads,
        }) catch unreachable;
        std.debug.assert(self.atlas.size == bench_atlas_size);
        std.debug.assert(self.atlas.rows_active == 0);
    }

    fn deinit(self: *BenchAtlas) void {
        self.atlas.deinit();
        self.uploads.deinit();
    }

    fn nextFrame(self: *BenchAtlas) void {
        _ = self.uploads.beginFrame(1);
        std.debug.assert(self.uploads.frameCurrent() > 1);
    }

    fn reset(self: *BenchAtlas) void {
        self.atlas.clear();
        self.nextFrame();
        var evicted: u32 = 0;
        while (self.atlas.evictOne()) evicted += 1;
        std.debug.assert(self.atlas.rows_active == 0);
        std.debug.assert(evicted <= self.atlas.shelves.len);
    }
};

fn benchAtlasInsert(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    storage: text.AtlasStorage,
    comptime glyph_width: u32,
    comptime glyph_height: u32,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(glyph_width > 0);
    std.debug.assert(glyph_height > 0);
    const bench_atlas = allocator.create(BenchAtlas) catch unreachable;
    defer allocator.destroy(bench_atlas);
    bench_atlas.init(allocator, storage);
    defer bench_atlas.deinit();
    const pixel_data = comptime generatePixelData(glyph_width, glyph_height);

    for (0..getWarmupIterations(count)) |_| {
        bench_atlas.reset();
        insertUniformBatch(&bench_atlas.atlas, glyph_width, glyph_height, &pixel_data, count);
    }
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < getMinSampleIterations(count)) {
        bench_atlas.reset();
        const start = time.Instant.now();
        insertUniformBatch(&bench_atlas.atlas, glyph_width, glyph_height, &pixel_data, count);
        const elapsed = time.Instant.now().since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }
    std.debug.assert(bench_atlas.atlas.rows_active > 0);
    return atlasResult(name, count, total_time_ns, iterations, samples.computePercentiles(count));
}

fn insertUniformBatch(atlas: *Atlas, width: u32, height: u32, pixels: []const u8, count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        _ = atlas.insert(width, height, pixels) orelse unreachable;
    }
    std.debug.assert(atlas.rows_active <= atlas.size);
}

fn benchAtlasInsertMixed(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(count > 0);
    std.debug.assert(count <= 1000);
    const bench_atlas = allocator.create(BenchAtlas) catch unreachable;
    defer allocator.destroy(bench_atlas);
    bench_atlas.init(allocator, .gpu_upload);
    defer bench_atlas.deinit();

    for (0..getWarmupIterations(count)) |_| {
        bench_atlas.reset();
        _ = insertMixedBatch(&bench_atlas.atlas, count);
    }
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < getMinSampleIterations(count)) {
        bench_atlas.reset();
        const start = time.Instant.now();
        _ = insertMixedBatch(&bench_atlas.atlas, count);
        const elapsed = time.Instant.now().since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }
    return atlasResult(name, count, total_time_ns, iterations, samples.computePercentiles(count));
}

fn insertMixedBatch(atlas: *Atlas, count: u32) u64 {
    const pixels = comptime generatePixelData(24, 28);
    var area: u64 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const variant: u32 = index % 3;
        const glyph_width: u32 = 8 + variant * 8;
        const glyph_height: u32 = 12 + variant * 8;
        _ = atlas.insert(glyph_width, glyph_height, &pixels) orelse unreachable;
        area += glyph_width * glyph_height;
    }
    std.debug.assert(atlas.rows_active > 0);
    return area;
}

fn benchAtlasEvict(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime count: u32,
) BenchmarkResult {
    const glyph_width: u32 = 30;
    const glyph_height: u32 = 30;
    const shelf_count = bench_atlas_size / 32;
    const per_shelf = bench_atlas_size / 32;
    comptime std.debug.assert(count <= shelf_count);
    const bench_atlas = allocator.create(BenchAtlas) catch unreachable;
    defer allocator.destroy(bench_atlas);
    bench_atlas.init(allocator, .gpu_upload);
    defer bench_atlas.deinit();
    const pixel_data = comptime generatePixelData(glyph_width, glyph_height);

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < getMinSampleIterations(count)) {
        bench_atlas.reset();
        insertUniformBatch(
            &bench_atlas.atlas,
            glyph_width,
            glyph_height,
            &pixel_data,
            shelf_count * per_shelf,
        );
        std.debug.assert(bench_atlas.atlas.rows_active == bench_atlas_size);
        bench_atlas.nextFrame();
        const start = time.Instant.now();
        insertUniformBatch(
            &bench_atlas.atlas,
            bench_atlas_size - 2,
            glyph_height,
            &pixel_data_wide,
            count,
        );
        const elapsed = time.Instant.now().since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }
    return atlasResult(name, count, total_time_ns, iterations, samples.computePercentiles(count));
}

const pixel_data_wide: [(bench_atlas_size - 2) * 30]u8 = @splat(0x80);

fn atlasResult(
    comptime name: []const u8,
    count: u32,
    total_time_ns: u64,
    iterations: u32,
    percentiles: anytype,
) BenchmarkResult {
    std.debug.assert(count > 0);
    std.debug.assert(iterations > 0);
    return .{
        .name = name,
        .operation_count = count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

fn benchShapeCold(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(bench_text.len <= 512);

    const warmup_iters = getWarmupIterations(1);
    const min_iters = getMinSampleIterations(1);
    const allocator = text_sys.run_allocator;

    for (0..warmup_iters) |_| {
        text_sys.shape_cache.clear();
        var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
        run.deinit(allocator);
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        text_sys.shape_cache.clear();

        const start = time.Instant.now();
        var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

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
    const allocator = text_sys.run_allocator;

    {
        var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
        run.deinit(allocator);
    }

    for (0..warmup_iters) |_| {
        for (0..count) |_| {
            var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
            run.deinit(allocator);
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = time.Instant.now();
        for (0..count) |_| {
            var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
            last_width = run.width;
            run.deinit(allocator);
        }
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

fn benchShapeWarmArena(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(count > 0);

    const gpa = text_sys.run_allocator;
    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    {
        var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
        run.deinit(gpa);
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    for (0..warmup_iters) |_| {
        text_sys.run_allocator = arena_alloc;
        for (0..count) |_| {
            var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
            run.deinit(arena_alloc);
        }
        text_sys.run_allocator = gpa;
        _ = arena.reset(.retain_capacity);
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        text_sys.run_allocator = arena_alloc;
        const start = time.Instant.now();
        for (0..count) |_| {
            var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
            last_width = run.width;
            run.deinit(arena_alloc);
        }
        const end = time.Instant.now();
        text_sys.run_allocator = gpa;

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

fn benchShapeWarmInto(
    text_sys: *TextSystem,
    comptime name: []const u8,
    bench_text: []const u8,
    comptime count: u32,
) BenchmarkResult {
    std.debug.assert(bench_text.len > 0);
    std.debug.assert(count > 0);

    const allocator = text_sys.run_allocator;
    const warmup_iters = getWarmupIterations(count);
    const min_iters = getMinSampleIterations(count);

    {
        var run = text_sys.shapeText(.app, bench_text, .regular, null) catch unreachable;
        run.deinit(allocator);
    }

    for (0..warmup_iters) |_| {
        for (0..count) |_| {
            var buf: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph = undefined;
            var run = text_sys.shapeTextInto(.app, bench_text, .regular, null, &buf) catch
                unreachable;
            if (run.owned) run.deinit(allocator);
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = time.Instant.now();
        for (0..count) |_| {
            var buf: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph = undefined;
            var run = text_sys.shapeTextInto(.app, bench_text, .regular, null, &buf) catch
                unreachable;
            last_width = run.width;
            if (run.owned) run.deinit(allocator);
        }
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

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

    for (0..warmup_iters) |_| {
        for (0..count) |_| {
            _ = text_sys.measureText(.app, bench_text, .regular) catch unreachable;
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_width: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = time.Instant.now();
        for (0..count) |_| {
            last_width = text_sys.measureText(.app, bench_text, .regular) catch unreachable;
        }
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

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

    for (0..warmup_iters) |_| {
        for (0..count) |_| {
            _ = text_sys.measureTextEx(.app, bench_text, .regular, max_width) catch unreachable;
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_line_count: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = time.Instant.now();
        for (0..count) |_| {
            const measurement = text_sys.measureTextEx(.app, bench_text, .regular, max_width) catch
                unreachable;
            last_line_count = measurement.line_count;
        }
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

const bench_frame_key: usize = 1;

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

    for (0..3) |_| {
        _ = text_sys.cache.grayscale_atlas.uploads.beginFrame(bench_frame_key);
        text_sys.cache.clear();
        for (glyph_ids) |glyph_id| {
            _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        _ = text_sys.cache.grayscale_atlas.uploads.beginFrame(bench_frame_key);
        text_sys.cache.clear();

        const start = time.Instant.now();
        for (glyph_ids) |glyph_id| {
            const cached = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
            last_advance_x = cached.advance_x;
        }
        const end = time.Instant.now();

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    std.debug.assert(last_advance_x >= 0);
    std.debug.assert(iterations >= min_iters);
    const percentiles = samples.computePercentiles(glyph_count);

    return .{
        .name = name,
        .operation_count = glyph_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

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

    for (glyph_ids) |glyph_id| {
        _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
    }

    for (0..3) |_| {
        for (0..repetitions) |_| {
            for (glyph_ids) |glyph_id| {
                _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
            }
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = time.Instant.now();
        for (0..repetitions) |_| {
            for (glyph_ids) |glyph_id| {
                const cached = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
                std.mem.doNotOptimizeAway(cached);
                last_advance_x = cached.advance_x;
            }
        }
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

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

    for (0..BENCH_SUBPIXEL_VARIANTS) |sx| {
        for (glyph_ids) |glyph_id| {
            _ = text_sys.getGlyphSubpixel(glyph_id, font_size, @intCast(sx), 0) catch unreachable;
        }
    }

    for (0..3) |_| {
        for (0..repetitions) |_| {
            for (0..BENCH_SUBPIXEL_VARIANTS) |sx| {
                for (glyph_ids) |glyph_id| {
                    _ = text_sys.getGlyphSubpixel(glyph_id, font_size, @intCast(sx), 0) catch unreachable;
                }
            }
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = time.Instant.now();
        for (0..repetitions) |_| {
            for (0..BENCH_SUBPIXEL_VARIANTS) |sx| {
                for (glyph_ids) |glyph_id| {
                    const cached = text_sys.getGlyphSubpixel(glyph_id, font_size, @intCast(sx), 0) catch unreachable;
                    std.mem.doNotOptimizeAway(cached);
                    last_advance_x = cached.advance_x;
                }
            }
        }
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

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

    for (glyph_ids) |glyph_id| {
        _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
    }

    for (0..3) |_| {
        for (0..repetitions) |_| {
            for (shaped_glyphs[0..glyph_count]) |glyph| {
                _ = text_sys.getGlyphSubpixel(glyph.glyph_id, font_size, 0, 0) catch unreachable;
            }
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = time.Instant.now();
        for (0..repetitions) |_| {
            for (shaped_glyphs[0..glyph_count]) |glyph| {
                const cached = text_sys.getGlyphSubpixel(glyph.glyph_id, font_size, 0, 0) catch unreachable;
                std.mem.doNotOptimizeAway(cached);
                last_advance_x = cached.advance_x;
            }
        }
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

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

    for (glyph_ids) |glyph_id| {
        _ = text_sys.getGlyphSubpixel(glyph_id, font_size, 0, 0) catch unreachable;
    }

    for (0..3) |_| {
        for (0..repetitions) |_| {
            text_sys.resolveGlyphBatch(
                .app,
                shaped_glyphs[0..glyph_count],
                .regular,
                font_size,
                subpixel_xs[0..glyph_count],
                out_cached[0..glyph_count],
            ) catch unreachable;
        }
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();
    var last_advance_x: f32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iters) {
        const start = time.Instant.now();
        for (0..repetitions) |_| {
            text_sys.resolveGlyphBatch(
                .app,
                shaped_glyphs[0..glyph_count],
                .regular,
                font_size,
                subpixel_xs[0..glyph_count],
                out_cached[0..glyph_count],
            ) catch unreachable;
        }
        const end = time.Instant.now();

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
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
    };
}

test "validate: atlas insert fills shelves without eviction" {
    const allocator = std.testing.allocator;
    const bench_atlas = try allocator.create(BenchAtlas);
    defer allocator.destroy(bench_atlas);
    bench_atlas.init(allocator, .cpu_texture);
    defer bench_atlas.deinit();

    const pixel_data = comptime generatePixelData(8, 12);
    insertUniformBatch(&bench_atlas.atlas, 8, 12, &pixel_data, 100);
    try std.testing.expectEqual(@as(u32, 16), bench_atlas.atlas.rows_active);
    try std.testing.expectEqual(@as(u8, pixel_data[0]), bench_atlas.atlas.getData()[1024 + 1]);
}

test "validate: atlas mixed insert and reset round-trip" {
    const allocator = std.testing.allocator;
    const bench_atlas = try allocator.create(BenchAtlas);
    defer allocator.destroy(bench_atlas);
    bench_atlas.init(allocator, .gpu_upload);
    defer bench_atlas.deinit();

    const area = insertMixedBatch(&bench_atlas.atlas, 99);
    try std.testing.expectEqual(@as(u64, 33 * (8 * 12 + 16 * 20 + 24 * 28)), area);
    bench_atlas.reset();
    try std.testing.expectEqual(@as(u32, 0), bench_atlas.atlas.rows_active);
}

test "validate: generatePixelData produces non-zero output" {
    const data = comptime generatePixelData(8, 12);
    var nonzero_count: u32 = 0;
    for (data) |byte| {
        if (byte > 0) nonzero_count += 1;
    }
    try std.testing.expect(nonzero_count > 0);
}

test "validate: IterationSamples computes correct percentiles" {
    var samples = IterationSamples.init();
    for (0..100) |i| {
        samples.record((@as(u64, i) + 1) * 1000);
    }
    try std.testing.expectEqual(@as(u32, 100), samples.count);

    const p = samples.computePercentiles(1);
    try std.testing.expectApproxEqAbs(@as(f64, 50000.0), p.p50_per_op_ns, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 99000.0), p.p99_per_op_ns, 1.0);
}

test "validate: IterationSamples single sample returns same for p50 and p99" {
    var samples = IterationSamples.init();
    samples.record(42000);
    try std.testing.expectEqual(@as(u32, 1), samples.count);

    const p = samples.computePercentiles(1);
    try std.testing.expectApproxEqAbs(@as(f64, 42000.0), p.p50_per_op_ns, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 42000.0), p.p99_per_op_ns, 1.0);
}

test "validate: IterationSamples divides by operation count" {
    var samples = IterationSamples.init();
    samples.record(10000);
    samples.record(20000);
    samples.record(30000);

    const p = samples.computePercentiles(10);
    try std.testing.expectApproxEqAbs(@as(f64, 2000.0), p.p50_per_op_ns, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 2000.0), p.p99_per_op_ns, 1.0);
}

fn createTestTextSystem(allocator: std.mem.Allocator) ?*TextSystem {
    const ts = allocator.create(TextSystem) catch return null;
    const uploads = allocator.create(text.AtlasUploads) catch {
        allocator.destroy(ts);
        return null;
    };
    uploads.initHeadless(allocator, std.testing.io) catch {
        allocator.destroy(uploads);
        allocator.destroy(ts);
        return null;
    };

    ts.initInPlace(allocator, 1.0, std.testing.io, &bench_text_limits, .{
        .size = 1024,
        .uploads = uploads,
    }) catch {
        uploads.deinit();
        allocator.destroy(uploads);
        allocator.destroy(ts);
        return null;
    };

    ts.loadSystemFont(.monospace, BENCH_FONT_SIZE) catch {
        destroyTestTextSystem(allocator, ts);
        return null;
    };

    std.debug.assert(ts.getMetrics() != null);
    std.debug.assert(ts.scale_factor == 1.0);

    return ts;
}

fn destroyTestTextSystem(allocator: std.mem.Allocator, ts: *TextSystem) void {
    std.debug.assert(ts.scale_factor > 0);
    std.debug.assert(ts.scale_factor <= 4.0);
    const uploads = ts.cache.grayscale_atlas.uploads;
    ts.deinit();
    allocator.destroy(ts);
    uploads.deinit();
    allocator.destroy(uploads);
}

test "validate: text shaping produces glyphs" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    var run = ts.shapeText(.app, "Hello", .regular, null) catch return;
    defer run.deinit(allocator);

    try std.testing.expect(run.glyphs.len > 0);
    try std.testing.expect(run.width > 0);
}

test "validate: text shaping warm path returns consistent width" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    var run_first = ts.shapeText(.app, TEXT_SHORT, .regular, null) catch return;
    const first_width = run_first.width;
    run_first.deinit(allocator);

    var run_second = ts.shapeText(.app, TEXT_SHORT, .regular, null) catch return;
    defer run_second.deinit(allocator);

    try std.testing.expectApproxEqAbs(first_width, run_second.width, 0.01);
    try std.testing.expect(run_second.width > 0);
}

test "validate: shapeTextInto warm path returns owned=false with correct glyphs" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    var prime = ts.shapeText(.app, TEXT_SHORT, .regular, null) catch return;
    const expected_width = prime.width;
    const expected_count = prime.glyphs.len;
    prime.deinit(allocator);

    var buf: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph = undefined;
    var into_run = ts.shapeTextInto(.app, TEXT_SHORT, .regular, null, &buf) catch return;
    defer if (into_run.owned) into_run.deinit(allocator);

    try std.testing.expect(!into_run.owned);
    try std.testing.expectEqual(expected_count, into_run.glyphs.len);
    try std.testing.expectApproxEqAbs(expected_width, into_run.width, 0.001);

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

    const width = ts.measureText(.app, TEXT_SHORT, .regular) catch return;
    try std.testing.expect(width > 0);
    try std.testing.expect(width < 10000);
}

test "validate: text measurement with wrapping produces multiple lines" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    const measurement = ts.measureTextEx(.app, TEXT_MEDIUM, .regular, 50.0) catch return;
    try std.testing.expect(measurement.line_count >= 1);
    try std.testing.expect(measurement.width > 0);
}

test "validate: glyph rasterization produces cached glyph" {
    const allocator = std.testing.allocator;
    const ts = createTestTextSystem(allocator) orelse return;
    defer destroyTestTextSystem(allocator, ts);

    var run = ts.shapeText(.app, "A", .regular, null) catch return;
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

    var run = ts.shapeText(.app, "Hello", .regular, null) catch return;
    defer run.deinit(allocator);

    if (run.glyphs.len == 0) return;
    std.debug.assert(run.glyphs.len <= MAX_UNIQUE_GLYPHS);

    const glyph_count = run.glyphs.len;

    var per_glyph: [MAX_UNIQUE_GLYPHS]CachedGlyph = undefined;
    for (run.glyphs, 0..) |glyph, i| {
        per_glyph[i] = ts.getGlyphSubpixel(glyph.glyph_id, BENCH_FONT_SIZE, 0, 0) catch return;
    }

    var subpixel_xs: [MAX_UNIQUE_GLYPHS]u8 = @splat(0);
    var batch: [MAX_UNIQUE_GLYPHS]CachedGlyph = undefined;
    ts.resolveGlyphBatch(
        .app,
        run.glyphs,
        .regular,
        BENCH_FONT_SIZE,
        subpixel_xs[0..glyph_count],
        batch[0..glyph_count],
    ) catch return;

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

test "validate: extractUniqueGlyphIds deduplicates correctly" {
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
    for (1..ascii.len) |i| {
        try std.testing.expect(ascii[i] == ascii[i - 1] + 1);
    }
}

fn collect(reporter: *bench.Reporter, result: BenchmarkResult) void {
    reporter.addEntry(bench.entryWithPercentiles(
        result.name,
        result.operation_count,
        result.total_time_ns,
        result.iterations,
        result.min_per_op_ns,
        result.p50_per_op_ns,
        result.p99_per_op_ns,
    ));
    result.print();
    reporter.beginBenchmark();
}

fn printSectionHeader(title: []const u8) void {
    std.debug.assert(title.len > 0);
    std.debug.assert(title.len < TABLE_WIDTH);
    std.debug.print("\n", .{});
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("{s}\n", .{title});
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('-')) ++ "\n", .{});
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

fn runAtlasBenchmarks(gpa: std.mem.Allocator, reporter: *bench.Reporter) void {
    comptime std.debug.assert(bench_atlas_size == 1024);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Atlas Insert (shelf placement)");
    collect(reporter, benchAtlasInsert(gpa, "insert_8x12_x100", .gpu_upload, 8, 12, 100));
    collect(reporter, benchAtlasInsert(gpa, "insert_16x20_x100", .gpu_upload, 16, 20, 100));
    collect(reporter, benchAtlasInsertMixed(gpa, "insert_mixed_x100", 100));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});

    printSectionHeader("Gooey Text Benchmarks \u{2014} Atlas Insert + Pixels (CPU texture)");
    collect(reporter, benchAtlasInsert(gpa, "insert_pixels_8x12_x100", .cpu_texture, 8, 12, 100));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});

    printSectionHeader("Gooey Text Benchmarks \u{2014} Atlas Evict (insert into a full atlas)");
    collect(reporter, benchAtlasEvict(gpa, "evict_full_x16", 16));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});

    printSectionHeader("Gooey Text Benchmarks \u{2014} Atlas Insert Scaling (8x12, varying count)");
    collect(reporter, benchAtlasInsert(gpa, "scaling_insert_x50", .gpu_upload, 8, 12, 50));
    collect(reporter, benchAtlasInsert(gpa, "scaling_insert_x100", .gpu_upload, 8, 12, 100));
    collect(reporter, benchAtlasInsert(gpa, "scaling_insert_x200", .gpu_upload, 8, 12, 200));
    collect(reporter, benchAtlasInsert(gpa, "scaling_insert_x400", .gpu_upload, 8, 12, 400));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});

    printAtlasUtilization(gpa);
    printAtlasNotes();
}

fn printAtlasUtilization(gpa: std.mem.Allocator) void {
    const bench_atlas = gpa.create(BenchAtlas) catch unreachable;
    defer gpa.destroy(bench_atlas);
    bench_atlas.init(gpa, .gpu_upload);
    defer bench_atlas.deinit();

    const area = insertMixedBatch(&bench_atlas.atlas, 900);
    const shelf_area: u64 = @as(u64, bench_atlas.atlas.rows_active) * bench_atlas_size;
    const utilization = @as(f64, @floatFromInt(area)) / @as(f64, @floatFromInt(shelf_area)) * 100.0;
    std.debug.print("\n  Atlas utilization (900 mixed glyphs, {d}x{d} atlas):\n", .{
        bench_atlas_size, bench_atlas_size,
    });
    std.debug.print("    {d} rows held; glyph area {d} / shelf area {d} px = {d:>5.1}% fill\n", .{
        bench_atlas.atlas.rows_active, area, shelf_area, utilization,
    });
}

fn printAtlasNotes() void {
    std.debug.print(
        \\
        \\Notes:
        \\  - Insert = shelf placement; with no renderer registered nothing is staged.
        \\  - Insert + Pixels = placement plus the bordered pixel write of the CPU renderer.
        \\  - Evict = insert into a full atlas: an LRU scan and a shelf eviction per insert.
        \\  - Scaling: ns/op should stay flat as the shelf table fills.
        \\  - Utilization: glyph pixel area / area of the shelves holding it.
        \\  - p50/p99 show per-iteration percentiles (tail latency for frame budgets).
        \\  - All atlas benchmarks use the `.standard` 1024x1024 grayscale glyph atlas.
        \\  - Iterations are adaptive: at least 50 ms wall-clock or minimum sample count.
        \\
    , .{});
}

fn printShapingBenchmarks(text_sys: *TextSystem, reporter: *bench.Reporter) void {
    std.debug.assert(text_sys.getMetrics() != null);
    std.debug.assert(text_sys.scale_factor > 0);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Text Shaping (cold = cache miss, warm = cache hit)");
    collect(reporter, benchShapeCold(text_sys, "shape_cold_short_13ch", TEXT_SHORT));
    collect(reporter, benchShapeCold(text_sys, "shape_cold_medium_50ch", TEXT_MEDIUM));
    collect(reporter, benchShapeCold(text_sys, "shape_cold_long_104ch", TEXT_LONG));
    collect(reporter, benchShapeWarm(text_sys, "shape_warm_short_13ch_x100", TEXT_SHORT, 100));
    collect(reporter, benchShapeWarm(text_sys, "shape_warm_medium_50ch_x100", TEXT_MEDIUM, 100));
    collect(reporter, benchShapeWarm(text_sys, "shape_warm_long_104ch_x100", TEXT_LONG, 100));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('-')) ++ "\n", .{});
    collect(reporter, benchShapeWarmArena(text_sys, "shape_warm_arena_short_13ch_x100", TEXT_SHORT, 100));
    collect(reporter, benchShapeWarmArena(text_sys, "shape_warm_arena_medium_50ch_x100", TEXT_MEDIUM, 100));
    collect(reporter, benchShapeWarmArena(text_sys, "shape_warm_arena_long_104ch_x100", TEXT_LONG, 100));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('-')) ++ "\n", .{});
    collect(reporter, benchShapeWarmInto(text_sys, "shape_warm_into_short_13ch_x100", TEXT_SHORT, 100));
    collect(reporter, benchShapeWarmInto(text_sys, "shape_warm_into_medium_50ch_x100", TEXT_MEDIUM, 100));
    collect(reporter, benchShapeWarmInto(text_sys, "shape_warm_into_long_104ch_x100", TEXT_LONG, 100));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
}

fn printMeasurementBenchmarks(text_sys: *TextSystem, reporter: *bench.Reporter) void {
    std.debug.assert(text_sys.getMetrics() != null);
    std.debug.assert(text_sys.scale_factor > 0);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Text Measurement (measureText + measureTextEx)");
    collect(reporter, benchMeasureText(text_sys, "measure_short_13ch_x100", TEXT_SHORT, 100));
    collect(reporter, benchMeasureText(text_sys, "measure_medium_50ch_x100", TEXT_MEDIUM, 100));
    collect(reporter, benchMeasureText(text_sys, "measure_long_104ch_x100", TEXT_LONG, 100));
    collect(reporter, benchMeasureTextWrapped(text_sys, "measure_wrapped_50ch_200px_x100", TEXT_MEDIUM, 200.0, 100));
    collect(reporter, benchMeasureTextWrapped(text_sys, "measure_wrapped_104ch_300px_x100", TEXT_LONG, 300.0, 100));

    std.debug.assert(ShapedRunCache.MAX_GLYPHS_PER_ENTRY == 128);
    std.debug.assert(ShapedRunCache.MAX_TEXT_LEN >= 129);
    collect(reporter, benchMeasureText(text_sys, "measure_at_shape_limit_128ch_x100", SCALING_TEXT_BASE[0..128], 100));
    collect(reporter, benchMeasureText(text_sys, "measure_over_shape_limit_129ch_x100", SCALING_TEXT_BASE[0..129], 100));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
}

fn printGlyphBenchmarks(text_sys: *TextSystem, glyph_ids: []const u16, reporter: *bench.Reporter) void {
    std.debug.assert(glyph_ids.len > 0);
    std.debug.assert(text_sys.getMetrics() != null);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Glyph Rasterization (cold = render, warm = cache hit)");
    collect(reporter, benchGlyphRasterCold(text_sys, "glyph_raster_cold_ascii", glyph_ids, BENCH_FONT_SIZE));
    collect(reporter, benchGlyphRasterWarm(text_sys, "glyph_raster_warm_ascii_x20", glyph_ids, BENCH_FONT_SIZE, 20));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('-')) ++ "\n", .{});
    collect(reporter, benchGlyphRasterWarmPerGlyph(text_sys, "glyph_warm_perglyph_ascii_x20", glyph_ids, BENCH_FONT_SIZE, 20));
    collect(reporter, benchGlyphRasterWarmBatch(text_sys, "glyph_warm_batch_ascii_x20", glyph_ids, BENCH_FONT_SIZE, 20));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('-')) ++ "\n", .{});
    collect(reporter, benchGlyphRasterWarmSubpixel(text_sys, "glyph_warm_subpixel_ascii_x5", glyph_ids, BENCH_FONT_SIZE, 5));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
}

fn printScalingBenchmarks(text_sys: *TextSystem, reporter: *bench.Reporter) void {
    std.debug.assert(text_sys.getMetrics() != null);
    std.debug.assert(SCALING_TEXT_BASE.len >= 200);

    printSectionHeader("Gooey Text Benchmarks \u{2014} Shaping Scaling (cold shape at varying text length)");
    collect(reporter, benchShapeCold(text_sys, "scaling_shape_10ch", SCALING_TEXT_BASE[0..10]));
    collect(reporter, benchShapeCold(text_sys, "scaling_shape_25ch", SCALING_TEXT_BASE[0..25]));
    collect(reporter, benchShapeCold(text_sys, "scaling_shape_50ch", SCALING_TEXT_BASE[0..50]));
    collect(reporter, benchShapeCold(text_sys, "scaling_shape_100ch", SCALING_TEXT_BASE[0..100]));
    collect(reporter, benchShapeCold(text_sys, "scaling_shape_200ch", SCALING_TEXT_BASE[0..200]));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
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
        \\    This is the pattern placeText uses for zero-alloc warm-path rendering.
        \\  - Measure = measureText() which calls shapeText() internally.
        \\  - Measure wrapped = measureTextEx() with max_width constraint (line-breaking).
        \\  - Glyph cold = clear glyph cache, then rasterize all printable ASCII glyphs.
        \\  - Glyph warm = all glyphs pre-cached, pure hash table lookups (subpixel_x=0).
        \\    Iterates a compact u16 glyph ID array (best-case memory layout).
        \\  - Glyph warm per-glyph = same as warm, but iterates ShapedGlyph structs (44 bytes
        \\    each) with per-glyph mutex lock/unlock.  Matches placeText's real data layout.
        \\  - Glyph warm batch = same data layout as per-glyph, but all lookups under one
        \\    mutex lock via resolveGlyphBatch().  Compare per-glyph vs batch to isolate
        \\    the cost of N-1 redundant lock/unlock pairs.
        \\  - Glyph warm subpixel = warm lookups across all 4 horizontal subpixel X offsets.
        \\    Exercises the full cache working set that real rendering produces.
        \\    If ns/op is higher than warm, subpixel diversity is causing capacity pressure.
        \\  - Scaling = cold shaping at increasing text lengths to reveal linear vs super-linear cost.
        \\    Time/Op = ns per shape call.  Divide by character count for ns/char.
        \\  - Cold benchmarks report op_count = 1 (single shape per iteration, many iterations).
        \\  - Warm benchmarks amortize over many operations per iteration for stable timing.
        \\  - p50/p99 columns show per-operation percentiles derived from per-iteration samples.
        \\
    , .{});
}

fn runTextPipelineBenchmarks(gpa: std.mem.Allocator, reporter: *bench.Reporter) !void {
    reporter.pauseBenchmark();

    const text_sys = try gpa.create(TextSystem);
    defer gpa.destroy(text_sys);

    var uploads: text.AtlasUploads = undefined;
    try uploads.initHeadless(gpa, reporter.io);
    defer uploads.deinit();
    try text_sys.initInPlace(gpa, 1.0, reporter.io, &bench_text_limits, .{
        .size = 1024,
        .uploads = &uploads,
    });
    defer text_sys.deinit();

    try text_sys.loadSystemFont(.monospace, BENCH_FONT_SIZE);
    reporter.beginBenchmark();

    printShapingBenchmarks(text_sys, reporter);

    printMeasurementBenchmarks(text_sys, reporter);

    reporter.pauseBenchmark();
    const printable_ascii = comptime generatePrintableAscii();
    var ascii_run = try text_sys.shapeText(.app, &printable_ascii, .regular, null);

    std.debug.assert(ascii_run.glyphs.len > 0);
    const unique_glyphs = extractUniqueGlyphIds(ascii_run.glyphs);
    ascii_run.deinit(gpa);

    std.debug.print("\n  (Extracted {d} unique glyph IDs from {d} printable ASCII characters)\n", .{
        unique_glyphs.count,
        printable_ascii.len,
    });
    reporter.beginBenchmark();
    printGlyphBenchmarks(text_sys, unique_glyphs.ids[0..unique_glyphs.count], reporter);

    printScalingBenchmarks(text_sys, reporter);

    printTextPipelineNotes();
}

pub fn main(init: std.process.Init) !void {
    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var reporter = bench.Reporter.init("text", init.io, init.minimal.args.vector);

    runAtlasBenchmarks(gpa, &reporter);

    runTextPipelineBenchmarks(gpa, &reporter) catch |err| {
        std.debug.print(
            "\nSkipping text pipeline benchmarks: {s}\n" ++
                "  (Font loading or TextSystem init failed — expected on headless CI.)\n",
            .{@errorName(err)},
        );
    };

    reporter.finish();
}
