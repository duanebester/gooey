//! Per-iteration timing accumulator shared by every benchmark harness.
//!
//! Each harness times its hot path across many iterations. Historically each
//! timed loop kept its own `total_time_ns` / `iterations` locals and summed
//! them by hand, so adding a new statistic meant touching ~30 loops across the
//! four `*/benchmarks.zig` files. `Sampler` centralizes that bookkeeping: the
//! loops feed it one `record(elapsed_ns)` per iteration, and a new statistic is
//! added here once — never threaded through the individual loops again.
//!
//! Why track the minimum: interference on a shared CI runner (scheduler
//! preemption, CPU migration, cache eviction, thermal throttling) only ever
//! *adds* time to a sample. The smallest observed iteration is therefore the
//! estimator least perturbed by that noise — the "best-of-N" the regression
//! gate wants, available for free since the harness already runs N timed
//! iterations. The mean is retained for human-facing context, but the gate
//! classifies on the min (see `bench/compare.zig`).

const std = @import("std");

/// Fixed-size, allocation-free accumulator over per-iteration timings.
///
/// `record` is the only mutator; the public fields are read directly by the
/// harness loop condition (e.g. `sampler.total_time_ns < MIN_SAMPLE_TIME_NS`)
/// and when constructing the result entry. All reads happen outside the timed
/// region, so the accumulator never perturbs the measurement it collects.
pub const Sampler = struct {
    /// Total wall-clock nanoseconds across all recorded iterations.
    total_time_ns: u64 = 0,

    /// Smallest single-iteration time observed, in nanoseconds. Initialized to
    /// the max sentinel so the first `record` always wins the `@min`; callers
    /// must record at least one sample before reading it via `minTimeNs`.
    min_time_ns: u64 = std.math.maxInt(u64),

    /// Number of iterations recorded.
    iterations: u32 = 0,

    /// Record one iteration's elapsed time. `elapsed_ns` may legitimately be
    /// zero when the work completes faster than the monotonic clock's
    /// resolution — that is still a valid (floored) sample, not an error.
    pub fn record(self: *Sampler, elapsed_ns: u64) void {
        self.total_time_ns += elapsed_ns;
        self.min_time_ns = @min(self.min_time_ns, elapsed_ns);
        self.iterations += 1;
        // The minimum can never exceed the running total once a sample exists,
        // and a recorded sample always advances the count past zero.
        std.debug.assert(self.min_time_ns <= self.total_time_ns);
        std.debug.assert(self.iterations > 0);
    }

    /// Minimum observed iteration time in nanoseconds. Asserts at least one
    /// sample has been recorded so the sentinel can never leak to a caller.
    pub fn minTimeNs(self: *const Sampler) u64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.min_time_ns != std.math.maxInt(u64));
        return self.min_time_ns;
    }

    /// Minimum per-operation nanoseconds: the best-observed iteration divided
    /// by the operations performed in one iteration. Mirrors the mean-based
    /// `timePerOpNs` so the two estimators are directly comparable.
    pub fn minPerOpNs(self: *const Sampler, operation_count: u32) f64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(operation_count > 0);
        const min_ns: f64 = @floatFromInt(self.minTimeNs());
        return min_ns / @as(f64, @floatFromInt(operation_count));
    }
};

test "Sampler: record accumulates total, count, and minimum" {
    var sampler: Sampler = .{};
    sampler.record(100);
    sampler.record(40);
    sampler.record(70);

    try std.testing.expectEqual(@as(u64, 210), sampler.total_time_ns);
    try std.testing.expectEqual(@as(u32, 3), sampler.iterations);
    try std.testing.expectEqual(@as(u64, 40), sampler.minTimeNs());
}

test "Sampler: minPerOpNs divides the best iteration by operation count" {
    var sampler: Sampler = .{};
    sampler.record(1000);
    sampler.record(800); // Best iteration.
    sampler.record(1200);

    // 800 ns over 16 ops = 50 ns/op.
    try std.testing.expectEqual(@as(f64, 50.0), sampler.minPerOpNs(16));
}

test "Sampler: a single zero-duration sample is valid and floors the min" {
    var sampler: Sampler = .{};
    sampler.record(0);

    try std.testing.expectEqual(@as(u64, 0), sampler.minTimeNs());
    try std.testing.expectEqual(@as(u32, 1), sampler.iterations);
}
