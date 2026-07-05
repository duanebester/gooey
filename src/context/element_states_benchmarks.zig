//! Element-State Pool Benchmarks
//!
//! Benchmark suite for `context/element_states.zig` — the keyed pool that backs
//! `cx.with_element_state(...)` and holds every stateful widget's retained
//! state (`(id_hash, type_id) -> *S`). `bench-context` covers the dispatch
//! tree and entity map; this suite isolates the element-state pool, whose hot
//! path runs once per stateful widget per frame.
//!
//! Run as executable: zig build bench-element-states
//! Quick tests only:  zig test src/context/element_states_benchmarks.zig
//!                    (validates lookup correctness + the zero-alloc invariant)
//!
//! Groups:
//!   - Lookup vs occupancy — `get` hit cost at 8 / 64 / 512 / 4096 entries.
//!                           This is the headline number: `findIndex` is an
//!                           explicit O(count) linear scan, and this curve says
//!                           whether the scan stays cheap or needs a hash map.
//!   - Get-or-create hit   — `withElementState` on already-present keys; the
//!                           real per-frame call site, gated zero-allocation.
//!   - Insert + remove     — the miss path (`create(S)`) + teardown (`destroy`);
//!                           the control-plane churn cost, which *does* allocate.
//!
//! Why this split (CLAUDE.md §8, control vs data plane): the steady-state hot
//! path is a lookup on a present key and must be allocation-free; the miss path
//! is one `create(S)`. The lookup-vs-occupancy curve directly answers the
//! standing question in `findIndex`'s own comment — *"if a profile shows
//! otherwise we can swap in an AutoHashMap"* — the same way the scene suite's
//! sort measurement prescribed sort-keys-not-payloads.

const std = @import("std");
const gooey = @import("gooey");
const bench = @import("bench");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Minimal `Instant.now()` / `.since()` shim over `std.Io.Clock.awake`, kept
/// local to the benchmark module so every sample site reads as a two-line
/// capture-then-diff. `.awake` is the monotonic clock — deltas here can never
/// go negative regardless of NTP or sysadmin clock edits.
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

const context = gooey.context;
const ElementStates = context.ElementStates;
const MAX_ELEMENT_STATES = context.MAX_ELEMENT_STATES;

/// Payload stored in the pool for every benchmark. A bare `u64` keeps the
/// per-entry allocation tiny so the measurement reflects the pool's lookup and
/// slot bookkeeping, not the cost of constructing a fat widget state.
const BenchState = struct {
    value: u64,

    /// Comptime factory required by `withElementState`.
    pub fn defaultInit() BenchState {
        return .{ .value = 0 };
    }
};

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
const MAX_SAMPLE_COUNT: u32 = 4096;

/// Table width for benchmark output formatting (characters per row).
const TABLE_WIDTH = 99;
const TABLE_RULE: [TABLE_WIDTH]u8 = @splat('=');
const TABLE_SEPARATOR: [TABLE_WIDTH]u8 = @splat('-');

// =============================================================================
// Iteration Sample Collection and Percentile Computation
// =============================================================================

/// Per-iteration timing data for percentile analysis. Fixed capacity avoids
/// dynamic allocation during benchmark runs. Mirrors the scene/animation suites.
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

    /// Sort collected samples and extract min/p50/p99 percentiles as ns/op.
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
};

/// Assemble a result from the common runner outputs.
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

// =============================================================================
// Pool Lifecycle Helpers
//
// `ElementStates` embeds a 128 KiB entries array, so it is heap-allocated and
// initialised in place (CLAUDE.md §14) rather than returned by value.
// =============================================================================

/// Allocate + in-place-init an empty pool. Caller owns it via `destroyPool`.
fn createPool(allocator: Allocator) !*ElementStates {
    const pool = try allocator.create(ElementStates);
    pool.initInPlace(allocator);
    std.debug.assert(pool.len() == 0);
    return pool;
}

/// Tear down a pool's payloads and free the container.
fn destroyPool(allocator: Allocator, pool: *ElementStates) void {
    pool.deinit();
    allocator.destroy(pool);
}

/// Fill the pool with `occupancy` distinct keys (id_hash = 0..occupancy-1).
/// Keys are inserted in ascending order, so key `i` lands at slot `i`.
fn fillPool(pool: *ElementStates, occupancy: u32) !void {
    std.debug.assert(occupancy > 0);
    std.debug.assert(occupancy <= MAX_ELEMENT_STATES);
    var i: u32 = 0;
    while (i < occupancy) : (i += 1) {
        _ = try pool.withElementState(BenchState, i, BenchState.defaultInit);
    }
    std.debug.assert(pool.len() == occupancy);
}

// =============================================================================
// Hot Loops (CLAUDE.md §20 — primitive args, no struct receiver beyond *pool)
// =============================================================================

/// Look up every key once via `get`, summing payload values so the scan is not
/// optimized away. Average scanned position is occupancy/2, so ns/op tracks the
/// O(count) cost of `findIndex` directly.
fn getScanSum(pool: *ElementStates, occupancy: u32) u64 {
    std.debug.assert(occupancy > 0);
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < occupancy) : (i += 1) {
        // Keys 0..occupancy-1 are all present, so the lookup never misses.
        const ptr = pool.get(BenchState, i) orelse unreachable;
        sum +%= ptr.value;
    }
    return sum;
}

/// Look up every key once via `withElementState` (the real per-frame call site).
/// Every key is present, so this is pure get-on-hit — no allocation.
fn withHitSum(pool: *ElementStates, occupancy: u32) u64 {
    std.debug.assert(occupancy > 0);
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < occupancy) : (i += 1) {
        // Present keys never hit the miss path, so the error set is unreachable.
        const ptr = pool.withElementState(BenchState, i, BenchState.defaultInit) catch unreachable;
        sum +%= ptr.value;
    }
    return sum;
}

/// Insert `count` fresh keys (miss path: `create(S)`) then remove them all
/// (teardown: `destroy`). Leaves the pool empty for the next iteration.
fn churnInsertRemove(pool: *ElementStates, count: u32) void {
    std.debug.assert(count > 0);
    std.debug.assert(pool.len() == 0);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // The pool was empty and count <= capacity, so neither error can fire.
        _ = pool.withElementState(BenchState, i, BenchState.defaultInit) catch unreachable;
    }
    std.debug.assert(pool.len() == count);

    i = 0;
    while (i < count) : (i += 1) {
        const removed = pool.remove(BenchState, i);
        std.debug.assert(removed);
    }
    std.debug.assert(pool.len() == 0);
}

// =============================================================================
// Benchmark Runners
// =============================================================================

/// Lookup vs occupancy: fill to `occupancy`, then time one `get` per key.
/// Reports ns per lookup — the linear-scan cost at this fill level.
fn benchGetByOccupancy(allocator: Allocator, comptime name: []const u8, occupancy: u32) !BenchmarkResult {
    std.debug.assert(occupancy > 0);
    std.debug.assert(occupancy <= MAX_ELEMENT_STATES);

    const pool = try createPool(allocator);
    defer destroyPool(allocator, pool);

    try fillPool(pool, occupancy);

    const warmup_iters = getWarmupIterations(occupancy);
    const min_sample_iters = getMinSampleIterations(occupancy);

    for (0..warmup_iters) |_| std.mem.doNotOptimizeAway(getScanSum(pool, occupancy));

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        const sum = getScanSum(pool, occupancy);
        const end = time.Instant.now();
        std.mem.doNotOptimizeAway(sum);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(occupancy);
    return makeResult(name, occupancy, total_time_ns, iterations, percentiles);
}

/// Get-or-create hit: fill to `occupancy`, then time one `withElementState`
/// per present key. Reports ns per hit — the allocation-free steady-state path.
fn benchWithHit(allocator: Allocator, comptime name: []const u8, occupancy: u32) !BenchmarkResult {
    std.debug.assert(occupancy > 0);
    std.debug.assert(occupancy <= MAX_ELEMENT_STATES);

    const pool = try createPool(allocator);
    defer destroyPool(allocator, pool);

    try fillPool(pool, occupancy);

    const warmup_iters = getWarmupIterations(occupancy);
    const min_sample_iters = getMinSampleIterations(occupancy);

    for (0..warmup_iters) |_| std.mem.doNotOptimizeAway(withHitSum(pool, occupancy));

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        const sum = withHitSum(pool, occupancy);
        const end = time.Instant.now();
        std.mem.doNotOptimizeAway(sum);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(occupancy);
    return makeResult(name, occupancy, total_time_ns, iterations, percentiles);
}

/// Insert + remove churn: time a full `count`-key insert-then-remove cycle.
/// Reports ns per (insert+remove) pair — the control-plane allocate/free cost.
fn benchInsertRemove(allocator: Allocator, comptime name: []const u8, count: u32) !BenchmarkResult {
    std.debug.assert(count > 0);
    std.debug.assert(count <= MAX_ELEMENT_STATES);

    const pool = try createPool(allocator);
    defer destroyPool(allocator, pool);

    const warmup_iters = getWarmupIterations(count);
    const min_sample_iters = getMinSampleIterations(count);

    for (0..warmup_iters) |_| churnInsertRemove(pool, count);

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        churnInsertRemove(pool, count);
        const end = time.Instant.now();

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(count);
    return makeResult(name, count, total_time_ns, iterations, percentiles);
}

// =============================================================================
// Counting Allocator (zero-allocation invariant check)
// =============================================================================

/// Wraps a backing allocator and counts every vtable call. After the pool is
/// filled, a steady-state lookup loop must touch the heap zero times — the get
/// path never allocates (CLAUDE.md §2). Mirrors the scene/animation suites.
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
// Validation Tests (run with `zig test src/context/element_states_benchmarks.zig`)
// =============================================================================

test "validate: filled pool returns every key and stays dense" {
    const allocator = std.testing.allocator;

    const pool = try createPool(allocator);
    defer destroyPool(allocator, pool);

    const occupancy: u32 = 512;
    try fillPool(pool, occupancy);
    try std.testing.expectEqual(occupancy, pool.len());

    // Every inserted key resolves to a live slot.
    var i: u32 = 0;
    while (i < occupancy) : (i += 1) {
        try std.testing.expect(pool.get(BenchState, i) != null);
    }
    // A key past the fill level is genuinely absent.
    try std.testing.expect(pool.get(BenchState, occupancy) == null);
}

test "validate: insert + remove churn returns the pool to empty" {
    const allocator = std.testing.allocator;

    const pool = try createPool(allocator);
    defer destroyPool(allocator, pool);

    churnInsertRemove(pool, 256);
    try std.testing.expectEqual(@as(u32, 0), pool.len());
}

test "validate: steady-state lookup performs zero heap allocations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counter = CountingAllocator{ .backing = gpa.allocator() };
    const allocator = counter.allocator();

    const pool = try createPool(allocator);
    defer destroyPool(allocator, pool);

    const occupancy: u32 = 256;
    try fillPool(pool, occupancy);

    // Warm once so any lazy first-use cost is paid before the gate.
    std.mem.doNotOptimizeAway(getScanSum(pool, occupancy));
    std.mem.doNotOptimizeAway(withHitSum(pool, occupancy));

    const calls_before = counter.calls;

    // Steady state: get and withElementState on present keys are pure lookups.
    var iter: u32 = 0;
    while (iter < 16) : (iter += 1) {
        std.mem.doNotOptimizeAway(getScanSum(pool, occupancy));
        std.mem.doNotOptimizeAway(withHitSum(pool, occupancy));
    }

    try std.testing.expectEqual(calls_before, counter.calls);
}

// =============================================================================
// Main Entry Point (for benchmark executable)
// =============================================================================

/// Print a benchmark result and record it in the JSON reporter. Entries carry
/// p50/p99; the regression gate still classifies on the min (best-of-N).
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

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reporter = bench.Reporter.init("element-states", init.io, init.minimal.args.vector);

    // =========================================================================
    // Lookup vs Occupancy (the linear-scan cost curve)
    // =========================================================================

    printSectionHeader("Gooey Element-State Benchmarks — Lookup vs Occupancy (get hit, O(count) scan)");
    collect(&reporter, try benchGetByOccupancy(allocator, "get_occupancy_8", 8));
    collect(&reporter, try benchGetByOccupancy(allocator, "get_occupancy_64", 64));
    collect(&reporter, try benchGetByOccupancy(allocator, "get_occupancy_512", 512));
    collect(&reporter, try benchGetByOccupancy(allocator, "get_occupancy_4096", 4096));
    std.debug.print(TABLE_RULE ++ "\n", .{});

    // =========================================================================
    // Get-or-create Hit (the real per-frame call site, zero-alloc)
    // =========================================================================

    printSectionHeader("Gooey Element-State Benchmarks — Get-or-create Hit (withElementState on present keys)");
    collect(&reporter, try benchWithHit(allocator, "with_hit_64", 64));
    collect(&reporter, try benchWithHit(allocator, "with_hit_512", 512));
    std.debug.print(TABLE_RULE ++ "\n", .{});

    // =========================================================================
    // Insert + Remove (the allocating control-plane churn)
    // =========================================================================

    printSectionHeader("Gooey Element-State Benchmarks — Insert + Remove (create/destroy churn)");
    collect(&reporter, try benchInsertRemove(allocator, "insert_remove_64", 64));
    collect(&reporter, try benchInsertRemove(allocator, "insert_remove_512", 512));
    std.debug.print(TABLE_RULE ++ "\n", .{});

    std.debug.print(
        \\
        \\Notes:
        \\  - Lookup vs Occupancy = one get() per present key, averaged over scan
        \\    positions (mean position = occupancy/2). A flat ns/op means the linear
        \\    scan stays cheap; a rising curve is the signal to swap findIndex for a
        \\    hash map (see element_states.zig findIndex comment).
        \\  - Get-or-create Hit   = withElementState on present keys — the real frame
        \\    call site. Must match get() and allocate zero (gated in the tests).
        \\  - Insert + Remove     = create(S) miss path + remove() teardown; the only
        \\    group that touches the heap, reported per insert+remove pair.
        \\  - ns/op and percentiles are per lookup / per pair; iterations are adaptive.
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
    std.debug.print(TABLE_RULE ++ "\n", .{});
    std.debug.print("{s}\n", .{title});
    std.debug.print(TABLE_RULE ++ "\n", .{});
    printHeader();
    std.debug.print(TABLE_SEPARATOR ++ "\n", .{});
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
