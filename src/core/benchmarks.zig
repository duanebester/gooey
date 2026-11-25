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

const geometry = gooey.internals.geometry;
const Vec2 = geometry.Vec2;
const IndexSlice = geometry.IndexSlice;
const Triangulator = geometry.Triangulator;
const FixedArray = gooey.internals.fixed_array.FixedArray;
const RectF = geometry.RectF;
const PointF = geometry.PointF;
const limits = gooey.internals.limits;
const records = gooey.internals.records;
const pack_mod = gooey.internals.pack;
const packed_frame = gooey.internals.packed_frame;
const assert = std.debug.assert;

const stroke_mod = geometry.stroke;
const LineCap = stroke_mod.LineCap;
const LineJoin = stroke_mod.LineJoin;

const MAX_PATH_VERTICES = limits.MAX_PATH_VERTICES;
const MAX_STROKE_INPUT = limits.MAX_STROKE_INPUT;

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

const BenchmarkResult = struct {
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    min_time_ns: u64,

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

    pub fn minPerOpNs(self: BenchmarkResult) f64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.operation_count > 0);
        return @as(f64, @floatFromInt(self.min_time_ns)) / @as(f64, @floatFromInt(self.operation_count));
    }

    pub fn print(self: BenchmarkResult) void {
        std.debug.print(
            "| {s:<44} | {d:>8} | {d:>10.4} ms | {d:>10.2} ns/op | {d:>6} iters |\n",
            .{ self.name, self.operation_count, self.avgTimeMs(), self.timePerOpNs(), self.iterations },
        );
    }
};

const PolygonData = struct {
    points: [MAX_PATH_VERTICES]Vec2 = undefined,
    vertex_count: u32 = 0,
};

const StrokeData = struct {
    points: [MAX_STROKE_INPUT]Vec2 = undefined,
    point_count: u32 = 0,
};

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

    const warmup_count = getWarmupIterations(operation_count);
    for (0..warmup_count) |_| {
        triangulator.reset();
        _ = triangulator.triangulate(polygon_vertices, polygon) catch unreachable;
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};
    var last_index_count: usize = 0;

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        triangulator.reset();
        const start = time.Instant.now();
        const indices = triangulator.triangulate(polygon_vertices, polygon) catch unreachable;
        const end = time.Instant.now();
        last_index_count = indices.len;
        sampler.record(end.since(start));
    }

    std.debug.assert(last_index_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

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

    const warmup_count = getWarmupIterations(operation_count);
    for (0..warmup_count) |_| {
        _ = stroke_mod.expandStroke(path_points, stroke_width, cap, join, miter_limit, closed) catch unreachable;
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};
    var last_output_count: usize = 0;

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        const start = time.Instant.now();
        const result = stroke_mod.expandStroke(path_points, stroke_width, cap, join, miter_limit, closed) catch unreachable;
        const end = time.Instant.now();
        last_output_count = result.points.len;
        sampler.record(end.since(start));
    }

    std.debug.assert(last_output_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

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

    const warmup_count = getWarmupIterations(operation_count);
    for (0..warmup_count) |_| {
        _ = stroke_mod.expandStrokeToTriangles(path_points, stroke_width, cap, join, miter_limit, closed) catch unreachable;
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};
    var last_triangle_count: usize = 0;

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        const start = time.Instant.now();
        const result = stroke_mod.expandStrokeToTriangles(path_points, stroke_width, cap, join, miter_limit, closed) catch unreachable;
        const end = time.Instant.now();
        last_triangle_count = result.indices.len / 3;
        sampler.record(end.since(start));
    }

    std.debug.assert(last_triangle_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

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

    for (0..warmup_count) |_| {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        array.clear();
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        var array: FixedArray(u32, 8192) = .{};
        const start = time.Instant.now();
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        std.mem.doNotOptimizeAway(array.constSlice());
        array.clear();
        const end = time.Instant.now();
        std.debug.assert(array.len == 0);
        sampler.record(end.since(start));
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

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

    for (0..warmup_count) |_| {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        for (0..item_count) |_| {
            _ = array.pop();
        }
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        std.mem.doNotOptimizeAway(array.constSlice());

        var pop_sink: u32 = 0;
        const start = time.Instant.now();
        for (0..item_count) |_| {
            pop_sink +%= array.pop();
        }
        const end = time.Instant.now();
        std.mem.doNotOptimizeAway(pop_sink);
        std.debug.assert(array.len == 0);
        sampler.record(end.since(start));
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

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

    for (0..warmup_count) |_| {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        for (0..item_count) |_| {
            _ = array.swapRemove(0);
        }
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        const start = time.Instant.now();
        for (0..item_count) |_| {
            _ = array.swapRemove(0);
        }
        const end = time.Instant.now();
        std.debug.assert(array.len == 0);
        sampler.record(end.since(start));
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

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

    for (0..warmup_count) |_| {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        for (0..item_count) |_| {
            _ = array.orderedRemove(0);
        }
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        var array: FixedArray(u32, 8192) = .{};
        for (0..item_count) |i| {
            array.appendAssumeCapacity(@intCast(i));
        }
        const start = time.Instant.now();
        for (0..item_count) |_| {
            _ = array.orderedRemove(0);
        }
        const end = time.Instant.now();
        std.debug.assert(array.len == 0);
        sampler.record(end.since(start));
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

fn benchVec2Normalize(
    comptime name: []const u8,
    comptime vector_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(vector_count > 0);
        std.debug.assert(vector_count <= 4096);
    }

    var vectors: [vector_count]Vec2 = undefined;
    for (0..vector_count) |i| {
        const fi: f32 = @as(f32, @floatFromInt(i)) + 1.0;
        vectors[i] = Vec2{ .x = fi, .y = fi * 0.7 + 0.5 };
    }

    const operation_count = vector_count;
    const warmup_count = getWarmupIterations(operation_count);

    var sink = Vec2.zero;
    for (0..warmup_count) |_| {
        for (0..vector_count) |i| {
            sink = sink.add(vectors[i].normalize());
        }
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        const start = time.Instant.now();
        for (0..vector_count) |i| {
            sink = sink.add(vectors[i].normalize());
        }
        const end = time.Instant.now();
        sampler.record(end.since(start));
    }

    std.debug.assert(sink.lengthSq() >= 0);
    std.debug.assert(!std.math.isNan(sink.x));

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

fn benchRectContains(
    comptime name: []const u8,
    comptime point_count: u32,
) BenchmarkResult {
    comptime {
        std.debug.assert(point_count > 0);
        std.debug.assert(point_count <= 4096);
    }

    const rect = RectF.init(10.0, 10.0, 100.0, 100.0);

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

    var hit_count: u32 = 0;
    for (0..warmup_count) |_| {
        for (0..point_count) |i| {
            if (rect.contains(test_points[i])) {
                hit_count += 1;
            }
        }
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        const start = time.Instant.now();
        for (0..point_count) |i| {
            if (rect.contains(test_points[i])) {
                hit_count += 1;
            }
        }
        const end = time.Instant.now();
        sampler.record(end.since(start));
    }

    std.debug.assert(hit_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

const pack_card_count: u32 = 128;
const pack_card_glyph_count: u32 = 24;
const pack_card_record_count: u32 = 5 + pack_card_glyph_count;

const pack_chart_row_count: u32 = 4;
const pack_chart_column_count: u32 = 64;
const pack_chart_triangle_count: u32 = pack_chart_row_count * pack_chart_column_count * 2;

const PackFixture = struct {
    frame: records.Frame,
    target: packed_frame.PackedFrame,

    const paint_record_count_max: u32 = 4_096;
    const mesh_point_count_max: u32 = pack_chart_triangle_count * 3;

    comptime {
        assert(pack_card_count * pack_card_record_count <= paint_record_count_max);
        assert(pack_chart_column_count * 2 * 3 <= gooey.internals.emit.triangle_points_max);
    }

    fn init(self: *PackFixture, gpa: std.mem.Allocator) !void {
        try self.frame.initInPlace(gpa, &.{
            .paint_record_count_max = paint_record_count_max,
            .hit_record_count_max = 1,
            .handler_count_max = 1,
            .a11y_node_count_max = 1,
            .announcements = .{ .polite_pending_max = 1, .message_bytes_max = 1 },
            .text_bytes_max = 1,
            .mesh_point_count_max = mesh_point_count_max,
            .params_slot_count_max = 0,
            .params_stride = 0,
        });
        errdefer self.frame.deinit(gpa);
        try self.target.initInPlace(&.{
            .paint = limits.PaintLimits.standard,
            .paint_record_count_max = paint_record_count_max,
        });
        self.frame.reset(1, .{ .width = 1200, .height = 800, .scale_factor = 1 });
        assert(self.frame.paint_count == 0);
        assert(self.target.draw_count == 0);
    }

    fn deinit(self: *PackFixture, gpa: std.mem.Allocator) void {
        self.target.deinit();
        self.frame.deinit(gpa);
    }
};

fn appendPackCards(frame: *records.Frame) void {
    assert(frame.paint_count == 0);
    const white = records.Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    for (0..pack_card_count) |card| {
        const y: f32 = @floatFromInt(card * 48);
        const bounds = records.Rect{ .x = 16, .y = y, .width = 400, .height = 40 };
        const shadow = records.Color{ .r = 0, .g = 0, .b = 0, .a = 0.3 };
        frame.appendPaint(.{ .quad = packCardQuad(bounds, 8, shadow) });
        frame.appendPaint(.{ .quad = packCardQuad(bounds, 0, white) });
        frame.appendPaint(.{ .clip_push = bounds });
        for (0..pack_card_glyph_count) |glyph| {
            const x: f32 = 24 + @as(f32, @floatFromInt(glyph)) * 9;
            const glyph_bounds = records.Rect{ .x = x, .y = y + 12, .width = 8, .height = 14 };
            frame.appendPaint(.{ .sprite = packSprite(.glyph, glyph_bounds) });
        }
        const icon_bounds = records.Rect{ .x = 380, .y = y + 8, .width = 24, .height = 24 };
        frame.appendPaint(.{ .sprite = packSprite(.svg, icon_bounds) });
        frame.appendPaint(.clip_pop);
    }
    assert(frame.paint_count == pack_card_count * pack_card_record_count);
}

fn packCardQuad(bounds: records.Rect, blur: f32, fill: records.Color) records.Quad {
    assert(blur >= 0);
    return .{
        .bounds = bounds,
        .fill = fill,
        .border = .none,
        .corners = .all(8),
        .blur = blur,
        .offset_y = 2,
    };
}

fn packSprite(atlas: records.AtlasKind, bounds: records.Rect) records.Sprite {
    assert(bounds.width > 0);
    return .{
        .bounds = bounds,
        .atlas = atlas,
        .uv = .{ .x = 0.25, .y = 0.25, .width = 0.0625, .height = 0.0625 },
        .tint = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1 },
        .secondary = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .corners = .zero,
        .grayscale = 0,
        .opacity = 1,
    };
}

fn appendPackChart(frame: *records.Frame) void {
    assert(frame.paint_count == 0);
    const cell: f32 = 32;
    for (0..pack_chart_row_count) |row| {
        const range = frame.claimMeshPoints(pack_chart_column_count * 6);
        const points = frame.meshPoints(range);
        const y0 = @as(f32, @floatFromInt(row)) * cell;
        const y1 = y0 + cell;
        for (0..pack_chart_column_count) |column| {
            const x0 = @as(f32, @floatFromInt(column)) * cell;
            const x1 = x0 + cell;
            const corners = [6][2]f32{
                .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 },
                .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 },
            };
            for (points[column * 6 ..][0..6], corners) |*point, corner| {
                point.* = .{ .x = corner[0], .y = corner[1] };
            }
        }
        frame.mesh_point_counts[@backingInt(records.Mesh.Topology.triangles)] += range.count;
        const shade: f32 = if (row % 2 == 0) 0.2 else 0.8;
        frame.appendPaint(.{ .mesh = .{
            .range = range,
            .topology = .triangles,
            .fill = .{ .r = shade, .g = 0.4, .b = 0.6, .a = 1 },
            .width = 0,
        } });
    }
    assert(frame.mesh_point_count == pack_chart_triangle_count * 3);
}

fn benchPack(
    comptime name: []const u8,
    fixture: *PackFixture,
    operation_count: u32,
) BenchmarkResult {
    assert(operation_count > 0);
    assert(fixture.frame.paint_count > 0);
    for (0..getWarmupIterations(operation_count)) |_| {
        pack_mod.pack(&fixture.frame, &fixture.target);
    }

    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};
    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        const start = time.Instant.now();
        pack_mod.pack(&fixture.frame, &fixture.target);
        const end = time.Instant.now();
        sampler.record(end.since(start));
    }
    assert(fixture.target.draw_count > 0);

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

fn runPackBenchmarks(reporter: *bench.Reporter, gpa: std.mem.Allocator) !void {
    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Pack (records to packed frame)\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    reporter.pauseBenchmark();

    var fixture: PackFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    reporter.beginBenchmark();
    appendPackCards(&fixture.frame);
    const card_records = pack_card_count * pack_card_record_count;
    collect(reporter, benchPack("pack_cards_3712_records", &fixture, card_records));

    fixture.frame.reset(2, .{ .width = 1200, .height = 800, .scale_factor = 1 });
    appendPackChart(&fixture.frame);
    collect(reporter, benchPack("pack_chart_512_triangles", &fixture, pack_chart_triangle_count));
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
}

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

fn validateTriangulation(comptime generateFn: fn () PolygonData) !void {
    const data = generateFn();
    std.debug.assert(data.vertex_count >= 3);

    const polygon_vertices = data.points[0..data.vertex_count];
    const polygon = IndexSlice{ .start = 0, .end = data.vertex_count };

    var triangulator = Triangulator.init();
    const indices = try triangulator.triangulate(polygon_vertices, polygon);

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
    var swap_arr: FixedArray(u32, 8) = .{};
    swap_arr.appendAssumeCapacity(10);
    swap_arr.appendAssumeCapacity(20);
    swap_arr.appendAssumeCapacity(30);
    _ = swap_arr.swapRemove(0);
    try std.testing.expectEqual(@as(u32, 30), swap_arr.get(0));

    var ord_arr: FixedArray(u32, 8) = .{};
    ord_arr.appendAssumeCapacity(10);
    ord_arr.appendAssumeCapacity(20);
    ord_arr.appendAssumeCapacity(30);
    _ = ord_arr.orderedRemove(0);
    try std.testing.expectEqual(@as(u32, 20), ord_arr.get(0));
}

test "validate: Vec2 normalize produces unit length" {
    const v = Vec2{ .x = 3.0, .y = 4.0 };
    const n = v.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), n.length(), 1e-6);
}

test "validate: Rect.contains boundary behavior" {
    const rect = RectF.init(10.0, 10.0, 100.0, 100.0);
    try std.testing.expect(rect.contains(PointF.init(50.0, 50.0)));
    try std.testing.expect(!rect.contains(PointF.init(0.0, 0.0)));
    try std.testing.expect(!rect.contains(PointF.init(200.0, 200.0)));
}

test "validate: pack keeps every card record, one draw per pipeline run" {
    var fixture: PackFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    appendPackCards(&fixture.frame);
    pack_mod.pack(&fixture.frame, &fixture.target);
    const target = &fixture.target;
    try std.testing.expectEqual(pack_card_count * 2, target.quad_count);
    const shadow_count = target.counts[@backingInt(packed_frame.Pool.shadows)];
    try std.testing.expectEqual(pack_card_count, shadow_count);
    try std.testing.expectEqual(pack_card_count * (pack_card_glyph_count + 1), target.sprite_count);
    try std.testing.expectEqual(pack_card_count + 1, target.clip_count);
    try std.testing.expectEqual(pack_card_count * 3, target.draw_count);
}

test "validate: pack classifies the chart's shared edges" {
    var fixture: PackFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    appendPackChart(&fixture.frame);
    pack_mod.pack(&fixture.frame, &fixture.target);
    const modes = fixture.target.edgeModeList();
    try std.testing.expectEqual(@as(usize, pack_chart_triangle_count), modes.len);
    const cell_a = pack_chart_column_count * 2 + 10 * 2;
    try std.testing.expectEqual(@as(u32, 1), modes[cell_a]);
    try std.testing.expectEqual(@as(u32, 2 << 2), modes[cell_a + 1]);
    try std.testing.expectEqual(pack_chart_row_count, fixture.target.mesh_count);
}

const keymap_mod = gooey.internals.keymap;
const keymaps_mod = gooey.internals.keymaps;
const actions_mod = gooey.internals.actions;
const text_engine_mod = gooey.internals.text_engine;
const AreaEngine = text_engine_mod.AreaEngine;
const KeyEvent = gooey.input.KeyEvent;

const key_bytes_max: u32 = 4096;
const key_path_depth: u32 = 4;
const key_count_sample: u32 = 1000;

const KeyPath = struct {
    contexts: [key_path_depth]u64,

    pub fn contains(self: KeyPath, hash: u64) bool {
        for (self.contexts) |context| {
            if (context == hash) return true;
        }
        return false;
    }
};

const KeyFixture = struct {
    engine: AreaEngine,
    bytes: [key_bytes_max]u8,
    preedit: [64]u8,
    edits: [64]gooey.internals.text_history.Edit,
    history_bytes: [key_bytes_max]u8,
    action_ids: [7]u64,

    fn init(self: *KeyFixture) void {
        self.engine.bytes = &self.bytes;
        self.engine.preedit = &self.preedit;
        self.engine.history = text_engine_mod.History.init(&self.edits, &self.history_bytes);
        self.engine.reset();
        self.engine.insert("the quick brown fox jumps over the lazy dog\nsecond line here");
        self.action_ids = .{
            actions_mod.text_command, actions_mod.undo,  actions_mod.redo,
            actions_mod.select_all,   actions_mod.paste, actions_mod.copy,
            actions_mod.cut,
        };
        assert(self.engine.len > 0);
        assert(self.engine.cursor == self.engine.len);
    }
};

fn keyEvent(key: gooey.input.KeyCode, modifiers: gooey.input.Modifiers) KeyEvent {
    return .{
        .key = key,
        .modifiers = modifiers,
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = false,
    };
}

fn dispatchKey(
    table: []const keymap_mod.Compiled,
    fixture: *KeyFixture,
    path: KeyPath,
    key: *const KeyEvent,
) bool {
    const found = keymap_mod.match(table, key, path) orelse {
        const event = gooey.input.InputEvent{ .key_down = key.* };
        return fixture.engine.apply(&event);
    };
    assert(found.action != 0);
    const listed = std.mem.indexOfScalar(u64, &fixture.action_ids, found.action) != null;
    assert(listed);
    assert(found.action == actions_mod.text_command);
    return fixture.engine.perform(@fromBackingInt(@intCast(found.arg)));
}

fn benchKeyDispatch(
    comptime name: []const u8,
    comptime convention: keymap_mod.Convention,
    keys: [2]KeyEvent,
    hit: bool,
) BenchmarkResult {
    const table = comptime keymap_mod.compile(keymaps_mod.text_default, convention);
    var fixture: KeyFixture = undefined;
    fixture.init();
    const path = KeyPath{ .contexts = .{ keymaps_mod.context_area.hash, 0, 0, 0 } };
    const operation_count = key_count_sample;
    var handled_count: u32 = 0;
    for (0..getWarmupIterations(operation_count)) |_| {
        for (0..operation_count) |index| {
            if (dispatchKey(table, &fixture, path, &keys[index % 2])) handled_count += 1;
        }
    }
    const min_iterations = getMinSampleIterations(operation_count);
    var sampler: bench.Sampler = .{};
    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_iterations) {
        const start = time.Instant.now();
        for (0..operation_count) |index| {
            if (dispatchKey(table, &fixture, path, &keys[index % 2])) handled_count += 1;
        }
        const end = time.Instant.now();
        sampler.record(end.since(start));
    }
    if (hit) assert(handled_count > 0) else assert(handled_count == 0);
    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

fn runKeyBenchmarks(reporter: *bench.Reporter) void {
    const mac = comptime keymap_mod.compile(keymaps_mod.text_default, .mac);
    const pc = comptime keymap_mod.compile(keymaps_mod.text_default, .pc);
    const entry_bytes = @sizeOf(keymap_mod.Compiled);
    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Key dispatch to a focused TextArea " ++
        "(mac {d} bindings, {d} B; pc {d} bindings, {d} B)\n", .{
        mac.len, mac.len * entry_bytes, pc.len, pc.len * entry_bytes,
    });
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});
    const alt = gooey.input.Modifiers{ .alt = true };
    const ctrl = gooey.input.Modifiers{ .ctrl = true };
    const miss = [2]KeyEvent{ keyEvent(.q, .{}), keyEvent(.w, .{}) };
    const mac_words = [2]KeyEvent{ keyEvent(.left, alt), keyEvent(.right, alt) };
    const pc_words = [2]KeyEvent{ keyEvent(.left, ctrl), keyEvent(.right, ctrl) };
    collect(reporter, benchKeyDispatch("key_mac_word_move_hit", .mac, mac_words, true));
    collect(reporter, benchKeyDispatch("key_mac_unbound_miss", .mac, miss, false));
    collect(reporter, benchKeyDispatch("key_pc_word_move_hit", .pc, pc_words, true));
    collect(reporter, benchKeyDispatch("key_pc_unbound_miss", .pc, miss, false));
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
}

fn collect(reporter: *bench.Reporter, result: BenchmarkResult) void {
    reporter.addEntry(bench.entry(
        result.name,
        result.operation_count,
        result.total_time_ns,
        result.iterations,
        result.minPerOpNs(),
    ));
    result.print();
    reporter.beginBenchmark();
}

pub fn main(init: std.process.Init) !void {
    var reporter = bench.Reporter.init("core", init.io, init.minimal.args.vector);

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Triangulation (convex polygons, ear-clip)\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchTriangulate("convex_8", buildConvex8));
    collect(&reporter, benchTriangulate("convex_32", buildConvex32));
    collect(&reporter, benchTriangulate("convex_64", buildConvex64));
    collect(&reporter, benchTriangulate("convex_128", buildConvex128));
    collect(&reporter, benchTriangulate("convex_256", buildConvex256));
    collect(&reporter, benchTriangulate("convex_512", buildConvex512));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Triangulation (concave star polygons)\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchTriangulate("star_5 (10 verts)", buildStar5));
    collect(&reporter, benchTriangulate("star_10 (20 verts)", buildStar10));
    collect(&reporter, benchTriangulate("star_50 (100 verts)", buildStar50));
    collect(&reporter, benchTriangulate("star_100 (200 verts)", buildStar100));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Stroke Expansion (open, butt cap, miter join)\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchStrokeExpand("zigzag_4_butt_miter", buildZigzag4, .butt, .miter, false));
    collect(&reporter, benchStrokeExpand("zigzag_32_butt_miter", buildZigzag32, .butt, .miter, false));
    collect(&reporter, benchStrokeExpand("zigzag_128_butt_miter", buildZigzag128, .butt, .miter, false));
    collect(&reporter, benchStrokeExpand("zigzag_256_butt_miter", buildZigzag256, .butt, .miter, false));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Stroke Style Comparison (zigzag 32 points)\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchStrokeExpand("zigzag_32_butt_miter", buildZigzag32, .butt, .miter, false));
    collect(&reporter, benchStrokeExpand("zigzag_32_round_round", buildZigzag32, .round, .round, false));
    collect(&reporter, benchStrokeExpand("zigzag_32_square_bevel", buildZigzag32, .square, .bevel, false));

    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchStrokeExpand("sine_64_butt_miter", buildSine64, .butt, .miter, false));
    collect(&reporter, benchStrokeExpand("sine_64_round_round", buildSine64, .round, .round, false));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Stroke Expansion (closed paths)\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchStrokeExpand("circle_32_closed_miter", buildCircle32, .butt, .miter, true));
    collect(&reporter, benchStrokeExpand("circle_64_closed_miter", buildCircle64, .butt, .miter, true));
    collect(&reporter, benchStrokeExpand("circle_32_closed_round", buildCircle32, .butt, .round, true));
    collect(&reporter, benchStrokeExpand("circle_64_closed_round", buildCircle64, .butt, .round, true));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Stroke To Triangles (bypasses ear-clipper)\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchStrokeToTriangles("zigzag_32_tri_butt_miter", buildZigzag32, .butt, .miter, false));
    collect(&reporter, benchStrokeToTriangles("zigzag_128_tri_butt_miter", buildZigzag128, .butt, .miter, false));
    collect(&reporter, benchStrokeToTriangles("circle_32_tri_closed", buildCircle32, .butt, .miter, true));
    collect(&reporter, benchStrokeToTriangles("circle_64_tri_closed", buildCircle64, .butt, .miter, true));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — FixedArray Append/Clear\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchFixedArrayAppendClear("append_clear_100", 100));
    collect(&reporter, benchFixedArrayAppendClear("append_clear_1000", 1000));
    collect(&reporter, benchFixedArrayAppendClear("append_clear_4000", 4000));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — FixedArray Removal Strategies (O(1) vs O(n))\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchFixedArrayPopCycle("pop_100", 100));
    collect(&reporter, benchFixedArrayPopCycle("pop_1000", 1000));

    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchFixedArraySwapRemove("swap_remove_100", 100));
    collect(&reporter, benchFixedArraySwapRemove("swap_remove_1000", 1000));

    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchFixedArrayOrderedRemove("ordered_remove_100", 100));
    collect(&reporter, benchFixedArrayOrderedRemove("ordered_remove_500", 500));
    collect(&reporter, benchFixedArrayOrderedRemove("ordered_remove_1000", 1000));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Vec2 Batch Normalize\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchVec2Normalize("normalize_100", 100));
    collect(&reporter, benchVec2Normalize("normalize_1000", 1000));
    collect(&reporter, benchVec2Normalize("normalize_4000", 4000));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Rect.contains Batch Containment\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchRectContains("contains_100", 100));
    collect(&reporter, benchRectContains("contains_1000", 1000));
    collect(&reporter, benchRectContains("contains_4000", 4000));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    try runPackBenchmarks(&reporter, init.gpa);

    runKeyBenchmarks(&reporter);

    std.debug.print("\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Core Benchmarks — Scaling Analysis (triangulate ns/op vs vertex count)\n", .{});
    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchTriangulate("scaling_convex_8", buildConvex8));
    collect(&reporter, benchTriangulate("scaling_convex_16", buildConvex16));
    collect(&reporter, benchTriangulate("scaling_convex_32", buildConvex32));
    collect(&reporter, benchTriangulate("scaling_convex_64", buildConvex64));
    collect(&reporter, benchTriangulate("scaling_convex_128", buildConvex128));
    collect(&reporter, benchTriangulate("scaling_convex_256", buildConvex256));
    collect(&reporter, benchTriangulate("scaling_convex_512", buildConvex512));

    std.debug.print(&@as([105]u8, @splat('-')) ++ "\n", .{});

    collect(&reporter, benchTriangulate("scaling_star_5", buildStar5));
    collect(&reporter, benchTriangulate("scaling_star_10", buildStar10));
    collect(&reporter, benchTriangulate("scaling_star_50", buildStar50));
    collect(&reporter, benchTriangulate("scaling_star_100", buildStar100));

    std.debug.print(&@as([105]u8, @splat('=')) ++ "\n", .{});

    std.debug.print(
        \\
        \\Notes:
        \\  - Triangulation = reset() + triangulate() via ear-clipping. O(n * r) where r = reflex count.
        \\  - Stroke Expand = expandStroke() producing a polygon outline for the ear-clipper.
        \\  - Stroke To Triangles = expandStrokeToTriangles() producing GPU-ready indices directly.
        \\  - FixedArray: append/clear measures write throughput; pop/swap are O(1); orderedRemove is O(n).
        \\  - Vec2 Normalize = batch normalize with sqrt + division per vector.
        \\  - Rect.contains = four comparisons per point (branch-heavy).
        \\  - Scaling Analysis: if triangulate ns/op grows linearly, total cost is O(n²).
        \\    Convex polygons have zero reflex vertices — best case for ear-clipper.
        \\    Star polygons have ~N/2 reflex vertices — worst case for point-in-triangle checks.
        \\  - Iterations are adaptive based on operation count.
        \\
    , .{});

    reporter.finish();
}

fn printHeader() void {
    std.debug.print("| {s:<44} | {s:>8} | {s:>13} | {s:>14} | {s:>10} |\n", .{
        "Test",
        "Ops",
        "Avg Time",
        "Time/Op",
        "Iters",
    });
}
