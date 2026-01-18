//! Input Handling
//!
//! Routes input events (keyboard, mouse, scroll) to the appropriate handlers,
//! widgets, and dispatch tree nodes.
//!
//! This module is structured as focused sub-functions per CLAUDE.md guidelines:
//! - handleScrollEvent: scroll wheel input
//! - handleMouseMoveEvent: hover state and drag updates
//! - handleMouseDownEvent: click dispatch, scrollbar interaction
//! - handleMouseUpEvent: end drag operations
//! - handleKeyboardEvent: key routing to focused widgets

const std = @import("std");
const geometry = @import("../core/geometry.zig");

// Core imports
const gooey_mod = @import("../context/gooey.zig");
const drag_mod = @import("../context/drag.zig");
const input_mod = @import("../input/events.zig");
const dispatch_mod = @import("../context/dispatch.zig");
const debugger_mod = @import("../debug/debugger.zig");
const cx_mod = @import("../cx.zig");
const ui_mod = @import("../ui/mod.zig");

const Gooey = gooey_mod.Gooey;
const Cx = cx_mod.Cx;
const InputEvent = input_mod.InputEvent;
const DispatchNodeId = dispatch_mod.DispatchNodeId;
const Builder = ui_mod.Builder;

// =============================================================================
// Main Entry Point
// =============================================================================

/// Handle input with Cx context
/// Routes events to appropriate handlers based on event type
pub fn handleInputCx(
    cx: *Cx,
    on_event: ?*const fn (*Cx, InputEvent) bool,
    event: InputEvent,
) bool {
    // Cache pointers (avoids repeated method calls)
    const gooey = cx.gooey();
    const builder = cx.builder();

    // Route by event type
    switch (event) {
        .scroll => |scroll_ev| {
            if (handleScrollEvent(cx, gooey, builder, scroll_ev)) return true;
        },
        .mouse_moved => |move_ev| {
            if (handleMouseMoveEvent(cx, gooey, move_ev.position, false)) return true;
        },
        .mouse_dragged => |drag_ev| {
            if (handleMouseDragEvent(cx, gooey, builder, drag_ev.position)) return true;
            if (handleMouseMoveEvent(cx, gooey, drag_ev.position, true)) return true;
        },
        .mouse_exited => {
            gooey.clearHover();
            cx.notify();
        },
        .mouse_down => |down_ev| {
            if (handleMouseDownEvent(cx, gooey, builder, down_ev)) return true;
        },
        .mouse_up => {
            if (handleMouseUpEvent(cx, gooey, builder)) return true;
        },
        .key_down => |k| {
            if (handleKeyDownEvent(cx, gooey, k)) return true;
        },
        .text_input => |t| {
            if (handleTextInputEvent(cx, gooey, t.text)) return true;
        },
        .composition => |c| {
            if (handleCompositionEvent(cx, gooey, c.text)) return true;
        },
        else => {},
    }

    // Let user's event handler run
    if (on_event) |handler| {
        if (handler(cx, event)) {
            return true;
        }
    }

    return false;
}

// =============================================================================
// Scroll Handling
// =============================================================================

/// Handle scroll wheel events
/// Returns true if event was consumed
fn handleScrollEvent(
    cx: *Cx,
    gooey: *Gooey,
    builder: *Builder,
    scroll_ev: input_mod.ScrollEvent,
) bool {
    const x: f32 = @floatCast(scroll_ev.position.x);
    const y: f32 = @floatCast(scroll_ev.position.y);

    // Check TextAreas for scroll
    for (builder.pending_text_areas.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        if (!pointInBounds(x, y, bounds)) continue;

        const ta = gooey.textArea(pending.id) orelse continue;
        if (ta.line_height > 0 and ta.viewport_height > 0) {
            const delta_y: f32 = @floatCast(scroll_ev.delta.y);
            const content_height: f32 = @as(f32, @floatFromInt(ta.lineCount())) * ta.line_height;
            const max_scroll: f32 = @max(0, content_height - ta.viewport_height);
            const new_offset = ta.scroll_offset_y - delta_y * 20;
            ta.scroll_offset_y = std.math.clamp(new_offset, 0, max_scroll);
            cx.notify();
            return true;
        }
    }

    // Check CodeEditors for scroll
    for (builder.pending_code_editors.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        if (!pointInBounds(x, y, bounds)) continue;

        const ce = gooey.codeEditor(pending.id) orelse continue;
        const ta = &ce.text_area;
        if (ta.line_height > 0 and ta.viewport_height > 0) {
            const delta_y: f32 = @floatCast(scroll_ev.delta.y);
            const content_height: f32 = @as(f32, @floatFromInt(ta.lineCount())) * ta.line_height;
            const max_scroll: f32 = @max(0, content_height - ta.viewport_height);
            const new_offset = ta.scroll_offset_y - delta_y * 20;
            ta.scroll_offset_y = std.math.clamp(new_offset, 0, max_scroll);
            cx.notify();
            return true;
        }
    }

    // Check scroll containers
    for (builder.pending_scrolls.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        if (!pointInBounds(x, y, bounds)) continue;

        const sc = gooey.widgets.getScrollContainer(pending.id) orelse continue;
        if (sc.handleScroll(scroll_ev.delta.x, scroll_ev.delta.y)) {
            cx.notify();
            return true;
        }
    }

    return false;
}

// =============================================================================
// Mouse Move/Drag Handling
// =============================================================================

/// Handle mouse drag events for active scroll containers
/// Uses O(1) lookup via active_scroll_drag_id
fn handleMouseDragEvent(
    cx: *Cx,
    gooey: *Gooey,
    builder: *Builder,
    position: geometry.Point(f64),
) bool {
    const x: f32 = @floatCast(position.x);
    const y: f32 = @floatCast(position.y);

    // O(1) check: use tracked active drag ID instead of scanning all scrolls
    if (builder.getActiveScrollDrag()) |drag_id| {
        if (gooey.widgets.getScrollContainer(drag_id)) |sc| {
            sc.updateDrag(x, y);
            cx.notify();
            return true;
        }
    }

    // Fallback: scan for any dragging scroll (handles edge case if tracking was missed)
    for (builder.pending_scrolls.items) |pending| {
        if (gooey.widgets.getScrollContainer(pending.id)) |sc| {
            if (sc.state.dragging_vertical or sc.state.dragging_horizontal) {
                // Track this for future O(1) lookups
                builder.setActiveScrollDrag(pending.id);
                sc.updateDrag(x, y);
                cx.notify();
                return true;
            }
        }
    }

    return false;
}

/// Handle mouse move events for hover state and drag activation
fn handleMouseMoveEvent(
    cx: *Cx,
    gooey: *Gooey,
    position: geometry.Point(f64),
    is_drag: bool,
) bool {
    _ = is_drag; // Reserved for future use (e.g., drag selection)

    const x: f32 = @floatCast(position.x);
    const y: f32 = @floatCast(position.y);

    // Check if pending drag should become active
    if (gooey.pending_drag) |pending| {
        const dx = x - pending.start_position.x;
        const dy = y - pending.start_position.y;
        const distance = @sqrt(dx * dx + dy * dy);

        if (distance > drag_mod.DRAG_THRESHOLD) {
            // Promote to active drag
            gooey.active_drag = .{
                .value_ptr = pending.value_ptr,
                .type_id = pending.type_id,
                .cursor_offset = .{ .x = dx, .y = dy },
                .cursor_position = .{ .x = x, .y = y },
                .start_position = pending.start_position,
                .source_layout_id = pending.source_layout_id,
            };
            gooey.pending_drag = null;
            cx.notify();
            return true;
        }
    }

    // Update active drag position and find drop target
    if (gooey.active_drag) |*drag| {
        drag.cursor_position = .{ .x = x, .y = y };

        // Find drop target under cursor
        updateDragOverTarget(gooey, x, y, drag.type_id);

        cx.notify();
        return true;
    }

    // Normal hover update
    if (gooey.updateHover(x, y)) {
        cx.notify();
        return true;
    }

    return false;
}

/// Find and track the drop target under cursor during drag
fn updateDragOverTarget(gooey: *Gooey, x: f32, y: f32, drag_type_id: drag_mod.DragTypeId) void {
    gooey.drag_over_target = null;

    if (gooey.dispatch.hitTest(x, y)) |hit| {
        var path_buf: [64]DispatchNodeId = undefined;
        const path = gooey.dispatch.dispatchPath(hit, &path_buf);
        if (path.len > 0) {
            // Walk up path to find compatible drop target
            if (gooey.dispatch.findDropTarget(path, drag_type_id)) |target| {
                if (gooey.dispatch.getNodeConst(target.node_id)) |node| {
                    gooey.drag_over_target = node.layout_id;
                }
            }
        }
    }
}

// =============================================================================
// Mouse Down Handling
// =============================================================================

/// Handle mouse down events
/// Priority order: scrollbar clicks > text areas > dispatch tree > debugger
fn handleMouseDownEvent(
    cx: *Cx,
    gooey: *Gooey,
    builder: *Builder,
    down_ev: input_mod.MouseEvent,
) bool {
    const x: f32 = @floatCast(down_ev.position.x);
    const y: f32 = @floatCast(down_ev.position.y);

    // 1. Check scroll containers for scrollbar clicks (highest priority)
    if (handleScrollbarClick(cx, gooey, builder, x, y)) return true;

    // 2. Check if click is in a TextArea
    if (handleTextAreaClick(cx, gooey, builder, x, y)) return true;

    // 3. Check if click is in a CodeEditor
    if (handleCodeEditorClick(cx, gooey, builder, down_ev)) return true;

    // 4. Compute hit target once for both click-outside and click dispatch
    const hit_target = gooey.dispatch.hitTest(x, y);

    // 4. Check for drag source — start pending drag
    if (hit_target) |target| {
        _ = handleDragSourceClick(gooey, target, x, y);
        // Don't return true yet — still dispatch click-outside etc.
    }

    // 5. Dispatch click-outside events (for closing dropdowns, modals, etc.)
    if (gooey.dispatch.dispatchClickOutsideWithTarget(x, y, hit_target, gooey)) {
        cx.notify();
    }

    // 6. Dispatch click to hit target
    if (hit_target) |target| {
        if (handleDispatchClick(cx, gooey, target)) return true;
    }

    // 7. Debugger: handle click to select element for inspection
    if (gooey.debugger.isActive()) {
        gooey.debugger.handleClick(gooey.hovered_layout_id);
        cx.notify();
    }

    return false;
}

/// Check if click hit a drag source, start pending drag if so
/// Walks up the dispatch path to find drag source on parent elements
fn handleDragSourceClick(gooey: *Gooey, target: DispatchNodeId, x: f32, y: f32) bool {
    // Don't start new drag if one is active
    if (gooey.active_drag != null or gooey.pending_drag != null) return false;

    // Build dispatch path from hit target to root
    var path_buf: [64]DispatchNodeId = undefined;
    const path = gooey.dispatch.dispatchPath(target, &path_buf);

    // Walk up path to find drag source (closest to hit point first)
    for (path) |node_id| {
        if (gooey.dispatch.getNodeConst(node_id)) |node| {
            if (node.drag_source) |source| {
                gooey.pending_drag = .{
                    .value_ptr = source.value_ptr,
                    .type_id = source.type_id,
                    .start_position = .{ .x = x, .y = y },
                    .source_layout_id = node.layout_id,
                };
                return true;
            }
        }
    }
    return false;
}

/// Handle scrollbar thumb/track clicks
fn handleScrollbarClick(
    cx: *Cx,
    gooey: *Gooey,
    builder: *Builder,
    x: f32,
    y: f32,
) bool {
    for (builder.pending_scrolls.items) |pending| {
        const sc = gooey.widgets.getScrollContainer(pending.id) orelse continue;

        // Check for thumb drag
        if (sc.hitTestThumb(x, y)) |hit| {
            switch (hit) {
                .vertical => sc.startDrag(.vertical, x, y),
                .horizontal => sc.startDrag(.horizontal, x, y),
            }
            // Track active drag for O(1) lookup
            builder.setActiveScrollDrag(pending.id);
            cx.notify();
            return true;
        }

        // Check for track click (jump to position)
        if (sc.handleTrackClick(x, y)) {
            cx.notify();
            return true;
        }
    }
    return false;
}

/// Handle clicks in text area bounds
fn handleTextAreaClick(
    cx: *Cx,
    gooey: *Gooey,
    builder: *Builder,
    x: f32,
    y: f32,
) bool {
    for (builder.pending_text_areas.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        if (pointInBounds(x, y, bounds)) {
            gooey.focusTextArea(pending.id);
            cx.notify();
            return true;
        }
    }
    return false;
}

fn handleCodeEditorClick(
    cx: *Cx,
    gooey: *Gooey,
    builder: *Builder,
    down_ev: input_mod.MouseEvent,
) bool {
    std.debug.assert(builder.pending_code_editors.items.len <= Builder.MAX_PENDING_CODE_EDITORS);

    const x: f32 = @floatCast(down_ev.position.x);
    const y: f32 = @floatCast(down_ev.position.y);
    std.debug.assert(std.math.isFinite(x) and std.math.isFinite(y));

    for (builder.pending_code_editors.items) |pending| {
        const bounds = gooey.layout.getBoundingBox(pending.layout_id.id) orelse continue;
        if (pointInBounds(x, y, bounds)) {
            // Get the code editor widget and pass the event to it
            if (gooey.codeEditor(pending.id)) |ce| {
                // Pass mouse event to widget for gutter click handling
                const input_event = InputEvent{ .mouse_down = down_ev };
                _ = ce.handleEvent(input_event);
            }
            gooey.focusCodeEditor(pending.id);
            cx.notify();
            return true;
        }
    }
    return false;
}

/// Handle click dispatch through dispatch tree
fn handleDispatchClick(cx: *Cx, gooey: *Gooey, target: DispatchNodeId) bool {
    // Handle focus
    if (gooey.dispatch.getNodeConst(target)) |node| {
        if (node.focus_id) |focus_id| {
            if (gooey.focus.getHandleById(focus_id)) |handle| {
                gooey.focusElement(handle.string_id);
            }
        }
    }

    // Dispatch click event
    if (gooey.dispatch.dispatchClick(target, gooey)) {
        cx.notify();
        return true;
    }

    return false;
}

// =============================================================================
// Mouse Up Handling
// =============================================================================

/// Handle mouse up events (end drag operations)
fn handleMouseUpEvent(
    cx: *Cx,
    gooey: *Gooey,
    builder: *Builder,
) bool {
    // Handle drop if drag is active
    if (gooey.active_drag) |drag| {
        defer {
            gooey.active_drag = null;
            gooey.pending_drag = null;
            gooey.drag_over_target = null;
        }

        const x = drag.cursor_position.x;
        const y = drag.cursor_position.y;

        if (gooey.dispatch.hitTest(x, y)) |hit| {
            var path_buf: [64]DispatchNodeId = undefined;
            const path = gooey.dispatch.dispatchPath(hit, &path_buf);
            if (path.len > 0) {
                if (gooey.dispatch.findDropTarget(path, drag.type_id)) |target| {
                    // Execute drop handler
                    if (target.handler) |handler| {
                        handler.invoke(gooey);
                    }
                    cx.notify();
                    return true;
                }
            }
        }

        // Drag ended without drop
        cx.notify();
        return true;
    }

    // Cancel pending drag on mouse up (click without drag)
    if (gooey.pending_drag != null) {
        gooey.pending_drag = null;
    }

    // O(1) check: use tracked active drag ID for scroll
    if (builder.getActiveScrollDrag()) |drag_id| {
        if (gooey.widgets.getScrollContainer(drag_id)) |sc| {
            if (sc.state.dragging_vertical or sc.state.dragging_horizontal) {
                sc.endDrag();
                builder.setActiveScrollDrag(null);
                cx.notify();
                return true;
            }
        }
        // Clear stale tracking
        builder.setActiveScrollDrag(null);
    }

    return false;
}

// =============================================================================
// Keyboard Handling
// =============================================================================

/// Handle key down events
fn handleKeyDownEvent(cx: *Cx, gooey: *Gooey, k: input_mod.KeyEvent) bool {
    // Cancel drag on Escape
    if (k.key == .escape and (gooey.active_drag != null or gooey.pending_drag != null)) {
        gooey.cancelDrag();
        cx.notify();
        return true;
    }

    // Debugger toggle: Cmd+Shift+I (macOS) or Ctrl+Shift+I
    if (debugger_mod.Debugger.isToggleShortcut(k.key, k.modifiers)) {
        gooey.debugger.toggle();
        cx.notify();
        return true;
    }

    // Tab navigation - but let CodeEditor handle Tab for indentation
    if (k.key == .tab) {
        // CodeEditor intercepts Tab for indentation (not focus navigation)
        if (gooey.getFocusedCodeEditor()) |ce| {
            if (!k.modifiers.shift and !k.modifiers.ctrl and !k.modifiers.alt) {
                _ = ce.handleKey(k.key, k.modifiers);
                syncCodeEditorBoundVariablesCx(cx);
                cx.notify();
                return true;
            }
        }
        // Default: use Tab for focus navigation
        if (k.modifiers.shift) {
            gooey.focusPrev();
        } else {
            gooey.focusNext();
        }
        return true;
    }

    // Try action dispatch through focus path
    if (handleFocusedKeyAction(cx, gooey, k)) return true;

    // Handle focused TextInput
    if (gooey.getFocusedTextInput()) |input| {
        if (isControlKey(k.key, k.modifiers)) {
            input.handleKey(k) catch {};
            syncBoundVariablesCx(cx);
            cx.notify();
            return true;
        }
    }

    // Handle focused TextArea
    if (gooey.getFocusedTextArea()) |ta| {
        if (isControlKey(k.key, k.modifiers)) {
            ta.handleKey(k) catch {};
            syncTextAreaBoundVariablesCx(cx);
            cx.notify();
            return true;
        }
    }

    // Handle focused CodeEditor
    if (gooey.getFocusedCodeEditor()) |ce| {
        if (isControlKey(k.key, k.modifiers)) {
            _ = ce.handleKey(k.key, k.modifiers);
            syncCodeEditorBoundVariablesCx(cx);
            cx.notify();
            return true;
        }
    }

    return false;
}

/// Handle key actions through focus path
fn handleFocusedKeyAction(cx: *Cx, gooey: *Gooey, k: input_mod.KeyEvent) bool {
    if (gooey.focus.getFocused()) |focus_id| {
        var path_buf: [64]DispatchNodeId = undefined;
        if (gooey.dispatch.focusPath(focus_id, &path_buf)) |path| {
            var ctx_buf: [64][]const u8 = undefined;
            const contexts = gooey.dispatch.contextStack(path, &ctx_buf);

            if (gooey.keymap.match(k.key, k.modifiers, contexts)) |binding| {
                if (gooey.dispatch.dispatchAction(binding.action_type, path, gooey)) {
                    cx.notify();
                    return true;
                }
            }

            if (gooey.dispatch.dispatchKeyDown(focus_id, k)) {
                cx.notify();
                return true;
            }
        }
    } else {
        // No focus - try root path
        var path_buf: [64]DispatchNodeId = undefined;
        if (gooey.dispatch.rootPath(&path_buf)) |path| {
            if (gooey.keymap.match(k.key, k.modifiers, &.{})) |binding| {
                if (gooey.dispatch.dispatchAction(binding.action_type, path, gooey)) {
                    cx.notify();
                    return true;
                }
            }
        }
    }
    return false;
}

/// Handle text input events (character insertion)
fn handleTextInputEvent(cx: *Cx, gooey: *Gooey, text: []const u8) bool {
    if (gooey.getFocusedTextInput()) |input| {
        input.insertText(text) catch {};
        syncBoundVariablesCx(cx);
        cx.notify();
        return true;
    }
    if (gooey.getFocusedTextArea()) |ta| {
        ta.insertText(text) catch {};
        syncTextAreaBoundVariablesCx(cx);
        cx.notify();
        return true;
    }
    if (gooey.getFocusedCodeEditor()) |ce| {
        ce.insertText(text);
        syncCodeEditorBoundVariablesCx(cx);
        cx.notify();
        return true;
    }
    return false;
}

/// Handle IME composition events
fn handleCompositionEvent(cx: *Cx, gooey: *Gooey, text: []const u8) bool {
    if (gooey.getFocusedTextInput()) |input| {
        input.setComposition(text) catch {};
        cx.notify();
        return true;
    }
    if (gooey.getFocusedTextArea()) |ta| {
        ta.setComposition(text) catch {};
        cx.notify();
        return true;
    }
    if (gooey.getFocusedCodeEditor()) |ce| {
        ce.setComposition(text);
        cx.notify();
        return true;
    }
    return false;
}

// =============================================================================
// Bound Variable Syncing
// =============================================================================

/// Sync TextInput content back to bound variables (Cx version)
pub fn syncBoundVariablesCx(cx: *Cx) void {
    const builder = cx.builder();
    const gooey = cx.gooey();

    for (builder.pending_inputs.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (gooey.textInput(pending.id)) |input| {
                bind_ptr.* = input.getText();
            }
        }
    }
}

/// Sync TextArea content back to bound variables (Cx version)
pub fn syncTextAreaBoundVariablesCx(cx: *Cx) void {
    const builder = cx.builder();
    const gooey = cx.gooey();

    for (builder.pending_text_areas.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (gooey.textArea(pending.id)) |ta| {
                bind_ptr.* = ta.getText();
            }
        }
    }
}

/// Sync CodeEditor content back to bound variables (Cx version)
pub fn syncCodeEditorBoundVariablesCx(cx: *Cx) void {
    const builder = cx.builder();
    const gooey = cx.gooey();

    for (builder.pending_code_editors.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (gooey.codeEditor(pending.id)) |ce| {
                bind_ptr.* = ce.getText();
            }
        }
    }
}

// =============================================================================
// Utilities
// =============================================================================

/// Check if a key event should be forwarded to text widgets
pub fn isControlKey(key: input_mod.KeyCode, mods: input_mod.Modifiers) bool {
    // Forward key events when cmd/ctrl is held (for shortcuts like Cmd+A, Cmd+C, etc.)
    if (mods.cmd or mods.ctrl) {
        return true;
    }

    return switch (key) {
        .left,
        .right,
        .up,
        .down,
        .delete,
        .forward_delete,
        .@"return",
        .tab,
        .escape,
        => true,
        else => false,
    };
}

/// Check if point is within bounding box
inline fn pointInBounds(x: f32, y: f32, bounds: anytype) bool {
    return x >= bounds.x and x < bounds.x + bounds.width and
        y >= bounds.y and y < bounds.y + bounds.height;
}
