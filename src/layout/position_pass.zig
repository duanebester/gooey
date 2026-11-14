//! Layout position pass — Phase 3 of the layout pipeline.
//!
//! Reads sized elements from the sizing pass and writes
//! `LayoutElement.computed.{bounding_box,content_box}`.
//!
//! Two sub-phases:
//!   1. `computePositions` walks the main tree top-down, threading scroll
//!      offsets and child-alignment / main-axis-distribution rules through
//!      `planChildPositions`.
//!   2. `computeFloatingPositions` re-enters the sizing pass for each
//!      floating subtree (sizes can shift once the parent bbox is known),
//!      then positions the floating root and its children.
//!
//! Floating elements never affect parent sizing (enforced by the sizing
//! pass); this file relies on that invariant when computing constraints.
//!
//! Like the sizing pass, nothing here recurses (CLAUDE.md §6): placement keeps
//! an explicit stack of open parents bounded by the engine's open depth, and
//! the floating passes walk a subtree's pre-order index range forwards
//! (`sizing_pass.subtreeEnd`).

const std = @import("std");

const engine_mod = @import("engine.zig");
const sizing_pass = @import("sizing_pass.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutElement = engine_mod.LayoutElement;
const LayoutConfig = types.LayoutConfig;
const BoundingBox = types.BoundingBox;
const FloatingConfig = types.FloatingConfig;

/// The explicit stack's ceiling; `sizing_pass.zig` explains the choice.
const box_depth_ceiling = @import("../core/limits.zig").box_depth_ceiling;

// ============================================================================
// Phase 3: Compute positions (top-down)
// ============================================================================

/// Place `root` at (`x`, `y`), then place the rest of its subtree.
pub fn computePositions(engine: *LayoutEngine, root: u32, x: f32, y: f32) void {
    std.debug.assert(root < engine.elements.len()); // Valid element index
    placeElement(engine.elements.get(root), x, y);
    positionSubtree(engine, root);
}

/// One placed parent whose children the walk is placing: where its next
/// child goes and how its children line up. The walk places one child and,
/// when that child has children, plans it straight away. A parent whose
/// children are all leaves is placed on the spot; any other is pushed. A
/// subtree is therefore placed while its root is still in cache, in the
/// order the recursive pass used, and the stack holds one frame per open
/// level.
const PositionFrame = struct {
    /// The next child to place, or null once every child is placed.
    cursor: ?u32,
    is_horizontal: bool,
    /// Whether any non-floating child has children of its own.
    has_grandchildren: bool,
    alignment: types.ChildAlignment,
    content_box: BoundingBox,
    /// The next child's top-left corner before its cross-axis alignment.
    next_x: f32,
    next_y: f32,
    /// The main-axis space after each child.
    gap: f32,
};

/// Place the rest of `root`'s subtree, `root` already placed: each parent
/// places its children inside its content box (honoring its scroll offset)
/// before they place theirs. Floating subtrees below `root` are skipped;
/// `computeFloatingPositions` places them.
fn positionSubtree(engine: *LayoutEngine, root: u32) void {
    std.debug.assert(root < engine.elements.len());
    if (engine.elements.getConst(root).first_child_index == null) return;

    const root_plan = planChildPositions(engine, root);
    if (!root_plan.has_grandchildren) {
        placeLeafChildren(engine, root_plan); // No frame needed.
        return;
    }

    // A frame per open level: the open stack bounds the tree's depth.
    var stack: [box_depth_ceiling]PositionFrame = undefined;
    stack[0] = root_plan;
    var depth: u32 = 1;
    var open_count: u32 = 1;
    while (depth > 0) {
        std.debug.assert(open_count <= engine.elements.len()); // Each parent once.
        var opened: PositionFrame = undefined;
        if (placeSiblings(engine, &stack[depth - 1], &opened)) {
            std.debug.assert(depth < engine.capacity.box_depth_max);
            stack[depth] = opened;
            depth += 1;
            open_count += 1;
        } else {
            depth -= 1;
        }
    }
}

/// Plan where `parent_index`'s children go: the main-axis distribution's
/// start offset and gap, shifted by the parent's scroll offset (negative:
/// content scrolls under the viewport).
fn planChildPositions(engine: *LayoutEngine, parent_index: u32) PositionFrame {
    const parent = engine.elements.getConst(parent_index);
    const first_child = parent.first_child_index.?;
    std.debug.assert(first_child > parent_index); // Pre-order: children follow.
    const layout = parent.config.layout;
    const content_box = parent.computed.content_box;
    std.debug.assert(content_box.width >= 0);
    const is_horizontal = layout.layout_direction.isHorizontal();

    var frame: PositionFrame = .{
        .cursor = first_child,
        .is_horizontal = is_horizontal,
        .has_grandchildren = false,
        .alignment = layout.child_alignment,
        .content_box = content_box,
        .next_x = 0,
        .next_y = 0,
        .gap = 0,
    };
    // Sum non-floating child sizes and count them along the main axis.
    const totals = sumChildrenAlongMainAxis(engine, first_child, is_horizontal);
    if (totals.child_count == 0) {
        frame.cursor = null; // Only floating children: nothing flows here.
        return frame;
    }

    // Convert distribution mode into concrete gap + start offset.
    const dist = distributionParams(layout, content_box, totals);
    const offset_x: f32 = if (parent.config.scroll) |s| -s.scroll_offset.x else 0;
    const offset_y: f32 = if (parent.config.scroll) |s| -s.scroll_offset.y else 0;
    frame.next_x = content_box.x + offset_x + if (is_horizontal) dist.start_offset else 0;
    frame.next_y = content_box.y + offset_y + if (!is_horizontal) dist.start_offset else 0;
    frame.gap = dist.effective_gap;
    frame.has_grandchildren = totals.has_grandchildren;
    std.debug.assert(frame.gap >= 0);
    return frame;
}

/// Place `frame`'s remaining children until one has grandchildren: plan it
/// into `opened` and return true for the walk to push it, its siblings left
/// for later; or return false once every child is placed. A child whose own
/// children are all leaves is finished here, without a frame. Floating
/// children are placed by `computeFloatingPositions`.
fn placeSiblings(engine: *LayoutEngine, frame: *PositionFrame, opened: *PositionFrame) bool {
    std.debug.assert(frame.gap >= 0);
    var local = frame.*; // Kept in registers across a wide row.
    var sibling_count: u32 = 0;
    while (local.cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len()); // Each sibling once.
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        local.cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            placeNext(&local, child);
            if (child.first_child_index != null) {
                const plan = planChildPositions(engine, child_index);
                if (plan.has_grandchildren) {
                    frame.* = local;
                    opened.* = plan;
                    return true;
                }
                placeLeafChildren(engine, plan);
            }
        }
    }
    frame.cursor = null;
    return false;
}

/// Place every child of a parent whose non-floating children are all leaves.
fn placeLeafChildren(engine: *LayoutEngine, plan: PositionFrame) void {
    std.debug.assert(!plan.has_grandchildren);
    var local = plan;
    var sibling_count: u32 = 0;
    while (local.cursor) |child_index| {
        std.debug.assert(sibling_count < engine.elements.len()); // Each sibling once.
        sibling_count += 1;
        const child = engine.elements.get(child_index);
        local.cursor = child.next_sibling_index;
        if (child.config.floating == null) {
            std.debug.assert(child.first_child_index == null);
            placeNext(&local, child);
        }
    }
}

/// Place one non-floating child at its parent's next slot, aligned on the
/// cross axis, and advance the slot past it and the gap.
inline fn placeNext(frame: *PositionFrame, child: *LayoutElement) void {
    std.debug.assert(child.config.floating == null);
    std.debug.assert(frame.gap >= 0);
    const is_horizontal = frame.is_horizontal;
    const cross_offset = crossAxisOffset(frame.alignment, frame.content_box, child, is_horizontal);
    const child_x = frame.next_x + (if (frame.is_horizontal) 0 else cross_offset);
    const child_y = frame.next_y + (if (frame.is_horizontal) cross_offset else 0);
    placeElement(child, child_x, child_y);
    if (frame.is_horizontal) {
        frame.next_x += child.computed.sized_width + frame.gap;
    } else {
        frame.next_y += child.computed.sized_height + frame.gap;
    }
}

/// Set one element's `bounding_box` at (`x`, `y`) and its `content_box`
/// inside its padding.
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

    // Content box (inside padding)
    // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
    elem.computed.content_box = .{
        .x = x + @as(f32, @floatFromInt(padding.left)),
        .y = y + @as(f32, @floatFromInt(padding.top)),
        .width = @max(0, elem.computed.sized_width - padding.totalX()),
        .height = @max(0, elem.computed.sized_height - padding.totalY()),
    };
}

/// A parent's non-floating children: their summed main-axis size, their
/// count, and whether any has children of its own.
const MainAxisTotals = struct {
    total_size: f32,
    child_count: u32,
    has_grandchildren: bool,
};

/// Pre-pass: count non-floating children and sum their main-axis sizes.
/// Floating siblings are excluded because they don't participate in flow.
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

/// Resolved `main_axis_distribution` parameters — concrete gap and start
/// offset both ≥ 0. Branchless caller code, easy to reason about.
const DistributionParams = struct {
    effective_gap: f32,
    start_offset: f32,
};

/// Translate the `main_axis_distribution` enum into concrete spacing.
/// Pure function — no engine state touched. Clamps both outputs to ≥0
/// because children that overflow the container can otherwise produce
/// negative gaps which the cursor loop would interpret as overlap.
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
            // Children packed at start with base gap
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
            // Equal space between children, none at edges. Single-child layouts collapse to start.
            effective_gap = if (totals.child_count > 1) remaining_space / @as(f32, @floatFromInt(totals.child_count - 1)) else 0;
            start_offset = 0;
        },
        .space_around => {
            // Equal space around each child (half at edges).
            const space_per_child = remaining_space / child_count_f;
            effective_gap = space_per_child;
            start_offset = space_per_child / 2;
        },
        .space_evenly => {
            // Equal space between and around children.
            effective_gap = remaining_space / @as(f32, @floatFromInt(totals.child_count + 1));
            start_offset = effective_gap;
        },
    }

    return .{
        .effective_gap = @max(0, effective_gap),
        .start_offset = @max(0, start_offset),
    };
}

/// Compute the cross-axis offset for a single child given the parent's
/// `child_alignment`. The cross axis is height when laying out horizontally
/// and width when laying out vertically.
fn crossAxisOffset(
    alignment: types.ChildAlignment,
    content_box: BoundingBox,
    child: *const LayoutElement,
    is_horizontal: bool,
) f32 {
    if (is_horizontal) {
        return switch (alignment.y) {
            .top => 0,
            .center => (content_box.height - child.computed.sized_height) / 2,
            .bottom => content_box.height - child.computed.sized_height,
        };
    }
    return switch (alignment.x) {
        .left => 0,
        .center => (content_box.width - child.computed.sized_width) / 2,
        .right => content_box.width - child.computed.sized_width,
    };
}

// ============================================================================
// Phase 3b: Position floating elements
// ============================================================================

/// Position each floating element in two passes per element. Re-enters the
/// sizing pass for the floating subtree so nested layouts see the parent's
/// bbox as their constraint, then assigns concrete coordinates.
pub fn computeFloatingPositions(engine: *LayoutEngine) !void {
    std.debug.assert(engine.floating_roots.len <= engine.capacity.floating_count_max);

    for (engine.floating_roots.slice()) |float_idx| {
        const elem = engine.elements.get(float_idx);
        const floating = elem.config.floating orelse continue;

        const parent_bbox = resolveFloatingParentBbox(engine, elem, floating);

        // expand uses parent dimensions as constraints.
        const constraint_width = if (floating.expand.width) parent_bbox.width else engine.viewport_width;
        const constraint_height = if (floating.expand.height) parent_bbox.height else engine.viewport_height;

        // PASS 1: Compute sizes with integrated text wrapping.
        try computeFloatingSizesWithText(engine, float_idx, constraint_width, constraint_height);

        // Apply expand after sizing (override computed sizes if expand is set).
        if (floating.expand.width) elem.computed.sized_width = parent_bbox.width;
        if (floating.expand.height) elem.computed.sized_height = parent_bbox.height;

        // PASS 2: Position element and children.
        positionFloatingElement(engine, float_idx, floating, parent_bbox);
    }
}

/// Resolve the bbox to position a floating element relative to: the direct
/// parent when `attach_to_parent` is set (dropdowns), else the viewport
/// (modals).
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

/// Compute sizes for a floating element with text wrapping integrated.
/// Walks the floating subtree forwards, skipping nested floating subtrees
/// (they have their own pass). Each element visited sizes its own subtree
/// again from the size it holds when the walk reaches it, then wraps its
/// text: the order and results of the recursive pass this replaces.
pub fn computeFloatingSizesWithText(
    engine: *LayoutEngine,
    float_root: u32,
    max_width: f32,
    max_height: f32,
) !void {
    std.debug.assert(max_width >= 0);
    std.debug.assert(max_height >= 0);

    const end = sizing_pass.subtreeEnd(engine, float_root);
    var index = float_root;
    while (index < end) {
        const elem = engine.elements.get(index);
        if (index > float_root) std.debug.assert(elem.parent_index.? < index);
        if (index != float_root and elem.config.floating != null) {
            index = sizing_pass.subtreeEnd(engine, index);
            continue;
        }
        const is_root = index == float_root;
        const available_width = if (is_root) max_width else elem.computed.sized_width;
        const available_height = if (is_root) max_height else elem.computed.sized_height;
        sizing_pass.computeFinalSizes(engine, index, available_width, available_height);
        try wrapFloatingText(engine, index, available_width);
        index += 1;
    }
    std.debug.assert(index == end);
}

/// Wrap one element of a floating subtree at its parent's content width, or
/// at `max_width` without a parent, and grow its fit-content ancestors.
fn wrapFloatingText(engine: *LayoutEngine, index: u32, max_width: f32) !void {
    std.debug.assert(max_width >= 0);
    const elem = engine.elements.get(index);
    const td = if (elem.text_data) |*data| data else return;
    const text_max_width = if (elem.parent_index) |pi| blk: {
        const parent = engine.elements.getConst(pi);
        // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
        break :blk @max(0, parent.computed.sized_width - parent.config.layout.padding.totalX());
    } else max_width;

    td.container_width = text_max_width;
    if (td.config.wrap_mode == .none or text_max_width <= 0) return;

    const wrap_result = try sizing_pass.wrapText(engine, td.text, td.config, text_max_width);
    td.wrapped_lines = wrap_result.lines;
    if (wrap_result.lines.len > 0) {
        td.measured_width = wrap_result.max_line_width;
        td.measured_height = wrap_result.total_height;
        elem.computed.sized_width = wrap_result.max_line_width;
        elem.computed.sized_height = wrap_result.total_height;
        // Grow the fit-content containers up to this floating root,
        // as the main pass does; the menu or modal grows with them.
        sizing_pass.propagateHeightChange(engine, elem.parent_index);
    }
}

/// A parent-attached floating element that runs past the viewport's top or
/// bottom opens on its parent's other side when it fits there, as a native
/// menu opens upward near the screen's bottom: its span is mirrored about
/// the parent's vertical centre, so a menu below its trigger lands above
/// it with the same gap. Otherwise it keeps `y` for the clamp, which may
/// cover the parent.
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

/// Position a floating element and its children, clamping to the viewport
/// so floating elements don't render off-screen.
fn positionFloatingElement(
    engine: *LayoutEngine,
    float_idx: u32,
    floating: FloatingConfig,
    parent_bbox: BoundingBox,
) void {
    const elem = engine.elements.get(float_idx);

    // Calculate attach point on parent.
    const parent_x = parent_bbox.x + parent_bbox.width * floating.parent_attach.normalizedX();
    const parent_y = parent_bbox.y + parent_bbox.height * floating.parent_attach.normalizedY();

    // Calculate element anchor offset.
    const elem_offset_x = elem.computed.sized_width * floating.element_attach.normalizedX();
    const elem_offset_y = elem.computed.sized_height * floating.element_attach.normalizedY();

    // Final position (before clamping).
    var final_x = parent_x - elem_offset_x + floating.offset.x;
    var final_y = parent_y - elem_offset_y + floating.offset.y;
    if (floating.attach_to_parent) {
        const height = elem.computed.sized_height;
        final_y = flipIntoViewport(final_y, height, parent_bbox, engine.viewport_height);
    }

    // Clamp to viewport bounds (keep floating elements on-screen).
    if (final_x < 0) final_x = 0;
    if (final_y < 0) final_y = 0;
    const max_x = engine.viewport_width - elem.computed.sized_width;
    const max_y = engine.viewport_height - elem.computed.sized_height;
    if (final_x > max_x) final_x = @max(0, max_x);
    if (final_y > max_y) final_y = @max(0, max_y);

    // Update bounding boxes.
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
        // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
        .width = @max(0, elem.computed.sized_width - padding.totalX()),
        .height = @max(0, elem.computed.sized_height - padding.totalY()),
    };

    // Place the floating element's subtree inside it.
    positionSubtree(engine, float_idx);
}
