//! VirtualList - Virtualized list with variable item heights
//!
//! Unlike UniformList where all items have the same height, VirtualList
//! supports items with different heights. Heights are cached after rendering
//! for efficient scroll calculations.
//!
//! Best for:
//! - Chat messages (varying lengths)
//! - Expandable/collapsible rows
//! - Mixed content types with different heights
//! - Any list where row heights vary
//!
//! For uniform-height items, prefer UniformList for O(1) performance.
//!
//! ## Usage
//!
//! ```zig
//! // In your retained state:
//! var list_state = VirtualListState.init(1000, 32.0); // count, default height
//!
//! // In your render function - callback returns item height:
//! cx.virtualList("chat-list", &list_state, .{ .grow_height = true }, renderMessage);
//!
//! fn renderMessage(index: u32, cx: *Cx) f32 {
//!     const msg = messages[index];
//!     const height: f32 = if (msg.has_image) 120.0 else 48.0;
//!     cx.render(ui.box(.{ .height = height }, .{ ui.text(msg.text, .{}) }));
//!     return height; // Return actual rendered height
//! }
//! ```
//!
//! ## Memory: ~16.5 KB per VirtualListState (supports up to 4096 items)

const std = @import("std");

// =============================================================================
// Constants (per CLAUDE.md - put a limit on everything)
// =============================================================================

/// Maximum items supported in a virtual list.
/// Chosen to balance memory (16KB for heights) vs capability.
/// For larger lists, consider pagination or use UniformList with estimated height.
pub const MAX_VIRTUAL_LIST_ITEMS: u32 = 4096;

/// Maximum visible items that can be rendered in a single frame.
/// Prevents runaway rendering with very small items.
pub const MAX_VISIBLE_ITEMS: u32 = 256;

/// Default number of items to render above/below visible area.
/// Reduces pop-in when scrolling quickly.
pub const DEFAULT_OVERDRAW_ITEMS: u32 = 3;

/// Default viewport height when none specified (pixels).
pub const DEFAULT_VIEWPORT_HEIGHT: f32 = 300.0;

/// Sentinel value for unmeasured height (use default).
const UNMEASURED_HEIGHT: f32 = 0.0;

// =============================================================================
// Scroll Strategy (shared with UniformList)
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
pub const PendingScrollRequest = union(enum) {
    /// Scroll to absolute pixel offset
    absolute: f32,
    /// Scroll to top
    to_top,
    /// Scroll to bottom (resolved during sync)
    to_end,
    /// Scroll to make item visible with strategy
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
// Virtual List State
// =============================================================================

/// Retained state for a virtualized variable-height list.
/// Store this in your component/view state - do NOT recreate each frame.
///
/// Heights are cached as items are rendered. Unmeasured items use
/// `default_height_px` for layout estimates.
pub const VirtualListState = struct {
    /// Total number of items in the data source
    item_count: u32,

    /// Default height for items not yet measured (pixels)
    default_height_px: f32,

    /// Gap between items in pixels
    gap_px: f32 = 0,

    /// Current scroll offset (pixels from top)
    scroll_offset_px: f32 = 0,

    /// Viewport height (updated during layout)
    viewport_height_px: f32 = 0,

    /// Number of items to render above/below visible area
    overdraw: u32 = DEFAULT_OVERDRAW_ITEMS,

    /// Cached item heights. 0.0 means "not yet measured, use default".
    /// Index directly by item index. Memory: 16KB.
    heights: [MAX_VIRTUAL_LIST_ITEMS]f32 = [_]f32{UNMEASURED_HEIGHT} ** MAX_VIRTUAL_LIST_ITEMS,

    /// Pending programmatic scroll request.
    /// Set by scrollTo*, resolved and consumed by builder each frame.
    pending_scroll: ?PendingScrollRequest = null,

    const Self = @This();

    // =========================================================================
    // Initialization
    // =========================================================================

    /// Initialize with item count and default height for unmeasured items.
    /// Item count must be <= MAX_VIRTUAL_LIST_ITEMS.
    /// default_height_px must be > 0.
    pub fn init(item_count: u32, default_height_px: f32) Self {
        std.debug.assert(item_count <= MAX_VIRTUAL_LIST_ITEMS);
        std.debug.assert(default_height_px > 0);
        return .{
            .item_count = item_count,
            .default_height_px = default_height_px,
        };
    }

    /// Initialize with item count, default height, and gap between items.
    pub fn initWithGap(item_count: u32, default_height_px: f32, gap_px: f32) Self {
        std.debug.assert(item_count <= MAX_VIRTUAL_LIST_ITEMS);
        std.debug.assert(default_height_px > 0);
        std.debug.assert(gap_px >= 0);
        return .{
            .item_count = item_count,
            .default_height_px = default_height_px,
            .gap_px = gap_px,
        };
    }

    // =========================================================================
    // Height Management
    // =========================================================================

    /// Get the height of an item. Returns cached height or default if unmeasured.
    pub inline fn getHeight(self: *const Self, index: u32) f32 {
        if (index >= self.item_count) return self.default_height_px;
        if (index >= MAX_VIRTUAL_LIST_ITEMS) return self.default_height_px;

        const cached = self.heights[index];
        return if (cached == UNMEASURED_HEIGHT) self.default_height_px else cached;
    }

    /// Set the height of an item (called after rendering).
    /// Height must be > 0.
    pub fn setHeight(self: *Self, index: u32, height: f32) void {
        std.debug.assert(height > 0);
        if (index < MAX_VIRTUAL_LIST_ITEMS) {
            self.heights[index] = height;
        }
    }

    /// Check if an item's height has been measured.
    pub inline fn isMeasured(self: *const Self, index: u32) bool {
        if (index >= MAX_VIRTUAL_LIST_ITEMS) return false;
        return self.heights[index] != UNMEASURED_HEIGHT;
    }

    /// Clear all cached heights (e.g., after data change).
    /// Items will be re-measured on next render.
    pub fn clearHeights(self: *Self) void {
        @memset(&self.heights, UNMEASURED_HEIGHT);
    }

    /// Clear height for a specific item (e.g., content changed).
    pub fn clearHeight(self: *Self, index: u32) void {
        if (index < MAX_VIRTUAL_LIST_ITEMS) {
            self.heights[index] = UNMEASURED_HEIGHT;
        }
    }

    // =========================================================================
    // Layout Calculations - O(n) but bounded by MAX_VIRTUAL_LIST_ITEMS
    // =========================================================================

    /// Get Y position of an item's top edge.
    /// O(n) where n = index, but n <= MAX_VIRTUAL_LIST_ITEMS.
    pub fn itemTopY(self: *const Self, index: u32) f32 {
        if (index == 0) return 0;

        var y: f32 = 0;
        const limit = @min(index, self.item_count);
        var i: u32 = 0;
        while (i < limit) : (i += 1) {
            y += self.getHeight(i);
            y += self.gap_px;
        }
        return y;
    }

    /// Get the item index at a given Y position.
    /// O(n) where n = item_count.
    pub fn itemAtY(self: *const Self, y: f32) u32 {
        if (y <= 0) return 0;
        if (self.item_count == 0) return 0;

        var offset: f32 = 0;
        var i: u32 = 0;
        while (i < self.item_count) : (i += 1) {
            const h = self.getHeight(i);
            if (offset + h > y) return i;
            offset += h + self.gap_px;
        }
        return self.item_count -| 1;
    }

    /// Total content height including gaps.
    /// O(n) where n = item_count.
    pub fn contentHeight(self: *const Self) f32 {
        if (self.item_count == 0) return 0;

        var h: f32 = 0;
        var i: u32 = 0;
        while (i < self.item_count) : (i += 1) {
            h += self.getHeight(i);
        }
        // Add gaps between items (count - 1 gaps)
        if (self.item_count > 1) {
            h += @as(f32, @floatFromInt(self.item_count - 1)) * self.gap_px;
        }
        return h;
    }

    /// Maximum scroll offset (content height - viewport height, clamped to 0)
    pub inline fn maxScrollOffset(self: *const Self) f32 {
        return @max(0, self.contentHeight() - self.viewport_height_px);
    }

    /// Calculate visible range [start, end) including overdraw.
    /// O(n) where n = item_count.
    pub fn visibleRange(self: *const Self) VisibleRange {
        if (self.item_count == 0) {
            return .{ .start = 0, .end = 0 };
        }

        // Find first item that intersects viewport
        const start = self.itemAtY(self.scroll_offset_px);

        // Find last item that intersects viewport
        const viewport_bottom = self.scroll_offset_px + self.viewport_height_px;
        var end = start;
        var y = self.itemTopY(start);

        while (end < self.item_count) : (end += 1) {
            if (y >= viewport_bottom) break;
            y += self.getHeight(end) + self.gap_px;
        }

        // Apply overdraw and clamp
        const od_start = start -| self.overdraw;
        const od_end = @min(end +| self.overdraw, self.item_count);

        // Safety: don't render too many items
        const clamped_end = @min(od_end, od_start +| MAX_VISIBLE_ITEMS);

        return .{ .start = od_start, .end = clamped_end };
    }

    // =========================================================================
    // Spacer Heights (for virtualization)
    // =========================================================================

    /// Calculate spacer height for items above visible range.
    pub fn topSpacerHeight(self: *const Self, range: VisibleRange) f32 {
        if (range.start == 0) return 0;
        return self.itemTopY(range.start);
    }

    /// Calculate spacer height for items below visible range.
    pub fn bottomSpacerHeight(self: *const Self, range: VisibleRange) f32 {
        if (range.end >= self.item_count) return 0;

        const total = self.contentHeight();
        const visible_end_y = self.itemTopY(range.end);
        return @max(0, total - visible_end_y);
    }

    // =========================================================================
    // Scroll Control
    // =========================================================================

    /// Scroll to item index with specified strategy.
    pub fn scrollToItem(self: *Self, index: u32, strategy: ScrollStrategy) void {
        if (index >= self.item_count) return;

        // For .top strategy, we can compute immediately
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
        const item_height = self.getHeight(index);
        const item_bottom = item_top + item_height;
        const viewport_bottom = self.scroll_offset_px + self.viewport_height_px;

        const new_offset: f32 = switch (strategy) {
            .top => item_top,
            .center => item_top - (self.viewport_height_px / 2) + (item_height / 2),
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

    // =========================================================================
    // Data Management
    // =========================================================================

    /// Update item count (e.g., when data changes).
    /// Clamps scroll offset if necessary.
    /// Does NOT clear heights - call clearHeights() if items changed identity.
    pub fn setItemCount(self: *Self, count: u32) void {
        std.debug.assert(count <= MAX_VIRTUAL_LIST_ITEMS);
        self.item_count = count;
        self.scroll_offset_px = @min(self.scroll_offset_px, self.maxScrollOffset());
    }

    /// Update default height (e.g., for zoom/font change).
    /// Maintains scroll position as percentage.
    pub fn setDefaultHeight(self: *Self, height: f32) void {
        std.debug.assert(height > 0);
        const percent = self.scrollPercent();
        self.default_height_px = height;
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

    /// Reset to initial state (useful when data source completely changes).
    /// Clears all heights and resets scroll position.
    pub fn reset(self: *Self, item_count: u32, default_height: f32) void {
        std.debug.assert(item_count <= MAX_VIRTUAL_LIST_ITEMS);
        std.debug.assert(default_height > 0);
        self.item_count = item_count;
        self.default_height_px = default_height;
        self.scroll_offset_px = 0;
        self.pending_scroll = null;
        self.clearHeights();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "VirtualListState init and basic properties" {
    const state = VirtualListState.init(100, 32.0);
    try std.testing.expectEqual(@as(u32, 100), state.item_count);
    try std.testing.expectEqual(@as(f32, 32.0), state.default_height_px);
    try std.testing.expectEqual(@as(f32, 0), state.gap_px);
    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset_px);
}

test "VirtualListState initWithGap" {
    const state = VirtualListState.initWithGap(100, 32.0, 8.0);
    try std.testing.expectEqual(@as(u32, 100), state.item_count);
    try std.testing.expectEqual(@as(f32, 32.0), state.default_height_px);
    try std.testing.expectEqual(@as(f32, 8.0), state.gap_px);
}

test "VirtualListState getHeight returns default for unmeasured" {
    const state = VirtualListState.init(100, 32.0);
    try std.testing.expectEqual(@as(f32, 32.0), state.getHeight(0));
    try std.testing.expectEqual(@as(f32, 32.0), state.getHeight(50));
    try std.testing.expectEqual(@as(f32, 32.0), state.getHeight(99));
}

test "VirtualListState setHeight and getHeight" {
    var state = VirtualListState.init(100, 32.0);
    state.setHeight(5, 48.0);
    state.setHeight(10, 64.0);

    try std.testing.expectEqual(@as(f32, 32.0), state.getHeight(0));
    try std.testing.expectEqual(@as(f32, 48.0), state.getHeight(5));
    try std.testing.expectEqual(@as(f32, 64.0), state.getHeight(10));
    try std.testing.expectEqual(@as(f32, 32.0), state.getHeight(15));
}

test "VirtualListState isMeasured" {
    var state = VirtualListState.init(100, 32.0);
    try std.testing.expect(!state.isMeasured(0));

    state.setHeight(0, 48.0);
    try std.testing.expect(state.isMeasured(0));
    try std.testing.expect(!state.isMeasured(1));
}

test "VirtualListState clearHeight" {
    var state = VirtualListState.init(100, 32.0);
    state.setHeight(5, 48.0);
    try std.testing.expect(state.isMeasured(5));

    state.clearHeight(5);
    try std.testing.expect(!state.isMeasured(5));
    try std.testing.expectEqual(@as(f32, 32.0), state.getHeight(5));
}

test "VirtualListState contentHeight uniform" {
    const state = VirtualListState.init(10, 32.0);
    // 10 items * 32px = 320px (no gaps)
    try std.testing.expectEqual(@as(f32, 320.0), state.contentHeight());
}

test "VirtualListState contentHeight with gap" {
    const state = VirtualListState.initWithGap(10, 32.0, 8.0);
    // 10 items * 32px + 9 gaps * 8px = 320 + 72 = 392px
    try std.testing.expectEqual(@as(f32, 392.0), state.contentHeight());
}

test "VirtualListState contentHeight variable heights" {
    var state = VirtualListState.init(5, 32.0);
    state.setHeight(0, 40.0);
    state.setHeight(2, 60.0);
    state.setHeight(4, 20.0);
    // Heights: 40, 32, 60, 32, 20 = 184px
    try std.testing.expectEqual(@as(f32, 184.0), state.contentHeight());
}

test "VirtualListState itemTopY" {
    var state = VirtualListState.init(5, 32.0);
    state.setHeight(0, 40.0);
    state.setHeight(1, 50.0);

    try std.testing.expectEqual(@as(f32, 0.0), state.itemTopY(0));
    try std.testing.expectEqual(@as(f32, 40.0), state.itemTopY(1));
    try std.testing.expectEqual(@as(f32, 90.0), state.itemTopY(2)); // 40 + 50
    try std.testing.expectEqual(@as(f32, 122.0), state.itemTopY(3)); // 40 + 50 + 32
}

test "VirtualListState itemTopY with gap" {
    var state = VirtualListState.initWithGap(5, 32.0, 8.0);
    state.setHeight(0, 40.0);
    state.setHeight(1, 50.0);

    try std.testing.expectEqual(@as(f32, 0.0), state.itemTopY(0));
    try std.testing.expectEqual(@as(f32, 48.0), state.itemTopY(1)); // 40 + 8
    try std.testing.expectEqual(@as(f32, 106.0), state.itemTopY(2)); // 40 + 8 + 50 + 8
}

test "VirtualListState itemAtY" {
    var state = VirtualListState.init(5, 32.0);
    state.setHeight(0, 40.0);
    state.setHeight(1, 50.0);

    try std.testing.expectEqual(@as(u32, 0), state.itemAtY(0));
    try std.testing.expectEqual(@as(u32, 0), state.itemAtY(39));
    try std.testing.expectEqual(@as(u32, 1), state.itemAtY(40));
    try std.testing.expectEqual(@as(u32, 1), state.itemAtY(89));
    try std.testing.expectEqual(@as(u32, 2), state.itemAtY(90));
}

test "VirtualListState visibleRange at top" {
    var state = VirtualListState.init(100, 32.0);
    state.viewport_height_px = 100.0;
    state.scroll_offset_px = 0;
    state.overdraw = 2;

    const range = state.visibleRange();
    try std.testing.expectEqual(@as(u32, 0), range.start);
    // Visible: 0-3 (4 items fit in 100px), plus 2 overdraw below = 6
    try std.testing.expectEqual(@as(u32, 6), range.end);
}

test "VirtualListState visibleRange scrolled" {
    var state = VirtualListState.init(100, 32.0);
    state.viewport_height_px = 100.0;
    state.scroll_offset_px = 64.0; // 2 items scrolled
    state.overdraw = 2;

    const range = state.visibleRange();
    try std.testing.expectEqual(@as(u32, 0), range.start); // 2 - 2 overdraw = 0
    try std.testing.expectEqual(@as(u32, 8), range.end); // 2 + 4 visible + 2 overdraw = 8
}

test "VirtualListState visibleRange variable heights" {
    var state = VirtualListState.init(10, 32.0);
    state.setHeight(0, 100.0);
    state.setHeight(1, 100.0);
    state.viewport_height_px = 150.0;
    state.scroll_offset_px = 0;
    state.overdraw = 1;

    const range = state.visibleRange();
    try std.testing.expectEqual(@as(u32, 0), range.start);
    // Item 0: 100px, Item 1: 100px - both partially visible in 150px viewport
    // Plus 1 overdraw = 3
    try std.testing.expectEqual(@as(u32, 3), range.end);
}

test "VirtualListState empty list" {
    const state = VirtualListState.init(0, 32.0);
    try std.testing.expectEqual(@as(f32, 0), state.contentHeight());
    const range = state.visibleRange();
    try std.testing.expectEqual(@as(u32, 0), range.start);
    try std.testing.expectEqual(@as(u32, 0), range.end);
}

test "VirtualListState scrollToItem top strategy" {
    var state = VirtualListState.init(100, 32.0);
    state.viewport_height_px = 100.0;

    state.scrollToItem(10, .top);
    try std.testing.expect(state.pending_scroll != null);

    // Resolve - item 10 top is at 320px
    if (state.pending_scroll) |p| {
        switch (p) {
            .absolute => |offset| try std.testing.expectEqual(@as(f32, 320.0), offset),
            else => try std.testing.expect(false),
        }
    }
}

test "VirtualListState scrollToItem center strategy deferred" {
    var state = VirtualListState.init(100, 32.0);
    state.viewport_height_px = 100.0;

    state.scrollToItem(10, .center);
    try std.testing.expect(state.pending_scroll != null);

    // Should be deferred as to_item
    if (state.pending_scroll) |p| {
        switch (p) {
            .to_item => |item| {
                try std.testing.expectEqual(@as(u32, 10), item.index);
                try std.testing.expectEqual(ScrollStrategy.center, item.strategy);
            },
            else => try std.testing.expect(false),
        }
    }
}

test "VirtualListState resolveScrollToItem center" {
    var state = VirtualListState.init(100, 32.0);
    state.viewport_height_px = 100.0;

    // Item 10 at 320px, height 32px, center in 100px viewport
    // center = 320 - 50 + 16 = 286
    const offset = state.resolveScrollToItem(10, .center);
    try std.testing.expectEqual(@as(f32, 286.0), offset);
}

test "VirtualListState scrollToItem nearest - already visible" {
    var state = VirtualListState.init(100, 32.0);
    state.viewport_height_px = 100.0;
    state.scroll_offset_px = 320.0; // Item 10 at top

    // Item 10 is fully visible, should not scroll
    const offset = state.resolveScrollToItem(10, .nearest);
    try std.testing.expectEqual(@as(f32, 320.0), offset);
}

test "VirtualListState scrollBy" {
    var state = VirtualListState.init(100, 32.0);
    state.viewport_height_px = 100.0;
    state.scroll_offset_px = 100.0;

    state.scrollBy(50.0);
    try std.testing.expectEqual(@as(f32, 150.0), state.scroll_offset_px);

    state.scrollBy(-200.0);
    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset_px); // Clamped to 0
}

test "VirtualListState isItemVisible" {
    var state = VirtualListState.init(100, 32.0);
    state.viewport_height_px = 100.0;
    state.scroll_offset_px = 192.0; // Items 6+ visible (192/32 = 6)

    // With overdraw of 3, visible range is [3, 10+3] = [3, 13]
    try std.testing.expect(!state.isItemVisible(0)); // Above overdraw range
    try std.testing.expect(!state.isItemVisible(2)); // Still above
    try std.testing.expect(state.isItemVisible(3)); // In overdraw
    try std.testing.expect(state.isItemVisible(6)); // First truly visible
    try std.testing.expect(!state.isItemVisible(50)); // Below
}

test "VirtualListState topSpacerHeight" {
    var state = VirtualListState.init(100, 32.0);
    state.setHeight(0, 40.0);
    state.setHeight(1, 50.0);
    state.viewport_height_px = 100.0;
    state.scroll_offset_px = 90.0; // Start at item 2
    state.overdraw = 0; // No overdraw for cleaner test

    const range = state.visibleRange();
    const spacer = state.topSpacerHeight(range);
    // Items 0 (40px) + 1 (50px) = 90px before item 2
    try std.testing.expectEqual(@as(f32, 90.0), spacer);
}

test "VirtualListState bottomSpacerHeight" {
    var state = VirtualListState.init(10, 32.0);
    state.setHeight(0, 40.0);
    state.viewport_height_px = 100.0;
    state.scroll_offset_px = 0;
    state.overdraw = 0;

    const range = state.visibleRange();
    const total = state.contentHeight();
    const spacer = state.bottomSpacerHeight(range);
    // Total: 40 + 9*32 = 328px
    // Visible end at item ~4, so items 4-9 below
    try std.testing.expectEqual(@as(f32, 328.0), total);
    try std.testing.expect(spacer > 0);
}

test "VirtualListState setItemCount" {
    var state = VirtualListState.init(100, 32.0);
    state.scroll_offset_px = 1000.0;

    state.setItemCount(10);
    try std.testing.expectEqual(@as(u32, 10), state.item_count);
    // Scroll should be clamped to new max
    try std.testing.expect(state.scroll_offset_px <= state.maxScrollOffset());
}

test "VirtualListState setItemCount to zero" {
    var state = VirtualListState.init(100, 32.0);
    state.scroll_offset_px = 500.0;

    state.setItemCount(0);
    try std.testing.expectEqual(@as(u32, 0), state.item_count);
    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset_px);
}

test "VirtualListState setGap" {
    var state = VirtualListState.init(10, 32.0);
    try std.testing.expectEqual(@as(f32, 320.0), state.contentHeight());

    state.setGap(8.0);
    // 10 * 32 + 9 * 8 = 320 + 72 = 392
    try std.testing.expectEqual(@as(f32, 392.0), state.contentHeight());
}

test "VirtualListState reset" {
    var state = VirtualListState.init(100, 32.0);
    state.setHeight(0, 48.0);
    state.setHeight(1, 64.0);
    state.scroll_offset_px = 500.0;
    state.gap_px = 8.0;

    state.reset(50, 40.0);
    try std.testing.expectEqual(@as(u32, 50), state.item_count);
    try std.testing.expectEqual(@as(f32, 40.0), state.default_height_px);
    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset_px);
    try std.testing.expect(!state.isMeasured(0));
    try std.testing.expect(!state.isMeasured(1));
}

test "VirtualListState clearHeights" {
    var state = VirtualListState.init(100, 32.0);
    state.setHeight(0, 48.0);
    state.setHeight(50, 64.0);
    try std.testing.expect(state.isMeasured(0));
    try std.testing.expect(state.isMeasured(50));

    state.clearHeights();
    try std.testing.expect(!state.isMeasured(0));
    try std.testing.expect(!state.isMeasured(50));
}

test "VisibleRange contains" {
    const range = VisibleRange{ .start = 5, .end = 15 };
    try std.testing.expect(!range.contains(4));
    try std.testing.expect(range.contains(5));
    try std.testing.expect(range.contains(10));
    try std.testing.expect(range.contains(14));
    try std.testing.expect(!range.contains(15));
}

test "VisibleRange count" {
    const range = VisibleRange{ .start = 5, .end = 15 };
    try std.testing.expectEqual(@as(u32, 10), range.count());
}
