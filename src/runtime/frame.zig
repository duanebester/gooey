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

    // Register hit regions
    cx.builder().registerPendingScrollRegions();

    // Clear scene
    cx.gooey().scene.clear();

    // Render all commands (includes SVGs and images inline for correct z-ordering)
    for (commands) |cmd| {
        try render_cmd.renderCommand(cx.gooey(), cmd);
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

    // Render scrollbars
    for (cx.builder().pending_scrolls.items) |pending| {
        if (cx.gooey().widgets.scrollContainer(pending.id)) |scroll_widget| {
            try scroll_widget.renderScrollbars(cx.gooey().scene);
        }
    }

    cx.gooey().scene.finish();
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

    // Register hit regions
    ctx.builder.registerPendingScrollRegions();

    // Clear scene
    ctx.gooey.scene.clear();

    // Render all commands
    for (commands) |cmd| {
        try render_cmd.renderCommand(ctx.gooey, cmd);
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

    // Render scrollbars
    for (ctx.builder.pending_scrolls.items) |pending| {
        if (ctx.gooey.widgets.scrollContainer(pending.id)) |scroll_widget| {
            try scroll_widget.renderScrollbars(ctx.gooey.scene);
        }
    }

    ctx.gooey.scene.finish();
}
