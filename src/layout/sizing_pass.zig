// Mutates `LayoutElement.computed.{min_,sized_}{width,height}`; positions
// belong to `position_pass.zig`. No pass recurses (CLAUDE.md §6): each pass
// keeps an explicit stack of open parents bounded by the engine's open depth
// and visits elements in the recursive passes' order, and elements are
// stored in pre-order, so a subtree is the contiguous index range
// `root..subtreeEnd(root)`. Helpers are `pub` because
// `position_pass.computeFloatingSizesWithText` re-enters the pipeline
// mid-frame for floating subtrees.

const std = @import("std");

const engine_mod = @import("engine.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutElement = engine_mod.LayoutElement;
const BoundedList = engine_mod.BoundedList;
const WordInfo = engine_mod.WordInfo;
const TextConfig = types.TextConfig;
const SizingAxis = types.SizingAxis;
const LayoutConfig = types.LayoutConfig;
const MeasureTextFn = engine_mod.MeasureTextFn;

/// The passes' explicit stacks live on the call stack at the framework's
/// depth ceiling (128 frames of a few dozen bytes) and are bounded at run time
/// by the engine's `box_depth_max`, so no pass needs reserved scratch.
const box_depth_ceiling = @import("../core/limits.zig").box_depth_ceiling;
const UNCONSTRAINED_MAX = engine_mod.UNCONSTRAINED_MAX;

/// One past the last element of `root`'s subtree: the next sibling of `root`
/// or of its nearest ancestor that has one, else the end of the list. The
/// walk climbs at most the tree's depth, which the open stack bounds.
pub fn subtreeEnd(engine: *const LayoutEngine, root: u32) u32 {
    const count = engine.elements.len();
    std.debug.assert(root < count);
    var index = root;
    var steps: u32 = 0;
    while (steps <= engine.capacity.box_depth_max) : (steps += 1) {
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
    /// The children's floors along the width, as `content_width` sums or
    /// takes the widest of their minimums.
    content_floor: f32,
    /// Non-floating children added so far, for the gaps.
    flow_count: u32,
    is_horizontal: bool,
    is_horizontal_scroll: bool,
    is_vertical_scroll: bool,
};

/// Content minimums for `root`'s whole subtree, floating elements included
/// (they size themselves but do not count toward their parent).
pub fn computeMinSizes(engine: *LayoutEngine, root: u32) void {
    if (engine.floors_differ) {
        computeMinSizesWith(true, engine, root);
    } else {
        computeMinSizesWith(false, engine, root);
    }
}

/// `floors` is `engine.floors_differ`, at compile time: without a text whose
/// floor is narrower than its line, every floor equals its minimum, so the
/// walk copies minimums rather than summing floors beside them.
fn computeMinSizesWith(comptime floors: bool, engine: *LayoutEngine, root: u32) void {
    std.debug.assert(root < engine.elements.len());
    if (engine.elements.getConst(root).first_child_index == null) {
        finishMinSize(floors, engine.elements.get(root), 0, 0, 0);
        return;
    }

    // A frame per open level: the open stack bounds the tree's depth.
    var stack: [box_depth_ceiling]MinSizeFrame = undefined;
    stack[0] = openMinSizeFrame(engine, root);
    var depth: u32 = 1;
    var open_count: u32 = 1;
    while (depth > 0) {
        std.debug.assert(open_count <= engine.elements.len()); // Each parent once.
        const frame = &stack[depth - 1];
        if (addChildMinSizes(floors, engine, frame)) |child_index| {
            std.debug.assert(depth < engine.capacity.box_depth_max);
            stack[depth] = openMinSizeFrame(engine, child_index);
            depth += 1;
            open_count += 1;
        } else {
            const parent = engine.elements.get(frame.index);
            addGaps(floors, frame, parent.config.layout.child_gap);
            if (parent.config.layout.wrap and !frame.is_horizontal_scroll) {
                const widest = widestChildMin(engine, parent);
                frame.content_width = widest.min;
                frame.content_floor = widest.floor;
            }
            finishMinSize(
                floors,
                parent,
                frame.content_width,
                frame.content_height,
                frame.content_floor,
            );
            depth -= 1;
            if (depth > 0) addChildMinSize(floors, &stack[depth - 1], parent);
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
        .content_floor = 0,
        .flow_count = 0,
        .is_horizontal = elem.config.layout.layout_direction.isHorizontal(),
        .is_horizontal_scroll = if (elem.config.scroll) |scroll| scroll.horizontal else false,
        .is_vertical_scroll = if (elem.config.scroll) |scroll| scroll.vertical else false,
    };
}

/// Finish and add `frame`'s remaining leaf children until one has children
/// of its own: return it for the walk to open, its siblings left for later,
/// or null once every child is added.
fn addChildMinSizes(comptime floors: bool, engine: *LayoutEngine, frame: *MinSizeFrame) ?u32 {
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
        finishMinSize(floors, child, 0, 0, 0);
        addChildMinSize(floors, frame, child);
    }
    frame.cursor = null;
    return null;
}

/// Add one finished child's minimum along the parent's main axis (sum) and
/// cross axis (max), respecting scroll-direction opt-outs. Floating children
/// do not affect their parent's minimum.
fn addChildMinSize(comptime floors: bool, frame: *MinSizeFrame, child: *const LayoutElement) void {
    std.debug.assert(child.computed.min_width >= 0);
    std.debug.assert(child.computed.floor_width <= child.computed.min_width);
    if (child.config.floating != null) return;
    const min_width = child.computed.min_width;
    const min_height = child.computed.min_height;
    const floor_width = child.computed.floor_width;
    if (frame.is_horizontal) {
        if (!frame.is_horizontal_scroll) {
            frame.content_width += min_width;
            if (floors) frame.content_floor += floor_width;
        }
        if (!frame.is_vertical_scroll) frame.content_height = @max(frame.content_height, min_height);
    } else {
        if (!frame.is_horizontal_scroll) {
            frame.content_width = @max(frame.content_width, min_width);
            if (floors) frame.content_floor = @max(frame.content_floor, floor_width);
        }
        if (!frame.is_vertical_scroll) frame.content_height += min_height;
    }
    frame.flow_count += 1;
}

/// Add gaps between the flow children, but not for scroll containers in
/// their scrollable direction.
fn addGaps(comptime floors: bool, frame: *MinSizeFrame, child_gap: u16) void {
    std.debug.assert(frame.cursor == null); // Every child is added.
    if (frame.flow_count > 1) {
        const gap: f32 = @floatFromInt(child_gap);
        const gap_total = gap * @as(f32, @floatFromInt(frame.flow_count - 1));
        if (frame.is_horizontal) {
            if (!frame.is_horizontal_scroll) {
                frame.content_width += gap_total;
                if (floors) frame.content_floor += gap_total;
            }
        } else {
            if (!frame.is_vertical_scroll) frame.content_height += gap_total;
        }
    }
}

/// A wrapping row can be as narrow as its widest child, which may get a line
/// of its own: its children's widest minimum and widest floor, without gaps,
/// replace the sums a row takes. Once per wrapping row, so rows that do not
/// wrap pay nothing per child.
fn widestChildMin(
    engine: *const LayoutEngine,
    parent: *const LayoutElement,
) struct { min: f32, floor: f32 } {
    std.debug.assert(parent.config.layout.wrap);
    std.debug.assert(parent.config.layout.layout_direction.isHorizontal());
    var widest: f32 = 0;
    var widest_floor: f32 = 0;
    var cursor = parent.first_child_index;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.getConst(index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            widest = @max(widest, child.computed.min_width);
            widest_floor = @max(widest_floor, child.computed.floor_width);
        }
    }
    std.debug.assert(widest_floor <= widest);
    return .{ .min = widest, .floor = widest_floor };
}

/// Write one element's minimum and floor from its children's: widen them to
/// its text, add padding, then apply its own sizing-axis constraints.
fn finishMinSize(
    comptime floors: bool,
    elem: *LayoutElement,
    children_width: f32,
    children_height: f32,
    children_floor: f32,
) void {
    std.debug.assert(children_width >= 0);
    std.debug.assert(children_floor <= children_width or !floors);
    var content_width = children_width;
    var content_height = children_height;
    var content_floor = children_floor;

    if (elem.text_data) |td| {
        content_width = @max(content_width, td.measured_width);
        content_height = @max(content_height, td.measured_height);
        content_floor = @max(content_floor, td.floor_width);
    }

    const padding = elem.config.layout.padding;
    const sizing = elem.config.layout.sizing;
    elem.computed.min_width = applyMinMax(content_width + padding.totalX(), sizing.width);
    elem.computed.min_height = applyMinMax(content_height + padding.totalY(), sizing.height);
    // Floors and minimums are summed in the same order, so they are equal to
    // the bit unless word-wrapping text lies below: most elements copy the
    // minimum. Clamping and padding are monotonic, so a floor that differs
    // stays at most the minimum.
    if (!floors or content_floor == content_width) {
        elem.computed.floor_width = elem.computed.min_width;
    } else {
        elem.computed.floor_width = applyMinMax(content_floor + padding.totalX(), sizing.width);
    }
    std.debug.assert(elem.computed.floor_width <= elem.computed.min_width);
}

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
    /// The free space per grow weight, which sizes grow children under both
    /// rules.
    factor: f32,
    /// Under `.shrink`, the cap on every fit and grow child along the main
    /// axis, never below the child's floor: the widest give way first.
    level: f32,
    /// What a `.percent` child takes its fraction of along the main axis: the
    /// content size less the gaps between flow children, as Clay sizes it, so
    /// percents that add up to 1 fill the parent exactly.
    percent_basis: f32,
};

const SizingRule = enum {
    /// The uniform-grow fast path already wrote every child's size.
    assigned,
    /// The children overflow: fit and grow children shrink, largest first,
    /// to `level`, none below its floor.
    shrink,
    /// The children fit: grow children share the free space by weight.
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
    std.debug.assert(available_width >= 0 or available_width == std.math.floatMax(f32));

    sizeElement(engine, engine.elements.get(root), available_width, available_height);
    if (engine.elements.getConst(root).first_child_index == null) return;

    const root_plan = planChildSizes(engine, root);
    if (!root_plan.has_grandchildren) {
        sizeLeafChildren(engine, &root_plan);
        return;
    }

    // A frame per open level: the open stack bounds the tree's depth.
    var stack: [box_depth_ceiling]SizingFrame = undefined;
    stack[0] = root_plan;
    var depth: u32 = 1;
    var open_count: u32 = 1;
    while (depth > 0) {
        std.debug.assert(open_count <= engine.elements.len()); // Each parent once.
        var opened: SizingFrame = undefined;
        if (sizeSiblings(engine, &stack[depth - 1], &opened)) {
            std.debug.assert(depth < engine.capacity.box_depth_max);
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
            sizeByRule(engine, frame, child);
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
            sizeByRule(engine, frame, child);
        }
    }
}

/// Size one non-floating child by its parent's planned rule.
inline fn sizeByRule(engine: *LayoutEngine, frame: *const SizingFrame, child: *LayoutElement) void {
    std.debug.assert(child.config.floating == null);
    std.debug.assert(frame.factor >= 0);
    std.debug.assert(frame.level >= 0);
    switch (frame.rule) {
        .assigned => {},
        .shrink => assignShrunkSize(engine, child, frame),
        .grow => assignGrownSize(
            engine,
            child,
            frame.is_horizontal,
            frame.width,
            frame.height,
            frame.factor,
            frame.percent_basis,
        ),
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
        .level = std.math.floatMax(f32),
        .percent_basis = 0,
    };
    if (parent.config.layout.wrap) {
        std.debug.assert(is_horizontal);
        engine.heights_derived = true; // Its aspect children's heights too.
        engine.elements.get(parent_index).min_height_dirty = true;
        frame.has_grandchildren = sizeWrappedChildren(
            engine,
            parent_index,
            content.width,
            content.height,
        );
        return frame; // Every child is sized: `.assigned`.
    }
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

    const totals = sumDesiredSizes(engine, first_child, is_horizontal);
    frame.has_grandchildren = totals.has_grandchildren;
    planDistribution(engine, &frame, &totals, available, gap);
    return frame;
}

/// Choose the slow path's rule. Grow children share the free space by
/// weight, each at least its floor. When that cannot fit, because the other
/// children already overflow or a grow child's floor is above its share, the
/// children shrink as Clay shrinks them: the widest fit and grow children
/// give way first, down to a common `level`, and none goes below its floor.
/// Fixed and percent children keep their size. What floors still cannot fit
/// overflows, as in CSS flexbox and Clay. Inline, with `shrinkLevel`: the
/// sizing pass calls it once per parent, and outlined beside its second
/// caller in the heights pass it cost a sizing pass 2 % more instructions.
inline fn planDistribution(
    engine: *const LayoutEngine,
    frame: *SizingFrame,
    totals: *const ChildTotals,
    available: f32,
    gap: f32,
) void {
    std.debug.assert(totals.grow_weight_total >= 0);
    std.debug.assert(totals.total_desired >= 0);
    std.debug.assert(totals.percent_total >= 0);
    const gap_count: f32 = @floatFromInt(@max(totals.child_count, 1) - 1);
    const total_gap = gap * gap_count;
    frame.percent_basis = @max(0, available - total_gap);
    const total_desired = totals.total_desired + totals.percent_total * frame.percent_basis;
    const free = available - total_desired - total_gap;
    frame.rule = .grow;
    frame.level = std.math.floatMax(f32);
    frame.factor = if (totals.grow_weight_total > 0)
        @max(0, free) / totals.grow_weight_total
    else
        0;
    std.debug.assert(frame.factor >= 0);
    // Without overflow and with every grow child above its floor, the
    // shares fill the space exactly; with nothing that can shrink, sizes
    // stay as `.grow` gives them. Neither needs a walk.
    if (free >= 0 and frame.factor >= totals.grow_floor_ratio_max) return;
    if (totals.shrinkable_count == 0) return;

    // No fit or grow child is wider than this before shrinking: a grow
    // child takes max(floor, factor × weight), which is at most its weight
    // times the larger of its floor per weight and the factor.
    const grow_per_weight = @max(totals.grow_floor_ratio_max, frame.factor);
    const largest = @max(totals.fit_desired_max, grow_per_weight * totals.grow_weight_max);
    const level = shrinkLevel(engine, frame, available - total_gap, largest);
    if (level == std.math.floatMax(f32)) return; // Grow maximums left room.
    frame.rule = .shrink;
    frame.level = level;
}

/// Leveling rounds before `shrinkLevel` bisects instead. A round settles
/// every child at one size, so ordinary rows need one or two; a row of many
/// distinct sizes would need a round per size.
const shrink_round_count_max: u32 = 16;

/// Bisection steps after the rounds: each halves the interval, so a level up
/// to 2^20 px is found within 2^-12 px, below what any display shows.
const shrink_step_count: u32 = 32;

/// The level at which the children fit in `target`, or `floatMax` when they
/// already fit. Leveling starts at `largest`, at least every fit and grow
/// child's size, so the first walk already finds the children that give way.
/// Exact leveling, as Clay shrinks: from above, every child at the level
/// gives way together until the total fits or the level reaches
/// the next size where a child joins or stops at its floor. At most
/// `shrink_round_count_max` rounds and `shrink_step_count` bisection steps,
/// one walk over the children each, and only on a parent that overflows.
/// Inline into `planDistribution`, as it was with one caller.
inline fn shrinkLevel(
    engine: *const LayoutEngine,
    frame: *const SizingFrame,
    target: f32,
    largest: f32,
) f32 {
    std.debug.assert(largest >= 0);
    std.debug.assert(std.math.isFinite(largest));
    var level: f32 = largest;
    var round: u32 = 0;
    while (round < shrink_round_count_max) : (round += 1) {
        const step = levelStep(engine, frame, level);
        const excess = step.total - target;
        if (excess <= 0) {
            // Nothing is capped at the starting level: the children fit.
            std.debug.assert(round == 0); // Later rounds stop above the target.
            return std.math.floatMax(f32);
        }
        if (step.active_count > 0) {
            const active: f32 = @floatFromInt(step.active_count);
            const next = level - excess / active;
            if (next >= step.breakpoint) return next;
        } else {
            // Every shrinkable child is at its floor, or above `level` with
            // a floor at it: nothing gives way, at this level or below.
            if (step.breakpoint == 0) return level;
        }
        level = step.breakpoint;
    }
    return bisectLevel(engine, frame, target, level);
}

/// The highest level in `[0, high_start]` at which the children fit, by
/// bisection, once leveling ran out of rounds. Level 0 leaves every
/// shrinkable child at its floor; when even that overflows, the floors do.
fn bisectLevel(
    engine: *const LayoutEngine,
    frame: *const SizingFrame,
    target: f32,
    high_start: f32,
) f32 {
    std.debug.assert(high_start >= 0);
    std.debug.assert(std.math.isFinite(high_start));
    if (levelStep(engine, frame, 0).total > target) return 0;
    var low: f32 = 0; // Fits.
    var high: f32 = high_start; // Overflows.
    var step: u32 = 0;
    while (step < shrink_step_count) : (step += 1) {
        const middle = low + (high - low) / 2;
        if (levelStep(engine, frame, middle).total <= target) {
            low = middle;
        } else {
            high = middle;
        }
    }
    std.debug.assert(low <= high);
    return low;
}

/// The children at one level: their main-axis total, how many give way as
/// the level falls (fit or grow children at the level, above their floor),
/// and the next level below where that count changes: the largest size
/// under the level, or the highest floor under it of a child that gives
/// way; 0 when there is none.
const LevelStep = struct { total: f32, active_count: u32, breakpoint: f32 };

fn levelStep(engine: *const LayoutEngine, frame: *const SizingFrame, level: f32) LevelStep {
    std.debug.assert(level >= 0);
    const is_horizontal = frame.is_horizontal;
    var step: LevelStep = .{ .total = 0, .active_count = 0, .breakpoint = 0 };
    var cursor = frame.cursor;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.getConst(index);
        cursor = child.next_sibling_index;
        if (child.config.floating != null) continue;
        const layout = &child.config.layout;
        const sizing = if (is_horizontal) layout.sizing.width else layout.sizing.height;
        const tentative = shrunkMainSize(child, frame, std.math.floatMax(f32));
        if (sizing.value == .fit or sizing.value == .grow) {
            const floor = floorMain(child, is_horizontal);
            step.total += @min(tentative, @max(floor, level));
            if (tentative < level) {
                step.breakpoint = @max(step.breakpoint, tentative);
            } else if (floor < level) {
                step.active_count += 1;
                step.breakpoint = @max(step.breakpoint, floor);
            }
        } else {
            step.total += tentative;
        }
    }
    std.debug.assert(step.breakpoint < level or level == 0);
    return step;
}

/// A child's main-axis size under `.shrink` at `level`: its size as `.grow`
/// would give it, capped at `level` when it is fit or grow, and never below
/// its floor.
fn shrunkMainSize(child: *const LayoutElement, frame: *const SizingFrame, level: f32) f32 {
    std.debug.assert(child.config.floating == null);
    std.debug.assert(level >= 0);
    const is_horizontal = frame.is_horizontal;
    const both = child.config.layout.sizing;
    const sizing = if (is_horizontal) both.width else both.height;
    const content = if (is_horizontal) child.computed.min_width else child.computed.min_height;
    const floor = floorMain(child, is_horizontal);
    return switch (sizing.value) {
        .grow => |grow| blk: {
            const share = applyMinMax(@max(floor, frame.factor * grow.weight), sizing);
            break :blk @min(share, @max(floor, level));
        },
        .fit => |mm| blk: {
            const desired = @max(content, if (mm.max >= 1e10) content else mm.max);
            break :blk @min(desired, @max(floor, level));
        },
        .fixed => |mm| mm.min,
        .percent => |p| @max(p.min, @min(p.max, frame.percent_basis * p.value)),
    };
}

/// How narrow (or short) a child can be along the main axis without cutting
/// its content. Heights have no separate floor before text wraps.
inline fn floorMain(child: *const LayoutElement, is_horizontal: bool) f32 {
    const floor = if (is_horizontal) child.computed.floor_width else child.computed.min_height;
    std.debug.assert(floor >= 0);
    return floor;
}

/// Resolve one element's concrete size for the space its parent offers.
/// Aspect-ratio derives height from width here so that grow/shrink
/// calculations see the final height.
fn sizeElement(
    engine: *LayoutEngine,
    elem: *LayoutElement,
    available_width: f32,
    available_height: f32,
) void {
    std.debug.assert(available_width >= 0 or available_width == std.math.floatMax(f32));
    std.debug.assert(available_height >= 0 or available_height == std.math.floatMax(f32));
    const layout = elem.config.layout;
    const sizing = layout.sizing;

    const final_width = computeAxisSize(sizing.width, elem.computed.min_width, available_width);
    var final_height = computeAxisSize(sizing.height, elem.computed.min_height, available_height);

    if (layout.aspect_ratio) |ratio| {
        final_height = final_width / ratio;
        engine.heights_derived = true;
        elem.min_height_dirty = true;
    }

    elem.computed.sized_width = final_width;
    elem.computed.sized_height = final_height;
}

/// Pre-pass totals from `planChildSizes`: the grow children's summed
/// weights, how much fit and fixed desired space they occupy, the percent
/// children's summed fractions (of a basis known only once the count is),
/// and the count itself (for gaps).
const ChildTotals = struct {
    grow_weight_total: f32,
    total_desired: f32,
    percent_total: f32,
    /// The largest floor per weight among grow children: a share below it
    /// leaves that child at its floor, past its share.
    grow_floor_ratio_max: f32,
    /// The largest grow weight and the widest fit child's desired size, which
    /// bound where leveling starts (`shrinkLevel`).
    grow_weight_max: f32,
    fit_desired_max: f32,
    /// Fit and grow children: the ones an overflow can shrink.
    shrinkable_count: u32,
    child_count: u32,
    has_grandchildren: bool,
};

/// Inspect each non-floating child and classify by sizing type. The
/// numbers feed both the shrink-vs-grow decision in `planChildSizes`
/// and the gap accounting.
fn sumDesiredSizes(engine: *LayoutEngine, first_child: u32, is_horizontal: bool) ChildTotals {
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(first_child > 0); // Pre-order: a child follows its parent.

    var grow_weight_total: f32 = 0;
    var total_desired: f32 = 0;
    var percent_total: f32 = 0;
    var grow_floor_ratio_max: f32 = 0;
    var grow_weight_max: f32 = 0;
    var fit_desired_max: f32 = 0;
    var shrinkable_count: u32 = 0;
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
                shrinkable_count += 1;
                const ratio = floorMain(child, is_horizontal) / grow.weight;
                grow_floor_ratio_max = @max(grow_floor_ratio_max, ratio);
                grow_weight_max = @max(grow_weight_max, grow.weight);
                break :blk child_min; // grow elements only contribute their min
            },
            .fit => |mm| blk: {
                // If max is unbounded (floatMax), use min_width as desired
                // Otherwise use the max constraint as desired size
                const effective_max = if (mm.max >= 1e10) child_min else mm.max;
                const desired = @max(child_min, effective_max);
                shrinkable_count += 1;
                fit_desired_max = @max(fit_desired_max, desired);
                break :blk desired;
            },
            .fixed => |mm| mm.min, // fixed wants exactly this size
            .percent => |p| blk: {
                percent_total += p.value;
                break :blk 0; // Added once the basis is known.
            },
        };

        if (child_sizing.value != .grow) total_desired += child_desired;
        if (child.first_child_index != null) has_grandchildren = true;
        child_idx = child.next_sibling_index;
        child_count += 1;
    }

    std.debug.assert(std.math.isFinite(grow_weight_total));
    std.debug.assert(percent_total >= 0);
    return .{
        .grow_weight_total = grow_weight_total,
        .total_desired = total_desired,
        .percent_total = percent_total,
        .grow_floor_ratio_max = grow_floor_ratio_max,
        .grow_weight_max = grow_weight_max,
        .fit_desired_max = fit_desired_max,
        .shrinkable_count = shrinkable_count,
        .child_count = child_count,
        .has_grandchildren = has_grandchildren,
    };
}

/// Result of the speculative uniform-grow pass: eligibility, floating
/// siblings stepped over (sizes are recomputed after subtracting them),
/// and whether any flow child has children.
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
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(gap >= 0);

    // Get parent's child_count to pre-compute sizes (avoids counting pass)
    const first = engine.elements.getConst(first_child);
    const parent_idx = first.parent_index orelse return .ineligible;
    const parent = engine.elements.getConst(parent_idx);
    const total_children = parent.child_count;

    if (total_children == 0) return .ineligible;

    const total_gap = if (total_children > 1) gap * @as(f32, @floatFromInt(total_children - 1)) else 0;
    var per_child = @max(0, (available - total_gap) / @as(f32, @floatFromInt(total_children)));
    const cross_size = if (is_horizontal) height else width;

    const result = speculativeUniformAssign(engine, first_child, is_horizontal, per_child, cross_size);
    if (!result.eligible) return .ineligible;

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

        // A share below a child's floor would cut its content: the slow
        // path shrinks its siblings instead.
        const too_narrow = floorMain(child, is_horizontal) > per_child;
        if (!isUnconstrainedGrow(child, is_horizontal) or too_narrow) {
            return .{ .eligible = false, .floating_count = 0, .has_grandchildren = false };
        }

        // A floating child sizes itself, so only flow children count here.
        if (child.first_child_index != null) has_grandchildren = true;

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

/// Assign one child's size when its parent shrinks its children: the main
/// axis capped at the frame's level (`shrunkMainSize`), then the cross axis
/// and aspect ratio. A leaf: no recursion, no side effects beyond
/// `child.computed` and, for an aspect ratio, `engine.heights_derived`.
fn assignShrunkSize(engine: *LayoutEngine, child: *LayoutElement, frame: *const SizingFrame) void {
    std.debug.assert(frame.rule == .shrink);
    std.debug.assert(child.config.floating == null);
    const sizing = child.config.layout.sizing;
    const main = shrunkMainSize(child, frame, frame.level);
    if (frame.is_horizontal) {
        child.computed.sized_width = main;
        const min_height = child.computed.min_height;
        child.computed.sized_height = computeAxisSize(sizing.height, min_height, frame.height);
    } else {
        const min_width = child.computed.min_width;
        child.computed.sized_width = computeAxisSize(sizing.width, min_width, frame.width);
        child.computed.sized_height = main;
    }

    if (child.config.layout.aspect_ratio) |ratio| {
        if (frame.is_horizontal) {
            child.computed.sized_height = child.computed.sized_width / ratio;
        } else {
            child.computed.sized_width = child.computed.sized_height * ratio;
        }
        engine.heights_derived = true;
        child.min_height_dirty = true;
    }
    std.debug.assert(main >= 0);
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
/// Takes the frame's fields as values (CLAUDE.md §20): a pointer or an
/// options struct made the per-child call reload or rebuild them.
fn assignGrownSize(
    engine: *LayoutEngine,
    child: *LayoutElement,
    is_horizontal: bool,
    width: f32,
    height: f32,
    per_weight: f32,
    percent_basis: f32,
) void {
    std.debug.assert(per_weight >= 0);
    std.debug.assert(percent_basis >= 0);
    std.debug.assert(child.config.floating == null);

    const sizing = child.config.layout.sizing;
    const child_sizing_main = if (is_horizontal) sizing.width else sizing.height;
    const child_min_main = if (is_horizontal) child.computed.min_width else child.computed.min_height;
    const child_desired: f32 = switch (child_sizing_main.value) {
        .grow => 0, // handled separately
        .fit => |mm| @max(child_min_main, mm.max),
        .fixed => |mm| mm.min,
        // `sizeElement` takes the fraction of what it is offered: offer the
        // basis, so the fraction is taken once.
        .percent => percent_basis,
    };

    const per_grow: f32 = switch (child_sizing_main.value) {
        .grow => |grow| per_weight * grow.weight,
        else => 0,
    };
    var child_width: f32 = undefined;
    var child_height: f32 = undefined;

    if (is_horizontal) {
        child_width = if (child_sizing_main.value == .grow)
            @max(child.computed.floor_width, per_grow)
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

    sizeElement(engine, child, child_width, child_height);
}

/// One line of a wrapping row, as `breakWrapLine` finds it.
const WrapLine = struct {
    /// The next line's first child, or null for the last line.
    end: ?u32,
    /// The flow children's widths before growing, and the gaps between them.
    used: f32,
    /// What of `used` the grow children take. They share the line's free
    /// width from 0, as they share a row that does not wrap.
    grow_basis: f32,
    grow_weight_total: f32,
    flow_count: u32,
    has_grandchildren: bool,
};

/// Size a wrapping row's children and break them into lines. Each child
/// takes its own width; a line ends before the child that would overflow the
/// content width; grow children share their line's free width by weight; a
/// line is as tall as its tallest child, and cross-axis grow children fill
/// it. A fit-height row becomes as tall as its lines, `child_gap` apart.
/// Returns whether any flow child has children.
///
/// Work: three walks over each line's children, no storage. The lines are
/// recorded in each child's `line_start`.
fn sizeWrappedChildren(engine: *LayoutEngine, parent_index: u32, width: f32, height: f32) bool {
    const parent = engine.elements.get(parent_index);
    std.debug.assert(parent.config.layout.wrap);
    std.debug.assert(width >= 0);
    const gap: f32 = @floatFromInt(parent.config.layout.child_gap);
    var line_first: ?u32 = parent.first_child_index;
    var lines_height: f32 = 0;
    var line_count: u32 = 0;
    var has_grandchildren = false;
    while (line_first) |first| {
        std.debug.assert(line_count < engine.elements.len()); // A line holds a child.
        const line = breakWrapLine(engine, first, width, gap);
        if (line.flow_count > 0) {
            const line_height = sizeWrapLine(engine, first, &line, width, height);
            if (line_count > 0) lines_height += gap;
            lines_height += line_height;
            line_count += 1;
            if (line.has_grandchildren) has_grandchildren = true;
        } else {
            std.debug.assert(line.end == null); // Only floating children were left.
        }
        line_first = line.end;
    }
    const sizing = parent.config.layout.sizing.height;
    if (sizing.value == .fit and parent.config.layout.aspect_ratio == null) {
        const padding_y = parent.config.layout.padding.totalY();
        parent.computed.sized_height = applyMinMax(lines_height + padding_y, sizing);
    }
    std.debug.assert(lines_height >= 0);
    return has_grandchildren;
}

/// Find the line that starts at `first`: its flow children while their
/// widths and gaps fit in `width`, and always at least one. Marks the first
/// flow child `line_start` and the others not.
fn breakWrapLine(engine: *LayoutEngine, first: u32, width: f32, gap: f32) WrapLine {
    std.debug.assert(gap >= 0);
    var line: WrapLine = .{
        .end = null,
        .used = 0,
        .grow_basis = 0,
        .grow_weight_total = 0,
        .flow_count = 0,
        .has_grandchildren = false,
    };
    var cursor: ?u32 = first;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.get(index);
        if (child.config.floating == null) {
            const basis = wrapBasis(child, width);
            const gap_before: f32 = if (line.flow_count > 0) gap else 0;
            if (line.flow_count > 0 and line.used + gap_before + basis > width) {
                line.end = index;
                break;
            }
            child.line_start = line.flow_count == 0;
            line.used += gap_before + basis;
            switch (child.config.layout.sizing.width.value) {
                .grow => |grow| {
                    line.grow_basis += basis;
                    line.grow_weight_total += grow.weight;
                },
                else => {},
            }
            line.flow_count += 1;
            if (child.first_child_index != null) line.has_grandchildren = true;
        }
        cursor = child.next_sibling_index;
    }
    std.debug.assert(line.grow_basis <= line.used);
    return line;
}

/// A child's width before its line grows: a grow child's content minimum,
/// any other child its own width. Neither is wider than the line unless its
/// sizing minimum is, so one long child wraps alone instead of overflowing,
/// as a row that does not wrap shrinks its children.
fn wrapBasis(child: *const LayoutElement, width: f32) f32 {
    std.debug.assert(child.config.floating == null);
    const sizing = child.config.layout.sizing.width;
    const own = switch (sizing.value) {
        .grow => child.computed.min_width,
        else => computeAxisSize(sizing, child.computed.min_width, width),
    };
    std.debug.assert(own >= 0);
    return @min(own, @max(sizing.getMin(), width));
}

/// Size the children of one line: widths, then heights, the line's height
/// being its tallest child's. Returns that height.
fn sizeWrapLine(
    engine: *LayoutEngine,
    first: u32,
    line: *const WrapLine,
    width: f32,
    height: f32,
) f32 {
    std.debug.assert(line.flow_count > 0);
    // Free width, as `planChildSizes` computes it: the grow children's
    // minimums do not take it, so they share it by weight from 0.
    const free = width - (line.used - line.grow_basis);
    const per_weight: f32 = if (line.grow_weight_total > 0)
        @max(0, free) / line.grow_weight_total
    else
        0;
    var line_height: f32 = 0;
    var cursor: ?u32 = first;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        if (line.end) |end| if (index == end) break;
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            line_height = @max(line_height, sizeWrapChild(child, per_weight, width, height));
        }
    }
    // Cross-axis grow children fill the line, as `align-items: stretch`.
    cursor = first;
    visited = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        if (line.end) |end| if (index == end) break;
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        const layout = &child.config.layout;
        if (child.config.floating == null and layout.aspect_ratio == null) {
            if (layout.sizing.height.value == .grow) {
                child.computed.sized_height = applyMinMax(line_height, layout.sizing.height);
            }
        }
    }
    std.debug.assert(line_height >= 0);
    return line_height;
}

/// Size one child of a line: its width from `per_weight` when it grows, and
/// its height, a cross-axis grow child's being its minimum until the line's
/// height is known. Returns the height it adds to the line.
fn sizeWrapChild(child: *LayoutElement, per_weight: f32, width: f32, height: f32) f32 {
    std.debug.assert(per_weight >= 0);
    std.debug.assert(child.config.floating == null);
    const layout = &child.config.layout;
    const basis = wrapBasis(child, width);
    const grown = switch (layout.sizing.width.value) {
        .grow => |grow| blk: {
            const share = @max(child.computed.min_width, per_weight * grow.weight);
            break :blk applyMinMax(share, layout.sizing.width);
        },
        else => basis,
    };
    child.computed.sized_width = @min(grown, @max(layout.sizing.width.getMin(), width));
    if (layout.aspect_ratio) |ratio| {
        child.computed.sized_height = child.computed.sized_width / ratio;
        child.min_height_dirty = true;
    } else {
        child.computed.sized_height = switch (layout.sizing.height.value) {
            .grow => child.computed.min_height,
            else => computeAxisSize(layout.sizing.height, child.computed.min_height, height),
        };
    }
    std.debug.assert(child.computed.sized_width >= 0);
    return child.computed.sized_height;
}

/// A span along the cross axis of a wrapping row, from its content top.
pub const LineSpan = struct { start: f32, size: f32 };

/// Where the line holding flow child `target` of a wrapping row starts below
/// its content top, and how tall the line is; with `target` null, the height
/// of all its lines from 0. Lines start where the sizing pass set
/// `line_start`, `gap` apart, each as tall as its tallest child.
pub fn wrapLineSpan(
    engine: *const LayoutEngine,
    first_child: u32,
    gap: f32,
    target: ?u32,
) LineSpan {
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(gap >= 0);
    var line_top: f32 = 0;
    var line_height: f32 = 0;
    var line_count: u32 = 0;
    var target_found = false;
    var cursor: ?u32 = first_child;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.getConst(index);
        cursor = child.next_sibling_index;
        if (child.config.floating != null) continue;
        if (line_count == 0) std.debug.assert(child.line_start);
        if (child.line_start) {
            if (target_found) break;
            if (line_count > 0) line_top += line_height + gap;
            line_height = 0;
            line_count += 1;
        }
        line_height = @max(line_height, child.computed.sized_height);
        if (target) |target_index| {
            if (index == target_index) target_found = true;
        }
    }
    if (target != null) {
        std.debug.assert(target_found);
        return .{ .start = line_top, .size = line_height };
    }
    const total: f32 = if (line_count > 0) line_top + line_height else 0;
    return .{ .start = 0, .size = total };
}

/// Wrap the text in `root`'s subtree at the widths the sizing pass gave its
/// containers, skipping floating subtrees below `root`: each wraps in its own
/// pass once its root is sized (`position_pass.computeFloatingSizesWithText`).
/// A text that wraps to a height other than its one-line height marks the
/// frame's heights as derived from widths, so `computeHeights` runs.
pub fn computeTextWrapping(engine: *LayoutEngine, root: u32) !void {
    std.debug.assert(root < engine.elements.len());
    std.debug.assert(engine.floating_roots.len <= engine.capacity.floating_count_max);
    if (engine.floating_roots.len > 0) {
        try wrapSubtreeText(true, engine, root);
    } else {
        try wrapSubtreeText(false, engine, root);
    }
}

/// `skip_floating` is whether the frame has a floating element, at compile
/// time: without one, the walk does not read every element's `floating`.
fn wrapSubtreeText(comptime skip_floating: bool, engine: *LayoutEngine, root: u32) !void {
    const end = subtreeEnd(engine, root);
    std.debug.assert(end > root);
    var index = root;
    while (index < end) {
        assertPreOrder(engine, root, index);
        const elem = engine.elements.getConst(index);
        if (skip_floating and index != root and elem.config.floating != null) {
            index = subtreeEnd(engine, index);
            continue;
        }
        if (elem.text_data != null) try wrapElementText(engine, index);
        index += 1;
    }
    std.debug.assert(index == end);
}

/// Wrap one element's text, if it has any, at its parent's content width.
fn wrapElementText(engine: *LayoutEngine, index: u32) !void {
    const elem = engine.elements.get(index);

    if (elem.text_data) |*td| {
        const max_width = textContainerWidth(engine, elem);

        // Stored even when not wrapping; alignment reads it.
        td.container_width = max_width;

        // A text its row shrank below its one-line width wraps at the width
        // the row gave it, which `floor_width` keeps at least its widest word.
        const shrunk = elem.computed.sized_width < elem.computed.min_width;
        const wrap_width = if (shrunk) @min(max_width, elem.computed.sized_width) else max_width;

        if (td.config.wrap_mode != .none and wrap_width > 0) {
            const wrap_result = try wrapText(engine, td.text, td.config, wrap_width);
            td.wrapped_lines = wrap_result.lines;

            if (wrap_result.lines.len > 0) {
                if (wrap_result.total_height != td.measured_height) {
                    engine.heights_derived = true;
                    elem.min_height_dirty = true;
                }
                td.measured_width = wrap_result.max_line_width;
                td.measured_height = wrap_result.total_height;

                elem.computed.sized_width = wrap_result.max_line_width;
                elem.computed.sized_height = wrap_result.total_height;
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

/// Size heights in `root`'s subtree again once its text has wrapped, as Clay
/// sizes heights after widths. Every width is final by now, so wrapped text,
/// aspect ratios, and wrapping rows' lines give their real heights, and a
/// height that follows from its parent's or its siblings' is sized from
/// them: a stretched child reaches its row's wrapped height, and a grow child
/// in a column shares what its wrapped siblings leave. The sizing pass sized
/// heights from one-line text, which is right wherever no minimum height
/// under a parent changed; only the rest is sized again.
///
/// Work: a backward and a forward walk that read two flags per element; one
/// walk over the children of each parent whose minimum may have changed, and
/// one to three over the children of each parent whose children's heights
/// did. No storage. Floating subtrees below `root` hold no flags: their
/// sizing and wrapping run in their own pass.
pub fn computeHeights(engine: *LayoutEngine, root: u32, available_height: f32) void {
    std.debug.assert(engine.heights_derived);
    std.debug.assert(available_height >= 0);
    const end = subtreeEnd(engine, root);
    computeMinHeights(engine, root, end);
    const root_elem = engine.elements.get(root);
    const root_height = offeredHeight(root_elem, available_height);
    if (root_height != root_elem.computed.sized_height) root_elem.heights_dirty = true;
    root_elem.computed.sized_height = root_height;

    var index = root;
    while (index < end) : (index += 1) {
        assertPreOrder(engine, root, index);
        const elem = engine.elements.get(index);
        std.debug.assert(!elem.min_height_dirty);
        if (elem.heights_dirty) {
            @branchHint(.unlikely); // Off the path every unchanged box takes.
            elem.heights_dirty = false;
            std.debug.assert(elem.first_child_index != null);
            sizeChildHeights(engine, index);
        }
    }
}

/// Recompute the minimum height of each element marked `min_height_dirty`,
/// and when it changed, mark its parent: the parent's minimum may change too,
/// and its children's heights need sizing again. Pre-order puts children
/// after their parent, so walking backwards finishes every child before its
/// parent adds it up. A floating element's minimum takes no part in its
/// parent's, so it marks nothing above it.
fn computeMinHeights(engine: *LayoutEngine, root: u32, end: u32) void {
    std.debug.assert(root < end);
    std.debug.assert(end <= engine.elements.len());
    var index = end;
    while (index > root) {
        index -= 1;
        const elem = engine.elements.get(index);
        if (elem.min_height_dirty) {
            @branchHint(.unlikely); // Off the path every unchanged box takes.
            elem.min_height_dirty = false;
            const min_height = minHeight(engine, elem);
            std.debug.assert(min_height >= 0);
            const changed = min_height != elem.computed.min_height;
            elem.computed.min_height = min_height;
            if (changed and elem.config.floating == null and index > root) {
                const parent = engine.elements.get(elem.parent_index.?);
                parent.min_height_dirty = true;
                parent.heights_dirty = true;
            }
        }
    }
}

/// One element's minimum height, as `finishMinSize` computes it before text
/// wraps, but from wrapped text, wrapping rows' lines, and a height an
/// aspect ratio takes from the final width.
fn minHeight(engine: *const LayoutEngine, elem: *const LayoutElement) f32 {
    const layout = &elem.config.layout;
    if (layout.aspect_ratio) |ratio| {
        std.debug.assert(ratio > 0);
        return elem.computed.sized_width / ratio;
    }
    var content: f32 = 0;
    if (elem.text_data) |td| content = td.measured_height;
    std.debug.assert(content >= 0);
    const is_vertical_scroll = if (elem.config.scroll) |scroll| scroll.vertical else false;
    if (elem.first_child_index != null and !is_vertical_scroll) {
        content = @max(content, childrenMinHeight(engine, elem));
    }
    return applyMinMax(content + layout.padding.totalY(), layout.sizing.height);
}

/// The height `parent`'s flow children need at their minimums: stacked with
/// gaps in a column, the tallest in a row, and a wrapping row's lines, each
/// as tall as its tallest child, stacked with gaps.
fn childrenMinHeight(engine: *const LayoutEngine, parent: *const LayoutElement) f32 {
    const gap: f32 = @floatFromInt(parent.config.layout.child_gap);
    const wrap = parent.config.layout.wrap;
    const is_vertical = !parent.config.layout.layout_direction.isHorizontal();
    var total: f32 = 0;
    var line: f32 = 0;
    var flow_count: u32 = 0;
    var cursor = parent.first_child_index;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.getConst(index);
        cursor = child.next_sibling_index;
        if (child.config.floating != null) continue;
        const height = child.computed.min_height;
        if (wrap) {
            if (flow_count == 0) std.debug.assert(child.line_start);
            if (child.line_start and flow_count > 0) {
                total += line + gap;
                line = 0;
            }
            line = @max(line, height);
        } else {
            if (is_vertical) {
                total += height;
            } else {
                total = @max(total, height);
            }
        }
        flow_count += 1;
    }
    if (wrap) return total + line;
    if (is_vertical and flow_count > 1) total += gap * @as(f32, @floatFromInt(flow_count - 1));
    std.debug.assert(total >= 0);
    return total;
}

/// Size the heights of `parent_index`'s children from its final height: a
/// column shares its height along its main axis, as the sizing pass shares
/// widths; a row offers each child its height, so a grow child stretches to
/// it; a wrapping row stretches its grow children to their line.
fn sizeChildHeights(engine: *LayoutEngine, parent_index: u32) void {
    const parent = engine.elements.getConst(parent_index);
    const first_child = parent.first_child_index.?;
    std.debug.assert(first_child > parent_index); // Pre-order: children follow.
    const height = childContentArea(parent).height;
    std.debug.assert(!parent.heights_dirty); // `computeHeights` cleared it first.
    if (parent.config.layout.wrap) {
        stretchWrapLines(engine, first_child, height);
        return;
    }
    if (!parent.config.layout.layout_direction.isHorizontal()) {
        distributeColumnHeights(engine, parent_index, height);
        return;
    }
    var cursor: ?u32 = first_child;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) setHeight(child, offeredHeight(child, height));
    }
}

/// A column's children's heights, by the rule `planDistribution` chooses
/// for widths in a row: grow children share the free height by weight, and
/// an overflowing column shrinks its tallest fit and grow children first,
/// none below its minimum. Their minimums now hold wrapped text.
fn distributeColumnHeights(engine: *LayoutEngine, parent_index: u32, height: f32) void {
    std.debug.assert(height >= 0);
    const parent = engine.elements.getConst(parent_index);
    const first_child = parent.first_child_index.?;
    const gap: f32 = @floatFromInt(parent.config.layout.child_gap);
    var frame: SizingFrame = .{
        .cursor = first_child,
        .rule = .assigned,
        .is_horizontal = false,
        .has_grandchildren = false,
        .width = childContentArea(parent).width,
        .height = height,
        .factor = 0,
        .level = std.math.floatMax(f32),
        .percent_basis = 0,
    };
    const totals = sumDesiredSizes(engine, first_child, false);
    planDistribution(engine, &frame, &totals, height, gap);
    std.debug.assert(frame.rule != .assigned);

    var cursor: ?u32 = first_child;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) setHeight(child, columnChildHeight(child, &frame));
    }
}

/// One column child's height under its parent's rule: shrunk to the level,
/// or offered what `assignGrownSize` offers it, and resolved by its sizing.
/// An aspect child keeps the height its final width gives it.
fn columnChildHeight(child: *const LayoutElement, frame: *const SizingFrame) f32 {
    std.debug.assert(!frame.is_horizontal);
    std.debug.assert(frame.factor >= 0);
    if (child.config.layout.aspect_ratio != null) return child.computed.min_height;
    if (frame.rule == .shrink) return shrunkMainSize(child, frame, frame.level);
    const min_height = child.computed.min_height;
    const offered: f32 = switch (child.config.layout.sizing.height.value) {
        .grow => |grow| @max(min_height, frame.factor * grow.weight),
        .fit => |mm| @max(min_height, mm.max),
        .fixed => |mm| mm.min,
        .percent => frame.percent_basis,
    };
    return offeredHeight(child, offered);
}

/// The height an element takes when offered `offered`: what its sizing
/// gives it, or what its final width gives it under an aspect ratio.
fn offeredHeight(elem: *const LayoutElement, offered: f32) f32 {
    std.debug.assert(offered >= 0);
    if (elem.config.layout.aspect_ratio) |ratio| {
        std.debug.assert(ratio > 0);
        return elem.computed.sized_width / ratio;
    }
    const sizing = elem.config.layout.sizing.height;
    return computeAxisSize(sizing, elem.computed.min_height, offered);
}

/// Write a child's height in the heights pass, marking its children for
/// sizing again when it changed: they were sized from the old height.
inline fn setHeight(child: *LayoutElement, height: f32) void {
    std.debug.assert(height >= 0);
    std.debug.assert(child.config.floating == null);
    if (height != child.computed.sized_height and child.first_child_index != null) {
        child.heights_dirty = true;
    }
    child.computed.sized_height = height;
}

/// A wrapping row's lines, from the `line_start` marks the sizing pass set:
/// each line as tall as its tallest child, with its grow children stretched
/// to it, as `sizeWrapLine` sized them from one-line text.
fn stretchWrapLines(engine: *LayoutEngine, first_child: u32, height: f32) void {
    std.debug.assert(height >= 0);
    var line_first: ?u32 = first_child;
    var line_count: u32 = 0;
    while (line_first) |first| : (line_count += 1) {
        std.debug.assert(line_count < engine.elements.len()); // A line holds a child.
        const line = wrapLineHeight(engine, first, height);
        var cursor: ?u32 = first;
        var visited: u32 = 0;
        while (cursor) |index| : (visited += 1) {
            std.debug.assert(visited < engine.elements.len()); // Each sibling once.
            if (line.end) |end| if (index == end) break;
            const child = engine.elements.get(index);
            cursor = child.next_sibling_index;
            if (child.config.floating == null) {
                const sizing = child.config.layout.sizing.height;
                const child_height = if (stretchesInLine(child))
                    applyMinMax(line.height, sizing)
                else
                    offeredHeight(child, height);
                setHeight(child, child_height);
            }
        }
        line_first = line.end;
    }
}

/// Whether a wrapping row's child fills its line's height, as
/// `align-items: stretch`: a grow height not derived from its width.
inline fn stretchesInLine(child: *const LayoutElement) bool {
    std.debug.assert(child.config.floating == null);
    const layout = &child.config.layout;
    return layout.sizing.height.value == .grow and layout.aspect_ratio == null;
}

/// The line of a wrapping row that starts at `first`: as tall as its
/// tallest child, a stretching child counting its minimum, and the next
/// line's first child, or null for the last line.
fn wrapLineHeight(
    engine: *const LayoutEngine,
    first: u32,
    height: f32,
) struct { end: ?u32, height: f32 } {
    std.debug.assert(height >= 0);
    var line_height: f32 = 0;
    var flow_count: u32 = 0;
    var cursor: ?u32 = first;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.getConst(index);
        if (child.config.floating == null) {
            if (child.line_start and flow_count > 0) {
                return .{ .end = index, .height = line_height };
            }
            const child_height = if (stretchesInLine(child))
                child.computed.min_height
            else
                offeredHeight(child, height);
            line_height = @max(line_height, child_height);
            flow_count += 1;
        }
        cursor = child.next_sibling_index;
    }
    return .{ .end = null, .height = line_height };
}

/// Output of `wrapText` — owned by the per-frame arena.
pub const WrapResult = struct {
    lines: []types.WrappedLine,
    total_height: f32,
    max_line_width: f32,
};

/// Wrap text into lines based on available width. Two passes per batch:
///   1. `scanWords` measures each word ONCE, and each space and tab after
///      it at its own advance, until the word scratch is full or the text
///      ends.
///   2. `LinePacker` packs the batch's words onto lines, carrying the line
///      in progress into the next batch.
/// A text of any length wraps exactly as it would in one batch: the word
/// scratch bounds a batch, not a text, and the frame's line budget bounds
/// the lines. Returns a slice allocated from the per-frame arena, so it is
/// safe to stash on `TextData.wrapped_lines` for the rest of the frame.
///
/// Work: one measurement per word (cached by the text system) and one line
/// record per line; batches of `word_count_text_max` words keep the scratch
/// at 24 KiB whatever the text's length.
pub fn wrapText(
    engine: *LayoutEngine,
    text_str: []const u8,
    config: TextConfig,
    max_width: f32,
) !WrapResult {
    std.debug.assert(max_width >= 0 or config.wrap_mode == .none);
    std.debug.assert(text_str.len <= std.math.maxInt(u32)); // Ensure offsets fit in u32

    // Short-circuit on no-op inputs. `scanWords` requires `text_str.len > 0`,
    // so the empty-text gate must live here at the public boundary.
    if (config.wrap_mode == .none or max_width <= 0 or text_str.len == 0) {
        return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
    }

    if (engine.measure_text_fn == null) {
        return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
    }

    var lines: BoundedList(types.WrappedLine) = .{ .buffer = engine.line_scratch };
    const max_line_width = wrapLines(engine, text_str, config, max_width, &lines);
    claimWrappedLines(engine, lines.len);
    // Copy to arena for return (arena memory persists until frame end).
    const result_lines = try engine.arena.allocator().dupe(types.WrappedLine, lines.slice());
    const line_height = config.lineHeightPx();
    const total_height = line_height * @as(f32, @floatFromInt(@max(1, result_lines.len)));

    return .{
        .lines = result_lines,
        .total_height = total_height,
        .max_line_width = max_line_width,
    };
}

/// A text's size wrapped at `max_width` as layout would size it, without
/// keeping its lines: `cx.measureText` sizes a row from content during the
/// build, before layout. Unwrapped text is one measured line, as
/// `LayoutEngine.text` measures it. Uses the line scratch, which is free
/// until layout wraps at `endFrame`, and claims nothing from the frame.
pub fn measureWrapped(
    engine: *LayoutEngine,
    text_str: []const u8,
    config: TextConfig,
    max_width: f32,
) engine_mod.TextMeasurement {
    std.debug.assert(max_width >= 0);
    std.debug.assert(text_str.len <= std.math.maxInt(u32));
    const measure_fn = engine.measure_text_fn.?;
    const user_data = engine.measure_text_user_data;
    const one_line = measure_fn(text_str, config.font_id, config.font_size, null, user_data);
    if (config.wrap_mode == .none or max_width <= 0 or text_str.len == 0) return one_line;
    var lines: BoundedList(types.WrappedLine) = .{ .buffer = engine.line_scratch };
    const max_line_width = wrapLines(engine, text_str, config, max_width, &lines);
    const line_count: f32 = @floatFromInt(lines.len);
    const result: engine_mod.TextMeasurement = .{
        .width = max_line_width,
        .height = config.lineHeightPx() * line_count,
    };
    std.debug.assert(result.width >= 0);
    std.debug.assert(result.height > 0);
    return result;
}

/// Wrap `text_str` into `lines`, batch by batch through the word scratch,
/// and return the widest line. Shared by layout's wrap and `measureWrapped`
/// so a measured text and a laid-out one break at the same words.
fn wrapLines(
    engine: *LayoutEngine,
    text_str: []const u8,
    config: TextConfig,
    max_width: f32,
    lines: *BoundedList(types.WrappedLine),
) f32 {
    std.debug.assert(text_str.len > 0);
    std.debug.assert(lines.len == 0);
    const measure_fn = engine.measure_text_fn.?;
    var words: BoundedList(WordInfo) = .{ .buffer = engine.word_scratch };
    const user_data = engine.measure_text_user_data;
    var scan = WordScanState.init(text_str, measure_fn, config, user_data, &words);
    var packer: LinePacker = .{
        .text = text_str,
        .max_width = max_width,
        .wrap_words = config.wrap_mode == .words,
        .space_width = scan.space_width,
        .tab_width = scan.tab_width,
        .lines = lines,
    };
    // Each full batch consumes at least one word, hence one byte.
    var batch_count: u32 = 0;
    while (true) : (batch_count += 1) {
        std.debug.assert(batch_count <= text_str.len);
        words.len = 0;
        const done = scanWords(&scan);
        engine.word_count_used_max = @max(engine.word_count_used_max, words.len);
        for (words.slice()) |*word| packer.pack(word);
        if (done) break;
    }
    // The last line runs to the text's end, whitespace included; a text
    // ending in a newline has nothing after it.
    if (packer.line_start < text_str.len) packer.finishLine(@intCast(text_str.len));
    engine.line_count_used_max = @max(engine.line_count_used_max, lines.len);
    std.debug.assert(lines.len > 0);
    return packer.widest;
}

/// The widest word of `text_str` as layout's word breaking measures it: the
/// narrowest width it wraps at without cutting a word, and so a wrapping
/// text's floor. Scans the words in batches as `wrapLines` does, measuring
/// each once, and keeps no lines.
pub fn widestWord(engine: *LayoutEngine, text_str: []const u8, config: TextConfig) f32 {
    std.debug.assert(text_str.len > 0);
    std.debug.assert(config.wrap_mode == .words);
    const measure_fn = engine.measure_text_fn.?;
    var words: BoundedList(WordInfo) = .{ .buffer = engine.word_scratch };
    const user_data = engine.measure_text_user_data;
    var scan = WordScanState.init(text_str, measure_fn, config, user_data, &words);
    var widest: f32 = 0;
    var batch_count: u32 = 0;
    while (true) : (batch_count += 1) {
        std.debug.assert(batch_count <= text_str.len); // A batch consumes a byte.
        words.len = 0;
        const done = scanWords(&scan);
        engine.word_count_used_max = @max(engine.word_count_used_max, words.len);
        for (words.slice()) |*word| widest = @max(widest, word.width);
        if (done) break;
    }
    std.debug.assert(widest >= 0);
    return widest;
}

/// Packs measured words onto lines as GPUI's `LineWrapper` does: a line's
/// width is the advance of every codepoint on it, its leading whitespace
/// and each space and tab included. A word's whitespace stays on its line,
/// before the break, and counts toward fitting it, so a drawn line never
/// passes the wrap width: a word that does not fit after what the line
/// holds, or whose whitespace does not, starts the next line. Whitespace
/// that does not fit even then breaks where it overflows, so the rest leads
/// the next line. A line's first word stays whole however wide; that is
/// the one line that may pass the width. With `.newlines`, only newlines
/// break. The line in progress carries from one batch of words to the
/// next, so a text wraps as it would in one batch.
const LinePacker = struct {
    text: []const u8,
    max_width: f32,
    wrap_words: bool,
    space_width: f32,
    tab_width: f32,
    lines: *BoundedList(types.WrappedLine),
    /// The line in progress: its first byte, and the advance of every
    /// codepoint packed on it so far.
    line_start: u32 = 0,
    line_width: f32 = 0,
    /// The widest finished line.
    widest: f32 = 0,

    fn pack(self: *LinePacker, word: *const WordInfo) void {
        std.debug.assert(self.line_start <= word.start);
        std.debug.assert(word.start <= word.end);
        std.debug.assert(word.end <= word.space_end);
        std.debug.assert(word.space_end <= self.text.len);
        if (!self.wrap_words) {
            self.line_width += word.width + word.space_width;
        } else {
            self.packWord(word);
        }
        if (word.has_newline) {
            std.debug.assert(self.text[word.space_end] == '\n');
            self.finishLine(word.space_end);
            self.line_start = word.space_end + 1; // The newline byte.
        }
    }

    /// The word, then its whitespace in one step when all of it fits, as
    /// most does, else codepoint by codepoint (`packSpace`).
    fn packWord(self: *LinePacker, word: *const WordInfo) void {
        std.debug.assert(self.wrap_words);
        const holds = word.start > self.line_start;
        if (holds and self.line_width + word.width > self.max_width) {
            self.finishLine(word.start);
            self.line_start = word.start;
        }
        const width_before = self.line_width;
        self.line_width += word.width;
        if (self.line_width + word.space_width <= self.max_width) {
            self.line_width += word.space_width;
            return;
        }
        self.packSpace(word, width_before);
    }

    /// The whitespace after `word` that does not all fit, one byte (a space
    /// or tab) at a time. Its first overflow moves the word, with the
    /// whitespace so far, to the next line, unless the word is the line's
    /// first; an overflow there breaks inside the whitespace.
    fn packSpace(self: *LinePacker, word: *const WordInfo, width_before: f32) void {
        var word_first = word.start == self.line_start;
        var position = word.end;
        while (position < word.space_end) : (position += 1) {
            const byte = self.text[position];
            std.debug.assert(byte == ' ' or byte == '\t');
            const advance = if (byte == '\t') self.tab_width else self.space_width;
            if (self.line_width + advance > self.max_width and !word_first) {
                const moved = self.line_width - width_before;
                self.line_width = width_before;
                self.finishLine(word.start);
                self.line_start = word.start;
                self.line_width = moved;
                word_first = true;
            }
            if (self.line_width + advance > self.max_width and position > self.line_start) {
                self.finishLine(position);
                self.line_start = position;
            }
            self.line_width += advance;
        }
        std.debug.assert(position == word.space_end);
    }

    /// End the line in progress at `end`, exclusive, and start an empty one
    /// there; the caller moves `line_start` past a newline.
    fn finishLine(self: *LinePacker, end: u32) void {
        std.debug.assert(self.line_start <= end);
        std.debug.assert(self.line_width >= 0);
        appendLine(self.lines, .{
            .start_offset = self.line_start,
            .length = end - self.line_start,
            .width = self.line_width,
        });
        self.widest = @max(self.widest, self.line_width);
        self.line_start = end;
        self.line_width = 0;
    }
};

/// Count a text's lines against the frame's budget before they take arena
/// space, so an over-budget frame names the pool instead of failing as an
/// arena allocation.
fn claimWrappedLines(engine: *LayoutEngine, line_count: u32) void {
    std.debug.assert(line_count <= engine.line_scratch.len);
    const capacity = engine.capacity.wrapped_line_count_frame_max;
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

/// One text's lines share the frame's budget: the scratch holds as many as
/// the frame may wrap, so a single text past it is a capacity-planning error
/// that stops here, naming the same field as `claimWrappedLines`.
fn appendLine(lines: *BoundedList(types.WrappedLine), line: types.WrappedLine) void {
    lines.append(line) catch std.debug.panic("wrapped lines exhausted: capacity {d} " ++
        "(paint.glyph_count_frame_max), {d} in use by one text, 1 requested", .{
        lines.buffer.len,
        lines.len,
    });
}

/// `scanWords` stops a batch before the scratch fills.
fn appendWord(words: *BoundedList(WordInfo), word: WordInfo) void {
    std.debug.assert(words.len < words.buffer.len);
    std.debug.assert(word.start <= word.end);
    words.append(word) catch unreachable;
}

/// Scanner state for `findWordBoundaries`: the unit in progress, a word and
/// the run of spaces and tabs after it. A paragraph's leading whitespace is
/// a unit with an empty word.
const WordScanState = struct {
    text: []const u8,
    measure_fn: MeasureTextFn,
    config: TextConfig,
    user_data: ?*anyopaque,
    words: *BoundedList(WordInfo),
    /// A space's and a tab's advance, measured once: constant for a font
    /// and size, they save a measure call per whitespace byte.
    space_width: f32,
    tab_width: f32,
    byte_pos: u32 = 0,
    phase: Phase = .idle,
    /// The unit's word: its first byte, its end once measured, and width.
    word_start: u32 = 0,
    word_end: u32 = 0,
    word_width: f32 = 0,
    /// The advance of the unit's whitespace so far.
    space_width_sum: f32 = 0,

    const Phase = enum { idle, word, space };

    fn init(
        text: []const u8,
        measure_fn: MeasureTextFn,
        config: TextConfig,
        user_data: ?*anyopaque,
        words: *BoundedList(WordInfo),
    ) WordScanState {
        std.debug.assert(text.len > 0);
        std.debug.assert(words.len == 0);
        const space = measure_fn(" ", config.font_id, config.font_size, null, user_data);
        const tab = measure_fn("\t", config.font_id, config.font_size, null, user_data);
        std.debug.assert(space.width >= 0);
        std.debug.assert(tab.width >= 0);
        return .{
            .text = text,
            .measure_fn = measure_fn,
            .config = config,
            .user_data = user_data,
            .words = words,
            .space_width = space.width,
            .tab_width = tab.width,
        };
    }

    /// Measure the word that ends at `byte_pos`, once.
    fn endWord(self: *WordScanState) void {
        std.debug.assert(self.phase == .word);
        std.debug.assert(self.word_start < self.byte_pos);
        const word_text = self.text[self.word_start..self.byte_pos];
        const config = self.config;
        const size = self.measure_fn(word_text, config.font_id, config.font_size, null, self.user_data);
        self.word_end = self.byte_pos;
        self.word_width = size.width;
        self.space_width_sum = 0;
        self.phase = .space;
    }

    /// Start a unit at `byte_pos`: a word, or whitespace with no word.
    fn startUnit(self: *WordScanState, phase: Phase) void {
        std.debug.assert(phase != .idle);
        self.word_start = self.byte_pos;
        self.word_end = self.byte_pos;
        self.word_width = 0;
        self.space_width_sum = 0;
        self.phase = phase;
    }

    /// Append the unit in progress, its whitespace ending at `byte_pos`.
    fn emitUnit(self: *WordScanState, has_newline: bool) void {
        std.debug.assert(self.phase == .space);
        appendWord(self.words, .{
            .start = self.word_start,
            .end = self.word_end,
            .space_end = self.byte_pos,
            .width = self.word_width,
            .space_width = self.space_width_sum,
            .has_newline = has_newline,
        });
        self.phase = .idle;
    }
};

/// Find word boundaries in text and measure each word exactly once.
/// Returns the number of words appended. Caller supplies an empty `words`
/// array with room for every word of `text_str`.
pub fn findWordBoundaries(
    text_str: []const u8,
    measure_fn: MeasureTextFn,
    config: TextConfig,
    user_data: ?*anyopaque,
    words: *BoundedList(WordInfo),
) u32 {
    var state = WordScanState.init(text_str, measure_fn, config, user_data, words);
    const done = scanWords(&state);
    std.debug.assert(done);
    return words.len;
}

/// Scan from where the last batch stopped, appending each unit (a word
/// measured once, and the spaces and tabs after it, each at its own
/// advance) until `words` is full or the text ends. Returns whether the
/// text ended; a full batch resumes at the codepoint it stopped before.
/// Each codepoint appends at most one unit, so a free slot at the top of
/// the loop is room for it.
fn scanWords(state: *WordScanState) bool {
    const text_str = state.text;
    std.debug.assert(text_str.len > 0);
    std.debug.assert(state.words.len == 0); // Each batch starts empty.
    std.debug.assert(state.byte_pos <= text_str.len);

    var iter = std.unicode.Utf8Iterator{ .bytes = text_str, .i = state.byte_pos };
    while (state.byte_pos < text_str.len) {
        if (state.words.len == state.words.buffer.len) return false;
        const codepoint_slice = iter.nextCodepointSlice().?;
        const codepoint_len: u32 = @intCast(codepoint_slice.len);
        const c = codepoint_slice[0]; // First byte for ASCII checks
        const is_ascii = codepoint_len == 1;
        if (is_ascii and c == '\n') {
            // A newline ends the unit in progress, or an empty one.
            if (state.phase == .word) state.endWord();
            if (state.phase == .idle) state.startUnit(.space);
            state.emitUnit(true);
        } else if (is_ascii and (c == ' ' or c == '\t')) {
            if (state.phase == .word) state.endWord();
            if (state.phase == .idle) state.startUnit(.space);
            state.space_width_sum += if (c == '\t') state.tab_width else state.space_width;
        } else {
            // A word starts after whitespace, which ends the unit before.
            if (state.phase == .space) state.emitUnit(false);
            if (state.phase == .idle) state.startUnit(.word);
        }
        state.byte_pos += codepoint_len;
        std.debug.assert(iter.i == state.byte_pos);
    }

    // The last unit, if the text does not end in a newline: one more slot.
    if (state.phase != .idle) {
        if (state.words.len == state.words.buffer.len) return false;
        if (state.phase == .word) state.endWord();
        state.emitUnit(false);
    }
    return true;
}

pub fn applyMinMax(size: f32, axis: SizingAxis) f32 {
    const min_val = axis.getMin();
    const max_val = axis.getMax();
    return @max(min_val, @min(max_val, size));
}

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
