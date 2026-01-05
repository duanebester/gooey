//! Input Handling
//!
//! Routes input events (keyboard, mouse, scroll) to the appropriate handlers,
//! widgets, and dispatch tree nodes.

const std = @import("std");

// Core imports
const gooey_mod = @import("../context/gooey.zig");
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

/// Handle input with Cx context
pub fn handleInputCx(
    cx: *Cx,
    on_event: ?*const fn (*Cx, InputEvent) bool,
    event: InputEvent,
) bool {
    // Handle scroll events
    if (event == .scroll) {
        const scroll_ev = event.scroll;
        const x: f32 = @floatCast(scroll_ev.position.x);
        const y: f32 = @floatCast(scroll_ev.position.y);

        // Check TextAreas for scroll
        for (cx.builder().pending_text_areas.items) |pending| {
            const bounds = cx.gooey().layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    if (cx.gooey().textArea(pending.id)) |ta| {
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
                }
            }
        }

        // Check scroll containers
        for (cx.builder().pending_scrolls.items) |pending| {
            const bounds = cx.gooey().layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    if (cx.gooey().widgets.getScrollContainer(pending.id)) |sc| {
                        if (sc.handleScroll(scroll_ev.delta.x, scroll_ev.delta.y)) {
                            cx.notify();
                            return true;
                        }
                    }
                }
            }
        }
    }

    // Handle mouse_moved for hover state
    if (event == .mouse_moved or event == .mouse_dragged) {
        const pos = switch (event) {
            .mouse_moved => |m| m.position,
            .mouse_dragged => |m| m.position,
            else => unreachable,
        };
        const x: f32 = @floatCast(pos.x);
        const y: f32 = @floatCast(pos.y);

        // Update scrollbar thumb position during drag
        if (event == .mouse_dragged) {
            for (cx.builder().pending_scrolls.items) |pending| {
                if (cx.gooey().widgets.getScrollContainer(pending.id)) |sc| {
                    if (sc.state.dragging_vertical or sc.state.dragging_horizontal) {
                        sc.updateDrag(x, y);
                        cx.notify();
                        return true;
                    }
                }
            }
        }

        if (cx.gooey().updateHover(x, y)) {
            cx.notify();
        }
    }

    // Handle mouse_exited to clear hover
    if (event == .mouse_exited) {
        cx.gooey().clearHover();
        cx.notify();
    }

    // Handle mouse down through dispatch tree
    if (event == .mouse_down) {
        const pos = event.mouse_down.position;
        const x: f32 = @floatCast(pos.x);
        const y: f32 = @floatCast(pos.y);

        // Check scroll containers for scrollbar clicks (priority - handle before other widgets)
        for (cx.builder().pending_scrolls.items) |pending| {
            if (cx.gooey().widgets.getScrollContainer(pending.id)) |sc| {
                // Check for thumb drag
                if (sc.hitTestThumb(x, y)) |hit| {
                    switch (hit) {
                        .vertical => sc.startDrag(.vertical, x, y),
                        .horizontal => sc.startDrag(.horizontal, x, y),
                    }
                    cx.notify();
                    return true;
                }
                // Check for track click (jump to position)
                if (sc.handleTrackClick(x, y)) {
                    cx.notify();
                    return true;
                }
            }
        }

        // Check if click is in a TextArea
        for (cx.builder().pending_text_areas.items) |pending| {
            const bounds = cx.gooey().layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    cx.gooey().focusTextArea(pending.id);
                    cx.notify();
                    return true;
                }
            }
        }

        // Compute hit target once for both click-outside and click dispatch
        const hit_target = cx.gooey().dispatch.hitTest(x, y);

        // Dispatch click-outside events first (for closing dropdowns, modals, etc.)
        // This fires for any click, regardless of what was hit
        if (cx.gooey().dispatch.dispatchClickOutsideWithTarget(x, y, hit_target, cx.gooey())) {
            cx.notify();
        }

        if (hit_target) |target| {
            if (cx.gooey().dispatch.getNodeConst(target)) |node| {
                if (node.focus_id) |focus_id| {
                    if (cx.gooey().focus.getHandleById(focus_id)) |handle| {
                        cx.gooey().focusElement(handle.string_id);
                    }
                }
            }

            if (cx.gooey().dispatch.dispatchClick(target, cx.gooey())) {
                cx.notify();
                return true;
            }
        }

        // Debugger: handle click to select element for inspection
        if (cx.gooey().debugger.isActive()) {
            cx.gooey().debugger.handleClick(cx.gooey().hovered_layout_id);
            cx.notify();
        }
    }

    // Handle mouse_up to end scrollbar drag
    if (event == .mouse_up) {
        for (cx.builder().pending_scrolls.items) |pending| {
            if (cx.gooey().widgets.getScrollContainer(pending.id)) |sc| {
                if (sc.state.dragging_vertical or sc.state.dragging_horizontal) {
                    sc.endDrag();
                    cx.notify();
                    return true;
                }
            }
        }
    }

    // Let user's event handler run first
    if (on_event) |handler| {
        if (handler(cx, event)) return true;
    }

    // Route keyboard/text events to focused widgets
    switch (event) {
        .key_down => |k| {
            // Debugger toggle: Cmd+Shift+I (macOS) or Ctrl+Shift+I
            if (debugger_mod.Debugger.isToggleShortcut(k.key, k.modifiers)) {
                cx.gooey().debugger.toggle();
                cx.notify();
                return true;
            }

            if (k.key == .tab) {
                if (k.modifiers.shift) {
                    cx.gooey().focusPrev();
                } else {
                    cx.gooey().focusNext();
                }
                return true;
            }

            // Try action dispatch through focus path
            if (cx.gooey().focus.getFocused()) |focus_id| {
                var path_buf: [64]DispatchNodeId = undefined;
                if (cx.gooey().dispatch.focusPath(focus_id, &path_buf)) |path| {
                    var ctx_buf: [64][]const u8 = undefined;
                    const contexts = cx.gooey().dispatch.contextStack(path, &ctx_buf);

                    if (cx.gooey().keymap.match(k.key, k.modifiers, contexts)) |binding| {
                        if (cx.gooey().dispatch.dispatchAction(binding.action_type, path, cx.gooey())) {
                            cx.notify();
                            return true;
                        }
                    }

                    if (cx.gooey().dispatch.dispatchKeyDown(focus_id, k)) {
                        cx.notify();
                        return true;
                    }
                }
            } else {
                var path_buf: [64]DispatchNodeId = undefined;
                if (cx.gooey().dispatch.rootPath(&path_buf)) |path| {
                    if (cx.gooey().keymap.match(k.key, k.modifiers, &.{})) |binding| {
                        if (cx.gooey().dispatch.dispatchAction(binding.action_type, path, cx.gooey())) {
                            cx.notify();
                            return true;
                        }
                    }
                }
            }

            // Handle focused TextInput
            if (cx.gooey().getFocusedTextInput()) |input| {
                if (isControlKey(k.key, k.modifiers)) {
                    input.handleKey(k) catch {};
                    syncBoundVariablesCx(cx);
                    cx.notify();
                    return true;
                }
            }

            // Handle focused TextArea
            if (cx.gooey().getFocusedTextArea()) |ta| {
                if (isControlKey(k.key, k.modifiers)) {
                    ta.handleKey(k) catch {};
                    syncTextAreaBoundVariablesCx(cx);
                    cx.notify();
                    return true;
                }
            }
        },
        .text_input => |t| {
            if (cx.gooey().getFocusedTextInput()) |input| {
                input.insertText(t.text) catch {};
                syncBoundVariablesCx(cx);
                cx.notify();
                return true;
            }
            if (cx.gooey().getFocusedTextArea()) |ta| {
                ta.insertText(t.text) catch {};
                syncTextAreaBoundVariablesCx(cx);
                cx.notify();
                return true;
            }
        },
        .composition => |c| {
            if (cx.gooey().getFocusedTextInput()) |input| {
                input.setComposition(c.text) catch {};
                cx.notify();
                return true;
            }
            if (cx.gooey().getFocusedTextArea()) |ta| {
                ta.setComposition(c.text) catch {};
                cx.notify();
                return true;
            }
        },
        else => {},
    }

    // Final chance for user handler
    if (on_event) |handler| {
        return handler(cx, event);
    }
    return false;
}

// =============================================================================
// Bound Variable Syncing
// =============================================================================

/// Sync TextInput content back to bound variables (Cx version)
pub fn syncBoundVariablesCx(cx: *Cx) void {
    for (cx.builder().pending_inputs.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (cx.gooey().textInput(pending.id)) |input| {
                bind_ptr.* = input.getText();
            }
        }
    }
}

/// Sync TextArea content back to bound variables (Cx version)
pub fn syncTextAreaBoundVariablesCx(cx: *Cx) void {
    for (cx.builder().pending_text_areas.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (cx.gooey().textArea(pending.id)) |ta| {
                bind_ptr.* = ta.getText();
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
