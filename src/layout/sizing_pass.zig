//! Layout sizing pass — Phases 1 and 2 of the layout pipeline.
//!
//! Split out from `engine.zig` per
//! [docs/cleanup-implementation-plan.md PR 10](../../docs/cleanup-implementation-plan.md#pr-10--layout-engine-split--fuzz-targets).
//! All functions in this file take a `*LayoutEngine` as the first argument
//! and mutate `LayoutElement.computed.{min_,sized_}{width,height}` in place.
//! They never touch positions or render commands — those belong to
//! `position_pass.zig` and `scroll_pass.zig` respectively.
//!
//! Phase ordering inside this file:
//!   1. `computeMinSizes`  — bottom-up content minimums
//!   2. `computeFinalSizes` — top-down concrete sizes with `distributeSpace` family
//!   3. `computeTextWrapping` — wraps text once container widths are known,
//!      propagates fit-content parent height changes
//!
//! Everything not consumed externally is `pub` only because the orchestrator
//! and `position_pass.computeFloatingSizesWithText` re-enter the pipeline
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

const MAX_RECURSION_DEPTH = engine_mod.MAX_RECURSION_DEPTH;
const MAX_LINES_PER_TEXT = engine_mod.MAX_LINES_PER_TEXT;
const MAX_WORDS_PER_TEXT = engine_mod.MAX_WORDS_PER_TEXT;
const UNCONSTRAINED_MAX = engine_mod.UNCONSTRAINED_MAX;

// ============================================================================
// Phase 1: Compute minimum sizes (bottom-up)
// ============================================================================

/// Walk children first, accumulate their min widths/heights along the main
/// axis (respecting scroll-direction opt-outs), then add gaps + padding + the
/// element's own sizing-axis constraints. Writes into `computed.min_*`.
pub fn computeMinSizes(engine: *LayoutEngine, index: u32, depth: u32) void {
    // Assertions per CLAUDE.md: minimum 2 per function, put a limit on everything
    std.debug.assert(index < engine.elements.len()); // Valid element index
    std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md

    const elem = engine.elements.get(index);
    const layout = elem.config.layout;
    const padding = layout.padding;

    // Check if this is a scroll container - scroll containers don't use
    // children's sizes for min_height/min_width in the scrollable direction
    const is_vertical_scroll = if (elem.config.scroll) |s| s.vertical else false;
    const is_horizontal_scroll = if (elem.config.scroll) |s| s.horizontal else false;

    var content_width: f32 = 0;
    var content_height: f32 = 0;

    if (elem.first_child_index) |first_child| {
        accumulateChildMinSizes(
            engine,
            first_child,
            layout,
            depth,
            is_horizontal_scroll,
            is_vertical_scroll,
            &content_width,
            &content_height,
        );
    }

    // Text content measurement
    if (elem.text_data) |td| {
        content_width = @max(content_width, td.measured_width);
        content_height = @max(content_height, td.measured_height);
    }

    // Add padding to get total minimum size
    const min_width = content_width + padding.totalX();
    const min_height = content_height + padding.totalY();

    // Apply sizing constraints from declaration
    elem.computed.min_width = applyMinMax(min_width, layout.sizing.width);
    elem.computed.min_height = applyMinMax(min_height, layout.sizing.height);
}

/// Helper kept under 70 lines: recurse into children, sum/max along the main
/// axis, and add gap contributions. Skips floating elements (they don't
/// influence parent sizing). Outputs accumulated `content_*` via pointers.
fn accumulateChildMinSizes(
    engine: *LayoutEngine,
    first_child: u32,
    layout: LayoutConfig,
    depth: u32,
    is_horizontal_scroll: bool,
    is_vertical_scroll: bool,
    content_width: *f32,
    content_height: *f32,
) void {
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(depth < MAX_RECURSION_DEPTH);

    var child_idx: ?u32 = first_child;
    var child_count: u32 = 0;
    const is_horizontal_layout = layout.layout_direction.isHorizontal();

    while (child_idx) |ci| {
        computeMinSizes(engine, ci, depth + 1);
        const child = engine.elements.getConst(ci);

        // Skip floating elements - they don't affect parent's min size
        if (child.config.floating == null) {
            if (is_horizontal_layout) {
                if (!is_horizontal_scroll) content_width.* += child.computed.min_width;
                if (!is_vertical_scroll) content_height.* = @max(content_height.*, child.computed.min_height);
            } else {
                if (!is_horizontal_scroll) content_width.* = @max(content_width.*, child.computed.min_width);
                if (!is_vertical_scroll) content_height.* += child.computed.min_height;
            }
            child_count += 1;
        }

        child_idx = child.next_sibling_index;
    }

    // Add gaps between children (but not for scroll containers in scrollable direction)
    if (child_count > 1) {
        const gap: f32 = @floatFromInt(layout.child_gap);
        const gap_total = gap * @as(f32, @floatFromInt(child_count - 1));
        if (is_horizontal_layout) {
            if (!is_horizontal_scroll) content_width.* += gap_total;
        } else {
            if (!is_vertical_scroll) content_height.* += gap_total;
        }
    }
}

// ============================================================================
// Phase 2: Compute final sizes (top-down)
// ============================================================================

/// Resolve concrete sizes for this element given available space, then
/// distribute remaining space among children. Aspect-ratio derives height
/// from width here so that grow/shrink calculations see the final height.
pub fn computeFinalSizes(
    engine: *LayoutEngine,
    index: u32,
    available_width: f32,
    available_height: f32,
    depth: u32,
) void {
    // Assertions per CLAUDE.md: minimum 2 per function, put a limit on everything
    std.debug.assert(index < engine.elements.len()); // Valid element index
    std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md
    std.debug.assert(available_width >= 0 or available_width == std.math.floatMax(f32)); // Valid width

    const elem = engine.elements.get(index);
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

    // Content area for children (after padding)
    // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
    const content_width = @max(0, final_width - layout.padding.totalX());
    const content_height = @max(0, final_height - layout.padding.totalY());

    if (elem.first_child_index) |first_child| {
        // For scroll containers, allow children to overflow in scrollable directions
        // by passing a very large available size (prevents shrinking)
        var child_available_width = content_width;
        var child_available_height = content_height;

        if (elem.config.scroll) |scroll| {
            if (scroll.horizontal) child_available_width = std.math.floatMax(f32);
            if (scroll.vertical) child_available_height = std.math.floatMax(f32);
        }

        distributeSpace(engine, first_child, layout, child_available_width, child_available_height, depth);
    }
}

/// Distribute available space among children (handles grow and shrink).
/// Coordinator: delegates to the uniform-grow fast path first, then falls
/// back to the two-pass shrink/grow algorithm.
pub fn distributeSpace(
    engine: *LayoutEngine,
    first_child: u32,
    layout: LayoutConfig,
    width: f32,
    height: f32,
    depth: u32,
) void {
    // Assertions per CLAUDE.md
    std.debug.assert(width >= 0 or width == std.math.floatMax(f32));
    std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md

    const is_horizontal = layout.layout_direction.isHorizontal();
    const gap: f32 = @floatFromInt(layout.child_gap);
    const available = if (is_horizontal) width else height;

    // Fast path: Check if all children are uniform grow elements (very common case)
    if (tryUniformGrowFastPath(engine, first_child, is_horizontal, width, height, available, gap, depth)) {
        return;
    }

    // Slow path: classify children, then dispatch to shrink or grow
    const totals = sumDesiredSizes(engine, first_child, is_horizontal, available);
    const total_gap = if (totals.child_count > 1) gap * @as(f32, @floatFromInt(totals.child_count - 1)) else 0;
    const size_to_distribute = available - totals.total_desired - total_gap;

    if (size_to_distribute < 0 and totals.total_desired > 0) {
        distributeShrink(engine, first_child, is_horizontal, available, width, height, totals.total_desired, size_to_distribute, depth);
    } else {
        distributeGrow(engine, first_child, is_horizontal, width, height, totals.grow_count, size_to_distribute, depth);
    }
}

/// Pre-pass totals from `distributeSpace`: how many children grow, how much
/// non-grow desired space they occupy, and the count itself (for gaps).
const ChildTotals = struct {
    grow_count: u32,
    total_desired: f32,
    child_count: u32,
};

/// Inspect each non-floating child and classify by sizing type. The
/// numbers feed both the shrink-vs-grow decision in `distributeSpace`
/// and the gap accounting.
fn sumDesiredSizes(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    available: f32,
) ChildTotals {
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(available >= 0 or available == std.math.floatMax(f32));

    var grow_count: u32 = 0;
    var total_desired: f32 = 0;
    var child_count: u32 = 0;

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
            .grow => blk: {
                grow_count += 1;
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
        child_idx = child.next_sibling_index;
        child_count += 1;
    }

    return .{ .grow_count = grow_count, .total_desired = total_desired, .child_count = child_count };
}

// ============================================================================
// Phase 2 — fast path for uniform grow children
// ============================================================================

/// Result of the speculative uniform-grow pass: was it eligible, and how
/// many floating siblings did we step over (we recompute per-child size
/// after subtracting those out)?
const SpeculativeResult = struct {
    eligible: bool,
    floating_count: u32,
    has_grandchildren: bool,
};

/// Fast path for uniform grow children — speculative single pass with early
/// bailout. Returns `true` when the fast path handled distribution.
fn tryUniformGrowFastPath(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    width: f32,
    height: f32,
    available: f32,
    gap: f32,
    depth: u32,
) bool {
    // Assertions per CLAUDE.md: minimum 2 per function
    std.debug.assert(first_child < engine.elements.len()); // Valid child index
    std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit

    // Get parent's child_count to pre-compute sizes (avoids counting pass)
    const first = engine.elements.getConst(first_child);
    const parent_idx = first.parent_index orelse return false;
    const parent = engine.elements.getConst(parent_idx);
    const total_children = parent.child_count;

    if (total_children == 0) return false;

    // Pre-compute uniform size assuming no floating elements
    const total_gap = if (total_children > 1) gap * @as(f32, @floatFromInt(total_children - 1)) else 0;
    var per_child = @max(0, (available - total_gap) / @as(f32, @floatFromInt(total_children)));
    const cross_size = if (is_horizontal) height else width;

    const result = speculativeUniformAssign(engine, first_child, is_horizontal, per_child, cross_size);
    if (!result.eligible) return false;

    // If we had floating elements, recalculate and re-assign
    if (result.floating_count > 0) {
        const actual_children = total_children - result.floating_count;
        if (actual_children == 0) return false;

        const actual_gap = if (actual_children > 1) gap * @as(f32, @floatFromInt(actual_children - 1)) else 0;
        per_child = @max(0, (available - actual_gap) / @as(f32, @floatFromInt(actual_children)));
        reassignUniformSizes(engine, first_child, is_horizontal, per_child, cross_size);
    }

    // Handle grandchildren recursion in a separate pass (only if needed)
    if (result.has_grandchildren) {
        distributeToGrandchildren(engine, first_child, is_horizontal, depth);
    }

    return true;
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
    // Assertions per CLAUDE.md: minimum 2 per function
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

        // Track grandchildren
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

    return .{ .eligible = true, .floating_count = floating_count, .has_grandchildren = has_grandchildren };
}

/// Fast-path eligibility check: both axes are unbounded `grow` and no
/// aspect ratio is in play. Anything else routes to the slow path.
fn isUnconstrainedGrow(child: *const LayoutElement, is_horizontal: bool) bool {
    // Assertions per CLAUDE.md: minimum 2 per function
    std.debug.assert(child.config.layout.aspect_ratio == null or child.config.layout.aspect_ratio.? > 0);
    std.debug.assert(UNCONSTRAINED_MAX > 0);

    // Aspect ratio requires special handling - bail to slow path
    if (child.config.layout.aspect_ratio != null) return false;

    const main_sizing = if (is_horizontal) child.config.layout.sizing.width else child.config.layout.sizing.height;
    const main_ok = switch (main_sizing.value) {
        .grow => |mm| mm.min == 0 and mm.max >= UNCONSTRAINED_MAX,
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
    // Assertions per CLAUDE.md: minimum 2 per function
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

/// Distribute space to grandchildren after uniform assignment
fn distributeToGrandchildren(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    depth: u32,
) void {
    // Assertions per CLAUDE.md: minimum 2 per function
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(depth < MAX_RECURSION_DEPTH);

    _ = is_horizontal;
    var child_idx: ?u32 = first_child;
    while (child_idx) |ci| {
        const child = engine.elements.get(ci);
        if (child.config.floating == null) {
            if (child.first_child_index) |grandchild| {
                const child_layout = child.config.layout;
                const content_width = @max(0, child.computed.sized_width - child_layout.padding.totalX());
                const content_height = @max(0, child.computed.sized_height - child_layout.padding.totalY());
                distributeSpace(engine, grandchild, child_layout, content_width, content_height, depth + 1);
            }
        }
        child_idx = child.next_sibling_index;
    }
}

// ============================================================================
// Phase 2 — shrink / grow distribution (slow path)
// ============================================================================

/// Shrink children proportionally when content exceeds available space.
/// `total_desired > 0` is asserted so the ratio math is well-defined.
fn distributeShrink(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    available: f32,
    width: f32,
    height: f32,
    total_desired: f32,
    size_to_distribute: f32,
    depth: u32,
) void {
    std.debug.assert(size_to_distribute < 0);
    std.debug.assert(total_desired > 0);

    const overflow = -size_to_distribute;
    const shrink_ratio = @max(0, 1.0 - overflow / total_desired);

    var child_idx: ?u32 = first_child;
    while (child_idx) |ci| {
        const child = engine.elements.get(ci);

        // Skip floating elements
        if (child.config.floating != null) {
            child_idx = child.next_sibling_index;
            continue;
        }

        assignShrunkSize(child, is_horizontal, available, width, height, shrink_ratio);
        recurseShrinkChildren(engine, child, depth);

        child_idx = child.next_sibling_index;
    }
}

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

/// Recurse `distributeSpace` into a shrunk child's content area, honoring
/// scroll-overflow semantics on the scrollable axes.
fn recurseShrinkChildren(engine: *LayoutEngine, child: *LayoutElement, depth: u32) void {
    std.debug.assert(depth < MAX_RECURSION_DEPTH);
    const child_layout = child.config.layout;

    // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
    var content_width = @max(0, child.computed.sized_width - child_layout.padding.totalX());
    var content_height = @max(0, child.computed.sized_height - child_layout.padding.totalY());

    // For scroll containers, allow children to overflow in scrollable directions
    if (child.config.scroll) |scroll| {
        if (scroll.horizontal) content_width = std.math.floatMax(f32);
        if (scroll.vertical) content_height = std.math.floatMax(f32);
    }

    if (child.first_child_index) |grandchild| {
        distributeSpace(engine, grandchild, child_layout, content_width, content_height, depth + 1);
    }
}

/// Distribute extra space to grow elements (slow path). Non-grow children
/// take their desired size, then we recurse into each child via
/// `computeFinalSizes` so nested layouts run on accurate constraints.
fn distributeGrow(
    engine: *LayoutEngine,
    first_child: u32,
    is_horizontal: bool,
    width: f32,
    height: f32,
    grow_count: u32,
    size_to_distribute: f32,
    depth: u32,
) void {
    std.debug.assert(size_to_distribute >= 0 or grow_count == 0);

    const per_grow = if (grow_count > 0) @max(0, size_to_distribute) / @as(f32, @floatFromInt(grow_count)) else 0;

    var child_idx: ?u32 = first_child;
    while (child_idx) |ci| {
        const child = engine.elements.get(ci);

        // Skip floating elements
        if (child.config.floating != null) {
            child_idx = child.next_sibling_index;
            continue;
        }

        const child_sizing_main = if (is_horizontal) child.config.layout.sizing.width else child.config.layout.sizing.height;
        const child_desired: f32 = switch (child_sizing_main.value) {
            .grow => 0, // handled separately
            .fit => |mm| @max(if (is_horizontal) child.computed.min_width else child.computed.min_height, mm.max),
            .fixed => |mm| mm.min,
            .percent => |p| (if (is_horizontal) width else height) * p.value,
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

        computeFinalSizes(engine, ci, child_width, child_height, depth + 1);
        child_idx = child.next_sibling_index;
    }
}

// ============================================================================
// Phase 2b: Text wrapping (container widths now known)
// ============================================================================

/// Wrap text under each element once container widths are settled, and
/// propagate height changes back up to fit-content parents.
pub fn computeTextWrapping(engine: *LayoutEngine, index: u32) !void {
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

    // Recurse to children
    if (elem.first_child_index) |first_child| {
        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            try computeTextWrapping(engine, ci);
            child_idx = engine.elements.getConst(ci).next_sibling_index;
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

/// Propagate child height changes up to fit-content parents
pub fn propagateHeightChange(engine: *LayoutEngine, parent_idx: ?u32) void {
    var idx = parent_idx;
    while (idx) |pi| {
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
            if (is_vertical) {
                total_height += child.computed.sized_height;
            } else {
                total_height = @max(total_height, child.computed.sized_height);
            }
            child_idx = child.next_sibling_index;
            child_count += 1;
        }

        if (is_vertical and child_count > 1) {
            total_height += gap * @as(f32, @floatFromInt(child_count - 1));
        }

        const new_height = total_height + padding.totalY();
        parent.computed.sized_height = @max(sizing.getMin(), @min(sizing.getMax(), new_height));

        idx = parent.parent_index;
    }
}

// ============================================================================
// Text wrapping — Phase 2.1 two-pass algorithm
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
    // Assertions per CLAUDE.md: minimum 2 per function
    std.debug.assert(max_width >= 0 or config.wrap_mode == .none);
    std.debug.assert(text_str.len <= std.math.maxInt(u32)); // Ensure offsets fit in u32

    // Short-circuit on no-op inputs. Empty text was caught by the PR 10
    // fuzzer — `findWordBoundaries` documents `text_str.len > 0` as a
    // precondition, so the gate must live here at the public boundary.
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
    // line carries the same `line_width` the pre-split function emitted.
    var lines: FixedCapacityArray(types.WrappedLine, MAX_LINES_PER_TEXT) = .{};
    var residual: LineResidual = .{};
    const max_line_width = accumulateWordsIntoLines(words.slice(), config.wrap_mode, max_width, &lines, &residual);

    // Emit final line (matches original tail-emit semantics, width included).
    const final_max = finalizeLastLine(text_str, residual, &lines);

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

/// Carryover state from the accumulator into `finalizeLastLine` — keeps
/// the byte offset where the in-progress line started and the width that
/// has been accumulated so far (sans trailing whitespace). Equivalent to
/// the two locals that lived inside the pre-split `wrapText` body.
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
            lines.append(.{
                .start_offset = line_start,
                .length = word.end - line_start,
                .width = total_width,
            }) catch break;
            max_line_width = @max(max_line_width, total_width);

            line_start = word.end + 1; // +1 to skip the newline byte
            line_width = 0;
            line_width_with_space = 0;
            continue;
        }

        const potential_width = line_width_with_space + word.width;
        if (wrap_mode == .words and potential_width > max_width and line_width > 0) {
            // Overflow - emit current line WITHOUT this word.
            lines.append(.{
                .start_offset = line_start,
                .length = word.start - line_start,
                .width = line_width,
            }) catch break;
            max_line_width = @max(max_line_width, line_width);

            line_start = word.start;
            line_width = word.width;
            line_width_with_space = word.width + word.trailing_space_width;
        } else if (wrap_mode == .words and word.width > max_width and line_width == 0) {
            // Single word is wider than max_width - force it onto its own line.
            lines.append(.{
                .start_offset = word.start,
                .length = word.end - word.start,
                .width = word.width,
            }) catch break;
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
/// last line break. Returns the width contribution so `wrapText` can fold
/// it into `max_line_width`. Matches the pre-split function's behavior of
/// stashing the accumulator's final `line_width` on the trailing line.
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

    lines.append(.{
        .start_offset = residual.line_start,
        .length = @intCast(trimmed.len),
        .width = residual.line_width,
    }) catch return 0; // Best effort for final line
    return residual.line_width;
}

// ============================================================================
// Word-boundary scanning (Phase 2.1 helper)
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
            if (emitOnNewline(&state)) {
                state.in_word = false;
                state.word_start = state.byte_pos + codepoint_len;
                state.byte_pos += codepoint_len;
                continue;
            }
            // overflow inside emitOnNewline — bail with whatever we have
            return @intCast(words.len);
        } else if (is_space) {
            if (state.in_word) {
                if (!emitOnSpace(&state)) return @intCast(words.len);
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

/// Append a word at a newline boundary. Returns `false` only on overflow,
/// which causes the caller to abort the scan with the partial result.
fn emitOnNewline(state: *WordScanState) bool {
    if (state.in_word) {
        const word_text = state.text[state.word_start..state.byte_pos];
        const word_width = state.measure_fn(word_text, state.config.font_id, state.config.font_size, null, state.user_data).width;
        state.words.append(.{
            .start = state.word_start,
            .end = state.byte_pos,
            .width = word_width,
            .trailing_space_width = 0,
            .has_newline = true,
        }) catch return false;
    } else {
        // Empty line (newline with no preceding word content)
        state.words.append(.{
            .start = state.byte_pos,
            .end = state.byte_pos,
            .width = 0,
            .trailing_space_width = 0,
            .has_newline = true,
        }) catch return false;
    }
    return true;
}

/// Append a word ending at a space character. Caller guarantees `in_word`.
fn emitOnSpace(state: *WordScanState) bool {
    std.debug.assert(state.in_word);

    const word_text = state.text[state.word_start..state.byte_pos];
    const word_width = state.measure_fn(word_text, state.config.font_id, state.config.font_size, null, state.user_data).width;
    state.words.append(.{
        .start = state.word_start,
        .end = state.byte_pos,
        .width = word_width,
        .trailing_space_width = state.cached_space_width,
        .has_newline = false,
    }) catch return false;
    return true;
}

/// Append the trailing word at end-of-string (no terminating space/newline).
fn emitFinalWord(state: *WordScanState) void {
    std.debug.assert(state.in_word);
    std.debug.assert(state.word_start < state.text.len);

    const word_text = state.text[state.word_start..];
    const word_width = state.measure_fn(word_text, state.config.font_id, state.config.font_size, null, state.user_data).width;
    state.words.append(.{
        .start = state.word_start,
        .end = @intCast(state.text.len),
        .width = word_width,
        .trailing_space_width = 0,
        .has_newline = false,
    }) catch {};
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
