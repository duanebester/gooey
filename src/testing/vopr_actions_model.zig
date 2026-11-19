//! The VOPR's model of the actions example: which action each drain fires
//! last, so `State.message` is known after every drain. It catches what the
//! model-free invariants cannot: a binding that fires outside its key
//! context, an action that misses the focused scope, a chord that matches
//! with the wrong modifiers, or a key an action took that also reached the
//! focused control's own handler or default (a Return that both fired an
//! action and clicked a button would leave the button's message).
//!
//! The model is written from the example's keymap and the contract's key
//! rules, not from the router:
//! - Ctrl+Z is Undo, Ctrl+Shift+Z is Redo, and plain Escape is Cancel,
//!   wherever focus is, nothing focused included: the root box handles
//!   them. Ctrl+S is Save only while focus is inside the "Editor" context,
//!   whose one focusable is the text input. Modifiers match exactly.
//! - A key no action took goes to the focused control: Tab and Shift+Tab
//!   move through tab stops; Return or Space without Ctrl, Cmd, or Alt
//!   clicks a focused button (Undo or Redo). The text input takes edits,
//!   which change no message.
//! - Any press focuses the innermost focusable record under it, or nothing;
//!   only a left press and release over the same button clicks it, unless
//!   the platform cancelled the gesture between them.
//! The VOPR pins Ctrl as the edit modifier, so it drives `AppWith(.ctrl)`.
//!
//! The model checks the message, which shows only the last action of a
//! drain; an action that fired twice for one key leaves the same message
//! and is not caught here.

const std = @import("std");
const gooey = @import("gooey");
const actions = @import("actions_example");
const vopr = @import("vopr.zig");
const vopr_events = @import("vopr_events.zig");
const vopr_frame = @import("vopr_frame.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const input = gooey.input;
const Window = internals.window.Window;
const ElementId = records.ElementId;
const Action = vopr.Action;
const Event = vopr_events.Event;
const Point = vopr_events.Point;

pub const App = actions.AppWith(.ctrl);

/// Actions one drain can hold, as the queue's capacity.
const pending_count_max: u32 = App.limits.events.queue_count_max;
/// Ids one press lands in: one per box on the path to the root.
const press_path_len_max: u32 = internals.window.box_depth_ceiling;

const Message = enum {
    none,
    undo,
    redo,
    cancel,
    save,

    fn text(self: Message) []const u8 {
        return switch (self) {
            .none => "",
            .undo => "Undo!",
            .redo => "Redo!",
            .cancel => "Cancelled!",
            .save => "Saved!",
        };
    }
};

pub const ActionsModel = struct {
    message: Message,
    /// Focus within the drain being applied; read from the window first.
    focus: ElementId,
    /// The ids the last left press landed in, innermost first.
    press_path: [press_path_len_max]ElementId,
    press_len: u32,
    pending: [pending_count_max]Action,
    pending_count: u32,
    counts: Stats,

    /// The kinds actions' swarm draws weights for, in this order.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .text, .compose, .wait_ns, .tick_main, .present, .resize, .cancel,
    };

    /// The bound keys (Z, S, Escape), the keys that click and move focus,
    /// and editing keys for the input.
    pub const key_choices: []const input.KeyCode = &.{
        .z,    .s,    .escape, .@"return", .space, .tab,
        .left, .home, .delete, .a,         .c,     .v,
    };

    pub const Stats = struct {
        /// Fires by action, from keys and from clicks.
        fired: [5]u32,
        /// Ctrl+S pressed with focus outside the editor, so no Save.
        save_outside: u32,

        const zero: Stats = .{ .fired = @splat(0), .save_outside = 0 };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("undo {d}, redo {d}, cancel {d}, save {d}; ctrl+s outside the " ++
                "editor {d}", .{
                self.fired[@backingInt(Message.undo)],
                self.fired[@backingInt(Message.redo)],
                self.fired[@backingInt(Message.cancel)],
                self.fired[@backingInt(Message.save)],
                self.save_outside,
            });
        }
    };

    pub fn init(self: *ActionsModel) void {
        self.message = .none;
        self.focus = .root;
        self.press_len = 0;
        self.pending_count = 0;
        self.counts = .zero;
        assert(std.mem.eql(u8, (actions.State{}).message, Message.none.text()));
    }

    pub fn stats(self: *const ActionsModel) Stats {
        assert(self.pending_count <= pending_count_max);
        return self.counts;
    }

    pub fn pendingRoom(self: *const ActionsModel) u32 {
        assert(self.pending_count <= pending_count_max);
        return pending_count_max - self.pending_count;
    }

    /// Record an input action for the next drain; its text is not read.
    pub fn queue(self: *ActionsModel, action: Action) void {
        assert(self.pending_count < pending_count_max);
        assert(action != .tick_main);
        self.pending[self.pending_count] = action;
        self.pending_count += 1;
    }

    pub fn beginDrain(self: *ActionsModel, window: *Window) void {
        assert(window.phase == .idle);
        self.focus = window.focus;
    }

    pub fn endDrain(self: *ActionsModel, window: *Window, published: bool) void {
        _ = published;
        const frame = window.rendered();
        for (self.pending[0..self.pending_count]) |*action| {
            const events = vopr_events.lower(action);
            for (events.slice()) |*event| self.route(frame, event);
        }
        self.pending_count = 0;
    }

    pub fn check(self: *const ActionsModel, state: *const actions.State, step: u64) void {
        if (std.mem.eql(u8, state.message, self.message.text())) return;
        std.debug.panic("vopr actions model: after step {d} the message is \"{s}\"; the " ++
            "model expects \"{s}\" (focus {x})", .{
            step, state.message, self.message.text(), @backingInt(self.focus),
        });
    }

    /// Where the generator aims: the text input, and a third of the time
    /// the row of buttons.
    pub fn biasTarget(window: *Window) ?vopr.Bias {
        const frame = window.rendered();
        var input_bounds: ?records.Rect = null;
        var buttons: ?records.Rect = null;
        for (frame.a11y[0..frame.a11y_count]) |*node| {
            switch (node.role) {
                .textbox => input_bounds = node.bounds,
                .button => buttons = if (buttons) |row| unite(row, node.bounds) else node.bounds,
                else => {},
            }
        }
        return .{ .area = input_bounds orelse return null, .alternate = buttons };
    }

    fn route(self: *ActionsModel, frame: *const records.Frame, event: *const Event) void {
        switch (event.*) {
            .down => |event_press| self.press(frame, event_press),
            .up => |up| if (up.button == .left) self.release(frame, up.point),
            .key_down => |chord| self.key(frame, chord),
            // A cancelled gesture clicks nothing at its release.
            .pointer_cancelled => self.press_len = 0,
            .moved, .key_up, .other => {},
        }
    }

    fn fire(self: *ActionsModel, message: Message) void {
        assert(message != .none);
        self.message = message;
        self.counts.fired[@backingInt(message)] += 1;
    }

    /// The action the keymap binds `chord` to with the current focus.
    fn boundAction(self: *ActionsModel, frame: *const records.Frame, chord: Action.Chord) ?Message {
        const m = chord.modifiers;
        const ctrl_only = m.ctrl and !m.shift and !m.alt and !m.cmd;
        const ctrl_shift = m.ctrl and m.shift and !m.alt and !m.cmd;
        const plain = !m.ctrl and !m.shift and !m.alt and !m.cmd;
        return switch (chord.key) {
            .z => {
                if (ctrl_only) return .undo;
                if (ctrl_shift) return .redo;
                return null;
            },
            .s => {
                if (!ctrl_only) return null;
                if (self.editorFocused(frame)) return .save;
                self.counts.save_outside += 1;
                return null;
            },
            .escape => if (plain) .cancel else null,
            else => null,
        };
    }

    fn key(self: *ActionsModel, frame: *const records.Frame, chord: Action.Chord) void {
        if (self.boundAction(frame, chord)) |message| return self.fire(message);
        const focused = vopr_frame.findHit(frame, self.focus);
        if (chord.key == .tab) {
            self.focus = vopr_frame.nextTabStop(frame, self.focus, chord.modifiers.shift);
            return;
        }
        const index = focused orelse return;
        const m = chord.modifiers;
        const activates = chord.key == .@"return" or chord.key == .space;
        if (!activates or m.ctrl or m.alt or m.cmd) return;
        if (buttonMessage(frame, index)) |message| self.fire(message);
    }

    /// A press of any button focuses; a left press records its path.
    fn press(self: *ActionsModel, frame: *const records.Frame, event: vopr_events.Press) void {
        const left = event.button == .left;
        if (left) self.press_len = 0;
        var focus_id: ElementId = .root;
        var index = vopr_frame.hitIndex(frame, event.point.x, event.point.y) orelse
            records.index_none;
        var depth: u32 = 0;
        while (index != records.index_none) : (depth += 1) {
            assert(depth < press_path_len_max);
            const record = &frame.hits[index];
            if (focus_id == .root and record.focusable) focus_id = record.id;
            if (left) self.press_path[depth] = record.id;
            index = record.parent;
        }
        if (left) self.press_len = depth;
        self.focus = focus_id;
    }

    /// A left release clicks the innermost `on_click` under it that the
    /// left press also landed in.
    fn release(self: *ActionsModel, frame: *const records.Frame, point: Point) void {
        const pressed = self.press_path[0..self.press_len];
        self.press_len = 0;
        if (pressed.len == 0) return;
        var index = vopr_frame.hitIndex(frame, point.x, point.y) orelse return;
        var depth: u32 = 0;
        while (index != records.index_none) : (depth += 1) {
            assert(depth <= frame.hit_count);
            const record = &frame.hits[index];
            const in_press = std.mem.indexOfScalar(ElementId, pressed, record.id) != null;
            if (in_press and record.on_click != records.index_none) {
                if (buttonMessage(frame, index)) |message| self.fire(message);
                return;
            }
            index = record.parent;
        }
    }

    /// Whether focus is on the editor's text input, the one focusable
    /// inside the "Editor" key context.
    fn editorFocused(self: *const ActionsModel, frame: *const records.Frame) bool {
        const node = vopr_frame.findA11y(frame, self.focus) orelse return false;
        return node.role == .textbox;
    }
};

/// The message a click on record `index` sets: Undo's or Redo's, by the
/// button's accessible name.
fn buttonMessage(frame: *const records.Frame, index: u32) ?Message {
    assert(index < frame.hit_count);
    const record = &frame.hits[index];
    if (record.on_click == records.index_none) return null;
    const node = vopr_frame.findA11y(frame, record.id) orelse return null;
    if (node.role != .button) return null;
    const name = frame.text(node.name) orelse return null;
    if (std.mem.startsWith(u8, name, "Undo")) return .undo;
    if (std.mem.startsWith(u8, name, "Redo")) return .redo;
    std.debug.panic("vopr actions model: a button named \"{s}\"", .{name});
}

fn unite(a: records.Rect, b: records.Rect) records.Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{
        .x = x,
        .y = y,
        .width = @max(a.x + a.width, b.x + b.width) - x,
        .height = @max(a.y + a.height, b.y + b.height) - y,
    };
}
