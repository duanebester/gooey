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

const pending_count_max: u32 = App.limits.events.queue_count_max;
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
    focus: ElementId,
    press_path: [press_path_len_max]ElementId,
    press_len: u32,
    pending: [pending_count_max]Action,
    pending_count: u32,
    composing: bool,
    counts: Stats,

    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .text, .compose, .wait_ns, .tick_main, .present, .resize, .cancel,
    };

    pub const key_choices: []const input.KeyCode = &.{
        .z,    .s,    .escape, .@"return", .space, .tab,
        .left, .home, .delete, .a,         .c,     .v,
    };

    pub const Stats = struct {
        fired: [5]u32,
        save_outside: u32,
        field_history: u32,
        composing_keys: u32,

        const zero: Stats = .{
            .fired = @splat(0),
            .save_outside = 0,
            .field_history = 0,
            .composing_keys = 0,
        };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("undo {d}, redo {d}, cancel {d}, save {d}; ctrl+s outside the " ++
                "editor {d}, field undo or redo {d}, keys while composing {d}", .{
                self.fired[@backingInt(Message.undo)],
                self.fired[@backingInt(Message.redo)],
                self.fired[@backingInt(Message.cancel)],
                self.fired[@backingInt(Message.save)],
                self.save_outside,
                self.field_history,
                self.composing_keys,
            });
        }
    };

    pub fn init(self: *ActionsModel) void {
        self.message = .none;
        self.focus = .root;
        self.press_len = 0;
        self.pending_count = 0;
        self.composing = false;
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

    pub fn queue(self: *ActionsModel, action: Action) void {
        assert(self.pending_count < pending_count_max);
        assert(action != .tick_main);
        self.pending[self.pending_count] = action;
        self.pending_count += 1;
    }

    pub fn beginDrain(self: *ActionsModel, window: *Window) void {
        assert(window.phase == .idle);
        self.focus = window.focus;
        const engine = findEngine(window) orelse {
            self.composing = false;
            return;
        };
        self.composing = engine.preedit_len > 0;
    }

    pub fn endDrain(self: *ActionsModel, window: *Window, published: bool) void {
        _ = published;
        const frame = window.rendered();
        for (self.pending[0..self.pending_count]) |*action| {
            switch (action.*) {
                .text => if (self.editorFocused(frame)) {
                    self.composing = false;
                },
                .compose => |text| if (self.editorFocused(frame)) {
                    self.composing = text.len > 0;
                },
                else => {},
            }
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
            .pointer_cancelled => self.press_len = 0,
            .moved, .key_up, .other => {},
        }
    }

    fn fire(self: *ActionsModel, message: Message) void {
        assert(message != .none);
        self.message = message;
        self.counts.fired[@backingInt(message)] += 1;
    }

    fn boundAction(self: *ActionsModel, frame: *const records.Frame, chord: Action.Chord) ?Message {
        const m = chord.modifiers;
        const ctrl_only = m.ctrl and !m.shift and !m.alt and !m.cmd;
        const ctrl_shift = m.ctrl and m.shift and !m.alt and !m.cmd;
        const plain = !m.ctrl and !m.shift and !m.alt and !m.cmd;
        if (self.editorFocused(frame)) {
            if (self.composing) {
                if (bound(chord)) self.counts.composing_keys += 1;
                return null;
            }
        }
        return switch (chord.key) {
            .z => {
                if (!ctrl_only and !ctrl_shift) return null;
                if (self.editorFocused(frame)) {
                    self.counts.field_history += 1;
                    return null;
                }
                if (ctrl_only) return .undo;
                return .redo;
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

    fn editorFocused(self: *const ActionsModel, frame: *const records.Frame) bool {
        const node = vopr_frame.findA11y(frame, self.focus) orelse return false;
        return node.role == .textbox;
    }
};

fn bound(chord: Action.Chord) bool {
    const m = chord.modifiers;
    const ctrl = m.ctrl and !m.alt and !m.cmd;
    const plain = !m.ctrl and !m.shift and !m.alt and !m.cmd;
    return switch (chord.key) {
        .z => ctrl,
        .s => ctrl and !m.shift,
        .escape => plain,
        else => false,
    };
}

fn findEngine(window: *Window) ?*const internals.text_engine.InputEngine {
    const frame = window.rendered();
    const node = for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role == .textbox) break node;
    } else return null;
    const type_id = internals.handler.typeId(internals.text_engine.InputEngine);
    const slot = window.inputs.slab.find(node.id, type_id) orelse return null;
    return @ptrCast(@alignCast(window.inputs.slab.slotBytes(slot).ptr));
}

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
