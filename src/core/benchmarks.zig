//! Core Module Benchmarks
//!
//! Benchmark suite for triangulation, stroke expansion, FixedArray, Vec2,
//! geometry, and ElementId hot paths.  Measures the performance-critical
//! operations that run during path rendering every frame.
//!
//! Run as executable: zig build bench-core
//! Quick tests only:  zig build test (validates outputs, doesn't time)
//!
//! Scenarios:
//!   - Triangulation: convex polygons (8–512 vertices), concave stars
//!   - Stroke expansion: varying point counts and cap/join styles
//!   - Stroke to triangles: direct GPU-ready output path
//!   - FixedArray: append/clear, pop, orderedRemove, swapRemove
//!   - Vec2: batch normalize, batch dot product
//!   - Rect.contains: batch containment testing
//!   - ElementId: hash throughput and equality comparison

const std = @import("std");
const gooey = @import("gooey");

const core = gooey.core;
const Vec2 = core.Vec2;
const IndexSlice = core.IndexSlice;
const Triangulator = core.Triangulator;
const FixedArray = core.FixedArray;
const RectF = core.RectF;
const PointF = core.PointF;
const ElementId = core.ElementId;
const limits = core.limits;

const stroke_mod = core.stroke;
const LineCap = stroke_mod.LineCap;
const LineJoin = stroke_mod.LineJoin;

const MAX_PATH_VERTICES = limits.MAX_PATH_VERTICES;
const MAX_STROKE_INPUT = limits.MAX_STROKE_INPUT;

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

// =============================================================================
// Benchmark Results
// =============================================================================

const BenchmarkResult = struct {
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,

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
            "| {s:<44} | {d:>8} | {d:>10.4} ms | {d:>10.2} ns/op | {d:>6} iters |\n",
            .{ self.name, self.operation_count, self.avgTimeMs(), self.timePerOpNs(), self.iterations },
        );
    }
};

// =============================================================================
// Data Types
// =============================================================================

/// Pre-generated polygon vertex data for triangulation benchmarks.
const PolygonData = struct {
    points: [MAX_PATH_VERTICES]Vec2 = undefined,
    vertex_count: u32 = 0,
};

/// Pre-generated polyline data for stroke benchmarks.
const StrokeData = struct {
    points: [MAX_STROKE_INPUT]Vec2 = undefined,
    point_count: u32 = 0,
};

// =============================================================================
// Polygon Generators
// =============================================================================

/// Regular convex N-gon on a circle of radius 90 centered at (100, 100).
/// CCW winding for consistent triangulator behavior.
fn generateConvexPolygon(comptime vertex_count: u32) PolygonData {
    comptime {
        std.debug.assert(vertex_count >= 3);
        std.debug.assert(vertex_count <= MAX_PATH_VERTICES);
    }

    var data = PolygonData{};
    data.vertex_count = vertex_count;

    const tau: f32 = 2.0 * std.math.pi;
    const step: f32 = tau / @as(f32, @floatFromInt(vertex_count));

    for (0..vertex_count) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * step;
        data.points[i] = Vec2{
            .x = 100.0 + 90.0 * std.math.cos(angle),
            .y = 100.0 + 90.0 * std.math.sin(angle),
        };
    }
    return data;
}

/// Star polygon with N outer points and N inner points (2N vertices total).
/// Alternates between outer radius 90 and inner radius 40.
/// Concave shape — stresses reflex vertex tracking in ear-clipper.
fn generateStarPolygon(comptime point_count: u32) PolygonData {
    comptime {
        std.debug.assert(point_count >= 3);
        std.debug.assert(point_count * 2 <= MAX_PATH_VERTICES);
    }

    const vertex_count: u32 = point_count * 2;
    var data = PolygonData{};
    data.vertex_count = vertex_count;

    const tau: f32 = 2.0 * std.math.pi;
    const step: f32 = tau / @as(f32, @floatFromInt(vertex_count));
    const outer_radius: f32 = 90.0;
    const inner_radius: f32 = 40.0;

    for (0..vertex_count) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * step;
        const radius: f32 = if (i % 2 == 0) outer_radius else inner_radius;
        data.points[i] = Vec2{
            .x = 100.0 + radius * std.math.cos(angle),
            .y = 100.0 + radius * std.math.sin(angle),
        };
    }
    return data;
}

// =============================================================================
// Stroke Path Generators
// =============================================================================

/// Zigzag path — alternates between y=10 and y=60 with uniform x spacing.
/// Sharp corners stress miter/bevel join logic.
fn generateZigzagPath(comptime point_count: u32) StrokeData {
    comptime {
        std.debug.assert(point_count >= 2);
        std.debug.assert(point_count <= MAX_STROKE_INPUT);
    }

    var data = StrokeData{};
    data.point_count = point_count;

    for (0..point_count) |i| {
        const x: f32 = @as(f32, @floatFromInt(i)) * 5.0;
        const y: f32 = if (i % 2 == 0) 10.0 else 60.0;
        data.points[i] = Vec2{ .x = x, .y = y };
    }
    return data;
}

/// Sine wave path — smooth curve with gradual direction changes.
/// Exercises round join logic without extreme miter angles.
fn generateSinePath(comptime point_count: u32) StrokeData {
    comptime {
        std.debug.assert(point_count >= 2);
        std.debug.assert(point_count <= MAX_STROKE_INPUT);
    }

    var data = StrokeData{};
    data.point_count = point_count;

    for (0..point_count) |i| {
        const fi: f32 = @as(f32, @floatFromInt(i));
        data.points[i] = Vec2{
            .x = fi * 5.0,
            .y = 50.0 + 40.0 * std.math.sin(fi * 0.3),
        };
    }
    return data;
}

/// Circle-approximation path — points on a circle, for closed stroke testing.
/// Uniform curvature exercises join logic at every vertex.
fn generateCirclePath(comptime point_count: u32) StrokeData {
    comptime {
        std.debug.assert(point_count >= 3);
        std.debug.assert(point_count <= MAX_STROKE_INPUT);
    }

    var data = StrokeData{};
    data.point_count = point_count;

    const tau: f32 = 2.0 * std.math.pi;
    const step: f32 = tau / @as(f32, @floatFromInt(point_count));

    for (0..point_count) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * step;
        data.points[i] = Vec2{
            .x = 100.0 + 80.0 * std.math.cos(angle),
            .y = 100.0 + 80.0 * std.math.sin(angle),
        };
    }
    return data;
}

// =============================================================================
// Benchmark Runners — Triangulation
// =============================================================================

/// Benchmark ear-clip triangulation: measures reset + triangulate.
/// Operation count = vertex count (cost scales with polygon complexity).
fn benchTriangulate(
    comptime name: []const u8,
    comptime generateFn: fn () PolygonData,
) BenchmarkResult {
    const data = generateFn();
    std.debug.assert(data.vertex_count >= 3);
    std.debug.assert(data.vertex_count <= MAX_PATH_VERTICES);

    const polygon_vertices = data.points[0..data.vertex_count];
    const polygon = IndexSlice{ .start = 0, .end = data.vertex_count };
    const operation_count = data.vertex_count;

    var triangulator = Triangulator.init();

    // Warmup.
    const warmup_count = getWarmupIterations(operation_count);
    for (0..warmup_count) |_| {
        triangulator.reset();
        _ = triangulator.triangulate(polygon_vertices, polygon) catch unreachable;
    }

    // Timed sampling.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var last_index_count: usize = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        triangulator.reset();
        const start = std.time.Instant.now() catch unreachable;
        const indices = triangulator.triangulate(polygon_vertices, polygon) catch unreachable;
        const end = std.time.Instant.now() catch unreachable;
        last_index_count = indices.len;
        total_time_ns += end.since(start);
        iterations += 1;
    }

    // Result must be consumed to prevent dead-code elimination.
    std.debug.assert(last_index_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

// =============================================================================
// Benchmark Runners — Stroke Expansion
// =============================================================================

/// Benchmark stroke expansion to polygon outline.
/// Operation count = input point count.
fn benchStrokeExpand(
    comptime name: []const u8,
    comptime generateFn: fn () StrokeData,
    comptime cap: LineCap,
    comptime join: LineJoin,
    comptime closed: bool,
) BenchmarkResult {
    const data = generateFn();
    std.debug.assert(data.point_count >= 2);
    std.debug.assert(data.point_count <= MAX_STROKE_INPUT);

    const path_points = data.points[0..data.point_count];
    const operation_count = data.point_count;
    const stroke_width: f32 = 2.0;
    const miter_limit: f32 = 4.0;

    // Warmup.
    const warmup_count = getWarmupIterations(operation_count);
    for (0..warmup_count) |_| {
        _ = stroke_mod.expandStroke(path_points, stroke_width, cap, join, miter_limit, closed) catch unreachable;
    }

    // Timed sampling.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var last_output_count: usize = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        const start = std.time.Instant.now() catch unreachable;
        const result = stroke_mod.expandStroke(path_points, stroke_width, cap, join, miter_limit, closed) catch unreachable;
        const end = std.time.Instant.now() catch unreachable;
        last_output_count = result.points.len;
        total_time_ns += end.since(start);
        iterations += 1;
    }

    std.debug.assert(last_output_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

/// Benchmark direct stroke-to-triangles path (bypasses ear-clipper).
/// Operation count = input point count.
fn benchStrokeToTriangles(
    comptime name: []const u8,
    comptime generateFn: fn () StrokeData,
    comptime cap: LineCap,
    comptime join: LineJoin,
    comptime closed: bool,
) BenchmarkResult {
    const data = generateFn();
    std.debug.assert(data.point_count >= 2);
    std.debug.assert(data.point_count <= MAX_STROKE_INPUT);

    const path_points = data.points[0..data.point_count];
    const operation_count = data.point_count;
    const stroke_width: f32 = 2.0;
    const miter_limit: f32 = 4.0;

    // Warmup.
    const warmup_count = getWarmupIterations(operation_count);
    for (0..warmup_count) |_| {
        _ = stroke_mod.expandStrokeToTriangles(path_points, stroke_width, cap, join, miter_limit, closed) catch unreachable;
    }

    // Timed sampling.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var last_triangle_count: usize = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        const start = std.time.Instant.now() catch unreachable;
        const result = stroke_mod.expandStrokeToTriangles(path_points, stroke_width, cap, join, miter_limit, closed) catch unreachable;
        const end = std.time.Instant.now() catch unreachable;
        last_triangle_count = result.indices.len / 3;
        total_time_ns += end.since(start);
        iterations += 1;
    }

    std.debug.assert(last_triangle_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

// =============================================================================
// Benchmark Runners — FixedArray
// =============================================================================

/// Benchmark append N items then clear.
/// Measures raw append throughput.  Operation count = item_count.
fn benchFixedArrayAppendClear(
    comptime name: []const u8,
    comptime item_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(item_count > 0);
        std.debug.assert(item_count <= 8192);
    }

    const operation_count = item_count;
    const warmup_count = getWarmupIterations(operation_count);

    // Warmup.
    for (0..warmup_count) |_| {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        array.clear();
    }

    // Timed sampling.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        var array: FixedArray(u32, 8192) = .{};
        const start = std.time.Instant.now() catch unreachable;
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        // Treat the entire populated slice as externally observable.
        // This prevents LLVM from folding the sequential stores into a
        // computed final state — every element must be materialised.
        std.mem.doNotOptimizeAway(array.constSlice());
        array.clear();
        const end = std.time.Instant.now() catch unreachable;
        std.debug.assert(array.len == 0);
        total_time_ns += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

/// Benchmark pop all items from a pre-filled array.
/// Measures LIFO removal throughput (O(1) per pop).  Operation count = item_count.
fn benchFixedArrayPopCycle(
    comptime name: []const u8,
    comptime item_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(item_count > 0);
        std.debug.assert(item_count <= 8192);
    }

    const operation_count = item_count;
    const warmup_count = getWarmupIterations(operation_count);

    // Warmup.
    for (0..warmup_count) |_| {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        for (0..item_count) |_| {
            _ = array.pop();
        }
    }

    // Timed sampling: fill outside timing window, pop inside.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        // Make array contents opaque so LLVM cannot predict pop return values
        // and fold the loop into an arithmetic identity (sum = N*(N-1)/2).
        std.mem.doNotOptimizeAway(array.constSlice());

        var pop_sink: u32 = 0;
        const start = std.time.Instant.now() catch unreachable;
        for (0..item_count) |_| {
            pop_sink +%= array.pop();
        }
        const end = std.time.Instant.now() catch unreachable;
        // Sink must be observable per-iteration to prevent cross-iteration folding.
        std.mem.doNotOptimizeAway(pop_sink);
        std.debug.assert(array.len == 0);
        total_time_ns += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

/// Benchmark swapRemove from index 0 on a pre-filled array.
/// Each swapRemove is O(1).  Operation count = item_count.
fn benchFixedArraySwapRemove(
    comptime name: []const u8,
    comptime item_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(item_count > 0);
        std.debug.assert(item_count <= 8192);
    }

    const operation_count = item_count;
    const warmup_count = getWarmupIterations(operation_count);

    // Warmup.
    for (0..warmup_count) |_| {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        for (0..item_count) |_| {
            _ = array.swapRemove(0);
        }
    }

    // Timed sampling: fill outside timing window, remove inside.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        const start = std.time.Instant.now() catch unreachable;
        for (0..item_count) |_| {
            _ = array.swapRemove(0);
        }
        const end = std.time.Instant.now() catch unreachable;
        std.debug.assert(array.len == 0);
        total_time_ns += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

/// Benchmark orderedRemove from index 0 on a pre-filled array.
/// Each orderedRemove is O(n) due to element shifting — exposes quadratic total cost.
/// Operation count = item_count.
fn benchFixedArrayOrderedRemove(
    comptime name: []const u8,
    comptime item_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(item_count > 0);
        std.debug.assert(item_count <= 8192);
    }

    const operation_count = item_count;
    const warmup_count = getWarmupIterations(operation_count);

    // Warmup.
    for (0..warmup_count) |_| {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        for (0..item_count) |_| {
            _ = array.orderedRemove(0);
        }
    }

    // Timed sampling: fill outside timing window, remove inside.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        const start = std.time.Instant.now() catch unreachable;
        for (0..item_count) |_| {
            _ = array.orderedRemove(0);
        }
        const end = std.time.Instant.now() catch unreachable;
        std.debug.assert(array.len == 0);
        total_time_ns += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

// =============================================================================
// Benchmark Runners — Vec2
// =============================================================================

/// Benchmark batch Vec2 normalize.
/// Each iteration normalizes vector_count vectors.  Operation count = vector_count.
fn benchVec2Normalize(
    comptime name: []const u8,
    comptime vector_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(vector_count > 0);
        std.debug.assert(vector_count <= 4096);
    }

    // Generate non-degenerate test vectors.
    var vectors: [vector_count]Vec2 = undefined;
    for (0..vector_count) |i| {
        const fi: f32 = @as(f32, @floatFromInt(i)) + 1.0;
        vectors[i] = Vec2{ .x = fi, .y = fi * 0.7 + 0.5 };
    }

    const operation_count = vector_count;
    const warmup_count = getWarmupIterations(operation_count);

    // Warmup — accumulate into sink to prevent dead-code elimination.
    var sink = Vec2.zero;
    for (0..warmup_count) |_| {
        for (0..vector_count) |i| {
            sink = sink.add(vectors[i].normalize());
        }
    }

    // Timed sampling.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..vector_count) |i| {
            sink = sink.add(vectors[i].normalize());
        }
        const end = std.time.Instant.now() catch unreachable;
        total_time_ns += end.since(start);
        iterations += 1;
    }

    // Accumulated length must be finite (ensures work was not optimized away).
    std.debug.assert(sink.lengthSq() >= 0);
    std.debug.assert(!std.math.isNan(sink.x));

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

// =============================================================================
// Benchmark Runners — Geometry
// =============================================================================

/// Benchmark batch Rect.contains point testing.
/// Points oscillate in and out of the rect to defeat branch prediction.
/// Operation count = point_count.
fn benchRectContains(
    comptime name: []const u8,
    comptime point_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(point_count > 0);
        std.debug.assert(point_count <= 4096);
    }

    const rect = RectF.init(10.0, 10.0, 100.0, 100.0);

    // Generate points that oscillate across the rect boundary.
    var test_points: [point_count]PointF = undefined;
    for (0..point_count) |i| {
        const fi: f32 = @as(f32, @floatFromInt(i));
        test_points[i] = PointF.init(
            60.0 + 80.0 * std.math.sin(fi * 0.1),
            60.0 + 80.0 * std.math.cos(fi * 0.13),
        );
    }

    const operation_count = point_count;
    const warmup_count = getWarmupIterations(operation_count);

    // Warmup.
    var hit_count: u32 = 0;
    for (0..warmup_count) |_| {
        for (0..point_count) |i| {
            if (rect.contains(test_points[i])) {
                hit_count += 1;
            }
        }
    }

    // Timed sampling.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..point_count) |i| {
            if (rect.contains(test_points[i])) {
                hit_count += 1;
            }
        }
        const end = std.time.Instant.now() catch unreachable;
        total_time_ns += end.since(start);
        iterations += 1;
    }

    // Hit count must be non-zero (some points are inside the rect).
    std.debug.assert(hit_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

// =============================================================================
// Benchmark Runners — ElementId
// =============================================================================

/// Static pool of element names for hash benchmarks.
const element_names = [_][]const u8{
    "button_ok",      "button_cancel",  "sidebar_left",  "header_main",
    "footer_nav",     "modal_dialog",   "input_email",   "label_name",
    "checkbox_terms", "radio_option_a", "slider_volume", "dropdown_menu",
    "tab_home",       "tab_settings",   "tab_profile",   "tab_messages",
};

/// Benchmark ElementId named hashing throughput.
/// Hashes hash_count names drawn round-robin from the name pool.
/// Operation count = hash_count.
fn benchElementIdHash(
    comptime name: []const u8,
    comptime hash_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(hash_count > 0);
        std.debug.assert(element_names.len > 0);
    }

    const operation_count = hash_count;
    const warmup_count = getWarmupIterations(operation_count);

    // Warmup.
    var hash_sink: u64 = 0;
    for (0..warmup_count) |_| {
        for (0..hash_count) |i| {
            const element_id = ElementId.named(element_names[i % element_names.len]);
            hash_sink +%= element_id.hash();
        }
    }

    // Timed sampling.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..hash_count) |i| {
            const element_id = ElementId.named(element_names[i % element_names.len]);
            hash_sink +%= element_id.hash();
        }
        const end = std.time.Instant.now() catch unreachable;
        total_time_ns += end.since(start);
        iterations += 1;
    }

    // Hash sink must have accumulated values.
    std.debug.assert(hash_sink != 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

/// Benchmark ElementId equality comparison throughput.
/// Compares comparison_count pairs of IDs (alternating equal and unequal).
/// Operation count = comparison_count.
fn benchElementIdEquality(
    comptime name: []const u8,
    comptime comparison_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(comparison_count > 0);
        std.debug.assert(element_names.len >= 2);
    }

    const operation_count = comparison_count;
    const warmup_count = getWarmupIterations(operation_count);

    // Pre-build ID pairs.
    var ids_a: [comparison_count]ElementId = undefined;
    var ids_b: [comparison_count]ElementId = undefined;
    for (0..comparison_count) |i| {
        ids_a[i] = ElementId.named(element_names[i % element_names.len]);
        // Even indices: same name (equal).  Odd indices: next name (unequal).
        const b_index = if (i % 2 == 0) i else i + 1;
        ids_b[i] = ElementId.named(element_names[b_index % element_names.len]);
    }

    // Warmup.
    var match_count: u32 = 0;
    for (0..warmup_count) |_| {
        for (0..comparison_count) |i| {
            if (ids_a[i].eql(ids_b[i])) {
                match_count += 1;
            }
        }
    }

    // Timed sampling.
    const min_iterations = getMinSampleIterations(operation_count);
    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_iterations) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..comparison_count) |i| {
            if (ids_a[i].eql(ids_b[i])) {
                match_count += 1;
            }
        }
        const end = std.time.Instant.now() catch unreachable;
        total_time_ns += end.since(start);
        iterations += 1;
    }

    // Some comparisons must have matched (even indices are equal).
    std.debug.assert(match_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
}

// =============================================================================
// Comptime Wrappers — Polygon Generators
// =============================================================================

fn buildConvex8() PolygonData {
    return generateConvexPolygon(8);
}
fn buildConvex16() PolygonData {
    return generateConvexPolygon(16);
}
fn buildConvex32() PolygonData {
    return generateConvexPolygon(32);
}
fn buildConvex64() PolygonData {
    return generateConvexPolygon(64);
}
fn buildConvex128() PolygonData {
    return generateConvexPolygon(128);
}
fn buildConvex256() PolygonData {
    return generateConvexPolygon(256);
}
fn buildConvex512() PolygonData {
    return generateConvexPolygon(512);
}

fn buildStar5() PolygonData {
    return generateStarPolygon(5);
}
fn buildStar10() PolygonData {
    return generateStarPolygon(10);
}
fn buildStar50() PolygonData {
    return generateStarPolygon(50);
}
fn buildStar100() PolygonData {
    return generateStarPolygon(100);
}

// =============================================================================
// Comptime Wrappers — Stroke Path Generators
// =============================================================================

fn buildZigzag4() StrokeData {
    return generateZigzagPath(4);
}
fn buildZigzag32() StrokeData {
    return generateZigzagPath(32);
}
fn buildZigzag128() StrokeData {
    return generateZigzagPath(128);
}
fn buildZigzag256() StrokeData {
    return generateZigzagPath(256);
}
fn buildSine64() StrokeData {
    return generateSinePath(64);
}
fn buildCircle32() StrokeData {
    return generateCirclePath(32);
}
fn buildCircle64() StrokeData {
    return generateCirclePath(64);
}

// =============================================================================
// Validation Tests
// =============================================================================

/// Assert that triangulation produces the correct number of triangles.
fn validateTriangulation(comptime generateFn: fn () PolygonData) !void {
    const data = generateFn();
    std.debug.assert(data.vertex_count >= 3);

    const polygon_vertices = data.points[0..data.vertex_count];
    const polygon = IndexSlice{ .start = 0, .end = data.vertex_count };

    var triangulator = Triangulator.init();
    const indices = try triangulator.triangulate(polygon_vertices, polygon);

    // N-vertex simple polygon always produces exactly (N - 2) triangles.
    const expected_triangles = data.vertex_count - 2;
    const expected_indices = expected_triangles * 3;
    try std.testing.expectEqual(expected_indices, @as(u32, @intCast(indices.len)));
}

test "validate: convex_8 triangulation" {
    try validateTriangulation(buildConvex8);
}

test "validate: convex_32 triangulation" {
    try validateTriangulation(buildConvex32);
}

test "validate: convex_128 triangulation" {
    try validateTriangulation(buildConvex128);
}

test "validate: convex_512 triangulation" {
    try validateTriangulation(buildConvex512);
}

test "validate: star_5 triangulation" {
    try validateTriangulation(buildStar5);
}

test "validate: star_50 triangulation" {
    try validateTriangulation(buildStar50);
}

test "validate: star_100 triangulation" {
    try validateTriangulation(buildStar100);
}

test "validate: stroke expand produces output" {
    const data = generateZigzagPath(32);
    const path_points = data.points[0..data.point_count];
    const result = try stroke_mod.expandStroke(path_points, 2.0, .butt, .miter, 4.0, false);
    try std.testing.expect(result.points.len > 0);
}

test "validate: stroke to triangles produces output" {
    const data = generateZigzagPath(32);
    const path_points = data.points[0..data.point_count];
    const result = try stroke_mod.expandStrokeToTriangles(path_points, 2.0, .butt, .miter, 4.0, false);
    try std.testing.expect(result.vertices.len > 0);
    try std.testing.expect(result.indices.len > 0);
    // Index count must be a multiple of 3 (triangles).
    try std.testing.expectEqual(@as(usize, 0), result.indices.len % 3);
}

test "validate: FixedArray append and clear" {
    var array: FixedArray(u32, 64) = .{};
    for (0..64) |i| {
        array.appendAssumeCapacity(@intCast(i));
    }
    try std.testing.expectEqual(@as(usize, 64), array.len);
    array.clear();
    try std.testing.expectEqual(@as(usize, 0), array.len);
}

test "validate: FixedArray swapRemove vs orderedRemove" {
    // swapRemove does NOT preserve order.
    var swap_arr: FixedArray(u32, 8) = .{};
    swap_arr.appendAssumeCapacity(10);
    swap_arr.appendAssumeCapacity(20);
    swap_arr.appendAssumeCapacity(30);
    _ = swap_arr.swapRemove(0); // 30 moves to index 0.
    try std.testing.expectEqual(@as(u32, 30), swap_arr.get(0));

    // orderedRemove preserves order.
    var ord_arr: FixedArray(u32, 8) = .{};
    ord_arr.appendAssumeCapacity(10);
    ord_arr.appendAssumeCapacity(20);
    ord_arr.appendAssumeCapacity(30);
    _ = ord_arr.orderedRemove(0); // 20 shifts to index 0.
    try std.testing.expectEqual(@as(u32, 20), ord_arr.get(0));
}

test "validate: Vec2 normalize produces unit length" {
    const v = Vec2{ .x = 3.0, .y = 4.0 };
    const n = v.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), n.length(), 1e-6);
}

test "validate: Rect.contains boundary behavior" {
    const rect = RectF.init(10.0, 10.0, 100.0, 100.0);
    // Inside.
    try std.testing.expect(rect.contains(PointF.init(50.0, 50.0)));
    // Outside.
    try std.testing.expect(!rect.contains(PointF.init(0.0, 0.0)));
    try std.testing.expect(!rect.contains(PointF.init(200.0, 200.0)));
}

test "validate: ElementId hash determinism" {
    const id_a = ElementId.named("button_ok");
    const id_b = ElementId.named("button_ok");
    try std.testing.expectEqual(id_a.hash(), id_b.hash());
    try std.testing.expect(id_a.eql(id_b));
}

// =============================================================================
// Main Entry Point (for benchmark executable)
// =============================================================================

pub fn main() !void {

    // =========================================================================
    // Triangulation — Convex Polygons
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Triangulation (convex polygons, ear-clip)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchTriangulate("convex_8", buildConvex8).print();
    benchTriangulate("convex_32", buildConvex32).print();
    benchTriangulate("convex_64", buildConvex64).print();
    benchTriangulate("convex_128", buildConvex128).print();
    benchTriangulate("convex_256", buildConvex256).print();
    benchTriangulate("convex_512", buildConvex512).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Triangulation — Concave Stars
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Triangulation (concave star polygons)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchTriangulate("star_5 (10 verts)", buildStar5).print();
    benchTriangulate("star_10 (20 verts)", buildStar10).print();
    benchTriangulate("star_50 (100 verts)", buildStar50).print();
    benchTriangulate("star_100 (200 verts)", buildStar100).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Stroke Expansion — Open Path Scaling
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Stroke Expansion (open, butt cap, miter join)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchStrokeExpand("zigzag_4_butt_miter", buildZigzag4, .butt, .miter, false).print();
    benchStrokeExpand("zigzag_32_butt_miter", buildZigzag32, .butt, .miter, false).print();
    benchStrokeExpand("zigzag_128_butt_miter", buildZigzag128, .butt, .miter, false).print();
    benchStrokeExpand("zigzag_256_butt_miter", buildZigzag256, .butt, .miter, false).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Stroke Expansion — Style Comparison (32 points)
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Stroke Style Comparison (zigzag 32 points)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchStrokeExpand("zigzag_32_butt_miter", buildZigzag32, .butt, .miter, false).print();
    benchStrokeExpand("zigzag_32_round_round", buildZigzag32, .round, .round, false).print();
    benchStrokeExpand("zigzag_32_square_bevel", buildZigzag32, .square, .bevel, false).print();

    std.debug.print("-" ** 105 ++ "\n", .{});

    benchStrokeExpand("sine_64_butt_miter", buildSine64, .butt, .miter, false).print();
    benchStrokeExpand("sine_64_round_round", buildSine64, .round, .round, false).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Stroke Expansion — Closed Paths
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Stroke Expansion (closed paths)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchStrokeExpand("circle_32_closed_miter", buildCircle32, .butt, .miter, true).print();
    benchStrokeExpand("circle_64_closed_miter", buildCircle64, .butt, .miter, true).print();
    benchStrokeExpand("circle_32_closed_round", buildCircle32, .butt, .round, true).print();
    benchStrokeExpand("circle_64_closed_round", buildCircle64, .butt, .round, true).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Stroke To Triangles (direct GPU output)
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Stroke To Triangles (bypasses ear-clipper)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchStrokeToTriangles("zigzag_32_tri_butt_miter", buildZigzag32, .butt, .miter, false).print();
    benchStrokeToTriangles("zigzag_128_tri_butt_miter", buildZigzag128, .butt, .miter, false).print();
    benchStrokeToTriangles("circle_32_tri_closed", buildCircle32, .butt, .miter, true).print();
    benchStrokeToTriangles("circle_64_tri_closed", buildCircle64, .butt, .miter, true).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // FixedArray — Append/Clear Throughput
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — FixedArray Append/Clear\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchFixedArrayAppendClear("append_clear_100", 100).print();
    benchFixedArrayAppendClear("append_clear_1000", 1000).print();
    benchFixedArrayAppendClear("append_clear_4000", 4000).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // FixedArray — Removal Strategy Comparison
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — FixedArray Removal Strategies (O(1) vs O(n))\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    // O(1) removal: pop from end.
    benchFixedArrayPopCycle("pop_100", 100).print();
    benchFixedArrayPopCycle("pop_1000", 1000).print();

    std.debug.print("-" ** 105 ++ "\n", .{});

    // O(1) removal: swap with last element.
    benchFixedArraySwapRemove("swap_remove_100", 100).print();
    benchFixedArraySwapRemove("swap_remove_1000", 1000).print();

    std.debug.print("-" ** 105 ++ "\n", .{});

    // O(n) removal: shift all elements left. ns/op should grow with N.
    benchFixedArrayOrderedRemove("ordered_remove_100", 100).print();
    benchFixedArrayOrderedRemove("ordered_remove_500", 500).print();
    benchFixedArrayOrderedRemove("ordered_remove_1000", 1000).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Vec2 — Batch Normalize
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Vec2 Batch Normalize\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchVec2Normalize("normalize_100", 100).print();
    benchVec2Normalize("normalize_1000", 1000).print();
    benchVec2Normalize("normalize_4000", 4000).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Rect.contains — Batch Containment
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Rect.contains Batch Containment\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchRectContains("contains_100", 100).print();
    benchRectContains("contains_1000", 1000).print();
    benchRectContains("contains_4000", 4000).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // ElementId — Hash + Equality
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — ElementId Hash + Equality\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    benchElementIdHash("hash_100", 100).print();
    benchElementIdHash("hash_1000", 1000).print();
    benchElementIdHash("hash_4000", 4000).print();

    std.debug.print("-" ** 105 ++ "\n", .{});

    benchElementIdEquality("equality_100", 100).print();
    benchElementIdEquality("equality_1000", 1000).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Scaling Analysis — Triangulation
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Scaling Analysis (triangulate ns/op vs vertex count)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    // Ear-clipping is O(n²): ns/op should grow linearly with vertex count.
    // Reflex-set optimization reduces constant factor for convex polygons.
    benchTriangulate("scaling_convex_8", buildConvex8).print();
    benchTriangulate("scaling_convex_16", buildConvex16).print();
    benchTriangulate("scaling_convex_32", buildConvex32).print();
    benchTriangulate("scaling_convex_64", buildConvex64).print();
    benchTriangulate("scaling_convex_128", buildConvex128).print();
    benchTriangulate("scaling_convex_256", buildConvex256).print();
    benchTriangulate("scaling_convex_512", buildConvex512).print();

    std.debug.print("-" ** 105 ++ "\n", .{});

    // Stars are concave — more reflex vertices mean more work per ear test.
    benchTriangulate("scaling_star_5", buildStar5).print();
    benchTriangulate("scaling_star_10", buildStar10).print();
    benchTriangulate("scaling_star_50", buildStar50).print();
    benchTriangulate("scaling_star_100", buildStar100).print();

    std.debug.print("=" ** 105 ++ "\n", .{});

    std.debug.print(
        \\
        \\Notes:
        \\  - Triangulation = reset() + triangulate() via ear-clipping. O(n * r) where r = reflex count.
        \\  - Stroke Expand = expandStroke() producing a polygon outline for the ear-clipper.
        \\  - Stroke To Triangles = expandStrokeToTriangles() producing GPU-ready indices directly.
        \\  - FixedArray: append/clear measures write throughput; pop/swap are O(1); orderedRemove is O(n).
        \\  - Vec2 Normalize = batch normalize with sqrt + division per vector.
        \\  - Rect.contains = four comparisons per point (branch-heavy).
        \\  - ElementId Hash = Wyhash over variable-length name strings.
        \\  - Scaling Analysis: if triangulate ns/op grows linearly, total cost is O(n²).
        \\    Convex polygons have zero reflex vertices — best case for ear-clipper.
        \\    Star polygons have ~N/2 reflex vertices — worst case for point-in-triangle checks.
        \\  - Iterations are adaptive based on operation count.
        \\
    , .{});
}

// =============================================================================
// Helpers
// =============================================================================

fn printHeader() void {
    std.debug.print("| {s:<44} | {s:>8} | {s:>13} | {s:>14} | {s:>10} |\n", .{
        "Test",
        "Ops",
        "Avg Time",
        "Time/Op",
        "Iters",
    });
}
