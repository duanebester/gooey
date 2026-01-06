//! UniformList - Virtualized list with uniform item height
//!
//! Only renders visible items + overdraw buffer. O(1) layout since
//! all items have the same height. Ideal for:
//! - File lists
//! - Log viewers
//! - Simple tables
//! - Any list where all rows have identical height
//!
//! ## Usage
//!
//! ```zig
//! // In your retained state:
//! var list_state = UniformListState.init(1000, 32.0);
//!
//! // In your render function:
//! b.uniformList("file-list", &list_state, .{ .height = 400 }, renderItem);
//!
//! fn renderItem(index: u32, b: *Builder) void {
//!     b.box(.{ .height = 32 }, .{ text("Item", .{}) });
//! }
//! ```
//!
//! ## With gaps between items:
//!
//! ```zig
//! var list_state = UniformListState.initWithGap(1000, 32.0, 4.0);
//! // Or set later:
//! list_state.setGap(4.0);
//! ```
//!
//! ## Memory: 72 bytes per UniformListState (no per-item allocation)

const std = @import("std");

// =============================================================================
// Constants (per CLAUDE.md - put a limit on everything)
// =============================================================================

/// Maximum visible items that can be rendered in a single frame.
/// Prevents runaway rendering. 128 items * ~40px = 5120px viewport max.
pub const MAX_VISIBLE_ITEMS: u32 = 128;

/// Default number of items to render above/below visible area.
/// Reduces pop-in when scrolling quickly.
pub const DEFAULT_OVERDRAW_ITEMS: u32 = 3;

/// Default viewport height when none specified (pixels).
/// Used as fallback in builder when no explicit height is set.
pub const DEFAULT_VIEWPORT_HEIGHT: f32 = 300.0;

// =============================================================================
// Scroll Strategy
// =============================================================================

/// Strategy for programmatic scrolling to a specific item
pub const ScrollStrategy = enum {
    /// Place item at top of viewport
    top,
    /// Place item at center of viewport
    center,
    /// Place item at bottom of viewport
    bottom,
    /// Scroll minimally to make item visible
    nearest,
};

/// Deferred scroll request - resolved during sync when viewport dimensions are accurate.
/// This avoids jitter from stale viewport_height_px values.
pub const PendingScrollRequest = union(enum) {
    /// Scroll to absolute pixel offset (clamped to valid range during sync)
    absolute: f32,
    /// Scroll to top (always 0)
    to_top,
    /// Scroll to bottom (resolved to maxScrollOffset during sync)
    to_end,
    /// Scroll to make item visible with strategy (resolved during sync)
    to_item: struct {
        index: u32,
        strategy: ScrollStrategy,
    },
};

// =============================================================================
// Visible Range
// =============================================================================

/// Range of visible items [start, end)
pub const VisibleRange = struct {
    start: u32,
    end: u32,

    /// Number of items in range
    pub inline fn count(self: VisibleRange) u32 {
        return self.end - self.start;
    }

    /// Check if range contains index
    pub inline fn contains(self: VisibleRange, index: u32) bool {
        return index >= self.start and index < self.end;
    }
};

// =============================================================================
// Uniform List State
// =============================================================================

/// Retained state for a virtualized uniform-height list.
/// Store this in your component/view state - do NOT recreate each frame.
pub const UniformListState = struct {
    /// Total number of items in the data source
    item_count: u32,
    /// Height of each item in pixels (uniform for all items)
    item_height_px: f32,
    /// Gap between items in pixels (for spacing calculations)
    gap_px: f32 = 0,
    /// Current scroll offset (pixels from top)
    scroll_offset_px: f32 = 0,
    /// Viewport height (updated during layout)
    viewport_height_px: f32 = 0,
    /// Number of items to render above/below visible area
    overdraw: u32 = DEFAULT_OVERDRAW_ITEMS,
    /// Pending programmatic scroll request (takes precedence over retained state).
    /// Set by scrollTo*, resolved and consumed by builder each frame.
    /// Uses PendingScrollRequest to defer calculations that need accurate viewport dimensions.
    pending_scroll: ?PendingScrollRequest = null,

    const Self = @This();

    /// Initialize with item count and uniform height.
    /// item_height_px must be > 0.
    pub fn init(item_count: u32, item_height_px: f32) Self {
        std.debug.assert(item_height_px > 0);
        return .{
            .item_count = item_count,
            .item_height_px = item_height_px,
        };
    }

    /// Initialize with item count, uniform height, and gap between items.
    /// item_height_px must be > 0, gap_px must be >= 0.
    pub fn initWithGap(item_count: u32, item_height_px: f32, gap_px: f32) Self {
        std.debug.assert(item_height_px > 0);
        std.debug.assert(gap_px >= 0);
        return .{
            .item_count = item_count,
            .item_height_px = item_height_px,
            .gap_px = gap_px,
        };
    }

    /// Effective row height including gap (item height + gap).
    /// Used for position calculations.
    inline fn rowStride(self: *const Self) f32 {
        return self.item_height_px + self.gap_px;
    }

    /// Calculate visible range [start, end) - O(1)
    /// Returns indices of items to render (inclusive start, exclusive end)
    pub fn visibleRange(self: *const Self) VisibleRange {
        std.debug.assert(self.item_height_px > 0);

        if (self.item_count == 0) {
            return .{ .start = 0, .end = 0 };
        }

        const stride = self.rowStride();

        // First visible item index
        const first_visible = @as(u32, @intFromFloat(
            @floor(self.scroll_offset_px / stride),
        ));

        // Number of items that fit in viewport (ceiling + 1 for partial)
        const visible_count = @as(u32, @intFromFloat(
            @ceil(self.viewport_height_px / stride),
        )) + 1;

        // Apply overdraw and clamp to valid range
        const start = first_visible -| self.overdraw;
        const raw_end = first_visible +| visible_count +| self.overdraw;
        const end = @min(raw_end, self.item_count);

        // Assert we're not trying to render too many items
        std.debug.assert(end - start <= MAX_VISIBLE_ITEMS);

        return .{ .start = start, .end = end };
    }

    /// Total content height including gaps - O(1)
    /// Formula: (item_count * item_height) + ((item_count - 1) * gap)
    /// Equivalent to: (item_count * stride) - gap (for item_count > 0)
    pub inline fn contentHeight(self: *const Self) f32 {
        if (self.item_count == 0) return 0;
        const items_height = @as(f32, @floatFromInt(self.item_count)) * self.item_height_px;
        const gaps_height = @as(f32, @floatFromInt(self.item_count -| 1)) * self.gap_px;
        return items_height + gaps_height;
    }

    /// Maximum scroll offset (content height - viewport height, clamped to 0)
    pub inline fn maxScrollOffset(self: *const Self) f32 {
        return @max(0, self.contentHeight() - self.viewport_height_px);
    }

    /// Get Y position of an item's top edge - O(1)
    /// Accounts for gaps between items.
    pub inline fn itemTopY(self: *const Self, index: u32) f32 {
        return @as(f32, @floatFromInt(index)) * self.rowStride();
    }

    /// Get the item index at a given Y position - O(1)
    pub fn itemAtY(self: *const Self, y: f32) u32 {
        std.debug.assert(self.item_height_px > 0);
        if (y < 0) return 0;
        if (self.item_count == 0) return 0;
        const index = @as(u32, @intFromFloat(y / self.rowStride()));
        return @min(index, self.item_count -| 1);
    }

    /// Calculate spacer height for items above visible range.
    /// Accounts for gaps correctly.
    pub fn topSpacerHeight(self: *const Self, range: VisibleRange) f32 {
        if (range.start == 0) return 0;
        // Height = (start items * item_height) + (start gaps)
        const items = @as(f32, @floatFromInt(range.start)) * self.item_height_px;
        const gaps = @as(f32, @floatFromInt(range.start)) * self.gap_px;
        return items + gaps;
    }

    /// Calculate spacer height for items below visible range.
    /// Accounts for gaps correctly.
    pub fn bottomSpacerHeight(self: *const Self, range: VisibleRange) f32 {
        const items_below = self.item_count -| range.end;
        if (items_below == 0) return 0;
        // Height = (remaining items * item_height) + (remaining - 1 gaps)
        // But we also need the gap after the last visible item
        const items = @as(f32, @floatFromInt(items_below)) * self.item_height_px;
        const gaps = @as(f32, @floatFromInt(items_below)) * self.gap_px;
        return items + gaps;
    }

    /// Scroll to item index with specified strategy.
    /// The actual scroll offset is computed during sync when viewport dimensions are accurate.
    pub fn scrollToItem(self: *Self, index: u32, strategy: ScrollStrategy) void {
        if (index >= self.item_count) return;

        // For .top strategy, we can compute immediately (doesn't need viewport_height)
        if (strategy == .top) {
            const offset = std.math.clamp(self.itemTopY(index), 0, self.maxScrollOffset());
            self.pending_scroll = .{ .absolute = offset };
            return;
        }

        // Other strategies need accurate viewport_height - defer to sync time
        self.pending_scroll = .{ .to_item = .{ .index = index, .strategy = strategy } };
    }

    /// Resolve a to_item scroll request with current viewport dimensions.
    /// Called by builder during sync when viewport_height_px is accurate.
    pub fn resolveScrollToItem(self: *Self, index: u32, strategy: ScrollStrategy) f32 {
        if (index >= self.item_count) return self.scroll_offset_px;

        const item_top = self.itemTopY(index);
        const item_bottom = item_top + self.item_height_px;
        const viewport_bottom = self.scroll_offset_px + self.viewport_height_px;

        const new_offset: f32 = switch (strategy) {
            .top => item_top,
            .center => item_top - (self.viewport_height_px / 2) + (self.item_height_px / 2),
            .bottom => item_bottom - self.viewport_height_px,
            .nearest => blk: {
                // Already fully visible? Don't scroll
                if (item_top >= self.scroll_offset_px and item_bottom <= viewport_bottom) {
                    break :blk self.scroll_offset_px;
                }
                // Scroll minimally to reveal
                if (item_top < self.scroll_offset_px) {
                    break :blk item_top; // Scroll up
                }
                break :blk item_bottom - self.viewport_height_px; // Scroll down
            },
        };

        return std.math.clamp(new_offset, 0, self.maxScrollOffset());
    }

    /// Scroll by delta (e.g., from scroll wheel)
    pub fn scrollBy(self: *Self, delta_y: f32) void {
        const clamped = std.math.clamp(
            self.scroll_offset_px + delta_y,
            0,
            self.maxScrollOffset(),
        );
        self.scroll_offset_px = clamped;
        self.pending_scroll = .{ .absolute = clamped };
    }

    /// Scroll to absolute position
    pub fn scrollTo(self: *Self, offset: f32) void {
        const clamped = std.math.clamp(offset, 0, self.maxScrollOffset());
        self.scroll_offset_px = clamped;
        self.pending_scroll = .{ .absolute = clamped };
    }

    /// Scroll to top
    pub fn scrollToTop(self: *Self) void {
        self.scroll_offset_px = 0;
        self.pending_scroll = .to_top;
    }

    /// Scroll to bottom (resolved during sync when viewport dimensions are accurate)
    pub fn scrollToBottom(self: *Self) void {
        self.pending_scroll = .to_end;
    }

    /// Get scroll percentage (0.0 - 1.0)
    pub fn scrollPercent(self: *const Self) f32 {
        const max = self.maxScrollOffset();
        if (max <= 0) return 0;
        return self.scroll_offset_px / max;
    }

    /// Check if an item is currently visible (even partially)
    pub fn isItemVisible(self: *const Self, index: u32) bool {
        const range = self.visibleRange();
        return range.contains(index);
    }

    /// Update item count (e.g., when data changes).
    /// Automatically clamps scroll offset if necessary.
    pub fn setItemCount(self: *Self, count: u32) void {
        self.item_count = count;
        self.scroll_offset_px = @min(self.scroll_offset_px, self.maxScrollOffset());
    }

    /// Update item height (e.g., for zoom).
    /// Maintains scroll position as percentage.
    pub fn setItemHeight(self: *Self, height: f32) void {
        std.debug.assert(height > 0);
        const percent = self.scrollPercent();
        self.item_height_px = height;
        self.scroll_offset_px = percent * self.maxScrollOffset();
    }

    /// Update gap between items.
    /// Maintains scroll position as percentage.
    pub fn setGap(self: *Self, gap: f32) void {
        std.debug.assert(gap >= 0);
        const percent = self.scrollPercent();
        self.gap_px = gap;
        self.scroll_offset_px = percent * self.maxScrollOffset();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "UniformListState init and basic properties" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;

    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset_px);
    try std.testing.expectEqual(@as(f32, 3200), state.contentHeight());
    try std.testing.expectEqual(@as(f32, 3000), state.maxScrollOffset());
    try std.testing.expectEqual(@as(f32, 0), state.scrollPercent());
}

test "UniformListState initWithGap" {
    var state = UniformListState.initWithGap(100, 32.0, 4.0);
    state.viewport_height_px = 200;

    // Content height = (100 * 32) + (99 * 4) = 3200 + 396 = 3596
    try std.testing.expectEqual(@as(f32, 3596), state.contentHeight());
    try std.testing.expectEqual(@as(f32, 3396), state.maxScrollOffset());
}

test "UniformListState contentHeight with gap" {
    // 0 items
    var state0 = UniformListState.initWithGap(0, 32.0, 4.0);
    try std.testing.expectEqual(@as(f32, 0), state0.contentHeight());

    // 1 item (no gaps)
    var state1 = UniformListState.initWithGap(1, 32.0, 4.0);
    try std.testing.expectEqual(@as(f32, 32), state1.contentHeight());

    // 2 items (1 gap)
    var state2 = UniformListState.initWithGap(2, 32.0, 4.0);
    try std.testing.expectEqual(@as(f32, 68), state2.contentHeight()); // 64 + 4

    // 10 items (9 gaps)
    var state10 = UniformListState.initWithGap(10, 32.0, 4.0);
    try std.testing.expectEqual(@as(f32, 356), state10.contentHeight()); // 320 + 36
}

test "UniformListState visibleRange at top" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.overdraw = 2;

    const range = state.visibleRange();
    try std.testing.expectEqual(@as(u32, 0), range.start);
    // ceil(200/32) + 1 = 8, + overdraw 2 = 10
    try std.testing.expectEqual(@as(u32, 10), range.end);
    try std.testing.expectEqual(@as(u32, 10), range.count());
}

test "UniformListState visibleRange with gap" {
    var state = UniformListState.initWithGap(100, 32.0, 8.0);
    state.viewport_height_px = 200;
    state.overdraw = 0;

    // stride = 40px, viewport fits ceil(200/40)+1 = 6 items
    const range = state.visibleRange();
    try std.testing.expectEqual(@as(u32, 0), range.start);
    try std.testing.expectEqual(@as(u32, 6), range.end);
}

test "UniformListState visibleRange scrolled" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.overdraw = 2;
    state.scroll_offset_px = 320; // 10 items down

    const range = state.visibleRange();
    try std.testing.expectEqual(@as(u32, 8), range.start); // 10 - 2 overdraw
    try std.testing.expectEqual(@as(u32, 20), range.end); // 10 + 8 visible + 2 overdraw
}

test "UniformListState visibleRange at bottom" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.overdraw = 2;
    state.scroll_offset_px = 3000; // At max scroll

    const range = state.visibleRange();
    try std.testing.expect(range.end == 100);
    try std.testing.expect(range.contains(99));
}

test "UniformListState scrollToItem top strategy" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;

    state.scrollToItem(50, .top);
    // .top strategy can be computed immediately (doesn't need viewport_height)
    try std.testing.expect(state.pending_scroll != null);
    const pending = state.pending_scroll.?;
    try std.testing.expectEqual(PendingScrollRequest{ .absolute = 1600 }, pending);
}

test "UniformListState scrollToItem top strategy with gap" {
    var state = UniformListState.initWithGap(100, 32.0, 4.0);
    state.viewport_height_px = 200;

    state.scrollToItem(50, .top);
    // Item 50 top = 50 * 36 = 1800
    try std.testing.expect(state.pending_scroll != null);
    const pending = state.pending_scroll.?;
    try std.testing.expectEqual(PendingScrollRequest{ .absolute = 1800 }, pending);
}

test "UniformListState scrollToItem center strategy deferred" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;

    state.scrollToItem(50, .center);
    // .center strategy is deferred (needs viewport_height at resolve time)
    try std.testing.expect(state.pending_scroll != null);
    const pending = state.pending_scroll.?;
    try std.testing.expectEqual(PendingScrollRequest{ .to_item = .{ .index = 50, .strategy = .center } }, pending);
}

test "UniformListState resolveScrollToItem center strategy" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;

    // Test the resolve function directly (simulates what builder does during sync)
    const resolved = state.resolveScrollToItem(50, .center);
    // item_top - viewport/2 + item_height/2 = 1600 - 100 + 16 = 1516
    try std.testing.expectEqual(@as(f32, 1516), resolved);
}

test "UniformListState scrollToItem bottom strategy deferred" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;

    state.scrollToItem(50, .bottom);
    // .bottom strategy is deferred
    try std.testing.expect(state.pending_scroll != null);
    const pending = state.pending_scroll.?;
    try std.testing.expectEqual(PendingScrollRequest{ .to_item = .{ .index = 50, .strategy = .bottom } }, pending);
}

test "UniformListState resolveScrollToItem bottom strategy" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;

    const resolved = state.resolveScrollToItem(50, .bottom);
    // item_bottom - viewport = 1632 - 200 = 1432
    try std.testing.expectEqual(@as(f32, 1432), resolved);
}

test "UniformListState scrollToItem nearest - already visible" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.scroll_offset_px = 320; // Viewing items ~10-16

    // Test resolve directly - should return current scroll (item already visible)
    const resolved = state.resolveScrollToItem(12, .nearest);
    try std.testing.expectEqual(@as(f32, 320), resolved);
}

test "UniformListState scrollToItem nearest - scroll up" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.scroll_offset_px = 320;

    const resolved = state.resolveScrollToItem(5, .nearest);
    try std.testing.expectEqual(@as(f32, 160), resolved);
}

test "UniformListState scrollToItem nearest - scroll down" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.scroll_offset_px = 0;

    const resolved = state.resolveScrollToItem(20, .nearest);
    // item_bottom - viewport = 672 - 200 = 472
    try std.testing.expectEqual(@as(f32, 472), resolved);
}

test "UniformListState empty list" {
    var state = UniformListState.init(0, 32.0);
    state.viewport_height_px = 200;

    const range = state.visibleRange();
    try std.testing.expectEqual(@as(u32, 0), range.start);
    try std.testing.expectEqual(@as(u32, 0), range.end);
    try std.testing.expectEqual(@as(f32, 0), state.contentHeight());
    try std.testing.expectEqual(@as(f32, 0), state.maxScrollOffset());
}

test "UniformListState setItemCount clamps scroll" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.scroll_offset_px = 2000;

    state.setItemCount(20);
    // New max = 20*32 - 200 = 440
    try std.testing.expectEqual(@as(f32, 440), state.scroll_offset_px);
}

test "UniformListState setItemCount to zero" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.scroll_offset_px = 500;

    state.setItemCount(0);
    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset_px);
}

test "UniformListState itemAtY" {
    const state = UniformListState.init(100, 32.0);

    try std.testing.expectEqual(@as(u32, 0), state.itemAtY(0));
    try std.testing.expectEqual(@as(u32, 0), state.itemAtY(31));
    try std.testing.expectEqual(@as(u32, 1), state.itemAtY(32));
    try std.testing.expectEqual(@as(u32, 3), state.itemAtY(100));
    try std.testing.expectEqual(@as(u32, 99), state.itemAtY(5000)); // Clamped
}

test "UniformListState itemAtY with gap" {
    const state = UniformListState.initWithGap(100, 32.0, 8.0);

    // stride = 40px
    try std.testing.expectEqual(@as(u32, 0), state.itemAtY(0));
    try std.testing.expectEqual(@as(u32, 0), state.itemAtY(39));
    try std.testing.expectEqual(@as(u32, 1), state.itemAtY(40));
    try std.testing.expectEqual(@as(u32, 2), state.itemAtY(80));
}

test "UniformListState scrollBy" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;

    state.scrollBy(100);
    try std.testing.expectEqual(@as(f32, 100), state.scroll_offset_px);

    state.scrollBy(-200); // Would go negative
    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset_px);

    state.scrollBy(5000); // Would exceed max
    try std.testing.expectEqual(@as(f32, 3000), state.scroll_offset_px);
}

test "UniformListState isItemVisible" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;
    state.overdraw = 0;

    try std.testing.expect(state.isItemVisible(0));
    try std.testing.expect(state.isItemVisible(6));
    try std.testing.expect(!state.isItemVisible(50));

    state.scroll_offset_px = 1600;
    try std.testing.expect(!state.isItemVisible(0));
    try std.testing.expect(state.isItemVisible(50));
}

test "UniformListState topSpacerHeight" {
    const state = UniformListState.initWithGap(100, 32.0, 4.0);

    // Range starting at 0
    const range0 = VisibleRange{ .start = 0, .end = 10 };
    try std.testing.expectEqual(@as(f32, 0), state.topSpacerHeight(range0));

    // Range starting at 10: 10 items + 10 gaps = 10*32 + 10*4 = 360
    const range10 = VisibleRange{ .start = 10, .end = 20 };
    try std.testing.expectEqual(@as(f32, 360), state.topSpacerHeight(range10));
}

test "UniformListState bottomSpacerHeight" {
    const state = UniformListState.initWithGap(100, 32.0, 4.0);

    // Range ending at 100 (nothing below)
    const range_end = VisibleRange{ .start = 90, .end = 100 };
    try std.testing.expectEqual(@as(f32, 0), state.bottomSpacerHeight(range_end));

    // Range ending at 90 (10 items below): 10*32 + 10*4 = 360
    const range90 = VisibleRange{ .start = 80, .end = 90 };
    try std.testing.expectEqual(@as(f32, 360), state.bottomSpacerHeight(range90));
}

test "UniformListState setGap" {
    var state = UniformListState.init(100, 32.0);
    state.viewport_height_px = 200;

    try std.testing.expectEqual(@as(f32, 3200), state.contentHeight());

    state.setGap(4.0);
    try std.testing.expectEqual(@as(f32, 3596), state.contentHeight());
}

test "VisibleRange contains" {
    const range = VisibleRange{ .start = 10, .end = 20 };

    try std.testing.expect(!range.contains(9));
    try std.testing.expect(range.contains(10));
    try std.testing.expect(range.contains(15));
    try std.testing.expect(range.contains(19));
    try std.testing.expect(!range.contains(20));
}
