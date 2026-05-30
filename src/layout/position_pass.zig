//! Layout position pass — Phase 3 of the layout pipeline.
//!
//! Reads sized elements from the sizing pass and writes
//! `LayoutElement.computed.{bounding_box,content_box}`.
//!
//! Two sub-phases:
//!   1. `computePositions` walks the main tree top-down, threading scroll
//!      offsets and child-alignment / main-axis-distribution rules through
//!      `positionChildren`.
//!   2. `computeFloatingPositions` re-enters the sizing pass for each
//!      floating subtree (sizes can shift once the parent bbox is known),
//!      then positions the floating root and its children.
//!
//! Floating elements never affect parent sizing (enforced by the sizing
//! pass); this file relies on that invariant when computing constraints.

const std = @import("std");

const engine_mod = @import("engine.zig");
const sizing_pass = @import("sizing_pass.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutElement = engine_mod.LayoutElement;
const ScrollOffset = engine_mod.ScrollOffset;
const LayoutConfig = types.LayoutConfig;
const BoundingBox = types.BoundingBox;
const FloatingConfig = types.FloatingConfig;

const MAX_RECURSION_DEPTH = engine_mod.MAX_RECURSION_DEPTH;
const MAX_FLOATING_ROOTS = engine_mod.MAX_FLOATING_ROOTS;

// ============================================================================
// Phase 3: Compute positions (top-down)
// ============================================================================

/// Set this element's `bounding_box` and `content_box`, then position its
/// children inside the content box (honoring scroll offset if present).
pub fn computePositions(engine: *LayoutEngine, index: u32, parent_x: f32, parent_y: f32, depth: u32) void {
    std.debug.assert(index < engine.elements.len()); // Valid element index
    std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit

    const elem = engine.elements.get(index);
    const layout = elem.config.layout;
    const padding = layout.padding;

    // Set this element's bounding box
    elem.computed.bounding_box = .{
        .x = parent_x,
        .y = parent_y,
        .width = elem.computed.sized_width,
        .height = elem.computed.sized_height,
    };

    // Content box (inside padding)
    // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
    elem.computed.content_box = .{
        .x = parent_x + @as(f32, @floatFromInt(padding.left)),
        .y = parent_y + @as(f32, @floatFromInt(padding.top)),
        .width = @max(0, elem.computed.sized_width - padding.totalX()),
        .height = @max(0, elem.computed.sized_height - padding.totalY()),
    };

    // Position children (pass scroll offset if this is a scroll container)
    if (elem.first_child_index) |first_child| {
        const scroll_offset: ?ScrollOffset = if (elem.config.scroll) |s|
            .{ .x = s.scroll_offset.x, .y = s.scroll_offset.y }
        else
            null;
        positionChildren(engine, first_child, layout, elem.computed.content_box, scroll_offset, depth);
    }
}

/// Position children along the main axis based on
/// `main_axis_distribution` and `child_alignment`, skipping floating
/// elements (those are positioned separately in `computeFloatingPositions`).
pub fn positionChildren(
    engine: *LayoutEngine,
    first_child: u32,
    layout: LayoutConfig,
    content_box: BoundingBox,
    scroll_offset: ?ScrollOffset,
    depth: u32,
) void {
    std.debug.assert(first_child < engine.elements.len()); // Valid child index
    std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit

    const is_horizontal = layout.layout_direction.isHorizontal();

    // Sum non-floating child sizes and count them along the main axis.
    const totals = sumChildrenAlongMainAxis(engine, first_child, is_horizontal);
    if (totals.child_count == 0) return;

    // Convert distribution mode into concrete gap + start offset.
    const dist = distributionParams(layout, content_box, totals);

    // Apply scroll offset (negative — content scrolls under the viewport).
    const offset_x: f32 = if (scroll_offset) |s| -s.x else 0;
    const offset_y: f32 = if (scroll_offset) |s| -s.y else 0;

    var cursor_x: f32 = content_box.x + offset_x + if (is_horizontal) dist.start_offset else 0;
    var cursor_y: f32 = content_box.y + offset_y + if (!is_horizontal) dist.start_offset else 0;

    // Position each child, recursing into its subtree.
    var child_idx: ?u32 = first_child;
    while (child_idx) |ci| {
        const child = engine.elements.get(ci);

        // Skip floating elements - they are positioned separately in computeFloatingPositions
        if (child.config.floating != null) {
            child_idx = child.next_sibling_index;
            continue;
        }

        const cross_offset = crossAxisOffset(layout.child_alignment, content_box, child, is_horizontal);
        const child_x = cursor_x + (if (is_horizontal) 0 else cross_offset);
        const child_y = cursor_y + (if (is_horizontal) cross_offset else 0);

        computePositions(engine, ci, child_x, child_y, depth + 1);

        if (is_horizontal) {
            cursor_x += child.computed.sized_width + dist.effective_gap;
        } else {
            cursor_y += child.computed.sized_height + dist.effective_gap;
        }

        child_idx = child.next_sibling_index;
    }
}

/// Aggregates passed between the helpers below. Identical to the locals in
/// the pre-split `positionChildren`.
const MainAxisTotals = struct {
    total_size: f32,
    child_count: u32,
};

/// Pre-pass: count non-floating children and sum their main-axis sizes.
/// Floating siblings are excluded because they don't participate in flow.
fn sumChildrenAlongMainAxis(engine: *LayoutEngine, first_child: u32, is_horizontal: bool) MainAxisTotals {
    std.debug.assert(first_child < engine.elements.len());

    var total_size: f32 = 0;
    var child_count: u32 = 0;
    var child_idx: ?u32 = first_child;

    while (child_idx) |ci| {
        const child = engine.elements.getConst(ci);
        if (child.config.floating == null) {
            total_size += if (is_horizontal) child.computed.sized_width else child.computed.sized_height;
            child_count += 1;
        }
        child_idx = child.next_sibling_index;
    }

    return .{ .total_size = total_size, .child_count = child_count };
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
    std.debug.assert(engine.floating_roots.len <= MAX_FLOATING_ROOTS);

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

/// Resolve the bbox to position a floating element relative to. Order:
///   1. `attach_to_parent` honors the direct parent (e.g., dropdowns).
///   2. Otherwise, use the cached `resolved_floating_parent` index
///      (set at element creation time to avoid a HashMap lookup here).
///   3. Fall back to the viewport when neither applies (modals).
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
    } else if (elem.computed.resolved_floating_parent) |pi| {
        // cached parent index instead of HashMap lookup
        bbox = engine.elements.getConst(pi).computed.bounding_box;
    }

    return bbox;
}

/// Compute sizes for a floating element with text wrapping integrated.
pub fn computeFloatingSizesWithText(
    engine: *LayoutEngine,
    index: u32,
    max_width: f32,
    max_height: f32,
) !void {
    std.debug.assert(max_width >= 0);
    std.debug.assert(max_height >= 0);

    // First compute initial sizes (top-down).
    sizing_pass.computeFinalSizes(engine, index, max_width, max_height, 0);

    // Now wrap text with known container widths - this may change element dimensions.
    const elem = engine.elements.get(index);
    var needs_resize = false;

    if (elem.text_data) |*td| {
        const text_max_width = if (elem.parent_index) |pi| blk: {
            const parent = engine.elements.getConst(pi);
            // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
            break :blk @max(0, parent.computed.sized_width - parent.config.layout.padding.totalX());
        } else max_width;

        td.container_width = text_max_width;

        if (td.config.wrap_mode != .none and text_max_width > 0) {
            const wrap_result = try sizing_pass.wrapText(engine, td.text, td.config, text_max_width);
            td.wrapped_lines = wrap_result.lines;

            if (wrap_result.lines.len > 0) {
                td.measured_width = wrap_result.max_line_width;
                td.measured_height = wrap_result.total_height;
                elem.computed.sized_width = wrap_result.max_line_width;
                elem.computed.sized_height = wrap_result.total_height;
                needs_resize = true;
            }
        }
    }

    // Recurse to children (skipping nested floating elements — they have their own pass).
    if (elem.first_child_index) |first_child| {
        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            const child = engine.elements.get(ci);
            if (child.config.floating == null) {
                const child_max_w = child.computed.sized_width;
                const child_max_h = child.computed.sized_height;
                try computeFloatingSizesWithText(engine, ci, child_max_w, child_max_h);
            }
            child_idx = child.next_sibling_index;
        }
    }

    // If text wrapping changed dimensions, propagate up and recompute.
    if (needs_resize) {
        sizing_pass.computeMinSizes(engine, index, 0);
        sizing_pass.computeFinalSizes(engine, index, max_width, max_height, 0);
    }
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

    // Recursively position children of the floating element.
    if (elem.first_child_index) |first_child| {
        const scroll_offset: ?ScrollOffset = if (elem.config.scroll) |s|
            .{ .x = s.scroll_offset.x, .y = s.scroll_offset.y }
        else
            null;
        positionChildren(engine, first_child, elem.config.layout, elem.computed.content_box, scroll_offset, 0);
    }
}
