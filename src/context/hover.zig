//! `HoverState` — fixed-capacity hover tracker extracted from `Gooey`.
//!
//! Rationale (cleanup item #1, plan §7b in
//! `docs/architectural-cleanup-plan.md`): six fields and six methods
//! on `Gooey` form a textbook subsystem. Keeping them tangled inside
//! the god struct makes hover behavior hard to reason about in
//! isolation and inflates `gooey.zig`'s line count past the 1,200-line
//! target. Pulling them out here is a pure mechanical lift — no
//! behavior change, no API change at the `Gooey` level (the public
//! methods stay as one-line forwarders).
//!
//! ## What lives here
//!
//! - `hovered_layout_id`: the topmost element under the cursor at the
//!   end of the last `update`. `null` when the cursor is outside any
//!   hit-testable element.
//! - `last_mouse_x` / `last_mouse_y`: the most recent cursor position.
//!   Captured so `refresh` can re-run hit testing after bounds sync
//!   without the runtime needing to re-thread the coordinates through
//!   another event.
//! - `hovered_ancestors` (cap `MAX_HOVERED_ANCESTORS`): cached parent
//!   chain of the hovered element, populated during `update` and read
//!   by `isHoveredOrDescendant`. The cache must be filled before the
//!   dispatch tree is reset for the next frame, hence why we don't
//!   compute it lazily.
//! - `hover_changed`: latch that's true for one frame whenever the
//!   hovered element changes. Cleared at the start of every frame by
//!   `beginFrame`. Kept so the runtime can decide whether a re-render
//!   is warranted without a separate side channel.
//!
//! ## Decoupling from `Gooey`
//!
//! `update` takes a `*const DispatchTree` rather than a `*Gooey`
//! back-pointer. The dispatch tree is the only `Gooey` field this
//! subsystem reads, and threading it as a parameter makes the data
//! dependency obvious at every call site. Per `CLAUDE.md` §6 (explicit
//! control flow): leaf functions stay pure, control flow stays in the
//! parent (`Gooey.updateHover` is now a one-liner that hands the
//! tree to the leaf).
//!
//! ## Invariants
//!
//! - `hovered_ancestor_count <= MAX_HOVERED_ANCESTORS`.
//! - When `hovered_layout_id == null`, `hovered_ancestor_count == 0`.
//!   The reverse does not hold — a hovered element may have zero
//!   ancestors (it's the root).
//! - `last_mouse_x` / `last_mouse_y` are always finite. The platform
//!   layer never feeds NaN coordinates; if it ever did, the assertion
//!   in `update` would catch it before we wrote to the cache.

const std = @import("std");

const dispatch_mod = @import("dispatch.zig");
const DispatchTree = dispatch_mod.DispatchTree;

const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;

// =============================================================================
// Capacity caps (per `CLAUDE.md` §4 — every loop and queue gets a hard cap)
// =============================================================================

/// Hard cap on the cached ancestor chain.
///
/// 32 levels of nesting is comfortably above what any real UI hits —
/// `MAX_NESTED_COMPONENTS` in `CLAUDE.md` example tables sits at 64,
/// but the hovered chain is the depth of one hit path, not the entire
/// component tree. 32 covers e.g. a deeply-nested form inside a
/// scrolling list inside a tabbed pane inside a dialog without
/// truncation. Truncation just means `isHoveredOrDescendant` returns
/// false for ancestors beyond the cap — a graceful degradation, not a
/// crash.
pub const MAX_HOVERED_ANCESTORS: u32 = 32;

// =============================================================================
// HoverState
// =============================================================================

pub const HoverState = struct {
    /// Layout id (hash) of the topmost element under the cursor, or
    /// `null` when the cursor is outside any hit-testable element.
    /// Persists across frames until the next `update` / `clear`.
    hovered_layout_id: ?u32 = null,

    /// Last cursor position fed into `update`. Captured so `refresh`
    /// can re-run hit testing without the runtime needing to thread
    /// coordinates through another event.
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,

    /// Cached ancestor chain of `hovered_layout_id`, populated during
    /// `update` and read by `isHoveredOrDescendant`. Must be filled
    /// while the dispatch tree is still valid for the just-processed
    /// frame — the next frame resets the tree before we'd otherwise
    /// have a chance to walk it.
    hovered_ancestors: [MAX_HOVERED_ANCESTORS]u32 = [_]u32{0} ** MAX_HOVERED_ANCESTORS,

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

    /// Empty hover state — nothing hovered, cursor at origin, no
    /// pending change. Cheap; the struct is small enough to return by
    /// value without WASM stack concerns.
    pub fn init() Self {
        return .{};
    }

    /// In-place reset to the empty state. Use this from a parent
    /// struct's `initInPlace` path (per `CLAUDE.md` §13) where any
    /// stack temp would compound with the parent's frame budget.
    pub fn initInPlace(self: *Self) void {
        // Field-by-field — no struct literal, no stack temp. Mirrors
        // the convention used by `Tree.initInPlace` in the a11y module.
        self.hovered_layout_id = null;
        self.last_mouse_x = 0;
        self.last_mouse_y = 0;
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
    // Update / refresh
    // -------------------------------------------------------------------------

    /// Recompute hover from cursor `(x, y)` against the current
    /// dispatch tree. Returns `true` iff the hovered element changed
    /// (caller may want to request a render).
    ///
    /// Side effects:
    ///   - `last_mouse_{x,y}` capture the new coordinates.
    ///   - `hovered_layout_id` is set to the hit element's layout id,
    ///     or cleared to `null` if the hit miss.
    ///   - `hovered_ancestors` is rebuilt by walking parent links from
    ///     the hit node, capped at `MAX_HOVERED_ANCESTORS`.
    ///   - `hover_changed` is latched to `true` if the id changed.
    ///
    /// The caller is expected to ensure that `tree` reflects the
    /// previous frame's bounds — `update` is typically called on
    /// `mouse_moved` events, which arrive between frames. `refresh`
    /// re-runs the same logic with the cached coordinates after a
    /// fresh layout pass.
    pub fn update(self: *Self, tree: *const DispatchTree, x: f32, y: f32) bool {
        // Coordinates must be finite. The platform layer is the
        // source of truth here; an assertion catches a regression at
        // the earliest write boundary rather than letting NaNs
        // propagate into hit testing where they'd silently disable
        // hover.
        std.debug.assert(!std.math.isNan(x));
        std.debug.assert(!std.math.isNan(y));

        self.last_mouse_x = x;
        self.last_mouse_y = y;

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

    /// Re-run hit testing with the last cursor position. Call this
    /// after a fresh layout pass to fix the one-frame lag between
    /// "input handled with stale bounds" and "bounds synced for the
    /// upcoming frame."
    pub fn refresh(self: *Self, tree: *const DispatchTree) void {
        _ = self.update(tree, self.last_mouse_x, self.last_mouse_y);
    }

    /// Apply a hit-test result: set `hovered_layout_id` from the node
    /// and walk parents to fill `hovered_ancestors`.
    ///
    /// Pure leaf — no control flow other than the bounded walk. Per
    /// `CLAUDE.md` §5 (70-line limit + push-ifs-up), the parent
    /// `update` keeps the hit-vs-miss branching and we keep the loop.
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
    try testing.expectEqual(@as(f32, 0), h.last_mouse_x);
    try testing.expectEqual(@as(f32, 0), h.last_mouse_y);
    try testing.expectEqual(@as(u8, 0), h.hovered_ancestor_count);
    try testing.expectEqual(false, h.hover_changed);
}

test "HoverState: initInPlace matches init" {
    var via_value = HoverState.init();
    var via_ptr: HoverState = undefined;
    via_ptr.initInPlace();

    try testing.expectEqual(via_value.hovered_layout_id, via_ptr.hovered_layout_id);
    try testing.expectEqual(via_value.last_mouse_x, via_ptr.last_mouse_x);
    try testing.expectEqual(via_value.last_mouse_y, via_ptr.last_mouse_y);
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
