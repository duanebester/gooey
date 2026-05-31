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
// `Frame` is referenced by name in the end-of-frame `mem.swap` below.
const frame_mod = @import("../context/frame.zig");
const Frame = frame_mod.Frame;

const Window = window_mod.Window;
const Cx = cx_mod.Cx;
const Builder = ui_mod.Builder;

// Widget-state lookups (scrollbars and the post-layout text-widget render
// passes) go through `window.element_states`, keyed by `LayoutId.id` hash.
// Read-only `get` is correct: the slot was seeded earlier this frame by the
// matching builder call, so a `null` return means that seed failed (capacity
// exhaustion or OOM), in which case skipping this frame's render is the right
// fail-safe.
const scroll_container_mod = @import("../widgets/scroll_container.zig");
const ScrollContainer = scroll_container_mod.ScrollContainer;

const text_input_state_mod = @import("../widgets/text_input_state.zig");
const TextInputState = text_input_state_mod.TextInputState;
const text_area_state_mod = @import("../widgets/text_area_state.zig");
const TextAreaState = text_area_state_mod.TextAreaState;
const code_editor_state_mod = @import("../widgets/code_editor_state.zig");
const CodeEditorState = code_editor_state_mod.CodeEditorState;

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
    // The app-scoped per-tick begin/end pair is driven from this layer, not
    // through `Window`, so it runs exactly once per tick even when N windows
    // share one `App` (running it per-window would discard each window's
    // earlier-this-tick entity observations).
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

    // Sync builder's cached `scene` / `dispatch` pointers to the current
    // `next_frame.*` build target. Builder caches the pointers it was handed
    // at init time, but the previous tick's end-of-frame `mem.swap` rotated
    // those allocations into `rendered_frame`. Refreshing here keeps the
    // cached pointers tracking the live build target across every swap.
    builder.scene = window.next_frame.scene;
    builder.dispatch = window.next_frame.dispatch;

    window.beginFrame();

    // App-scoped per-tick hook: drains async image-load results into the
    // shared atlas and clears stale entity observations from the previous
    // tick. Must run after `window.beginFrame()` (so the atlas frame counter
    // has advanced) and before `render_fn(cx)` (so this tick's observations
    // survive the clear). Call once per tick, never once per window.
    app.beginFrame();

    // Clear blur handlers from previous frame
    window.clearBlurHandlers();

    // Reset builder state
    builder.id_counter = 0;
    builder.pending_inputs.clearRetainingCapacity();
    builder.pending_text_areas.clearRetainingCapacity();
    builder.pending_code_editors.clearRetainingCapacity();
    builder.pending_text_widgets.clearRetainingCapacity();
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
    // PR 11b.3a — the unified control queue holds one record per
    // text widget, so it cannot exceed the three pools combined.
    std.debug.assert(builder.pending_text_widgets.items.len <= Builder.MAX_PENDING_TEXT_WIDGETS);
    std.debug.assert(builder.pending_scrolls.items.len <= Builder.MAX_PENDING_SCROLLS);
    std.debug.assert(builder.pending_canvas.items.len <= Builder.MAX_PENDING_CANVAS);

    // End frame and get render commands
    const commands = try window.endFrame();

    // Symmetric app-scoped per-tick finalisation (currently a no-op; reserved
    // for future batching). Must run once per tick after every window's
    // `endFrame` has completed its per-window finalisation.
    app.endFrame();

    // Assert render command count is within limits
    std.debug.assert(commands.len <= MAX_RENDER_COMMANDS);

    // Sync bounds and z_index from layout into the just-built
    // `next_frame.dispatch` (pre-swap). The end-of-frame swap rotates this
    // synced tree into `rendered_frame.dispatch`, which is what input
    // handlers hit-test against between frames (see `Window.updateHover` and
    // the dispatch call sites in `runtime/input.zig`). The double buffer is
    // why no post-loop hover re-run is needed: input never hit-tests against
    // the in-progress build target.
    window.debugger().beginDispatchSync(window.io);

    for (window.next_frame.dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = window.layout.getBoundingBox(layout_id);
            node.z_index = window.layout.getZIndex(layout_id);
        }
    }

    // Register hit regions
    builder.registerPendingScrollRegions();

    window.debugger().endDispatchSync(window.io);

    // Clear the build-target scene before the command-replay pass populates it.
    window.next_frame.scene.clear();

    // Reset SVG atlas per-frame rasterization budget so that expensive
    // software rasterizations are spread across multiple frames instead
    // of stalling a single frame when many uncached icons scroll into view.
    window.resources.svg_atlas.resetFrameBudget();

    // Start render timing for profiler
    window.debugger().beginRender(window.io);

    // Render all commands inline (SVGs, images, scrollbars at their
    // `scissor_end`) so z-ordering is correct. Canvas and scroll are
    // deliberately coupled to this command-replay loop rather than the
    // post-layout text-widget queue: canvas must reserve its draw-order block
    // (and capture the live clip) at the moment `cmd.id` is replayed, and
    // scrollbars must paint at the matching `scissor_end` to land after
    // scroll content but before siblings.
    try renderCommands(window, @constCast(builder), commands);

    // Register blur handlers from pending items
    registerBlurHandlers(window, builder);

    // Render the text widgets (inputs / text areas / code editors) in a
    // single tree-ordered pass over the unified control queue (PR 11b.3a).
    try renderTextWidgets(window, builder);

    // Render canvas elements (custom vector graphics)
    renderCanvasElements(window, builder);

    // Update IME cursor position for focused text input
    updateImeCursorPosition(window, builder);

    // End render timing for profiler
    window.debugger().endRender(window.io);

    // Render debug overlays (if enabled via Cmd+Shift+I)
    try renderDebugOverlays(window);

    window.next_frame.scene.finish();

    // If SVG rasterizations were deferred due to per-frame budget, request
    // another render so the remaining icons progressively appear.
    if (window.resources.svg_atlas.hasDeferredWork()) {
        window.requestRender();
    }

    // Finalize frame timing for profiler
    window.finalizeFrame();

    // =========================================================================
    // Frame-boundary `mem.swap` for the double buffer.
    // =========================================================================
    //
    // The build pass has finished writing the just-built tree (bounds synced,
    // scene primitives committed) into `window.next_frame.*`. Swap it into
    // `window.rendered_frame` so:
    //   1. The GPU side picks up the just-built scene on the next render
    //      (the platform scene pointer is updated below to follow it).
    //   2. Input events between ticks hit-test against `rendered_frame.dispatch`
    //      — the tree the user is currently seeing.
    //
    // The pre-swap `next_frame` (previous tick's displayed tree) becomes the
    // recycled buffer; clear its scene and reset its dispatch so the next
    // tick builds from an empty state. Both halves stay `owned = true` — this
    // is a physical struct exchange between two owning slots, and
    // `Window.deinit` frees both pointee pairs regardless of swap count.
    std.mem.swap(Frame, &window.rendered_frame, &window.next_frame);
    window.next_frame.scene.clear();
    window.next_frame.dispatch.reset();

    // Point the platform window's scene at the post-swap `rendered_frame.scene`
    // (the just-built tree, now the GPU-side display buffer); the physical
    // Scene allocation rotates every tick, so the platform pointer must follow.
    // Web reads `rendered_frame.scene` directly and returns null here, so the
    // branch short-circuits.
    if (window.getPlatformWindow()) |pw| {
        pw.setScene(window.rendered_frame.scene);
    }
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
                pending.base_order = window.next_frame.scene.reserveCanvasOrders(256); // Reserve block of 256 orders
                pending.clip_bounds = window.next_frame.scene.currentClip();
                break;
            }
        }

        try render_cmd.renderCommand(window, cmd);

        // When a scissor region ends, check if it's a scroll container and render its scrollbars
        // This ensures scrollbars appear after scroll content but before sibling elements
        if (cmd.command_type == .scissor_end) {
            if (builder.findPendingScrollByLayoutId(cmd.id)) |pending| {
                if (window.element_states.get(ScrollContainer, @as(u64, pending.layout_id.id))) |scroll_widget| {
                    try scroll_widget.renderScrollbars(window.next_frame.scene);
                }
            }
        }
    }
}

/// Render all pending canvas elements
fn renderCanvasElements(window: *Window, builder: *const Builder) void {
    for (builder.pending_canvas.items) |pending| {
        const bounds = window.layout.getBoundingBox(pending.layout_id) orelse continue;
        canvas_mod.executePendingCanvas(pending, window.next_frame.scene, scene_mod.Bounds.init(
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
        ), window.resources.text_system);
    }
}

/// Render every pending text widget in one tree-ordered pass over the unified
/// control queue. Each `{ kind, index }` record selects the matching typed
/// pool; a comptime `switch (kind)` picks the per-kind render helper (no
/// runtime trait objects). Tree-order replay is correct when widgets of
/// different kinds overlap.
fn renderTextWidgets(window: *Window, builder: *const Builder) !void {
    for (builder.pending_text_widgets.items) |entry| {
        switch (entry.kind) {
            .input => {
                std.debug.assert(entry.index < builder.pending_inputs.items.len);
                try renderTextInput(window, &builder.pending_inputs.items[entry.index]);
            },
            .text_area => {
                std.debug.assert(entry.index < builder.pending_text_areas.items.len);
                try renderTextArea(window, &builder.pending_text_areas.items[entry.index]);
            },
            .code_editor => {
                std.debug.assert(entry.index < builder.pending_code_editors.items.len);
                try renderCodeEditor(window, &builder.pending_code_editors.items[entry.index]);
            },
        }
    }
}

/// Render a single pending text input. A missing bounds or pool slot is
/// a skip (the slot is seeded at builder time; absence means the seed
/// itself failed this frame — capacity or OOM).
fn renderTextInput(window: *Window, pending: *const Builder.PendingInput) !void {
    const bounds = window.layout.getBoundingBox(pending.layout_id.id) orelse return;
    const input_widget = window.element_states.get(TextInputState, @as(u64, pending.layout_id.id)) orelse return;

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
    try input_widget.render(window.next_frame.scene, window.resources.text_system, window.scale_factor);
}

/// Render a single pending text area.
fn renderTextArea(window: *Window, pending: *const Builder.PendingTextArea) !void {
    const bounds = window.layout.getBoundingBox(pending.layout_id.id) orelse return;
    const ta_widget = window.element_states.get(TextAreaState, @as(u64, pending.layout_id.id)) orelse return;

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
    try ta_widget.render(window.next_frame.scene, window.resources.text_system, window.scale_factor);
}

/// Render a single pending code editor.
fn renderCodeEditor(window: *Window, pending: *const Builder.PendingCodeEditor) !void {
    const bounds = window.layout.getBoundingBox(pending.layout_id.id) orelse return;
    const ce_widget = window.element_states.get(CodeEditorState, @as(u64, pending.layout_id.id)) orelse return;

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
    try ce_widget.render(window.next_frame.scene, window.resources.text_system, window.scale_factor);
}

/// Update IME cursor position for the focused text widget. Priority is
/// input > area > editor; at most one is focused at a time and the IME only
/// needs one rect.
fn updateImeCursorPosition(window: *Window, builder: *const Builder) void {
    const platform_window = window.getPlatformWindow() orelse return;
    const input_mod = @import("input.zig");
    if (input_mod.focusedTextInput(window, builder)) |input| {
        const rect = input.cursor_rect;
        platform_window.setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    } else if (input_mod.focusedTextArea(window, builder)) |ta| {
        const rect = ta.cursor_rect;
        platform_window.setImeCursorRect(rect.x, rect.y, rect.width, rect.height);
    } else if (input_mod.focusedCodeEditor(window, builder)) |ce| {
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
    try window.debugger().renderOverlays(window.next_frame.scene);

    // Render inspector panel (Phase 2)
    if (window.debugger().showInspector()) {
        try window.debugger().renderInspectorPanel(
            window.next_frame.scene,
            window.resources.text_system,
            window.width,
            window.height,
            window.scale_factor,
        );
    }

    // Render profiler panel
    if (window.debugger().showProfiler()) {
        try window.debugger().renderProfilerPanel(
            window.next_frame.scene,
            window.resources.text_system,
            window.width,
            window.scale_factor,
        );
    }
}
