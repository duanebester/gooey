//! The router: hit testing, focus, hover, and handler dispatch for every
//! event kind, plus the read-only `Query` (contract §5).
//!
//! Every event is routed against the rendered frame: the frame the user is
//! looking at. Pointer events hit-test (the deepest hit record containing
//! the point, which is the last in pre-order); key, text, and composition
//! events go to the focused element. Both then bubble through `parent` links
//! until a handler stops propagation. Each handler is invoked with `Effects`,
//! which the router applies after the handler returns.
//!
//! Work per event is bounded: a hit test or click-outside scan visits at most
//! `records.hit_record_count_frame_max` records, and a bubble at most the box
//! depth. A press focuses and runs click-outside handlers; the click fires
//! on release, over a record the press also landed in (decision 7).
//!
//! A key no handler stopped has a default, as in a browser: Tab moves focus,
//! and Enter or Space runs the focused record's `on_click` (0.4.2), one more
//! handler per key. `effects.click` adds one record search and one handler
//! per handler that asks. Focus the keyboard moved is `focus_visible`, which
//! draws the focus ring in emit.

const std = @import("std");
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
const PointerDrag = handler_mod.Effects.PointerDrag;
const ElementId = records.ElementId;
const index_none = records.index_none;

pub const Point = struct { x: f32, y: f32 };

/// Synchronous, read-only questions a platform must answer before its
/// callback returns (`firstRectForCharacterRange`, `performKeyEquivalent`).
/// Reads only the rendered frame; it cannot mutate state, invoke handlers,
/// or re-enter the core.
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

    pub fn imeSelectedRange(self: *const Query) ?records.TextRange {
        const ime = self.window.rendered().ime orelse return null;
        assert(ime.selected_start <= ime.selected_end);
        return .{ .offset = ime.selected_start, .len = ime.selected_end - ime.selected_start };
    }

    /// Whether a keymap binding names an action that an element on the
    /// focus path handles, so the drain will consume `key` (contract §5).
    pub fn keymapClaims(self: *const Query, key: input.KeyEvent) bool {
        assert(self.window.phase != .build);
        if (debugger.isToggle(&key)) return true;
        return findAction(self.window, &key) != null;
    }
};

/// The deepest hit record containing `point`, or `index_none`. Records
/// below the last modal fragment are never hit (contract §6), and records
/// of `pointer_events = .none` boxes let the point through to earlier ones.
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

/// Route one drained event. Runs in the drain phase on the main thread.
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
            press(window, event, point);
        },
        .mouse_up => |mouse| {
            const point = pointOf(mouse.position);
            window.pointer = .{ .x = point.x, .y = point.y };
            if (window.scroll_drag != .root) endScrollDrag(window);
            if (window.capture.id != .root and window.capture.button == mouse.button) {
                finishCapture(window, event, .end, point);
            }
            release(window, event, point);
        },
        // An entry carries a real position: AppKit holds back the entry of
        // a drag that left the window and delivers it as the first move
        // after the release, so dropping it would leave the hover and the
        // cursor of the drag in place.
        .mouse_moved, .mouse_dragged, .mouse_entered => |mouse| {
            const point = pointOf(mouse.position);
            window.pointer = .{ .x = point.x, .y = point.y };
            if (window.scroll_drag != .root) dragScrollbar(window, point);
            if (window.capture.id != .root) moveCapture(window, event, point);
            updateHover(window);
            debugger.pointerMoved(window);
        },
        .mouse_exited => {
            window.pointer = null;
            updateHover(window);
            debugger.pointerMoved(window);
        },
        .key_down => |key| {
            // Escape cancels a capture and goes no further, as a drag's does.
            if (key.key == .escape and window.capture.id != .root) {
                finishCapture(window, event, .cancel, capturePoint(window));
            } else {
                keyToFocus(window, event);
            }
        },
        .key_up, .text_input, .composition => keyToFocus(window, event),
        .scroll => |scroll| wheel(window, event, pointOf(scroll.position)),
        .pointer_cancelled => {
            if (window.scroll_drag != .root) endScrollDrag(window);
            if (window.capture.id != .root) {
                finishCapture(window, event, .cancel, capturePoint(window));
            }
            window.press_len = 0;
        },
        else => {},
    }
}

fn pointOf(position: anytype) Point {
    const point = Point{ .x = @floatCast(position.x), .y = @floatCast(position.y) };
    assert(std.math.isFinite(point.x));
    assert(std.math.isFinite(point.y));
    return point;
}

/// A press: click-outside handlers and focus now; the click itself fires on
/// release (decision 7), so the press records the path it landed on.
fn press(window: *Window, event: *const input.InputEvent, point: Point) void {
    const frame = window.rendered();
    const target = hitIndex(frame, point);
    if (pressScrollbar(window, target, point)) return;
    window.press_len = pathOf(frame, target, &window.press_path);
    // A second button pressed during a capture clicks as usual but does
    // not take the capture over.
    const capturing = if (window.capture.id == .root) captureIndex(frame, target) else index_none;
    if (capturing != index_none) {
        window.capture = .{
            .id = frame.hits[capturing].id,
            .button = event.mouse_down.button,
            .start_x = point.x,
            .start_y = point.y,
            .moved = false,
            .cursor = cursorOf(frame, target),
        };
    }
    clickOutside(window, event, target);
    var focus_id: ElementId = .root;
    var index = target;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_max);
        if (frame.hits[index].focusable) {
            focus_id = frame.hits[index].id;
            break;
        }
        index = frame.hits[index].parent;
    }
    setFocus(window, focus_id, false);
    if (capturing != index_none) deliverCapture(window, event, .begin, point);
}

/// A release: click handlers bubbling from the record under the pointer,
/// limited to records the press also landed in. Pressing one button and
/// releasing over another clicks neither; releasing over the pressed
/// button's child clicks the button.
fn release(window: *Window, event: *const input.InputEvent, point: Point) void {
    const pressed = window.press_path[0..window.press_len];
    defer window.press_len = 0;
    if (pressed.len == 0) return;
    const frame = window.rendered();
    var index = hitIndex(frame, point);
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_max);
        const record = &frame.hits[index];
        if (std.mem.indexOfScalar(ElementId, pressed, record.id) != null) {
            if (frame.handlerAt(record.on_click)) |handler| {
                if (invoke(window, handler, event, null, record.id)) return;
            }
        }
        index = record.parent;
    }
}

/// The innermost record on the press path with `Box.on_pointer_drag`.
fn captureIndex(frame: *const records.Frame, target: u32) u32 {
    var index = target;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_max);
        if (frame.hits[index].on_pointer_drag != index_none) return index;
        index = frame.hits[index].parent;
    }
    return index_none;
}

/// A capture's pointer move. Past `click_slop_px` from the press the
/// gesture is a drag, so its release clicks nothing.
fn moveCapture(window: *Window, event: *const input.InputEvent, point: Point) void {
    const capture = &window.capture;
    assert(capture.id.isKeyed());
    if (!capture.moved) {
        const dx = point.x - capture.start_x;
        const dy = point.y - capture.start_y;
        const slop = Capture.click_slop_px;
        if (dx * dx + dy * dy > slop * slop) {
            capture.moved = true;
            window.press_len = 0;
        }
    }
    deliverCapture(window, event, .move, point);
}

/// End a capture with `end` or `cancel`, then resolve the cursor from what
/// is under the pointer again.
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

/// Where a capture ends that no pointer event ends: the last pointer
/// position, or the press when the pointer has left the window.
fn capturePoint(window: *const Window) Point {
    assert(window.capture.id.isKeyed());
    const pointer = window.pointer orelse
        return .{ .x = window.capture.start_x, .y = window.capture.start_y };
    return .{ .x = pointer.x, .y = pointer.y };
}

/// Call the capturing record's `on_pointer_drag` with one step, from the
/// frame on screen. A box that stopped rendering, or no longer has the
/// handler, ends the capture with no call: nothing is left to tell.
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

/// A press on a scroll box's scrollbar drags its thumb or jumps along its
/// track, and is consumed: no click, focus, or click-outside, as in 0.3.1.
/// The innermost scroll box whose bar is under the pointer takes it.
fn pressScrollbar(window: *Window, target: u32, point: Point) bool {
    assert(window.scroll_drag == .root);
    const frame = window.rendered();
    var index = target;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_max);
        const record = &frame.hits[index];
        if (record.scroll) {
            if (window.retained.find(window_mod.ScrollState, record.id)) |state| {
                if (state.press(point.x, point.y)) {
                    if (state.dragging != null) window.scroll_drag = record.id;
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

/// The dragged box stops dragging if it stopped rendering, which retired
/// its state.
fn dragScrollbar(window: *Window, point: Point) void {
    assert(window.scroll_drag.isKeyed());
    const state = window.retained.find(window_mod.ScrollState, window.scroll_drag) orelse {
        window.scroll_drag = .root;
        return;
    };
    assert(state.dragging != null);
    if (state.drag(point.x, point.y)) window.render_requested = true;
}

/// The release ends the drag and redraws the thumb in its resting colour.
fn endScrollDrag(window: *Window) void {
    assert(window.scroll_drag.isKeyed());
    if (window.retained.find(window_mod.ScrollState, window.scroll_drag)) |state| {
        state.dragging = null;
    }
    window.scroll_drag = .root;
    window.render_requested = true;
}

/// The ids from `index` up to the root; returns the count written.
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
        // Every click-outside handler runs; one cannot stop another.
        _ = invoke(window, frame.handlerAt(record.on_click_outside).?, event, null, record.id);
    }
}

fn isAncestorOrSelf(frame: *const records.Frame, ancestor: u32, index_start: u32) bool {
    var index = index_start;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_max);
        if (index == ancestor) return true;
        index = frame.hits[index].parent;
    }
    return false;
}

const Slot = enum { click, key };

/// Returns whether a handler stopped propagation.
fn bubble(window: *Window, event: *const input.InputEvent, start: u32, slot: Slot) bool {
    const frame = window.rendered();
    var index = start;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_max);
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

/// The wheel scrolls the innermost scrollable under the pointer: a text area
/// or editor through its key handler, as 0.3.1 scrolled them, or a
/// `Style.scroll` box through its retained offset. A box already at its end
/// passes the wheel to the boxes around it, as 0.3.1's nested scroll
/// containers do; a wheel nothing can take is dropped.
fn wheel(window: *Window, event: *const input.InputEvent, point: Point) void {
    assert(event.* == .scroll);
    const frame = window.rendered();
    const area_type = handler_mod.typeId(text_engine.AreaEngine);
    const editor_type = handler_mod.typeId(text_engine.EditorEngine);
    var index = hitIndex(frame, point);
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_max);
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

/// Returns whether the box's offset moved. The rendered frame's records
/// outlive the box only if it stopped rendering, which retires its state.
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
            // A handled action consumes the key, whether or not it stops
            // propagation: there is nothing further for it to reach.
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
    // The defaults for a key no handler claimed, as a browser's: Tab moves
    // focus, and Enter or Space clicks the element the key was sent to,
    // which a handler may have moved focus away from.
    const key = &event.key_down;
    assert(target < frame.hit_count);
    if (key.key == .tab) {
        moveFocus(window, key.modifiers.shift);
    } else {
        if (activates(key)) {
            if (frame.handlerAt(frame.hits[target].on_click)) |handler| {
                _ = invoke(window, handler, event, null, frame.hits[target].id);
            }
        }
    }
}

/// Enter or Space without Cmd, Ctrl, or Alt, and not a repeat: one click
/// per press, as a native button gives.
fn activates(key: *const input.KeyEvent) bool {
    const modifiers = key.modifiers;
    if (key.is_repeat) return false;
    if (modifiers.cmd or modifiers.ctrl or modifiers.alt) return false;
    return switch (key.key) {
        .@"return", .keypad_enter, .space => true,
        else => false,
    };
}

/// The focus path for keys, innermost first: the focused record and its
/// ancestors, or with nothing focused the top-level records in tree order.
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

    /// For `keymap.match`: whether a record on the path has the context.
    pub fn contains(self: FocusPath, context: u64) bool {
        var path = self;
        while (path.next()) |record| {
            if (record.key_context == context) return true;
        }
        return false;
    }
};

const FoundAction = struct { id: ElementId, handler: handler_mod.Handler };

/// The handler a key press resolves to through the keymap, if any.
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

/// Focus the next (or previous) tab stop in tree order, wrapping, among the
/// records a modal leaves reachable (contract §6): Tab never reaches a
/// control the pointer cannot, so Enter cannot click it. A focusable record
/// that is not a tab stop, such as a Select's option, is left to its
/// control's keys.
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
    assert(completion.request_id < window_mod.dialog_count_max);
    const slot = &window.dialog_handlers[completion.request_id];
    const handler = slot.* orelse std.debug.panic("completion for unknown request {d}", .{
        completion.request_id,
    });
    slot.* = null;
    _ = invoke(window, handler, null, completion, .root);
}

/// Invoke one handler and apply its effects, then the click it requested,
/// if any. Returns whether the handler stopped propagation.
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

/// `effects.click`: the clicked element's `on_click`, from the frame on
/// screen. Not recursive: a click it requests in turn is a programmer error.
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

/// Run one handler and apply every request but a click, which `invoke`
/// applies after it.
fn call(window: *Window, handler: handler_mod.Handler, effects: *handler_mod.Effects) void {
    assert(effects.click_request == null);
    assert(!effects.propagation_stopped);
    effects.clipboard = &window.clipboard;
    effects.store = window.store;
    effects.rendered = window.rendered();
    handler.call(window.store, effects);
    if (effects.render_requested) window.render_requested = true;
    if (effects.quit_requested) window.quit_requested = true;
    // Focus a handler moves for a key shows its ring, as Tab's does.
    const from_keyboard = if (effects.event) |event| isKeyboard(event) else false;
    switch (effects.focus_request) {
        .none => {},
        .focus => |id| setFocus(window, id, from_keyboard),
        .blur => setFocus(window, .root, false),
    }
    if (effects.file_dialog) |request| requestDialog(window, request);
    if (effects.font_request) |request| requestFont(window, request);
    if (effects.theme_request) |theme| {
        // Only build reads the theme, on this thread, so the swap is safe
        // with a frame in flight; the clear colour follows at that build.
        window.theme = theme;
        window.render_requested = true;
    }
    if (effects.announcement) |announcement| {
        window.announcements.push(announcement.text, announcement.politeness);
        window.render_requested = true;
    }
}

fn isKeyboard(event: *const input.InputEvent) bool {
    return switch (event.*) {
        .key_down, .key_up, .text_input, .composition => true,
        else => false,
    };
}

/// Copy a font change for the tick to apply (`tick.applyFont`). A name past
/// `family_name_bytes_max` is a programmer error, named here.
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
    if (window.pending_dialog != null) {
        std.debug.panic("a second file dialog was requested in frame {d}; one opens per tick", .{
            window.frame_number,
        });
    }
    var copy = request;
    switch (copy.kind) {
        .open => {},
        .save => |*options| copySaveOptions(window, options),
    }
    window.pending_dialog = copy;
}

/// Copy a save request's folder and name into the window, since the
/// handler's strings may live in its frame. Both share one bounded buffer.
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

/// `visible` draws the focused element's ring: focus moved by keyboard.
pub fn setFocus(window: *Window, id: ElementId, visible: bool) void {
    if (window.focus == id and window.focus_visible == visible) return;
    window.focus = id;
    window.focus_visible = visible;
    window.focus_reveal = visible;
    window.render_requested = true;
}

/// Recompute the hover path from the pointer against the rendered frame.
pub fn updateHover(window: *Window) void {
    const frame = window.rendered();
    var path: [window_mod.box_depth_max]ElementId = undefined;
    var len: u32 = 0;
    // Resolved even when the path is unchanged: a new frame may give the
    // same records another cursor. A capture keeps the cursor of its press.
    var target: u32 = index_none;
    if (window.pointer) |pointer| {
        target = hitIndex(frame, .{ .x = pointer.x, .y = pointer.y });
        var index = target;
        while (index != index_none) : (len += 1) {
            assert(len < window_mod.box_depth_max);
            path[len] = frame.hits[index].id;
            index = frame.hits[index].parent;
        }
    }
    const captured = window.capture.id != .root;
    window.cursor = if (captured) window.capture.cursor else cursorOf(frame, target);
    if (len == 0 and !captured) assert(window.cursor == .default);
    const same = len == window.hover_len and
        std.mem.eql(ElementId, path[0..len], window.hover_path[0..len]);
    if (same) return;
    @memcpy(window.hover_path[0..len], path[0..len]);
    window.hover_len = len;
    window.render_requested = true;
}

/// The innermost cursor set on `index` or its ancestors, as `Box.cursor`
/// did in 0.3.1; `.default` when none sets one or `index` is none.
fn cursorOf(frame: *const records.Frame, index_start: u32) element.CursorShape {
    var index = index_start;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth <= window_mod.box_depth_max);
        if (frame.hits[index].cursor) |cursor| return cursor;
        index = frame.hits[index].parent;
    }
    return .default;
}

/// Move focus off an element that the frame just built did not render, no
/// longer lets focus, or that a modal opened over: keys must not reach what
/// the pointer cannot. Focus passes to its successor (`focusSuccessor`), so
/// the next Tab continues from where it was, and keeps its ring.
pub fn validateFocus(window: *Window) void {
    if (window.focus == .root) return;
    const frame = window.built();
    const index = findRecord(frame, window.focus);
    if (index != index_none and frame.hits[index].focusable) {
        if (index >= frame.modal_hit_start) return;
    }
    const successor = focusSuccessor(window.rendered(), frame, window.focus);
    assert(successor != window.focus);
    window.focus = successor;
    if (successor == .root) window.focus_visible = false;
    window.focus_reveal = window.focus_visible;
    window.render_requested = true;
}

/// Tab stops tried on each side of a lost focus (`focusSuccessor`).
const successor_tab_stop_count_max: u32 = 32;
const successor_candidate_count_max: u32 =
    window_mod.box_depth_max + 2 * successor_tab_stop_count_max;

/// Where focus goes when `lost` leaves: in the frame on screen, its nearest
/// focusable ancestor, such as the combobox of an option chosen with the
/// pointer; else the next tab stop after it, such as the next row's control
/// after a deleted row's; else the previous one. The first of these that
/// `built` still renders, focusable and reachable past its modal, wins.
/// None is `.root`. One pass over `built`'s records against at most
/// `successor_candidate_count_max` ids, run only when focus is lost.
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

/// `focusSuccessor`'s candidates in order of preference. Returns the count.
fn successorCandidates(frame: *const records.Frame, lost: ElementId, out: []ElementId) u32 {
    assert(out.len == successor_candidate_count_max);
    const start = findRecord(frame, lost);
    if (start == index_none) return 0;
    var count: u32 = 0;
    var index = frame.hits[start].parent;
    var depth: u32 = 0;
    while (index != index_none) : (index = frame.hits[index].parent) {
        depth += 1;
        assert(depth <= window_mod.box_depth_max);
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
