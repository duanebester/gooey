const std = @import("std");

const engine_mod = @import("engine.zig");
const grid_mod = @import("grid.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutElement = engine_mod.LayoutElement;
const BoundedList = engine_mod.BoundedList;
const WordInfo = engine_mod.WordInfo;
const TextConfig = types.TextConfig;
const SizingAxis = types.SizingAxis;
const LayoutConfig = types.LayoutConfig;
const MeasureTextFn = engine_mod.MeasureTextFn;

const box_depth_ceiling = @import("../core/limits.zig").box_depth_ceiling;
const UNCONSTRAINED_MAX = engine_mod.UNCONSTRAINED_MAX;

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
    unreachable;
}

inline fn assertPreOrder(engine: *const LayoutEngine, root: u32, index: u32) void {
    if (index > root) {
        const parent = engine.elements.getConst(index).parent_index.?;
        std.debug.assert(parent < index);
        std.debug.assert(parent >= root);
    }
}

const MinSizeFrame = struct {
    index: u32,
    cursor: ?u32,
    content_width: f32,
    content_height: f32,
    content_floor: f32,
    flow_count: u32,
    is_horizontal: bool,
    is_horizontal_scroll: bool,
    is_vertical_scroll: bool,
};

pub fn computeMinSizes(engine: *LayoutEngine, root: u32) void {
    const grids = engine.grid_count > 0;
    if (engine.floors_differ) {
        if (grids) {
            computeMinSizesWith(.{ .floors = true, .grids = true }, engine, root);
        } else {
            computeMinSizesWith(.{ .floors = true, .grids = false }, engine, root);
        }
    } else {
        if (grids) {
            computeMinSizesWith(.{ .floors = false, .grids = true }, engine, root);
        } else {
            computeMinSizesWith(.{ .floors = false, .grids = false }, engine, root);
        }
    }
}

const MinSizeWalk = struct { floors: bool, grids: bool };

fn computeMinSizesWith(comptime walk: MinSizeWalk, engine: *LayoutEngine, root: u32) void {
    std.debug.assert(root < engine.elements.len());
    if (!walk.grids) std.debug.assert(engine.grid_count == 0);
    if (engine.elements.getConst(root).first_child_index == null) {
        finishLeafMinSize(walk, engine, root);
        return;
    }

    var stack: [box_depth_ceiling]MinSizeFrame = undefined;
    stack[0] = openMinSizeFrame(engine, root);
    var depth: u32 = 1;
    var open_count: u32 = 1;
    while (depth > 0) {
        std.debug.assert(open_count <= engine.elements.len());
        const frame = &stack[depth - 1];
        if (addChildMinSizes(walk, engine, frame)) |child_index| {
            std.debug.assert(depth < engine.capacity.box_depth_max);
            stack[depth] = openMinSizeFrame(engine, child_index);
            depth += 1;
            open_count += 1;
        } else {
            const parent = engine.elements.get(frame.index);
            addGaps(walk.floors, frame, parent.config.layout.child_gap);
            if (parent.config.layout.wrap and !frame.is_horizontal_scroll) {
                const widest = widestChildMin(engine, parent);
                frame.content_width = widest.min;
                frame.content_floor = widest.floor;
            }
            if (walk.grids and parent.config.layout.grid == .grid) measureGrid(engine, frame);
            finishMinSize(
                walk.floors,
                parent,
                frame.content_width,
                frame.content_height,
                frame.content_floor,
            );
            depth -= 1;
            if (depth > 0) addChildMinSize(walk.floors, &stack[depth - 1], parent);
        }
    }
}

fn measureGrid(engine: *LayoutEngine, frame: *MinSizeFrame) void {
    std.debug.assert(frame.cursor == null);
    const minimums = grid_mod.measure(engine, frame.index);
    if (!frame.is_horizontal_scroll) {
        frame.content_width = minimums.width;
        frame.content_floor = minimums.floor;
    }
    if (!frame.is_vertical_scroll) frame.content_height = minimums.height;
}

fn openMinSizeFrame(engine: *LayoutEngine, index: u32) MinSizeFrame {
    const elem = engine.elements.getConst(index);
    const first_child = elem.first_child_index.?;
    std.debug.assert(first_child > index);
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

fn addChildMinSizes(comptime walk: MinSizeWalk, engine: *LayoutEngine, frame: *MinSizeFrame) ?u32 {
    std.debug.assert(frame.index < engine.elements.len());
    var cursor = frame.cursor;
    var sibling_count: u32 = 0;
    while (cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len());
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        cursor = child.next_sibling_index;
        if (child.first_child_index != null) {
            frame.cursor = cursor;
            return child_index;
        }
        finishLeafMinSize(walk, engine, child_index);
        addChildMinSize(walk.floors, frame, child);
    }
    frame.cursor = null;
    return null;
}

inline fn finishLeafMinSize(comptime walk: MinSizeWalk, engine: *LayoutEngine, index: u32) void {
    const elem = engine.elements.get(index);
    std.debug.assert(elem.first_child_index == null);
    if (walk.grids and elem.config.layout.grid == .grid) {
        @branchHint(.unlikely);
        const minimums = grid_mod.measure(engine, index);
        finishMinSize(walk.floors, elem, minimums.width, minimums.height, minimums.floor);
        return;
    }
    finishMinSize(walk.floors, elem, 0, 0, 0);
}

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

fn addGaps(comptime floors: bool, frame: *MinSizeFrame, child_gap: u16) void {
    std.debug.assert(frame.cursor == null);
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
        std.debug.assert(visited < engine.elements.len());
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
    if (!floors or content_floor == content_width) {
        elem.computed.floor_width = elem.computed.min_width;
    } else {
        elem.computed.floor_width = applyMinMax(content_floor + padding.totalX(), sizing.width);
    }
    std.debug.assert(elem.computed.floor_width <= elem.computed.min_width);
}

const SizingFrame = struct {
    cursor: ?u32,
    rule: SizingRule,
    is_horizontal: bool,
    has_grandchildren: bool,
    width: f32,
    height: f32,
    factor: f32,
    level: f32,
    percent_basis: f32,
};

const SizingRule = enum {
    assigned,
    shrink,
    grow,
};

pub fn computeFinalSizes(
    engine: *LayoutEngine,
    root: u32,
    available_width: f32,
    available_height: f32,
) void {
    std.debug.assert(root < engine.elements.len());
    std.debug.assert(available_width >= 0 or available_width == std.math.floatMax(f32));

    sizeElement(engine, engine.elements.get(root), available_width, available_height);
    if (engine.elements.getConst(root).first_child_index == null) return;

    const root_plan = planChildSizes(engine, root);
    if (!root_plan.has_grandchildren) {
        sizeLeafChildren(engine, &root_plan);
        return;
    }

    var stack: [box_depth_ceiling]SizingFrame = undefined;
    stack[0] = root_plan;
    var depth: u32 = 1;
    var open_count: u32 = 1;
    while (depth > 0) {
        std.debug.assert(open_count <= engine.elements.len());
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

fn sizeSiblings(engine: *LayoutEngine, frame: *SizingFrame, opened: *SizingFrame) bool {
    std.debug.assert(frame.factor >= 0);
    var cursor = frame.cursor;
    var sibling_count: u32 = 0;
    while (cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len());
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

fn sizeLeafChildren(engine: *LayoutEngine, frame: *const SizingFrame) void {
    std.debug.assert(!frame.has_grandchildren);
    var cursor = frame.cursor;
    var sibling_count: u32 = 0;
    while (cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len());
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            std.debug.assert(child.first_child_index == null);
            sizeByRule(engine, frame, child);
        }
    }
}

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

fn planChildSizes(engine: *LayoutEngine, parent_index: u32) SizingFrame {
    const parent = engine.elements.getConst(parent_index);
    const first_child = parent.first_child_index.?;
    std.debug.assert(first_child > parent_index);
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
    if (parent.config.layout.grid != .none) {
        @branchHint(.unlikely);
        frame.has_grandchildren = grid_mod.sizeCells(
            engine,
            parent_index,
            content.width,
            content.height,
        );
        return frame;
    }
    if (parent.config.layout.wrap) {
        std.debug.assert(is_horizontal);
        engine.heights_derived = true;
        engine.elements.get(parent_index).min_height_dirty = true;
        frame.has_grandchildren = sizeWrappedChildren(
            engine,
            parent_index,
            content.width,
            content.height,
        );
        return frame;
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
            frame.cursor = null;
            frame.has_grandchildren = false;
            return frame;
        },
    }

    const totals = sumDesiredSizes(engine, first_child, is_horizontal);
    frame.has_grandchildren = totals.has_grandchildren;
    planDistribution(engine, &frame, &totals, available, gap);
    return frame;
}

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
    if (free >= 0 and frame.factor >= totals.grow_floor_ratio_max) return;
    if (totals.shrinkable_count == 0) return;

    const grow_per_weight = @max(totals.grow_floor_ratio_max, frame.factor);
    const largest = @max(totals.fit_desired_max, grow_per_weight * totals.grow_weight_max);
    const level = shrinkLevel(engine, frame, available - total_gap, largest);
    if (level == std.math.floatMax(f32)) return;
    frame.rule = .shrink;
    frame.level = level;
}

const shrink_round_count_max: u32 = 16;

const shrink_step_count: u32 = 32;

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
            if (round == 0) return std.math.floatMax(f32);
            std.debug.assert(-excess <= @max(1, @abs(target)) * 1e-4);
            return level;
        }
        if (step.active_count > 0) {
            const active: f32 = @floatFromInt(step.active_count);
            const next = level - excess / active;
            if (next >= step.breakpoint) return next;
        } else {
            if (step.breakpoint == 0) return level;
        }
        level = step.breakpoint;
    }
    return bisectLevel(engine, frame, target, level);
}

fn bisectLevel(
    engine: *const LayoutEngine,
    frame: *const SizingFrame,
    target: f32,
    high_start: f32,
) f32 {
    std.debug.assert(high_start >= 0);
    std.debug.assert(std.math.isFinite(high_start));
    if (levelStep(engine, frame, 0).total > target) return 0;
    var low: f32 = 0;
    var high: f32 = high_start;
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

const LevelStep = struct { total: f32, active_count: u32, breakpoint: f32 };

fn levelStep(engine: *const LayoutEngine, frame: *const SizingFrame, level: f32) LevelStep {
    std.debug.assert(level >= 0);
    const is_horizontal = frame.is_horizontal;
    var step: LevelStep = .{ .total = 0, .active_count = 0, .breakpoint = 0 };
    var cursor = frame.cursor;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len());
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

inline fn floorMain(child: *const LayoutElement, is_horizontal: bool) f32 {
    const floor = if (is_horizontal) child.computed.floor_width else child.computed.min_height;
    std.debug.assert(floor >= 0);
    return floor;
}

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

const ChildTotals = struct {
    grow_weight_total: f32,
    total_desired: f32,
    percent_total: f32,
    grow_floor_ratio_max: f32,
    grow_weight_max: f32,
    fit_desired_max: f32,
    shrinkable_count: u32,
    child_count: u32,
    has_grandchildren: bool,
};

fn sumDesiredSizes(engine: *LayoutEngine, first_child: u32, is_horizontal: bool) ChildTotals {
    std.debug.assert(first_child < engine.elements.len());
    std.debug.assert(first_child > 0);

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
                break :blk child_min;
            },
            .fit => |mm| blk: {
                const effective_max = if (mm.max >= 1e10) child_min else mm.max;
                const desired = @max(child_min, effective_max);
                shrinkable_count += 1;
                fit_desired_max = @max(fit_desired_max, desired);
                break :blk desired;
            },
            .fixed => |mm| mm.min,
            .percent => |p| blk: {
                percent_total += p.value;
                break :blk 0;
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

const SpeculativeResult = struct {
    eligible: bool,
    floating_count: u32,
    has_grandchildren: bool,
};

const FastPathResult = enum { ineligible, sized, sized_leaves };

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

        if (child.config.floating != null) {
            floating_count += 1;
            child_idx = child.next_sibling_index;
            continue;
        }

        const too_narrow = floorMain(child, is_horizontal) > per_child;
        if (!isUnconstrainedGrow(child, is_horizontal) or too_narrow) {
            return .{ .eligible = false, .floating_count = 0, .has_grandchildren = false };
        }

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

fn childContentArea(child: *const LayoutElement) struct { width: f32, height: f32 } {
    const child_layout = child.config.layout;
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
        .grow => 0,
        .fit => |mm| @max(child_min_main, mm.max),
        .fixed => |mm| mm.min,
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

const WrapLine = struct {
    end: ?u32,
    used: f32,
    grow_basis: f32,
    grow_weight_total: f32,
    flow_count: u32,
    has_grandchildren: bool,
};

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
        std.debug.assert(line_count < engine.elements.len());
        const line = breakWrapLine(engine, first, width, gap);
        if (line.flow_count > 0) {
            const line_height = sizeWrapLine(engine, first, &line, width, height);
            if (line_count > 0) lines_height += gap;
            lines_height += line_height;
            line_count += 1;
            if (line.has_grandchildren) has_grandchildren = true;
        } else {
            std.debug.assert(line.end == null);
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
        std.debug.assert(visited < engine.elements.len());
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

fn sizeWrapLine(
    engine: *LayoutEngine,
    first: u32,
    line: *const WrapLine,
    width: f32,
    height: f32,
) f32 {
    std.debug.assert(line.flow_count > 0);
    const free = width - (line.used - line.grow_basis);
    const per_weight: f32 = if (line.grow_weight_total > 0)
        @max(0, free) / line.grow_weight_total
    else
        0;
    var line_height: f32 = 0;
    var cursor: ?u32 = first;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len());
        if (line.end) |end| if (index == end) break;
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            line_height = @max(line_height, sizeWrapChild(child, per_weight, width, height));
        }
    }
    cursor = first;
    visited = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len());
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

pub const LineSpan = struct { start: f32, size: f32 };

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
        std.debug.assert(visited < engine.elements.len());
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

pub fn computeTextWrapping(engine: *LayoutEngine, root: u32) !void {
    std.debug.assert(root < engine.elements.len());
    std.debug.assert(engine.floating_roots.len <= engine.capacity.floating_count_max);
    if (engine.floating_roots.len > 0) {
        try wrapSubtreeText(true, engine, root);
    } else {
        try wrapSubtreeText(false, engine, root);
    }
}

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

fn wrapElementText(engine: *LayoutEngine, index: u32) !void {
    const elem = engine.elements.get(index);

    if (elem.text_data) |*td| {
        const max_width = textContainerWidth(engine, elem);

        td.container_width = max_width;

        const shrunk = elem.computed.sized_width < elem.computed.min_width;
        const wrap_width = if (shrunk) @min(max_width, elem.computed.sized_width) else max_width;

        if (td.config.wrap_mode != .none and wrap_width > 0) {
            const wrap_result = try wrapText(engine, td.text, td.config, wrap_width);
            std.debug.assert(wrap_result.max_line_width <= wrap_width);
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
        } else if (td.measured_width > wrap_width and !scrollsAcross(engine, elem)) {
            try cutOneLine(engine, elem, wrap_width);
        }
    }
}

fn cutOneLine(engine: *LayoutEngine, elem: *LayoutElement, cut_width: f32) !void {
    const td = &elem.text_data.?;
    std.debug.assert(cut_width >= 0);
    std.debug.assert(td.measured_width > cut_width);
    std.debug.assert(td.text.len <= types.line_length_max);
    claimWrappedLines(engine, 1);
    const lines = try engine.arena.allocator().alloc(types.WrappedLine, 1);
    lines[0] = .{
        .start_offset = 0,
        .extent = .{ .length = @intCast(td.text.len), .end = .cut_if_wide },
        .width = cut_width,
    };
    td.wrapped_lines = lines;
    td.measured_width = cut_width;
    elem.computed.sized_width = cut_width;
    std.debug.assert(elem.computed.sized_width >= 0);
}

fn scrollsAcross(engine: *const LayoutEngine, elem: *const LayoutElement) bool {
    const parent_index = elem.parent_index orelse return false;
    const scroll = engine.elements.getConst(parent_index).config.scroll orelse return false;
    return scroll.horizontal;
}

fn textContainerWidth(engine: *LayoutEngine, elem: *const LayoutElement) f32 {
    if (elem.parent_index) |pi| {
        const parent = engine.elements.getConst(pi);
        if (parent.config.layout.grid != .none) return grid_mod.cellWidthOf(engine, elem);
        return @max(0, parent.computed.sized_width - parent.config.layout.padding.totalX());
    }
    return engine.viewport_width;
}

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
            @branchHint(.unlikely);
            elem.heights_dirty = false;
            std.debug.assert(elem.first_child_index != null);
            sizeChildHeights(engine, index);
        }
    }
}

fn computeMinHeights(engine: *LayoutEngine, root: u32, end: u32) void {
    std.debug.assert(root < end);
    std.debug.assert(end <= engine.elements.len());
    var index = end;
    while (index > root) {
        index -= 1;
        const elem = engine.elements.get(index);
        if (elem.min_height_dirty) {
            @branchHint(.unlikely);
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
        const children = if (elem.config.layout.grid == .grid)
            grid_mod.rowsMinHeight(engine, elem)
        else
            childrenMinHeight(engine, elem);
        content = @max(content, children);
    }
    return applyMinMax(content + layout.padding.totalY(), layout.sizing.height);
}

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
        std.debug.assert(visited < engine.elements.len());
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

fn sizeChildHeights(engine: *LayoutEngine, parent_index: u32) void {
    const parent = engine.elements.getConst(parent_index);
    const first_child = parent.first_child_index.?;
    std.debug.assert(first_child > parent_index);
    const height = childContentArea(parent).height;
    std.debug.assert(!parent.heights_dirty);
    if (parent.config.layout.grid == .grid) {
        grid_mod.sizeRows(engine, parent_index, height);
        return;
    }
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
        std.debug.assert(visited < engine.elements.len());
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) setHeight(child, offeredHeight(child, height));
    }
}

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
        std.debug.assert(visited < engine.elements.len());
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating == null) setHeight(child, columnChildHeight(child, &frame));
    }
}

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

fn offeredHeight(elem: *const LayoutElement, offered: f32) f32 {
    std.debug.assert(offered >= 0);
    if (elem.config.layout.aspect_ratio) |ratio| {
        std.debug.assert(ratio > 0);
        return elem.computed.sized_width / ratio;
    }
    const sizing = elem.config.layout.sizing.height;
    return computeAxisSize(sizing, elem.computed.min_height, offered);
}

pub inline fn setHeight(child: *LayoutElement, height: f32) void {
    std.debug.assert(height >= 0);
    std.debug.assert(child.config.floating == null);
    if (height != child.computed.sized_height and child.first_child_index != null) {
        child.heights_dirty = true;
    }
    child.computed.sized_height = height;
}

fn stretchWrapLines(engine: *LayoutEngine, first_child: u32, height: f32) void {
    std.debug.assert(height >= 0);
    var line_first: ?u32 = first_child;
    var line_count: u32 = 0;
    while (line_first) |first| : (line_count += 1) {
        std.debug.assert(line_count < engine.elements.len());
        const line = wrapLineHeight(engine, first, height);
        var cursor: ?u32 = first;
        var visited: u32 = 0;
        while (cursor) |index| : (visited += 1) {
            std.debug.assert(visited < engine.elements.len());
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

inline fn stretchesInLine(child: *const LayoutElement) bool {
    std.debug.assert(child.config.floating == null);
    const layout = &child.config.layout;
    return layout.sizing.height.value == .grow and layout.aspect_ratio == null;
}

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
        std.debug.assert(visited < engine.elements.len());
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

pub const WrapResult = struct {
    lines: []types.WrappedLine,
    total_height: f32,
    max_line_width: f32,
};

pub fn wrapText(
    engine: *LayoutEngine,
    text_str: []const u8,
    config: TextConfig,
    max_width: f32,
) !WrapResult {
    std.debug.assert(max_width >= 0 or config.wrap_mode == .none);
    std.debug.assert(text_str.len <= types.line_length_max);

    if (config.wrap_mode == .none or max_width <= 0 or text_str.len == 0) {
        return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
    }

    if (engine.measure_text_fn == null) {
        return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
    }

    var lines: BoundedList(types.WrappedLine) = .{ .buffer = engine.line_scratch };
    const max_line_width = wrapLines(engine, text_str, config, max_width, &lines);
    claimWrappedLines(engine, lines.len);
    const result_lines = try engine.arena.allocator().dupe(types.WrappedLine, lines.slice());
    const line_height = config.lineHeightPx();
    const total_height = line_height * @as(f32, @floatFromInt(@max(1, result_lines.len)));

    return .{
        .lines = result_lines,
        .total_height = total_height,
        .max_line_width = max_line_width,
    };
}

pub fn measureWrapped(
    engine: *LayoutEngine,
    text_str: []const u8,
    config: TextConfig,
    max_width: f32,
) engine_mod.TextMeasurement {
    std.debug.assert(max_width >= 0);
    std.debug.assert(text_str.len <= types.line_length_max);
    const measure_fn = engine.measure_text_fn.?;
    const user_data = engine.measure_text_user_data;
    var one_line = measure_fn(text_str, config.font_id, config.font_size, null, user_data);
    one_line.width = @min(one_line.width, max_width);
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
        .line_count_max = config.line_count_max,
        .ellipsis = config.overflow == .ellipsis,
    };
    var batch_count: u32 = 0;
    while (true) : (batch_count += 1) {
        std.debug.assert(batch_count <= text_str.len);
        words.len = 0;
        const done = scanWords(&scan);
        engine.word_count_used_max = @max(engine.word_count_used_max, words.len);
        for (words.slice()) |*word| packer.pack(word);
        if (done or packer.clamped) break;
    }
    if (!packer.clamped and packer.line_start < text_str.len) {
        packer.finishLine(@intCast(text_str.len));
    }
    engine.line_count_used_max = @max(engine.line_count_used_max, lines.len);
    std.debug.assert(lines.len > 0);
    if (config.line_count_max > 0) std.debug.assert(lines.len <= config.line_count_max);
    return packer.widest;
}

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
        std.debug.assert(batch_count <= text_str.len);
        words.len = 0;
        const done = scanWords(&scan);
        engine.word_count_used_max = @max(engine.word_count_used_max, words.len);
        for (words.slice()) |*word| widest = @max(widest, word.width);
        if (done) break;
    }
    std.debug.assert(widest >= 0);
    return widest;
}

const LinePacker = struct {
    text: []const u8,
    max_width: f32,
    wrap_words: bool,
    space_width: f32,
    tab_width: f32,
    lines: *BoundedList(types.WrappedLine),
    line_count_max: u8,
    ellipsis: bool,
    clamped: bool = false,
    line_start: u32 = 0,
    line_width: f32 = 0,
    widest: f32 = 0,

    fn pack(self: *LinePacker, word: *const WordInfo) void {
        if (self.clamped) return;
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
            self.line_start = word.space_end + 1;
        }
    }

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

    fn finishLine(self: *LinePacker, end: u32) void {
        std.debug.assert(self.line_start <= end);
        std.debug.assert(self.line_width >= 0);
        if (self.clamped) return;
        if (self.line_count_max > 0 and self.lines.len == self.line_count_max) {
            self.clamped = true;
            if (self.ellipsis) self.cutLastLine();
            return;
        }
        const wide = self.line_width > self.max_width;
        const width = if (wide) self.max_width else self.line_width;
        appendLine(self.lines, .{
            .start_offset = self.line_start,
            .extent = .{
                .length = @intCast(end - self.line_start),
                .end = if (wide) .cut_if_wide else .whole,
            },
            .width = width,
        });
        self.widest = @max(self.widest, width);
        self.line_start = end;
        self.line_width = 0;
    }

    fn cutLastLine(self: *LinePacker) void {
        std.debug.assert(self.clamped);
        std.debug.assert(self.lines.len == self.line_count_max);
        const last = &self.lines.buffer[self.lines.len - 1];
        const line_end = last.start_offset + last.extent.length;
        std.debug.assert(line_end <= self.text.len);
        if (!textFollows(self.text, line_end)) return;
        var end: usize = line_end;
        if (self.text[line_end] != '\n') {
            end = std.mem.indexOfScalarPos(u8, self.text, line_end, '\n') orelse self.text.len;
        }
        std.debug.assert(end >= line_end);
        last.extent = .{ .length = @intCast(end - last.start_offset), .end = .cut };
        last.width = self.max_width;
        self.widest = @max(self.widest, self.max_width);
    }
};

fn textFollows(text: []const u8, start: usize) bool {
    std.debug.assert(start <= text.len);
    for (text[start..]) |byte| {
        const blank = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
        if (!blank) return true;
    }
    return false;
}

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

fn appendLine(lines: *BoundedList(types.WrappedLine), line: types.WrappedLine) void {
    lines.append(line) catch std.debug.panic("wrapped lines exhausted: capacity {d} " ++
        "(paint.glyph_count_frame_max), {d} in use by one text, 1 requested", .{
        lines.buffer.len,
        lines.len,
    });
}

fn appendWord(words: *BoundedList(WordInfo), word: WordInfo) void {
    std.debug.assert(words.len < words.buffer.len);
    std.debug.assert(word.start <= word.end);
    words.append(word) catch unreachable;
}

const WordScanState = struct {
    text: []const u8,
    measure_fn: MeasureTextFn,
    config: TextConfig,
    user_data: ?*anyopaque,
    words: *BoundedList(WordInfo),
    space_width: f32,
    tab_width: f32,
    byte_pos: u32 = 0,
    phase: Phase = .idle,
    word_start: u32 = 0,
    word_end: u32 = 0,
    word_width: f32 = 0,
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

    fn startUnit(self: *WordScanState, phase: Phase) void {
        std.debug.assert(phase != .idle);
        self.word_start = self.byte_pos;
        self.word_end = self.byte_pos;
        self.word_width = 0;
        self.space_width_sum = 0;
        self.phase = phase;
    }

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

fn scanWords(state: *WordScanState) bool {
    const text_str = state.text;
    std.debug.assert(text_str.len > 0);
    std.debug.assert(state.words.len == 0);
    std.debug.assert(state.byte_pos <= text_str.len);

    var iter = std.unicode.Utf8Iterator{ .bytes = text_str, .i = state.byte_pos };
    while (state.byte_pos < text_str.len) {
        if (state.words.len == state.words.buffer.len) return false;
        const codepoint_slice = iter.nextCodepointSlice().?;
        const codepoint_len: u32 = @intCast(codepoint_slice.len);
        const c = codepoint_slice[0];
        const is_ascii = codepoint_len == 1;
        if (is_ascii and c == '\n') {
            if (state.phase == .word) state.endWord();
            if (state.phase == .idle) state.startUnit(.space);
            state.emitUnit(true);
        } else if (is_ascii and (c == ' ' or c == '\t')) {
            if (state.phase == .word) state.endWord();
            if (state.phase == .idle) state.startUnit(.space);
            state.space_width_sum += if (c == '\t') state.tab_width else state.space_width;
        } else {
            if (state.phase == .space) state.emitUnit(false);
            if (state.phase == .idle) state.startUnit(.word);
        }
        state.byte_pos += codepoint_len;
        std.debug.assert(iter.i == state.byte_pos);
    }

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
