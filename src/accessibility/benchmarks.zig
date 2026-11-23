const std = @import("std");
const gooey = @import("gooey");
const bench = @import("bench");

const Allocator = std.mem.Allocator;

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

const a11y = gooey.internals.accessibility;
const Tree = a11y.Tree;
const fingerprint = a11y.fingerprint;
const Fingerprint = fingerprint.Fingerprint;

const capacity = a11y.TreeCapacity.standard;

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

const FRAME_BUDGET_60HZ_NS: f64 = 16_666_667.0;
const FRAME_BUDGET_120HZ_NS: f64 = 8_333_333.0;

const NAME_STRIDE: u32 = 20;

const TABLE_WIDTH = 99;

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
        std.debug.print(
            "| {s:<40} | {d:>7} | {d:>9.2} | {d:>9.2} | {d:>9.2} | {d:>6} |\n",
            .{ self.name, self.operation_count, self.timePerOpNs(), self.p50_per_op_ns, self.p99_per_op_ns, self.iterations },
        );
    }

    pub fn printFrameBudget(self: BenchmarkResult) void {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.operation_count > 0);
        const avg_ns: f64 = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        const p99_ns: f64 = self.p99_per_op_ns * @as(f64, @floatFromInt(self.operation_count));
        std.debug.print(
            "| {s:<28} | {d:>6} | {d:>10.2} us | {d:>10.2} us | {d:>6.2}% | {d:>6.2}% |\n",
            .{
                self.name,
                self.operation_count,
                avg_ns / 1000.0,
                p99_ns / 1000.0,
                100.0 * avg_ns / FRAME_BUDGET_60HZ_NS,
                100.0 * avg_ns / FRAME_BUDGET_120HZ_NS,
            },
        );
    }
};

fn makeResult(
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    percentiles: PercentileResult,
) BenchmarkResult {
    std.debug.assert(operation_count > 0);
    std.debug.assert(iterations > 0);
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

const NameTable = struct {
    backing: []u8,
    names: [][]const u8,
};

fn allocNames(allocator: Allocator, count: u32) !NameTable {
    std.debug.assert(count > 0);

    const backing = try allocator.alloc(u8, count * NAME_STRIDE);
    errdefer allocator.free(backing);

    const names = try allocator.alloc([]const u8, count);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const slot = backing[i * NAME_STRIDE ..][0..NAME_STRIDE];
        const written = std.fmt.bufPrint(slot, "a11y_elem_{d}", .{i}) catch unreachable;
        names[i] = written;
    }
    return .{ .backing = backing, .names = names };
}

fn freeNames(allocator: Allocator, table: NameTable) void {
    allocator.free(table.names);
    allocator.free(table.backing);
}

fn buildTree(tree: *Tree, names: [][]const u8, churn_count: u32, toggle: bool) void {
    std.debug.assert(names.len >= 1);
    std.debug.assert(churn_count <= names.len);

    _ = tree.pushElement(.{ .role = .group, .name = "a11y_root" });

    const child_count: u32 = @intCast(names.len);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        if (i < churn_count) {
            const value: []const u8 = if (toggle) "on" else "off";
            _ = tree.pushElement(.{ .role = .status, .name = names[i], .value = value });
        } else {
            _ = tree.pushElement(.{ .role = .button, .name = names[i] });
        }
        tree.popElement();
    }

    tree.popElement();
}

fn runDiffFrame(tree: *Tree, names: [][]const u8, churn_count: u32, toggle: bool) u32 {
    std.debug.assert(names.len >= 1);
    tree.beginFrame();
    buildTree(tree, names, churn_count, toggle);
    tree.endFrame();
    const dirty: u32 = @intCast(tree.getDirtyElements().len);
    const removed: u32 = @intCast(tree.getRemovedFingerprints().len);
    return dirty + removed;
}

fn fingerprintSum(count: u32, name: []const u8, parent: ?Fingerprint) u64 {
    std.debug.assert(count > 0);
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const position: u8 = @intCast(i % 255);
        const fp = fingerprint.compute(.button, name, parent, position);
        sum +%= fp.toU64();
    }
    return sum;
}

fn benchFingerprint(comptime name: []const u8, count: u32, with_parent: bool) BenchmarkResult {
    std.debug.assert(count > 0);

    const parent: ?Fingerprint = if (with_parent)
        fingerprint.compute(.group, "a11y_parent", null, 0)
    else
        null;
    const sample_name = "a11y_fingerprint_bench";

    const warmup_iters = getWarmupIterations(count);
    const min_sample_iters = getMinSampleIterations(count);

    for (0..warmup_iters) |_| std.mem.doNotOptimizeAway(fingerprintSum(count, sample_name, parent));

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        const sum = fingerprintSum(count, sample_name, parent);
        const end = time.Instant.now();
        std.mem.doNotOptimizeAway(sum);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(count);
    return makeResult(name, count, total_time_ns, iterations, percentiles);
}

fn benchFrameDiff(allocator: Allocator, comptime name: []const u8, child_count: u32, churn_count: u32) !BenchmarkResult {
    std.debug.assert(child_count > 0);
    std.debug.assert(churn_count <= child_count);
    std.debug.assert(child_count + 1 <= capacity.element_count_max);

    const table = try allocNames(allocator, child_count);
    defer freeNames(allocator, table);

    const tree = try allocator.create(Tree);
    defer allocator.destroy(tree);

    try tree.initInPlace(&capacity);
    defer tree.deinit();

    const operation_count = child_count + 1;
    const warmup_iters = getWarmupIterations(operation_count);
    const min_sample_iters = getMinSampleIterations(operation_count);

    var toggle = false;
    for (0..warmup_iters) |_| {
        std.mem.doNotOptimizeAway(runDiffFrame(tree, table.names, churn_count, toggle));
        toggle = !toggle;
    }

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        const changed = runDiffFrame(tree, table.names, churn_count, toggle);
        const end = time.Instant.now();
        toggle = !toggle;
        std.mem.doNotOptimizeAway(changed);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(operation_count);
    return makeResult(name, operation_count, total_time_ns, iterations, percentiles);
}

test "validate: a stable rebuild reports zero dirty after the first frame" {
    const allocator = std.testing.allocator;

    const table = try allocNames(allocator, 64);
    defer freeNames(allocator, table);

    const tree = try allocator.create(Tree);
    defer allocator.destroy(tree);

    try tree.initInPlace(&capacity);
    defer tree.deinit();

    _ = runDiffFrame(tree, table.names, 0, false);
    try std.testing.expectEqual(@as(usize, 65), tree.getDirtyElements().len);

    _ = runDiffFrame(tree, table.names, 0, false);
    try std.testing.expectEqual(@as(usize, 0), tree.getDirtyElements().len);
    try std.testing.expectEqual(@as(usize, 0), tree.getRemovedFingerprints().len);
}

test "validate: churn marks exactly the changed elements dirty" {
    const allocator = std.testing.allocator;

    const table = try allocNames(allocator, 64);
    defer freeNames(allocator, table);

    const tree = try allocator.create(Tree);
    defer allocator.destroy(tree);

    try tree.initInPlace(&capacity);
    defer tree.deinit();

    const churn_count: u32 = 8;

    _ = runDiffFrame(tree, table.names, churn_count, false);
    _ = runDiffFrame(tree, table.names, churn_count, false);
    const changed = runDiffFrame(tree, table.names, churn_count, true);

    try std.testing.expectEqual(@as(u32, churn_count), changed);
    try std.testing.expectEqual(@as(usize, 0), tree.getRemovedFingerprints().len);
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

fn collectFrame(reporter: *bench.Reporter, result: BenchmarkResult) void {
    reporter.addEntry(bench.entryWithPercentiles(
        result.name,
        result.operation_count,
        result.total_time_ns,
        result.iterations,
        result.min_per_op_ns,
        result.p50_per_op_ns,
        result.p99_per_op_ns,
    ));
    result.printFrameBudget();
    reporter.beginBenchmark();
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reporter = bench.Reporter.init("accessibility", init.io, init.minimal.args.vector);

    printSectionHeader("Gooey Accessibility Benchmarks — Fingerprint (fingerprint.compute)");
    collect(&reporter, benchFingerprint("fingerprint_flat_4k", 4000, false));
    collect(&reporter, benchFingerprint("fingerprint_parented_4k", 4000, true));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});

    printFrameHeader();
    collectFrame(&reporter, try benchFrameDiff(allocator, "frame_stable_64", 64, 0));
    collectFrame(&reporter, try benchFrameDiff(allocator, "frame_stable_256", 256, 0));
    collectFrame(&reporter, try benchFrameDiff(allocator, "frame_stable_1000", 1000, 0));
    collectFrame(&reporter, try benchFrameDiff(allocator, "frame_churn_256", 256, 32));
    collectFrame(&reporter, try benchFrameDiff(allocator, "frame_churn_1000", 1000, 125));
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});

    std.debug.print(
        \\
        \\Notes:
        \\  - Fingerprint = fingerprint.compute over N calls; the per-element hash
        \\    that beginFrame (snapshot) and endFrame (diff) both walk. ns/op = per call.
        \\  - Frame Diff  = beginFrame -> pushElement x N (+popElement) -> endFrame,
        \\    the full snapshot + rebuild + computeDirty/computeRemoved cycle. Reported
        \\    whole-frame; 60Hz budget = 16.67 ms, 120Hz = 8.33 ms.
        \\  - stable = identical content each frame (steady state, ~0 dirty after frame 1).
        \\    churn  = a fraction of live .status elements change value each frame, driving
        \\    the dirty-detection + auto-announce path.
        \\  - The tree reserves its tables once at init (`standard` profile), so there
        \\    is no per-frame zero-alloc gate to run here.
        \\  - operation_count = total elements (children + root); iterations are adaptive.
        \\
    , .{});

    reporter.finish();
}

fn printSectionHeader(comptime title: []const u8) void {
    comptime std.debug.assert(title.len > 0);
    comptime std.debug.assert(title.len < TABLE_WIDTH);
    std.debug.print("\n", .{});
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("{s}\n", .{title});
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
    printHeader();
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('-')) ++ "\n", .{});
}

fn printHeader() void {
    std.debug.print("| {s:<40} | {s:>7} | {s:>9} | {s:>9} | {s:>9} | {s:>6} |\n", .{
        "Test",
        "Ops",
        "ns/op",
        "p50",
        "p99",
        "Iters",
    });
}

fn printFrameHeader() void {
    std.debug.print("\n", .{});
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("Gooey Accessibility Benchmarks — Frame Diff (beginFrame -> build N -> endFrame)\n", .{});
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('=')) ++ "\n", .{});
    std.debug.print("| {s:<28} | {s:>6} | {s:>13} | {s:>13} | {s:>6} | {s:>6} |\n", .{
        "Test",
        "Elems",
        "Avg/frame",
        "p99/frame",
        "60Hz",
        "120Hz",
    });
    std.debug.print(&@as([TABLE_WIDTH]u8, @splat('-')) ++ "\n", .{});
}
