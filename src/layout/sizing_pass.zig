//! Layout sizing pass — Phases 1 and 2 of the layout pipeline.
//!
//! Every function takes a `*LayoutEngine` and mutates
//! `LayoutElement.computed.{min_,sized_}{width,height}` in place; positions
//! belong to `position_pass.zig`.
//!
//! Phase order:
//!   1. `computeMinSizes`     — bottom-up content minimums.
//!   2. `computeFinalSizes`   — top-down concrete sizes (`planChildSizes`).
//!   3. `computeTextWrapping` — wraps text once container widths are known.
//!
//! No pass recurses (CLAUDE.md §6). Min and final sizes keep an explicit
//! stack of open parents, one frame per level, bounded by the engine's open
//! depth, and visit elements in the recursive passes' order: a child's
//! subtree is done while the child is still in cache. A parent whose
//! children are all leaves needs no frame. The engine also stores elements
//! in pre-order (`createElement` appends a parent before its children), so a
//! subtree is the contiguous index range `root..subtreeEnd(root)`, which text
//! wrapping and the floating passes walk forwards.
//!
//! Helpers are `pub` because the orchestrator and
//! `position_pass.computeFloatingSizesWithText` re-enter the pipeline
//! mid-frame for floating subtrees.

const std = @import("std");

const engine_mod = @import("engine.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutElement = engine_mod.LayoutElement;
const FixedCapacityArray = engine_mod.FixedCapacityArray;
const WordInfo = engine_mod.WordInfo;
const TextConfig = types.TextConfig;
const SizingAxis = types.SizingAxis;
const LayoutConfig = types.LayoutConfig;
const MeasureTextFn = engine_mod.MeasureTextFn;

const MAX_OPEN_DEPTH = engine_mod.MAX_OPEN_DEPTH;
const MAX_LINES_PER_TEXT = engine_mod.MAX_LINES_PER_TEXT;
const MAX_WORDS_PER_TEXT = engine_mod.MAX_WORDS_PER_TEXT;
const UNCONSTRAINED_MAX = engine_mod.UNCONSTRAINED_MAX;

// ============================================================================
// Pre-order subtrees
// ============================================================================

/// One past the last element of `root`'s subtree: the next sibling of `root`
/// or of its nearest ancestor that has one, else the end of the list. The
/// walk climbs at most the tree's depth, which the open stack bounds.
pub fn subtreeEnd(engine: *const LayoutEngine, root: u32) u32 {
    const count = engine.elements.len();
    std.debug.assert(root < count);
    var index = root;
    var steps: u32 = 0;
    while (steps <= MAX_OPEN_DEPTH) : (steps += 1) {
        const elem = engine.elements.getConst(index);
        if (elem.next_sibling_index) |next| {
            std.debug.assert(next > root);
            return next;
        }
        index = elem.parent_index orelse return count;
    }
    unreachable; // A deeper chain than the open stack allows cannot be built.
}

/// The pre-order invariant every pass relies on: a child follows its parent.
inline fn assertPreOrder(engine: *const LayoutEngine, root: u32, index: u32) void {
    if (index > root) {
        const parent = engine.elements.getConst(index).parent_index.?;
        std.debug.assert(parent < index);
        std.debug.assert(parent >= root);
    }
}

// ============================================================================
// Phase 1: Compute minimum sizes (bottom-up)
// ============================================================================

/// One parent whose children's minimums the bottom-up walk is summing. The
/// walk finishes a leaf child at once and opens a child that has children,
/// so each child's minimum is added while it is still in cache, in the order
/// the recursive pass used (float sums depend on it). The stack holds one
/// frame per open level.
const MinSizeFrame = struct {
    index: u32,
    /// The next child to add, or null once every child is added.
    cursor: ?u32,
    content_width: f32,
    content_height: f32,
    /// Non-floating children added so far, for the gaps.
    flow_count: u32,
    is_horizontal: bool,
    is_horizontal_scroll: bool,
    is_vertical_scroll: bool,
};

/// Content minimums for `root`'s whole subtree, floating elements included
/// (they size themselves but do not count toward their parent).
pub fn computeMinSizes(engine: *LayoutEngine, root: u32) void {
    std.debug.assert(root < engine.elements.len()); // Valid element index
    if (engine.elements.getConst(root).first_child_index == null) {
        finishMinSize(engine.elements.get(root), 0, 0);
        return;
    }

    // A frame per open level: the open stack bounds the tree's depth.
    var stack: [MAX_OPEN_DEPTH]MinSizeFrame = undefined;
    stack[0] = openMinSizeFrame(engine, root);
    var depth: u32 = 1;
    var open_count: u32 = 1;
    while (depth > 0) {
        std.debug.assert(open_count <= engine.elements.len()); // Each parent once.
        const frame = &stack[depth - 1];
        if (addChildMinSizes(engine, frame)) |child_index| {
            std.debug.assert(depth < stack.len);
            stack[depth] = openMinSizeFrame(engine, child_index);
            depth += 1;
            open_count += 1;
        } else {
            const parent = engine.elements.get(frame.index);
            addGaps(frame, parent.config.layout.child_gap);
            finishMinSize(parent, frame.content_width, frame.content_height);
            depth -= 1;
            if (depth > 0) addChildMinSize(&stack[depth - 1], parent);
        }
    }
}

/// A frame for `index`'s children. Scroll containers don't use children's
/// sizes for min_height/min_width in the scrollable direction.
fn openMinSizeFrame(engine: *LayoutEngine, index: u32) MinSizeFrame {
    const elem = engine.elements.getConst(index);
    const first_child = elem.first_child_index.?;
    std.debug.assert(first_child > index); // Pre-order: children follow.
    return .{
        .index = index,
        .cursor = first_child,
        .content_width = 0,
        .content_height = 0,
        .flow_count = 0,
        .is_horizontal = elem.config.layout.layout_direction.isHorizontal(),
        .is_horizontal_scroll = if (elem.config.scroll) |scroll| scroll.horizontal else false,
        .is_vertical_scroll = if (elem.config.scroll) |scroll| scroll.vertical else false,
    };
}

/// Finish and add `frame`'s remaining leaf children until one has children
/// of its own: return it for the walk to open, its siblings left for later,
/// or null once every child is added.
fn addChildMinSizes(engine: *LayoutEngine, frame: *MinSizeFrame) ?u32 {
    std.debug.assert(frame.index < engine.elements.len());
    var cursor = frame.cursor;
    var sibling_count: u32 = 0;
    while (cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len()); // Each sibling once.
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        cursor = child.next_sibling_index;
        if (child.first_child_index != null) {
            frame.cursor = cursor;
            return child_index;
        }
        finishMinSize(child, 0, 0);
        addChildMinSize(frame, child);
    }
    frame.cursor = null;
    return null;
}

/// Add one finished child's minimum along the parent's main axis (sum) and
/// cross axis (max), respecting scroll-direction opt-outs. Floating children
/// do not affect their parent's minimum.
fn addChildMinSize(frame: *MinSizeFrame, child: *const LayoutElement) void {
    std.debug.assert(child.computed.min_width >= 0);
    std.debug.assert(child.computed.min_height >= 0);
    if (child.config.floating != null) return;
    const min_width = child.computed.min_width;
    const min_height = child.computed.min_height;
    if (frame.is_horizontal) {
        if (!frame.is_horizontal_scroll) frame.content_width += min_width;
        if (!frame.is_vertical_scroll) frame.content_height = @max(frame.content_height, min_height);
    } else {
        if (!frame.is_horizontal_scroll) frame.content_width = @max(frame.content_width, min_width);
        if (!frame.is_vertical_scroll) frame.content_height += min_height;
    }
    frame.flow_count += 1;
}

/// Add gaps between the flow children, but not for scroll containers in
/// their scrollable direction.
fn addGaps(frame: *MinSizeFrame, child_gap: u16) void {
    std.debug.assert(frame.cursor == null); // Every child is added.
    if (frame.flow_count > 1) {
        const gap: f32 = @floatFromInt(child_gap);
        const gap_total = gap * @as(f32, @floatFromInt(frame.flow_count - 1));
        if (frame.is_horizontal) {
            if (!frame.is_horizontal_scroll) frame.content_width += gap_total;
        } else {
            if (!frame.is_vertical_scroll) frame.content_height += gap_total;
        }
    }
}

/// Write one element's minimum from its children's content size: widen it to
/// its text, add padding, then apply its own sizing-axis constraints.
fn finishMinSize(elem: *LayoutElement, children_width: f32, children_height: f32) void {
    std.debug.assert(children_width >= 0);
    std.debug.assert(children_height >= 0);
    var content_width = children_width;
    var content_height = children_height;

    // Text content measurement
    if (elem.text_data) |td| {
        content_width = @max(content_width, td.measured_width);
        content_height = @max(content_height, td.measured_height);
    }

    // Add padding to get total minimum size
    const padding = elem.config.layout.padding;
    const min_width = content_width + padding.totalX();
    const min_height = content_height + padding.totalY();

    // Apply sizing constraints from declaration
    elem.computed.min_width = applyMinMax(min_width, elem.config.layout.sizing.width);
    elem.computed.min_height = applyMinMax(min_height, elem.config.layout.sizing.height);
}

// ============================================================================
// Phase 2: Compute final sizes (top-down)
// ============================================================================

/// One parent whose children the top-down walk is sizing, and the rule that
/// gives each remaining child its size. The rule is planned once per parent
/// from all its children (`planChildSizes`); the walk then sizes one child
/// and, when that child has children, plans it straight away. A parent whose
/// children are all leaves is sized on the spot; any other is pushed. A
/// subtree is therefore sized while its root is still in cache, in the order
/// the recursive pass used, and the stack holds one frame per open level.
const SizingFrame = struct {
    /// The next child to size, or null once every child is sized.
    cursor: ?u32,
    rule: SizingRule,
    is_horizontal: bool,
    /// Whether any non-floating child has children of its own.
    has_grandchildren: bool,
    /// The parent's content area, offered to every child.
    width: f32,
    height: f32,
    /// The shrink ratio for `.shrink`, the space per grow weight for `.grow`.
    factor: f32,
};

const SizingRule = enum {
    /// The uniform-grow fast path already wrote every child's size.
    assigned,
    shrink,
    grow,
};

/// Size `root` within the available space, then size the rest of its
/// subtree top-down: each parent's rule sizes its children before they size
/// theirs. Floating subtrees below `root` are skipped;
/// `position_pass.computeFloatingPositions` sizes them.
pub fn computeFinalSizes(
    engine: *LayoutEngine,
    root: u32,
    available_width: f32,
    available_height: f32,
) void {
    std.debug.assert(root < engine.elements.len()); // Valid element index
    std.debug.assert(available_width >= 0 or available_width == std.math.floatMax(f32)); // Valid width

    sizeElement(engine.elements.get(root), available_width, available_height);
    if (engine.elements.getConst(root).first_child_index == null) return;

    const root_plan = planChildSizes(engine, root);
    if (!root_plan.has_grandchildren) {
        sizeLeafChildren(engine, &root_plan); // No frame needed.
        return;
    }

    // A frame per open level: the open stack bounds the tree's depth.
    var stack: [MAX_OPEN_DEPTH]SizingFrame = undefined;
    stack[0] = root_plan;
    var depth: u32 = 1;
    var open_count: u32 = 1;
    while (depth > 0) {
        std.debug.assert(open_count <= engine.elements.len()); // Each parent once.
        var opened: SizingFrame = undefined;
        if (sizeSiblings(engine, &stack[depth - 1], &opened)) {
            std.debug.assert(depth < stack.len);
            stack[depth] = opened;
            depth += 1;
            open_count += 1;
        } else {
            depth -= 1;
        }
    }
}

/// Size `frame`'s remaining children until one has grandchildren: plan it
/// into `opened` and return true for the walk to push it, its siblings left
/// for later; or return false once every child is sized. A child whose own
/// children are all leaves is finished here, without a frame.
fn sizeSiblings(engine: *LayoutEngine, frame: *SizingFrame, opened: *SizingFrame) bool {
    std.debug.assert(frame.factor >= 0);
    var cursor = frame.cursor;
    var sibling_count: u32 = 0;
    while (cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len()); // Each sibling once.
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            sizeByRule(frame, child);
            if (child.first_child_index != null) {
                const plan = planChildSizes(engine, child_index);
                if (plan.has_grandchildren) {
                    frame.cursor = cursor;
                    opened.* = plan;
                    return true;
                }
                sizeLeafChildren(engine, &plan);
            }
        }
    }
    frame.cursor = null;
    return false;
}

/// Size every child of a parent whose non-floating children are all leaves.
fn sizeLeafChildren(engine: *LayoutEngine, frame: *const SizingFrame) void {
    std.debug.assert(!frame.has_grandchildren);
    var cursor = frame.cursor;
    var sibling_count: u32 = 0;
    while (cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len()); // Each sibling once.
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            std.debug.assert(child.first_child_index == null);
            sizeByRule(frame, child);
        }
    }
}

/// Size one non-floating child by its parent's planned rule.
inline fn sizeByRule(frame: *const SizingFrame, child: *LayoutElement) void {
    std.debug.assert(child.config.floating == null);
    std.debug.assert(frame.factor >= 0);
    const is_horizontal = frame.is_horizontal;
    switch (frame.rule) {
        .assigned => {},
        .shrink => {
            const available = if (is_horizontal) frame.width else frame.height;
            assignShrunkSize(child, is_horizontal, available, frame.width, frame.height, frame.factor);
        },
        .grow => assignGrownSize(child, is_horizontal, frame.width, frame.height, frame.factor),
    }
}

/// Plan how `parent_index`'s content area is shared among its children: the
/// uniform-grow fast path assigns every size now; otherwise the children's
/// desired sizes decide between shrinking them and growing them.
fn planChildSizes(engine: *LayoutEngine, parent_index: u32) SizingFrame {
    const parent = engine.elements.getConst(parent_index);
    const first_child = parent.first_child_index.?;
    std.debug.assert(first_child > parent_index); // Pre-order: children follow.
    // Read the two layout fields rather than copy the whole config: the fast
    // path below writes elements, so a copy could not be elided.
    const content = childContentArea(parent);
    const is_horizontal = parent.config.layout.layout_direction.isHorizontal();
    const gap: f32 = @floatFromInt(parent.config.layout.child_gap);
    const available = if (is_horizontal) content.width else content.height;

    var frame: SizingFrame = .{
        .cursor = first_child,
        .rule = .assigned,
        .is_horizontal = is_horizontal,
        .has_grandchildren = true,
        .width = content.width,
        .height = content.height,
        .factor = 0,
    };
    // Fast path: Check if all children are uniform grow elements (very common case)
    const fast_path = tryUniformGrowFastPath(
        engine,
        first_child,
        is_horizontal,
        content.width,
        content.height,
        available,
        gap,
    );
    switch (fast_path) {
        .ineligible => {},
        .sized => return frame,
        .sized_leaves => {
            frame.cursor = null; // No child has children: the subtree is sized.
            frame.has_grandchildren = false;
            return frame;
        },
    }

    // Slow path: classify children, then shrink or grow them.
    const totals = sumDesiredSizes(engine, first_child, is_horizontal, available);
    const total_gap = if (totals.child_count > 1) gap * @as(f32, @floatFromInt(totals.child_count - 1)) else 0;
    const size_to_distribute = available - totals.total_desired - total_gap;
    frame.has_grandchildren = totals.has_grandchildren;

    if (size_to_distribute < 0 and totals.total_desired > 0) {
        const overflow = -size_to_distribute;
        frame.rule = .shrink;
        frame.factor = @max(0, 1.0 - overflow / totals.total_desired);
        std.debug.assert(frame.factor <= 1.0);
    } else {
        std.debug.assert(totals.grow_weight_total >= 0);
        std.debug.assert(size_to_distribute >= 0 or totals.grow_weight_total == 0);
        frame.rule = .grow;
        frame.factor = if (totals.grow_weight_total > 0)
            @max(0, size_to_distribute) / totals.grow_weight_total
        else
            0;
    }
    std.debug.assert(frame.factor >= 0);
    return frame;
}

/// Resolve one element's concrete size for the space its parent offers.
/// Aspect-ratio derives height from width here so that grow/shrink
/// calculations see the final height.
fn sizeElement(elem: *LayoutElement, available_width: f32, available_height: f32) void {
    std.debug.assert(available_width >= 0 or available_width == std.math.floatMax(f32));
    std.debug.assert(available_height >= 0 or available_height == std.math.floatMax(f32));
    const layout = elem.config.layout;
    const sizing = layout.sizing;

    // Compute base sizes
    const final_width = computeAxisSize(sizing.width, elem.computed.min_width, available_width);
    var final_height = computeAxisSize(sizing.height, elem.computed.min_height, available_height);

    // ASPECT RATIO (Phase 1): Derive height from width
    if (layout.aspect_ratio) |ratio| {
        // aspect_ratio = width / height, so height = width / ratio
        final_height = final_width / ratio;
    }

    elem.computed.sized_width = final_width;
    elem.computed.sized_height = final_height;
}

/// Pre-pass totals from `planChildSizes`: the grow children's summed
/// weights, how much non-grow desired space they occupy, and the count
/// itself (for gaps).
const ChildTotals = struct {
    grow_weight_total: f32,
    total_desired: f32,
    child_count: u32,
    has_grandchildren: bool,
};

/// Inspect each non-floating child and classify by sizing type. The
/// numbers feed both the shrink-vs-grow decision in `planChildSizes`
/// and the gap accounting.
fn sumDesiredSizes(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    available: f32,
) ChildTotals {
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(available >= 0 or available == std.math.floatMax(f32));

    var grow_weight_total: f32 = 0;
    var total_desired: f32 = 0;
    var child_count: u32 = 0;
    var has_grandchildren = false;

    var child_idx: ?u32 = first_child;
    while (child_idx) |ci| {
        const child = engine.elements.getConst(ci);

        // Skip floating elements - they don't participate in space distribution
        if (child.config.floating != null) {
            child_idx = child.next_sibling_index;
            continue;
        }

        const child_sizing = if (is_horizontal) child.config.layout.sizing.width else child.config.layout.sizing.height;
        const child_min = if (is_horizontal) child.computed.min_width else child.computed.min_height;

        const child_desired: f32 = switch (child_sizing.value) {
            .grow => |grow| blk: {
                std.debug.assert(grow.weight > 0);
                grow_weight_total += grow.weight;
                break :blk child_min; // grow elements only contribute their min
            },
            .fit => |mm| blk: {
                // If max is unbounded (floatMax), use min_width as desired
                // Otherwise use the max constraint as desired size
                const effective_max = if (mm.max >= 1e10) child_min else mm.max;
                break :blk @max(child_min, effective_max);
            },
            .fixed => |mm| mm.min, // fixed wants exactly this size
            .percent => |p| available * p.value, // percent of available
        };

        if (child_sizing.value != .grow) total_desired += child_desired;
        if (child.first_child_index != null) has_grandchildren = true;
        child_idx = child.next_sibling_index;
        child_count += 1;
    }

    std.debug.assert(std.math.isFinite(grow_weight_total));
    return .{
        .grow_weight_total = grow_weight_total,
        .total_desired = total_desired,
        .child_count = child_count,
        .has_grandchildren = has_grandchildren,
    };
}

// ============================================================================
// Phase 2 — fast path for uniform grow children
// ============================================================================

/// Result of the speculative uniform-grow pass: was it eligible, how many
/// floating siblings did we step over (we recompute per-child size after
/// subtracting those out), and does any flow child have children?
const SpeculativeResult = struct {
    eligible: bool,
    floating_count: u32,
    has_grandchildren: bool,
};

/// What the uniform-grow fast path did. `sized_leaves` lets the walk skip the
/// children entirely: a wide row of grow leaves is not visited twice.
const FastPathResult = enum { ineligible, sized, sized_leaves };

/// Fast path for uniform grow children — speculative single pass with early
/// bailout. Returns `.ineligible` when the slow path must distribute.
fn tryUniformGrowFastPath(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    width: f32,
    height: f32,
    available: f32,
    gap: f32,
) FastPathResult {
    std.debug.assert(first_child < engine.elements.len()); // Valid child index
    std.debug.assert(gap >= 0);

    // Get parent's child_count to pre-compute sizes (avoids counting pass)
    const first = engine.elements.getConst(first_child);
    const parent_idx = first.parent_index orelse return .ineligible;
    const parent = engine.elements.getConst(parent_idx);
    const total_children = parent.child_count;

    if (total_children == 0) return .ineligible;

    // Pre-compute uniform size assuming no floating elements
    const total_gap = if (total_children > 1) gap * @as(f32, @floatFromInt(total_children - 1)) else 0;
    var per_child = @max(0, (available - total_gap) / @as(f32, @floatFromInt(total_children)));
    const cross_size = if (is_horizontal) height else width;

    const result = speculativeUniformAssign(engine, first_child, is_horizontal, per_child, cross_size);
    if (!result.eligible) return .ineligible;

    // If we had floating elements, recalculate and re-assign
    if (result.floating_count > 0) {
        const actual_children = total_children - result.floating_count;
        if (actual_children == 0) return .ineligible;

        const actual_gap = if (actual_children > 1) gap * @as(f32, @floatFromInt(actual_children - 1)) else 0;
        per_child = @max(0, (available - actual_gap) / @as(f32, @floatFromInt(actual_children)));
        reassignUniformSizes(engine, first_child, is_horizontal, per_child, cross_size);
    }

    return if (result.has_grandchildren) .sized else .sized_leaves;
}

/// Speculative pass: walk children once, assign uniform sizes, and report
/// eligibility. Returns early via the eligibility flag — callers must check
/// it before trusting the writes (they're harmless to overwrite later).
fn speculativeUniformAssign(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    per_child: f32,
    cross_size: f32,
) SpeculativeResult {
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(per_child >= 0);

    var floating_count: u32 = 0;
    var has_grandchildren: bool = false;
    var child_idx: ?u32 = first_child;

    while (child_idx) |ci| {
        const child = engine.elements.get(ci);

        // Skip floating elements but count them
        if (child.config.floating != null) {
            floating_count += 1;
            child_idx = child.next_sibling_index;
            continue;
        }

        // Check if child qualifies for fast path
        if (!isUnconstrainedGrow(child, is_horizontal)) {
            return .{ .eligible = false, .floating_count = 0, .has_grandchildren = false };
        }

        // A floating child sizes itself, so only flow children count here.
        if (child.first_child_index != null) has_grandchildren = true;

        // Assign sizes speculatively
        if (is_horizontal) {
            child.computed.sized_width = per_child;
            child.computed.sized_height = cross_size;
        } else {
            child.computed.sized_width = cross_size;
            child.computed.sized_height = per_child;
        }

        child_idx = child.next_sibling_index;
    }

    return .{
        .eligible = true,
        .floating_count = floating_count,
        .has_grandchildren = has_grandchildren,
    };
}

/// Fast-path eligibility check: both axes are unbounded `grow`, the main
/// axis at weight 1 so every sibling's share is equal, and no aspect ratio
/// is in play. Anything else routes to the slow path.
fn isUnconstrainedGrow(child: *const LayoutElement, is_horizontal: bool) bool {
    std.debug.assert(child.config.layout.aspect_ratio == null or child.config.layout.aspect_ratio.? > 0);
    std.debug.assert(UNCONSTRAINED_MAX > 0);

    // Aspect ratio requires special handling - bail to slow path
    if (child.config.layout.aspect_ratio != null) return false;

    const main_sizing = if (is_horizontal) child.config.layout.sizing.width else child.config.layout.sizing.height;
    const main_ok = switch (main_sizing.value) {
        .grow => |mm| mm.min == 0 and mm.max >= UNCONSTRAINED_MAX and mm.weight == 1,
        else => false,
    };
    if (!main_ok) return false;

    const cross_sizing = if (is_horizontal) child.config.layout.sizing.height else child.config.layout.sizing.width;
    return switch (cross_sizing.value) {
        .grow => |mm| mm.min == 0 and mm.max >= UNCONSTRAINED_MAX,
        else => false,
    };
}

/// Re-assign uniform sizes after adjusting for floating elements
fn reassignUniformSizes(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    per_child: f32,
    cross_size: f32,
) void {
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(per_child >= 0);

    var child_idx: ?u32 = first_child;
    while (child_idx) |ci| {
        const child = engine.elements.get(ci);
        if (child.config.floating == null) {
            if (is_horizontal) {
                child.computed.sized_width = per_child;
                child.computed.sized_height = cross_size;
            } else {
                child.computed.sized_width = cross_size;
                child.computed.sized_height = per_child;
            }
        }
        child_idx = child.next_sibling_index;
    }
}

// ============================================================================
// Phase 2 — shrink / grow distribution (slow path)
// ============================================================================

/// Compute and assign the shrunk size for a single child on the main axis,
/// honoring its min constraint, then resolve the cross axis and aspect
/// ratio. Pure leaf — no recursion, no side effects beyond `child.computed`.
fn assignShrunkSize(
    child: *LayoutElement,
    is_horizontal: bool,
    available: f32,
    width: f32,
    height: f32,
    shrink_ratio: f32,
) void {
    std.debug.assert(shrink_ratio >= 0);
    std.debug.assert(shrink_ratio <= 1.0);

    const child_sizing = if (is_horizontal) child.config.layout.sizing.width else child.config.layout.sizing.height;
    const child_min_constraint = child_sizing.getMin();
    const child_min_content = if (is_horizontal) child.computed.min_width else child.computed.min_height;

    const child_desired: f32 = switch (child_sizing.value) {
        .grow => child_min_content,
        .fit => |mm| @max(child_min_content, if (mm.max >= 1e10) child_min_content else mm.max),
        .fixed => |mm| mm.min,
        .percent => |p| available * p.value,
    };

    const new_size: f32 = if (child_sizing.value == .grow)
        child_min_constraint
    else
        // Shrink proportionally but respect minimum constraint
        @max(child_min_constraint, child_desired * shrink_ratio);

    if (is_horizontal) {
        child.computed.sized_width = new_size;
        child.computed.sized_height = computeAxisSize(child.config.layout.sizing.height, child.computed.min_height, height);
    } else {
        child.computed.sized_width = computeAxisSize(child.config.layout.sizing.width, child.computed.min_width, width);
        child.computed.sized_height = new_size;
    }

    if (child.config.layout.aspect_ratio) |ratio| {
        if (is_horizontal) {
            child.computed.sized_height = child.computed.sized_width / ratio;
        } else {
            child.computed.sized_width = child.computed.sized_height * ratio;
        }
    }
}

/// The space a sized element offers its children: its content box, unbounded
/// along a scroll container's scrollable axes so its children overflow
/// rather than shrink. `computeFinalSizes` distributes every element's
/// children within it.
fn childContentArea(child: *const LayoutElement) struct { width: f32, height: f32 } {
    const child_layout = child.config.layout;
    // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
    var content_width = @max(0, child.computed.sized_width - child_layout.padding.totalX());
    var content_height = @max(0, child.computed.sized_height - child_layout.padding.totalY());
    if (child.config.scroll) |scroll| {
        if (scroll.horizontal) content_width = std.math.floatMax(f32);
        if (scroll.vertical) content_height = std.math.floatMax(f32);
    }
    std.debug.assert(content_width >= 0);
    std.debug.assert(content_height >= 0);
    return .{ .width = content_width, .height = content_height };
}

/// Assign one child's size when its parent grows its children: a grow child
/// takes the share of the free space its weight gives it, any other child its
/// desired size. The child then resolves its own size from what it is offered
/// (`sizeElement`), so nested layouts run on accurate constraints.
fn assignGrownSize(
    child: *LayoutElement,
    is_horizontal: bool,
    width: f32,
    height: f32,
    per_weight: f32,
) void {
    std.debug.assert(per_weight >= 0);
    std.debug.assert(child.config.floating == null);

    const sizing = child.config.layout.sizing;
    const child_sizing_main = if (is_horizontal) sizing.width else sizing.height;
    const child_min_main = if (is_horizontal) child.computed.min_width else child.computed.min_height;
    const child_desired: f32 = switch (child_sizing_main.value) {
        .grow => 0, // handled separately
        .fit => |mm| @max(child_min_main, mm.max),
        .fixed => |mm| mm.min,
        .percent => |p| (if (is_horizontal) width else height) * p.value,
    };

    const per_grow: f32 = switch (child_sizing_main.value) {
        .grow => |grow| per_weight * grow.weight,
        else => 0,
    };
    var child_width: f32 = undefined;
    var child_height: f32 = undefined;

    if (is_horizontal) {
        child_width = if (child_sizing_main.value == .grow)
            @max(child.computed.min_width, per_grow)
        else
            child_desired;
        child_height = height;
    } else {
        child_width = width;
        child_height = if (child_sizing_main.value == .grow)
            @max(child.computed.min_height, per_grow)
        else
            child_desired;
    }

    sizeElement(child, child_width, child_height);
}

// ============================================================================
// Phase 2b: Text wrapping (container widths now known)
// ============================================================================

/// Wrap text in `root`'s subtree, floating elements included, once container
/// widths are settled, and propagate height changes back up to fit-content
/// parents. Walks the subtree forwards, the order the recursive pass used.
pub fn computeTextWrapping(engine: *LayoutEngine, root: u32) !void {
    const end = subtreeEnd(engine, root);
    std.debug.assert(end > root);
    var index = root;
    while (index < end) : (index += 1) {
        assertPreOrder(engine, root, index);
        try wrapElementText(engine, index);
    }
}

/// Wrap one element's text, if it has any, at its parent's content width.
fn wrapElementText(engine: *LayoutEngine, index: u32) !void {
    const elem = engine.elements.get(index);

    if (elem.text_data) |*td| {
        const max_width = textContainerWidth(engine, elem);

        // Always store container width for alignment calculations (used even when no wrap)
        td.container_width = max_width;

        if (td.config.wrap_mode != .none and max_width > 0) {
            const wrap_result = try wrapText(engine, td.text, td.config, max_width);
            td.wrapped_lines = wrap_result.lines;

            if (wrap_result.lines.len > 0) {
                td.measured_width = wrap_result.max_line_width;
                td.measured_height = wrap_result.total_height;

                elem.computed.sized_width = wrap_result.max_line_width;
                elem.computed.sized_height = wrap_result.total_height;

                // Propagate height change up to fit-content parents
                propagateHeightChange(engine, elem.parent_index);
            }
        }
    }
}

/// Width available for text content: parent's sized width minus its
/// horizontal padding, clamped to ≥0 to survive over-shrunk parents.
fn textContainerWidth(engine: *LayoutEngine, elem: *const LayoutElement) f32 {
    if (elem.parent_index) |pi| {
        const parent = engine.elements.getConst(pi);
        return @max(0, parent.computed.sized_width - parent.config.layout.padding.totalX());
    }
    return engine.viewport_width;
}

/// Propagate child height changes up to fit-content parents. Floating
/// children take no space in their parent, so they are left out of its
/// height, and the walk stops at a floating element: its height does not
/// change its host's layout.
pub fn propagateHeightChange(engine: *LayoutEngine, parent_idx: ?u32) void {
    var idx = parent_idx;
    var depth: u32 = 0;
    while (idx) |pi| : (depth += 1) {
        std.debug.assert(depth <= MAX_OPEN_DEPTH); // Ancestors are open containers.
        const parent = engine.elements.get(pi);
        const sizing = parent.config.layout.sizing.height;

        // Only update fit-content parents (not fixed, grow, or percent)
        if (sizing.value != .fit) break;

        // Recalculate height based on children
        const padding = parent.config.layout.padding;
        var total_height: f32 = 0;
        const gap: f32 = @floatFromInt(parent.config.layout.child_gap);
        const is_vertical = !parent.config.layout.layout_direction.isHorizontal();

        var child_idx = parent.first_child_index;
        var child_count: u32 = 0;
        while (child_idx) |ci| {
            const child = engine.elements.getConst(ci);
            child_idx = child.next_sibling_index;
            if (child.config.floating != null) continue;
            if (is_vertical) {
                total_height += child.computed.sized_height;
            } else {
                total_height = @max(total_height, child.computed.sized_height);
            }
            child_count += 1;
        }

        if (is_vertical and child_count > 1) {
            total_height += gap * @as(f32, @floatFromInt(child_count - 1));
        }

        const new_height = total_height + padding.totalY();
        parent.computed.sized_height = @max(sizing.getMin(), @min(sizing.getMax(), new_height));

        if (parent.config.floating != null) break;
        idx = parent.parent_index;
    }
}

// ============================================================================
// Text wrapping — two-pass algorithm
// ============================================================================

/// Output of `wrapText` — owned by the per-frame arena.
pub const WrapResult = struct {
    lines: []types.WrappedLine,
    total_height: f32,
    max_line_width: f32,
};

/// Wrap text into lines based on available width. Two-pass algorithm:
///   1. `findWordBoundaries` measures each word ONCE.
///   2. `accumulateWordsIntoLines` packs measured words onto lines and
///      returns the residual state so the final line preserves its width.
/// Returns a slice allocated from the per-frame arena, so it is safe to
/// stash on `TextData.wrapped_lines` for the rest of the frame.
pub fn wrapText(
    engine: *LayoutEngine,
    text_str: []const u8,
    config: TextConfig,
    max_width: f32,
) !WrapResult {
    std.debug.assert(max_width >= 0 or config.wrap_mode == .none);
    std.debug.assert(text_str.len <= std.math.maxInt(u32)); // Ensure offsets fit in u32

    // Short-circuit on no-op inputs. `findWordBoundaries` requires
    // `text_str.len > 0`, so the empty-text gate must live here at the
    // public boundary.
    if (config.wrap_mode == .none or max_width <= 0 or text_str.len == 0) {
        return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
    }

    const measure_fn = engine.measure_text_fn orelse {
        return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
    };

    // Pass 1: Find word boundaries and measure each word once.
    var words: FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT) = .{};
    _ = findWordBoundaries(text_str, measure_fn, config, engine.measure_text_user_data, &words);

    // Pass 2: Accumulate words onto lines; capture residual so the final
    // line carries the right `line_width`.
    var lines: FixedCapacityArray(types.WrappedLine, MAX_LINES_PER_TEXT) = .{};
    var residual: LineResidual = .{};
    const max_line_width = accumulateWordsIntoLines(words.slice(), config.wrap_mode, max_width, &lines, &residual);

    const final_max = finalizeLastLine(text_str, residual, &lines);

    claimWrappedLines(engine, @intCast(lines.len));
    // Copy to arena for return (arena memory persists until frame end).
    const result_lines = try engine.arena.allocator().dupe(types.WrappedLine, lines.slice());
    const line_height = config.lineHeightPx();
    const total_height = line_height * @as(f32, @floatFromInt(@max(1, result_lines.len)));

    return .{
        .lines = result_lines,
        .total_height = total_height,
        .max_line_width = @max(max_line_width, final_max),
    };
}

/// Carryover from the accumulator into `finalizeLastLine`: the byte offset
/// where the in-progress line started and its accumulated width (sans
/// trailing whitespace).
const LineResidual = struct {
    line_start: u32 = 0,
    line_width: f32 = 0,
};

/// Walk pre-measured words and pack them onto lines. The two-flavor state
/// (`line_width` without trailing space, `line_width_with_space` with it)
/// matters because trailing whitespace should never push a word off-screen.
/// Returns the running `max_line_width`; the trailing line is emitted by
/// `finalizeLastLine` using `residual_out`.
fn accumulateWordsIntoLines(
    words: []const WordInfo,
    wrap_mode: TextConfig.WrapMode,
    max_width: f32,
    lines: *FixedCapacityArray(types.WrappedLine, MAX_LINES_PER_TEXT),
    residual_out: *LineResidual,
) f32 {
    std.debug.assert(max_width >= 0);
    std.debug.assert(wrap_mode != .none);

    var max_line_width: f32 = 0;
    var line_start: u32 = 0; // byte offset where current line starts
    var line_width: f32 = 0; // accumulated width of current line (without trailing space)
    var line_width_with_space: f32 = 0; // line width including trailing space

    for (words) |word| {
        if (word.has_newline) {
            // Handle forced newlines - emit current line and start fresh.
            const total_width = line_width + word.width;
            appendLine(lines, .{
                .start_offset = line_start,
                .length = word.end - line_start,
                .width = total_width,
            });
            max_line_width = @max(max_line_width, total_width);

            line_start = word.end + 1; // +1 to skip the newline byte
            line_width = 0;
            line_width_with_space = 0;
            continue;
        }

        const potential_width = line_width_with_space + word.width;
        if (wrap_mode == .words and potential_width > max_width and line_width > 0) {
            // Overflow - emit current line WITHOUT this word.
            appendLine(lines, .{
                .start_offset = line_start,
                .length = word.start - line_start,
                .width = line_width,
            });
            max_line_width = @max(max_line_width, line_width);

            line_start = word.start;
            line_width = word.width;
            line_width_with_space = word.width + word.trailing_space_width;
        } else if (wrap_mode == .words and word.width > max_width and line_width == 0) {
            // Single word is wider than max_width - force it onto its own line.
            appendLine(lines, .{
                .start_offset = word.start,
                .length = word.end - word.start,
                .width = word.width,
            });
            max_line_width = @max(max_line_width, word.width);

            line_start = word.end;
            if (word.trailing_space_width > 0) line_start += 1; // Assume single-byte space
            line_width = 0;
            line_width_with_space = 0;
        } else {
            // Word fits - add it to current line.
            line_width = line_width_with_space + word.width;
            line_width_with_space = line_width + word.trailing_space_width;
        }
    }

    residual_out.* = .{ .line_start = line_start, .line_width = line_width };
    return max_line_width;
}

/// Emit the trailing line if any content remains past the accumulator's
/// last line break, stashing its `line_width`. Returns the width
/// contribution so `wrapText` can fold it into `max_line_width`.
fn finalizeLastLine(
    text_str: []const u8,
    residual: LineResidual,
    lines: *FixedCapacityArray(types.WrappedLine, MAX_LINES_PER_TEXT),
) f32 {
    if (residual.line_start >= text_str.len) return 0;

    // Trim trailing whitespace from final line.
    const remaining = text_str[residual.line_start..];
    const trimmed = std.mem.trimEnd(u8, remaining, " \t\n");
    if (trimmed.len == 0) return 0;

    appendLine(lines, .{
        .start_offset = residual.line_start,
        .length = @intCast(trimmed.len),
        .width = residual.line_width,
    });
    return residual.line_width;
}

/// Count a text's lines against the frame's budget before they take arena
/// space, so an over-budget frame names the pool instead of failing as an
/// arena allocation.
fn claimWrappedLines(engine: *LayoutEngine, line_count: u32) void {
    std.debug.assert(line_count <= MAX_LINES_PER_TEXT);
    const capacity = engine.wrapped_line_count_frame_max orelse return;
    std.debug.assert(engine.wrapped_line_count <= capacity);
    if (line_count > capacity - engine.wrapped_line_count) {
        std.debug.panic("wrapped lines exhausted: capacity {d} " ++
            "(paint.glyph_count_frame_max), {d} in use, {d} requested", .{
            capacity,
            engine.wrapped_line_count,
            line_count,
        });
    }
    engine.wrapped_line_count += line_count;
}

/// Wrapped lines and words are fixed pools: a text past either capacity is a
/// capacity-planning error, so it stops here rather than dropping the rest.
fn appendLine(
    lines: *FixedCapacityArray(types.WrappedLine, MAX_LINES_PER_TEXT),
    line: types.WrappedLine,
) void {
    lines.append(line) catch std.debug.panic(
        "wrapped text lines exhausted: capacity {d} (MAX_LINES_PER_TEXT), 1 requested",
        .{MAX_LINES_PER_TEXT},
    );
}

fn appendWord(words: *FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT), word: WordInfo) void {
    words.append(word) catch std.debug.panic(
        "wrapped text words exhausted: capacity {d} (MAX_WORDS_PER_TEXT), 1 requested",
        .{MAX_WORDS_PER_TEXT},
    );
}

// ============================================================================
// Word-boundary scanning
// ============================================================================

/// Scanner state for `findWordBoundaries`. Split out so the inner loop can
/// stay a pure switch on the current codepoint without a long `if` chain.
const WordScanState = struct {
    text: []const u8,
    measure_fn: MeasureTextFn,
    config: TextConfig,
    user_data: ?*anyopaque,
    words: *FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT),
    cached_space_width: f32,
    word_start: u32 = 0,
    byte_pos: u32 = 0,
    in_word: bool = false,
};

/// Find word boundaries in text and measure each word exactly once.
/// Returns the number of words appended (≤ MAX_WORDS_PER_TEXT). Caller
/// supplies an empty `words` array.
pub fn findWordBoundaries(
    text_str: []const u8,
    measure_fn: MeasureTextFn,
    config: TextConfig,
    user_data: ?*anyopaque,
    words: *FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT),
) u32 {
    std.debug.assert(text_str.len > 0);
    std.debug.assert(words.len == 0); // Should start empty

    // Cache space width — constant for a given font_id/font_size, avoids redundant
    // measure calls per word boundary (typically 100s of calls per text block).
    var state: WordScanState = .{
        .text = text_str,
        .measure_fn = measure_fn,
        .config = config,
        .user_data = user_data,
        .words = words,
        .cached_space_width = measure_fn(" ", config.font_id, config.font_size, null, user_data).width,
    };

    // Use UTF-8 view for proper multi-byte character handling
    const utf8_view = std.unicode.Utf8View.initUnchecked(text_str);
    var iter = utf8_view.iterator();

    while (iter.nextCodepointSlice()) |codepoint_slice| {
        const codepoint_len: u32 = @intCast(codepoint_slice.len);
        const c = codepoint_slice[0]; // First byte for ASCII checks
        const is_ascii = codepoint_len == 1;
        const is_space = is_ascii and (c == ' ' or c == '\t');
        const is_newline = is_ascii and c == '\n';

        if (is_newline) {
            emitOnNewline(&state);
            state.in_word = false;
            state.word_start = state.byte_pos + codepoint_len;
            state.byte_pos += codepoint_len;
            continue;
        } else if (is_space) {
            if (state.in_word) {
                emitOnSpace(&state);
                state.in_word = false;
            }
            // Skip leading/consecutive spaces - next word starts after this space
            state.word_start = state.byte_pos + codepoint_len;
        } else {
            // Regular character - start or continue word
            if (!state.in_word) {
                state.word_start = state.byte_pos;
                state.in_word = true;
            }
        }

        state.byte_pos += codepoint_len;
    }

    // Final word (no trailing space/newline)
    if (state.in_word and state.word_start < text_str.len) {
        emitFinalWord(&state);
    }

    return @intCast(words.len);
}

/// Append a word at a newline boundary.
fn emitOnNewline(state: *WordScanState) void {
    if (state.in_word) {
        const word_text = state.text[state.word_start..state.byte_pos];
        const word_width = state.measure_fn(word_text, state.config.font_id, state.config.font_size, null, state.user_data).width;
        appendWord(state.words, .{
            .start = state.word_start,
            .end = state.byte_pos,
            .width = word_width,
            .trailing_space_width = 0,
            .has_newline = true,
        });
    } else {
        // Empty line (newline with no preceding word content)
        appendWord(state.words, .{
            .start = state.byte_pos,
            .end = state.byte_pos,
            .width = 0,
            .trailing_space_width = 0,
            .has_newline = true,
        });
    }
}

/// Append a word ending at a space character. Caller guarantees `in_word`.
fn emitOnSpace(state: *WordScanState) void {
    std.debug.assert(state.in_word);

    const word_text = state.text[state.word_start..state.byte_pos];
    const word_width = state.measure_fn(word_text, state.config.font_id, state.config.font_size, null, state.user_data).width;
    appendWord(state.words, .{
        .start = state.word_start,
        .end = state.byte_pos,
        .width = word_width,
        .trailing_space_width = state.cached_space_width,
        .has_newline = false,
    });
}

/// Append the trailing word at end-of-string (no terminating space/newline).
fn emitFinalWord(state: *WordScanState) void {
    std.debug.assert(state.in_word);
    std.debug.assert(state.word_start < state.text.len);

    const word_text = state.text[state.word_start..];
    const word_width = state.measure_fn(word_text, state.config.font_id, state.config.font_size, null, state.user_data).width;
    appendWord(state.words, .{
        .start = state.word_start,
        .end = @intCast(state.text.len),
        .width = word_width,
        .trailing_space_width = 0,
        .has_newline = false,
    });
}

// ============================================================================
// Sizing axis primitives
// ============================================================================

/// Apply min/max constraints to a size
pub fn applyMinMax(size: f32, axis: SizingAxis) f32 {
    const min_val = axis.getMin();
    const max_val = axis.getMax();
    return @max(min_val, @min(max_val, size));
}

/// Compute final size based on sizing type
pub fn computeAxisSize(axis: SizingAxis, min_size: f32, available: f32) f32 {
    return switch (axis.value) {
        .fit => |mm| blk: {
            // If max is bounded, use it as preferred size (allows shrinking from max to min)
            // If max is unbounded, use content size
            const preferred = if (mm.max < 1e10) mm.max else min_size;
            break :blk @max(mm.min, @min(mm.max, preferred));
        },
        .grow => applyMinMax(available, axis),
        .fixed => |mm| mm.min,
        .percent => |p| blk: {
            const computed = available * p.value;
            break :blk @max(p.min, @min(p.max, computed));
        },
    };
}
