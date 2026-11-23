const std = @import("std");

const engine_mod = @import("engine.zig");
const grid_mod = @import("grid.zig");
const sizing_pass = @import("sizing_pass.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutElement = engine_mod.LayoutElement;
const LayoutConfig = types.LayoutConfig;
const BoundingBox = types.BoundingBox;
const FloatingConfig = types.FloatingConfig;

const box_depth_ceiling = @import("../core/limits.zig").box_depth_ceiling;

pub fn computePositions(engine: *LayoutEngine, root: u32, x: f32, y: f32) void {
    std.debug.assert(root < engine.elements.len());
    placeElement(engine.elements.get(root), x, y);
    positionSubtree(engine, root);
}

const PositionFrame = struct {
    cursor: ?u32,
    is_horizontal: bool,
    has_grandchildren: bool,
    alignment: types.ChildAlignment,
    cross_size: f32,
    flow: Flow,
    line_y: f32,
    content_x: f32,
    next_x: f32,
    next_y: f32,
    gap: f32,
};

const Flow = enum { line, wrap, grid, grid_row };

fn positionSubtree(engine: *LayoutEngine, root: u32) void {
    std.debug.assert(root < engine.elements.len());
    if (engine.elements.getConst(root).first_child_index == null) return;

    const root_plan = planChildPositions(engine, root);
    if (!root_plan.has_grandchildren) {
        placeLeaves(engine, root_plan);
        return;
    }

    var stack: [box_depth_ceiling]PositionFrame = undefined;
    stack[0] = root_plan;
    var depth: u32 = 1;
    var open_count: u32 = 1;
    while (depth > 0) {
        std.debug.assert(open_count <= engine.elements.len());
        var opened: PositionFrame = undefined;
        const frame = &stack[depth - 1];
        const pushed = switch (frame.flow) {
            inline else => |flow| placeSiblings(flow, engine, frame, &opened),
        };
        if (pushed) {
            std.debug.assert(depth < engine.capacity.box_depth_max);
            stack[depth] = opened;
            depth += 1;
            open_count += 1;
        } else {
            depth -= 1;
        }
    }
}

fn planChildPositions(engine: *LayoutEngine, parent_index: u32) PositionFrame {
    const parent = engine.elements.getConst(parent_index);
    const first_child = parent.first_child_index.?;
    std.debug.assert(first_child > parent_index);
    const layout = &parent.config.layout;
    const content_box = parent.computed.content_box;
    std.debug.assert(content_box.width >= 0);
    const is_horizontal = layout.layout_direction.isHorizontal();

    var frame: PositionFrame = .{
        .cursor = first_child,
        .is_horizontal = is_horizontal,
        .has_grandchildren = false,
        .alignment = layout.child_alignment,
        .cross_size = if (is_horizontal) content_box.height else content_box.width,
        .flow = if (layout.wrap) .wrap else .line,
        .line_y = 0,
        .content_x = content_box.x,
        .next_x = 0,
        .next_y = 0,
        .gap = 0,
    };
    const totals = sumChildrenAlongMainAxis(engine, first_child, is_horizontal);
    if (totals.child_count == 0) {
        if (parent.config.scroll != null) {
            engine.elements.get(parent_index).config.scroll.?.target = .none;
        }
        frame.cursor = null;
        return frame;
    }

    const dist = distributionParams(layout.*, content_box, totals);
    if (parent.config.scroll) |scroll| {
        if (scroll.target != .none) {
            resolveScrollTarget(engine, parent_index, .{
                .totals = totals,
                .dist = dist,
                .is_horizontal = is_horizontal,
            });
        }
    }
    const offset_x: f32 = if (parent.config.scroll) |s| -s.scroll_offset.x else 0;
    const offset_y: f32 = if (parent.config.scroll) |s| -s.scroll_offset.y else 0;
    frame.content_x = content_box.x + offset_x;
    frame.next_x = frame.content_x + if (is_horizontal) dist.start_offset else 0;
    frame.next_y = content_box.y + offset_y + if (!is_horizontal) dist.start_offset else 0;
    frame.gap = dist.effective_gap;
    frame.has_grandchildren = totals.has_grandchildren;
    frame.line_y = content_box.y + offset_y;
    if (layout.grid != .none) {
        @branchHint(.unlikely);
        planGridPositions(engine, parent_index, &frame);
    }
    std.debug.assert(frame.gap >= 0);
    return frame;
}

noinline fn planGridPositions(
    engine: *const LayoutEngine,
    parent_index: u32,
    frame: *PositionFrame,
) void {
    const parent = engine.elements.getConst(parent_index);
    std.debug.assert(parent.config.layout.grid != .none);
    std.debug.assert(!parent.config.layout.wrap);
    frame.next_x = frame.content_x;
    frame.gap = 0;
    if (parent.config.layout.grid == .grid) {
        frame.flow = .grid;
        const slot = grid_mod.slotOf(engine, parent);
        const height = parent.computed.content_box.height;
        slot.position_row = 0;
        slot.position_row_plan = grid_mod.rowPlan(engine, parent, height);
        slot.position_row_alignment = .auto;
        return;
    }
    frame.flow = .grid_row;
    frame.next_y = frame.line_y;
    frame.cross_size = parent.computed.content_box.height;
    const grid = engine.elements.getConst(parent.parent_index.?);
    std.debug.assert(grid.config.layout.grid == .grid);
    frame.alignment.x = grid.config.layout.child_alignment.x;
}

fn beginGridRow(engine: *const LayoutEngine, frame: *PositionFrame, first: u32) void {
    std.debug.assert(frame.flow == .grid);
    const grid = grid_mod.gridOfCell(engine, engine.elements.getConst(first));
    const slot = grid_mod.slotOf(engine, grid);
    const row = slot.position_row;
    std.debug.assert(row < slot.row_total);
    const track = slot.rowTrack(row);
    const extent = grid_mod.rowExtent(engine, first, .natural);
    const height = grid_mod.trackHeight(track, extent.tallest, slot.position_row_plan);
    frame.next_y = frame.line_y;
    frame.cross_size = height;
    frame.line_y += height + slot.row_gap;
    slot.position_row_alignment = track.alignment;
    slot.position_row = row + 1;
}

fn placeCell(engine: *const LayoutEngine, frame: *const PositionFrame, child: *LayoutElement) void {
    std.debug.assert(child.config.floating == null);
    std.debug.assert(frame.flow == .grid or frame.flow == .grid_row);
    if (child.config.layout.grid == .row) {
        placeElement(child, frame.content_x, frame.next_y);
        return;
    }
    const slot = grid_mod.slotOf(engine, grid_mod.gridOfCell(engine, child));
    const column = child.cell_column;
    const left = frame.content_x + slot.column_left[column];
    const cell_width = slot.cellWidth(column, child.cell_span);
    const free_x = cell_width - child.computed.sized_width;
    const free_y = frame.cross_size - child.computed.sized_height;
    const x = left + alignOffset(slot.columns[column].alignment, switch (frame.alignment.x) {
        .left => .start,
        .center => .center,
        .right => .end,
    }, free_x);
    const y = frame.next_y + alignOffset(slot.position_row_alignment, switch (frame.alignment.y) {
        .top => .start,
        .center => .center,
        .bottom => .end,
    }, free_y);
    placeElement(child, x, y);
    if (child.text_data) |*text| text.container_x = left;
}

fn alignOffset(alignment: types.TrackAlignment, fallback: types.TrackAlignment, free: f32) f32 {
    std.debug.assert(fallback != .auto);
    if (free <= 0) return 0;
    const resolved = if (alignment == .auto) fallback else alignment;
    return switch (resolved) {
        .auto => unreachable,
        .start => 0,
        .center => free / 2,
        .end => free,
    };
}

fn beginLine(engine: *const LayoutEngine, frame: *PositionFrame, first: u32) void {
    std.debug.assert(frame.flow == .wrap);
    const child = engine.elements.getConst(first);
    std.debug.assert(child.line_start);
    const parent = engine.elements.getConst(child.parent_index.?);
    var totals: MainAxisTotals = .{ .total_size = 0, .child_count = 0, .has_grandchildren = false };
    var line_height: f32 = 0;
    var cursor: ?u32 = first;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len());
        const sibling = engine.elements.getConst(index);
        cursor = sibling.next_sibling_index;
        if (sibling.config.floating != null) continue;
        if (sibling.line_start and index != first) break;
        totals.total_size += sibling.computed.sized_width;
        totals.child_count += 1;
        line_height = @max(line_height, sibling.computed.sized_height);
    }
    std.debug.assert(totals.child_count > 0);
    const dist = distributionParams(parent.config.layout, parent.computed.content_box, totals);
    frame.next_x = frame.content_x + dist.start_offset;
    frame.next_y = frame.line_y;
    frame.gap = dist.effective_gap;
    frame.cross_size = line_height;
    frame.line_y += line_height + @as(f32, @floatFromInt(parent.config.layout.child_gap));
}

const ContentPlan = struct {
    totals: MainAxisTotals,
    dist: DistributionParams,
    is_horizontal: bool,
};

fn resolveScrollTarget(engine: *LayoutEngine, parent_index: u32, plan: ContentPlan) void {
    const parent = engine.elements.get(parent_index);
    const scroll = &parent.config.scroll.?;
    std.debug.assert(scroll.target != .none);
    std.debug.assert(plan.totals.child_count > 0);
    const is_horizontal = plan.is_horizontal;
    const content_box = parent.computed.content_box;
    const gaps = plan.dist.effective_gap * @as(f32, @floatFromInt(plan.totals.child_count - 1));
    const main_length = plan.dist.start_offset + plan.totals.total_size + gaps;
    const first_child = parent.first_child_index.?;
    const is_wrap = parent.config.layout.wrap;
    const is_grid = parent.config.layout.grid == .grid;
    const child_gap: f32 = @floatFromInt(parent.config.layout.child_gap);
    const row_plan: grid_mod.RowPlan = if (is_grid)
        grid_mod.rowPlan(engine, parent, content_box.height)
    else
        .{ .per_weight = 0, .percent_basis = 0, .definite = false };
    const cross_length = if (is_grid)
        grid_mod.rowSpan(engine, parent, row_plan, null).size
    else if (is_wrap)
        sizing_pass.wrapLineSpan(engine, first_child, child_gap, null).size
    else
        crossExtent(engine, first_child, is_horizontal);
    const flow_width = if (is_horizontal) main_length else cross_length;
    const width = if (is_grid)
        grid_mod.slotOf(engine, parent).columnsWidth()
    else if (is_wrap) content_box.width else flow_width;
    const height = if (is_horizontal) cross_length else main_length;
    const along_x = is_horizontal and !is_wrap and !is_grid;
    const max_x: f32 = if (scroll.horizontal) @max(0, width - content_box.width) else 0;
    const max_y: f32 = if (scroll.vertical) @max(0, height - content_box.height) else 0;
    var offset = scroll.scroll_offset;
    switch (scroll.target) {
        .none => unreachable,
        .start => offset = .{ .x = 0, .y = 0 },
        .end => offset = .{ .x = max_x, .y = max_y },
        .offset => |target| offset = target,
        .child => |child| {
            const span: Span = if (is_grid) blk: {
                const row = grid_mod.rowSpan(engine, parent, row_plan, child.index);
                break :blk .{ .start = row.start, .size = row.size };
            } else if (is_wrap) blk: {
                const line = sizing_pass.wrapLineSpan(engine, first_child, child_gap, child.index);
                break :blk .{ .start = line.start, .size = line.size };
            } else childSpan(engine, first_child, child.index, plan);
            const view = if (along_x) content_box.width else content_box.height;
            const current = if (along_x) offset.x else offset.y;
            const along = alignSpan(child.alignment, span, view, current);
            if (along_x) offset.x = along else offset.y = along;
        },
    }
    scroll.scroll_offset = .{
        .x = std.math.clamp(offset.x, 0, max_x),
        .y = std.math.clamp(offset.y, 0, max_y),
    };
    scroll.target = .none;
    std.debug.assert(scroll.scroll_offset.x <= max_x);
    std.debug.assert(scroll.scroll_offset.y <= max_y);
}

fn crossExtent(engine: *const LayoutEngine, first_child: u32, is_horizontal: bool) f32 {
    var extent: f32 = 0;
    var child_index: ?u32 = first_child;
    var visited: u32 = 0;
    while (child_index) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len());
        const child = engine.elements.getConst(index);
        if (child.config.floating == null) {
            const computed = &child.computed;
            const size = if (is_horizontal) computed.sized_height else computed.sized_width;
            extent = @max(extent, size);
        }
        child_index = child.next_sibling_index;
    }
    std.debug.assert(extent >= 0);
    return extent;
}

const Span = struct { start: f32, size: f32 };

fn childSpan(engine: *const LayoutEngine, first_child: u32, target: u32, plan: ContentPlan) Span {
    std.debug.assert(target >= first_child);
    const is_horizontal = plan.is_horizontal;
    var start = plan.dist.start_offset;
    var child_index: ?u32 = first_child;
    var visited: u32 = 0;
    while (child_index) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len());
        const child = engine.elements.getConst(index);
        const size = if (is_horizontal) child.computed.sized_width else child.computed.sized_height;
        if (index == target) {
            std.debug.assert(child.config.floating == null);
            return .{ .start = start, .size = size };
        }
        if (child.config.floating == null) start += size + plan.dist.effective_gap;
        child_index = child.next_sibling_index;
    }
    unreachable;
}

fn alignSpan(alignment: types.ScrollAlignment, span: Span, view: f32, current: f32) f32 {
    std.debug.assert(span.size >= 0);
    std.debug.assert(view >= 0);
    return switch (alignment) {
        .start => span.start,
        .center => span.start + span.size / 2 - view / 2,
        .end => span.start + span.size - view,
        .nearest => blk: {
            if (span.start < current or span.size > view) break :blk span.start;
            const overshoot = span.start + span.size - (current + view);
            break :blk if (overshoot > 0) current + overshoot else current;
        },
    };
}

fn placeSiblings(
    comptime flow: Flow,
    engine: *LayoutEngine,
    frame: *PositionFrame,
    opened: *PositionFrame,
) bool {
    std.debug.assert(frame.flow == flow);
    std.debug.assert(frame.gap >= 0);
    var local = frame.*;
    var sibling_count: u32 = 0;
    while (local.cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len());
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        local.cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            placeFlowChild(flow, engine, &local, child_index, child);
            if (child.first_child_index != null) {
                const plan = planChildPositions(engine, child_index);
                if (plan.has_grandchildren) {
                    frame.* = local;
                    opened.* = plan;
                    return true;
                }
                placeLeaves(engine, plan);
            }
        }
    }
    frame.cursor = null;
    return false;
}

fn placeLeaves(engine: *LayoutEngine, plan: PositionFrame) void {
    switch (plan.flow) {
        .line => placeLeafChildren(.line, engine, plan),
        .wrap => placeLeafChildren(.wrap, engine, plan),
        .grid, .grid_row => {
            @branchHint(.unlikely);
            placeGridLeaves(engine, plan);
        },
    }
}

noinline fn placeGridLeaves(engine: *LayoutEngine, plan: PositionFrame) void {
    std.debug.assert(plan.flow == .grid or plan.flow == .grid_row);
    if (plan.flow == .grid) {
        placeLeafChildren(.grid, engine, plan);
    } else {
        placeLeafChildren(.grid_row, engine, plan);
    }
}

fn placeLeafChildren(comptime flow: Flow, engine: *LayoutEngine, plan: PositionFrame) void {
    std.debug.assert(plan.flow == flow);
    std.debug.assert(!plan.has_grandchildren);
    var local = plan;
    var sibling_count: u32 = 0;
    while (local.cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len());
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        local.cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            std.debug.assert(child.first_child_index == null);
            placeFlowChild(flow, engine, &local, child_index, child);
        }
    }
}

inline fn placeFlowChild(
    comptime flow: Flow,
    engine: *const LayoutEngine,
    frame: *PositionFrame,
    child_index: u32,
    child: *LayoutElement,
) void {
    std.debug.assert(child.config.floating == null);
    switch (flow) {
        .line => placeNext(frame, child),
        .wrap => {
            if (child.line_start) beginLine(engine, frame, child_index);
            placeNext(frame, child);
        },
        .grid => {
            if (child.line_start) beginGridRow(engine, frame, child_index);
            placeCell(engine, frame, child);
        },
        .grid_row => placeCell(engine, frame, child),
    }
}

inline fn placeNext(frame: *PositionFrame, child: *LayoutElement) void {
    std.debug.assert(child.config.floating == null);
    std.debug.assert(frame.gap >= 0);
    const is_horizontal = frame.is_horizontal;
    const cross_offset = crossAxisOffset(frame.alignment, frame.cross_size, child, is_horizontal);
    const child_x = frame.next_x + (if (frame.is_horizontal) 0 else cross_offset);
    const child_y = frame.next_y + (if (frame.is_horizontal) cross_offset else 0);
    placeElement(child, child_x, child_y);
    if (child.text_data) |*text| text.container_x = frame.content_x;
    if (frame.is_horizontal) {
        frame.next_x += child.computed.sized_width + frame.gap;
    } else {
        frame.next_y += child.computed.sized_height + frame.gap;
    }
}

fn placeElement(elem: *LayoutElement, x: f32, y: f32) void {
    std.debug.assert(!std.math.isNan(x));
    std.debug.assert(!std.math.isNan(y));
    const padding = elem.config.layout.padding;

    elem.computed.bounding_box = .{
        .x = x,
        .y = y,
        .width = elem.computed.sized_width,
        .height = elem.computed.sized_height,
    };

    elem.computed.content_box = .{
        .x = x + @as(f32, @floatFromInt(padding.left)),
        .y = y + @as(f32, @floatFromInt(padding.top)),
        .width = @max(0, elem.computed.sized_width - padding.totalX()),
        .height = @max(0, elem.computed.sized_height - padding.totalY()),
    };
}

const MainAxisTotals = struct {
    total_size: f32,
    child_count: u32,
    has_grandchildren: bool,
};

fn sumChildrenAlongMainAxis(engine: *LayoutEngine, first_child: u32, is_horizontal: bool) MainAxisTotals {
    std.debug.assert(first_child < engine.elements.len());

    var total_size: f32 = 0;
    var child_count: u32 = 0;
    var has_grandchildren = false;
    var child_idx: ?u32 = first_child;

    while (child_idx) |ci| {
        const child = engine.elements.getConst(ci);
        if (child.config.floating == null) {
            total_size += if (is_horizontal) child.computed.sized_width else child.computed.sized_height;
            child_count += 1;
            if (child.first_child_index != null) has_grandchildren = true;
        }
        child_idx = child.next_sibling_index;
    }

    return .{
        .total_size = total_size,
        .child_count = child_count,
        .has_grandchildren = has_grandchildren,
    };
}

const DistributionParams = struct {
    effective_gap: f32,
    start_offset: f32,
};

fn distributionParams(
    layout: LayoutConfig,
    content_box: BoundingBox,
    totals: MainAxisTotals,
) DistributionParams {
    std.debug.assert(totals.child_count > 0);

    const is_horizontal = layout.layout_direction.isHorizontal();
    const base_gap: f32 = @floatFromInt(layout.child_gap);
    const container_main_size = if (is_horizontal) content_box.width else content_box.height;
    const remaining_space = container_main_size - totals.total_size;
    const child_count_f: f32 = @floatFromInt(totals.child_count);

    var effective_gap: f32 = base_gap;
    var start_offset: f32 = 0;

    switch (layout.main_axis_distribution) {
        .start => {
            effective_gap = base_gap;
            start_offset = 0;
        },
        .center => {
            effective_gap = base_gap;
            const total_with_gaps = totals.total_size + base_gap * @as(f32, @floatFromInt(@max(1, totals.child_count) - 1));
            start_offset = (container_main_size - total_with_gaps) / 2;
        },
        .end => {
            effective_gap = base_gap;
            const total_with_gaps = totals.total_size + base_gap * @as(f32, @floatFromInt(@max(1, totals.child_count) - 1));
            start_offset = container_main_size - total_with_gaps;
        },
        .space_between => {
            effective_gap = if (totals.child_count > 1) remaining_space / @as(f32, @floatFromInt(totals.child_count - 1)) else 0;
            start_offset = 0;
        },
        .space_around => {
            const space_per_child = remaining_space / child_count_f;
            effective_gap = space_per_child;
            start_offset = space_per_child / 2;
        },
        .space_evenly => {
            effective_gap = remaining_space / @as(f32, @floatFromInt(totals.child_count + 1));
            start_offset = effective_gap;
        },
    }

    return .{
        .effective_gap = @max(0, effective_gap),
        .start_offset = @max(0, start_offset),
    };
}

fn crossAxisOffset(
    alignment: types.ChildAlignment,
    cross_size: f32,
    child: *const LayoutElement,
    is_horizontal: bool,
) f32 {
    std.debug.assert(cross_size >= 0);
    if (is_horizontal) {
        return switch (alignment.y) {
            .top => 0,
            .center => (cross_size - child.computed.sized_height) / 2,
            .bottom => cross_size - child.computed.sized_height,
        };
    }
    return switch (alignment.x) {
        .left => 0,
        .center => (cross_size - child.computed.sized_width) / 2,
        .right => cross_size - child.computed.sized_width,
    };
}

pub fn computeFloatingPositions(engine: *LayoutEngine) !void {
    std.debug.assert(engine.floating_roots.len <= engine.capacity.floating_count_max);

    for (engine.floating_roots.slice()) |float_idx| {
        const elem = engine.elements.get(float_idx);
        const floating = elem.config.floating orelse continue;

        const parent_bbox = resolveFloatingParentBbox(engine, elem, floating);

        const constraint_width = if (floating.expand.width) parent_bbox.width else engine.viewport_width;
        const constraint_height = if (floating.expand.height) parent_bbox.height else engine.viewport_height;

        try computeFloatingSizesWithText(engine, float_idx, constraint_width, constraint_height);

        if (floating.expand.width) elem.computed.sized_width = parent_bbox.width;
        if (floating.expand.height) elem.computed.sized_height = parent_bbox.height;

        positionFloatingElement(engine, float_idx, floating, parent_bbox);
    }
}

fn resolveFloatingParentBbox(
    engine: *LayoutEngine,
    elem: *const LayoutElement,
    floating: FloatingConfig,
) BoundingBox {
    var bbox: BoundingBox = .{
        .width = engine.viewport_width,
        .height = engine.viewport_height,
    };

    if (floating.attach_to_parent) {
        if (elem.parent_index) |pi| bbox = engine.elements.getConst(pi).computed.bounding_box;
    }

    return bbox;
}

pub fn computeFloatingSizesWithText(
    engine: *LayoutEngine,
    float_root: u32,
    max_width: f32,
    max_height: f32,
) !void {
    std.debug.assert(max_width >= 0);
    std.debug.assert(max_height >= 0);
    std.debug.assert(engine.elements.getConst(float_root).config.floating != null);

    sizing_pass.computeFinalSizes(engine, float_root, max_width, max_height);
    try sizing_pass.computeTextWrapping(engine, float_root);
    if (engine.heights_derived) sizing_pass.computeHeights(engine, float_root, max_height);
}

fn flipIntoViewport(y: f32, height: f32, parent: BoundingBox, viewport_height: f32) f32 {
    std.debug.assert(height >= 0);
    std.debug.assert(parent.height >= 0);
    const overflows = y < 0 or y + height > viewport_height;
    if (!overflows) return y;
    const mirrored = parent.y + parent.height - (y - parent.y) - height;
    if (mirrored < 0) return y;
    if (mirrored + height > viewport_height) return y;
    return mirrored;
}

fn positionFloatingElement(
    engine: *LayoutEngine,
    float_idx: u32,
    floating: FloatingConfig,
    parent_bbox: BoundingBox,
) void {
    const elem = engine.elements.get(float_idx);

    const parent_x = parent_bbox.x + parent_bbox.width * floating.parent_attach.normalizedX();
    const parent_y = parent_bbox.y + parent_bbox.height * floating.parent_attach.normalizedY();

    const elem_offset_x = elem.computed.sized_width * floating.element_attach.normalizedX();
    const elem_offset_y = elem.computed.sized_height * floating.element_attach.normalizedY();

    var final_x = parent_x - elem_offset_x + floating.offset.x;
    var final_y = parent_y - elem_offset_y + floating.offset.y;
    if (floating.attach_to_parent) {
        const height = elem.computed.sized_height;
        final_y = flipIntoViewport(final_y, height, parent_bbox, engine.viewport_height);
    }

    if (final_x < 0) final_x = 0;
    if (final_y < 0) final_y = 0;
    const max_x = engine.viewport_width - elem.computed.sized_width;
    const max_y = engine.viewport_height - elem.computed.sized_height;
    if (final_x > max_x) final_x = @max(0, max_x);
    if (final_y > max_y) final_y = @max(0, max_y);

    elem.computed.bounding_box = .{
        .x = final_x,
        .y = final_y,
        .width = elem.computed.sized_width,
        .height = elem.computed.sized_height,
    };

    const padding = elem.config.layout.padding;
    elem.computed.content_box = .{
        .x = final_x + @as(f32, @floatFromInt(padding.left)),
        .y = final_y + @as(f32, @floatFromInt(padding.top)),
        .width = @max(0, elem.computed.sized_width - padding.totalX()),
        .height = @max(0, elem.computed.sized_height - padding.totalY()),
    };

    positionSubtree(engine, float_idx);
}
