//! Scene Module Benchmarks
//!
//! Benchmark suite for the data-plane pipeline: the scene → batch → frame path
//! that actually feeds the GPU. The control-plane suites (`bench`, `bench-context`,
//! `bench-core`, `bench-text`) cover layout, the dispatch tree, geometry, and text
//! shaping; this suite measures what those produce per frame — the instances/vertices
//! emitted, how cleanly they batch, the draw-order sort, and the clip stack.
//!
//! Run as executable: zig build bench-scene
//! Quick tests only:  zig test src/scene/benchmarks.zig (validates counts + zero-alloc)
//!
//! Groups:
//!   - Scene build      — clear() + insertQuad/insertGlyph/insertShadow emission
//!   - Batch iteration  — BatchIterator.next() drain cost + batch count (coalescing)
//!   - Draw-order sort  — finish() pdq sort over an out-of-order quad array
//!   - Clip stack       — pushClip/popClip pairs at increasing nesting depth
//!   - Frame e2e        — clear → build → finish → drain, reported against the
//!                        16.6 ms (60 Hz) / 8.3 ms (120 Hz) frame budget with p99
//!
//! Why these: CLAUDE.md §7 ("how many vertices/texture uploads per frame?") and §8
//! ("batching is religion") call for measuring the data plane directly. The frame
//! group is the only number that answers "do we fit the frame budget?"; it reports
//! tail latency (p99), since GUI quality is frame-budget consistency, not throughput.
//!
//! Scope note: this measures the headless scene→batch portion of the frame. The
//! platform/GPU submission in `runtime/frame.zig` needs a live window, Metal device,
//! and CoreText stack, so it cannot run in a headless benchmark; the scene data plane
//! is the part that is both measurable here and the GPU-bandwidth proxy.

const std = @import("std");
const gooey = @import("gooey");
const bench = @import("bench");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Minimal `Instant.now()` / `.since()` shim over `std.Io.Clock.awake`, kept
/// local to the benchmark module so every sample site reads as a two-line
/// capture-then-diff instead of threading `io` through every benchmark
/// helper signature. `.awake` is the monotonic clock — deltas here can
/// never go negative regardless of NTP or sysadmin clock edits.
///
/// `std.Io` is a pair of pointers into a process-lifetime vtable, so the
/// per-call `global_single_threaded.io()` lookup compiles down to a pair
/// of constant pointer loads — effectively free.
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

const scene_mod = gooey.scene;
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const GlyphInstance = scene_mod.GlyphInstance;
const Shadow = scene_mod.Shadow;
const Hsla = scene_mod.Hsla;
const BatchIterator = scene_mod.BatchIterator;

const MAX_QUADS_PER_FRAME = scene_mod.MAX_QUADS_PER_FRAME;
const MAX_GLYPHS_PER_FRAME = scene_mod.MAX_GLYPHS_PER_FRAME;
const MAX_SHADOWS_PER_FRAME = scene_mod.MAX_SHADOWS_PER_FRAME;
const MAX_CLIP_STACK_DEPTH = scene_mod.MAX_CLIP_STACK_DEPTH;

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

/// Hard cap on batches drained from a single scene (CLAUDE.md §4: limit
/// everything). A scene can never produce more batches than primitives, and
/// the per-frame primitive caps sum to well under this; exceeding it means a
/// BatchIterator bug, so we fail fast rather than spin.
const MAX_DRAIN_BATCHES: u32 = 262_144;

/// Per-frame budgets in nanoseconds for the frame e2e summary.
const FRAME_BUDGET_60HZ_NS: f64 = 16_666_667.0;
const FRAME_BUDGET_120HZ_NS: f64 = 8_333_333.0;

/// Table width for benchmark output formatting (characters per row).
const TABLE_WIDTH = 104;

// =============================================================================
// Iteration Sample Collection and Percentile Computation
// =============================================================================

/// Per-iteration timing data for percentile analysis. Fixed capacity avoids
/// dynamic allocation during benchmark runs. Mirrors the text suite so both
/// percentile-reporting suites share one shape.
const IterationSamples = struct {
    times_ns: [MAX_SAMPLE_COUNT]u64,
    count: u32,

    fn init() IterationSamples {
        return .{ .times_ns = undefined, .count = 0 };
    }

    /// Record one iteration's elapsed time. Drops samples beyond capacity
    /// (the first MAX_SAMPLE_COUNT samples are sufficient for percentiles).
    fn record(self: *IterationSamples, elapsed_ns: u64) void {
        if (self.count < MAX_SAMPLE_COUNT) {
            self.times_ns[self.count] = elapsed_ns;
            self.count += 1;
        }
    }

    /// Sort collected samples and extract min/p50/p99 percentiles as ns/op.
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
            // The slice is sorted ascending, so slice[0] is the fastest sample (the min).
            .min_per_op_ns = @as(f64, @floatFromInt(slice[0])) / ops_f,
            .p50_per_op_ns = @as(f64, @floatFromInt(slice[p50_index])) / ops_f,
            .p99_per_op_ns = @as(f64, @floatFromInt(slice[p99_index])) / ops_f,
        };
    }
};

/// Percentile statistics computed from iteration samples.
const PercentileResult = struct {
    min_per_op_ns: f64,
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
    min_per_op_ns: f64,
    p50_per_op_ns: f64,
    p99_per_op_ns: f64,
    /// Number of draw-order batches the BatchIterator emitted for the scene.
    /// Zero for groups where batching is not exercised (build/sort/clip).
    batch_count: u32 = 0,

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
            @as(f64, @floatFromInt(self.operation_count * self.iterations));
        return avg_ns;
    }

    pub fn print(self: BenchmarkResult) void {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.operation_count > 0);
        // Batched groups show the batch count; non-batched groups show "-".
        if (self.batch_count > 0) {
            std.debug.print(
                "| {s:<40} | {d:>7} | {d:>9.2} | {d:>9.2} | {d:>9.2} | {d:>7} | {d:>6} |\n",
                .{ self.name, self.operation_count, self.timePerOpNs(), self.p50_per_op_ns, self.p99_per_op_ns, self.batch_count, self.iterations },
            );
        } else {
            std.debug.print(
                "| {s:<40} | {d:>7} | {d:>9.2} | {d:>9.2} | {d:>9.2} | {s:>7} | {d:>6} |\n",
                .{ self.name, self.operation_count, self.timePerOpNs(), self.p50_per_op_ns, self.p99_per_op_ns, "-", self.iterations },
            );
        }
    }

    /// Frame e2e summary line: total per-frame time (avg + p99) in microseconds
    /// and avg as a percentage of the 60 Hz and 120 Hz budgets. This is the
    /// "do we fit the budget?" number, so it is reported in whole-frame units.
    pub fn printFrameBudget(self: BenchmarkResult) void {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.operation_count > 0);
        const avg_ns: f64 = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        const p99_ns: f64 = self.p99_per_op_ns * @as(f64, @floatFromInt(self.operation_count));
        std.debug.print(
            "| {s:<28} | {d:>6} | {d:>5} | {d:>9.2} us | {d:>9.2} us | {d:>6.2}% | {d:>6.2}% |\n",
            .{
                self.name,
                self.operation_count,
                self.batch_count,
                avg_ns / 1000.0,
                p99_ns / 1000.0,
                100.0 * avg_ns / FRAME_BUDGET_60HZ_NS,
                100.0 * avg_ns / FRAME_BUDGET_120HZ_NS,
            },
        );
    }
};

/// Assemble a result from the common runner outputs. Centralizes the invariant
/// checks so each runner ends with a single tail call.
fn makeResult(
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    percentiles: PercentileResult,
    batch_count: u32,
) BenchmarkResult {
    std.debug.assert(operation_count > 0);
    std.debug.assert(iterations > 0);
    std.debug.assert(batch_count <= operation_count);
    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .min_per_op_ns = percentiles.min_per_op_ns,
        .p50_per_op_ns = percentiles.p50_per_op_ns,
        .p99_per_op_ns = percentiles.p99_per_op_ns,
        .batch_count = batch_count,
    };
}

// =============================================================================
// Scene Builders
//
// Each builder populates a freshly-cleared scene and returns the primitive
// count it emitted. They use only quads/glyphs/shadows (no paths/meshes) so the
// data plane is exercised without pulling in mesh-pool allocation — keeping the
// frame group on the static-allocation fast path (CLAUDE.md §2).
// =============================================================================

/// N filled quads in insertion order (auto-assigned ascending draw orders).
/// Coalesces into a single batch — the best case for the BatchIterator.
fn buildQuads(scene: *Scene, count: u32) Allocator.Error!u32 {
    std.debug.assert(count > 0);
    std.debug.assert(count <= MAX_QUADS_PER_FRAME);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        try scene.insertQuad(Quad.filled(fi * 2.0, fi * 1.5, 40.0, 24.0, Hsla.blue));
    }
    return count;
}

/// N glyphs in insertion order. Also a single coalesced batch.
fn buildGlyphs(scene: *Scene, count: u32) Allocator.Error!u32 {
    std.debug.assert(count > 0);
    std.debug.assert(count <= MAX_GLYPHS_PER_FRAME);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        try scene.insertGlyph(GlyphInstance.init(fi * 7.0, 100.0, 6.0, 12.0, 0.0, 0.0, 0.5, 0.5, Hsla.black));
    }
    return count;
}

/// Alternating quad/glyph emission — the worst case for batching: every
/// primitive sits between two of another type, so the iterator emits one batch
/// per primitive. Returns `pairs * 2` primitives.
fn buildInterleaved(scene: *Scene, pairs: u32) Allocator.Error!u32 {
    std.debug.assert(pairs > 0);
    std.debug.assert(pairs <= MAX_GLYPHS_PER_FRAME);
    std.debug.assert(pairs <= MAX_QUADS_PER_FRAME);

    var i: u32 = 0;
    while (i < pairs) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        try scene.insertQuad(Quad.filled(fi, fi, 10.0, 10.0, Hsla.red));
        try scene.insertGlyph(GlyphInstance.init(fi, fi, 6.0, 12.0, 0.0, 0.0, 0.5, 0.5, Hsla.black));
    }
    return pairs * 2;
}

/// A realistic "dashboard": a background, then a grid of cards, each a shadow +
/// rounded quad + a run of label glyphs. The per-panel glyph run coalesces into
/// one batch, so batch count grows with panels (mixed scene), not glyphs.
fn buildDashboard(scene: *Scene, panel_count: u32, glyphs_per_panel: u32) Allocator.Error!u32 {
    std.debug.assert(panel_count > 0);
    std.debug.assert(panel_count <= MAX_SHADOWS_PER_FRAME);
    std.debug.assert(glyphs_per_panel > 0);

    try scene.insertQuad(Quad.filled(0.0, 0.0, 1280.0, 800.0, Hsla.white));
    var count: u32 = 1;

    var p: u32 = 0;
    while (p < panel_count) : (p += 1) {
        const col: f32 = @floatFromInt(p % 4);
        const row: f32 = @floatFromInt(p / 4);
        const x = 16.0 + col * 312.0;
        const y = 16.0 + row * 120.0;

        const card = Quad.rounded(x, y, 296.0, 104.0, Hsla.blue, 8.0);
        try scene.insertShadow(Shadow.forQuad(card, 8.0));
        try scene.insertQuad(card);
        count += 2;

        var g: u32 = 0;
        while (g < glyphs_per_panel) : (g += 1) {
            const fg: f32 = @floatFromInt(g);
            try scene.insertGlyph(GlyphInstance.init(x + 12.0 + fg * 7.0, y + 16.0, 6.0, 12.0, 0.0, 0.0, 0.5, 0.5, Hsla.black));
            count += 1;
        }
    }

    std.debug.assert(count == 1 + panel_count * (2 + glyphs_per_panel));
    return count;
}

// Zero-argument wrappers so the runners can take a `comptime build_fn`.
fn buildQuads256(scene: *Scene) Allocator.Error!u32 {
    return buildQuads(scene, 256);
}
fn buildQuads2k(scene: *Scene) Allocator.Error!u32 {
    return buildQuads(scene, 2000);
}
fn buildQuads16k(scene: *Scene) Allocator.Error!u32 {
    return buildQuads(scene, 16000);
}
fn buildGlyphs2k(scene: *Scene) Allocator.Error!u32 {
    return buildGlyphs(scene, 2000);
}
fn buildGlyphs16k(scene: *Scene) Allocator.Error!u32 {
    return buildGlyphs(scene, 16000);
}
fn buildInterleaved2k(scene: *Scene) Allocator.Error!u32 {
    return buildInterleaved(scene, 2000);
}
fn buildDashboardSmall(scene: *Scene) Allocator.Error!u32 {
    return buildDashboard(scene, 12, 20);
}
fn buildDashboardMedium(scene: *Scene) Allocator.Error!u32 {
    return buildDashboard(scene, 48, 30);
}
fn buildDashboardLarge(scene: *Scene) Allocator.Error!u32 {
    return buildDashboard(scene, 120, 40);
}

// =============================================================================
// Batch Drain Helper
// =============================================================================

const DrainResult = struct {
    primitives: u64,
    batches: u32,
};

/// Drain a finished scene through the BatchIterator, returning the total
/// primitives and batch count. The returned `primitives` total is fed to
/// `doNotOptimizeAway` by timed callers so the drain is not elided.
fn drainScene(scene: *const Scene) DrainResult {
    var iterator = BatchIterator.init(scene);
    var primitives: u64 = 0;
    var batches: u32 = 0;

    while (iterator.next()) |batch| {
        primitives += batch.len();
        batches += 1;
        // Fail fast on a runaway iterator rather than spinning unbounded.
        if (batches >= MAX_DRAIN_BATCHES) unreachable;
    }

    std.debug.assert(iterator.done());
    return .{ .primitives = primitives, .batches = batches };
}

// =============================================================================
// Benchmark Runners
// =============================================================================

/// Scene build: time clear() + primitive emission together (both are per-frame
/// data-plane costs). Reports nanoseconds per emitted primitive.
fn benchSceneBuild(
    allocator: Allocator,
    comptime name: []const u8,
    comptime build_fn: fn (*Scene) Allocator.Error!u32,
) !BenchmarkResult {
    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    scene.clear();
    const operation_count = try build_fn(&scene);
    std.debug.assert(operation_count > 0);

    const warmup_iters = getWarmupIterations(operation_count);
    const min_sample_iters = getMinSampleIterations(operation_count);

    for (0..warmup_iters) |_| {
        scene.clear();
        _ = try build_fn(&scene);
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        scene.clear();
        const emitted = try build_fn(&scene);
        const end = time.Instant.now();
        std.debug.assert(emitted == operation_count);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(operation_count);
    return makeResult(name, operation_count, total_time_ns, iterations, percentiles, 0);
}

/// Batch iteration: build + finish once, then time draining the finished scene
/// through the BatchIterator. Reports ns per primitive drained and the batch
/// count (the coalescing measure from CLAUDE.md §8).
fn benchBatchIterate(
    allocator: Allocator,
    comptime name: []const u8,
    comptime build_fn: fn (*Scene) Allocator.Error!u32,
) !BenchmarkResult {
    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    scene.clear();
    const operation_count = try build_fn(&scene);
    scene.finish();
    std.debug.assert(operation_count > 0);

    // Batch count is a structural property of the scene — measure it once.
    const structure = drainScene(&scene);
    std.debug.assert(structure.primitives == operation_count);
    std.debug.assert(structure.batches > 0);
    const batch_count = structure.batches;

    const warmup_iters = getWarmupIterations(operation_count);
    const min_sample_iters = getMinSampleIterations(operation_count);

    for (0..warmup_iters) |_| {
        std.mem.doNotOptimizeAway(drainScene(&scene).primitives);
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        const drained = drainScene(&scene);
        const end = time.Instant.now();
        std.mem.doNotOptimizeAway(drained.primitives);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(operation_count);
    return makeResult(name, operation_count, total_time_ns, iterations, percentiles, batch_count);
}

/// Seed a scene with `count` quads whose draw orders are a deterministic
/// pseudo-random permutation, and snapshot that unsorted state into `out`. The
/// scene's quad array is left dirty so `finish()` must re-sort it.
///
/// We reach into `scene.quads.items` / `scene.needs_sort_quads` directly: there
/// is no public API to overwrite a quad's order in place, and the sort
/// microbench needs to restore the unsorted permutation each iteration without
/// paying the insertion cost. Acceptable coupling for a benchmark.
fn seedShuffledQuads(scene: *Scene, count: u32, out: []Quad) Allocator.Error!void {
    std.debug.assert(count > 1);
    std.debug.assert(out.len == count);

    scene.clear();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try scene.insertQuad(Quad.filled(0.0, 0.0, 1.0, 1.0, Hsla.white));
    }
    std.debug.assert(scene.quads.items.len == count);

    // xorshift32 gives a cheap, deterministic order permutation so pdq does
    // real O(n log n) work each iteration (not a reverse-sorted fast path).
    var rng: u32 = 0x9E3779B9;
    i = 0;
    while (i < count) : (i += 1) {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        out[i] = scene.quads.items[i];
        out[i].order = rng % count;
    }
    scene.needs_sort_quads = true;
}

/// Draw-order sort: time `finish()` over a quad array re-shuffled to the same
/// unsorted permutation each iteration. The memcpy restore is outside the timed
/// region, so only the pdq sort is measured. Reports ns per quad sorted.
fn benchDrawOrderSort(
    allocator: Allocator,
    comptime name: []const u8,
    count: u32,
) !BenchmarkResult {
    std.debug.assert(count > 1);
    std.debug.assert(count <= MAX_QUADS_PER_FRAME);

    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    const unsorted = try allocator.alloc(Quad, count);
    defer allocator.free(unsorted);

    try seedShuffledQuads(&scene, count, unsorted);
    const items = scene.quads.items;
    std.debug.assert(items.len == count);

    const warmup_iters = getWarmupIterations(count);
    const min_sample_iters = getMinSampleIterations(count);

    for (0..warmup_iters) |_| {
        @memcpy(items, unsorted);
        scene.needs_sort_quads = true;
        scene.finish();
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        @memcpy(items, unsorted); // restore unsorted permutation (untimed)
        scene.needs_sort_quads = true;

        const start = time.Instant.now();
        scene.finish();
        const end = time.Instant.now();
        std.debug.assert(scene.quads.items[0].order <= scene.quads.items[count - 1].order);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(count);
    return makeResult(name, count, total_time_ns, iterations, percentiles, 0);
}

/// Direct payload sort over the same shuffled quads: the pre-optimization
/// baseline that moves whole 128-byte `Quad` structs on every swap. Paired with
/// `benchDrawOrderSort` (the indirect key sort that `finish()` now uses) so
/// `bench-compare` can size the payload-move tax on this hardware — the concrete
/// before/after for Ericson's "sort keys, not payloads".
fn benchDrawOrderSortStruct(
    allocator: Allocator,
    comptime name: []const u8,
    count: u32,
) !BenchmarkResult {
    std.debug.assert(count > 1);
    std.debug.assert(count <= MAX_QUADS_PER_FRAME);

    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    const unsorted = try allocator.alloc(Quad, count);
    defer allocator.free(unsorted);

    try seedShuffledQuads(&scene, count, unsorted);
    const items = scene.quads.items;
    std.debug.assert(items.len == count);

    const warmup_iters = getWarmupIterations(count);
    const min_sample_iters = getMinSampleIterations(count);

    for (0..warmup_iters) |_| {
        @memcpy(items, unsorted);
        pdqQuadsByOrder(items);
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        @memcpy(items, unsorted); // restore unsorted permutation (untimed)

        const start = time.Instant.now();
        pdqQuadsByOrder(items);
        const end = time.Instant.now();
        std.debug.assert(items[0].order <= items[count - 1].order);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(count);
    return makeResult(name, count, total_time_ns, iterations, percentiles, 0);
}

/// The legacy sort: `std.sort.pdq` straight over the `Quad` payload array, so
/// every swap shuffles 128 bytes. Isolated here purely as the benchmark
/// baseline; production `finish()` no longer does this.
fn pdqQuadsByOrder(items: []Quad) void {
    std.sort.pdq(Quad, items, {}, struct {
        fn lessThan(_: void, a: Quad, b: Quad) bool {
            return a.order < b.order;
        }
    }.lessThan);
}

/// Clip stack: time `depth` pushClip calls (each intersecting the current clip)
/// followed by `depth` popClip calls. Reports ns per push/pop pair — the cost
/// of one nested clip level.
fn benchClipStack(
    allocator: Allocator,
    comptime name: []const u8,
    depth: u32,
) !BenchmarkResult {
    std.debug.assert(depth > 0);
    std.debug.assert(depth <= MAX_CLIP_STACK_DEPTH);

    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    const warmup_iters = getWarmupIterations(depth);
    const min_sample_iters = getMinSampleIterations(depth);

    for (0..warmup_iters) |_| {
        try pushPopClips(&scene, depth);
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        try pushPopClips(&scene, depth);
        const end = time.Instant.now();
        std.debug.assert(!scene.hasActiveClip());

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(depth);
    return makeResult(name, depth, total_time_ns, iterations, percentiles, 0);
}

/// Push `depth` nested clips (each shrinking inward so intersection does real
/// work) then pop them all. Leaves the clip stack empty.
fn pushPopClips(scene: *Scene, depth: u32) Allocator.Error!void {
    std.debug.assert(depth > 0);
    std.debug.assert(depth <= MAX_CLIP_STACK_DEPTH);

    var i: u32 = 0;
    while (i < depth) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        try scene.pushClip(.{ .x = fi, .y = fi, .width = 1000.0 - fi * 2.0, .height = 1000.0 - fi * 2.0 });
    }
    i = 0;
    while (i < depth) : (i += 1) {
        scene.popClip();
    }
}

/// Frame e2e: the full data-plane cycle — clear → build → finish → drain — the
/// only number that answers "do we fit the frame budget?". Reports ns per
/// primitive (gated) plus, via printFrameBudget, whole-frame avg/p99.
fn benchFrame(
    allocator: Allocator,
    comptime name: []const u8,
    comptime build_fn: fn (*Scene) Allocator.Error!u32,
) !BenchmarkResult {
    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    scene.clear();
    const operation_count = try build_fn(&scene);
    scene.finish();
    const batch_count = drainScene(&scene).batches;
    std.debug.assert(batch_count > 0);

    const warmup_iters = getWarmupIterations(operation_count);
    const min_sample_iters = getMinSampleIterations(operation_count);

    for (0..warmup_iters) |_| {
        scene.clear();
        _ = try build_fn(&scene);
        scene.finish();
        std.mem.doNotOptimizeAway(drainScene(&scene).primitives);
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        scene.clear();
        const emitted = try build_fn(&scene);
        scene.finish();
        const drained = drainScene(&scene);
        const end = time.Instant.now();
        std.debug.assert(emitted == operation_count);
        std.mem.doNotOptimizeAway(drained.primitives);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(operation_count);
    return makeResult(name, operation_count, total_time_ns, iterations, percentiles, batch_count);
}

// =============================================================================
// Counting Allocator (zero-allocation invariant check)
// =============================================================================

/// Wraps a backing allocator and counts every vtable call. After `initCapacity`
/// pre-allocates the scene's arrays, a steady-state frame must touch the heap
/// zero times (CLAUDE.md §2: zero dynamic allocation after init). This turns
/// that belief into a checkable fact in the validate tests below.
const CountingAllocator = struct {
    backing: Allocator,
    calls: u64 = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

// =============================================================================
// Validation Tests (run with `zig test src/scene/benchmarks.zig`)
//
// These do not time anything — they assert the builders emit the expected
// primitive counts, the BatchIterator drains exactly what was built, and the
// steady-state frame allocates nothing.
// =============================================================================

fn validateBuild(comptime build_fn: fn (*Scene) Allocator.Error!u32, expected: u32) !void {
    const allocator = std.testing.allocator;
    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    scene.clear();
    const emitted = try build_fn(&scene);
    try std.testing.expectEqual(expected, emitted);

    scene.finish();
    const drained = drainScene(&scene);
    try std.testing.expectEqual(@as(u64, expected), drained.primitives);
    try std.testing.expect(drained.batches > 0);
    try std.testing.expect(drained.batches <= emitted);
}

test "validate: build quads emits and drains expected count" {
    try validateBuild(buildQuads256, 256);
}

test "validate: build glyphs emits and drains expected count" {
    try validateBuild(buildGlyphs2k, 2000);
}

test "validate: interleaved build is the worst case for batching" {
    const allocator = std.testing.allocator;
    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    scene.clear();
    const emitted = try buildInterleaved(&scene, 100);
    try std.testing.expectEqual(@as(u32, 200), emitted);

    scene.finish();
    const drained = drainScene(&scene);
    // Alternating quad/glyph means every primitive is its own batch.
    try std.testing.expectEqual(@as(u32, 200), drained.batches);
}

test "validate: dashboard emits 1 + panels*(2 + glyphs)" {
    const allocator = std.testing.allocator;
    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    scene.clear();
    const emitted = try buildDashboard(&scene, 12, 20);
    try std.testing.expectEqual(@as(u32, 1 + 12 * (2 + 20)), emitted);
}

test "validate: finish sorts an out-of-order quad array ascending" {
    const allocator = std.testing.allocator;
    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    const count: u32 = 512;
    const unsorted = try allocator.alloc(Quad, count);
    defer allocator.free(unsorted);

    try seedShuffledQuads(&scene, count, unsorted);
    @memcpy(scene.quads.items, unsorted);
    scene.needs_sort_quads = true;
    scene.finish();

    // After finish, draw orders are non-decreasing.
    var i: u32 = 1;
    while (i < count) : (i += 1) {
        try std.testing.expect(scene.quads.items[i - 1].order <= scene.quads.items[i].order);
    }
}

test "validate: clip stack is balanced after push/pop" {
    const allocator = std.testing.allocator;
    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    try pushPopClips(&scene, MAX_CLIP_STACK_DEPTH);
    try std.testing.expect(!scene.hasActiveClip());
}

test "validate: steady-state frame performs zero heap allocations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counter = CountingAllocator{ .backing = gpa.allocator() };
    const allocator = counter.allocator();

    var scene = try Scene.initCapacity(allocator);
    defer scene.deinit();

    // Warm once so any lazy first-use allocation happens before we measure.
    scene.clear();
    _ = try buildDashboardSmall(&scene);
    scene.finish();
    _ = drainScene(&scene);

    const calls_before = counter.calls;

    // Steady state: clear retains capacity, inserts stay under the pre-allocated
    // caps, finish sorts in place, the iterator never allocates. Net heap: zero.
    var frame: u32 = 0;
    while (frame < 16) : (frame += 1) {
        scene.clear();
        _ = try buildDashboardSmall(&scene);
        scene.finish();
        std.mem.doNotOptimizeAway(drainScene(&scene).primitives);
    }

    try std.testing.expectEqual(calls_before, counter.calls);
}

// =============================================================================
// Main Entry Point (for benchmark executable)
// =============================================================================

/// Print a benchmark result and record it in the JSON reporter. Scene benchmarks
/// carry p50/p99 percentiles, so the entry uses the percentile constructor; the
/// regression gate still classifies on the min (best-of-N).
fn collect(reporter: *bench.Reporter, result: BenchmarkResult) void {
    result.print();
    reporter.addEntry(bench.entryWithPercentiles(
        result.name,
        result.operation_count,
        result.total_time_ns,
        result.iterations,
        result.min_per_op_ns,
        result.p50_per_op_ns,
        result.p99_per_op_ns,
    ));
}

/// Record a frame result in the reporter (no per-op table print — the frame
/// group prints its own whole-frame budget line via printFrameBudget).
fn collectFrame(reporter: *bench.Reporter, result: BenchmarkResult) void {
    result.printFrameBudget();
    reporter.addEntry(bench.entryWithPercentiles(
        result.name,
        result.operation_count,
        result.total_time_ns,
        result.iterations,
        result.min_per_op_ns,
        result.p50_per_op_ns,
        result.p99_per_op_ns,
    ));
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reporter = bench.Reporter.init("scene", init.io, init.minimal.args.vector);

    // =========================================================================
    // Scene Build
    // =========================================================================

    printSectionHeader("Gooey Scene Benchmarks — Scene Build (clear + primitive emission)");
    collect(&reporter, try benchSceneBuild(allocator, "build_quads_256", buildQuads256));
    collect(&reporter, try benchSceneBuild(allocator, "build_quads_2k", buildQuads2k));
    collect(&reporter, try benchSceneBuild(allocator, "build_quads_16k", buildQuads16k));
    collect(&reporter, try benchSceneBuild(allocator, "build_glyphs_2k", buildGlyphs2k));
    collect(&reporter, try benchSceneBuild(allocator, "build_glyphs_16k", buildGlyphs16k));
    collect(&reporter, try benchSceneBuild(allocator, "build_interleaved_2k", buildInterleaved2k));
    collect(&reporter, try benchSceneBuild(allocator, "build_dashboard_small", buildDashboardSmall));
    collect(&reporter, try benchSceneBuild(allocator, "build_dashboard_medium", buildDashboardMedium));
    collect(&reporter, try benchSceneBuild(allocator, "build_dashboard_large", buildDashboardLarge));
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    // =========================================================================
    // Batch Iteration
    // =========================================================================

    printSectionHeader("Gooey Scene Benchmarks — Batch Iteration (BatchIterator drain + coalescing)");
    collect(&reporter, try benchBatchIterate(allocator, "batch_quads_16k", buildQuads16k));
    collect(&reporter, try benchBatchIterate(allocator, "batch_glyphs_16k", buildGlyphs16k));
    collect(&reporter, try benchBatchIterate(allocator, "batch_interleaved_2k", buildInterleaved2k));
    collect(&reporter, try benchBatchIterate(allocator, "batch_dashboard_medium", buildDashboardMedium));
    collect(&reporter, try benchBatchIterate(allocator, "batch_dashboard_large", buildDashboardLarge));
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    // =========================================================================
    // Draw-Order Sort
    // =========================================================================

    printSectionHeader("Gooey Scene Benchmarks — Draw-Order Sort (finish() over shuffled quads)");
    // Indirect key sort (what finish() now does) vs. the legacy payload sort, on
    // identical shuffled inputs, so bench-compare can lock in the win.
    collect(&reporter, try benchDrawOrderSort(allocator, "sort_quads_1k", 1000));
    collect(&reporter, try benchDrawOrderSort(allocator, "sort_quads_8k", 8000));
    collect(&reporter, try benchDrawOrderSort(allocator, "sort_quads_32k", 32000));
    collect(&reporter, try benchDrawOrderSortStruct(allocator, "sort_struct_quads_1k", 1000));
    collect(&reporter, try benchDrawOrderSortStruct(allocator, "sort_struct_quads_8k", 8000));
    collect(&reporter, try benchDrawOrderSortStruct(allocator, "sort_struct_quads_32k", 32000));
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    // =========================================================================
    // Clip Stack
    // =========================================================================

    printSectionHeader("Gooey Scene Benchmarks — Clip Stack (pushClip/popClip pairs)");
    collect(&reporter, try benchClipStack(allocator, "clip_depth_8", 8));
    collect(&reporter, try benchClipStack(allocator, "clip_depth_16", 16));
    collect(&reporter, try benchClipStack(allocator, "clip_depth_32", 32));
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    // =========================================================================
    // Frame e2e (data plane)
    // =========================================================================

    printFrameHeader();
    collectFrame(&reporter, try benchFrame(allocator, "frame_dashboard_small", buildDashboardSmall));
    collectFrame(&reporter, try benchFrame(allocator, "frame_dashboard_medium", buildDashboardMedium));
    collectFrame(&reporter, try benchFrame(allocator, "frame_dashboard_large", buildDashboardLarge));
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});

    std.debug.print(
        \\
        \\Notes:
        \\  - Scene Build  = clear() + insertQuad/insertGlyph/insertShadow (per-frame emit).
        \\  - Batch Iter   = BatchIterator drain of a finished scene; Batches column is the
        \\                   coalescing measure (fewer = better; interleaved is worst case).
        \\  - Draw Sort    = finish() pdq sort over a shuffled quad array (overlay/z-order cost).
        \\  - Clip Stack   = pushClip (with intersection) + popClip pairs per nesting level.
        \\  - Frame e2e    = clear -> build -> finish -> drain; the data-plane frame budget.
        \\                   60Hz budget = 16.67 ms, 120Hz = 8.33 ms (avg % shown per frame).
        \\  - Frame e2e excludes platform/GPU submission (runtime/frame.zig needs a live
        \\    window + Metal + CoreText, so it cannot run headless).
        \\  - ns/op and percentiles are per primitive; iterations are adaptive.
        \\
    , .{});

    reporter.finish();
}

// =============================================================================
// Section Printers
// =============================================================================

fn printSectionHeader(comptime title: []const u8) void {
    comptime std.debug.assert(title.len > 0);
    comptime std.debug.assert(title.len < TABLE_WIDTH);
    std.debug.print("\n", .{});
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
    std.debug.print("{s}\n", .{title});
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** TABLE_WIDTH ++ "\n", .{});
}

fn printHeader() void {
    std.debug.print("| {s:<40} | {s:>7} | {s:>9} | {s:>9} | {s:>9} | {s:>7} | {s:>6} |\n", .{
        "Test",
        "Ops",
        "ns/op",
        "p50",
        "p99",
        "Batches",
        "Iters",
    });
}

fn printFrameHeader() void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
    std.debug.print("Gooey Scene Benchmarks — Frame e2e (clear -> build -> finish -> drain)\n", .{});
    std.debug.print("=" ** TABLE_WIDTH ++ "\n", .{});
    std.debug.print("| {s:<28} | {s:>6} | {s:>5} | {s:>12} | {s:>12} | {s:>6} | {s:>6} |\n", .{
        "Test",
        "Prims",
        "Batch",
        "Avg/frame",
        "p99/frame",
        "60Hz",
        "120Hz",
    });
    std.debug.print("-" ** TABLE_WIDTH ++ "\n", .{});
}
