const std = @import("std");
const gooey = @import("gooey");
const bench = @import("bench");

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
const layout = gooey.internals.layout;

const LayoutEngine = layout.LayoutEngine;

/// The framework ceiling, the profile `ResourceLimits` documents for stress
/// tests and benchmarks; an app budget is at most this.
const bench_capacity = layout.LayoutCapacity.fromLimits(&gooey.ResourceLimits.ceiling);
const Sizing = layout.Sizing;
const SizingAxis = layout.SizingAxis;
const Padding = layout.Padding;

fn getWarmupIterations(node_count: u32) u32 {
    if (node_count >= 10000) return 2;
    if (node_count >= 5000) return 3;
    return 5;
}

fn getMinSampleIterations(node_count: u32) u32 {
    if (node_count >= 10000) return 5;
    if (node_count >= 5000) return 8;
    return 10;
}

/// Minimum wall-clock time to sample before concluding a benchmark; zero in
/// the Cachegrind gate's fixed-iteration build (see `bench.sample_time_ns_min`).
const MIN_SAMPLE_TIME_NS: u64 = bench.sample_time_ns_min;

const BenchmarkResult = struct {
    name: []const u8,
    node_count: u32,
    total_time_ns: u64,
    iterations: u32,
    min_time_ns: u64,

    pub fn avgTimeMs(self: BenchmarkResult) f64 {
        const avg_ns: f64 = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        return avg_ns / std.time.ns_per_ms;
    }

    pub fn timePerNodeNs(self: BenchmarkResult) f64 {
        const avg_ns = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        return avg_ns / @as(f64, @floatFromInt(self.node_count));
    }

    /// Minimum observed per-node nanoseconds — the best-of-N estimator, least
    /// perturbed by runner noise. Mirrors `timePerOpNs` on the min sample.
    pub fn minPerOpNs(self: BenchmarkResult) f64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.node_count > 0);
        return @as(f64, @floatFromInt(self.min_time_ns)) / @as(f64, @floatFromInt(self.node_count));
    }

    pub fn print(self: BenchmarkResult) void {
        std.debug.print(
            "| {s:<40} | {d:>8} | {d:>10.4} ms | {d:>8.2} ns/node |\n",
            .{ self.name, self.node_count, self.avgTimeMs(), self.timePerNodeNs() },
        );
    }
};

fn runBenchmark(
    comptime name: []const u8,
    comptime buildFn: fn (*LayoutEngine) anyerror!u32,
) BenchmarkResult {
    var engine = LayoutEngine.init(&bench_capacity) catch
        @panic("layout-bench: LayoutEngine.init OOM");
    defer engine.deinit();

    engine.beginFrame(1000, 1000);
    const node_count = buildFn(&engine) catch unreachable;
    engine.endFrame() catch unreachable;

    const warmup_iters = getWarmupIterations(node_count);
    const min_sample_iters = getMinSampleIterations(node_count);

    var warmup_count: u32 = 0;
    while (warmup_count < warmup_iters) : (warmup_count += 1) {
        engine.beginFrame(1000, 1000);
        _ = buildFn(&engine) catch unreachable;
        engine.endFrame() catch unreachable;
    }

    var sampler: bench.Sampler = .{};

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_sample_iters) {
        engine.beginFrame(1000, 1000);
        _ = buildFn(&engine) catch unreachable;

        const start = time.Instant.now();
        engine.endFrame() catch unreachable;
        const end = time.Instant.now();

        sampler.record(end.since(start));
    }

    return .{
        .name = name,
        .node_count = node_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

fn runFullFrameBenchmark(
    comptime name: []const u8,
    comptime buildFn: fn (*LayoutEngine) anyerror!u32,
) BenchmarkResult {
    var engine = LayoutEngine.init(&bench_capacity) catch
        @panic("layout-bench: LayoutEngine.init OOM");
    defer engine.deinit();

    engine.beginFrame(1000, 1000);
    const node_count = buildFn(&engine) catch unreachable;
    engine.endFrame() catch unreachable;

    const warmup_iters = getWarmupIterations(node_count);
    const min_sample_iters = getMinSampleIterations(node_count);

    var warmup_count: u32 = 0;
    while (warmup_count < warmup_iters) : (warmup_count += 1) {
        engine.beginFrame(1000, 1000);
        _ = buildFn(&engine) catch unreachable;
        engine.endFrame() catch unreachable;
    }

    var sampler: bench.Sampler = .{};

    while (sampler.total_time_ns < MIN_SAMPLE_TIME_NS or sampler.iterations < min_sample_iters) {
        const start = time.Instant.now();
        engine.beginFrame(1000, 1000);
        _ = buildFn(&engine) catch unreachable;
        engine.endFrame() catch unreachable;
        const end = time.Instant.now();

        sampler.record(end.since(start));
    }

    return .{
        .name = name,
        .node_count = node_count,
        .total_time_ns = sampler.total_time_ns,
        .iterations = sampler.iterations,
        .min_time_ns = sampler.min_time_ns,
    };
}

fn validateBenchmark(
    comptime buildFn: fn (*LayoutEngine) anyerror!u32,
    expected_count: u32,
) !void {
    var engine = try LayoutEngine.init(&bench_capacity);
    defer engine.deinit();

    engine.beginFrame(1000, 1000);
    const count = try buildFn(&engine);
    try engine.endFrame();

    try std.testing.expectEqual(expected_count, count);
}

fn buildWideNoWrapSimpleFew(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fixed(100) },
            .layout_direction = .left_to_right,
        },
    });
    count += 1;

    for (0..1000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.fixed(10), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: wide_no_wrap_simple_few" {
    try validateBenchmark(buildWideNoWrapSimpleFew, 1001);
}

fn buildExpandWithMaxConstraint(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fit() },
            .layout_direction = .left_to_right,
        },
    });
    count += 1;

    for (0..1000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fit() },
                .layout_direction = .left_to_right,
            },
        });
        count += 1;

        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.growMax(40), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();

        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: expand_with_max_constraint" {
    try validateBenchmark(buildExpandWithMaxConstraint, 3001);
}

fn buildExpandWithMinConstraint(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fit() },
            .layout_direction = .left_to_right,
        },
    });
    count += 1;

    for (0..1000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fit() },
                .layout_direction = .left_to_right,
            },
        });
        count += 1;

        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.growMin(60), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();

        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: expand_with_min_constraint" {
    try validateBenchmark(buildExpandWithMinConstraint, 3001);
}

fn buildNestedVerticalStack(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(200), .height = SizingAxis.fit() },
            .layout_direction = .top_to_bottom,
            .padding = Padding.all(10),
            .child_gap = 5,
        },
    });
    count += 1;

    for (0..10000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(1) },
            },
        });
        count += 1;
        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: nested_vertical_stack" {
    try validateBenchmark(buildNestedVerticalStack, 10001);
}

fn buildFlexExpandEqualWeights(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(10000), .height = SizingAxis.fixed(100) },
            .layout_direction = .left_to_right,
        },
    });
    count += 1;

    for (0..15000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() },
            },
        });
        count += 1;
        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: flex_expand_equal_weights" {
    try validateBenchmark(buildFlexExpandEqualWeights, 15001);
}

fn buildFlexExpandWeights(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(10000), .height = SizingAxis.fixed(100) },
            .layout_direction = .left_to_right,
        },
    });
    count += 1;

    for (0..5000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fixed(100) },
                .layout_direction = .left_to_right,
            },
        });
        count += 1;

        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() },
            },
        });
        count += 1;
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.growWeighted(2, 0, std.math.floatMax(f32)),
                    .height = SizingAxis.grow(),
                },
            },
        });
        count += 1;
        engine.closeElement();

        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: flex_expand_weights" {
    try validateBenchmark(buildFlexExpandWeights, 15001);
}

fn buildPercentageAndRatio(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(1000), .height = SizingAxis.fixed(1000) },
            .layout_direction = .top_to_bottom,
        },
    });
    count += 1;

    for (0..10000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.percent(0.5), .height = SizingAxis.fit() },
                .aspect_ratio = 0.5,
            },
        });
        count += 1;
        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: percentage_and_ratio" {
    try validateBenchmark(buildPercentageAndRatio, 10001);
}

fn buildDeepNesting(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;
    const depth: u32 = 50; // Within every profile's `build.box_depth_max` (64).

    for (0..depth) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() },
                .layout_direction = .top_to_bottom,
                .padding = Padding.all(5),
            },
        });
        count += 1;
    }

    for (0..951) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();
    }

    for (0..depth) |_| {
        engine.closeElement();
    }

    return count;
}

test "validate: deep_nesting" {
    try validateBenchmark(buildDeepNesting, 1001);
}

fn buildMixedLayout(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(800), .height = SizingAxis.fixed(600) },
            .layout_direction = .top_to_bottom,
            .padding = Padding.all(10),
            .child_gap = 10,
        },
    });
    count += 1;

    for (0..50) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() },
                .layout_direction = .left_to_right,
                .child_gap = 5,
            },
        });
        count += 1;

        for (0..100) |_| {
            try engine.openElement(.{
                .layout = .{
                    .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() },
                },
            });
            count += 1;
            engine.closeElement();
        }

        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: mixed_layout" {
    try validateBenchmark(buildMixedLayout, 5051);
}

fn buildShrinkOverflow(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fixed(100) },
            .layout_direction = .left_to_right,
        },
    });
    count += 1;

    for (0..2000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.fitMax(50), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: shrink_overflow" {
    try validateBenchmark(buildShrinkOverflow, 2001);
}

fn buildSpaceDistribution(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(1000), .height = SizingAxis.fixed(500) },
            .layout_direction = .top_to_bottom,
            .main_axis_distribution = .space_between,
        },
    });
    count += 1;

    for (0..1000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: space_distribution" {
    try validateBenchmark(buildSpaceDistribution, 1001);
}

fn buildPercentageSizing(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(1000), .height = SizingAxis.fixed(1000) },
            .layout_direction = .top_to_bottom,
        },
    });
    count += 1;

    for (0..1000) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.percent(0.5), .height = SizingAxis.fit() },
                .aspect_ratio = 0.5,
            },
        });
        count += 1;
        engine.closeElement();
    }

    engine.closeElement();
    return count;
}

test "validate: percentage_sizing" {
    try validateBenchmark(buildPercentageSizing, 1001);
}

// A data table on one grid: a header and 300 row boxes of six cells, over
// fit, grow, fixed, and percent columns, as `docs/layout-grid.md` sketches.
// The cell widths vary by row so the fit columns take their widest cell.

const grid_table_columns = [_]layout.Track{
    .{},
    .{ .axis = SizingAxis.grow() },
    .{},
    .{ .axis = SizingAxis.fixed(96), .alignment = .end },
    .{ .axis = SizingAxis.growWeighted(2, 0, std.math.floatMax(f32)) },
    .{ .axis = SizingAxis.percent(0.1) },
};

fn buildGridTable(engine: *LayoutEngine) !u32 {
    const row_count: u32 = 300;
    const column_count: u32 = grid_table_columns.len;
    try engine.openElementWith(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(1000), .height = SizingAxis.fit() },
        .child_gap = 8,
        .grid = .grid,
    } }, .{ .grid = &.{ .columns = &grid_table_columns, .row_gap = 2 } });
    for (0..column_count) |column| {
        try openGridBenchLeaf(engine, @floatFromInt(40 + column * 10), 20);
    }
    for (0..row_count) |row| {
        try engine.openElementWith(.{ .layout = .{
            .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() },
            .padding = .{ .top = 4, .bottom = 4 },
            .grid = .row,
        } }, .{});
        for (0..column_count) |column| {
            const width: f32 = @floatFromInt(20 + (row * 7 + column * 13) % 60);
            try openGridBenchLeaf(engine, width, 16);
        }
        engine.closeElement();
    }
    engine.closeElement();
    return 1 + column_count + row_count * (1 + column_count);
}

fn openGridBenchLeaf(engine: *LayoutEngine, width: f32, height: f32) !void {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(width, height) } });
    engine.closeElement();
}

test "validate: grid_table" {
    try validateBenchmark(buildGridTable, 2107);
}

// A dashboard of 100 cards on 12 equal grow columns, spanning 3, 4, and 6
// in turn, each card a nested two-column grid of label and value cells.

const grid_cards_columns: [12]layout.Track = @splat(.{ .axis = SizingAxis.grow() });
const grid_card_columns = [_]layout.Track{ .{}, .{ .axis = SizingAxis.grow() } };

fn buildGridCards(engine: *LayoutEngine) !u32 {
    const card_count: u32 = 100;
    const spans = [_]u8{ 3, 4, 6 };
    try engine.openElementWith(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(1000), .height = SizingAxis.fit() },
        .child_gap = 12,
        .grid = .grid,
    } }, .{ .grid = &.{ .columns = &grid_cards_columns } });
    for (0..card_count) |card| {
        try engine.openElementWith(.{ .layout = .{
            .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() },
            .padding = Padding.all(8),
            .child_gap = 4,
            .grid = .grid,
        } }, .{
            .grid = &.{ .columns = &grid_card_columns },
            .cell = .{ .column_span = spans[card % spans.len] },
        });
        for (0..4) |cell| {
            try openGridBenchLeaf(engine, @floatFromInt(30 + (card + cell * 11) % 40), 18);
        }
        engine.closeElement();
    }
    engine.closeElement();
    return 1 + card_count * 5;
}

test "validate: grid_cards" {
    try validateBenchmark(buildGridCards, 501);
}

// Text truncation (`docs/text-truncation.md`): 100 cards of a 400-word body,
// clamped to three lines with an ellipsis or not clamped at all, and 1,000
// one-line table cells cut with an ellipsis. Text measures 7 px a byte.

const truncation_body: [400 * 6]u8 = blk: {
    @setEvalBranchQuota(10_000);
    const words = [_][]const u8{ "lorem", "ipsum", "dolor", "sit", "amet", "elit" };
    var bytes: [400 * 6]u8 = @splat(' ');
    var offset: usize = 0;
    var index: usize = 0;
    while (offset + 6 <= bytes.len) : (index += 1) {
        const word = words[index % words.len];
        @memcpy(bytes[offset..][0..word.len], word);
        offset += word.len + 1;
    }
    break :blk bytes;
};

fn measureSevenPixelsPerByte(
    text: []const u8,
    _: u16,
    font_size: u16,
    _: ?f32,
    _: ?*anyopaque,
) layout.engine.TextMeasurement {
    std.debug.assert(font_size > 0);
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 7, .height = 14 };
}

fn buildTextCards(engine: *LayoutEngine, line_count_max: u8) !u32 {
    const card_count: u32 = 100;
    engine.setMeasureTextFn(measureSevenPixelsPerByte, null);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(1000), .height = SizingAxis.fit() },
        .layout_direction = .top_to_bottom,
        .child_gap = 8,
    } });
    for (0..card_count) |_| {
        try engine.openElement(.{ .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(300), .height = SizingAxis.fit() },
            .layout_direction = .top_to_bottom,
            .padding = Padding.all(8),
        } });
        try engine.text(&truncation_body, .{
            .font_size = 14,
            .wrap_mode = .words,
            .line_count_max = line_count_max,
            .overflow = if (line_count_max > 0) .ellipsis else .clip,
        });
        engine.closeElement();
    }
    engine.closeElement();
    return 1 + card_count * 2;
}

fn buildTextClamp(engine: *LayoutEngine) !u32 {
    return buildTextCards(engine, 3);
}

fn buildTextUnclamped(engine: *LayoutEngine) !u32 {
    return buildTextCards(engine, 0);
}

fn buildTextEllipsisCells(engine: *LayoutEngine) !u32 {
    const row_count: u32 = 250;
    engine.setMeasureTextFn(measureSevenPixelsPerByte, null);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(1000), .height = SizingAxis.fit() },
        .layout_direction = .top_to_bottom,
    } });
    for (0..row_count) |row| {
        try engine.openElement(.{ .layout = .{
            .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() },
            .child_gap = 8,
        } });
        for (0..4) |cell| {
            const length = 40 + (row * 7 + cell * 13) % 60;
            const cell_text: layout.TextConfig = .{ .font_size = 14, .overflow = .ellipsis };
            try engine.text(truncation_body[0..length], cell_text);
        }
        engine.closeElement();
    }
    engine.closeElement();
    return 1 + row_count * 5;
}

test "validate: text_clamp" {
    try validateBenchmark(buildTextClamp, 201);
}

test "validate: text_unclamped" {
    try validateBenchmark(buildTextUnclamped, 201);
}

test "validate: text_ellipsis_cells" {
    try validateBenchmark(buildTextEllipsisCells, 1251);
}

// Models 127 open modals, each with a nested dropdown and later modal content.
// This nearly saturates the ceiling's 255 floating roots (one per layer, a
// `u8` fragment index) and positions nested floats on two-thirds of all
// elements without overflowing the floating pool.

fn buildNestedFloatingOverlays(engine: *LayoutEngine) !u32 {
    const group_count: u32 = 127;
    comptime {
        std.debug.assert(group_count > 0);
        std.debug.assert(group_count * 2 <= bench_capacity.floating_count_max);
        std.debug.assert(group_count * 2 + 2 > bench_capacity.floating_count_max);
    }

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(1000, 1000) },
    });

    for (0..group_count) |_| {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(400, 300) },
            .floating = .{ .attach_to_parent = false },
        });
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(200, 100) },
            .floating = .{},
        });
        engine.closeElement();
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(200, 100) },
        });
        engine.closeElement();
        engine.closeElement();
    }

    engine.closeElement();
    return 1 + group_count * 3;
}

test "validate: nested_floating_overlays" {
    try validateBenchmark(buildNestedFloatingOverlays, 382);
}

/// Print a layout benchmark result and record it in the JSON reporter.
/// Maps the layout-specific `node_count` field to the common `operation_count`.
fn collect(reporter: *bench.Reporter, result: BenchmarkResult) void {
    reporter.addEntry(bench.entry(
        result.name,
        result.node_count,
        result.total_time_ns,
        result.iterations,
        result.minPerOpNs(),
    ));
    result.print();
    // Printing stays outside the next benchmark's Cachegrind region.
    reporter.beginBenchmark();
}

pub fn main(init: std.process.Init) !void {
    var reporter = bench.Reporter.init("layout", init.io, init.minimal.args.vector);

    printTableHeader("Layout Only (endFrame)");
    collectLayoutOnly(&reporter);
    std.debug.print(&@as([90]u8, @splat('=')) ++ "\n", .{});

    printTableHeader("Full Frame (build + layout)");
    collectFullFrame(&reporter);
    std.debug.print(&@as([90]u8, @splat('=')) ++ "\n", .{});

    std.debug.print("\nLayout Only = endFrame() only. " ++
        "Full Frame = beginFrame + tree build + endFrame.\n", .{});
    std.debug.print("Iterations are adaptive based on node count (fewer for large tests).\n", .{});
    std.debug.print("\nEngine capacity = {d} elements (ResourceLimits.ceiling)\n", .{
        bench_capacity.element_count_max,
    });
    std.debug.print("PanGui benchmarks use up to 100k+ nodes for comparison.\n", .{});

    reporter.finish();
}

fn printTableHeader(comptime title: []const u8) void {
    comptime std.debug.assert(title.len > 0);
    std.debug.print("\n", .{});
    std.debug.print(&@as([90]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Layout Engine Benchmarks — " ++ title ++ "\n", .{});
    std.debug.print(&@as([90]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("| {s:<40} | {s:>8} | {s:>13} | {s:>14} |\n", .{
        "Test",
        "Nodes",
        "Avg Time",
        "Time/Node",
    });
    std.debug.print(&@as([90]u8, @splat('-')) ++ "\n", .{});
}

/// `endFrame` alone, in the order the Cachegrind gate's baselines use.
fn collectLayoutOnly(reporter: *bench.Reporter) void {
    collect(reporter, runBenchmark("nested_floating_overlays", buildNestedFloatingOverlays));
    collect(reporter, runBenchmark("wide_no_wrap_simple_few", buildWideNoWrapSimpleFew));
    collect(reporter, runBenchmark("deep_nesting", buildDeepNesting));
    collect(reporter, runBenchmark("space_distribution", buildSpaceDistribution));
    collect(reporter, runBenchmark("percentage_sizing", buildPercentageSizing));
    collect(reporter, runBenchmark("shrink_overflow", buildShrinkOverflow));
    collect(reporter, runBenchmark("expand_with_max_constraint", buildExpandWithMaxConstraint));
    collect(reporter, runBenchmark("expand_with_min_constraint", buildExpandWithMinConstraint));
    collect(reporter, runBenchmark("mixed_layout", buildMixedLayout));
    collect(reporter, runBenchmark("nested_vertical_stack", buildNestedVerticalStack));
    collect(reporter, runBenchmark("percentage_and_ratio", buildPercentageAndRatio));
    collect(reporter, runBenchmark("flex_expand_equal_weights", buildFlexExpandEqualWeights));
    collect(reporter, runBenchmark("flex_expand_weights", buildFlexExpandWeights));
    collect(reporter, runBenchmark("grid_table", buildGridTable));
    collect(reporter, runBenchmark("grid_cards", buildGridCards));
    collect(reporter, runBenchmark("text_clamp", buildTextClamp));
    collect(reporter, runBenchmark("text_unclamped", buildTextUnclamped));
    collect(reporter, runBenchmark("text_ellipsis_cells", buildTextEllipsisCells));
}

/// `beginFrame`, the tree build, and `endFrame`, in the gate's order.
fn collectFullFrame(reporter: *bench.Reporter) void {
    collect(reporter, runFullFrameBenchmark(
        "full_nested_floating_overlays",

        buildNestedFloatingOverlays,
    ));
    collect(reporter, runFullFrameBenchmark(
        "full_wide_no_wrap_simple_few",
        buildWideNoWrapSimpleFew,
    ));
    collect(reporter, runFullFrameBenchmark("full_deep_nesting", buildDeepNesting));
    collect(reporter, runFullFrameBenchmark("full_space_distribution", buildSpaceDistribution));
    collect(reporter, runFullFrameBenchmark("full_percentage_sizing", buildPercentageSizing));
    collect(reporter, runFullFrameBenchmark("full_shrink_overflow", buildShrinkOverflow));
    collect(reporter, runFullFrameBenchmark(
        "full_expand_with_max_constraint",
        buildExpandWithMaxConstraint,
    ));
    collect(reporter, runFullFrameBenchmark(
        "full_expand_with_min_constraint",
        buildExpandWithMinConstraint,
    ));
    collect(reporter, runFullFrameBenchmark("full_mixed_layout", buildMixedLayout));
    collect(reporter, runFullFrameBenchmark(
        "full_nested_vertical_stack",
        buildNestedVerticalStack,
    ));
    collect(reporter, runFullFrameBenchmark("full_percentage_and_ratio", buildPercentageAndRatio));
    collect(reporter, runFullFrameBenchmark(
        "full_flex_expand_equal_weights",
        buildFlexExpandEqualWeights,
    ));
    collect(reporter, runFullFrameBenchmark("full_flex_expand_weights", buildFlexExpandWeights));
    collect(reporter, runFullFrameBenchmark("full_grid_table", buildGridTable));
    collect(reporter, runFullFrameBenchmark("full_grid_cards", buildGridCards));
    collect(reporter, runFullFrameBenchmark("full_text_clamp", buildTextClamp));
    collect(reporter, runFullFrameBenchmark("full_text_unclamped", buildTextUnclamped));
    collect(reporter, runFullFrameBenchmark("full_text_ellipsis_cells", buildTextEllipsisCells));
}
