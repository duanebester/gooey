//! Layout Engine Benchmarks
//!
//! Benchmark suite modeled after PanGui's layout benchmarks.
//! Tests various layout scenarios to measure performance characteristics.
//!
//! Run as executable: zig build bench
//! Quick tests only:  zig build test (validates node counts, doesn't time)
//!
//! Current MAX_ELEMENTS_PER_FRAME = 16384. Only benchmarks that fit
//! within this limit are included. For comparison with PanGui's full suite
//! (which tests up to 100k+ nodes), consider increasing this limit.

const std = @import("std");
const gooey = @import("gooey");
const layout = gooey.layout;

const LayoutEngine = layout.LayoutEngine;
const Sizing = layout.Sizing;
const SizingAxis = layout.SizingAxis;
const Padding = layout.Padding;

// =============================================================================
// Benchmark Configuration
// =============================================================================

// Adaptive iterations based on node count (tree building is expensive for large tests)
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

const MIN_SAMPLE_TIME_NS: u64 = 50 * std.time.ns_per_ms; // 50ms for fast dev iteration

// =============================================================================
// Benchmark Results
// =============================================================================

const BenchmarkResult = struct {
    name: []const u8,
    node_count: u32,
    total_time_ns: u64,
    iterations: u32,

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

    pub fn print(self: BenchmarkResult) void {
        std.debug.print(
            "| {s:<40} | {d:>8} | {d:>10.4} ms | {d:>8.2} ns/node |\n",
            .{ self.name, self.node_count, self.avgTimeMs(), self.timePerNodeNs() },
        );
    }
};

// =============================================================================
// Benchmark Runner (for executable mode)
// =============================================================================

fn runBenchmark(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime buildFn: fn (*LayoutEngine) anyerror!u32,
) BenchmarkResult {
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    // First pass to get node count for adaptive iterations
    engine.beginFrame(1000, 1000);
    const node_count = buildFn(&engine) catch unreachable;
    _ = engine.endFrame() catch unreachable;

    const warmup_iters = getWarmupIterations(node_count);
    const min_sample_iters = getMinSampleIterations(node_count);

    // Warmup (adaptive based on node count)
    var warmup_count: u32 = 0;
    while (warmup_count < warmup_iters) : (warmup_count += 1) {
        engine.beginFrame(1000, 1000);
        _ = buildFn(&engine) catch unreachable;
        _ = engine.endFrame() catch unreachable;
    }

    // Sample - measure only layout computation (endFrame), not tree building
    var total_time: u64 = 0;
    var iterations: u32 = 0;

    while (total_time < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        engine.beginFrame(1000, 1000);
        _ = buildFn(&engine) catch unreachable;

        const start = std.time.Instant.now() catch unreachable;
        _ = engine.endFrame() catch unreachable;
        const end = std.time.Instant.now() catch unreachable;

        total_time += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .node_count = node_count,
        .total_time_ns = total_time,
        .iterations = iterations,
    };
}

// =============================================================================
// Quick Validation (for test mode - just check node counts)
// =============================================================================

fn validateBenchmark(
    comptime buildFn: fn (*LayoutEngine) anyerror!u32,
    expected_count: u32,
) !void {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(1000, 1000);
    const count = try buildFn(&engine);
    _ = try engine.endFrame();

    try std.testing.expectEqual(expected_count, count);
}

// =============================================================================
// Benchmark: wide_no_wrap_simple_few (1,001 nodes)
// =============================================================================
// From PanGui:
// Width(Pixels(100)).Height(Pixels(100)).Horizontal()
// {
//     Repeat(1000) { Width(Pixels(10)).Height(Pixels(10)) {} }
// }

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

// =============================================================================
// Benchmark: expand_with_max_constraint (3,001 nodes)
// =============================================================================
// From PanGui:
// Width(Pixels(100)).Height(Fit).Horizontal()
// {
//     Repeat(1000) {
//         Width(Pixels(100)).Height(Fit).Horizontal() {
//             Width(Expand(1)).Height(Pixels(10)) {}
//             Width(Expand(1)).Height(Pixels(10)).MaxWidth(Pixels(40)) {}
//         }
//     }
// }

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

        // First child: grow without constraint
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();

        // Second child: grow with max constraint
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

// =============================================================================
// Benchmark: expand_with_min_constraint (3,001 nodes)
// =============================================================================
// From PanGui:
// Width(Pixels(100)).Height(Fit).Horizontal()
// {
//     Repeat(1000) {
//         Width(Pixels(100)).Height(Fit).Horizontal() {
//             Width(Expand(1)).Height(Pixels(10)) {}
//             Width(Expand(1)).Height(Pixels(10)).MinWidth(Pixels(60)) {}
//         }
//     }
// }

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

        // First child: grow without constraint
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();

        // Second child: grow with min constraint
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

// =============================================================================
// Benchmark: nested_vertical_stack (10,001 nodes)
// =============================================================================
// From PanGui:
// Width(Pixels(200)).Height(Fit).Vertical().Padding(10).Gap(5)
// {
//     Repeat(10000) { Width(Expand).Height(Pixels(1)) {} }
// }

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

// =============================================================================
// Benchmark: flex_expand_equal_weights (15,001 nodes)
// =============================================================================
// From PanGui:
// Width(Pixels(10000)).Height(Pixels(100)).Horizontal()
// {
//     Repeat(15000) { Width(Expand(1)).Height(Expand) {} }
// }

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

// =============================================================================
// Benchmark: flex_expand_weights (15,001 nodes)
// =============================================================================
// From PanGui:
// Width(Pixels(10000)).Height(Pixels(100)).Horizontal()
// {
//     Repeat(5000) {
//         Width(100).Height(100).Horizontal() {
//             Width(Expand(1)).Height(Expand) {}
//             Width(Expand(2)).Height(Expand) {}
//         }
//     }
// }
// Note: Gooey doesn't support weighted grow yet, so both children use grow()

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

        // First child: Expand(1)
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() },
            },
        });
        count += 1;
        engine.closeElement();

        // Second child: Expand(2) - using grow() since we don't support weights
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() },
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

// =============================================================================
// Benchmark: percentage_and_ratio (10,001 nodes)
// =============================================================================
// From PanGui:
// Width(Pixels(1000)).Height(Pixels(1000)).Vertical()
// {
//     Repeat(10000) { Width(Percentage(0.5)).Height(Ratio(0.5)) {} }
// }

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
                .aspect_ratio = 0.5, // height = width * 0.5
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

// =============================================================================
// Benchmark: deep_nesting (1,001 nodes)
// =============================================================================
// Tests stack depth handling with deeply nested single-child containers

fn buildDeepNesting(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;
    const depth: u32 = 50; // Stay within MAX_OPEN_DEPTH (64)

    // Create nested containers
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

    // Add leaf children at the deepest level
    for (0..951) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(10) },
            },
        });
        count += 1;
        engine.closeElement();
    }

    // Close all containers
    for (0..depth) |_| {
        engine.closeElement();
    }

    return count;
}

test "validate: deep_nesting" {
    try validateBenchmark(buildDeepNesting, 1001);
}

// =============================================================================
// Benchmark: mixed_layout (5,051 nodes)
// =============================================================================
// Grid-like layout with mixed horizontal and vertical containers

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

    // 50 rows
    for (0..50) |_| {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() },
                .layout_direction = .left_to_right,
                .child_gap = 5,
            },
        });
        count += 1;

        // 100 cells per row
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

// =============================================================================
// Benchmark: shrink_overflow (2,001 nodes)
// =============================================================================
// Tests shrink behavior when children overflow parent

fn buildShrinkOverflow(engine: *LayoutEngine) !u32 {
    var count: u32 = 0;

    // Small container that will force shrinking
    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fixed(100) },
            .layout_direction = .left_to_right,
        },
    });
    count += 1;

    // 2000 children that want 50px each but can shrink
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

// =============================================================================
// Benchmark: space_distribution (1,001 nodes)
// =============================================================================
// Tests space_between distribution

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

// =============================================================================
// Benchmark: percentage_sizing (1,001 nodes)
// =============================================================================
// Tests percentage-based sizing with aspect ratio

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
                .aspect_ratio = 0.5, // height = width * 0.5
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

// =============================================================================
// Main Entry Point (for benchmark executable)
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("=" ** 90 ++ "\n", .{});
    std.debug.print("Gooey Layout Engine Benchmarks\n", .{});
    std.debug.print("=" ** 90 ++ "\n", .{});
    std.debug.print("| {s:<40} | {s:>8} | {s:>13} | {s:>14} |\n", .{
        "Test",
        "Nodes",
        "Avg Time",
        "Time/Node",
    });
    std.debug.print("-" ** 90 ++ "\n", .{});

    // Smallest first
    runBenchmark(allocator, "wide_no_wrap_simple_few", buildWideNoWrapSimpleFew).print();
    runBenchmark(allocator, "deep_nesting", buildDeepNesting).print();
    runBenchmark(allocator, "space_distribution", buildSpaceDistribution).print();
    runBenchmark(allocator, "percentage_sizing", buildPercentageSizing).print();
    runBenchmark(allocator, "shrink_overflow", buildShrinkOverflow).print();
    runBenchmark(allocator, "expand_with_max_constraint", buildExpandWithMaxConstraint).print();
    runBenchmark(allocator, "expand_with_min_constraint", buildExpandWithMinConstraint).print();
    runBenchmark(allocator, "mixed_layout", buildMixedLayout).print();
    // PanGui comparison benchmarks (larger node counts)
    runBenchmark(allocator, "nested_vertical_stack", buildNestedVerticalStack).print();
    runBenchmark(allocator, "percentage_and_ratio", buildPercentageAndRatio).print();
    runBenchmark(allocator, "flex_expand_equal_weights", buildFlexExpandEqualWeights).print();
    runBenchmark(allocator, "flex_expand_weights", buildFlexExpandWeights).print();

    std.debug.print("=" ** 90 ++ "\n", .{});
    std.debug.print("\nNote: Times shown are for layout computation only (endFrame).\n", .{});
    std.debug.print("Tree construction time is excluded from measurements.\n", .{});
    std.debug.print("Iterations are adaptive based on node count (fewer for large tests).\n", .{});
    std.debug.print("\nCurrent MAX_ELEMENTS_PER_FRAME = {d}\n", .{layout.engine.MAX_ELEMENTS_PER_FRAME});
    std.debug.print("PanGui benchmarks use up to 100k+ nodes for comparison.\n", .{});
}
