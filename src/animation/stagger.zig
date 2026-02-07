//! Stagger Animations
//!
//! A thin computation layer on top of the existing animation system that
//! enables cascading list/grid animations without manual delay math or
//! per-item ID formatting.
//!
//! - `StaggerConfig` — Per-group configuration (timing, direction, presets)
//! - `StaggerDirection` — Cascade order (forward, reverse, center-out, edges-in)
//! - `staggerItemId` — Combine base ID + index into a unique per-item hash
//! - `computeStaggerDelay` — Pure function: index × count × direction → delay ms
//!
//! No state is stored here. Each staggered item becomes a normal `AnimationState`
//! in the existing animation pool.

const std = @import("std");
const animation = @import("animation.zig");

// =============================================================================
// Limits (per CLAUDE.md: put a limit on everything)
// =============================================================================

/// Maximum items in a single stagger group.
pub const MAX_STAGGER_ITEMS: u32 = 512;

/// Maximum total stagger delay in milliseconds. Prevents a 1000-item list
/// from having a 50-second cascade.
pub const MAX_STAGGER_DELAY_MS: u32 = 2000;

// =============================================================================
// Types
// =============================================================================

pub const StaggerDirection = enum {
    /// First item animates first, last item last.
    forward,
    /// Last item animates first, first item last.
    reverse,
    /// Center items animate first, edges last.
    from_center,
    /// Edge items animate first, center last.
    from_edges,
};

pub const StaggerConfig = struct {
    /// Base animation config applied to each item.
    animation_config: animation.AnimationConfig = .{
        .duration_ms = 200,
        .easing = animation.Easing.easeOutCubic,
    },

    /// Delay between consecutive items in milliseconds.
    per_item_ms: u32 = 50,

    /// Stagger direction.
    direction: StaggerDirection = .forward,

    /// Maximum total delay across all items. 0 = use MAX_STAGGER_DELAY_MS.
    max_total_delay_ms: u32 = 0,

    // =========================================================================
    // Presets
    // =========================================================================

    /// Quick cascade, good for menu items.
    pub const fast = StaggerConfig{
        .per_item_ms = 30,
        .animation_config = .{ .duration_ms = 150 },
    };

    /// Standard list entry.
    pub const list = StaggerConfig{
        .per_item_ms = 50,
        .animation_config = .{
            .duration_ms = 200,
            .easing = animation.Easing.easeOutCubic,
        },
    };

    /// Slow reveal, good for hero sections.
    pub const reveal = StaggerConfig{
        .per_item_ms = 80,
        .animation_config = .{
            .duration_ms = 300,
            .easing = animation.Easing.easeOutQuint,
        },
    };

    /// Pop in from center, good for grids.
    pub const grid_pop = StaggerConfig{
        .per_item_ms = 40,
        .direction = .from_center,
        .animation_config = .{
            .duration_ms = 250,
            .easing = animation.Easing.easeOutBack,
        },
    };
};

// =============================================================================
// Core Functions
// =============================================================================

/// Combine a base animation ID hash with an item index to produce
/// a unique per-item ID. Uses xor + Murmur-style mixing to avoid collisions.
///
/// AnimationId 0 is reserved — remapped to 1 on collision (theoretically
/// possible but astronomically rare).
pub fn staggerItemId(base_id: u32, index: u32) u32 {
    std.debug.assert(index < MAX_STAGGER_ITEMS);

    // Murmur-style mix: xor with golden-ratio constant then multiply-shift
    var h = base_id ^ (index *% 0x9e3779b9);
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    // AnimationId 0 is reserved — remap on collision
    return if (h == 0) 1 else h;
}

/// Compute the delay in milliseconds for a specific item in a stagger group.
///
/// Pure function — no side effects, no allocations. The delay depends on
/// the item's position after applying the stagger direction, multiplied
/// by the per-item interval, clamped to the configured maximum.
pub fn computeStaggerDelay(
    index: u32,
    total_count: u32,
    config: StaggerConfig,
) u32 {
    std.debug.assert(total_count > 0);
    std.debug.assert(index < total_count);

    if (total_count == 1) return 0;

    const max_delay = if (config.max_total_delay_ms > 0)
        config.max_total_delay_ms
    else
        MAX_STAGGER_DELAY_MS;

    const position: u32 = switch (config.direction) {
        .forward => index,
        .reverse => total_count - 1 - index,
        .from_center => blk: {
            // Work in doubled space to avoid integer truncation on even counts.
            // For even counts, the two center items both get distance 0.
            const last = total_count - 1;
            const dist_x2 = if (index * 2 >= last) index * 2 - last else last - index * 2;
            break :blk dist_x2 / 2;
        },
        .from_edges => blk: {
            // Distance from nearest edge: 0 at edges, max in center.
            // Symmetric for both even and odd counts.
            break :blk @min(index, total_count - 1 - index);
        },
    };

    const raw_delay = position * config.per_item_ms;
    return @min(raw_delay, max_delay);
}

// =============================================================================
// Tests
// =============================================================================

test "stagger delay: forward direction" {
    const delay_0 = computeStaggerDelay(0, 5, .{ .per_item_ms = 50 });
    const delay_1 = computeStaggerDelay(1, 5, .{ .per_item_ms = 50 });
    const delay_4 = computeStaggerDelay(4, 5, .{ .per_item_ms = 50 });
    try std.testing.expectEqual(@as(u32, 0), delay_0);
    try std.testing.expectEqual(@as(u32, 50), delay_1);
    try std.testing.expectEqual(@as(u32, 200), delay_4);
}

test "stagger delay: reverse direction" {
    const delay_0 = computeStaggerDelay(0, 5, .{ .per_item_ms = 50, .direction = .reverse });
    const delay_4 = computeStaggerDelay(4, 5, .{ .per_item_ms = 50, .direction = .reverse });
    try std.testing.expectEqual(@as(u32, 200), delay_0); // First item has max delay
    try std.testing.expectEqual(@as(u32, 0), delay_4); // Last item has zero delay
}

test "stagger delay: from_center" {
    // 5 items, center is index 2
    const delay_2 = computeStaggerDelay(2, 5, .{ .per_item_ms = 50, .direction = .from_center });
    const delay_0 = computeStaggerDelay(0, 5, .{ .per_item_ms = 50, .direction = .from_center });
    const delay_4 = computeStaggerDelay(4, 5, .{ .per_item_ms = 50, .direction = .from_center });
    try std.testing.expectEqual(@as(u32, 0), delay_2); // Center = no delay
    try std.testing.expectEqual(@as(u32, 100), delay_0); // 2 away from center
    try std.testing.expectEqual(@as(u32, 100), delay_4); // 2 away from center
}

test "stagger delay: from_edges" {
    // 5 items: edges (0,4) animate first, center (2) animates last
    const delay_0 = computeStaggerDelay(0, 5, .{ .per_item_ms = 50, .direction = .from_edges });
    const delay_2 = computeStaggerDelay(2, 5, .{ .per_item_ms = 50, .direction = .from_edges });
    const delay_4 = computeStaggerDelay(4, 5, .{ .per_item_ms = 50, .direction = .from_edges });
    try std.testing.expectEqual(@as(u32, 0), delay_0); // Edge = no delay
    try std.testing.expectEqual(@as(u32, 100), delay_2); // Center = max delay
    try std.testing.expectEqual(@as(u32, 0), delay_4); // Edge = no delay
}

test "stagger delay respects max_total_delay_ms" {
    const delay = computeStaggerDelay(999, 1000, .{ .per_item_ms = 50, .max_total_delay_ms = 500 });
    try std.testing.expect(delay <= 500);
}

test "stagger item IDs are unique" {
    const base: u32 = 12345;
    const id_0 = staggerItemId(base, 0);
    const id_1 = staggerItemId(base, 1);
    const id_2 = staggerItemId(base, 2);
    try std.testing.expect(id_0 != id_1);
    try std.testing.expect(id_1 != id_2);
    try std.testing.expect(id_0 != id_2);
}

test "stagger item IDs are never zero" {
    // Zero is reserved — test a spread of inputs
    const bases = [_]u32{ 0, 1, 0xFFFFFFFF, 0xDEADBEEF, 42 };
    for (bases) |base| {
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            try std.testing.expect(staggerItemId(base, i) != 0);
        }
    }
}

test "stagger item IDs differ across base IDs" {
    const id_a = staggerItemId(100, 0);
    const id_b = staggerItemId(200, 0);
    try std.testing.expect(id_a != id_b);
}

test "single item stagger has zero delay" {
    const delay = computeStaggerDelay(0, 1, .{ .per_item_ms = 50 });
    try std.testing.expectEqual(@as(u32, 0), delay);
}

test "stagger presets are well-formed" {
    // Verify presets compile and have sensible values
    try std.testing.expect(StaggerConfig.fast.per_item_ms > 0);
    try std.testing.expect(StaggerConfig.fast.animation_config.duration_ms > 0);

    try std.testing.expect(StaggerConfig.list.per_item_ms > 0);
    try std.testing.expect(StaggerConfig.list.animation_config.duration_ms > 0);

    try std.testing.expect(StaggerConfig.reveal.per_item_ms > 0);
    try std.testing.expect(StaggerConfig.reveal.animation_config.duration_ms > 0);

    try std.testing.expect(StaggerConfig.grid_pop.per_item_ms > 0);
    try std.testing.expect(StaggerConfig.grid_pop.animation_config.duration_ms > 0);
    try std.testing.expectEqual(StaggerDirection.from_center, StaggerConfig.grid_pop.direction);
}

test "stagger delay: global MAX_STAGGER_DELAY_MS caps unbounded lists" {
    // 1000 items × 50ms = 49950ms raw, but capped at MAX_STAGGER_DELAY_MS (2000)
    const delay = computeStaggerDelay(999, 1000, .{ .per_item_ms = 50 });
    try std.testing.expect(delay <= MAX_STAGGER_DELAY_MS);
}

test "stagger delay: from_center symmetric for even count" {
    // 6 items: true center is between indices 2 and 3.
    // Both center-adjacent items get delay 0; edges are symmetric.
    const cfg = StaggerConfig{ .per_item_ms = 50, .direction = .from_center };
    const delay_0 = computeStaggerDelay(0, 6, cfg);
    const delay_1 = computeStaggerDelay(1, 6, cfg);
    const delay_2 = computeStaggerDelay(2, 6, cfg);
    const delay_3 = computeStaggerDelay(3, 6, cfg);
    const delay_4 = computeStaggerDelay(4, 6, cfg);
    const delay_5 = computeStaggerDelay(5, 6, cfg);
    // Symmetric: delay[i] == delay[count-1-i]
    try std.testing.expectEqual(delay_0, delay_5); // edges
    try std.testing.expectEqual(delay_1, delay_4); // inner
    try std.testing.expectEqual(delay_2, delay_3); // center pair
    // Cascade order: center first, edges last
    try std.testing.expectEqual(@as(u32, 0), delay_2);
    try std.testing.expectEqual(@as(u32, 0), delay_3);
    try std.testing.expectEqual(@as(u32, 50), delay_1);
    try std.testing.expectEqual(@as(u32, 50), delay_4);
    try std.testing.expectEqual(@as(u32, 100), delay_0);
    try std.testing.expectEqual(@as(u32, 100), delay_5);
}
