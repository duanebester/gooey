//! The VOPR's model of the text_area example: the field's text, caret,
//! selection, remembered column, and composition after every drain, and
//! the platform clipboard after every copy and cut. It catches what the
//! model-free invariants cannot: a caret one byte off, a vertical move that
//! forgets its column, a join past the line bound that goes through, a paste
//! that drops a line. Each new frame is also checked structurally (`checkBuild`).
//!
//! The rules come from the text engine's documented behaviour (text_engine,
//! the area kind; contract §3 and decision 10), not from its code:
//! - Committed text replaces the selection and ends a composition. An edit
//!   keeps the longest prefix that fits the field's bytes on a codepoint
//!   boundary, then the longest of that which leaves no line over 1,024
//!   codepoints (`line_codepoint_count_max`): every line the edit closes
//!   must fit, and the last also carries the text after the edit. A newline
//!   always fits, so it can split a line. When even an empty insert would
//!   join lines past the bound (deleting a newline between two long lines),
//!   the edit is refused whole, unless the joined line is no longer than
//!   the longer of the two lines it joins (a line the app set past the bound
//!   never grows). A refused edit changes nothing, not even the caret.
//! - Return inserts a newline with any modifiers. Tab is not the field's:
//!   it moves focus. Backspace and Delete remove the selection, or the
//!   codepoint before or after the caret; at the text's ends they do
//!   nothing. Left and Right move by codepoint; without Shift they first
//!   collapse a selection to its side; Ctrl goes to the line's start or end,
//!   Alt to the previous word start or next word start (words split at
//!   space, tab, and newline). Home and End go to the line's start and end,
//!   Ctrl+Home, Ctrl+End, Ctrl+Up, and Ctrl+Down to the text's.
//! - Up and Down move to the line above or below at the remembered byte
//!   column, clamped to that line and moved back to a codepoint start, and
//!   remember the column they started from until any other move or edit. On
//!   the first or last line they do nothing, the selection included.
//!   Shift extends with every move.
//! - Ctrl+A selects all; Ctrl+C copies a selection; Ctrl+X cuts it, unless
//!   the deletion would be refused, when nothing is copied either; Ctrl+V
//!   pastes the clipboard as one edit. A copy in a drain is what a paste
//!   later in that drain reads; the platform holds it after the drain.
//! - While a composition shows, keys go to the IME: the field takes none,
//!   so Tab still moves focus and nothing else happens. A composition
//!   changes no text; an empty one ends it. Focus leaving mid-composition
//!   commits it as typed text at the field's next build.
//! - A left click in the field moves the caret at the next build, to a
//!   point the model does not compute; a key, text, composition, or wheel
//!   the field takes before that build cancels it. The caret is adopted
//!   from the engine at the next drain. Page Up, Page Down, Escape, and
//!   Space change nothing.
//! - Sample and Clear assign the bound value; the field adopts it at the
//!   next event it handles or its next build, whichever comes first: the
//!   text becomes the value, the composition is dropped, the undo history
//!   starts over, and the caret keeps its offsets, clamped and moved back to
//!   a codepoint start. The remembered column is kept.
//!
//! Undo and redo are not modelled step by step: coalescing typed runs is
//! the history's own policy. After one, the text and caret are adopted from
//! the engine at the next drain, and the text must be one the field held
//! since its history last started over (while every state since then is
//! known to the model).
//!
//! Current behaviour, kept as the rules for now (reviewed 2026-11-20):
//! Return inserts a newline with any modifiers, Ctrl+Return included, as
//! the engine ignores modifiers on Return; Up on the first line and Down on
//! the last change nothing, the selection included; Page Up and Page Down
//! change nothing, as the engine does not handle them.

const std = @import("std");
const gooey = @import("gooey");
const text_area = @import("text_area_example");
const vopr = @import("vopr.zig");
const vopr_events = @import("vopr_events.zig");
const vopr_frame = @import("vopr_frame.zig");
const build_checks = @import("vopr_text_area_checks.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const input = gooey.input;
const Window = internals.window.Window;
const ElementId = records.ElementId;
const AreaEngine = internals.text_engine.AreaEngine;
const Action = vopr.Action;
const Point = vopr_events.Point;
const hitIndex = vopr_frame.hitIndex;
const findA11y = vopr_frame.findA11y;
const findHit = vopr_frame.findHit;

const app_limits = text_area.limits;
const bytes_max: u32 = app_limits.text.area.bytes_max;
/// The clipboard holds the largest text kind's bytes (`clipboardBytes`).
const clipboard_bytes_max: u32 = @max(app_limits.text.input.bytes_max, bytes_max);
const preedit_bytes_max: u32 = app_limits.text.preedit_bytes_max;
const line_codepoint_count_max: u32 = internals.limits.run_codepoint_count_max;
const pending_count_max: u32 = app_limits.events.queue_count_max;
const pending_text_bytes_max: u32 = app_limits.events.text_bytes_max;
const press_path_len_max: u32 = internals.window.box_depth_ceiling;
/// Texts the field held since its history started over, by hash. Undo can
/// reach back at most `undo_depth_max` edits, but one edit can be a long
/// typed run, so the ring keeps many more states than edits.
const history_text_count_max: u32 = 8192;

/// A word no line can break at any window width the VOPR draws.
const long_word = "Pneumonoultramicroscopic";

/// What the harness's platform clipboard holds before the first copy:
/// several lines, a tab, and a long word, so a paste is multi-line.
pub const clipboard_seed = "Pasted line one\n\tpasted, indented\n" ++ long_word ++ "\nend";

comptime {
    assert(clipboard_seed.len <= clipboard_bytes_max);
    assert(bytes_max == text_area.notes_bytes_max);
}

pub const TextAreaModel = struct {
    field: Field,
    focus: ElementId,
    /// The ids the last left press landed in, innermost first.
    press_path: [press_path_len_max]ElementId,
    press_len: u32,
    /// A left click in the field whose caret move waits for a build.
    click_pending: bool,
    /// The value Sample or Clear assigned that the field has not adopted.
    assigned: ?[]const u8,
    /// The platform clipboard: the storage behind the window's clipboard
    /// service, which the harness provides in place of a platform's.
    platform: Clip,
    /// What a paste reads now: the platform's text, or this drain's copy.
    clipboard: Clip,
    clipboard_known: bool,
    history: HistoryTexts,
    /// The caret or text changed since the last build, so that build
    /// scrolls the caret's line into view (`TextArea` calls `follow`).
    moved: bool,
    /// An undo or redo ran since the field was last adopted.
    undone: bool,
    pending: [pending_count_max]Action,
    pending_on_scrollbar: [pending_count_max]bool,
    pending_count: u32,
    pending_text: [pending_text_bytes_max]u8,
    pending_text_len: u32,
    counts: Stats,
    step_last: u64,

    /// The kinds text_area's swarm draws weights for, in this order.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key,       .text,    .compose, .scroll,
        .wait_ns, .tick_main, .present, .resize,  .cancel,
    };

    /// Keys that move across lines and pages, edit at line ends, and run the
    /// edit commands, with Tab, Escape, and Space, which the field leaves.
    /// Up and Down appear three times each so runs of vertical moves, which
    /// are what use the remembered column, are common.
    pub const key_choices: []const input.KeyCode = &.{
        .up,     .down,           .up,        .down,      .up,     .down,
        .home,   .end,            .page_up,   .page_down, .left,   .right,
        .delete, .forward_delete, .@"return", .tab,       .escape, .space,
        .a,      .c,              .x,         .v,         .z,
    };

    /// Short units that repeat and collide, a newline, a tab, and a word
    /// longer than any line the preview can wrap it to.
    pub const text_alphabet: []const []const u8 = &.{
        "a", "b", "Z", "1", " ", "\u{e9}", "\n", "\t", long_word,
    };

    pub const Stats = struct {
        newlines: u32,
        vertical_moves: u32,
        /// Vertical moves that used a column remembered from an earlier one.
        columns_remembered: u32,
        /// Edits the line bound cut short, and joins it refused whole.
        line_cuts: u32,
        joins_refused: u32,
        multiline_pastes: u32,
        commits_on_blur: u32,
        undos: u32,
        /// Undos and redos whose text was checked against the history.
        undos_checked: u32,
        resizes_selecting: u32,
        resizes_composing: u32,
        /// The most lines the field held.
        lines_max: u32,
        checks: build_checks.Counts,

        const zero: Stats = .{
            .newlines = 0,
            .vertical_moves = 0,
            .columns_remembered = 0,
            .line_cuts = 0,
            .joins_refused = 0,
            .multiline_pastes = 0,
            .commits_on_blur = 0,
            .undos = 0,
            .undos_checked = 0,
            .resizes_selecting = 0,
            .resizes_composing = 0,
            .lines_max = 0,
            .checks = .zero,
        };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d} newlines, {d} vertical moves ({d} remembered a column), " ++
                "{d} line cuts, {d} joins refused, {d} multi-line pastes, {d} commits on " ++
                "blur, {d} undos ({d} checked), resizes {d} selecting and {d} composing, " ++
                "{d} lines at most; {f}", .{
                self.newlines,          self.vertical_moves,    self.columns_remembered,
                self.line_cuts,         self.joins_refused,     self.multiline_pastes,
                self.commits_on_blur,   self.undos,             self.undos_checked,
                self.resizes_selecting, self.resizes_composing, self.lines_max,
                self.checks,
            });
        }
    };

    const Field = struct {
        bytes: [bytes_max]u8,
        len: u32,
        cursor: u32,
        anchor: u32,
        /// The byte column Up and Down aim for; null after any other move.
        preferred_column: ?u32,
        preedit: [preedit_bytes_max]u8,
        preedit_len: u32,
        /// False when the field adopted an assigned value while its text
        /// was unknown: an equal text keeps the composition, another drops
        /// it. Adopted at the next drain.
        preedit_known: bool,
        /// False after an undo or redo until the next drain adopts the
        /// engine's text; the caret is unknown then too.
        text_known: bool,
        /// False after a click resolves at a build, until the next drain.
        caret_known: bool,

        fn text(self: *const Field) []const u8 {
            assert(self.len <= bytes_max);
            return self.bytes[0..self.len];
        }

        fn selectionStart(self: *const Field) u32 {
            return @min(self.cursor, self.anchor);
        }

        fn selectionEnd(self: *const Field) u32 {
            return @max(self.cursor, self.anchor);
        }

        fn known(self: *const Field) bool {
            return self.text_known and self.caret_known;
        }
    };

    const Clip = struct {
        bytes: [clipboard_bytes_max]u8,
        len: u32,

        fn text(self: *const Clip) []const u8 {
            assert(self.len <= clipboard_bytes_max);
            return self.bytes[0..self.len];
        }

        /// Keep what fits, cut at a codepoint boundary, as the clipboard does.
        fn set(self: *Clip, value: []const u8) void {
            const kept = prefixFitting(value, clipboard_bytes_max);
            @memcpy(self.bytes[0..kept], value[0..kept]);
            self.len = kept;
        }
    };

    /// Hashes of every text the field held since its history started over,
    /// and whether that list is whole: an edit the model could not follow
    /// (after an undo, before the next adoption) leaves a state out.
    const HistoryTexts = struct {
        hashes: [history_text_count_max]u64,
        count: u32,
        complete: bool,

        fn reset(self: *HistoryTexts, value: []const u8) void {
            self.count = 0;
            self.complete = true;
            self.add(value);
        }

        fn add(self: *HistoryTexts, value: []const u8) void {
            if (self.count == history_text_count_max) {
                self.complete = false;
                return;
            }
            self.hashes[self.count] = std.hash.Wyhash.hash(0, value);
            self.count += 1;
        }

        fn contains(self: *const HistoryTexts, value: []const u8) bool {
            const hash = std.hash.Wyhash.hash(0, value);
            return std.mem.indexOfScalar(u64, self.hashes[0..self.count], hash) != null;
        }
    };

    pub fn init(self: *TextAreaModel) void {
        self.field.len = 0;
        self.field.cursor = 0;
        self.field.anchor = 0;
        self.field.preferred_column = null;
        self.field.preedit_len = 0;
        self.field.preedit_known = true;
        self.field.text_known = true;
        self.field.caret_known = true;
        self.focus = .root;
        self.press_len = 0;
        self.click_pending = false;
        self.assigned = null;
        self.platform.set(clipboard_seed);
        self.clipboard.set(clipboard_seed);
        self.clipboard_known = true;
        self.history.reset("");
        self.moved = true;
        self.undone = false;
        self.pending_count = 0;
        self.pending_text_len = 0;
        self.counts = .zero;
        self.step_last = 0;
        assert(self.field.known());
    }

    /// Bind the window's clipboard to `platform`, as a host binds the
    /// system clipboard, so a cut in one drain pastes in a later one.
    pub fn attach(self: *TextAreaModel, window: *Window) void {
        assert(window.clipboard.service == null);
        window.clipboard.service = .{
            .context = self,
            .read = platformRead,
            .write = platformWrite,
        };
    }

    fn platformRead(context: *anyopaque, out: []u8) u32 {
        const self: *TextAreaModel = @ptrCast(@alignCast(context));
        const value = self.platform.text();
        const kept = prefixFitting(value, @intCast(out.len));
        @memcpy(out[0..kept], value[0..kept]);
        return kept;
    }

    fn platformWrite(context: *anyopaque, value: []const u8) void {
        const self: *TextAreaModel = @ptrCast(@alignCast(context));
        assert(value.len > 0);
        self.platform.set(value);
    }

    pub fn stats(self: *const TextAreaModel) Stats {
        assert(self.pending_count <= pending_count_max);
        return self.counts;
    }

    pub fn pendingRoom(self: *const TextAreaModel) u32 {
        assert(self.pending_count <= pending_count_max);
        return pending_count_max - self.pending_count;
    }

    /// Record an input action for the next drain, copying its text.
    pub fn queue(self: *TextAreaModel, action: Action) void {
        assert(self.pending_count < pending_count_max);
        var copy = action;
        switch (copy) {
            .text, .compose => |*value| {
                const target = self.pending_text[self.pending_text_len..][0..value.len];
                @memcpy(target, value.*);
                self.pending_text_len += @intCast(value.len);
                value.* = target;
            },
            .pointer, .key, .scroll, .resize, .cancel => {},
            .wait_ns, .tick_main, .present, .drag => unreachable,
        }
        self.pending[self.pending_count] = copy;
        self.pending_count += 1;
        assert(self.pending_text_len <= pending_text_bytes_max);
    }

    /// Before `tickMain`: focus, the platform clipboard, and anything the
    /// last drain left unknown are read from the window.
    pub fn beginDrain(self: *TextAreaModel, window: *Window) void {
        assert(window.phase == .idle);
        self.focus = window.focus;
        for (self.pending[0..self.pending_count], 0..) |*action, index| {
            self.pending_on_scrollbar[index] = switch (action.*) {
                .pointer => |press_or_click| vopr_frame.onScrollbar(
                    window,
                    press_or_click.x,
                    press_or_click.y,
                ),
                else => false,
            };
        }
        self.clipboard.set(self.platform.text());
        self.clipboard_known = true;
        if (!self.field.known() or !self.field.preedit_known) self.adopt(window);
        assert(self.field.known());
        assert(self.field.preedit_known);
    }

    /// After `tickMain`: apply the drained actions in order against the
    /// frame the drain routed against, then the field's part of the build,
    /// then require the engine and the platform clipboard to match.
    pub fn endDrain(self: *TextAreaModel, window: *Window, published: bool) void {
        assert(window.phase == .idle);
        const frame = window.rendered();
        // Before the first frame there is nothing to route against, and
        // nothing was queued.
        const area_id = areaIdIn(frame) orelse {
            assert(self.pending_count == 0);
            if (published) self.moved = false;
            return;
        };
        const actions = self.pending[0..self.pending_count];
        for (actions, 0..) |*action, index| {
            // The queue folds a scroll into the one before it, keeping the
            // later position: a run of scrolls is one wheel event at the
            // last one's point.
            const folds = action.* == .scroll and index + 1 < actions.len and
                actions[index + 1] == .scroll;
            if (folds) continue;
            self.apply(frame, area_id, action, self.pending_on_scrollbar[index]);
        }
        self.pending_count = 0;
        self.pending_text_len = 0;
        if (self.focus != window.focus) {
            std.debug.panic("vopr text_area model: after step {d} focus is {x}, the model " ++
                "expects {x}", .{
                self.step_last,
                @backingInt(window.focus),
                @backingInt(self.focus),
            });
        }
        if (published) {
            self.build();
            build_checks.checkBuild(window, .{
                .area_id = area_id,
                .moved = self.moved,
                .counts = &self.counts.checks,
            });
            // The build's blink commits after `follow` and ends the move.
            self.commitOnBlur(area_id);
            self.moved = false;
        }
        self.compare(window, area_id);
        if (self.field.text_known) {
            const lines: u32 = @intCast(std.mem.count(u8, self.field.text(), "\n") + 1);
            self.counts.lines_max = @max(self.counts.lines_max, lines);
        }
    }

    /// After every step: the app's bound value is the field's text, or the
    /// value Sample or Clear assigned that the field has not adopted yet.
    pub fn check(self: *TextAreaModel, state: *const text_area.State, step: u64) void {
        self.step_last = step;
        if (!self.field.text_known) return;
        const expected = self.assigned orelse self.field.text();
        if (std.mem.eql(u8, state.notes, expected)) return;
        self.fail("the app's notes differ from the field's text", state.notes, expected);
    }

    /// Where the generator aims half its pointer and wheel actions: the field.
    pub fn biasTarget(window: *Window) ?vopr.Bias {
        const frame = window.rendered();
        const index = findHit(frame, areaId(frame)) orelse return null;
        return .{ .area = frame.hits[index].bounds, .alternate = null };
    }

    fn apply(
        self: *TextAreaModel,
        frame: *const records.Frame,
        area_id: ElementId,
        action: *const Action,
        on_scrollbar: bool,
    ) void {
        switch (action.*) {
            .pointer => |pointer_action| self.pointer(frame, area_id, pointer_action, on_scrollbar),
            .key => |chord| {
                self.keyDown(frame, area_id, chord);
                // The release goes to whatever has focus after the press.
                if (self.focus == area_id) self.sync();
            },
            .text => |value| if (self.focus == area_id) {
                self.sync();
                self.insert(value);
                self.click_pending = false;
            },
            .compose => |value| if (self.focus == area_id) {
                self.sync();
                self.setPreedit(value);
                self.click_pending = false;
            },
            .scroll => |scroll| if (wheelReaches(frame, area_id, scroll)) {
                self.sync();
                self.click_pending = false;
            },
            .resize => {
                if (self.field.preedit_len > 0) self.counts.resizes_composing += 1;
                if (self.field.cursor != self.field.anchor) self.counts.resizes_selecting += 1;
            },
            .cancel => |cancel| {
                if (cancel.kind != .focus_lost) self.press_len = 0;
                // A key a focus loss reports held is released to focus
                // (`pointer_cancelled` reports no keys).
                const releases = cancel.kind != .pointer_cancelled and cancel.key_held != null;
                if (releases and self.focus == area_id) self.sync();
            },
            .wait_ns, .tick_main, .present, .drag => unreachable,
        }
    }

    fn pointer(
        self: *TextAreaModel,
        frame: *const records.Frame,
        area_id: ElementId,
        action: Action.Pointer,
        on_scrollbar: bool,
    ) void {
        const point: Point = .{ .x = action.x, .y = action.y };
        const left = action.button == .left;
        // Only a left press takes a scrollbar; it lands in nothing.
        const scrollbar = on_scrollbar and left;
        if (action.releases_held and left) self.release(frame, area_id, point);
        switch (action.kind) {
            .move => {},
            .press => self.press(frame, point, left, scrollbar),
            .release => if (left) self.release(frame, area_id, point),
            .click => {
                self.press(frame, point, left, scrollbar);
                if (left) self.release(frame, area_id, point);
            },
        }
    }

    /// A press of any button focuses the innermost focusable record under
    /// it, or nothing; only a left press records the path a release clicks.
    fn press(
        self: *TextAreaModel,
        frame: *const records.Frame,
        point: Point,
        left: bool,
        scrollbar: bool,
    ) void {
        assert(left or !scrollbar);
        if (left) self.press_len = 0;
        if (scrollbar) return;
        var focus_id: ElementId = .root;
        var index = hitIndex(frame, point.x, point.y) orelse records.index_none;
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
    /// left press also landed in, and forgets that press.
    fn release(
        self: *TextAreaModel,
        frame: *const records.Frame,
        area_id: ElementId,
        point: Point,
    ) void {
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
                if (record.id == area_id) {
                    self.click_pending = true;
                } else {
                    self.activate(frame, record.id);
                }
                return;
            }
            index = record.parent;
        }
    }

    /// A key to the focused record: the field's own keys when it has focus;
    /// otherwise, or when it leaves the key, Tab moves focus and Enter or
    /// Space clicks a focused button.
    fn keyDown(
        self: *TextAreaModel,
        frame: *const records.Frame,
        area_id: ElementId,
        chord: Action.Chord,
    ) void {
        if (self.focus == area_id) {
            self.sync();
            if (self.applyKey(chord)) {
                self.click_pending = false;
                return;
            }
        }
        if (chord.key == .tab) {
            self.focus = vopr_frame.nextTabStop(frame, self.focus, chord.modifiers.shift);
            return;
        }
        const mods = chord.modifiers;
        const plain = !mods.ctrl and !mods.alt and !mods.cmd;
        const activates = chord.key == .@"return" or chord.key == .space;
        if (!plain or !activates or self.focus == area_id) return;
        const focused = findHit(frame, self.focus) orelse return;
        if (frame.hits[focused].on_click == records.index_none) return;
        self.activate(frame, self.focus);
    }

    /// Sample and Clear assign the bound value; the field adopts it later.
    fn activate(self: *TextAreaModel, frame: *const records.Frame, id: ElementId) void {
        const node = findA11y(frame, id) orelse
            std.debug.panic("vopr text_area: clicked element has no accessibility node", .{});
        const name = frame.text(node.name) orelse "";
        assert(node.role == .button);
        if (std.mem.eql(u8, name, "Sample")) {
            self.assigned = text_area.sample;
        } else {
            if (!std.mem.eql(u8, name, "Clear")) {
                std.debug.panic("vopr text_area: clicked an unknown button \"{s}\"", .{name});
            }
            self.assigned = "";
        }
    }

    /// The field's key handler: whether it took the key, and its effect.
    fn applyKey(self: *TextAreaModel, chord: Action.Chord) bool {
        if (!self.field.preedit_known and self.field.preedit_len > 0) {
            // A sync with the text unknown dropped the composition if the
            // value differed and kept it otherwise, so a key the field
            // takes went to the IME or edited: the field is unknown, and
            // whether its caret moves is too, so this build checks no move.
            if (takesKey(chord)) {
                if (chord.key == .c or chord.key == .x) self.clipboard_known = false;
                self.field.text_known = false;
                self.field.caret_known = false;
                self.history.complete = false;
                self.click_pending = false;
                self.moved = false;
            }
            return false;
        }
        if (self.field.preedit_len > 0) return false;
        if (!takesKey(chord)) return false;
        if (!self.field.known()) {
            // After an undo in this drain, edits cannot be followed.
            if (chord.key == .c or chord.key == .x) self.clipboard_known = false;
            self.field.text_known = false;
            self.field.caret_known = false;
            self.history.complete = false;
            return true;
        }
        const mods = chord.modifiers;
        const command = commandModifier(mods);
        const field = &self.field;
        if (command) {
            switch (chord.key) {
                .a, .c, .x, .v, .z => {
                    self.applyCommand(chord);
                    return true;
                },
                else => {},
            }
        }
        switch (chord.key) {
            .@"return" => {
                self.insert("\n");
                self.counts.newlines += 1;
            },
            .up => if (command) self.moveTo(0, mods.shift) else self.moveLine(false, mods.shift),
            .down => if (command) {
                self.moveTo(field.len, mods.shift);
            } else {
                self.moveLine(true, mods.shift);
            },
            .home => {
                const start = if (command) 0 else lineStart(field.text(), field.cursor);
                self.moveTo(start, mods.shift);
            },
            .end => {
                const end = if (command) field.len else lineEnd(field.text(), field.cursor);
                self.moveTo(end, mods.shift);
            },
            .delete => self.backspace(),
            .forward_delete => self.deleteForward(),
            .left => self.moveHorizontal(false, mods),
            .right => self.moveHorizontal(true, mods),
            else => unreachable, // `takesKey` lists the keys.
        }
        return true;
    }

    fn applyCommand(self: *TextAreaModel, chord: Action.Chord) void {
        const field = &self.field;
        const start = field.selectionStart();
        const end = field.selectionEnd();
        switch (chord.key) {
            .a => {
                field.anchor = 0;
                self.moveTo(field.len, true);
            },
            .c => if (end > start) self.clipboard.set(field.text()[start..end]),
            .x => if (end > start) {
                if (lineFit(field.text(), start, end, "") == null) {
                    self.counts.joins_refused += 1;
                    return;
                }
                self.clipboard.set(field.text()[start..end]);
                self.replace(start, end, "");
            },
            .v => if (self.clipboard.len > 0) {
                const pasted = self.clipboard.text();
                if (std.mem.indexOfScalar(u8, pasted, '\n') != null) {
                    self.counts.multiline_pastes += 1;
                }
                self.replace(start, end, pasted);
            },
            .z => {
                self.counts.undos += 1;
                field.text_known = false;
                field.caret_known = false;
                // Whether it moved the caret depends on the history, so
                // `moved` (a lower bound) is left alone.
                self.undone = true;
            },
            else => unreachable,
        }
    }

    /// Committed text: the composition ends, then the selection is replaced.
    fn insert(self: *TextAreaModel, value: []const u8) void {
        self.field.preedit_len = 0;
        self.field.preedit_known = true;
        if (!self.field.known()) {
            // At a caret the model does not know (a click resolved at this
            // build, or an undo), the text is unknown too.
            self.field.text_known = false;
            self.field.caret_known = false;
            self.history.complete = false;
            return;
        }
        self.replace(self.field.selectionStart(), self.field.selectionEnd(), value);
    }

    fn setPreedit(self: *TextAreaModel, value: []const u8) void {
        assert(value.len <= preedit_bytes_max);
        @memcpy(self.field.preedit[0..value.len], value);
        self.field.preedit_len = @intCast(value.len);
        self.field.preedit_known = true;
    }

    fn backspace(self: *TextAreaModel) void {
        const field = &self.field;
        if (field.cursor != field.anchor) {
            return self.replace(field.selectionStart(), field.selectionEnd(), "");
        }
        if (field.cursor == 0) return;
        self.replace(previousBoundary(field.text(), field.cursor), field.cursor, "");
    }

    fn deleteForward(self: *TextAreaModel) void {
        const field = &self.field;
        if (field.cursor != field.anchor) {
            return self.replace(field.selectionStart(), field.selectionEnd(), "");
        }
        if (field.cursor == field.len) return;
        self.replace(field.cursor, nextBoundary(field.text(), field.cursor), "");
    }

    /// Replace `start..end` with what fits of `value` (the field's bytes,
    /// then the line bound), leaving the caret after it. A refused edit
    /// changes nothing.
    fn replace(self: *TextAreaModel, start: u32, end: u32, value: []const u8) void {
        const field = &self.field;
        assert(field.known());
        assert(start <= end);
        assert(end <= field.len);
        const room = bytes_max - (field.len - (end - start));
        const fits = prefixFitting(value, room);
        const kept = lineFit(field.text(), start, end, value[0..fits]) orelse {
            self.counts.joins_refused += 1;
            return;
        };
        assert(kept <= fits);
        if (kept < fits) self.counts.line_cuts += 1;
        if (start == end and kept == 0) return;
        const tail_len = field.len - end;
        const target = start + kept;
        const tail_target = field.bytes[target..][0..tail_len];
        const tail_source = field.bytes[end..][0..tail_len];
        if (target > end) {
            std.mem.copyBackwards(u8, tail_target, tail_source);
        } else {
            std.mem.copyForwards(u8, tail_target, tail_source);
        }
        @memcpy(field.bytes[start..target], value[0..kept]);
        field.len = target + tail_len;
        field.cursor = target;
        field.anchor = target;
        field.preferred_column = null;
        self.moved = true;
        self.history.add(field.text());
        assert(field.len <= bytes_max);
    }

    fn moveTo(self: *TextAreaModel, target: u32, extend: bool) void {
        const field = &self.field;
        assert(target <= field.len);
        field.cursor = target;
        if (!extend) field.anchor = target;
        field.preferred_column = null;
        self.moved = true;
    }

    fn moveHorizontal(self: *TextAreaModel, forward: bool, mods: input.Modifiers) void {
        const field = &self.field;
        if (!mods.shift and field.cursor != field.anchor) {
            const edge = if (forward) field.selectionEnd() else field.selectionStart();
            return self.moveTo(edge, false);
        }
        const text = field.text();
        const at = field.cursor;
        var target: u32 = undefined;
        if (commandModifier(mods)) {
            target = if (forward) lineEnd(text, at) else lineStart(text, at);
        } else {
            if (mods.alt) {
                target = if (forward) nextWordStart(text, at) else previousWordStart(text, at);
            } else {
                target = if (forward) nextBoundary(text, at) else previousBoundary(text, at);
            }
        }
        self.moveTo(target, mods.shift);
    }

    /// Up or Down at the remembered column (or the caret's), clamped to the
    /// target line and moved back to a codepoint start.
    fn moveLine(self: *TextAreaModel, down: bool, extend: bool) void {
        const field = &self.field;
        const text = field.text();
        const start = lineStart(text, field.cursor);
        const column = field.preferred_column orelse field.cursor - start;
        var target_start: u32 = undefined;
        if (down) {
            const end = lineEnd(text, field.cursor);
            if (end == field.len) return;
            target_start = end + 1;
        } else {
            if (start == 0) return;
            target_start = lineStart(text, start - 1);
        }
        const target_len = lineEnd(text, target_start) - target_start;
        var target = target_start + @min(column, target_len);
        while (target > target_start and !isBoundary(text, target)) target -= 1;
        self.counts.vertical_moves += 1;
        if (field.preferred_column != null) self.counts.columns_remembered += 1;
        self.moveTo(target, extend);
        field.preferred_column = column;
    }

    /// The field adopts what Sample or Clear assigned, if anything.
    fn sync(self: *TextAreaModel) void {
        const value = self.assigned orelse return;
        self.assigned = null;
        const field = &self.field;
        if (field.text_known and std.mem.eql(u8, value, field.text())) return;
        // An unknown text equal to the value keeps the composition and the
        // history; another is replaced. Either way the text is the value.
        if (field.text_known) {
            field.preedit_len = 0;
        } else {
            field.preedit_known = false;
        }
        const kept = prefixFitting(value, bytes_max);
        @memcpy(field.bytes[0..kept], value[0..kept]);
        field.len = kept;
        if (field.caret_known) {
            field.cursor = boundaryAtOrBefore(field.text(), @min(field.cursor, field.len));
            field.anchor = boundaryAtOrBefore(field.text(), @min(field.anchor, field.len));
        }
        // An unknown text that equalled the value would have kept its
        // history and caret, and its view would not follow the caret; so
        // only a text known to differ counts as a move. Either way the text
        // is now the value.
        if (field.text_known) {
            self.history.reset(field.text());
            self.moved = true;
        } else {
            self.history.complete = false;
        }
        field.text_known = true;
    }

    /// The field's render at a build, up to scrolling the caret into view:
    /// it adopts an assigned value and moves the caret to a pending click.
    fn build(self: *TextAreaModel) void {
        self.sync();
        if (self.click_pending) {
            self.click_pending = false;
            self.field.caret_known = false;
            self.moved = true;
        }
    }

    /// The rest of the field's render: a composition commits when focus
    /// has left the field.
    fn commitOnBlur(self: *TextAreaModel, area_id: ElementId) void {
        if (self.focus == area_id) return;
        if (!self.field.preedit_known) {
            // A composition may commit: the text and caret are unknown.
            self.field.text_known = false;
            self.field.caret_known = false;
            self.history.complete = false;
            return;
        }
        if (self.field.preedit_len > 0) {
            self.counts.commits_on_blur += 1;
            var preedit: [preedit_bytes_max]u8 = undefined;
            const len = self.field.preedit_len;
            @memcpy(preedit[0..len], self.field.preedit[0..len]);
            self.insert(preedit[0..len]);
        }
    }

    /// Take what the engine holds where the model lost track, after
    /// checking it is text the generator could have produced and, after an
    /// undo, a text the field held before.
    fn adopt(self: *TextAreaModel, window: *Window) void {
        const engine = findEngine(window);
        const text = engine.text();
        const field = &self.field;
        if (field.text_known) {
            if (!std.mem.eql(u8, text, field.text())) {
                self.fail("the field's text differs from the model's", text, field.text());
            }
        } else {
            if (!validText(text)) self.fail("the field holds text nobody typed", text, "");
            if (self.undone and self.history.complete) {
                if (!self.history.contains(text)) {
                    self.fail("an undo or redo made a text the field never held", text, "");
                }
                self.counts.undos_checked += 1;
            }
            @memcpy(field.bytes[0..text.len], text);
            field.len = @intCast(text.len);
            self.history.add(text);
        }
        if (!isBoundary(text, engine.cursor) or !isBoundary(text, engine.anchor)) {
            self.fail("the caret splits a codepoint", text, "");
        }
        field.cursor = engine.cursor;
        field.anchor = engine.anchor;
        field.preferred_column = engine.preferred_column;
        if (!field.preedit_known) {
            const preedit = engine.preeditText();
            @memcpy(field.preedit[0..preedit.len], preedit);
            field.preedit_len = @intCast(preedit.len);
            field.preedit_known = true;
        }
        field.text_known = true;
        field.caret_known = true;
        self.undone = false;
    }

    /// The engine must hold what the model predicts, and the platform
    /// clipboard what the last copy or cut wrote.
    fn compare(self: *TextAreaModel, window: *Window, area_id: ElementId) void {
        _ = area_id;
        const engine = findEngine(window);
        const field = &self.field;
        const preedit = field.preedit[0..field.preedit_len];
        const preedit_differs = !std.mem.eql(u8, engine.preeditText(), preedit);
        if (field.preedit_known and preedit_differs) {
            self.fail("the composition differs", engine.preeditText(), preedit);
        }
        if (field.text_known and !std.mem.eql(u8, engine.text(), field.text())) {
            self.fail("the field's text differs", engine.text(), field.text());
        }
        if (field.known()) {
            const same = engine.cursor == field.cursor and engine.anchor == field.anchor and
                engine.preferred_column == field.preferred_column;
            if (!same) {
                std.debug.print("vopr text_area: caret {d}..{d} column {?d}, expected " ++
                    "{d}..{d} column {?d}\n", .{
                    engine.anchor, engine.cursor, engine.preferred_column,
                    field.anchor,  field.cursor,  field.preferred_column,
                });
                self.fail("the caret or selection differs", engine.text(), field.text());
            }
        }
        const platform = self.platform.text();
        if (self.clipboard_known and !std.mem.eql(u8, platform, self.clipboard.text())) {
            self.fail("the platform clipboard differs", platform, self.clipboard.text());
        }
    }

    fn fail(
        self: *const TextAreaModel,
        reason: []const u8,
        actual: []const u8,
        expected: []const u8,
    ) noreturn {
        std.debug.print("vopr text_area: actual   \"{s}\"\n", .{actual});
        std.debug.print("vopr text_area: expected \"{s}\"\n", .{expected});
        const field = &self.field;
        std.debug.print("vopr text_area: model caret {d}..{d} column {?d}, composing " ++
            "\"{s}\", text known {}, caret known {}, click pending {}, focus {x}\n", .{
            field.anchor,
            field.cursor,
            field.preferred_column,
            field.preedit[0..field.preedit_len],
            field.text_known,
            field.caret_known,
            self.click_pending,
            @backingInt(self.focus),
        });
        std.debug.panic("vopr text_area model: after step {d}: {s}", .{ self.step_last, reason });
    }
};

/// The keys the field takes, whatever its state (`applyKey`).
fn takesKey(chord: Action.Chord) bool {
    if (commandModifier(chord.modifiers)) {
        switch (chord.key) {
            .a, .c, .x, .v, .z => return true,
            else => {},
        }
    }
    return switch (chord.key) {
        .@"return", .keypad_enter, .up, .down, .home, .end => true,
        .delete, .forward_delete, .left, .right => true,
        else => false,
    };
}

/// Edit commands use Ctrl without Alt: the harness pins `uses_cmd` false.
fn commandModifier(mods: input.Modifiers) bool {
    return mods.ctrl and !mods.alt;
}

/// The wheel goes to the innermost scrollable under the point: the field
/// when the point is in it (it holds no other scrollable).
fn wheelReaches(frame: *const records.Frame, area_id: ElementId, scroll: Action.Scroll) bool {
    var index = hitIndex(frame, scroll.x, scroll.y) orelse return false;
    var depth: u32 = 0;
    while (index != records.index_none) : (depth += 1) {
        assert(depth <= frame.hit_count);
        if (frame.hits[index].id == area_id) return true;
        index = frame.hits[index].parent;
    }
    return false;
}

/// The field's id: its accessibility node is the frame's only text area.
fn areaId(frame: *const records.Frame) ElementId {
    return areaIdIn(frame) orelse
        std.debug.panic("vopr text_area: frame {d} has no text area", .{frame.frame_number});
}

fn areaIdIn(frame: *const records.Frame) ?ElementId {
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role == .textarea) return node.id;
    }
    return null;
}

pub fn findEngine(window: *Window) *const AreaEngine {
    const frame = window.rendered();
    const type_id = internals.handler.typeId(AreaEngine);
    const slot = window.areas.slab.find(areaId(frame), type_id) orelse
        std.debug.panic("vopr text_area: the field has no engine", .{});
    return @ptrCast(@alignCast(window.areas.slab.slotBytes(slot).ptr));
}

/// The longest prefix of `value` of whole codepoints within `room` bytes.
fn prefixFitting(value: []const u8, room: u32) u32 {
    if (value.len <= room) return @intCast(value.len);
    var end = room;
    while (end > 0 and !isBoundary(value, end)) end -= 1;
    return end;
}

/// The bytes of `value` an edit replacing `text[start..end]` keeps under
/// the line bound, or null when it is refused (see the file comment).
pub fn lineFit(text: []const u8, start: u32, end: u32, value: []const u8) ?u32 {
    const line_max = line_codepoint_count_max;
    const head = codepointCount(text[lineStart(text, start)..start]);
    const tail = codepointCount(text[end..lineEnd(text, end)]);
    // Codepoints on the line the kept prefix ends on, and how many of
    // them it added.
    var current = head;
    var added: u32 = 0;
    var kept: u32 = 0;
    while (kept < value.len) {
        if (value[kept] == '\n') {
            current = 0;
            added = 0;
        } else {
            if (current >= line_max) break;
            current += 1;
            added += 1;
        }
        kept = nextBoundary(value, kept);
    }
    while (added > 0 and current + tail > line_max) {
        kept = previousBoundary(value, kept);
        current -= 1;
        added -= 1;
    }
    if (current + tail <= line_max) return kept;
    assert(added == 0);
    const first = codepointCount(text[lineStart(text, start)..lineEnd(text, start)]);
    const last = codepointCount(text[lineStart(text, end)..lineEnd(text, end)]);
    if (current + tail > @max(first, last)) return null;
    return kept;
}

/// Valid UTF-8 made of codepoints the generator, Sample, or the seeded
/// clipboard can put in the field.
fn validText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepointSlice()) |slice| {
        const typed = for (TextAreaModel.text_alphabet) |unit| {
            if (std.mem.indexOf(u8, unit, slice) != null) break true;
        } else false;
        if (typed) continue;
        if (std.mem.indexOf(u8, text_area.sample, slice) != null) continue;
        if (std.mem.indexOf(u8, clipboard_seed, slice) != null) continue;
        return false;
    }
    return true;
}

fn codepointCount(text: []const u8) u32 {
    var count: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

pub fn lineStart(text: []const u8, index: u32) u32 {
    assert(index <= text.len);
    const newline = std.mem.lastIndexOfScalar(u8, text[0..index], '\n') orelse return 0;
    return @intCast(newline + 1);
}

pub fn lineEnd(text: []const u8, index: u32) u32 {
    assert(index <= text.len);
    const newline = std.mem.indexOfScalarPos(u8, text, index, '\n') orelse
        return @intCast(text.len);
    return @intCast(newline);
}

fn isBoundary(text: []const u8, index: u32) bool {
    if (index > text.len) return false;
    if (index == text.len) return true;
    return text[index] & 0xC0 != 0x80;
}

fn boundaryAtOrBefore(text: []const u8, index: u32) u32 {
    assert(index <= text.len);
    var position = index;
    while (!isBoundary(text, position)) position -= 1;
    return position;
}

fn previousBoundary(text: []const u8, index: u32) u32 {
    if (index == 0) return 0;
    return boundaryAtOrBefore(text, index - 1);
}

fn nextBoundary(text: []const u8, index: u32) u32 {
    assert(index <= text.len);
    if (index == text.len) return index;
    var position = index + 1;
    while (!isBoundary(text, position)) position += 1;
    return position;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// The start of the word before `index`, past the spaces before it.
fn previousWordStart(text: []const u8, index: u32) u32 {
    var position = index;
    while (position > 0 and isSpace(text[position - 1])) position -= 1;
    while (position > 0 and !isSpace(text[position - 1])) position -= 1;
    return position;
}

/// The start of the word after `index`: past this word, then its spaces.
fn nextWordStart(text: []const u8, index: u32) u32 {
    var position = index;
    while (position < text.len and !isSpace(text[position])) position += 1;
    while (position < text.len and isSpace(text[position])) position += 1;
    return position;
}
