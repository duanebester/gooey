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

const std = @import("std");
const records = @import("records.zig");
const handler_mod = @import("handler.zig");
const events = @import("events.zig");
const window_mod = @import("window.zig");
const input = @import("../input/mod.zig");
const keymap = @import("keymap.zig");

const assert = std.debug.assert;

const Window = window_mod.Window;
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
        return findAction(self.window, &key) != null;
    }
};

/// The deepest hit record containing `point`, or `index_none`.
fn hitIndex(frame: *const records.Frame, point: Point) u32 {
    assert(frame.hit_count <= frame.hits.len);
    var index = frame.hit_count;
    while (index > 0) {
        index -= 1;
        if (frame.hits[index].bounds.contains(point.x, point.y)) return index;
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
        .timer => window.render_requested = true,
    }
}

fn routeInput(window: *Window, event: *const input.InputEvent) void {
    switch (event.*) {
        .mouse_down => |mouse| {
            const point = pointOf(mouse.position);
            window.pointer = .{ .x = point.x, .y = point.y };
            press(window, event, point);
        },
        .mouse_up => |mouse| {
            const point = pointOf(mouse.position);
            window.pointer = .{ .x = point.x, .y = point.y };
            release(window, event, point);
        },
        .mouse_moved, .mouse_dragged => |mouse| {
            const point = pointOf(mouse.position);
            window.pointer = .{ .x = point.x, .y = point.y };
            updateHover(window);
        },
        .mouse_exited => {
            window.pointer = null;
            updateHover(window);
        },
        .key_down, .key_up, .text_input, .composition => keyToFocus(window, event),
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
    window.press_len = pathOf(frame, target, &window.press_path);
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
    setFocus(window, focus_id);
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

fn bubble(window: *Window, event: *const input.InputEvent, start: u32, slot: Slot) void {
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
            if (invoke(window, handler, event, null, record.id)) return;
        }
        index = record.parent;
    }
}

fn keyToFocus(window: *Window, event: *const input.InputEvent) void {
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
    if (target != index_none) bubble(window, event, target, .key);
    if (event.* == .key_down and event.key_down.key == .tab) {
        // Tab moves focus when no handler claimed it: the key bubbled here.
        moveFocus(window, event.key_down.modifiers.shift);
    }
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

/// Focus the next (or previous) focusable record in tree order, wrapping.
fn moveFocus(window: *Window, backward: bool) void {
    const frame = window.rendered();
    const count = frame.hit_count;
    if (count == 0) return;
    const current = findRecord(frame, window.focus);
    var step: u32 = 0;
    var index = if (current == index_none) (if (backward) count - 1 else 0) else current;
    while (step < count) : (step += 1) {
        if (current != index_none or step > 0) {
            index = if (backward) (index + count - 1) % count else (index + 1) % count;
        }
        if (frame.hits[index].focusable) {
            setFocus(window, frame.hits[index].id);
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

/// Invoke one handler and apply its effects. Returns whether it stopped
/// propagation.
fn invoke(
    window: *Window,
    handler: handler_mod.Handler,
    event: ?*const input.InputEvent,
    completion: ?*const events.Completion,
    current: ElementId,
) bool {
    var effects = handler_mod.Effects.init(event, current);
    effects.completion = completion;
    handler.call(window.store, &effects);
    if (effects.render_requested) window.render_requested = true;
    if (effects.quit_requested) window.quit_requested = true;
    switch (effects.focus_request) {
        .none => {},
        .focus => |id| setFocus(window, id),
        .blur => setFocus(window, .root),
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
    return effects.propagation_stopped;
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
    window.pending_dialog = request;
}

pub fn setFocus(window: *Window, id: ElementId) void {
    if (window.focus == id) return;
    window.focus = id;
    window.render_requested = true;
}

/// Recompute the hover path from the pointer against the rendered frame.
pub fn updateHover(window: *Window) void {
    const frame = window.rendered();
    var path: [window_mod.box_depth_max]ElementId = undefined;
    var len: u32 = 0;
    if (window.pointer) |pointer| {
        var index = hitIndex(frame, .{ .x = pointer.x, .y = pointer.y });
        while (index != index_none) : (len += 1) {
            assert(len < window_mod.box_depth_max);
            path[len] = frame.hits[index].id;
            index = frame.hits[index].parent;
        }
    }
    const same = len == window.hover_len and
        std.mem.eql(ElementId, path[0..len], window.hover_path[0..len]);
    if (same) return;
    @memcpy(window.hover_path[0..len], path[0..len]);
    window.hover_len = len;
    window.render_requested = true;
}

/// Blur a focused element that the frame just built did not render.
pub fn validateFocus(window: *Window) void {
    if (window.focus == .root) return;
    const frame = window.built();
    const index = findRecord(frame, window.focus);
    if (index != index_none and frame.hits[index].focusable) return;
    window.focus = .root;
    window.render_requested = true;
}
