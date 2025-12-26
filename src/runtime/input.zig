//! Input Handling
//!
//! Routes input events (keyboard, mouse, scroll) to the appropriate handlers,
//! widgets, and dispatch tree nodes.

const std = @import("std");

// Core imports
const gooey_mod = @import("../core/gooey.zig");
const input_mod = @import("../core/input.zig");
const dispatch_mod = @import("../core/dispatch.zig");
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
    }

    // Let user's event handler run first
    if (on_event) |handler| {
        if (handler(cx, event)) return true;
    }

    // Route keyboard/text events to focused widgets
    switch (event) {
        .key_down => |k| {
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

/// Handle input with typed context (legacy API support)
pub fn handleInputWithContext(
    comptime ContextType: type,
    ctx: *ContextType,
    on_event: ?*const fn (*ContextType, InputEvent) bool,
    event: InputEvent,
) bool {
    // Handle scroll events
    if (event == .scroll) {
        const scroll_ev = event.scroll;
        const x: f32 = @floatCast(scroll_ev.position.x);
        const y: f32 = @floatCast(scroll_ev.position.y);

        // Check TextAreas for scroll
        for (ctx.builder.pending_text_areas.items) |pending| {
            const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    if (ctx.gooey.textArea(pending.id)) |ta| {
                        // Only scroll if layout info has been set (after first render)
                        if (ta.line_height > 0 and ta.viewport_height > 0) {
                            const delta_y: f32 = @floatCast(scroll_ev.delta.y);
                            const content_height: f32 = @as(f32, @floatFromInt(ta.lineCount())) * ta.line_height;
                            const max_scroll: f32 = @max(0, content_height - ta.viewport_height);
                            const new_offset = ta.scroll_offset_y - delta_y * 20;
                            ta.scroll_offset_y = std.math.clamp(new_offset, 0, max_scroll);
                            ctx.notify();
                            return true;
                        }
                    }
                }
            }
        }

        // Check scroll containers
        for (ctx.builder.pending_scrolls.items) |pending| {
            const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    if (ctx.gooey.widgets.getScrollContainer(pending.id)) |sc| {
                        if (sc.handleScroll(scroll_ev.delta.x, scroll_ev.delta.y)) {
                            ctx.notify();
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

        if (ctx.gooey.updateHover(x, y)) {
            ctx.notify();
        }
    }

    // Handle mouse_exited to clear hover
    if (event == .mouse_exited) {
        ctx.gooey.clearHover();
        ctx.notify();
    }

    // Handle mouse down through dispatch tree
    if (event == .mouse_down) {
        const pos = event.mouse_down.position;
        const x: f32 = @floatCast(pos.x);
        const y: f32 = @floatCast(pos.y);

        // Check if click is in a TextArea
        for (ctx.builder.pending_text_areas.items) |pending| {
            const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);

            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    ctx.gooey.focusTextArea(pending.id);
                    ctx.notify();
                    return true;
                }
            }
        }

        // Compute hit target once for both click-outside and click dispatch
        const hit_target = ctx.gooey.dispatch.hitTest(x, y);

        // Dispatch click-outside events first (for closing dropdowns, modals, etc.)
        // This fires for any click, regardless of what was hit
        if (ctx.gooey.dispatch.dispatchClickOutsideWithTarget(x, y, hit_target, ctx.gooey)) {
            ctx.notify();
        }

        if (hit_target) |target| {
            if (ctx.gooey.dispatch.getNodeConst(target)) |node| {
                if (node.focus_id) |focus_id| {
                    if (ctx.gooey.focus.getHandleById(focus_id)) |handle| {
                        ctx.gooey.focusElement(handle.string_id);
                    }
                }
            }

            if (ctx.gooey.dispatch.dispatchClick(target, ctx.gooey)) {
                ctx.notify();
                return true;
            }
        }
    }

    // Let user's event handler run first
    if (on_event) |handler| {
        if (handler(ctx, event)) return true;
    }

    // Route keyboard/text events to focused widgets
    switch (event) {
        .key_down => |k| {
            if (k.key == .tab) {
                if (k.modifiers.shift) {
                    ctx.gooey.focusPrev();
                } else {
                    ctx.gooey.focusNext();
                }
                return true;
            }

            // Try action dispatch through focus path
            if (ctx.gooey.focus.getFocused()) |focus_id| {
                var path_buf: [64]DispatchNodeId = undefined;
                if (ctx.gooey.dispatch.focusPath(focus_id, &path_buf)) |path| {
                    var ctx_buf: [64][]const u8 = undefined;
                    const contexts = ctx.gooey.dispatch.contextStack(path, &ctx_buf);

                    if (ctx.gooey.keymap.match(k.key, k.modifiers, contexts)) |binding| {
                        if (ctx.gooey.dispatch.dispatchAction(binding.action_type, path, ctx.gooey)) {
                            ctx.notify();
                            return true;
                        }
                    }

                    if (ctx.gooey.dispatch.dispatchKeyDown(focus_id, k)) {
                        ctx.notify();
                        return true;
                    }
                }
            } else {
                var path_buf: [64]DispatchNodeId = undefined;
                if (ctx.gooey.dispatch.rootPath(&path_buf)) |path| {
                    if (ctx.gooey.keymap.match(k.key, k.modifiers, &.{})) |binding| {
                        if (ctx.gooey.dispatch.dispatchAction(binding.action_type, path, ctx.gooey)) {
                            ctx.notify();
                            return true;
                        }
                    }
                }
            }

            // Handle focused TextInput
            if (ctx.gooey.getFocusedTextInput()) |input| {
                if (isControlKey(k.key, k.modifiers)) {
                    input.handleKey(k) catch {};
                    syncBoundVariablesWithContext(ContextType, ctx);
                    ctx.notify();
                    return true;
                }
            }

            // Handle focused TextArea
            if (ctx.gooey.getFocusedTextArea()) |ta| {
                if (isControlKey(k.key, k.modifiers)) {
                    ta.handleKey(k) catch {};
                    syncTextAreaBoundVariablesWithContext(ContextType, ctx);
                    ctx.notify();
                    return true;
                }
            }
        },
        .text_input => |t| {
            if (ctx.gooey.getFocusedTextInput()) |input| {
                input.insertText(t.text) catch {};
                syncBoundVariablesWithContext(ContextType, ctx);
                ctx.notify();
                return true;
            }
            if (ctx.gooey.getFocusedTextArea()) |ta| {
                ta.insertText(t.text) catch {};
                syncTextAreaBoundVariablesWithContext(ContextType, ctx);
                ctx.notify();
                return true;
            }
        },
        .composition => |c| {
            if (ctx.gooey.getFocusedTextInput()) |input| {
                input.setComposition(c.text) catch {};
                ctx.notify();
                return true;
            }
            if (ctx.gooey.getFocusedTextArea()) |ta| {
                ta.setComposition(c.text) catch {};
                ctx.notify();
                return true;
            }
        },
        else => {},
    }

    // Final chance for user handler
    if (on_event) |handler| {
        return handler(ctx, event);
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

/// Sync TextInput content back to bound variables (generic version)
pub fn syncBoundVariablesWithContext(comptime ContextType: type, ctx: *ContextType) void {
    for (ctx.builder.pending_inputs.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (ctx.gooey.textInput(pending.id)) |input| {
                bind_ptr.* = input.getText();
            }
        }
    }
}

/// Sync TextArea content back to bound variables (generic version)
pub fn syncTextAreaBoundVariablesWithContext(comptime ContextType: type, ctx: *ContextType) void {
    for (ctx.builder.pending_text_areas.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (ctx.gooey.textArea(pending.id)) |ta| {
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
