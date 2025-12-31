//! Frame Rendering
//!
//! Handles the per-frame render cycle: clearing state, calling user render function,
//! processing layout commands, and rendering widgets (text inputs, text areas, scrollbars).

const std = @import("std");

// Core imports
const gooey_mod = @import("../core/gooey.zig");
const render_bridge = @import("../core/render_bridge.zig");
const layout_mod = @import("../layout/layout.zig");
const text_mod = @import("../text/mod.zig");
const cx_mod = @import("../cx.zig");
const ui_mod = @import("../ui/mod.zig");
const render_cmd = @import("render.zig");

const Gooey = gooey_mod.Gooey;
const Cx = cx_mod.Cx;
const Builder = ui_mod.Builder;

/// Render a single frame with Cx context
pub fn renderFrameCx(cx: *Cx, comptime render_fn: fn (*Cx) void) !void {
    // Reset dispatch tree for new frame
    cx.gooey().dispatch.reset();

    cx.gooey().beginFrame();

    // Reset builder state
    cx.builder().id_counter = 0;
    cx.builder().pending_inputs.clearRetainingCapacity();
    cx.builder().pending_text_areas.clearRetainingCapacity();
    cx.builder().pending_scrolls.clearRetainingCapacity();

    // Call user's render function with Cx
    render_fn(cx);

    // End frame and get render commands
    const commands = try cx.gooey().endFrame();

    // Sync bounds and z_index from layout to dispatch tree
    for (cx.gooey().dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = cx.gooey().layout.getBoundingBox(layout_id);
            node.z_index = cx.gooey().layout.getZIndex(layout_id);
        }
    }

    // Re-run hit testing with updated bounds to fix frame delay
    // (hover was computed with previous frame's bounds during input handling)
    cx.gooey().refreshHover();

    // Register hit regions
    cx.builder().registerPendingScrollRegions();

    // Clear scene
    cx.gooey().scene.clear();

    // Start render timing for profiler
    cx.gooey().debugger.beginRender();

    // Render all commands (includes SVGs and images inline for correct z-ordering)
    // Scrollbars are rendered inline when their scissor_end is encountered
    for (commands) |cmd| {
        try render_cmd.renderCommand(cx.gooey(), cmd);

        // When a scissor region ends, check if it's a scroll container and render its scrollbars
        // This ensures scrollbars appear after scroll content but before sibling elements
        if (cmd.command_type == .scissor_end) {
            if (cx.builder().findPendingScrollByLayoutId(cmd.id)) |pending| {
                if (cx.gooey().widgets.scrollContainer(pending.id)) |scroll_widget| {
                    try scroll_widget.renderScrollbars(cx.gooey().scene);
                }
            }
        }
    }

    // Render text inputs
    for (cx.builder().pending_inputs.items) |pending| {
        const bounds = cx.gooey().layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (cx.gooey().textInput(pending.id)) |input_widget| {
                const inset = pending.style.padding + pending.style.border_width;
                input_widget.bounds = .{
                    .x = b.x + inset,
                    .y = b.y + inset,
                    .width = pending.inner_width,
                    .height = pending.inner_height,
                };
                input_widget.setPlaceholder(pending.style.placeholder);
                input_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
                input_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
                input_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
                input_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
                try input_widget.render(cx.gooey().scene, cx.gooey().text_system, cx.gooey().scale_factor);
            }
        }
    }

    // Render text areas
    for (cx.builder().pending_text_areas.items) |pending| {
        const bounds = cx.gooey().layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (cx.gooey().textArea(pending.id)) |ta_widget| {
                ta_widget.bounds = .{
                    .x = b.x + pending.style.padding + pending.style.border_width,
                    .y = b.y + pending.style.padding + pending.style.border_width,
                    .width = pending.inner_width,
                    .height = pending.inner_height,
                };
                ta_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
                ta_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
                ta_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
                ta_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
                ta_widget.setPlaceholder(pending.style.placeholder);
                try ta_widget.render(cx.gooey().scene, cx.gooey().text_system, cx.gooey().scale_factor);
            }
        }
    }

    // Update IME cursor position for focused text input
    if (cx.gooey().getFocusedTextInput()) |input| {
        const rect = input.cursor_rect;
        cx.gooey().getWindow().setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    } else if (cx.gooey().getFocusedTextArea()) |ta| {
        const rect = ta.cursor_rect;
        cx.gooey().getWindow().setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    }

    // Note: Scrollbars are now rendered inline with commands (see above)
    // This ensures correct z-ordering with sibling elements

    // End render timing for profiler
    cx.gooey().debugger.endRender();

    // Render debug overlays (if enabled via Cmd+Shift+I)
    if (cx.gooey().debugger.isActive()) {
        cx.gooey().debugger.generateOverlays(
            cx.gooey().hovered_layout_id,
            cx.gooey().hovered_ancestors[0..cx.gooey().hovered_ancestor_count],
            cx.gooey().layout,
        );
        try cx.gooey().debugger.renderOverlays(cx.gooey().scene);

        // Render inspector panel (Phase 2)
        if (cx.gooey().debugger.showInspector()) {
            try cx.gooey().debugger.renderInspectorPanel(
                cx.gooey().scene,
                cx.gooey().text_system,
                cx.gooey().width,
                cx.gooey().height,
                cx.gooey().scale_factor,
            );
        }

        // Render profiler panel
        if (cx.gooey().debugger.showProfiler()) {
            try cx.gooey().debugger.renderProfilerPanel(
                cx.gooey().scene,
                cx.gooey().text_system,
                cx.gooey().width,
                cx.gooey().scale_factor,
            );
        }
    }

    cx.gooey().scene.finish();

    // Finalize frame timing for profiler
    cx.gooey().finalizeFrame();
}

/// Render a single frame with typed context (legacy API support)
pub fn renderFrameWithContext(
    comptime ContextType: type,
    ctx: *ContextType,
    render_fn: *const fn (*ContextType) void,
) !void {
    // Reset dispatch tree for new frame
    ctx.gooey.dispatch.reset();

    ctx.gooey.beginFrame();

    // Reset builder state
    ctx.builder.id_counter = 0;
    ctx.builder.pending_inputs.clearRetainingCapacity();
    ctx.builder.pending_text_areas.clearRetainingCapacity();
    ctx.builder.pending_scrolls.clearRetainingCapacity();
    ctx.builder.pending_svgs.clearRetainingCapacity();

    // Call user's render function with typed context
    render_fn(ctx);

    // End frame and get render commands
    const commands = try ctx.gooey.endFrame();

    // Sync bounds and z_index from layout to dispatch tree
    for (ctx.gooey.dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = ctx.gooey.layout.getBoundingBox(layout_id);
            node.z_index = ctx.gooey.layout.getZIndex(layout_id);
        }
    }

    // Re-run hit testing with updated bounds to fix frame delay
    // (hover was computed with previous frame's bounds during input handling)
    ctx.gooey.refreshHover();

    // Register hit regions
    ctx.builder.registerPendingScrollRegions();

    // Clear scene
    ctx.gooey.scene.clear();

    // Start render timing for profiler
    ctx.gooey.debugger.beginRender();

    // Render all commands
    // Scrollbars are rendered inline when their scissor_end is encountered
    for (commands) |cmd| {
        try render_cmd.renderCommand(ctx.gooey, cmd);

        // When a scissor region ends, check if it's a scroll container and render its scrollbars
        // This ensures scrollbars appear after scroll content but before sibling elements
        if (cmd.command_type == .scissor_end) {
            if (ctx.builder.findPendingScrollByLayoutId(cmd.id)) |pending| {
                if (ctx.gooey.widgets.scrollContainer(pending.id)) |scroll_widget| {
                    try scroll_widget.renderScrollbars(ctx.gooey.scene);
                }
            }
        }
    }

    // Render text inputs
    for (ctx.builder.pending_inputs.items) |pending| {
        const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (ctx.gooey.textInput(pending.id)) |input_widget| {
                // Calculate inner text area (inside padding and border)
                const inset = pending.style.padding + pending.style.border_width;
                input_widget.bounds = .{
                    .x = b.x + inset,
                    .y = b.y + inset,
                    .width = pending.inner_width,
                    .height = pending.inner_height,
                };
                input_widget.setPlaceholder(pending.style.placeholder);

                // Apply text styles from InputStyle
                input_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
                input_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
                input_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
                input_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);

                try input_widget.render(ctx.gooey.scene, ctx.gooey.text_system, ctx.gooey.scale_factor);
            }
        }
    }

    // Render text areas
    for (ctx.builder.pending_text_areas.items) |pending| {
        const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (ctx.gooey.textArea(pending.id)) |ta_widget| {
                // Set bounds (inner content area, accounting for padding/border)
                ta_widget.bounds = .{
                    .x = b.x + pending.style.padding + pending.style.border_width,
                    .y = b.y + pending.style.padding + pending.style.border_width,
                    .width = pending.inner_width,
                    .height = pending.inner_height,
                };

                // Apply style colors
                ta_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
                ta_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
                ta_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
                ta_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);

                ta_widget.setPlaceholder(pending.style.placeholder);
                try ta_widget.render(ctx.gooey.scene, ctx.gooey.text_system, ctx.gooey.scale_factor);
            }
        }
    }

    // Update IME cursor position for focused text input
    if (ctx.gooey.getFocusedTextInput()) |input| {
        const rect = input.cursor_rect;
        ctx.gooey.getWindow().setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    } else if (ctx.gooey.getFocusedTextArea()) |ta| {
        const rect = ta.cursor_rect;
        ctx.gooey.getWindow().setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    }

    // Note: Scrollbars are now rendered inline with commands (see above)
    // This ensures correct z-ordering with sibling elements

    // End render timing for profiler
    ctx.gooey.debugger.endRender();

    // Render debug overlays (if enabled via Cmd+Shift+I)
    if (ctx.gooey.debugger.isActive()) {
        ctx.gooey.debugger.generateOverlays(
            ctx.gooey.hovered_layout_id,
            ctx.gooey.hovered_ancestors[0..ctx.gooey.hovered_ancestor_count],
            ctx.gooey.layout,
        );
        try ctx.gooey.debugger.renderOverlays(ctx.gooey.scene);

        // Render inspector panel (Phase 2)
        if (ctx.gooey.debugger.showInspector()) {
            try ctx.gooey.debugger.renderInspectorPanel(
                ctx.gooey.scene,
                ctx.gooey.text_system,
                ctx.gooey.width,
                ctx.gooey.height,
                ctx.gooey.scale_factor,
            );
        }

        // Render profiler panel
        if (ctx.gooey.debugger.showProfiler()) {
            try ctx.gooey.debugger.renderProfilerPanel(
                ctx.gooey.scene,
                ctx.gooey.text_system,
                ctx.gooey.width,
                ctx.gooey.scale_factor,
            );
        }
    }

    ctx.gooey.scene.finish();

    // Finalize frame timing for profiler
    ctx.gooey.finalizeFrame();
}
