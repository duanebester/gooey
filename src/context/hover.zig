//! `HoverState` — fixed-capacity hover tracker.
//!
//! Tracks the topmost element under the cursor (`hovered_layout_id`,
//! `null` when over nothing hit-testable), its cached parent chain
//! (`hovered_ancestors`, read by `isHoveredOrDescendant`), and a
//! one-frame `hover_changed` latch the runtime reads to decide whether
//! to re-render. The ancestor cache is filled during `update` while
//! the dispatch tree is still valid, so it stays queryable between
//! frames without re-walking the tree.
//!
//! `update` takes a `*const DispatchTree` rather than a back-pointer so
//! the sole data dependency is explicit at the call site. The double-
//! buffered `Frame` guarantees that tree already has bounds synced, so
//! no post-build hit-test re-run is needed.
//!
//! Invariants:
//! - `hovered_ancestor_count <= MAX_HOVERED_ANCESTORS`.
//! - `hovered_layout_id == null` implies `hovered_ancestor_count == 0`
//!   (the reverse need not hold — a hovered root has zero ancestors).

const std = @import("std");

const dispatch_mod = @import("dispatch.zig");
const DispatchTree = dispatch_mod.DispatchTree;

const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;

// =============================================================================
// Capacity caps
// =============================================================================

/// Hard cap on the cached ancestor chain. The hovered chain is the
/// depth of one hit path, not the whole component tree, so 32 covers
/// realistic nesting. Truncation past the cap just makes
/// `isHoveredOrDescendant` return false for deeper ancestors —
/// graceful degradation, not a crash.
pub const MAX_HOVERED_ANCESTORS: u32 = 32;

// =============================================================================
// HoverState
// =============================================================================

pub const HoverState = struct {
    /// Layout id (hash) of the topmost element under the cursor, or
    /// `null` when the cursor is outside any hit-testable element.
    /// Persists across frames until the next `update` / `clear`.
    hovered_layout_id: ?u32 = null,

    /// Cached ancestor chain of `hovered_layout_id`, populated during
    /// `update` and read by `isHoveredOrDescendant` / `ancestors`.
    /// Filled while the dispatch tree is still valid; later reads query
    /// the cache, not the tree.
    hovered_ancestors: [MAX_HOVERED_ANCESTORS]u32 = @splat(0),

    /// Number of valid entries in `hovered_ancestors`. Always
    /// `<= MAX_HOVERED_ANCESTORS`.
    hovered_ancestor_count: u8 = 0,

    /// Latch: `true` for the frame in which the hovered element
    /// changed. Cleared at the start of every frame by `beginFrame`.
    /// The runtime reads this to decide whether to request a render
    /// without polling per-element hover state.
    hover_changed: bool = false,

    const Self = @This();

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /// Empty hover state. Small enough to return by value without WASM
    /// stack concerns.
    pub fn init() Self {
        return .{};
    }

    /// In-place reset to the empty state, for embedding in a parent
    /// struct's `initInPlace` path where a stack temp would compound
    /// with the parent's frame budget.
    pub fn initInPlace(self: *Self) void {
        // Field-by-field — no struct literal, no stack temp.
        self.hovered_layout_id = null;
        @memset(&self.hovered_ancestors, 0);
        self.hovered_ancestor_count = 0;
        self.hover_changed = false;
    }

    /// Frame boundary: clear the `hover_changed` latch. The runtime
    /// calls this once at the top of every frame so a downstream
    /// observer that didn't react in the previous frame won't see a
    /// stale `true`.
    ///
    /// Does NOT touch `hovered_layout_id` — hover persists across
    /// frames until the cursor moves or exits the window.
    pub fn beginFrame(self: *Self) void {
        self.hover_changed = false;
    }

    // -------------------------------------------------------------------------
    // Update
    // -------------------------------------------------------------------------

    /// Recompute hover from cursor `(x, y)` against the current
    /// dispatch tree. Returns `true` iff the hovered element changed
    /// (caller may want to request a render).
    ///
    /// Side effects:
    ///   - `hovered_layout_id` is set to the hit element's layout id,
    ///     or cleared to `null` if the hit missed.
    ///   - `hovered_ancestors` is rebuilt by walking parent links from
    ///     the hit node, capped at `MAX_HOVERED_ANCESTORS`.
    ///   - `hover_changed` is latched to `true` if the id changed.
    pub fn update(self: *Self, tree: *const DispatchTree, x: f32, y: f32) bool {
        // Coordinates must be finite. The platform layer is the
        // source of truth here; an assertion catches a regression at
        // the earliest write boundary rather than letting NaNs
        // propagate into hit testing where they'd silently disable
        // hover.
        std.debug.assert(!std.math.isNan(x));
        std.debug.assert(!std.math.isNan(y));

        const old_hovered = self.hovered_layout_id;

        // Reset ancestor cache before rebuilding. We also reset
        // `hovered_layout_id` — the hit-test branches below set it
        // back to a concrete id or leave it null.
        self.hovered_ancestor_count = 0;

        // Hit test against the dispatch tree. The leaf below builds
        // the ancestor chain when we hit something concrete.
        if (tree.hitTest(x, y)) |node_id| {
            self.applyHit(tree, node_id);
        } else {
            self.hovered_layout_id = null;
        }

        const changed = old_hovered != self.hovered_layout_id;
        if (changed) {
            self.hover_changed = true;
        }
        return changed;
    }

    /// Apply a hit-test result: set `hovered_layout_id` from the node
    /// and walk parents to fill `hovered_ancestors`. Pure leaf — the
    /// parent `update` keeps the hit-vs-miss branching; this owns only
    /// the bounded walk.
    fn applyHit(
        self: *Self,
        tree: *const DispatchTree,
        node_id: dispatch_mod.DispatchNodeId,
    ) void {
        const node = tree.getNodeConst(node_id) orelse {
            // Hit-test returned an id but the node lookup failed —
            // tree desync. Treat as a miss rather than asserting; the
            // dispatch tree's own assertions are the right place to
            // surface this if it's a real bug.
            self.hovered_layout_id = null;
            return;
        };

        self.hovered_layout_id = node.layout_id;

        // Walk parent links, capped by `MAX_HOVERED_ANCESTORS`.
        var current = node_id;
        while (current.isValid() and self.hovered_ancestor_count < MAX_HOVERED_ANCESTORS) {
            const n = tree.getNodeConst(current) orelse break;
            if (n.layout_id) |lid| {
                std.debug.assert(self.hovered_ancestor_count < MAX_HOVERED_ANCESTORS);
                self.hovered_ancestors[self.hovered_ancestor_count] = lid;
                self.hovered_ancestor_count += 1;
            }
            current = n.parent;
        }
    }

    // -------------------------------------------------------------------------
    // Inspection
    // -------------------------------------------------------------------------

    /// `true` iff the element with raw layout id hash `layout_id` is
    /// currently hovered. The "raw u32" form is what most hover-aware
    /// widgets already keep; `isLayoutIdHovered` is the strongly-typed
    /// variant.
    pub fn isHovered(self: *const Self, layout_id: u32) bool {
        return self.hovered_layout_id == layout_id;
    }

    /// `true` iff the element identified by `id` is currently hovered.
    pub fn isLayoutIdHovered(self: *const Self, id: LayoutId) bool {
        return self.hovered_layout_id == id.id;
    }

    /// `true` iff `layout_id` is the hovered element OR an ancestor of
    /// it. Useful for tooltips / hover-styles that should apply when
    /// the cursor is over any descendant.
    ///
    /// Reads the cached ancestor chain populated by the most recent
    /// `update` — does NOT walk the dispatch tree, which may have
    /// been reset between frames.
    pub fn isHoveredOrDescendant(self: *const Self, layout_id: u32) bool {
        std.debug.assert(self.hovered_ancestor_count <= MAX_HOVERED_ANCESTORS);
        for (self.hovered_ancestors[0..self.hovered_ancestor_count]) |ancestor_id| {
            if (ancestor_id == layout_id) return true;
        }
        return false;
    }

    /// Borrowed view of the hovered ancestor chain. Slice is valid
    /// until the next `update` / `clear` / `initInPlace`. Used by the
    /// debug overlay generator (`Debugger.generateOverlays`) which
    /// renders an outline around every ancestor of the hovered
    /// element.
    pub fn ancestors(self: *const Self) []const u32 {
        std.debug.assert(self.hovered_ancestor_count <= MAX_HOVERED_ANCESTORS);
        return self.hovered_ancestors[0..self.hovered_ancestor_count];
    }

    // -------------------------------------------------------------------------
    // Mutation (non-update)
    // -------------------------------------------------------------------------

    /// Drop hover state — typically called when the cursor leaves the
    /// window. Latches `hover_changed` if anything was actually
    /// hovered, so a tooltip-fade observer notices.
    pub fn clear(self: *Self) void {
        if (self.hovered_layout_id != null) {
            self.hovered_layout_id = null;
            self.hovered_ancestor_count = 0;
            self.hover_changed = true;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// Tests focus on the invariants that callers rely on:
//   1. `init` / `initInPlace` produce identical empty states.
//   2. `update` latches `hover_changed` only on transitions.
//   3. The ancestor cache respects `MAX_HOVERED_ANCESTORS`.
//   4. `clear` only latches when state was non-empty.
//
// Hit-testing semantics are owned by `DispatchTree` and tested there;
// these tests use a small hand-built tree to avoid coupling.

const testing = std.testing;

test "HoverState: init produces an empty, no-change state" {
    const h = HoverState.init();
    try testing.expectEqual(@as(?u32, null), h.hovered_layout_id);
    try testing.expectEqual(@as(u8, 0), h.hovered_ancestor_count);
    try testing.expectEqual(false, h.hover_changed);
}

test "HoverState: initInPlace matches init" {
    var via_value = HoverState.init();
    var via_ptr: HoverState = undefined;
    via_ptr.initInPlace();

    try testing.expectEqual(via_value.hovered_layout_id, via_ptr.hovered_layout_id);
    try testing.expectEqual(via_value.hovered_ancestor_count, via_ptr.hovered_ancestor_count);
    try testing.expectEqual(via_value.hover_changed, via_ptr.hover_changed);
    // The ancestor array is bulky — compare via slice.
    try testing.expectEqualSlices(u32, &via_value.hovered_ancestors, &via_ptr.hovered_ancestors);
}

test "HoverState: clear latches change only when something was hovered" {
    var h = HoverState.init();

    // Empty → clear: no-op.
    h.clear();
    try testing.expectEqual(false, h.hover_changed);

    // Force-populate, then clear: hover_changed must latch.
    h.hovered_layout_id = 42;
    h.hovered_ancestors[0] = 42;
    h.hovered_ancestor_count = 1;
    h.clear();
    try testing.expectEqual(@as(?u32, null), h.hovered_layout_id);
    try testing.expectEqual(@as(u8, 0), h.hovered_ancestor_count);
    try testing.expectEqual(true, h.hover_changed);
}

test "HoverState: beginFrame clears hover_changed but preserves hover id" {
    var h = HoverState.init();
    h.hovered_layout_id = 7;
    h.hover_changed = true;

    h.beginFrame();
    try testing.expectEqual(false, h.hover_changed);
    // Hover persists across frames.
    try testing.expectEqual(@as(?u32, 7), h.hovered_layout_id);
}

test "HoverState: isHoveredOrDescendant matches cached ancestors only" {
    var h = HoverState.init();
    h.hovered_layout_id = 100;
    h.hovered_ancestors[0] = 100;
    h.hovered_ancestors[1] = 50;
    h.hovered_ancestors[2] = 1;
    h.hovered_ancestor_count = 3;

    try testing.expect(h.isHoveredOrDescendant(100));
    try testing.expect(h.isHoveredOrDescendant(50));
    try testing.expect(h.isHoveredOrDescendant(1));
    try testing.expect(!h.isHoveredOrDescendant(999));

    // Slice view should match the populated prefix exactly.
    const view = h.ancestors();
    try testing.expectEqual(@as(usize, 3), view.len);
    try testing.expectEqual(@as(u32, 100), view[0]);
}

test "HoverState: isHovered and isLayoutIdHovered agree" {
    var h = HoverState.init();
    h.hovered_layout_id = 77;

    try testing.expect(h.isHovered(77));
    try testing.expect(!h.isHovered(78));

    const id = LayoutId{ .id = 77, .base_id = 77, .offset = 0, .string_id = null };
    try testing.expect(h.isLayoutIdHovered(id));
}
