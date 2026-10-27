//! Backend-independent accounting of the per-frame glyph, SVG and image instance
//! buffers a renderer reserves from `ResourceLimits.scene`. Three counters, no
//! allocation; each claim takes constant work. A renderer sizes each buffer from
//! `from_limits` and claims every batch before writing it, so a scene that
//! outgrows the renderer's budget stops with the pool name instead of overrunning
//! or regrowing the buffer. Quads and shadows use the renderer's primitive ring.
const std = @import("std");
const SceneLimits = @import("../core/limits.zig").SceneLimits;

pub const InstancePool = enum(u8) {
    glyphs,
    svgs,
    images,
};

pub const InstanceCounts = struct {
    counts: [3]u32 = @splat(0),

    pub fn from_limits(limits: *const SceneLimits) InstanceCounts {
        std.debug.assert(limits.check() == null);
        return .{ .counts = .{
            limits.glyph_count_frame_max,
            limits.svg_count_frame_max,
            limits.image_count_frame_max,
        } };
    }

    pub fn fits(
        self: *const InstanceCounts,
        budget: *const InstanceCounts,
        pool: InstancePool,
        requested: u32,
    ) bool {
        const index = @backingInt(pool);
        const capacity = budget.counts[index];
        const in_use = self.counts[index];
        if (in_use > capacity) return false;
        return requested <= capacity - in_use;
    }

    /// Claim `requested` instances and return the index of the first one, which is
    /// where the caller writes the batch in its frame buffer.
    pub fn claim(self: *InstanceCounts, budget: *const InstanceCounts, options: struct {
        pool: InstancePool,
        requested: u32,
        frame: u64,
    }) u32 {
        const index = @backingInt(options.pool);
        const capacity = budget.counts[index];
        if (!self.fits(budget, options.pool, options.requested)) {
            std.debug.panic(
                "Scene instance pool '{s}' exhausted: capacity {d} (ResourceLimits.scene), " ++
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
        const first = self.counts[index];
        std.debug.assert(first <= capacity);
        self.counts[index] += options.requested;
        std.debug.assert(self.counts[index] <= capacity);
        return first;
    }
};

test "instance claims return packed offsets and stop at exact boundaries" {
    // Two unequal claims fill each budget. The second claim must start where the
    // first ended. Check full, one past, integer overflow, then reuse the counters
    // as the next frame does.
    const budget = InstanceCounts{ .counts = .{ 7, 11, 13 } };
    var usage = InstanceCounts{};
    for (0..3) |_| {
        inline for (std.enums.values(InstancePool)) |pool| {
            const capacity = budget.counts[@backingInt(pool)];
            try std.testing.expect(usage.fits(&budget, pool, capacity));
            const first = usage.claim(&budget, .{ .pool = pool, .requested = capacity - 2, .frame = 7 });
            const second = usage.claim(&budget, .{ .pool = pool, .requested = 2, .frame = 7 });
            try std.testing.expectEqual(@as(u32, 0), first);
            try std.testing.expectEqual(capacity - 2, second);
            try std.testing.expectEqual(capacity, usage.counts[@backingInt(pool)]);
            try std.testing.expect(!usage.fits(&budget, pool, 1));
            try std.testing.expect(!usage.fits(&budget, pool, std.math.maxInt(u32)));
        }
        usage = .{};
    }
    // The pools are independent: filling glyphs leaves images empty.
    _ = usage.claim(&budget, .{ .pool = .glyphs, .requested = 7, .frame = 1 });
    try std.testing.expect(usage.fits(&budget, .images, 13));
}

test "from_limits mirrors the scene's glyph, SVG and image budgets" {
    const standard = InstanceCounts.from_limits(&SceneLimits.standard);
    try std.testing.expectEqual(SceneLimits.standard.glyph_count_frame_max, standard.counts[0]);
    try std.testing.expectEqual(SceneLimits.standard.svg_count_frame_max, standard.counts[1]);
    try std.testing.expectEqual(SceneLimits.standard.image_count_frame_max, standard.counts[2]);
}
