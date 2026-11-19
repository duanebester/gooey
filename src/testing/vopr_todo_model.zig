//! A reference model of the todo example for the VOPR, after TigerBeetle's
//! state checker: what todo should hold (items with text and done flags, the
//! filter, and the draft), updated from every action the harness performs and
//! compared with `app.state` after every step. A mismatch panics with the step
//! and both states.
//!
//! The model is written from todo's intended behaviour, not from its code:
//! - Add appends the draft, trimmed of spaces, then cut to at most 128 bytes
//!   at a codepoint boundary (so a cut item may end in a space), unless it is
//!   blank or the list holds 64 items. Add always empties the draft, even
//!   when it adds nothing, and the next edit starts from the empty draft.
//! - A row's checkbox and Delete act on the item the row showed in the frame
//!   the click landed on, by identity: an item an earlier event removed or
//!   moved is not confused with whichever item now has that index.
//! - The filter buttons set the filter; Clear completed removes done items.
//! - Clicks: the press focuses the innermost focusable record under the
//!   point (or nothing) and the release fires the innermost `on_click`. One
//!   press and release is one click whatever its click count. A press on a
//!   scrollbar with the left button is the scroll box's. Only the left
//!   button clicks: a right or middle press focuses (on a scrollbar too)
//!   and its release clicks nothing. A left press and its release may be
//!   apart, with other actions and other buttons between: the release
//!   clicks the innermost `on_click` under it whose record the left press
//!   also landed in, then forgets that press. Enter or Space without Ctrl
//!   or Alt clicks the focused control; Tab and Shift+Tab move focus
//!   through tab stops in tree order, wrapping.
//! - The draft is edited at the caret by committed text, Backspace, Delete,
//!   arrows, Home, End (Shift extends), Ctrl+A, Ctrl+X, and Ctrl+C. Typing
//!   past the input's capacity keeps the whole codepoints that fit.
//! - IME: preedit is not part of the draft; committed text replaces it at
//!   the caret; an empty composition ends it. When focus leaves mid-
//!   composition the core commits the preedit into the draft at the input's
//!   next build, so the draft is unknown until then.
//!
//! It does not model the core: focus at the start of a drain, the caret,
//! hit records, accessibility names, and scrollbar geometry are read from the
//! window. Events are applied in drain order after each `tickMain`, against
//! the frame the drain routed against (the rendered frame).
//!
//! Where an input's effect is unspecified for todo (a press placing the caret
//! in a non-empty draft, word, line, and undo shortcuts, paste of the
//! harness's empty clipboard, keys during an IME composition) the model marks
//! the draft unknown for the rest of that drain. An unknown draft, and an item
//! added from one, are adopted from the app at the next check only after they
//! pass validation: valid UTF-8 from the generator's alphabet, and for an
//! item, not done, non-empty, at most 128 bytes, and without a leading space.
//! Everything else must match exactly.

const std = @import("std");
const gooey = @import("gooey");
const todo = @import("todo_example");
const vopr = @import("vopr.zig");
const vopr_frame = @import("vopr_frame.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const input = gooey.input;
const Window = internals.window.Window;
const ElementId = records.ElementId;
const InputEngine = internals.text_engine.InputEngine;
const Action = vopr.Action;
const hitIndex = vopr_frame.hitIndex;
const onScrollbar = vopr_frame.onScrollbar;
const nextTabStop = vopr_frame.nextTabStop;
const findHit = vopr_frame.findHit;
const findA11y = vopr_frame.findA11y;

/// Items todo should keep at most.
const item_count_max: u32 = 64;
/// Bytes of one item's text at most.
const item_bytes_max: u32 = 128;
/// The draft's capacity: the input pool's bytes and a line's codepoints.
const draft_bytes_max: u32 = todo.App.limits.text.input.bytes_max;
const draft_codepoint_count_max: u32 = internals.limits.run_codepoint_count_max;
/// Actions one drain can hold. Each queues at least one event, but the core
/// queue folds a move or scroll into the one before it, so a drain can see
/// more actions than events: the harness asks `pendingRoom` before it
/// generates an input, as it asks the queue's room.
const pending_count_max: u32 = todo.App.limits.events.queue_count_max;
const pending_text_bytes_max: u32 = todo.App.limits.events.text_bytes_max;
/// Frames whose rows a click can refer to: the rendered and the built one.
const view_count_max: u32 = 2;
/// Ids one press lands in: one per box on the path to the root.
const press_path_len_max: u32 = internals.window.box_depth_ceiling;

const Point = struct { x: f32, y: f32 };

comptime {
    assert(item_bytes_max <= draft_bytes_max);
    assert(pending_count_max > 0);
}

pub const TodoModel = struct {
    items: [item_count_max]Item,
    item_count: u32,
    /// Identities for items, so a stale row is never confused with another.
    item_id_next: u32,
    filter: todo.Filter,
    /// The draft being edited.
    draft: Draft,
    /// Focus within the drain being applied; read from the window first.
    focus: ElementId,
    composing: bool,
    /// The ids the last press landed in, innermost first, until a release.
    press_path: [press_path_len_max]ElementId,
    press_len: u32,
    pending: [pending_count_max]Action,
    /// Whether each pending click lands on a scrollbar, decided before the
    /// drain: the build after it can move or remove the bar.
    pending_on_scrollbar: [pending_count_max]bool,
    pending_count: u32,
    pending_text: [pending_text_bytes_max]u8,
    pending_text_len: u32,
    /// Rows each recent frame showed, by item id, in order.
    views: [view_count_max]View,
    /// The frame `tickMain` published, whose view `check` records once the
    /// model is reconciled.
    view_frame_pending: ?u64,
    /// The step since which the input's engine has held text other than the
    /// draft, for the report of a mismatch it causes.
    stale_engine_step: ?u64,
    /// The last step whose drain ran a row control from a frame whose row no
    /// longer shows the same item at that position, for a mismatch report.
    stale_row_step: ?u64,
    step_last: u64,

    /// The action kinds todo's swarm draws weights for, in this order; the
    /// order is part of every seed, so it must not change.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .text, .compose, .scroll, .wait_ns, .tick_main, .present, .resize,
    };

    /// Todo's runs report no counts beyond the harness summary.
    pub const Stats = struct {};

    const Item = struct {
        id: u32,
        text: [item_bytes_max]u8,
        len: u32,
        done: bool,
        /// Added from an unknown draft: the app may or may not hold it, and
        /// its text is adopted at the next check.
        maybe: bool,
    };

    const Draft = struct {
        bytes: [draft_bytes_max]u8,
        len: u32,
        known: bool,
        /// Caret and selection end, when known, in bytes.
        caret_known: bool,
        cursor: u32,
        anchor: u32,

        fn text(self: *const Draft) []const u8 {
            assert(self.known);
            return self.bytes[0..self.len];
        }
    };

    const View = struct {
        frame_number: u64,
        ids: [item_count_max]u32,
        /// Where each row's item sat in the list when the frame was built.
        indexes: [item_count_max]u32,
        count: u32,
    };

    const Control = union(enum) {
        add,
        filter: todo.Filter,
        clear_completed,
        toggle: u32,
        delete: u32,
    };

    pub fn init(self: *TodoModel) void {
        self.item_count = 0;
        self.item_id_next = 1;
        self.filter = .all;
        self.draft.len = 0;
        self.draft.known = true;
        self.draft.caret_known = true;
        self.draft.cursor = 0;
        self.draft.anchor = 0;
        self.focus = .root;
        self.composing = false;
        self.press_len = 0;
        self.pending_count = 0;
        self.pending_text_len = 0;
        for (&self.views) |*view| {
            view.* = .{ .frame_number = 0, .ids = undefined, .indexes = undefined, .count = 0 };
        }
        self.view_frame_pending = null;
        self.stale_engine_step = null;
        self.stale_row_step = null;
        self.step_last = 0;
        assert(self.draft.text().len == 0);
    }

    pub fn stats(self: *const TodoModel) Stats {
        assert(self.item_count <= item_count_max);
        return .{};
    }

    /// Input actions the model can still record before the next drain.
    pub fn pendingRoom(self: *const TodoModel) u32 {
        assert(self.pending_count <= pending_count_max);
        return pending_count_max - self.pending_count;
    }

    /// Record an input action delivered to the queue, for the next drain.
    pub fn queue(self: *TodoModel, action: Action) void {
        assert(self.pending_count < pending_count_max);
        var copy = action;
        switch (copy) {
            .text, .compose => |*text| text.* = self.copyText(text.*),
            .pointer, .key, .scroll, .resize => {},
            // Todo's swarm draws no `.drag` (`action_kinds`).
            .wait_ns, .tick_main, .present, .drag => unreachable,
        }
        self.pending[self.pending_count] = copy;
        self.pending_count += 1;
    }

    fn copyText(self: *TodoModel, text: []const u8) []const u8 {
        assert(self.pending_text_len <= self.pending_text.len);
        assert(text.len <= self.pending_text.len - self.pending_text_len);
        const target = self.pending_text[self.pending_text_len..][0..text.len];
        @memcpy(target, text);
        self.pending_text_len += @intCast(text.len);
        return target;
    }

    /// Before `tickMain`: the focus, caret, and composition the drain starts
    /// from are the core's, read from the window.
    pub fn beginDrain(self: *TodoModel, window: *Window) void {
        assert(window.phase == .idle);
        self.focus = window.focus;
        for (self.pending[0..self.pending_count], 0..) |*action, index| {
            self.pending_on_scrollbar[index] = switch (action.*) {
                .pointer => |pointer| onScrollbar(window, pointer.x, pointer.y),
                else => false,
            };
        }
        const engine = findEngine(window) orelse {
            self.composing = false;
            self.draft.caret_known = self.draft.len == 0;
            self.draft.cursor = self.draft.len;
            self.draft.anchor = self.draft.len;
            return;
        };
        self.composing = engine.preedit_len > 0;
        assert(self.draft.known);
        if (self.composing and !self.inputFocused(window.rendered())) {
            // Focus left mid-composition: the core commits the preedit into
            // the draft at the input's next build, which this drain may run.
            self.forgetDraft();
            return;
        }
        if (std.mem.eql(u8, engine.text(), self.draft.text())) {
            self.stale_engine_step = null;
            const text = engine.text();
            if (!isBoundary(text, engine.cursor) or !isBoundary(text, engine.anchor)) {
                std.debug.panic("vopr model: the input's caret {d}..{d} splits a codepoint " ++
                    "of \"{s}\"", .{ engine.anchor, engine.cursor, text });
            }
            self.draft.caret_known = true;
            self.draft.cursor = engine.cursor;
            self.draft.anchor = engine.anchor;
        } else {
            // The app replaced the bound value since the engine last synced,
            // as Add does: editing continues from the end of the new value.
            // A mismatch while this holds names it (`stale_engine_step`).
            if (self.stale_engine_step == null) self.stale_engine_step = self.step_last;
            self.draft.caret_known = true;
            self.draft.cursor = self.draft.len;
            self.draft.anchor = self.draft.len;
        }
        assert(self.draft.cursor <= self.draft.len);
    }

    /// After `tickMain`: apply the drained actions in order against the
    /// frame the drain routed against.
    pub fn endDrain(self: *TodoModel, window: *Window, published: bool) void {
        assert(window.phase == .idle);
        const frame = window.rendered();
        for (self.pending[0..self.pending_count], 0..) |*action, index| {
            self.apply(frame, action, self.pending_on_scrollbar[index]);
        }
        self.pending_count = 0;
        self.pending_text_len = 0;
        if (published) self.view_frame_pending = window.built().frame_number;
    }

    fn apply(
        self: *TodoModel,
        frame: *const records.Frame,
        action: *const Action,
        on_scrollbar: bool,
    ) void {
        switch (action.*) {
            .pointer => |pointer| {
                const point: Point = .{ .x = pointer.x, .y = pointer.y };
                // Only a left press takes a scrollbar. No thumb drag is on
                // then: only the left button starts one, and it is up.
                const takes_scrollbar = on_scrollbar and pointer.button == .left;
                const left = pointer.button == .left;
                if (pointer.releases_held and left) self.release(frame, point);
                switch (pointer.kind) {
                    .move => {},
                    .press => self.press(frame, point, .{
                        .left = left,
                        .scrollbar = takes_scrollbar,
                    }),
                    .release => if (left) self.release(frame, point),
                    .click => {
                        self.press(frame, point, .{ .left = left, .scrollbar = takes_scrollbar });
                        if (left) self.release(frame, point);
                    },
                }
            },
            .key => |chord| self.key(frame, chord),
            .text => |text| {
                if (!self.inputFocused(frame)) return;
                self.composing = false;
                self.insert(text);
            },
            .compose => |text| {
                if (!self.inputFocused(frame)) return;
                // A composition that starts over a selection may replace it.
                if (!self.composing and self.hasSelection()) self.forgetDraft();
                self.composing = text.len > 0;
            },
            // A resize changes the layout, which the model reads from frames.
            .scroll, .resize => {},
            // Todo's swarm draws no `.drag` (`action_kinds`).
            .wait_ns, .tick_main, .present, .drag => unreachable,
        }
    }

    /// A press of any button: focus moves to the innermost focusable record
    /// under it, and the release that follows may click what it landed in.
    /// A left press on a scrollbar is the scroll box's: it lands in nothing.
    /// Only a left press records its path: other buttons click nothing and
    /// leave a left press's path alone, but focus all the same.
    fn press(
        self: *TodoModel,
        frame: *const records.Frame,
        point: Point,
        options: struct { left: bool, scrollbar: bool },
    ) void {
        assert(options.left or !options.scrollbar);
        if (options.left) self.press_len = 0;
        if (options.scrollbar) return;
        const deepest = hitIndex(frame, point.x, point.y) orelse {
            self.moveFocus(.root);
            return;
        };
        var focus_id: ElementId = .root;
        var index = deepest;
        var depth: u32 = 0;
        while (index != records.index_none) : (depth += 1) {
            assert(depth < press_path_len_max);
            const record = &frame.hits[index];
            if (focus_id == .root and record.focusable) focus_id = record.id;
            if (options.left) self.press_path[depth] = record.id;
            index = record.parent;
        }
        if (options.left) self.press_len = depth;
        self.moveFocus(focus_id);
        if (self.inputFocused(frame)) {
            // Where the press puts the caret depends on glyph layout.
            if (self.draft.known and self.draft.len == 0) {
                self.draft.caret_known = true;
            } else {
                self.draft.caret_known = false;
            }
        }
    }

    /// A release of any button fires the innermost `on_click` under it that
    /// the last press also landed in, and forgets that press.
    fn release(self: *TodoModel, frame: *const records.Frame, point: Point) void {
        const pressed = self.press_path[0..self.press_len];
        self.press_len = 0;
        if (pressed.len == 0) return;
        var index = hitIndex(frame, point.x, point.y) orelse return;
        var depth: u32 = 0;
        while (index != records.index_none) : (depth += 1) {
            assert(depth <= frame.hit_count);
            const record = &frame.hits[index];
            const in_press = std.mem.indexOfScalar(ElementId, pressed, record.id) != null;
            if (in_press and record.on_click != records.index_none) {
                self.activate(frame, record.id);
                return;
            }
            index = record.parent;
        }
    }

    /// Focus moving off the input during a composition leaves the draft
    /// unspecified, as does a press inside it.
    fn moveFocus(self: *TodoModel, focus_id: ElementId) void {
        if (self.composing) {
            self.composing = false;
            self.forgetDraft();
        }
        self.focus = focus_id;
        assert(!self.composing);
    }

    fn key(self: *TodoModel, frame: *const records.Frame, chord: Action.Chord) void {
        if (chord.key == .tab) {
            if (self.composing) {
                self.composing = false;
                self.forgetDraft();
            }
            self.focus = nextTabStop(frame, self.focus, chord.modifiers.shift);
            return;
        }
        const focused = findHit(frame, self.focus) orelse return;
        if (self.inputFocused(frame)) {
            if (self.composing) {
                self.forgetDraft();
            } else {
                self.edit(chord);
            }
            return;
        }
        const plain = !chord.modifiers.ctrl and !chord.modifiers.alt and !chord.modifiers.cmd;
        const activates = chord.key == .@"return" or chord.key == .space;
        if (plain and activates and frame.hits[focused].on_click != records.index_none) {
            self.activate(frame, frame.hits[focused].id);
        }
    }

    /// One key on the focused input. Keys whose effect todo does not
    /// specify (word moves, undo, paste) leave the draft unknown.
    fn edit(self: *TodoModel, chord: Action.Chord) void {
        const modifiers = chord.modifiers;
        const plain = !modifiers.shift and !modifiers.ctrl and !modifiers.alt;
        const shift_only = modifiers.shift and !modifiers.ctrl and !modifiers.alt;
        const ctrl_only = modifiers.ctrl and !modifiers.shift and !modifiers.alt;
        if (!self.draft.known) return;
        switch (chord.key) {
            .delete, .forward_delete => {
                if (plain) {
                    self.deleteAtCaret(chord.key == .forward_delete);
                } else {
                    self.forgetDraft();
                }
            },
            .left, .right, .home, .end => {
                if (plain or shift_only) {
                    self.moveCaret(chord.key, modifiers.shift);
                } else {
                    self.draft.caret_known = false;
                }
            },
            .a, .c, .x, .v, .z => {
                if (ctrl_only) {
                    self.shortcut(chord.key);
                } else {
                    // Ctrl with Shift or Alt has no meaning todo specifies.
                    if (modifiers.ctrl) self.forgetDraft();
                }
            },
            .space, .@"return", .tab => {},
            .up, .down, .escape => self.draft.caret_known = false,
            else => {},
        }
    }

    /// Ctrl+A selects all, Ctrl+X cuts the selection, and Ctrl+C copies;
    /// paste (of the harness's empty clipboard) and undo are unspecified.
    fn shortcut(self: *TodoModel, key_code: input.KeyCode) void {
        assert(self.draft.known);
        switch (key_code) {
            .a => {
                self.draft.caret_known = true;
                self.draft.anchor = 0;
                self.draft.cursor = self.draft.len;
            },
            .x => {
                if (!self.draft.caret_known) return self.forgetDraft();
                if (self.hasSelection()) self.replaceSelection("");
            },
            .c => {},
            .v, .z => self.forgetDraft(),
            else => unreachable,
        }
    }

    fn moveCaret(self: *TodoModel, key_code: input.KeyCode, extend: bool) void {
        const draft = &self.draft;
        if (!draft.caret_known) return;
        const text = draft.text();
        const start = @min(draft.cursor, draft.anchor);
        const end = @max(draft.cursor, draft.anchor);
        const target: u32 = switch (key_code) {
            .home => 0,
            .end => draft.len,
            // Without Shift, an arrow collapses a selection to its side.
            .left => if (!extend and start < end) start else previousBoundary(text, draft.cursor),
            .right => if (!extend and start < end) end else nextBoundary(text, draft.cursor),
            else => unreachable,
        };
        draft.cursor = target;
        if (!extend) draft.anchor = target;
        assert(draft.cursor <= draft.len);
        assert(draft.anchor <= draft.len);
    }

    fn deleteAtCaret(self: *TodoModel, forward: bool) void {
        const draft = &self.draft;
        if (!draft.caret_known) return self.forgetDraft();
        if (self.hasSelection()) return self.replaceSelection("");
        const text = draft.text();
        if (forward) {
            draft.anchor = nextBoundary(text, draft.cursor);
        } else {
            draft.anchor = previousBoundary(text, draft.cursor);
        }
        self.replaceSelection("");
    }

    fn insert(self: *TodoModel, text: []const u8) void {
        if (!self.draft.known or !self.draft.caret_known) return self.forgetDraft();
        self.replaceSelection(text);
    }

    /// Replace the selection with what fits of `text`: whole codepoints,
    /// within the input's bytes and a line's codepoints.
    fn replaceSelection(self: *TodoModel, text: []const u8) void {
        const draft = &self.draft;
        assert(draft.known);
        assert(draft.caret_known);
        const start = @min(draft.cursor, draft.anchor);
        const end = @max(draft.cursor, draft.anchor);
        assert(end <= draft.len);
        const kept_len = draft.len - (end - start);
        const codepoints_kept = codepointCount(draft.bytes[0..start]) +
            codepointCount(draft.bytes[end..draft.len]);
        const fits = fittingPrefix(text, .{
            .bytes_room = draft_bytes_max - kept_len,
            .codepoint_room = draft_codepoint_count_max -| codepoints_kept,
        });
        const tail_len = draft.len - end;
        // The tail moves left when the insert is shorter than the selection.
        const tail_target = draft.bytes[start + fits.len ..][0..tail_len];
        if (start + fits.len < end) {
            std.mem.copyForwards(u8, tail_target, draft.bytes[end..draft.len]);
        } else {
            std.mem.copyBackwards(u8, tail_target, draft.bytes[end..draft.len]);
        }
        @memcpy(draft.bytes[start..][0..fits.len], fits);
        draft.len = kept_len + @as(u32, @intCast(fits.len));
        draft.cursor = start + @as(u32, @intCast(fits.len));
        draft.anchor = draft.cursor;
        assert(draft.len <= draft_bytes_max);
    }

    fn hasSelection(self: *const TodoModel) bool {
        return self.draft.caret_known and self.draft.cursor != self.draft.anchor;
    }

    fn forgetDraft(self: *TodoModel) void {
        self.draft.known = false;
        self.draft.caret_known = false;
    }

    fn inputFocused(self: *const TodoModel, frame: *const records.Frame) bool {
        const node = findA11y(frame, self.focus) orelse return false;
        return node.role == .textbox;
    }

    /// Run the control `id` names in `frame`, by its accessibility role and
    /// name; a row's control acts on the item that row showed.
    fn activate(self: *TodoModel, frame: *const records.Frame, id: ElementId) void {
        const control = controlOf(frame, id);
        switch (control) {
            .add => self.add(),
            .filter => |filter| self.filter = filter,
            .clear_completed => {
                var kept: u32 = 0;
                for (self.items[0..self.item_count]) |item| {
                    if (item.done) continue;
                    self.items[kept] = item;
                    kept += 1;
                }
                self.item_count = kept;
            },
            .toggle, .delete => |row| {
                const view = self.viewOf(frame.frame_number);
                if (row < view.count) {} else {
                    std.debug.panic("vopr model: frame {d} shows row {d}, but showed {d} rows", .{
                        frame.frame_number,
                        row,
                        view.count,
                    });
                }
                const index_now = self.itemIndex(view.ids[row]);
                if (index_now != view.indexes[row]) self.stale_row_step = self.step_last;
                const index = index_now orelse return;
                if (control == .toggle) {
                    self.items[index].done = !self.items[index].done;
                } else {
                    self.removeItem(index);
                }
            },
        }
    }

    fn add(self: *TodoModel) void {
        // Add empties the draft. An unknown draft stays unknown: an IME
        // composition the press ended may settle into it after Add runs.
        // The input's engine adopts the emptied draft at its next edit.
        if (!self.draft.known or self.draft.len > 0) {
            if (self.stale_engine_step == null) self.stale_engine_step = self.step_last;
        }
        defer if (self.draft.known) self.clearDraft();
        if (self.item_count == item_count_max) return;
        const item = &self.items[self.item_count];
        item.id = self.item_id_next;
        item.done = false;
        if (!self.draft.known) {
            item.maybe = true;
            item.len = 0;
        } else {
            const value = std.mem.trim(u8, self.draft.text(), " ");
            if (value.len == 0) return;
            const kept = fittingPrefix(value, .{
                .bytes_room = item_bytes_max,
                .codepoint_room = item_bytes_max,
            });
            item.maybe = false;
            @memcpy(item.text[0..kept.len], kept);
            item.len = @intCast(kept.len);
        }
        self.item_id_next += 1;
        self.item_count += 1;
    }

    /// Add empties the draft, and the caret goes to its start.
    fn clearDraft(self: *TodoModel) void {
        assert(self.draft.known);
        self.draft.len = 0;
        self.draft.caret_known = true;
        self.draft.cursor = 0;
        self.draft.anchor = 0;
    }

    fn removeItem(self: *TodoModel, index: u32) void {
        assert(index < self.item_count);
        std.mem.copyForwards(
            Item,
            self.items[index .. self.item_count - 1],
            self.items[index + 1 .. self.item_count],
        );
        self.item_count -= 1;
    }

    fn itemIndex(self: *const TodoModel, id: u32) ?u32 {
        for (self.items[0..self.item_count], 0..) |*item, index| {
            if (item.id == id) return @intCast(index);
        }
        return null;
    }

    fn viewOf(self: *const TodoModel, frame_number: u64) *const View {
        for (&self.views) |*view| {
            if (view.frame_number == frame_number) return view;
        }
        std.debug.panic("vopr model: no rows recorded for frame {d}", .{frame_number});
    }

    /// After every step: reconcile what the model left unknown, then require
    /// the app's state to match. `step` names the step in a mismatch.
    pub fn check(self: *TodoModel, state: *const todo.State, step: u64) void {
        self.step_last = step;
        self.reconcile(state, step);
        var reason_buffer: [160]u8 = undefined;
        if (self.difference(state, &reason_buffer)) |reason| {
            self.fail(state, step, reason);
        }
        self.stale_row_step = null;
        if (self.view_frame_pending) |frame_number| {
            self.recordView(frame_number);
            self.view_frame_pending = null;
        }
    }

    /// Adopt an unknown draft and decide each maybe-item, after validating
    /// what the app holds.
    fn reconcile(self: *TodoModel, state: *const todo.State, step: u64) void {
        if (!self.draft.known) {
            if (!validText(state.draft) or state.draft.len > draft_bytes_max) {
                self.fail(state, step, "the draft is not text the generator typed");
            }
            @memcpy(self.draft.bytes[0..state.draft.len], state.draft);
            self.draft.len = @intCast(state.draft.len);
            self.draft.known = true;
        }
        var app_index: u32 = 0;
        var index: u32 = 0;
        while (index < self.item_count) {
            const item = &self.items[index];
            if (!item.maybe) {
                app_index += 1;
                index += 1;
                continue;
            }
            const fits = app_index < state.count and
                adoptable(&state.todos[app_index], item.done);
            if (fits) {
                const text = state.todos[app_index].bytes[0..state.todos[app_index].len];
                @memcpy(item.text[0..text.len], text);
                item.len = @intCast(text.len);
                item.maybe = false;
                app_index += 1;
                index += 1;
            } else {
                self.removeItem(index);
            }
        }
    }

    /// The first way `state` differs from the model, or null.
    fn difference(self: *const TodoModel, state: *const todo.State, buffer: []u8) ?[]const u8 {
        if (state.count != self.item_count) {
            return std.fmt.bufPrint(buffer, "{d} items, expected {d}", .{
                state.count,
                self.item_count,
            }) catch unreachable;
        }
        for (self.items[0..self.item_count], state.todos[0..state.count], 0..) |*a, *b, i| {
            assert(!a.maybe);
            if (!std.unicode.utf8ValidateSlice(b.bytes[0..b.len])) {
                return std.fmt.bufPrint(buffer, "item {d} is not valid UTF-8", .{i}) catch
                    unreachable;
            }
            if (!std.mem.eql(u8, a.text[0..a.len], b.bytes[0..b.len]) or a.done != b.done) {
                return std.fmt.bufPrint(buffer, "item {d} differs", .{i}) catch unreachable;
            }
        }
        if (state.filter != self.filter) return "the filter differs";
        if (!std.mem.eql(u8, state.draft, self.draft.text())) return "the draft differs";
        return null;
    }

    fn recordView(self: *TodoModel, frame_number: u64) void {
        // Replace the oldest view; frames are recorded in increasing order.
        var oldest = &self.views[0];
        for (&self.views) |*view| {
            if (view.frame_number < oldest.frame_number) oldest = view;
        }
        assert(oldest.frame_number < frame_number);
        oldest.frame_number = frame_number;
        oldest.count = 0;
        for (self.items[0..self.item_count], 0..) |*item, index| {
            if (!visibleUnder(self.filter, item.done)) continue;
            oldest.ids[oldest.count] = item.id;
            oldest.indexes[oldest.count] = @intCast(index);
            oldest.count += 1;
        }
    }

    fn fail(self: *const TodoModel, state: *const todo.State, step: u64, reason: []const u8) void {
        // A cut codepoint is its own finding, whatever else is stale.
        const utf8 = std.mem.endsWith(u8, reason, "valid UTF-8");
        std.debug.print("vopr model: expected\n", .{});
        self.dump();
        std.debug.print("vopr model: app holds\n", .{});
        dumpState(state);
        if (self.stale_row_step) |stale_step| {
            std.debug.print("vopr model: after step {d} a row control ran from a frame " ++
                "built before its item moved in the list\n", .{stale_step});
        }
        if (self.stale_engine_step) |stale_step| {
            std.debug.print("vopr model: the input's engine has held text other than the " ++
                "draft since step {d}; the app replaced the draft and no frame has synced " ++
                "the engine yet\n", .{stale_step});
        }
        std.debug.panic("vopr model: todo state diverged after step {d}: {s}{s}{s}", .{
            step,
            reason,
            if (self.stale_engine_step != null and !utf8) " (input engine stale)" else "",
            if (self.stale_row_step != null and !utf8) " (stale row)" else "",
        });
    }

    fn dump(self: *const TodoModel) void {
        std.debug.print("  filter {t}, draft ", .{self.filter});
        if (self.draft.known) {
            std.debug.print("\"{s}\"\n", .{self.draft.text()});
        } else {
            std.debug.print("unknown\n", .{});
        }
        for (self.items[0..self.item_count], 0..) |*item, index| {
            std.debug.print("  {d}: [{s}] \"{s}\"\n", .{
                index,
                if (item.done) "x" else " ",
                item.text[0..item.len],
            });
        }
    }
};

fn visibleUnder(filter: todo.Filter, done: bool) bool {
    return switch (filter) {
        .all => true,
        .active => !done,
        .done => done,
    };
}

fn dumpState(state: *const todo.State) void {
    std.debug.print("  filter {t}, draft \"{s}\"\n", .{ state.filter, state.draft });
    for (state.todos[0..state.count], 0..) |*item, index| {
        std.debug.print("  {d}: [{s}] \"{s}\"\n", .{
            index,
            if (item.done) "x" else " ",
            item.bytes[0..item.len],
        });
    }
}

/// An item added from an unknown draft is adoptable when it is what Add can
/// produce from typed text (trimmed, non-empty, at most 128 bytes) and has
/// the done flag the model gave it (its row's checkbox may have toggled it).
fn adoptable(item: anytype, done: bool) bool {
    const text = item.bytes[0..item.len];
    if (item.done != done) return false;
    if (text.len == 0 or text.len > item_bytes_max) return false;
    if (text[0] == ' ') return false;
    // Add trims, then cuts: only a cut item may end with a space, and a cut
    // on a codepoint boundary drops at most three bytes of the last one.
    if (text[text.len - 1] == ' ' and text.len + 3 < item_bytes_max) return false;
    return validText(text);
}

/// Valid UTF-8 made only of the generator's alphabet.
fn validText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    var count: u32 = 0;
    while (view.nextCodepointSlice()) |slice| : (count += 1) {
        assert(count < text.len + 1);
        const known = for (vopr.text_alphabet) |unit| {
            if (std.mem.eql(u8, unit, slice)) break true;
        } else false;
        if (!known) return false;
    }
    return true;
}

const Room = struct { bytes_room: u32, codepoint_room: u32 };

/// The longest prefix of `text` of whole codepoints within `room`.
fn fittingPrefix(text: []const u8, room: Room) []const u8 {
    assert(std.unicode.utf8ValidateSlice(text));
    var len: usize = 0;
    var count: u32 = 0;
    while (len < text.len and count < room.codepoint_room) : (count += 1) {
        const size = std.unicode.utf8ByteSequenceLength(text[len]) catch unreachable;
        if (len + size > room.bytes_room) break;
        len += size;
    }
    assert(len <= room.bytes_room);
    return text[0..len];
}

fn codepointCount(text: []const u8) u32 {
    return @intCast(std.unicode.utf8CountCodepoints(text) catch unreachable);
}

fn isBoundary(text: []const u8, offset: u32) bool {
    if (offset > text.len) return false;
    if (offset == text.len) return true;
    return text[offset] & 0xC0 != 0x80;
}

fn previousBoundary(text: []const u8, offset: u32) u32 {
    assert(offset <= text.len);
    if (offset == 0) return 0;
    var index = offset - 1;
    while (index > 0 and text[index] & 0xC0 == 0x80) index -= 1;
    return index;
}

fn nextBoundary(text: []const u8, offset: u32) u32 {
    assert(offset <= text.len);
    if (offset == text.len) return offset;
    const size = std.unicode.utf8ByteSequenceLength(text[offset]) catch unreachable;
    return offset + size;
}

/// What the control `id` is, from its accessibility node: todo's buttons by
/// name, and a row's control by its position among the rows' controls.
fn controlOf(frame: *const records.Frame, id: ElementId) TodoModel.Control {
    const node = findA11y(frame, id) orelse
        std.debug.panic("vopr model: clicked element has no accessibility node", .{});
    const name = frame.text(node.name) orelse "";
    switch (node.role) {
        .checkbox => return .{ .toggle = rowOf(frame, node, .checkbox, null) },
        .button => {
            if (std.mem.eql(u8, name, "Add")) return .add;
            if (std.mem.eql(u8, name, "All")) return .{ .filter = .all };
            if (std.mem.eql(u8, name, "Active")) return .{ .filter = .active };
            if (std.mem.eql(u8, name, "Done")) return .{ .filter = .done };
            if (std.mem.eql(u8, name, "Clear completed")) return .clear_completed;
            if (std.mem.eql(u8, name, "Delete")) {
                return .{ .delete = rowOf(frame, node, .button, "Delete") };
            }
        },
        else => {},
    }
    std.debug.panic("vopr model: clicked an unknown control: {t} \"{s}\"", .{ node.role, name });
}

/// How many nodes of `role` (and `name`) precede `target` in tree order.
fn rowOf(
    frame: *const records.Frame,
    target: *const records.A11yNode,
    role: @TypeOf(target.role),
    name: ?[]const u8,
) u32 {
    var row: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node == target) return row;
        if (node.role != role) continue;
        if (name) |wanted| {
            const actual = frame.text(node.name) orelse continue;
            if (!std.mem.eql(u8, actual, wanted)) continue;
        }
        row += 1;
    }
    unreachable;
}

/// The todo draft's engine, if its input is in the rendered frame.
fn findEngine(window: *Window) ?*const InputEngine {
    const frame = window.rendered();
    const node = for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role == .textbox) break node;
    } else return null;
    const type_id = internals.handler.typeId(InputEngine);
    const slot = window.inputs.slab.find(node.id, type_id) orelse return null;
    return @ptrCast(@alignCast(window.inputs.slab.slotBytes(slot).ptr));
}
