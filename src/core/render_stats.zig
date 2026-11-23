const std = @import("std");

pub const RenderStats = struct {
    shape_misses: u32 = 0,
    shape_time_ns: u64 = 0,
    shape_cache_hits: u32 = 0,

    const Self = @This();

    pub fn reset(self: *Self) void {
        self.* = .{};
    }

    pub inline fn recordShapeMiss(self: *Self, elapsed_ns: u64) void {
        self.shape_misses += 1;
        self.shape_time_ns += elapsed_ns;
    }

    pub inline fn recordShapeCacheHit(self: *Self) void {
        self.shape_cache_hits += 1;
    }
};

pub var frame_stats: RenderStats = .{};

pub fn beginFrame() void {
    frame_stats.reset();
}

test "RenderStats shape tracking" {
    var stats = RenderStats{};

    stats.recordShapeMiss(1_000_000);
    stats.recordShapeMiss(500_000);
    stats.recordShapeCacheHit();
    stats.recordShapeCacheHit();

    try std.testing.expectEqual(@as(u32, 2), stats.shape_misses);
    try std.testing.expectEqual(@as(u64, 1_500_000), stats.shape_time_ns);
    try std.testing.expectEqual(@as(u32, 2), stats.shape_cache_hits);
    stats.reset();
    try std.testing.expectEqual(@as(u32, 0), stats.shape_misses);
}
