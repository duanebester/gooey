//! Context Module Benchmarks
//!
//! Benchmark suite for dispatch tree, entity map, and widget store hot paths.
//! Measures the performance-critical operations that run every frame.
//!
//! Run as executable: zig build bench-context
//! Quick tests only:  zig build test (validates node counts, doesn't time)
//!
//! Scenarios:
//!   - Wide tree (1000 siblings)  — stresses pushNode's sibling chain
//!   - Deep tree (64 levels)      — stresses hitTest depth
//!   - Realistic tree (table)     — rows × columns, mixed depth/width
//!   - Hit testing                — point lookup on built trees
//!   - Reset cycle                — per-frame teardown cost
//!   - Entity markDirty           — duplicate detection scalability
//!   - Full frame cycle           — reset + build + syncBounds + hitTest

const std = @import("std");
const gooey = @import("gooey");
const bench = @import("bench");

const context = gooey.context;
const DispatchTree = context.DispatchTree;
const DispatchNodeId = context.DispatchNodeId;
const EntityMap = context.EntityMap;
const BoundingBox = gooey.BoundingBox;

// =============================================================================
// Benchmark Configuration
// =============================================================================

/// Adaptive warmup iterations based on operation count.
fn getWarmupIterations(operation_count: u32) u32 {
    if (operation_count >= 10000) return 2;
    if (operation_count >= 5000) return 3;
    return 5;
}

/// Adaptive minimum sample iterations based on operation count.
fn getMinSampleIterations(operation_count: u32) u32 {
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
// Tree Builders
// =============================================================================

/// Wide tree: single root with N direct children.
/// Stresses the pushNode sibling-chain walk (currently O(n²)).
fn buildWideTree(tree: *DispatchTree, child_count: u32) u32 {
    std.debug.assert(child_count > 0);

    _ = tree.pushNode(); // root
    var count: u32 = 1;

    for (0..child_count) |_| {
        const node_id = tree.pushNode();
        std.debug.assert(node_id.isValid());
        tree.popNode();
        count += 1;
    }

    tree.popNode();
    return count;
}

/// Deep tree: single chain of N nested elements.
/// Stresses hitTest traversal depth and dispatchPath length.
fn buildDeepTree(tree: *DispatchTree, depth: u32) u32 {
    std.debug.assert(depth > 0);
    std.debug.assert(depth <= DispatchTree.MAX_PATH_DEPTH);

    var count: u32 = 0;
    for (0..depth) |_| {
        _ = tree.pushNode();
        count += 1;
    }
    for (0..depth) |_| {
        tree.popNode();
    }
    return count;
}

/// Table tree: rows × columns, mimicking a data table.
/// Mixed depth and width — realistic UI scenario.
fn buildTableTree(tree: *DispatchTree, row_count: u32, column_count: u32) u32 {
    std.debug.assert(row_count > 0);
    std.debug.assert(column_count > 0);

    _ = tree.pushNode(); // table container
    var count: u32 = 1;

    for (0..row_count) |_| {
        _ = tree.pushNode(); // row
        count += 1;

        for (0..column_count) |_| {
            _ = tree.pushNode(); // cell
            count += 1;
            tree.popNode();
        }

        tree.popNode();
    }

    tree.popNode();
    return count;
}

/// Nested list tree: N groups each containing M items.
/// Two levels of width — stresses sibling walk at both levels.
fn buildNestedListTree(tree: *DispatchTree, group_count: u32, items_per_group: u32) u32 {
    std.debug.assert(group_count > 0);
    std.debug.assert(items_per_group > 0);

    _ = tree.pushNode(); // outer container
    var count: u32 = 1;

    for (0..group_count) |_| {
        _ = tree.pushNode(); // group header + container
        count += 1;

        for (0..items_per_group) |_| {
            _ = tree.pushNode(); // item
            count += 1;
            tree.popNode();
        }

        tree.popNode();
    }

    tree.popNode();
    return count;
}

/// Assign stacked bounding boxes to all nodes in a tree.
/// Each node gets a slightly smaller box than its parent,
/// so hitTest has meaningful geometry to work with.
fn assignBounds(tree: *DispatchTree) void {
    const node_count = tree.nodeCount();
    std.debug.assert(node_count > 0);

    for (0..node_count) |i| {
        const node_id = DispatchNodeId.fromIndex(@intCast(i));
        // Outer nodes are larger; leaf nodes are smaller.
        // This ensures containsPoint works realistically during hitTest.
        const inset: f32 = @floatFromInt(i);
        tree.setBounds(node_id, .{
            .x = inset * 0.1,
            .y = inset * 0.1,
            .width = 1000.0 - inset * 0.2,
            .height = 1000.0 - inset * 0.2,
        });
    }
}

// =============================================================================
// Benchmark Runners
// =============================================================================

/// Benchmark tree construction: measures reset + build.
fn benchTreeBuild(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime buildFn: fn (*DispatchTree) u32,
) BenchmarkResult {
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // First pass: get operation count.
    const operation_count = buildFn(&tree);
    tree.reset();

    const warmup_iters = getWarmupIterations(operation_count);
    const min_sample_iters = getMinSampleIterations(operation_count);

    // Warmup.
    for (0..warmup_iters) |_| {
        _ = buildFn(&tree);
        tree.reset();
    }

    // Sample: time reset + build together (both are per-frame costs).
    var total_time: u64 = 0;
    var iterations: u32 = 0;

    while (total_time < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = std.time.Instant.now() catch unreachable;
        tree.reset();
        _ = buildFn(&tree);
        const end = std.time.Instant.now() catch unreachable;

        total_time += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time,
        .iterations = iterations,
    };
}

/// Benchmark hit testing: builds tree once, then times repeated hitTest calls.
fn benchHitTest(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime buildFn: fn (*DispatchTree) u32,
) BenchmarkResult {
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    const operation_count = buildFn(&tree);
    assignBounds(&tree);

    const warmup_iters = getWarmupIterations(operation_count);
    const min_sample_iters = getMinSampleIterations(operation_count);

    // Warmup.
    for (0..warmup_iters) |_| {
        _ = tree.hitTest(500.0, 500.0);
        _ = tree.hitTest(0.5, 0.5);
        _ = tree.hitTest(999.0, 999.0);
    }

    // Sample: three hit test points per iteration (center, corner, edge).
    const hits_per_iter: u32 = 3;
    var total_time: u64 = 0;
    var iterations: u32 = 0;

    while (total_time < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = std.time.Instant.now() catch unreachable;
        std.mem.doNotOptimizeAway(tree.hitTest(500.0, 500.0));
        std.mem.doNotOptimizeAway(tree.hitTest(0.5, 0.5));
        std.mem.doNotOptimizeAway(tree.hitTest(999.0, 999.0));
        const end = std.time.Instant.now() catch unreachable;

        total_time += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time / hits_per_iter,
        .iterations = iterations,
    };
}

/// Benchmark reset only: builds tree, then times repeated resets.
fn benchReset(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime buildFn: fn (*DispatchTree) u32,
) BenchmarkResult {
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // Build once to establish high_water_mark and allocations.
    const operation_count = buildFn(&tree);

    const warmup_iters = getWarmupIterations(operation_count);
    const min_sample_iters = getMinSampleIterations(operation_count);

    // Warmup.
    for (0..warmup_iters) |_| {
        tree.reset();
        _ = buildFn(&tree);
    }

    // Sample: time only the reset call.
    var total_time: u64 = 0;
    var iterations: u32 = 0;

    while (total_time < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        // Rebuild so reset has work to do.
        tree.reset();
        _ = buildFn(&tree);

        const start = std.time.Instant.now() catch unreachable;
        tree.reset();
        const end = std.time.Instant.now() catch unreachable;

        total_time += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time,
        .iterations = iterations,
    };
}

/// Benchmark full frame cycle: reset + build + assignBounds + hitTest.
fn benchFullFrame(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime buildFn: fn (*DispatchTree) u32,
) BenchmarkResult {
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    const operation_count = buildFn(&tree);
    tree.reset();

    const warmup_iters = getWarmupIterations(operation_count);
    const min_sample_iters = getMinSampleIterations(operation_count);

    // Warmup.
    for (0..warmup_iters) |_| {
        tree.reset();
        _ = buildFn(&tree);
        assignBounds(&tree);
        _ = tree.hitTest(500.0, 500.0);
    }

    // Sample.
    var total_time: u64 = 0;
    var iterations: u32 = 0;

    while (total_time < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = std.time.Instant.now() catch unreachable;
        tree.reset();
        _ = buildFn(&tree);
        assignBounds(&tree);
        std.mem.doNotOptimizeAway(tree.hitTest(500.0, 500.0));
        const end = std.time.Instant.now() catch unreachable;

        total_time += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = operation_count,
        .total_time_ns = total_time,
        .iterations = iterations,
    };
}

/// Benchmark EntityMap.markDirty with N entities.
/// Measures duplicate-detection scalability.
fn benchMarkDirty(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    entity_count: u32,
) BenchmarkResult {
    std.debug.assert(entity_count > 0);

    var entities = EntityMap.init(allocator);
    defer entities.deinit();

    // Create entities.
    const Counter = struct { value: u32 };
    var ids: [4096]gooey.EntityId = undefined;
    std.debug.assert(entity_count <= ids.len);

    for (0..entity_count) |i| {
        const entity = entities.new(Counter, .{ .value = @intCast(i) }) catch unreachable;
        ids[i] = entity.id;
    }

    const warmup_iters = getWarmupIterations(entity_count);
    const min_sample_iters = getMinSampleIterations(entity_count);

    // Warmup.
    for (0..warmup_iters) |_| {
        for (ids[0..entity_count]) |id| {
            entities.markDirty(id);
        }
        _ = entities.processNotifications();
    }

    // Sample: mark all entities dirty, then process.
    var total_time: u64 = 0;
    var iterations: u32 = 0;

    while (total_time < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (ids[0..entity_count]) |id| {
            entities.markDirty(id);
        }
        std.mem.doNotOptimizeAway(entities.processNotifications());
        const end = std.time.Instant.now() catch unreachable;

        total_time += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = entity_count,
        .total_time_ns = total_time,
        .iterations = iterations,
    };
}

/// Benchmark markDirty with repeated dirtying of the same entities
/// (worst case for linear duplicate scan).
fn benchMarkDirtyDuplicates(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    entity_count: u32,
    rounds: u32,
) BenchmarkResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(rounds > 0);

    var entities = EntityMap.init(allocator);
    defer entities.deinit();

    const Counter = struct { value: u32 };
    var ids: [4096]gooey.EntityId = undefined;
    std.debug.assert(entity_count <= ids.len);

    for (0..entity_count) |i| {
        const entity = entities.new(Counter, .{ .value = @intCast(i) }) catch unreachable;
        ids[i] = entity.id;
    }

    const total_ops = entity_count * rounds;
    const warmup_iters = getWarmupIterations(total_ops);
    const min_sample_iters = getMinSampleIterations(total_ops);

    // Warmup.
    for (0..warmup_iters) |_| {
        for (0..rounds) |_| {
            for (ids[0..entity_count]) |id| {
                entities.markDirty(id);
            }
        }
        _ = entities.processNotifications();
    }

    // Sample: mark all entities dirty `rounds` times, then process.
    var total_time: u64 = 0;
    var iterations: u32 = 0;

    while (total_time < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = std.time.Instant.now() catch unreachable;
        for (0..rounds) |_| {
            for (ids[0..entity_count]) |id| {
                entities.markDirty(id);
            }
        }
        std.mem.doNotOptimizeAway(entities.processNotifications());
        const end = std.time.Instant.now() catch unreachable;

        total_time += end.since(start);
        iterations += 1;
    }

    return .{
        .name = name,
        .operation_count = total_ops,
        .total_time_ns = total_time,
        .iterations = iterations,
    };
}

// =============================================================================
// Concrete Build Functions (comptime-compatible wrappers)
// =============================================================================

fn buildWide100(tree: *DispatchTree) u32 {
    return buildWideTree(tree, 100);
}

fn buildWide500(tree: *DispatchTree) u32 {
    return buildWideTree(tree, 500);
}

fn buildWide1000(tree: *DispatchTree) u32 {
    return buildWideTree(tree, 1000);
}

fn buildWide2000(tree: *DispatchTree) u32 {
    return buildWideTree(tree, 2000);
}

fn buildDeep16(tree: *DispatchTree) u32 {
    return buildDeepTree(tree, 16);
}

fn buildDeep32(tree: *DispatchTree) u32 {
    return buildDeepTree(tree, 32);
}

fn buildDeep64(tree: *DispatchTree) u32 {
    return buildDeepTree(tree, 64);
}

fn buildTable50x10(tree: *DispatchTree) u32 {
    return buildTableTree(tree, 50, 10);
}

fn buildTable100x10(tree: *DispatchTree) u32 {
    return buildTableTree(tree, 100, 10);
}

fn buildTable200x8(tree: *DispatchTree) u32 {
    return buildTableTree(tree, 200, 8);
}

fn buildNestedList20x50(tree: *DispatchTree) u32 {
    return buildNestedListTree(tree, 20, 50);
}

fn buildNestedList50x20(tree: *DispatchTree) u32 {
    return buildNestedListTree(tree, 50, 20);
}

// =============================================================================
// Quick Validation (for test mode — just check node counts)
// =============================================================================

fn validateTreeBuild(
    comptime buildFn: fn (*DispatchTree) u32,
    expected_count: u32,
) !void {
    var tree = DispatchTree.init(std.testing.allocator);
    defer tree.deinit();

    const count = buildFn(&tree);
    try std.testing.expectEqual(expected_count, count);
}

test "validate: wide_100" {
    try validateTreeBuild(buildWide100, 101);
}

test "validate: wide_500" {
    try validateTreeBuild(buildWide500, 501);
}

test "validate: wide_1000" {
    try validateTreeBuild(buildWide1000, 1001);
}

test "validate: wide_2000" {
    try validateTreeBuild(buildWide2000, 2001);
}

test "validate: deep_16" {
    try validateTreeBuild(buildDeep16, 16);
}

test "validate: deep_32" {
    try validateTreeBuild(buildDeep32, 32);
}

test "validate: deep_64" {
    try validateTreeBuild(buildDeep64, 64);
}

test "validate: table_50x10" {
    // 1 container + 50 rows + 50*10 cells = 551
    try validateTreeBuild(buildTable50x10, 551);
}

test "validate: table_100x10" {
    // 1 container + 100 rows + 100*10 cells = 1101
    try validateTreeBuild(buildTable100x10, 1101);
}

test "validate: table_200x8" {
    // 1 container + 200 rows + 200*8 cells = 1801
    try validateTreeBuild(buildTable200x8, 1801);
}

test "validate: nested_list_20x50" {
    // 1 container + 20 groups + 20*50 items = 1021
    try validateTreeBuild(buildNestedList20x50, 1021);
}

test "validate: nested_list_50x20" {
    // 1 container + 50 groups + 50*20 items = 1051
    try validateTreeBuild(buildNestedList50x20, 1051);
}

test "validate: hitTest returns valid node" {
    var tree = DispatchTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = buildTable50x10(&tree);
    assignBounds(&tree);

    const result = tree.hitTest(500.0, 500.0);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.isValid());
}

test "validate: reset clears nodes" {
    var tree = DispatchTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = buildWide100(&tree);
    try std.testing.expect(tree.nodeCount() == 101);

    tree.reset();
    try std.testing.expect(tree.nodeCount() == 0);
}

test "validate: markDirty deduplication" {
    var entities = EntityMap.init(std.testing.allocator);
    defer entities.deinit();

    const Counter = struct { value: u32 };
    const e1 = try entities.new(Counter, .{ .value = 1 });

    entities.markDirty(e1.id);
    entities.markDirty(e1.id);
    entities.markDirty(e1.id);

    // Should still process correctly regardless of duplicate handling.
    const any_dirty = entities.processNotifications();
    _ = any_dirty;
}

// =============================================================================
// Main Entry Point (for benchmark executable)
// =============================================================================

/// Print a benchmark result and record it in the JSON reporter.
fn collect(reporter: *bench.Reporter, result: BenchmarkResult) void {
    result.print();
    reporter.addEntry(bench.entry(
        result.name,
        result.operation_count,
        result.total_time_ns,
        result.iterations,
    ));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reporter = bench.Reporter.init("context");

    // =========================================================================
    // Tree Build Benchmarks
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Context Benchmarks — Tree Build (reset + pushNode/popNode)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    // Wide trees: expose O(n²) sibling walk in pushNode.
    collect(&reporter, benchTreeBuild(allocator, "wide_100", buildWide100));
    collect(&reporter, benchTreeBuild(allocator, "wide_500", buildWide500));
    collect(&reporter, benchTreeBuild(allocator, "wide_1000", buildWide1000));
    collect(&reporter, benchTreeBuild(allocator, "wide_2000", buildWide2000));

    std.debug.print("-" ** 105 ++ "\n", .{});

    // Deep trees: linear depth, no sibling walk cost.
    collect(&reporter, benchTreeBuild(allocator, "deep_16", buildDeep16));
    collect(&reporter, benchTreeBuild(allocator, "deep_32", buildDeep32));
    collect(&reporter, benchTreeBuild(allocator, "deep_64", buildDeep64));

    std.debug.print("-" ** 105 ++ "\n", .{});

    // Realistic trees: mixed width and depth.
    collect(&reporter, benchTreeBuild(allocator, "table_50x10", buildTable50x10));
    collect(&reporter, benchTreeBuild(allocator, "table_100x10", buildTable100x10));
    collect(&reporter, benchTreeBuild(allocator, "table_200x8", buildTable200x8));
    collect(&reporter, benchTreeBuild(allocator, "nested_list_20x50", buildNestedList20x50));
    collect(&reporter, benchTreeBuild(allocator, "nested_list_50x20", buildNestedList50x20));

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Hit Testing Benchmarks
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Context Benchmarks — Hit Testing (single hitTest call)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    collect(&reporter, benchHitTest(allocator, "hit_wide_100", buildWide100));
    collect(&reporter, benchHitTest(allocator, "hit_wide_1000", buildWide1000));
    collect(&reporter, benchHitTest(allocator, "hit_deep_32", buildDeep32));
    collect(&reporter, benchHitTest(allocator, "hit_deep_64", buildDeep64));
    collect(&reporter, benchHitTest(allocator, "hit_table_50x10", buildTable50x10));
    collect(&reporter, benchHitTest(allocator, "hit_table_100x10", buildTable100x10));
    collect(&reporter, benchHitTest(allocator, "hit_table_200x8", buildTable200x8));
    collect(&reporter, benchHitTest(allocator, "hit_nested_list_20x50", buildNestedList20x50));

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Reset Benchmarks
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Context Benchmarks — Reset (per-frame teardown)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    collect(&reporter, benchReset(allocator, "reset_wide_1000", buildWide1000));
    collect(&reporter, benchReset(allocator, "reset_deep_64", buildDeep64));
    collect(&reporter, benchReset(allocator, "reset_table_100x10", buildTable100x10));
    collect(&reporter, benchReset(allocator, "reset_table_200x8", buildTable200x8));

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Full Frame Benchmarks
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Context Benchmarks — Full Frame (reset + build + bounds + hitTest)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    collect(&reporter, benchFullFrame(allocator, "frame_wide_100", buildWide100));
    collect(&reporter, benchFullFrame(allocator, "frame_wide_500", buildWide500));
    collect(&reporter, benchFullFrame(allocator, "frame_wide_1000", buildWide1000));
    collect(&reporter, benchFullFrame(allocator, "frame_wide_2000", buildWide2000));

    std.debug.print("-" ** 105 ++ "\n", .{});

    collect(&reporter, benchFullFrame(allocator, "frame_deep_32", buildDeep32));
    collect(&reporter, benchFullFrame(allocator, "frame_deep_64", buildDeep64));

    std.debug.print("-" ** 105 ++ "\n", .{});

    collect(&reporter, benchFullFrame(allocator, "frame_table_50x10", buildTable50x10));
    collect(&reporter, benchFullFrame(allocator, "frame_table_100x10", buildTable100x10));
    collect(&reporter, benchFullFrame(allocator, "frame_table_200x8", buildTable200x8));
    collect(&reporter, benchFullFrame(allocator, "frame_nested_list_20x50", buildNestedList20x50));
    collect(&reporter, benchFullFrame(allocator, "frame_nested_list_50x20", buildNestedList50x20));

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Entity Benchmarks
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Context Benchmarks — Entity markDirty + processNotifications\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    // Unique dirtying (each entity marked once).
    collect(&reporter, benchMarkDirty(allocator, "dirty_unique_10", 10));
    collect(&reporter, benchMarkDirty(allocator, "dirty_unique_50", 50));
    collect(&reporter, benchMarkDirty(allocator, "dirty_unique_200", 200));
    collect(&reporter, benchMarkDirty(allocator, "dirty_unique_1000", 1000));

    std.debug.print("-" ** 105 ++ "\n", .{});

    // Duplicate dirtying (same entities marked multiple times).
    // Exposes the O(n) linear scan for duplicate detection.
    collect(&reporter, benchMarkDirtyDuplicates(allocator, "dirty_dupes_50x10", 50, 10));
    collect(&reporter, benchMarkDirtyDuplicates(allocator, "dirty_dupes_200x5", 200, 5));
    collect(&reporter, benchMarkDirtyDuplicates(allocator, "dirty_dupes_200x10", 200, 10));
    collect(&reporter, benchMarkDirtyDuplicates(allocator, "dirty_dupes_1000x5", 1000, 5));

    std.debug.print("=" ** 105 ++ "\n", .{});

    // =========================================================================
    // Scaling Analysis
    // =========================================================================

    std.debug.print("\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    std.debug.print("Gooey Context Benchmarks — Scaling Analysis (pushNode ns/op vs width)\n", .{});
    std.debug.print("=" ** 105 ++ "\n", .{});
    printHeader();
    std.debug.print("-" ** 105 ++ "\n", .{});

    // If pushNode is O(n²) via sibling walk, ns/op should grow linearly with width.
    // After fixing to O(1) with last_child, ns/op should be roughly constant.
    collect(&reporter, benchTreeBuild(allocator, "scaling_wide_50", buildWide50));
    collect(&reporter, benchTreeBuild(allocator, "scaling_wide_100", buildWide100));
    collect(&reporter, benchTreeBuild(allocator, "scaling_wide_200", buildWide200));
    collect(&reporter, benchTreeBuild(allocator, "scaling_wide_500", buildWide500));
    collect(&reporter, benchTreeBuild(allocator, "scaling_wide_1000", buildWide1000));
    collect(&reporter, benchTreeBuild(allocator, "scaling_wide_2000", buildWide2000));

    std.debug.print("=" ** 105 ++ "\n", .{});

    std.debug.print(
        \\
        \\Notes:
        \\  - Tree Build = reset() + pushNode/popNode tree construction.
        \\  - Hit Testing = single hitTest() call on a pre-built tree with bounds.
        \\  - Reset = reset() only (clearing nodes, listeners, maps).
        \\  - Full Frame = reset + build + assignBounds + hitTest (simulated render cycle).
        \\  - Entity = markDirty on N entities + processNotifications.
        \\  - Scaling Analysis: if pushNode ns/op grows with width, sibling walk is O(n²).
        \\    After O(1) last_child fix, ns/op should be constant across widths.
        \\  - Iterations are adaptive based on operation count.
        \\
    , .{});

    reporter.finish();
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

// Extra scaling wrappers.
fn buildWide50(tree: *DispatchTree) u32 {
    return buildWideTree(tree, 50);
}

fn buildWide200(tree: *DispatchTree) u32 {
    return buildWideTree(tree, 200);
}
