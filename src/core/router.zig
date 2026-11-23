const std = @import("std");
const builtin = @import("builtin");
const records = @import("records.zig");
const element = @import("element.zig");
const handler_mod = @import("handler.zig");
const events = @import("events.zig");
const window_mod = @import("window.zig");
const input = @import("../input/mod.zig");
const keymap = @import("keymap.zig");
const text_engine = @import("text_engine.zig");
const debugger = @import("debugger.zig");

const assert = std.debug.assert;

const Window = window_mod.Window;
const Capture = window_mod.Capture;
const Drag = window_mod.Drag;
const PointerDrag = handler_mod.Effects.PointerDrag;
const ElementId = records.ElementId;
const index_none = records.index_none;

pub const Point = struct { x: f32, y: f32 };

pub const Query = struct {
    window: *const Window,

    pub fn hitTest(self: *const Query, point: Point) ?ElementId {
        const frame = self.window.rendered();
        const index = hitIndex(frame, point);
        if (index == index_none) return null;
        return frame.hits[index].id;
    }

    pub fn imeCursorRect(self: *const Query) ?records.Rect {
        const ime = self.window.rendered().ime orelse return null;
        assert(ime.cursor_rect.width >= 0);
        return ime.cursor_rect;
    }

    pub fn imeOwner(self: *const Query) ?ElementId {
        const ime = self.window.rendered().ime orelse return null;
        assert(ime.owner.isKeyed());
        return ime.owner;
    }

    pub fn imeSelectedRange(self: *const Query) ?records.TextRange {
        const ime = self.window.rendered().ime orelse return null;
        assert(ime.selected_start <= ime.selected_end);
        return .{ .offset = ime.selected_start, .len = ime.selected_end - ime.selected_start };
    }

    pub fn keymapClaims(self: *const Query, key: input.KeyEvent) bool {
        assert(self.window.phase != .build);
        if (debugger.isToggle(&key)) return true;
        return findAction(self.window, &key) != null;
    }

    pub fn pressClaims(self: *const Query, point: Point) bool {
        assert(self.window.phase != .build);
        assert(std.math.isFinite(point.x));
        assert(std.math.isFinite(point.y));
        const frame = self.window.rendered();
        var index = hitIndex(frame, point);
        var depth: u32 = 0;
        while (index != index_none) : (depth += 1) {
            assert(depth <= window_mod.box_depth_ceiling);
            const record = &frame.hits[index];
            if (record.on_click != index_none) return true;
            if (record.focusable) return true;
            if (record.on_pointer_drag != index_none) return true;
            if (record.drag_type != 0) return true;
            if (record.scroll) {
                const retained = &self.window.retained;
                if (retained.findConst(window_mod.ScrollState, record.id)) |state| {
                    if (state.scrollbarAt(point.x, point.y) != null) return true;
                }
            }
            index = record.parent;
        }
        return false;
    }
};

fn hitIndex(frame: *const records.Frame, point: Point) u32 {
    assert(frame.hit_count <= frame.hits.len);
    assert(frame.modal_hit_start <= frame.hit_count);
    var index = frame.hit_count;
    while (index > frame.modal_hit_start) {
        index -= 1;
        const record = &frame.hits[index];
        if (record.pointer and record.bounds.contains(point.x, point.y)) return index;
    }
    return index_none;
}

fn findRecord(frame: *const records.Frame, id: ElementId) u32 {
    if (id == .root) return index_none;
    for (frame.hits[0..frame.hit_count], 0..) |*record, index| {
        if (record.id == id) return @intCast(index);
    }
    return index_none;
}

pub fn route(window: *Window, event: *const events.Event) void {
    window.assertPhase(.drain);
    switch (event.*) {
        .input => |*value| routeInput(window, value),
        .completion => |*completion| routeCompletion(window, completion),
        .window => |change| switch (change) {
            .resized => |size| {
                assert(size.scale_factor > 0);
                window.width = size.width;
                window.height = size.height;
                window.scale_factor = size.scale_factor;
                window.render_requested = true;
            },
            .title_bar => |inset| {
                assert(inset.top >= 0);
                assert(inset.left >= 0);
                assert(inset.right >= 0);
                window.title_bar_inset = inset;
                window.render_requested = true;
            },
            .close_requested => window.quit_requested = true,
        },
    }
}

fn routeInput(window: *Window, event: *const input.InputEvent) void {
    switch (event.*) {
        .mouse_down => |mouse| {
            const point = pointOf(mouse.position);
            window.pointer = .{ .x = point.x, .y = point.y };
            debugger.press(window, point.x, point.y);
            if (window.drag.keyboard) cancelDrag(window);
            press(window, event, point);
        },
        .mouse_up => |mouse| {
            const point = pointOf(mouse.position);
            window.pointer = .{ .x = point.x, .y = point.y };
            if (window.scroll_drag != .root and mouse.button == .left) endScrollDrag(window);
            if (window.capture.id != .root and window.capture.button == mouse.button) {
                finishCapture(window, event, .end, point);
            }
            const pointer_drag = window.drag.phase != .idle and !window.drag.keyboard;
            if (pointer_drag and window.drag.button == mouse.button) {
                if (window.drag.phase == .active) {
                    drop(window, event, point);
                    return;
                }
                window.drag = Drag.idle;
            }
            if (mouse.button == .left) release(window, event, point);
        },
        .mouse_moved, .mouse_dragged, .mouse_entered => |mouse| {
            const point = pointOf(mouse.position);
            window.pointer = .{ .x = point.x, .y = point.y };
            if (window.scroll_drag != .root) dragScrollbar(window, point);
            if (window.capture.id != .root) moveCapture(window, event, point);
            if (window.drag.phase != .idle and !window.drag.keyboard) moveDrag(window, point);
            updateHover(window);
            debugger.pointerMoved(window);
        },
        .mouse_exited => {
            window.pointer = null;
            updateHover(window);
            debugger.pointerMoved(window);
        },
        .key_down => keyDown(window, event),
        .key_up, .text_input, .composition => {
            if (!window.drag.keyboard) keyToFocus(window, event);
        },
        .scroll => |scroll| wheel(window, event, pointOf(scroll.position)),
        .pointer_cancelled => cancelPointer(window, event),
        .focus_lost => |*lost| focusLost(window, lost),
        else => {},
    }
}

fn cancelPointer(window: *Window, event: *const input.InputEvent) void {
    assert(event.* == .pointer_cancelled);
    if (window.scroll_drag != .root) endScrollDrag(window);
    if (window.capture.id != .root) {
        finishCapture(window, event, .cancel, capturePoint(window));
    }
    if (window.drag.keyboard) {
        endKeyboardDrag(window);
    } else {
        if (window.drag.phase != .idle) cancelDrag(window);
    }
    window.press_len = 0;
    assert(window.capture.id == .root);
}

fn focusLost(window: *Window, lost: *const input.FocusLostEvent) void {
    if (lost.pointer_cancelled) {
        const cancelled: input.InputEvent = .pointer_cancelled;
        cancelPointer(window, &cancelled);
    }
    var keys = lost.keys_held.iterator(.{});
    var released: u32 = 0;
    while (keys.next()) |value| : (released += 1) {
        assert(released < input.held_key_count_max);
        const key: input.KeyCode = @fromBackingInt(@as(u16, @intCast(value)));
        assert(key != .unknown);
        const up: input.InputEvent = .{ .key_up = .{
            .key = key,
            .modifiers = .{},
            .characters = null,
            .characters_ignoring_modifiers = null,
            .is_repeat = false,
        } };
        if (!window.drag.keyboard) keyToFocus(window, &up);
    }
    assert(released == lost.keys_held.count());
}

fn keyDown(window: *Window, event: *const input.InputEvent) void {
    const key = &event.key_down;
    if (window.drag.keyboard) {
        keyboardDragKey(window, event);
    } else {
        if (key.key == .escape and window.capture.id != .root) {
            finishCapture(window, event, .cancel, capturePoint(window));
        } else {
            if (key.key == .escape and window.drag.phase != .idle) {
                cancelDrag(window);
            } else {
                keyToFocus(window, event);
            }
        }
    }
}

fn pointOf(position: anytype) Point {
    const point = Point{ .x = @floatCast(position.x), .y = @floatCast(position.y) };
    assert(std.math.isFinite(point.x));
    assert(std.math.isFinite(point.y));
    return point;
}

fn press(window: *Window, event: *const input.InputEvent, point: Point) void {
    const frame = window.rendered();
    const target = hitIndex(frame, point);
    const context = contextPress(&event.mouse_down);
    const left = event.mouse_down.button == .left and !context;
    const scrollbar_free = left and window.scroll_drag == .root;
    if (scrollbar_free and pressScrollbar(window, target, point)) return;
    assert(window.scroll_drag == .root or !scrollbar_free);
    if (left) window.press_len = pathOf(frame, target, window.press_path);
    const ctrl_click = context and event.mouse_down.button == .left;
    const idle = window.capture.id == .root and window.drag.phase == .idle and !ctrl_click;
    const gesture = if (idle) gestureIndex(frame, target) else index_none;
    var capturing = false;
    if (gesture != index_none) {
        const record = &frame.hits[gesture];
        if (record.on_pointer_drag != index_none) {
            capturing = true;
            window.capture = .{
                .id = record.id,
                .button = event.mouse_down.button,
                .start_x = point.x,
                .start_y = point.y,
                .moved = false,
                .cursor = cursorOf(frame, target),
            };
        } else {
            armDrag(window, record, event.mouse_down.button, point);
        }
    }
    clickOutside(window, event, target);
    var focus_id: ElementId = .root;
    var index = target;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        if (frame.hits[index].focusable) {
            focus_id = frame.hits[index].id;
            break;
        }
        index = frame.hits[index].parent;
    }
    setFocus(window, focus_id, false);
    if (capturing) deliverCapture(window, event, .begin, point);
    if (context) contextMenu(window, event, target);
}

fn release(window: *Window, event: *const input.InputEvent, point: Point) void {
    assert(event.mouse_up.button == .left);
    const pressed = window.press_path[0..window.press_len];
    defer window.press_len = 0;
    if (pressed.len == 0) return;
    const frame = window.rendered();
    var index = hitIndex(frame, point);
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        const record = &frame.hits[index];
        if (std.mem.indexOfScalar(ElementId, pressed, record.id) != null) {
            if (frame.handlerAt(record.on_click)) |handler| {
                if (invoke(window, handler, event, null, record.id)) return;
            }
        }
        index = record.parent;
    }
}

fn gestureIndex(frame: *const records.Frame, target: u32) u32 {
    var index = target;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        const record = &frame.hits[index];
        if (record.on_pointer_drag != index_none) return index;
        if (record.drag_type != 0) return index;
        index = record.parent;
    }
    return index_none;
}

fn armDrag(
    window: *Window,
    record: *const records.HitRecord,
    button: input.MouseButton,
    point: Point,
) void {
    assert(window.drag.phase == .idle);
    assert(record.drag_type != 0);
    assert(record.id.isKeyed());
    window.drag = .{
        .phase = .armed,
        .keyboard = false,
        .source = record.id,
        .button = button,
        .type_id = record.drag_type,
        .payload = record.drag_payload,
        .start_x = point.x,
        .start_y = point.y,
        .x = point.x,
        .y = point.y,
        .over = .root,
    };
}

fn moveDrag(window: *Window, point: Point) void {
    const drag = &window.drag;
    assert(drag.phase != .idle);
    if (drag.phase == .armed) {
        const dx = point.x - drag.start_x;
        const dy = point.y - drag.start_y;
        const slop = Capture.click_slop_px;
        if (dx * dx + dy * dy <= slop * slop) return;
        drag.phase = .active;
        if (drag.button == .left) window.press_len = 0;
    }
    drag.x = point.x;
    drag.y = point.y;
    window.render_requested = true;
    assert(drag.phase == .active);
}

fn dropTargetFrom(frame: *const records.Frame, index_start: u32, type_id: usize) u32 {
    assert(type_id != 0);
    var index = index_start;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        if (frame.hits[index].drop_type == type_id) return index;
        index = frame.hits[index].parent;
    }
    return index_none;
}

fn drop(window: *Window, event: *const input.InputEvent, point: Point) void {
    const drag = window.drag;
    assert(drag.phase == .active);
    assert(drag.type_id != 0);
    window.drag = Drag.idle;
    if (drag.button == .left) window.press_len = 0;
    window.render_requested = true;
    const frame = window.rendered();
    const target = dropTargetFrom(frame, hitIndex(frame, point), drag.type_id);
    updateHover(window);
    if (target != index_none) deliverDrop(window, event, &drag, target);
}

fn deliverDrop(
    window: *Window,
    event: *const input.InputEvent,
    drag: *const Drag,
    target: u32,
) void {
    assert(window.drag.phase == .idle);
    const frame = window.rendered();
    assert(target < frame.hit_count);
    const record = &frame.hits[target];
    assert(record.drop_type == drag.type_id);
    const handler = frame.handlerAt(record.on_drop).?;
    var effects = handler_mod.Effects.init(event, record.id);
    effects.drop = .{ .type_id = drag.type_id, .payload = drag.payload };
    call(window, handler, &effects);
    if (effects.click_request) |id| clickRequested(window, id, event);
}

fn cancelDrag(window: *Window) void {
    assert(window.drag.phase != .idle);
    if (window.drag.phase == .active) window.render_requested = true;
    window.drag = Drag.idle;
    window.press_len = 0;
    updateHover(window);
    assert(window.drag.over == .root);
}

fn applyDragStart(window: *Window, request: handler_mod.Effects.DragStart) void {
    const before = window.drag;
    startKeyboardDrag(window, request.id);
    if (request.started) {
        assert(window.drag.phase == .active);
        assert(window.drag.keyboard);
        assert(window.drag.source == request.id);
    } else {
        assert(window.drag.phase == before.phase);
        assert(window.drag.source == before.source);
        assert(window.drag.keyboard == before.keyboard);
    }
}

fn startKeyboardDrag(window: *Window, id: ElementId) void {
    assert(id.isKeyed());
    if (window.drag.phase != .idle) return;
    if (window.capture.id != .root) return;
    const frame = window.rendered();
    const index = findRecord(frame, id);
    if (index == index_none) return;
    const record = &frame.hits[index];
    assert(record.drag_type != 0);
    const centre = centreOf(record.bounds);
    window.drag = .{
        .phase = .active,
        .keyboard = true,
        .source = id,
        .button = .left,
        .type_id = record.drag_type,
        .payload = record.drag_payload,
        .start_x = centre.x,
        .start_y = centre.y,
        .x = centre.x,
        .y = centre.y,
        .over = .root,
    };
    window.press_len = 0;
    window.render_requested = true;
    assert(window.drag.over == .root);
}

fn centreOf(bounds: records.Rect) Point {
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    return .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
}

fn keyboardDragKey(window: *Window, event: *const input.InputEvent) void {
    assert(window.drag.keyboard);
    assert(window.drag.phase == .active);
    const key = &event.key_down;
    switch (key.key) {
        .tab => moveKeyboardOver(window, key.modifiers.shift),
        .down, .right => moveKeyboardOver(window, false),
        .up, .left => moveKeyboardOver(window, true),
        .escape => endKeyboardDrag(window),
        else => if (activates(key)) keyboardDrop(window, event),
    }
}

fn moveKeyboardOver(window: *Window, backward: bool) void {
    const drag = &window.drag;
    assert(drag.keyboard);
    assert(drag.type_id != 0);
    const frame = window.rendered();
    const count = frame.hit_count;
    assert(count <= frame.hits.len);
    if (count == 0) return;
    const from = findRecord(frame, if (drag.over != .root) drag.over else drag.source);
    var index: u32 = from;
    if (from == index_none) index = if (backward) 0 else count - 1;
    var steps: u32 = 0;
    while (steps < count) : (steps += 1) {
        index = if (backward) (index + count - 1) % count else (index + 1) % count;
        const record = &frame.hits[index];
        if (record.drop_type != drag.type_id) continue;
        if (!record.pointer or index < frame.modal_hit_start) continue;
        setKeyboardOver(window, record);
        return;
    }
}

fn setKeyboardOver(window: *Window, record: *const records.HitRecord) void {
    const drag = &window.drag;
    assert(record.drop_type == drag.type_id);
    assert(record.id.isKeyed());
    const centre = centreOf(record.bounds);
    drag.over = record.id;
    drag.x = centre.x;
    drag.y = centre.y;
    setFocus(window, record.id, true);
    window.render_requested = true;
}

fn keyboardDrop(window: *Window, event: *const input.InputEvent) void {
    const drag = window.drag;
    assert(drag.keyboard);
    assert(drag.phase == .active);
    if (drag.over == .root) return;
    const frame = window.rendered();
    const target = findRecord(frame, drag.over);
    if (target == index_none) return;
    endKeyboardDrag(window);
    if (frame.hits[target].focusable) setFocus(window, drag.over, true);
    deliverDrop(window, event, &drag, target);
}

fn endKeyboardDrag(window: *Window) void {
    assert(window.drag.keyboard);
    const source = window.drag.source;
    cancelDrag(window);
    setFocus(window, source, true);
    assert(!window.drag.keyboard);
}

fn moveCapture(window: *Window, event: *const input.InputEvent, point: Point) void {
    const capture = &window.capture;
    assert(capture.id.isKeyed());
    if (!capture.moved) {
        const dx = point.x - capture.start_x;
        const dy = point.y - capture.start_y;
        const slop = Capture.click_slop_px;
        if (dx * dx + dy * dy > slop * slop) {
            capture.moved = true;
            if (capture.button == .left) window.press_len = 0;
        }
    }
    deliverCapture(window, event, .move, point);
}

fn finishCapture(
    window: *Window,
    event: *const input.InputEvent,
    phase: PointerDrag.Phase,
    point: Point,
) void {
    assert(phase == .end or phase == .cancel);
    assert(window.capture.id.isKeyed());
    if (phase == .cancel) window.press_len = 0;
    deliverCapture(window, event, phase, point);
    window.capture = Capture.none;
    updateHover(window);
    assert(window.capture.id == .root);
}

fn capturePoint(window: *const Window) Point {
    assert(window.capture.id.isKeyed());
    const pointer = window.pointer orelse
        return .{ .x = window.capture.start_x, .y = window.capture.start_y };
    return .{ .x = pointer.x, .y = pointer.y };
}

fn deliverCapture(
    window: *Window,
    event: *const input.InputEvent,
    phase: PointerDrag.Phase,
    point: Point,
) void {
    const capture = window.capture;
    assert(capture.id.isKeyed());
    const frame = window.rendered();
    const index = findRecord(frame, capture.id);
    const handler = if (index == index_none)
        null
    else
        frame.handlerAt(frame.hits[index].on_pointer_drag);
    if (handler == null) {
        window.capture = Capture.none;
        return;
    }
    var effects = handler_mod.Effects.init(event, capture.id);
    effects.pointer_drag = .{
        .phase = phase,
        .x = point.x,
        .y = point.y,
        .start_x = capture.start_x,
        .start_y = capture.start_y,
        .button = capture.button,
        .modifiers = modifiersOf(event),
    };
    call(window, handler.?, &effects);
    if (effects.click_request) |id| clickRequested(window, id, event);
}

fn modifiersOf(event: *const input.InputEvent) input.Modifiers {
    return switch (event.*) {
        .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => |mouse| mouse.modifiers,
        .key_down, .key_up => |key| key.modifiers,
        else => .{},
    };
}

fn pressScrollbar(window: *Window, target: u32, point: Point) bool {
    assert(window.scroll_drag == .root);
    const frame = window.rendered();
    var index = target;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        const record = &frame.hits[index];
        if (record.scroll) {
            if (window.retained.find(window_mod.ScrollState, record.id)) |state| {
                if (state.press(point.x, point.y)) {
                    if (state.dragging != null) window.scroll_drag = record.id;
                    assert((state.dragging != null) == window.scroll_drag.isKeyed());
                    window.render_requested = true;
                    window.press_len = 0;
                    return true;
                }
            }
        }
        index = record.parent;
    }
    return false;
}

fn dragScrollbar(window: *Window, point: Point) void {
    assert(window.scroll_drag.isKeyed());
    const state = window.retained.find(window_mod.ScrollState, window.scroll_drag) orelse {
        window.scroll_drag = .root;
        return;
    };
    assert(state.dragging != null);
    if (state.drag(point.x, point.y)) window.render_requested = true;
}

fn endScrollDrag(window: *Window) void {
    assert(window.scroll_drag.isKeyed());
    if (window.retained.find(window_mod.ScrollState, window.scroll_drag)) |state| {
        assert(state.dragging != null);
        state.dragging = null;
    }
    window.scroll_drag = .root;
    window.render_requested = true;
    assert(window.scroll_drag == .root);
}

fn pathOf(frame: *const records.Frame, index_start: u32, path: []ElementId) u32 {
    var index = index_start;
    var len: u32 = 0;
    while (index != index_none) : (len += 1) {
        assert(len < path.len);
        path[len] = frame.hits[index].id;
        index = frame.hits[index].parent;
    }
    assert(len <= path.len);
    return len;
}

fn clickOutside(window: *Window, event: *const input.InputEvent, target: u32) void {
    const frame = window.rendered();
    for (frame.hits[0..frame.hit_count], 0..) |*record, index| {
        if (record.on_click_outside == index_none) continue;
        if (isAncestorOrSelf(frame, @intCast(index), target)) continue;
        _ = invoke(window, frame.handlerAt(record.on_click_outside).?, event, null, record.id);
    }
}

fn isAncestorOrSelf(frame: *const records.Frame, ancestor: u32, index_start: u32) bool {
    var index = index_start;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        if (index == ancestor) return true;
        index = frame.hits[index].parent;
    }
    return false;
}

const Slot = enum { click, key };

fn bubble(window: *Window, event: *const input.InputEvent, start: u32, slot: Slot) bool {
    const frame = window.rendered();
    var index = start;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        const record = &frame.hits[index];
        const handler_index = switch (slot) {
            .click => record.on_click,
            .key => record.on_key,
        };
        if (frame.handlerAt(handler_index)) |handler| {
            if (invoke(window, handler, event, null, record.id)) return true;
        }
        index = record.parent;
    }
    return false;
}

fn wheel(window: *Window, event: *const input.InputEvent, point: Point) void {
    assert(event.* == .scroll);
    const frame = window.rendered();
    const area_type = handler_mod.typeId(text_engine.AreaEngine);
    const editor_type = handler_mod.typeId(text_engine.EditorEngine);
    var index = hitIndex(frame, point);
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        const record = &frame.hits[index];
        if (frame.handlerAt(record.on_key)) |handler| {
            const type_id = handler.target.type_id;
            if (type_id == area_type or type_id == editor_type) {
                _ = invoke(window, handler, event, null, record.id);
                return;
            }
        }
        if (record.scroll) {
            if (scrollBox(window, record.id, &event.scroll)) return;
        }
        index = record.parent;
    }
}

fn scrollBox(window: *Window, id: ElementId, scroll: *const input.ScrollEvent) bool {
    assert(id.isKeyed());
    const state = window.retained.find(window_mod.ScrollState, id) orelse return false;
    const delta_x: f32 = @floatCast(scroll.delta.x);
    const delta_y: f32 = @floatCast(scroll.delta.y);
    if (!state.wheel(delta_x, delta_y)) return false;
    window.render_requested = true;
    return true;
}

fn keyToFocus(window: *Window, event: *const input.InputEvent) void {
    if (debugger.routeKey(window, event)) return;
    if (event.* == .key_down) {
        if (findAction(window, &event.key_down)) |found| {
            _ = invoke(window, found.handler, event, null, found.id);
            return;
        }
    }
    const frame = window.rendered();
    const target = findRecord(frame, window.focus);
    if (target == index_none) {
        if (event.* == .key_down and event.key_down.key == .tab) {
            moveFocus(window, event.key_down.modifiers.shift);
        }
        return;
    }
    if (bubble(window, event, target, .key)) return;
    if (event.* != .key_down) return;
    const key = &event.key_down;
    assert(target < frame.hit_count);
    if (key.key == .tab) {
        moveFocus(window, key.modifiers.shift);
    } else {
        if (activates(key)) {
            if (frame.handlerAt(frame.hits[target].on_click)) |handler| {
                _ = invoke(window, handler, event, null, frame.hits[target].id);
            }
        } else {
            if (opensContextMenu(key)) contextMenu(window, event, target);
        }
    }
}

fn opensContextMenu(key: *const input.KeyEvent) bool {
    const modifiers = key.modifiers;
    if (key.is_repeat) return false;
    if (modifiers.cmd or modifiers.ctrl or modifiers.alt) return false;
    return key.key == .f10 and modifiers.shift;
}

fn contextPress(mouse: *const input.MouseEvent) bool {
    if (mouse.button == .right) return true;
    if (builtin.os.tag != .macos) return false;
    return mouse.button == .left and mouse.modifiers.ctrl;
}

fn contextMenu(window: *Window, event: *const input.InputEvent, target: u32) void {
    assert(event.* == .mouse_down or event.* == .key_down);
    const frame = window.rendered();
    var index = target;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        assert(index < frame.hit_count);
        const record = &frame.hits[index];
        if (frame.handlerAt(record.on_context_menu)) |handler| {
            _ = invoke(window, handler, event, null, record.id);
            return;
        }
        index = record.parent;
    }
}

fn activates(key: *const input.KeyEvent) bool {
    const modifiers = key.modifiers;
    if (key.is_repeat) return false;
    if (modifiers.cmd or modifiers.ctrl or modifiers.alt) return false;
    return switch (key.key) {
        .@"return", .keypad_enter, .space => true,
        else => false,
    };
}

const FocusPath = struct {
    frame: *const records.Frame,
    next_index: u32,
    focused: bool,
    steps: u32,

    fn init(window: *const Window) FocusPath {
        const frame = window.rendered();
        const focused = findRecord(frame, window.focus);
        if (focused != index_none) {
            return .{ .frame = frame, .next_index = focused, .focused = true, .steps = 0 };
        }
        var path = FocusPath{ .frame = frame, .next_index = 0, .focused = false, .steps = 0 };
        path.next_index = path.nextTopLevel(0);
        return path;
    }

    fn next(self: *FocusPath) ?*const records.HitRecord {
        if (self.next_index == index_none) return null;
        self.steps += 1;
        assert(self.steps <= self.frame.hit_count);
        const record = &self.frame.hits[self.next_index];
        if (self.focused) {
            self.next_index = record.parent;
        } else {
            self.next_index = self.nextTopLevel(self.next_index + 1);
        }
        return record;
    }

    fn nextTopLevel(self: *const FocusPath, start: u32) u32 {
        var index = start;
        while (index < self.frame.hit_count) : (index += 1) {
            if (self.frame.hits[index].parent == index_none) return index;
        }
        return index_none;
    }

    pub fn contains(self: FocusPath, context: u64) bool {
        var path = self;
        while (path.next()) |record| {
            if (record.key_context == context) return true;
        }
        return false;
    }
};

const FoundAction = struct { id: ElementId, handler: handler_mod.Handler };

fn findAction(window: *const Window, key: *const input.KeyEvent) ?FoundAction {
    if (window.keymap.len == 0) return null;
    const start = FocusPath.init(window);
    const action = keymap.match(window.keymap, key, start) orelse return null;
    var path = start;
    while (path.next()) |record| {
        const handler = path.frame.actionHandler(record, action) orelse continue;
        return .{ .id = record.id, .handler = handler };
    }
    return null;
}

fn moveFocus(window: *Window, backward: bool) void {
    const frame = window.rendered();
    const start = frame.modal_hit_start;
    assert(start <= frame.hit_count);
    const count = frame.hit_count - start;
    if (count == 0) return;
    const found = findRecord(frame, window.focus);
    const current = if (found != index_none and found >= start) found - start else index_none;
    var step: u32 = 0;
    var index = if (current == index_none) (if (backward) count - 1 else 0) else current;
    while (step < count) : (step += 1) {
        if (current != index_none or step > 0) {
            index = if (backward) (index + count - 1) % count else (index + 1) % count;
        }
        assert(start + index < frame.hit_count);
        if (frame.hits[start + index].tab_stop) {
            setFocus(window, frame.hits[start + index].id, true);
            return;
        }
    }
}

fn routeCompletion(window: *Window, completion: *const events.Completion) void {
    assert(completion.request_id < window.dialog_handlers.len);
    const slot = &window.dialog_handlers[completion.request_id];
    const handler = slot.* orelse std.debug.panic("completion for unknown request {d}", .{
        completion.request_id,
    });
    slot.* = null;
    _ = invoke(window, handler, null, completion, .root);
}

pub fn routeJob(window: *Window, entry: *const events.JobEntry) void {
    window.assertPhase(.drain);
    const delivery = window.jobs.delivery(entry) orelse return;
    assert(delivery.handler.target.isRoot());
    var effects = handler_mod.Effects.init(null, .root);
    effects.job = delivery;
    call(window, delivery.handler, &effects);
    if (effects.click_request) |id| clickRequested(window, id, null);
    window.jobs.finishDelivery(entry);
    window.render_requested = true;
}

fn invoke(
    window: *Window,
    handler: handler_mod.Handler,
    event: ?*const input.InputEvent,
    completion: ?*const events.Completion,
    current: ElementId,
) bool {
    var effects = handler_mod.Effects.init(event, current);
    effects.completion = completion;
    call(window, handler, &effects);
    if (effects.click_request) |id| clickRequested(window, id, event);
    return effects.propagation_stopped;
}

fn clickRequested(window: *Window, id: ElementId, event: ?*const input.InputEvent) void {
    assert(id.isKeyed());
    const frame = window.rendered();
    const index = findRecord(frame, id);
    if (index == index_none) return;
    assert(index < frame.hit_count);
    const handler = frame.handlerAt(frame.hits[index].on_click) orelse return;
    var effects = handler_mod.Effects.init(event, id);
    call(window, handler, &effects);
    if (effects.click_request != null) std.debug.panic(
        "effects.click from a handler that effects.click ran, in frame {d}",
        .{window.frame_number},
    );
}

fn call(window: *Window, handler: handler_mod.Handler, effects: *handler_mod.Effects) void {
    assert(effects.click_request == null);
    assert(!effects.propagation_stopped);
    effects.clipboard = &window.clipboard;
    effects.store = window.store;
    effects.jobs = &window.jobs;
    effects.rendered = window.rendered();
    effects.focused_id = window.focus;
    effects.gesture_idle = window.drag.phase == .idle and window.capture.id == .root;
    effects.dialogs = .{ .pending = &window.pending_dialog, .slots = window.dialog_handlers };
    handler.call(window.store, effects);
    if (effects.render_requested) window.render_requested = true;
    if (effects.quit_requested) window.quit_requested = true;
    const from_keyboard = if (effects.event) |event| isKeyboard(event) else false;
    switch (effects.focus_request) {
        .none => {},
        .focus => |id| setFocus(window, id, from_keyboard),
        .blur => setFocus(window, .root, false),
    }
    if (effects.file_dialog) |request| requestDialog(window, request);
    if (effects.font_request) |request| requestFont(window, request);
    if (effects.theme_request) |theme| {
        window.theme = theme;
        window.render_requested = true;
    }
    if (effects.announcement) |announcement| {
        window.announcements.push(
            announcement.text,
            announcement.politeness,
            window.frame_number,
        );
        window.render_requested = true;
    }
    if (effects.drag_start) |request| applyDragStart(window, request);
    if (effects.scroll_request) |request| requestScroll(window, request);
}

fn requestScroll(window: *Window, request: handler_mod.Effects.ScrollRequest) void {
    assert(request.id.isKeyed());
    const ScrollState = window_mod.ScrollState;
    const state = window.retained.find(ScrollState, request.id) orelse return;
    state.target = switch (request.target) {
        .start => .start,
        .end => .end,
        .offset => |offset| .{ .offset = offset },
        .child => |child| .{ .child = .{
            .id = request.id.child(child.key),
            .index = if (child.key == .index) child.key.index else null,
            .alignment = child.alignment,
        } },
    };
    window.render_requested = true;
    assert(state.target != null);
}

fn isKeyboard(event: *const input.InputEvent) bool {
    return switch (event.*) {
        .key_down, .key_up, .text_input, .composition => true,
        else => false,
    };
}

pub fn requestFont(window: *Window, request: handler_mod.Effects.FontRequest) void {
    assert(request.size > 0 and request.size < 1000);
    if (request.name.len == 0 or request.name.len > window_mod.PendingFont.name_bytes_max) {
        std.debug.panic("effects.setFont: family name of {d} bytes; 1 to {d} are allowed", .{
            request.name.len,
            window_mod.PendingFont.name_bytes_max,
        });
    }
    var pending: window_mod.PendingFont = .{
        .name_buffer = undefined,
        .name_len = @intCast(request.name.len),
        .size = request.size,
    };
    @memcpy(pending.name_buffer[0..request.name.len], request.name);
    window.pending_font = pending;
    window.render_requested = true;
    assert(window.pending_font.?.name_len == request.name.len);
}

fn requestDialog(window: *Window, request: handler_mod.FileDialogRequest) void {
    const target = request.on_complete.target;
    if (target.isRoot() and target.type_id != window.store.root_type_id) {
        std.debug.panic("file dialog on_complete targets {s}; the root state is {s}", .{
            handler_mod.typeName(target.type_id),
            handler_mod.typeName(window.store.root_type_id),
        });
    }
    assert(window.pending_dialog == null);
    var slot_free_count: u32 = 0;
    for (window.dialog_handlers) |slot| {
        if (slot == null) slot_free_count += 1;
    }
    assert(slot_free_count > 0);
    var copy = request;
    switch (copy.kind) {
        .open => {},
        .save => |*options| copySaveOptions(window, options),
    }
    window.pending_dialog = copy;
}

fn copySaveOptions(window: *Window, options: *handler_mod.SavePromptOptions) void {
    const capacity = window.dialog_request_bytes.len;
    const directory_len = if (options.directory) |directory| directory.len else 0;
    const name_len = if (options.suggested_name) |name| name.len else 0;
    if (directory_len + name_len > capacity) {
        std.debug.panic("file dialog request bytes exhausted: capacity {d} bytes, {d} " ++
            "requested in frame {d}. Raise ResourceLimits.events.dialog_path_bytes_max.", .{
            capacity,
            directory_len + name_len,
            window.frame_number,
        });
    }
    const target = window.dialog_request_bytes;
    if (options.directory) |directory| {
        @memcpy(target[0..directory_len], directory);
        options.directory = target[0..directory_len];
    }
    if (options.suggested_name) |name| {
        @memcpy(target[directory_len..][0..name_len], name);
        options.suggested_name = target[directory_len..][0..name_len];
    }
    assert(directory_len + name_len <= capacity);
}

pub fn setFocus(window: *Window, id: ElementId, visible: bool) void {
    if (window.focus == id and window.focus_visible == visible) return;
    window.focus = id;
    window.focus_visible = visible;
    window.focus_reveal = visible;
    window.render_requested = true;
}

pub fn updateFocusPath(window: *Window) void {
    window.assertPhase(.build);
    window.focus_len = 0;
    if (!window.focus_visible) return;
    const frame = window.rendered();
    const target = findRecord(frame, window.focus);
    if (target == index_none) {
        if (window.focus != .root) window.render_requested = true;
        return;
    }
    window.focus_len = pathOf(frame, target, window.focus_path);
    assert(window.focus_len > 0);
    assert(window.focus_path[0] == window.focus);
}

pub fn updateHover(window: *Window) void {
    const frame = window.rendered();
    var path: [window_mod.box_depth_ceiling]ElementId = undefined;
    var len: u32 = 0;
    var target: u32 = index_none;
    if (window.pointer) |pointer| {
        target = hitIndex(frame, .{ .x = pointer.x, .y = pointer.y });
        var index = target;
        while (index != index_none) : (len += 1) {
            assert(len < window.hover_path.len);
            path[len] = frame.hits[index].id;
            index = frame.hits[index].parent;
        }
    }
    const captured = window.capture.id != .root;
    window.cursor = if (captured) window.capture.cursor else cursorOf(frame, target);
    if (len == 0 and !captured) assert(window.cursor == .default);
    updateOver(window, frame, target);
    const same = len == window.hover_len and
        std.mem.eql(ElementId, path[0..len], window.hover_path[0..len]);
    if (same) return;
    @memcpy(window.hover_path[0..len], path[0..len]);
    window.hover_len = len;
    window.render_requested = true;
}

fn updateOver(window: *Window, frame: *const records.Frame, target: u32) void {
    const drag = &window.drag;
    if (drag.phase != .active) {
        assert(drag.over == .root);
        return;
    }
    if (drag.keyboard) return followKeyboardOver(window, frame);
    const found = dropTargetFrom(frame, target, drag.type_id);
    const over = if (found == index_none) .root else frame.hits[found].id;
    if (over == drag.over) return;
    drag.over = over;
    window.render_requested = true;
}

fn followKeyboardOver(window: *Window, frame: *const records.Frame) void {
    const drag = &window.drag;
    assert(drag.keyboard);
    if (drag.over != .root) {
        const index = findRecord(frame, drag.over);
        if (index != index_none and frame.hits[index].drop_type == drag.type_id) {
            moveKeyboardPoint(window, frame.hits[index].bounds);
            return;
        }
        drag.over = .root;
        setFocus(window, drag.source, true);
        window.render_requested = true;
    }
    const source = findRecord(frame, drag.source);
    if (source != index_none) moveKeyboardPoint(window, frame.hits[source].bounds);
}

fn moveKeyboardPoint(window: *Window, bounds: records.Rect) void {
    const centre = centreOf(bounds);
    const drag = &window.drag;
    if (centre.x == drag.x and centre.y == drag.y) return;
    drag.x = centre.x;
    drag.y = centre.y;
    window.render_requested = true;
}

fn cursorOf(frame: *const records.Frame, index_start: u32) element.CursorShape {
    var index = index_start;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_ceiling);
        if (frame.hits[index].cursor) |cursor| return cursor;
        index = frame.hits[index].parent;
    }
    return .default;
}

pub fn validateFocus(window: *Window) void {
    if (window.focus == .root) return;
    const frame = window.built();
    const index = findRecord(frame, window.focus);
    if (index != index_none) {
        const record = &frame.hits[index];
        if (record.focusable or window.isKeyboardDropTarget(record.id)) {
            if (index >= frame.modal_hit_start) return;
        }
    }
    const successor = focusSuccessor(window.rendered(), frame, window.focus);
    assert(successor != window.focus);
    window.focus = successor;
    if (successor == .root) window.focus_visible = false;
    window.focus_reveal = window.focus_visible;
    window.render_requested = true;
}

const successor_tab_stop_count_max: u32 = 32;
const successor_candidate_count_max: u32 =
    window_mod.box_depth_ceiling + 2 * successor_tab_stop_count_max;

fn focusSuccessor(
    rendered: *const records.Frame,
    built: *const records.Frame,
    lost: ElementId,
) ElementId {
    var candidates: [successor_candidate_count_max]ElementId = undefined;
    const count = successorCandidates(rendered, lost, &candidates);
    assert(count <= candidates.len);
    var best: u32 = count;
    var found: ElementId = .root;
    for (built.hits[built.modal_hit_start..built.hit_count]) |*record| {
        if (!record.focusable) continue;
        const rank = std.mem.indexOfScalar(ElementId, candidates[0..best], record.id) orelse
            continue;
        best = @intCast(rank);
        found = record.id;
        if (best == 0) break;
    }
    if (found != .root) assert(best < count);
    return found;
}

fn successorCandidates(frame: *const records.Frame, lost: ElementId, out: []ElementId) u32 {
    assert(out.len == successor_candidate_count_max);
    const start = findRecord(frame, lost);
    if (start == index_none) return 0;
    var count: u32 = 0;
    var index = frame.hits[start].parent;
    var depth: u32 = 0;
    while (index != index_none) : (index = frame.hits[index].parent) {
        depth += 1;
        assert(depth <= window_mod.box_depth_ceiling);
        if (frame.hits[index].focusable) {
            out[count] = frame.hits[index].id;
            count += 1;
        }
    }
    var tab_stops: u32 = 0;
    index = start + 1;
    while (index < frame.hit_count and tab_stops < successor_tab_stop_count_max) : (index += 1) {
        if (!frame.hits[index].tab_stop) continue;
        out[count] = frame.hits[index].id;
        count += 1;
        tab_stops += 1;
    }
    tab_stops = 0;
    index = start;
    while (index > 0 and tab_stops < successor_tab_stop_count_max) {
        index -= 1;
        if (!frame.hits[index].tab_stop) continue;
        out[count] = frame.hits[index].id;
        count += 1;
        tab_stops += 1;
    }
    assert(count <= out.len);
    return count;
}
