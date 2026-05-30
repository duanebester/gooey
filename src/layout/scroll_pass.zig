//! Layout scroll/render pass — Phase 4 of the layout pipeline.
//!
//! Reads positioned elements from `position_pass.zig` and emits the flat
//! `RenderCommandList` consumed by the rendering backend.
//!
//! The dominant concern is scroll-container framing: every `scroll` element
//! gets paired `scissor_start` / `scissor_end` commands wrapping its
//! children. Background/text/svg/image emission is the other half, split
//! into per-primitive `emit*Command` helpers.
//!
//! Inherited state threads through the recursion:
//!   - `inherited_z_index` — floating elements override; descendants
//!     inherit until another floating ancestor changes it.
//!   - `inherited_opacity` — multiplicative; alpha-folded into each
//!     emitted command so the renderer doesn't need a stack.

const std = @import("std");

const engine_mod = @import("engine.zig");
const types = @import("types.zig");
const render_commands = @import("render_commands.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutElement = engine_mod.LayoutElement;
const BoundingBox = types.BoundingBox;
const RenderCommand = render_commands.RenderCommand;

const MAX_RECURSION_DEPTH = engine_mod.MAX_RECURSION_DEPTH;

// ============================================================================
// Phase 4: Generate render commands
// ============================================================================

/// Walk the positioned tree, emit one or more render commands per element,
/// and recurse. Wraps scroll containers in scissor pairs so the renderer
/// can clip out-of-bounds children without inspecting the layout tree.
pub fn generateRenderCommands(
    engine: *LayoutEngine,
    index: u32,
    inherited_z_index: i16,
    inherited_opacity: f32,
    depth: u32,
) !void {
    std.debug.assert(inherited_opacity >= 0 and inherited_opacity <= 1.0);
    std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit

    const elem = engine.elements.get(index);
    const bbox = elem.computed.bounding_box;

    // Floating elements override z_index for themselves and their children.
    const z_index: i16 = if (elem.config.floating) |f| f.z_index else inherited_z_index;

    // Combine element opacity with inherited opacity (multiplicative).
    const opacity = elem.config.opacity * inherited_opacity;

    // Cache z_index for O(1) lookup via getZIndex().
    elem.cached_z_index = z_index;

    // Generate commands for each visual component (order matters — shadow
    // first so it renders behind the background, canvas last so its draw
    // order slot follows everything else on this element).
    try emitShadowCommand(engine, elem, bbox, z_index, opacity);
    try emitRectangleCommand(engine, elem, bbox, z_index, opacity);
    try emitBorderCommand(engine, elem, bbox, z_index, opacity);
    try emitTextCommands(engine, elem, bbox, z_index, opacity);
    try emitSvgCommand(engine, elem, bbox, z_index, opacity);
    try emitImageCommand(engine, elem, bbox, z_index, opacity);
    try emitCanvasCommand(engine, elem, bbox, z_index);

    // Scissor for scroll containers (before children).
    const has_scroll = elem.config.scroll != null;
    if (has_scroll) try emitScissorStart(engine, elem, bbox, z_index);

    // Recurse to children (passing inherited opacity).
    if (elem.first_child_index) |first_child| {
        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            try generateRenderCommands(engine, ci, z_index, opacity, depth + 1);
            child_idx = engine.elements.getConst(ci).next_sibling_index;
        }
    }

    // End scissor (after children).
    if (has_scroll) try emitScissorEnd(engine, elem, bbox, z_index);
}

/// Emit a `scissor_start` command before any children of a scroll container
/// render. Pairs with `emitScissorEnd` — the renderer is responsible for
/// stack discipline within the command list, not us.
fn emitScissorStart(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16) !void {
    try engine.commands.append(.{
        .bounding_box = bbox,
        .command_type = .scissor_start,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .scissor_start = .{ .clip_bounds = bbox } },
    });
}

/// Emit a `scissor_end` command after the children of a scroll container
/// finish rendering. The bbox matches the start command so debug tools
/// (and the renderer) can pair them by structural equality.
fn emitScissorEnd(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16) !void {
    try engine.commands.append(.{
        .bounding_box = bbox,
        .command_type = .scissor_end,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .scissor_end = {} },
    });
}

/// Emit shadow render command (skip if invisible to keep command count tight).
fn emitShadowCommand(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
    const shadow = elem.config.shadow orelse return;
    if (!shadow.isVisible()) return;

    try engine.commands.append(.{
        .bounding_box = bbox,
        .command_type = .shadow,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .shadow = .{
            .blur_radius = shadow.blur_radius,
            .color = shadow.color.withAlpha(shadow.color.a * opacity),
            .offset_x = shadow.offset_x,
            .offset_y = shadow.offset_y,
            .corner_radius = elem.config.corner_radius,
        } },
    });
}

/// Emit background rectangle render command.
fn emitRectangleCommand(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
    const bg = elem.config.background_color orelse return;

    try engine.commands.append(.{
        .bounding_box = bbox,
        .command_type = .rectangle,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .rectangle = .{
            .background_color = bg.withAlpha(bg.a * opacity),
            .corner_radius = elem.config.corner_radius,
        } },
    });
}

/// Emit border render command.
fn emitBorderCommand(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
    const border = elem.config.border orelse return;

    try engine.commands.append(.{
        .bounding_box = bbox,
        .command_type = .border,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .border = .{
            .color = border.color.withAlpha(border.color.a * opacity),
            .width = border.width,
            .corner_radius = elem.config.corner_radius,
        } },
    });
}

/// Emit text render commands (handles wrapped and single-line). Delegates
/// to `emitWrappedLines` when wrapping is on so this function stays under
/// the 70-line limit.
fn emitTextCommands(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
    // `text_data` is unwrapped by reference so we don't copy ~60 bytes of
    // `TextData` for the common case (single text element per frame).
    const td: *const engine_mod.TextData = if (elem.text_data) |*t| t else return;
    const text_color = td.config.color.withAlpha(td.config.color.a * opacity);
    const align_width = if (td.container_width > 0) td.container_width else bbox.width;

    if (td.wrapped_lines) |lines| {
        try emitWrappedLines(engine, elem, td, lines, bbox, text_color, align_width, z_index);
        return;
    }

    // Single line (no wrapping)
    const text_x = bbox.x + switch (td.config.alignment) {
        .left => 0,
        .center => (align_width - td.measured_width) / 2,
        .right => align_width - td.measured_width,
    };
    try engine.commands.append(.{
        .bounding_box = .{ .x = text_x, .y = bbox.y, .width = td.measured_width, .height = bbox.height },
        .command_type = .text,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .text = .{
            .text = td.text,
            .color = text_color,
            .font_id = td.config.font_id,
            .font_size = td.config.font_size,
            .letter_spacing = td.config.letter_spacing,
            .underline = td.config.decoration.underline,
            .strikethrough = td.config.decoration.strikethrough,
        } },
    });
}

/// Emit one text command per wrapped line. Pure leaf — no recursion.
/// `lines` may be empty (when `wrapText` short-circuited), in which case
/// the loop emits nothing — do not assert non-empty here.
fn emitWrappedLines(
    engine: *LayoutEngine,
    elem: *LayoutElement,
    td: *const engine_mod.TextData,
    lines: []const types.WrappedLine,
    bbox: BoundingBox,
    text_color: types.Color,
    align_width: f32,
    z_index: i16,
) !void {
    std.debug.assert(td.config.font_size > 0);
    std.debug.assert(align_width >= 0);

    const line_height = td.config.lineHeightPx();
    for (lines, 0..) |line, i| {
        const line_y = bbox.y + @as(f32, @floatFromInt(i)) * line_height;
        const line_x = bbox.x + switch (td.config.alignment) {
            .left => 0,
            .center => (align_width - line.width) / 2,
            .right => align_width - line.width,
        };
        try engine.commands.append(.{
            .bounding_box = .{ .x = line_x, .y = line_y, .width = line.width, .height = line_height },
            .command_type = .text,
            .z_index = z_index,
            .id = elem.id,
            .data = .{ .text = .{
                .text = td.text[line.start_offset..][0..line.length],
                .color = text_color,
                .font_id = td.config.font_id,
                .font_size = td.config.font_size,
                .letter_spacing = td.config.letter_spacing,
                .underline = td.config.decoration.underline,
                .strikethrough = td.config.decoration.strikethrough,
            } },
        });
    }
}

/// Emit SVG render command.
fn emitSvgCommand(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
    const sd = elem.svg_data orelse return;

    try engine.commands.append(.{
        .bounding_box = bbox,
        .command_type = .svg,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .svg = .{
            .path = sd.path,
            .color = sd.color.withAlpha(sd.color.a * opacity),
            .stroke_color = if (sd.stroke_color) |sc| sc.withAlpha(sc.a * opacity) else null,
            .stroke_width = sd.stroke_width,
            .has_fill = sd.has_fill,
            .viewbox = sd.viewbox,
        } },
    });
}

/// Emit image render command (folds inherited opacity into the image's own
/// alpha so the renderer doesn't need an inheritance stack).
fn emitImageCommand(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
    const id = elem.image_data orelse return;

    try engine.commands.append(.{
        .bounding_box = bbox,
        .command_type = .image,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .image = .{
            .source = id.source,
            .width = id.width,
            .height = id.height,
            .fit = id.fit,
            .corner_radius = id.corner_radius,
            .tint = id.tint,
            .grayscale = id.grayscale,
            .opacity = id.opacity * opacity,
            .placeholder_color = id.placeholder_color,
        } },
    });
}

/// Emit canvas render command. Canvas commands reserve draw orders for
/// deferred paint callbacks — the renderer fills them in later.
fn emitCanvasCommand(engine: *LayoutEngine, elem: *LayoutElement, bbox: BoundingBox, z_index: i16) !void {
    if (!elem.config.is_canvas) return;

    try engine.commands.append(.{
        .bounding_box = bbox,
        .command_type = .canvas,
        .z_index = z_index,
        .id = elem.id,
        .data = .{ .canvas = .{ .layout_id = elem.id } },
    });
}
