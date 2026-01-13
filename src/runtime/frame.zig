//! Frame Rendering
//!
//! Handles the per-frame render cycle: clearing state, calling user render function,
//! processing layout commands, and rendering widgets (text inputs, text areas, scrollbars).

const std = @import("std");

// Core imports
const gooey_mod = @import("../context/gooey.zig");
const render_bridge = @import("../core/render_bridge.zig");
const layout_mod = @import("../layout/layout.zig");
const text_mod = @import("../text/mod.zig");
const cx_mod = @import("../cx.zig");
const ui_mod = @import("../ui/mod.zig");
const render_cmd = @import("render.zig");
const canvas_mod = @import("../ui/canvas.zig");
const scene_mod = @import("../scene/mod.zig");

const Gooey = gooey_mod.Gooey;
const Cx = cx_mod.Cx;
const Builder = ui_mod.Builder;

// =============================================================================
// Limits (per CLAUDE.md: "put a limit on everything")
// =============================================================================
const MAX_RENDER_COMMANDS: usize = 65536;

/// Render a single frame with Cx context
pub fn renderFrameCx(cx: *Cx, comptime render_fn: fn (*Cx) void) !void {
    // Cache pointers at function start (avoids repeated method calls)
    const gooey = cx.gooey();
    const builder = cx.builder();

    // Reset dispatch tree for new frame
    gooey.dispatch.reset();

    gooey.beginFrame();

    // Reset builder state
    builder.id_counter = 0;
    builder.pending_inputs.clearRetainingCapacity();
    builder.pending_text_areas.clearRetainingCapacity();
    builder.pending_code_editors.clearRetainingCapacity();
    builder.pending_scrolls.clearRetainingCapacity();
    builder.pending_canvas.clearRetainingCapacity();
    builder.pending_scrolls_by_layout_id.clearRetainingCapacity();
    builder.active_scroll_drag_id = null;

    // Call user's render function with Cx
    render_fn(cx);

    // Assert pending item counts are within limits
    std.debug.assert(builder.pending_inputs.items.len <= Builder.MAX_PENDING_INPUTS);
    std.debug.assert(builder.pending_text_areas.items.len <= Builder.MAX_PENDING_TEXT_AREAS);
    std.debug.assert(builder.pending_code_editors.items.len <= Builder.MAX_PENDING_CODE_EDITORS);
    std.debug.assert(builder.pending_scrolls.items.len <= Builder.MAX_PENDING_SCROLLS);
    std.debug.assert(builder.pending_canvas.items.len <= Builder.MAX_PENDING_CANVAS);

    // End frame and get render commands
    const commands = try gooey.endFrame();

    // Assert render command count is within limits
    std.debug.assert(commands.len <= MAX_RENDER_COMMANDS);

    // Sync bounds and z_index from layout to dispatch tree
    for (gooey.dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = gooey.layout.getBoundingBox(layout_id);
            node.z_index = gooey.layout.getZIndex(layout_id);
        }
    }

    // Re-run hit testing with updated bounds to fix frame delay
    // (hover was computed with previous frame's bounds during input handling)
    gooey.refreshHover();

    // Register hit regions
    builder.registerPendingScrollRegions();

    // Clear scene
    gooey.scene.clear();

    // Start render timing for profiler
    gooey.debugger.beginRender();

    // Render all commands (includes SVGs and images inline for correct z-ordering)
    // Scrollbars are rendered inline when their scissor_end is encountered
    // Canvas draw orders are reserved during this pass for correct z-ordering
    try renderCommands(gooey, @constCast(builder), commands);

    // Render text inputs
    try renderTextInputs(gooey, builder);

    // Render text areas
    try renderTextAreas(gooey, builder);

    // Render code editors
    try renderCodeEditors(gooey, builder);

    // Render canvas elements (custom vector graphics)
    renderCanvasElements(gooey, builder);

    // Update IME cursor position for focused text input
    updateImeCursorPosition(gooey);

    // End render timing for profiler
    gooey.debugger.endRender();

    // Render debug overlays (if enabled via Cmd+Shift+I)
    try renderDebugOverlays(gooey);

    gooey.scene.finish();

    // Finalize frame timing for profiler
    gooey.finalizeFrame();
}

// =============================================================================
// Internal Render Helpers
// =============================================================================

/// Render all layout commands
fn renderCommands(gooey: *Gooey, builder: *Builder, commands: []const layout_mod.RenderCommand) !void {
    for (commands) |cmd| {
        // Check if this command's element corresponds to a pending canvas
        // If so, reserve a draw order now (in correct z-order) for later canvas painting
        for (builder.pending_canvas.items) |*pending| {
            if (pending.layout_id == cmd.id and pending.base_order == 0) {
                // Reserve a base draw order for this canvas
                // Canvas primitives will use orders starting from this base
                pending.base_order = gooey.scene.reserveCanvasOrders(256); // Reserve block of 256 orders
                pending.clip_bounds = gooey.scene.currentClip();
                break;
            }
        }

        try render_cmd.renderCommand(gooey, cmd);

        // When a scissor region ends, check if it's a scroll container and render its scrollbars
        // This ensures scrollbars appear after scroll content but before sibling elements
        if (cmd.command_type == .scissor_end) {
            if (builder.findPendingScrollByLayoutId(cmd.id)) |pending| {
                if (gooey.widgets.scrollContainer(pending.id)) |scroll_widget| {
                    try scroll_widget.renderScrollbars(gooey.scene);
                }
            }
        }
    }
}

/// Render all pending canvas elements
fn renderCanvasElements(gooey: *Gooey, builder: *const Builder) void {
    for (builder.pending_canvas.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id) orelse continue;
        canvas_mod.executePendingCanvas(pending, gooey.scene, scene_mod.Bounds.init(
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
        ), gooey.text_system);
    }
}

/// Render all pending text inputs
fn renderTextInputs(gooey: *Gooey, builder: *const Builder) !void {
    for (builder.pending_inputs.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        const input_widget = gooey.textInput(pending.id) orelse continue;

        const inset = pending.style.padding + pending.style.border_width;
        input_widget.bounds = .{
            .x = bounds.x + inset,
            .y = bounds.y + inset,
            .width = pending.inner_width,
            .height = pending.inner_height,
        };
        input_widget.setPlaceholder(pending.style.placeholder);
        input_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
        input_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
        input_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
        input_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
        try input_widget.render(gooey.scene, gooey.text_system, gooey.scale_factor);
    }
}

/// Render all pending text areas
fn renderTextAreas(gooey: *Gooey, builder: *const Builder) !void {
    for (builder.pending_text_areas.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        const ta_widget = gooey.textArea(pending.id) orelse continue;

        ta_widget.bounds = .{
            .x = bounds.x + pending.style.padding + pending.style.border_width,
            .y = bounds.y + pending.style.padding + pending.style.border_width,
            .width = pending.inner_width,
            .height = pending.inner_height,
        };
        ta_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
        ta_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
        ta_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
        ta_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
        ta_widget.setPlaceholder(pending.style.placeholder);
        try ta_widget.render(gooey.scene, gooey.text_system, gooey.scale_factor);
    }
}

/// Render all pending code editors
fn renderCodeEditors(gooey: *Gooey, builder: *const Builder) !void {
    for (builder.pending_code_editors.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        const ce_widget = gooey.codeEditor(pending.id) orelse continue;

        const inset = pending.style.padding + pending.style.border_width;
        ce_widget.setBounds(.{
            .x = bounds.x + inset,
            .y = bounds.y + inset,
            .width = pending.inner_width,
            .height = pending.inner_height,
        });

        // Update code editor specific settings
        ce_widget.show_line_numbers = pending.style.show_line_numbers;
        ce_widget.gutter_width = pending.style.gutter_width;
        ce_widget.tab_size = pending.style.tab_size;
        ce_widget.use_hard_tabs = pending.style.use_hard_tabs;

        // Update style colors
        ce_widget.style.text.text_color = render_bridge.colorToHsla(pending.style.text_color);
        ce_widget.style.text.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
        ce_widget.style.text.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
        ce_widget.style.text.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
        ce_widget.style.gutter_background = render_bridge.colorToHsla(pending.style.gutter_background);
        ce_widget.style.line_number_color = render_bridge.colorToHsla(pending.style.line_number_color);
        ce_widget.style.current_line_number_color = render_bridge.colorToHsla(pending.style.current_line_number_color);
        ce_widget.style.gutter_separator_color = render_bridge.colorToHsla(pending.style.gutter_separator_color);
        ce_widget.style.current_line_background = render_bridge.colorToHsla(pending.style.current_line_background);

        // Status bar settings
        ce_widget.show_status_bar = pending.style.show_status_bar;
        ce_widget.status_bar_height = pending.style.status_bar_height;
        ce_widget.style.status_bar_background = render_bridge.colorToHsla(pending.style.status_bar_background);
        ce_widget.style.status_bar_text_color = render_bridge.colorToHsla(pending.style.status_bar_text_color);
        ce_widget.style.status_bar_separator_color = render_bridge.colorToHsla(pending.style.status_bar_separator_color);
        ce_widget.language_mode = pending.style.language_mode;
        ce_widget.encoding = pending.style.encoding;

        ce_widget.setPlaceholder(pending.style.placeholder);
        try ce_widget.render(gooey.scene, gooey.text_system, gooey.scale_factor);
    }
}

/// Update IME cursor position for focused text widget
fn updateImeCursorPosition(gooey: *Gooey) void {
    if (gooey.getFocusedTextInput()) |input| {
        const rect = input.cursor_rect;
        gooey.getWindow().setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    } else if (gooey.getFocusedTextArea()) |ta| {
        const rect = ta.cursor_rect;
        gooey.getWindow().setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    } else if (gooey.getFocusedCodeEditor()) |ce| {
        const rect = ce.getCursorRect();
        gooey.getWindow().setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    }
}

/// Render debug overlays if enabled
fn renderDebugOverlays(gooey: *Gooey) !void {
    if (!gooey.debugger.isActive()) return;

    gooey.debugger.generateOverlays(
        gooey.hovered_layout_id,
        gooey.hovered_ancestors[0..gooey.hovered_ancestor_count],
        gooey.layout,
    );
    try gooey.debugger.renderOverlays(gooey.scene);

    // Render inspector panel (Phase 2)
    if (gooey.debugger.showInspector()) {
        try gooey.debugger.renderInspectorPanel(
            gooey.scene,
            gooey.text_system,
            gooey.width,
            gooey.height,
            gooey.scale_factor,
        );
    }

    // Render profiler panel
    if (gooey.debugger.showProfiler()) {
        try gooey.debugger.renderProfilerPanel(
            gooey.scene,
            gooey.text_system,
            gooey.width,
            gooey.scale_factor,
        );
    }
}
