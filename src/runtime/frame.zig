//! Frame Rendering
//!
//! Handles the per-frame render cycle: clearing state, calling user render function,
//! processing layout commands, and rendering widgets (text inputs, text areas, scrollbars).

const std = @import("std");

// Core imports
const window_mod = @import("../context/window.zig");
const render_bridge = @import("../scene/render_bridge.zig");
const layout_mod = @import("../layout/layout.zig");
const text_mod = @import("../text/mod.zig");
const cx_mod = @import("../cx.zig");
const ui_mod = @import("../ui/mod.zig");
const render_cmd = @import("render.zig");
const canvas_mod = @import("../ui/canvas.zig");
const scene_mod = @import("../scene/mod.zig");

const Window = window_mod.Window;
const Cx = cx_mod.Cx;
const Builder = ui_mod.Builder;

// =============================================================================
// Limits (per CLAUDE.md: "put a limit on everything")
// =============================================================================
const MAX_RENDER_COMMANDS: usize = 65536;

/// Render a single frame with Cx context (comptime render function)
pub fn renderFrameCx(cx: *Cx, comptime render_fn: fn (*Cx) void) !void {
    try renderFrameImpl(cx, render_fn);
}

/// Render a single frame with Cx context (runtime render function pointer)
/// Used by WindowContext for per-window callbacks.
pub fn renderFrameCxRuntime(cx: *Cx, render_fn: *const fn (*Cx) void) !void {
    try renderFrameImpl(cx, render_fn);
}

/// Internal implementation shared by comptime and runtime variants
fn renderFrameImpl(cx: *Cx, render_fn: anytype) !void {
    // Cache pointers at function start (avoids repeated method calls).
    //
    // PR 7c.2 — `app` is now driven directly from this layer. The
    // app-scoped per-tick begin/end pair (see `App.beginFrame` /
    // `App.endFrame`) used to be reached through `Window.beginFrame`
    // / `Window.endFrame`; pre-7c.2 a multi-window flow with N
    // windows borrowing one `App` ran the begin pair N times per
    // tick, which was redundant for `image_loader.drain`
    // (idempotent) and *broken* for `entities.beginFrame`
    // (window-A-render-then-window-B-begin discarded window-A's
    // earlier-this-tick frame observations). Caching the pointer
    // here makes the once-per-tick invariant visible at the layer
    // that owns it.
    const window = cx.window();
    const app = window.app;
    const builder = cx.builder();

    // Report GPU timings from previous frame (GPU work happens after finalizeFrame).
    // Only available on platforms whose Window struct records GPU timing (Linux/Vulkan).
    if (window.getPlatformWindow()) |w| {
        const W = @TypeOf(w.*);
        if (comptime @hasField(W, "last_gpu_submit_ns")) {
            window.debugger().reportGpuTimings(w.last_gpu_submit_ns, w.last_atlas_upload_ns);
        }
    }

    // Reset dispatch tree for new frame
    window.frame.dispatch.reset();

    window.beginFrame();

    // PR 7c.2 — app-scoped per-tick hook. Hoisted out of
    // `Window.beginFrame` so it runs at the runtime layer, not
    // through every per-window forwarder. Drains async image-load
    // results into the shared atlas (idempotent — a second call
    // gets 0 results) and clears stale entity observations from
    // the previous tick (NOT idempotent within a tick).
    //
    // Order constraints the call site must preserve:
    //   1. After `window.beginFrame()` so the per-window
    //      `image_atlas.beginFrame()` has already incremented the
    //      frame counter; freshly-decoded pixels then land in the
    //      post-reset atlas.
    //   2. Before `render_fn(cx)` so observations made by widget
    //      renders this tick are not discarded by the entity-
    //      observation clear.
    //
    // Today's call shape (single window per tick) trivially
    // satisfies both. A future tick-driver in PR 7c.3+ that drives
    // N windows per tick must still call `app.beginFrame()` once
    // per tick *between* every window's `image_atlas.beginFrame`
    // and any window's render — not once per window.
    app.beginFrame();

    // Clear blur handlers from previous frame
    window.clearBlurHandlers();

    // Reset builder state
    builder.id_counter = 0;
    builder.pending_inputs.clearRetainingCapacity();
    builder.pending_text_areas.clearRetainingCapacity();
    builder.pending_code_editors.clearRetainingCapacity();
    builder.pending_scrolls.clearRetainingCapacity();
    builder.pending_canvas.clearRetainingCapacity();
    builder.pending_scrolls_by_layout_id.clearRetainingCapacity();
    builder.active_scroll_drag_id = null;

    // Call user's render function with Cx — time tree construction separately
    window.debugger().beginTreeBuild(window.io);
    render_fn(cx);
    window.debugger().endTreeBuild(window.io);

    // Assert pending item counts are within limits
    std.debug.assert(builder.pending_inputs.items.len <= Builder.MAX_PENDING_INPUTS);
    std.debug.assert(builder.pending_text_areas.items.len <= Builder.MAX_PENDING_TEXT_AREAS);
    std.debug.assert(builder.pending_code_editors.items.len <= Builder.MAX_PENDING_CODE_EDITORS);
    std.debug.assert(builder.pending_scrolls.items.len <= Builder.MAX_PENDING_SCROLLS);
    std.debug.assert(builder.pending_canvas.items.len <= Builder.MAX_PENDING_CANVAS);

    // End frame and get render commands
    const commands = try window.endFrame();

    // PR 7c.2 — symmetric app-scoped per-tick finalisation,
    // hoisted out of `Window.endFrame`. Currently a no-op
    // (`EntityMap.endFrame` is itself a no-op), so the visible
    // behaviour is unchanged; the motivation is layering. Future
    // batching optimisations the `App.endFrame` hook is reserved
    // for now have a single per-tick driver to hang off rather
    // than firing once per window per tick.
    //
    // Position: must follow `window.endFrame()` so any per-window
    // finalisation (a11y bounds sync, layout commit) has already
    // run. A future tick-driver running N windows per tick must
    // call this exactly once *after* every window's `endFrame`
    // returns.
    app.endFrame();

    // Assert render command count is within limits
    std.debug.assert(commands.len <= MAX_RENDER_COMMANDS);

    // Sync bounds and z_index from layout to dispatch tree
    // (previously untracked — now measured as "dispatch sync")
    window.debugger().beginDispatchSync(window.io);

    for (window.frame.dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = window.layout.getBoundingBox(layout_id);
            node.z_index = window.layout.getZIndex(layout_id);
        }
    }

    // Re-run hit testing with updated bounds to fix frame delay
    // (hover was computed with previous frame's bounds during input handling)
    window.refreshHover();

    // Register hit regions
    builder.registerPendingScrollRegions();

    window.debugger().endDispatchSync(window.io);

    // Clear scene
    window.frame.scene.clear();

    // Reset SVG atlas per-frame rasterization budget so that expensive
    // software rasterizations are spread across multiple frames instead
    // of stalling a single frame when many uncached icons scroll into view.
    window.resources.svg_atlas.resetFrameBudget();

    // Start render timing for profiler
    window.debugger().beginRender(window.io);

    // Render all commands (includes SVGs and images inline for correct z-ordering)
    // Scrollbars are rendered inline when their scissor_end is encountered
    // Canvas draw orders are reserved during this pass for correct z-ordering
    try renderCommands(window, @constCast(builder), commands);

    // Register blur handlers from pending items
    registerBlurHandlers(window, builder);

    // Render text inputs
    try renderTextInputs(window, builder);

    // Render text areas
    try renderTextAreas(window, builder);

    // Render code editors
    try renderCodeEditors(window, builder);

    // Render canvas elements (custom vector graphics)
    renderCanvasElements(window, builder);

    // Update IME cursor position for focused text input
    updateImeCursorPosition(window);

    // End render timing for profiler
    window.debugger().endRender(window.io);

    // Render debug overlays (if enabled via Cmd+Shift+I)
    try renderDebugOverlays(window);

    window.frame.scene.finish();

    // If SVG rasterizations were deferred due to per-frame budget, request
    // another render so the remaining icons progressively appear.
    if (window.resources.svg_atlas.hasDeferredWork()) {
        window.requestRender();
    }

    // Finalize frame timing for profiler
    window.finalizeFrame();
}

// =============================================================================
// Internal Render Helpers
// =============================================================================

/// Register blur handlers from pending items
fn registerBlurHandlers(window: *Window, builder: *const Builder) void {
    // Register handlers from pending text inputs
    for (builder.pending_inputs.items) |pending| {
        if (pending.on_blur_handler) |handler| {
            window.registerBlurHandler(pending.id, handler);
        }
    }
    // Register handlers from pending text areas
    for (builder.pending_text_areas.items) |pending| {
        if (pending.on_blur_handler) |handler| {
            window.registerBlurHandler(pending.id, handler);
        }
    }
    // Register handlers from pending code editors
    for (builder.pending_code_editors.items) |pending| {
        if (pending.on_blur_handler) |handler| {
            window.registerBlurHandler(pending.id, handler);
        }
    }
}

/// Render all layout commands
fn renderCommands(window: *Window, builder: *Builder, commands: []const layout_mod.RenderCommand) !void {
    for (commands) |cmd| {
        // Check if this command's element corresponds to a pending canvas
        // If so, reserve a draw order now (in correct z-order) for later canvas painting
        for (builder.pending_canvas.items) |*pending| {
            if (pending.layout_id == cmd.id and pending.base_order == 0) {
                // Reserve a base draw order for this canvas
                // Canvas primitives will use orders starting from this base
                pending.base_order = window.frame.scene.reserveCanvasOrders(256); // Reserve block of 256 orders
                pending.clip_bounds = window.frame.scene.currentClip();
                break;
            }
        }

        try render_cmd.renderCommand(window, cmd);

        // When a scissor region ends, check if it's a scroll container and render its scrollbars
        // This ensures scrollbars appear after scroll content but before sibling elements
        if (cmd.command_type == .scissor_end) {
            if (builder.findPendingScrollByLayoutId(cmd.id)) |pending| {
                if (window.widgets.scrollContainer(pending.id)) |scroll_widget| {
                    try scroll_widget.renderScrollbars(window.frame.scene);
                }
            }
        }
    }
}

/// Render all pending canvas elements
fn renderCanvasElements(window: *Window, builder: *const Builder) void {
    for (builder.pending_canvas.items) |pending| {
        const bounds = window.layout.getBoundingBox(pending.layout_id) orelse continue;
        canvas_mod.executePendingCanvas(pending, window.frame.scene, scene_mod.Bounds.init(
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
        ), window.resources.text_system);
    }
}

/// Render all pending text inputs
fn renderTextInputs(window: *Window, builder: *const Builder) !void {
    for (builder.pending_inputs.items) |pending| {
        const bounds = window.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        const input_widget = window.widgets.textInput(pending.id) orelse continue;

        // If disabled and currently focused, blur it
        if (pending.style.disabled and input_widget.isFocused()) {
            input_widget.blur();
        }

        const inset = pending.style.padding + pending.style.border_width;
        // Compute inner_width from layout bounds when fill_width is true
        const inner_width = if (pending.style.fill_width)
            bounds.width - (inset * 2)
        else
            pending.inner_width;
        input_widget.bounds = .{
            .x = bounds.x + inset,
            .y = bounds.y + inset,
            .width = inner_width,
            .height = pending.inner_height,
        };
        input_widget.setPlaceholder(pending.style.placeholder);
        // Use muted color for disabled inputs
        input_widget.style.text_color = if (pending.style.disabled)
            render_bridge.colorToHsla(pending.style.placeholder_color)
        else
            render_bridge.colorToHsla(pending.style.text_color);
        input_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
        input_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
        input_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
        input_widget.secure = pending.style.secure;
        try input_widget.render(window.frame.scene, window.resources.text_system, window.scale_factor);
    }
}

/// Render all pending text areas
fn renderTextAreas(window: *Window, builder: *const Builder) !void {
    for (builder.pending_text_areas.items) |pending| {
        const bounds = window.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        const ta_widget = window.widgets.textArea(pending.id) orelse continue;

        const inset = pending.style.padding + pending.style.border_width;
        // Compute inner_width from layout bounds when fill_width is true
        const inner_width = if (pending.style.fill_width)
            bounds.width - (inset * 2)
        else
            pending.inner_width;

        ta_widget.bounds = .{
            .x = bounds.x + inset,
            .y = bounds.y + inset,
            .width = inner_width,
            .height = pending.inner_height,
        };
        ta_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
        ta_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
        ta_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
        ta_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
        ta_widget.setPlaceholder(pending.style.placeholder);
        try ta_widget.render(window.frame.scene, window.resources.text_system, window.scale_factor);
    }
}

/// Render all pending code editors
fn renderCodeEditors(window: *Window, builder: *const Builder) !void {
    for (builder.pending_code_editors.items) |pending| {
        const bounds = window.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        const ce_widget = window.widgets.codeEditor(pending.id) orelse continue;

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
        try ce_widget.render(window.frame.scene, window.resources.text_system, window.scale_factor);
    }
}

/// Update IME cursor position for focused text widget.
///
/// PR 7b.1b — needs a clean separation between the framework `Window`
/// (where `widgets.*` lives) and the OS-level `PlatformWindow` (where
/// `setImeCursorRect` lives). Pre-rename, the original `gooey` param
/// and the local platform handle were named `gooey` and `window`
/// respectively; after the framework wrapper rename to `Window`, the
/// platform handle local moves to `platform_window` to avoid shadowing
/// the param.
fn updateImeCursorPosition(window: *Window) void {
    const platform_window = window.getPlatformWindow() orelse return;
    // PR 4: per-type forwarders (`getFocusedTextInput` etc.) moved off
    // `Window`; reach through `window.widgets.*` directly. Order matches
    // pre-PR-4 priority — text input first, then text area, then code
    // editor — because at most one of them is focused at a time and
    // the IME only needs one rect.
    if (window.widgets.getFocusedTextInput()) |input| {
        const rect = input.cursor_rect;
        platform_window.setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    } else if (window.widgets.getFocusedTextArea()) |ta| {
        const rect = ta.cursor_rect;
        platform_window.setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    } else if (window.widgets.getFocusedCodeEditor()) |ce| {
        const rect = ce.getCursorRect();
        platform_window.setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    }
}

/// Render debug overlays if enabled
fn renderDebugOverlays(window: *Window) !void {
    if (!window.debugger().isActive()) return;

    window.debugger().generateOverlays(
        window.hover.hovered_layout_id,
        window.hover.ancestors(),
        window.layout,
    );
    try window.debugger().renderOverlays(window.frame.scene);

    // Render inspector panel (Phase 2)
    if (window.debugger().showInspector()) {
        try window.debugger().renderInspectorPanel(
            window.frame.scene,
            window.resources.text_system,
            window.width,
            window.height,
            window.scale_factor,
        );
    }

    // Render profiler panel
    if (window.debugger().showProfiler()) {
        try window.debugger().renderProfilerPanel(
            window.frame.scene,
            window.resources.text_system,
            window.width,
            window.scale_factor,
        );
    }
}
