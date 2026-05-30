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
// PR 7c.3c — the end-of-frame `mem.swap` below references the
// `Frame` type by name; hoisted to the imports block to keep
// the swap call site readable.
const frame_mod = @import("../context/frame.zig");
const Frame = frame_mod.Frame;

const Window = window_mod.Window;
const Cx = cx_mod.Cx;
const Builder = ui_mod.Builder;

// PR 8.4 — `ScrollContainer` lookup for in-line scrollbar rendering
// goes through `window.element_states` post-PR-8.4. Same import
// shape as `runtime/input.zig`.
const scroll_container_mod = @import("../widgets/scroll_container.zig");
const ScrollContainer = scroll_container_mod.ScrollContainer;

// PR 8.4b — `TextInputState` / `TextAreaState` / `CodeEditorState`
// lookups for the post-layout render passes go through
// `window.element_states` post-PR-8.4b. Read-only `get` is the right
// shape because `Builder.renderInput` / `renderTextArea` /
// `renderCodeEditor` already seeded the slot earlier this frame; a
// `null` return here means the seed itself failed (capacity
// exhaustion or OOM at builder time), in which case skipping the
// post-layout render for this frame is the right fail-safe.
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

    // PR 7c.3d — the start-of-frame `next_frame.dispatch.reset()`
    // call that lived here pre-7c.3d was retired alongside
    // `refreshHover` (win (4) of the 7c.3c plan, cashed in this
    // slice). The end-of-frame `mem.swap` below leaves
    // `next_frame.dispatch` reset every tick after the first via
    // the post-swap recycle step; tick 0 starts with a fresh tree
    // from `Frame.initOwned`'s `DispatchTree.init`. Both paths give
    // us an empty dispatch tree at this point in the function, so
    // the explicit reset was redundant on every tick.

    // PR 7c.3c — sync builder's cached `scene` / `dispatch`
    // pointers to the post-swap `next_frame.*` pair.
    //
    // Builder caches the two pointers it was handed at
    // `Builder.init` time; the previous tick's `mem.swap` rotated
    // those allocations into `rendered_frame`, leaving builder's
    // cached pointers identifying the GPU-side display buffer
    // instead of the live build target. Refreshing both fields
    // here — alongside the per-tick `id_counter` / pending-queue
    // resets below — keeps the cached pointers tracking
    // `next_frame.*` across every swap.
    builder.scene = window.next_frame.scene;
    builder.dispatch = window.next_frame.dispatch;

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

    // PR 7c.3c — the bounds sync runs against the just-built
    // `next_frame.dispatch` (pre-swap). The end-of-frame swap below
    // rotates the synced tree into `rendered_frame.dispatch`, where
    // input handlers between frames will hit-test against it via
    // `window.updateHover` / the dispatch-tree call sites in
    // `runtime/input.zig`.
    //
    // PR 7c.3d — by the time the next mouse move arrives, the
    // end-of-frame `mem.swap` will have rotated this just-synced
    // tree into `rendered_frame.dispatch`, which is exactly what
    // `Window.updateHover` reads. Pre-7c.3d we ran `refreshHover`
    // immediately after this loop to re-run hit testing against
    // the (single-buffer) tree because input handlers earlier in
    // the same tick had hit-tested against stale bounds; the
    // double buffer makes that re-run unnecessary because input
    // never hit-tests against the in-progress build target.
    for (window.next_frame.dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = window.layout.getBoundingBox(layout_id);
            node.z_index = window.layout.getZIndex(layout_id);
        }
    }

    // Register hit regions
    builder.registerPendingScrollRegions();

    window.debugger().endDispatchSync(window.io);

    // PR 7c.3c — clear the build-target scene before the
    // command-replay pass below populates it. `Window.beginFrame`
    // already cleared `next_frame.scene` early in this function;
    // this second clear is the historical pre-7c.3a redundant
    // clear that 7c.3c preserves verbatim (the slice's job is
    // the swap and rename, not pruning the redundant clears).
    window.next_frame.scene.clear();

    // Reset SVG atlas per-frame rasterization budget so that expensive
    // software rasterizations are spread across multiple frames instead
    // of stalling a single frame when many uncached icons scroll into view.
    window.resources.svg_atlas.resetFrameBudget();

    // Start render timing for profiler
    window.debugger().beginRender(window.io);

    // Render all commands (includes SVGs and images inline for correct z-ordering)
    // Scrollbars are rendered inline when their scissor_end is encountered
    // Canvas draw orders are reserved during this pass for correct z-ordering
    //
    // PR 11b.3b — canvas + scroll are *deliberately* not folded into the
    // unified text-widget queue (PR 11b.3a). That queue is a pure
    // post-layout pass: walk records, look up bounds, paint. Canvas and
    // scroll are not post-layout — they are coupled to *this* command-replay
    // loop for z-ordering: `pending_canvas` must reserve its draw-order block
    // (and capture the live clip) at the exact moment `cmd.id` is replayed,
    // and `pending_scrolls` must paint its scrollbars at the matching
    // `scissor_end` so they land after scroll content but before siblings.
    // Moving either into a post-layout queue would reintroduce the
    // z-ordering they exist to get right — strictly more complex than the
    // inline coupling here. They stay as documented inline exceptions.
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
    // PR 7c.3c — frame-boundary `mem.swap` for the double buffer.
    // =========================================================================
    //
    // At this point the build pass has finished writing into
    // `window.next_frame.{scene,dispatch}` (just-built tree, with
    // bounds synced and scene primitives committed). Swap it into
    // `window.rendered_frame` so:
    //
    //   1. The GPU side picks up the just-built scene on the next
    //      `renderScene` (we update the platform window's scene
    //      pointer below to point at `rendered_frame.scene`,
    //      which post-swap is the same heap allocation we just
    //      finished writing into).
    //   2. Input events arriving between this tick and the next
    //      hit-test against `rendered_frame.dispatch` — the
    //      tree the user is currently *seeing*. See
    //      `Window.updateHover` and the dispatch-tree call sites
    //      in `runtime/input.zig` for the read side.
    //
    // The pre-swap `next_frame` (the previous tick's already-
    // displayed tree) becomes the recycled buffer post-swap; we
    // clear its scene + reset its dispatch so the next tick's
    // build into `next_frame.*` starts from an empty state. This
    // is the "recycle the older buffer" half of the swap pattern
    // sketched in `architectural-cleanup-plan.md` §11.
    //
    // Both halves of the swap retain `owned = true` — `mem.swap`
    // is a physical struct exchange between two owning slots, not
    // a hand-off through `Frame.borrowed`. `Window.deinit`
    // continues to free both pointee pairs regardless of how many
    // swaps have happened.
    std.mem.swap(Frame, &window.rendered_frame, &window.next_frame);
    window.next_frame.scene.clear();
    window.next_frame.dispatch.reset();

    // PR 7c.3c — update the platform window's scene pointer to
    // track the post-swap `rendered_frame.scene` (the just-built
    // tree, now the GPU-side display buffer). Pre-7c.3c the
    // platform pointer was set once at `WindowContext.setupWindow`
    // because there was only one Scene slot per window; with the
    // double buffer, the physical Scene allocation rotated into
    // the display side every tick, so the platform pointer must
    // follow the rotation. Web's renderer reads
    // `window.rendered_frame.scene` directly each tick and doesn't
    // need this update; the `getPlatformWindow` accessor returns
    // null on the web target, so the `if let` below short-circuits.
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
                // PR 8.4 — read-only `get` against the keyed pool. The
                // slot was seeded earlier this frame by `Builder.scroll`,
                // so a missing entry here means capacity exhaustion at
                // scroll-time — in which case skipping the scrollbar
                // for this frame is the right fail-safe.
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

/// Render every pending text widget in one tree-ordered pass.
///
/// PR 11b.3a — the three structurally-identical post-layout passes
/// (`renderTextInputs` / `renderTextAreas` / `renderCodeEditors`)
/// collapse into this single walk over `pending_text_widgets`, the
/// unified control queue. Each `{ kind, index }` record selects the
/// matching typed data-plane pool; a comptime `switch (kind)` picks the
/// per-kind render helper — no runtime trait objects, no by-value
/// per-element state (CLAUDE.md §6, §14). Control flow (the switch)
/// stays in this parent; the meaty per-kind work lives in the leaf
/// helpers (CLAUDE.md §5). Tree-order replay is strictly more correct
/// than the old grouped order when widgets of different kinds overlap.
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

/// Update IME cursor position for focused text widget.
///
/// PR 7b.1b — needs a clean separation between the framework `Window`
/// (where `widgets.*` lives) and the OS-level `PlatformWindow` (where
/// `setImeCursorRect` lives). Pre-rename, the original `gooey` param
/// and the local platform handle were named `gooey` and `window`
/// respectively; after the framework wrapper rename to `Window`, the
/// platform handle local moves to `platform_window` to avoid shadowing
/// the param.
fn updateImeCursorPosition(window: *Window, builder: *const Builder) void {
    const platform_window = window.getPlatformWindow() orelse return;
    // PR 8.4b — the per-type focused-widget walk (`getFocusedText*`)
    // retired alongside the StringHashMap maps. The replacement
    // walks the matching `pending_*` lists, hits the pool by
    // layout-id hash, and returns the first `isFocused()` match —
    // same priority order as pre-PR-8.4b (input > area > editor)
    // because at most one of them is focused at a time and the IME
    // only needs one rect.
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
