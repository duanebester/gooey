const std = @import("std");

pub const Sampler = struct {
    total_time_ns: u64 = 0,

    min_time_ns: u64 = std.math.maxInt(u64),

    iterations: u32 = 0,

    /// A zero sample is valid: work can complete below the clock's
    /// resolution — still a valid (floored) sample, not an error.
    pub fn record(self: *Sampler, elapsed_ns: u64) void {
        self.total_time_ns += elapsed_ns;
        self.min_time_ns = @min(self.min_time_ns, elapsed_ns);
        self.iterations += 1;
        std.debug.assert(self.min_time_ns <= self.total_time_ns);
        std.debug.assert(self.iterations > 0);
    }

    pub fn minTimeNs(self: *const Sampler) u64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.min_time_ns != std.math.maxInt(u64));
        return self.min_time_ns;
    }

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
    sampler.record(800);
    sampler.record(1200);

    try std.testing.expectEqual(@as(f64, 50.0), sampler.minPerOpNs(16));
}

test "Sampler: a single zero-duration sample is valid and floors the min" {
    var sampler: Sampler = .{};
    sampler.record(0);

    try std.testing.expectEqual(@as(u64, 0), sampler.minTimeNs());
    try std.testing.expectEqual(@as(u32, 1), sampler.iterations);
}
