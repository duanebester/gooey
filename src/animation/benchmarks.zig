//! Animation Module Benchmarks
//!
//! Benchmark suite for the per-frame animation tick — the spring physics and
//! the `AnimationStore` dispatch that run on every animating window each frame.
//! The control-plane suites (`bench`, `bench-context`, `bench-core`,
//! `bench-text`) and the scene data-plane suite (`bench-scene`) leave the
//! animation engine unbenched; this suite fills that gap.
//!
//! Run as executable: zig build bench-animation
//! Quick tests only:  zig test src/animation/benchmarks.zig (validates physics
//!                    sanity + the steady-state zero-allocation invariant)
//!
//! Groups:
//!   - Spring step    — `stepSpring` RK4 integration at a fixed dt (the §20 pure
//!                      hot loop; the in-flight physics cost per spring)
//!   - Spring tick    — `tickSpring` on settled springs (the at-rest fast path:
//!                      one branch, zero physics — the "at-rest ≈ free" claim)
//!   - Store frame    — `beginFrame → springById×N → endFrame`, reported against
//!                      the 16.6 ms (60 Hz) / 8.3 ms (120 Hz) frame budget
//!   - Motion frame   — the same per-frame cycle through `springMotionById`
//!
//! Why this split: `spring.zig`'s own back-of-envelope claims (a) an in-flight
//! step is ~20 multiply-adds and (b) an at-rest spring costs one branch. The
//! step vs at-rest-tick groups quantify both halves of that claim directly. The
//! store-frame groups measure the realistic per-frame *dispatch* cost (the
//! hash-map lookup + tick funnel that `cx.animations.spring(...)` walks) and
//! gate the steady-state zero-allocation invariant: the pools grow during warmup
//! and must never touch the heap again once every spring is registered.
//!
//! Scope note: the store ticks via `tickSpring`, whose dt comes from the
//! monotonic clock. A benchmark frame completes well under one millisecond, so
//! the clock-derived dt rounds toward zero and the store path measures the
//! lookup + dispatch overhead rather than RK4 work. That separation is on
//! purpose (CLAUDE.md §8, control plane vs data plane): the RK4 cost lives in
//! the Spring-step group, the dispatch cost in the Store-frame group.

const std = @import("std");
const gooey = @import("gooey");
const bench = @import("bench");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Minimal `Instant.now()` / `.since()` shim over `std.Io.Clock.awake`, kept
/// local to the benchmark module so every sample site reads as a two-line
/// capture-then-diff instead of threading `io` through every benchmark
/// helper signature. `.awake` is the monotonic clock — deltas here can never
/// go negative regardless of NTP or sysadmin clock edits.
///
/// `std.Io` is a pair of pointers into a process-lifetime vtable, so the
/// per-call `global_single_threaded.io()` lookup compiles down to a pair of
/// constant pointer loads — effectively free.
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

const anim = gooey.animation;
const spring_mod = anim.spring;
const SpringState = anim.SpringState;
const SpringConfig = anim.SpringConfig;
const AnimationStore = anim.AnimationStore;
const SpringMotionConfig = anim.SpringMotionConfig;

const MAX_SPRINGS = spring_mod.MAX_SPRINGS;

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

/// Fixed integration step for the Spring-step group: one 60 Hz frame. Using a
/// fixed dt (rather than the wall clock) makes the RK4 cost deterministic and
/// independent of how fast the benchmark loop happens to run.
const FIXED_DT_SECONDS: f32 = 1.0 / 60.0;

/// Per-frame budgets in nanoseconds for the frame-budget summary.
const FRAME_BUDGET_60HZ_NS: f64 = 16_666_667.0;
const FRAME_BUDGET_120HZ_NS: f64 = 8_333_333.0;

/// Table width for benchmark output formatting (characters per row).
const TABLE_WIDTH = 99;
const TABLE_RULE: [TABLE_WIDTH]u8 = @splat('=');
const TABLE_SEPARATOR: [TABLE_WIDTH]u8 = @splat('-');

// =============================================================================
// Iteration Sample Collection and Percentile Computation
// =============================================================================

/// Per-iteration timing data for percentile analysis. Fixed capacity avoids
/// dynamic allocation during benchmark runs. Mirrors the scene/text suites so
/// every percentile-reporting suite shares one shape.
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
        std.debug.print(
            "| {s:<40} | {d:>7} | {d:>9.2} | {d:>9.2} | {d:>9.2} | {d:>6} |\n",
            .{ self.name, self.operation_count, self.timePerOpNs(), self.p50_per_op_ns, self.p99_per_op_ns, self.iterations },
        );
    }

    /// Frame-budget summary line: whole-frame time (avg + p99) in microseconds
    /// and avg as a percentage of the 60 Hz and 120 Hz budgets. This is the
    /// "do we fit the budget?" number, so it is reported in whole-frame units.
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

/// Assemble a result from the common runner outputs. Centralizes the invariant
/// checks so each runner ends with a single tail call.
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
// Spring State Seeding
// =============================================================================

/// Seed every spring in the array to an in-flight state (position 0, target 1).
/// `stepSpring` does a full RK4 evaluation on these regardless of how far they
/// have converged, so the Spring-step group needs no per-iteration reset — the
/// arithmetic cost is constant even after a spring settles.
fn initInFlightSprings(states: []SpringState, io: std.Io) void {
    std.debug.assert(states.len > 0);
    const config: SpringConfig = .{
        .target = 1.0,
        .initial_position = 0.0,
        .stiffness = 170.0,
        .damping = 26.0,
    };
    for (states) |*state| state.* = SpringState.init(io, config);
    // The seed must actually be in flight, else the step group would measure
    // a degenerate fixed point instead of real RK4 work.
    std.debug.assert(!states[0].at_rest);
}

/// Seed every spring to a settled (at-rest) state at its target. `tickSpring`
/// early-returns on these without reading the clock or stepping physics, which
/// is exactly the fast path the Spring-tick group measures.
fn initAtRestSprings(states: []SpringState, io: std.Io) void {
    std.debug.assert(states.len > 0);
    const config: SpringConfig = .{ .target = 1.0 };
    for (states) |*state| state.* = SpringState.initSettled(io, config);
    std.debug.assert(states[0].at_rest);
}

// =============================================================================
// Hot Loops (CLAUDE.md §20 — primitive args, no struct receiver)
// =============================================================================

/// Advance N springs by one fixed RK4 step. The pure in-flight physics cost.
fn stepSpringBatch(states: []SpringState, dt_seconds: f32) void {
    std.debug.assert(states.len > 0);
    std.debug.assert(dt_seconds > 0.0);
    for (states) |*state| spring_mod.stepSpring(state, dt_seconds);
}

/// Tick N springs, summing the returned positions so the work is observable.
/// For at-rest springs this exercises only the early-return fast path.
fn tickSpringSum(io: std.Io, states: []SpringState) f32 {
    std.debug.assert(states.len > 0);
    var sum: f32 = 0.0;
    for (states) |*state| {
        const handle = spring_mod.tickSpring(io, state);
        sum += handle.value;
    }
    return sum;
}

/// One store frame over N pre-registered springs: reset the per-frame active
/// counters, poll every spring (hash-map lookup + tick), close the frame. The
/// summed value keeps the polls from being optimized away.
fn runSpringFrame(store: *AnimationStore, count: u32, config: SpringConfig) f32 {
    std.debug.assert(count > 0);
    store.beginFrame();
    var sum: f32 = 0.0;
    var i: u32 = 0;
    while (i < count) : (i += 1) sum += store.springById(i, config).value;
    store.endFrame();
    return sum;
}

/// One store frame over N pre-registered spring-motions (covers `motion.zig`'s
/// `tickSpringMotion` + the store dispatch). `show` is held true so settled
/// motions stay in the `entered` phase — the idle steady state.
fn runSpringMotionFrame(store: *AnimationStore, count: u32, config: SpringMotionConfig) f32 {
    std.debug.assert(count > 0);
    store.beginFrame();
    var sum: f32 = 0.0;
    var i: u32 = 0;
    while (i < count) : (i += 1) sum += store.springMotionById(i, true, config).progress;
    store.endFrame();
    return sum;
}

// =============================================================================
// Benchmark Runners
// =============================================================================

/// Spring step: time one RK4 step across N in-flight springs. Reports ns per
/// spring stepped — the §7 back-of-envelope physics cost made concrete.
fn benchSpringStep(allocator: Allocator, comptime name: []const u8, count: u32) !BenchmarkResult {
    std.debug.assert(count > 0);

    const states = try allocator.alloc(SpringState, count);
    defer allocator.free(states);

    initInFlightSprings(states, time.benchIo());

    const warmup_iters = getWarmupIterations(count);
    const min_sample_iters = getMinSampleIterations(count);

    for (0..warmup_iters) |_| stepSpringBatch(states, FIXED_DT_SECONDS);

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        stepSpringBatch(states, FIXED_DT_SECONDS);
        const end = time.Instant.now();
        std.mem.doNotOptimizeAway(states[count - 1].position);

        const elapsed = end.since(start);
        total_time_ns += elapsed;
        samples.record(elapsed);
        iterations += 1;
    }

    const percentiles = samples.computePercentiles(count);
    return makeResult(name, count, total_time_ns, iterations, percentiles);
}

/// Spring tick (at rest): time `tickSpring` across N settled springs. Reports
/// ns per spring — the at-rest fast path that should be far below the RK4 cost.
fn benchSpringTickAtRest(allocator: Allocator, comptime name: []const u8, count: u32) !BenchmarkResult {
    std.debug.assert(count > 0);

    const states = try allocator.alloc(SpringState, count);
    defer allocator.free(states);

    const io = time.benchIo();
    initAtRestSprings(states, io);

    const warmup_iters = getWarmupIterations(count);
    const min_sample_iters = getMinSampleIterations(count);

    for (0..warmup_iters) |_| std.mem.doNotOptimizeAway(tickSpringSum(io, states));

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        const sum = tickSpringSum(io, states);
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

/// Store frame (springs): pre-register N idle springs, then time the per-frame
/// `beginFrame → springById×N → endFrame` cycle. Reports against frame budget.
fn benchStoreSpringFrame(allocator: Allocator, comptime name: []const u8, count: u32) !BenchmarkResult {
    std.debug.assert(count > 0);
    std.debug.assert(count <= MAX_SPRINGS);

    var store = AnimationStore.init(allocator, time.benchIo());
    defer store.deinit();

    // target == default initial_position (0) → springs are created settled, so
    // the steady-state poll exercises the at-rest tick + lookup, not physics.
    const config: SpringConfig = .{ .target = 0.0 };
    var i: u32 = 0;
    while (i < count) : (i += 1) std.mem.doNotOptimizeAway(store.springById(i, config).value);
    std.debug.assert(store.springs.count() == count);

    const warmup_iters = getWarmupIterations(count);
    const min_sample_iters = getMinSampleIterations(count);

    for (0..warmup_iters) |_| std.mem.doNotOptimizeAway(runSpringFrame(&store, count, config));

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        const sum = runSpringFrame(&store, count, config);
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

/// Store frame (spring-motions): pre-register N visible spring-motions, then
/// time the per-frame poll cycle. Covers `motion.zig` + store dispatch.
fn benchStoreSpringMotionFrame(allocator: Allocator, comptime name: []const u8, count: u32) !BenchmarkResult {
    std.debug.assert(count > 0);
    std.debug.assert(count <= MAX_SPRINGS);

    var store = AnimationStore.init(allocator, time.benchIo());
    defer store.deinit();

    // start_visible → created settled in the entered phase; holding show=true
    // keeps them idle, so the poll measures lookup + at-rest dispatch.
    const config: SpringMotionConfig = .{ .start_visible = true };
    var i: u32 = 0;
    while (i < count) : (i += 1) std.mem.doNotOptimizeAway(store.springMotionById(i, true, config).progress);
    std.debug.assert(store.spring_motions.count() == count);

    const warmup_iters = getWarmupIterations(count);
    const min_sample_iters = getMinSampleIterations(count);

    for (0..warmup_iters) |_| std.mem.doNotOptimizeAway(runSpringMotionFrame(&store, count, config));

    var total_time_ns: u64 = 0;
    var iterations: u32 = 0;
    var samples = IterationSamples.init();

    while (total_time_ns < MIN_SAMPLE_TIME_NS or iterations < min_sample_iters) {
        const start = time.Instant.now();
        const sum = runSpringMotionFrame(&store, count, config);
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

// =============================================================================
// Counting Allocator (zero-allocation invariant check)
// =============================================================================

/// Wraps a backing allocator and counts every vtable call. After the spring
/// pools grow to hold every registered spring, a steady-state frame must touch
/// the heap zero times (CLAUDE.md §2). This turns that belief into a checkable
/// fact in the validate tests below. Mirrors the scene suite's counter.
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
// Validation Tests (run with `zig test src/animation/benchmarks.zig`)
//
// These do not time anything — they assert the physics moves in the right
// direction, the at-rest tick is a genuine no-op on state, and the
// steady-state store frame allocates nothing.
// =============================================================================

test "validate: in-flight spring advances toward its target under stepping" {
    const io = time.benchIo();
    var states: [4]SpringState = undefined;
    initInFlightSprings(&states, io);

    // 120 fixed steps ≈ 2 s of simulated time; the spring must reach rest.
    var i: u32 = 0;
    while (i < 120) : (i += 1) stepSpringBatch(&states, FIXED_DT_SECONDS);

    try std.testing.expect(states[0].at_rest);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), states[0].position, 0.001);
}

test "validate: at-rest tick leaves spring state untouched" {
    const io = time.benchIo();
    var states: [4]SpringState = undefined;
    initAtRestSprings(&states, io);

    const value_before = states[0].position;
    const sum = tickSpringSum(io, &states);

    // Settled springs early-return: position is unchanged and the summed
    // value is exactly N × target (here 4 × 1.0).
    try std.testing.expect(states[0].at_rest);
    try std.testing.expectEqual(value_before, states[0].position);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), sum, 0.0001);
}

test "validate: steady-state spring frame performs zero heap allocations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counter = CountingAllocator{ .backing = gpa.allocator() };
    const allocator = counter.allocator();

    var store = AnimationStore.init(allocator, time.benchIo());
    defer store.deinit();

    const config: SpringConfig = .{ .target = 0.0 };
    const count: u32 = 64;

    // Registration grows the pool — those allocations happen before we measure.
    var i: u32 = 0;
    while (i < count) : (i += 1) std.mem.doNotOptimizeAway(store.springById(i, config).value);
    std.debug.assert(store.springs.count() == count);

    // Warm once more so any lazy first-use growth is paid before the gate.
    std.mem.doNotOptimizeAway(runSpringFrame(&store, count, config));

    const calls_before = counter.calls;

    // Steady state: every key already exists, so getOrPut returns the cached
    // slot and ticks early-return on the settled springs. Net heap: zero.
    var frame: u32 = 0;
    while (frame < 16) : (frame += 1) {
        std.mem.doNotOptimizeAway(runSpringFrame(&store, count, config));
    }

    try std.testing.expectEqual(calls_before, counter.calls);
}

test "validate: steady-state spring-motion frame performs zero heap allocations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counter = CountingAllocator{ .backing = gpa.allocator() };
    const allocator = counter.allocator();

    var store = AnimationStore.init(allocator, time.benchIo());
    defer store.deinit();

    const config: SpringMotionConfig = .{ .start_visible = true };
    const count: u32 = 64;

    var i: u32 = 0;
    while (i < count) : (i += 1) std.mem.doNotOptimizeAway(store.springMotionById(i, true, config).progress);
    std.debug.assert(store.spring_motions.count() == count);

    std.mem.doNotOptimizeAway(runSpringMotionFrame(&store, count, config));

    const calls_before = counter.calls;

    var frame: u32 = 0;
    while (frame < 16) : (frame += 1) {
        std.mem.doNotOptimizeAway(runSpringMotionFrame(&store, count, config));
    }

    try std.testing.expectEqual(calls_before, counter.calls);
}

// =============================================================================
// Main Entry Point (for benchmark executable)
// =============================================================================

/// Print a benchmark result and record it in the JSON reporter. Animation
/// benchmarks carry p50/p99 percentiles, so the entry uses the percentile
/// constructor; the regression gate still classifies on the min (best-of-N).
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

/// Record a frame result (no per-op table print — the frame groups print their
/// own whole-frame budget line via printFrameBudget).
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

    var reporter = bench.Reporter.init("animation", init.io, init.minimal.args.vector);

    // =========================================================================
    // Spring Step (RK4 physics — the in-flight cost per spring)
    // =========================================================================

    printSectionHeader("Gooey Animation Benchmarks — Spring Step (stepSpring RK4, fixed dt)");
    collect(&reporter, try benchSpringStep(allocator, "spring_step_256", 256));
    collect(&reporter, try benchSpringStep(allocator, "spring_step_1k", 1024));
    std.debug.print(TABLE_RULE ++ "\n", .{});

    // =========================================================================
    // Spring Tick (at-rest fast path — the "≈ free" claim)
    // =========================================================================

    printSectionHeader("Gooey Animation Benchmarks — Spring Tick (tickSpring on settled springs)");
    collect(&reporter, try benchSpringTickAtRest(allocator, "spring_tick_atrest_256", 256));
    collect(&reporter, try benchSpringTickAtRest(allocator, "spring_tick_atrest_1k", 1024));
    std.debug.print(TABLE_RULE ++ "\n", .{});

    // =========================================================================
    // Store Frame (per-frame dispatch over N pre-registered springs/motions)
    // =========================================================================

    printFrameHeader();
    collectFrame(&reporter, try benchStoreSpringFrame(allocator, "frame_springs_16", 16));
    collectFrame(&reporter, try benchStoreSpringFrame(allocator, "frame_springs_64", 64));
    collectFrame(&reporter, try benchStoreSpringFrame(allocator, "frame_springs_256", 256));
    collectFrame(&reporter, try benchStoreSpringMotionFrame(allocator, "frame_spring_motions_64", 64));
    collectFrame(&reporter, try benchStoreSpringMotionFrame(allocator, "frame_spring_motions_256", 256));
    std.debug.print(TABLE_RULE ++ "\n", .{});

    std.debug.print(
        \\
        \\Notes:
        \\  - Spring Step  = stepSpring RK4 integration at a fixed 1/60 s dt; the pure
        \\                   in-flight physics cost per spring (CLAUDE.md §20 hot loop).
        \\  - Spring Tick  = tickSpring on settled springs — the at-rest early return.
        \\                   Compare against Spring Step to size "at-rest ≈ free".
        \\  - Store Frame  = beginFrame -> springById/springMotionById x N -> endFrame,
        \\                   the per-frame dispatch (hash-map lookup + tick) over idle
        \\                   springs. 60Hz budget = 16.67 ms, 120Hz = 8.33 ms.
        \\  - Store ticks via the monotonic clock; a sub-ms benchmark frame rounds dt
        \\    toward zero, so Store Frame measures dispatch overhead, not RK4. The RK4
        \\    cost is the Spring Step group; active per-frame cost ≈ frame + N x step.
        \\  - ns/op and percentiles are per spring/motion; iterations are adaptive.
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

fn printFrameHeader() void {
    std.debug.print("\n", .{});
    std.debug.print(TABLE_RULE ++ "\n", .{});
    std.debug.print("Gooey Animation Benchmarks — Store Frame (beginFrame -> poll N -> endFrame)\n", .{});
    std.debug.print(TABLE_RULE ++ "\n", .{});
    std.debug.print("| {s:<28} | {s:>6} | {s:>13} | {s:>13} | {s:>6} | {s:>6} |\n", .{
        "Test",
        "Count",
        "Avg/frame",
        "p99/frame",
        "60Hz",
        "120Hz",
    });
    std.debug.print(TABLE_SEPARATOR ++ "\n", .{});
}
