//! Render statistics: text shaping work per build, which the debugger's
//! profiler shows. The text system records each shape cache miss with its time
//! and each hit; the debugger resets the counts when a build starts.

const std = @import("std");

pub const RenderStats = struct {
    shape_misses: u32 = 0,
    shape_time_ns: u64 = 0,
    shape_cache_hits: u32 = 0,

    const Self = @This();

    /// Reset all counters to zero (call at the start of a build).
    pub fn reset(self: *Self) void {
        self.* = .{};
    }

    /// Record a text shaping cache miss with timing
    pub inline fn recordShapeMiss(self: *Self, elapsed_ns: u64) void {
        self.shape_misses += 1;
        self.shape_time_ns += elapsed_ns;
    }

    /// Record a shape cache hit (no shaping needed)
    pub inline fn recordShapeCacheHit(self: *Self) void {
        self.shape_cache_hits += 1;
    }
};

/// The current build's counts. Shaping and the reset both run on the thread
/// that builds frames.
pub var frame_stats: RenderStats = .{};

/// Start a new build's counts.
pub fn beginFrame() void {
    frame_stats.reset();
}

test "RenderStats shape tracking" {
    var stats = RenderStats{};

    stats.recordShapeMiss(1_000_000); // 1ms
    stats.recordShapeMiss(500_000); // 0.5ms
    stats.recordShapeCacheHit();
    stats.recordShapeCacheHit();

    try std.testing.expectEqual(@as(u32, 2), stats.shape_misses);
    try std.testing.expectEqual(@as(u64, 1_500_000), stats.shape_time_ns);
    try std.testing.expectEqual(@as(u32, 2), stats.shape_cache_hits);
    stats.reset();
    try std.testing.expectEqual(@as(u32, 0), stats.shape_misses);
}
