//! Backend-independent accounting of source geometry, summed across frame draws.
//! Five counters, no allocation; each claim takes constant work. Byte expansion
//! belongs to the backend, not this contract. Repeated mesh instances count again.
const std = @import("std");
const SceneLimits = @import("../core/limits.zig").SceneLimits;

pub const GeometryPool = enum(u8) {
    path_vertices,
    path_indices,
    polyline_points,
    points,
    colored_points,
};

pub const GeometryCounts = struct {
    counts: [5]u32 = @splat(0),

    pub fn from_limits(limits: *const SceneLimits) GeometryCounts {
        std.debug.assert(limits.check() == null);
        return .{ .counts = .{
            limits.path_vertex_count_frame_max,
            limits.path_index_count_frame_max,
            limits.polyline_point_count_frame_max,
            limits.point_count_frame_max,
            limits.colored_point_count_frame_max,
        } };
    }

    pub fn fits(
        self: *const GeometryCounts,
        budget: *const GeometryCounts,
        pool: GeometryPool,
        requested: u32,
    ) bool {
        const index = @backingInt(pool);
        const capacity = budget.counts[index];
        const in_use = self.counts[index];
        if (in_use > capacity) return false;
        return requested <= capacity - in_use;
    }

    pub fn claim(self: *GeometryCounts, budget: *const GeometryCounts, options: struct {
        pool: GeometryPool,
        requested: u32,
        frame: u64,
    }) void {
        const index = @backingInt(options.pool);
        const capacity = budget.counts[index];
        if (!self.fits(budget, options.pool, options.requested)) {
            std.debug.panic(
                "Scene geometry pool '{s}' exhausted: capacity {d} (ResourceLimits.scene), " ++
                    "{d} in use, {d} requested, frame {d}.",
                .{
                    @tagName(options.pool),
                    capacity,
                    self.counts[index],
                    options.requested,
                    options.frame,
                },
            );
        }
        std.debug.assert(self.counts[index] <= capacity);
        self.counts[index] += options.requested;
        std.debug.assert(self.counts[index] <= capacity);
    }
};

test "aggregate claims preserve independent pools and exact boundaries" {
    // Two unequal claims fill each budget. Check empty/full, a whole oversized
    // draw and integer overflow, then reuse the counters as the next frame does.
    const budget = GeometryCounts{ .counts = .{ 7, 11, 13, 17, 19 } };
    var usage = GeometryCounts{};
    for (0..3) |_| {
        inline for (std.enums.values(GeometryPool)) |pool| {
            const capacity = budget.counts[@backingInt(pool)];
            try std.testing.expect(usage.fits(&budget, pool, capacity));
            usage.claim(&budget, .{ .pool = pool, .requested = capacity - 2, .frame = 7 });
            usage.claim(&budget, .{ .pool = pool, .requested = 2, .frame = 7 });
            try std.testing.expectEqual(capacity, usage.counts[@backingInt(pool)]);
            try std.testing.expect(!usage.fits(&budget, pool, 1));
            try std.testing.expect(!usage.fits(&budget, pool, std.math.maxInt(u32)));
        }
        usage = .{};
        try std.testing.expect(!usage.fits(&budget, .path_vertices, 8));
    }
}
