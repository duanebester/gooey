//! The VOPR's model of the core_file_dialog example: what its status line
//! and path show, from the input the harness queued and the answers its
//! platform dialogs gave (`vopr_dialogs.zig`). Each of the four buttons asks
//! for a dialog; the core refuses one with `error.DialogBusy` while another
//! request waits for this tick's drain or every dialog slot holds a dialog
//! awaiting its outcome, and the app then shows "A dialog is already open."
//! and keeps its path. Every answer completes into `State.completed`, which
//! overwrites both. The model routes a drain as the core must, in one pass:
//! the outcome a modal dialog returned from `open` last tick (queued then),
//! then the queue in push order, input and answers interleaved, then the
//! ring's answers, which the drain appends after the queue's. Clicks and
//! keys are routed against the frame on screen as the actions model routes
//! them. A selection shows its first path, cut at the last UTF-8 boundary
//! within the app's 512 bytes; the model cuts by decoding codepoints, not by
//! the app's continuation-byte scan. It catches a refusal the core missed or
//! made wrongly, a slot freed late or never, a completion routed to the
//! wrong drain, out of order, or twice, paths the queue or the ring copied
//! wrong, and a cut inside a codepoint.

const std = @import("std");
const gooey = @import("gooey");
const file_dialog = @import("core_file_dialog_example");
const vopr = @import("vopr.zig");
const vopr_dialogs = @import("vopr_dialogs.zig");
const vopr_events = @import("vopr_events.zig");
const vopr_frame = @import("vopr_frame.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const Window = internals.window.Window;
const ElementId = records.ElementId;
const Rect = records.Rect;
const Action = vopr.Action;
const Answer = vopr_dialogs.Answer;
const Event = vopr_events.Event;
const Point = vopr_events.Point;

pub const App = file_dialog.App;
const Dialogs = vopr_dialogs.Dialogs(App.limits.events);

/// The longest path the app keeps (`core_file_dialog.zig`).
const kept_bytes_max: u32 = 512;
/// Items one drain can route from the queue, and answers from the ring:
/// one queue's worth each.
const pending_count_max: u32 = App.limits.events.queue_count_max;
/// Dialogs that can await an outcome at once: the dialog table.
const slot_count_max: u32 = App.limits.events.dialog_count_max;
/// Ids one press lands in: one per box on the path to the root.
const press_path_len_max: u32 = internals.window.box_depth_ceiling;
/// The status a refusal shows (`State.refused`).
const busy_status = "A dialog is already open.";

/// What one completion makes the app show.
const Shown = struct {
    outcome: Answer.Outcome,
    path_count: u32,
    path: [kept_bytes_max]u8,
    path_len: u32,
    /// The first path was longer than the app keeps.
    cut: bool,

    const initial: Shown = .{
        .outcome = .cancelled,
        .path_count = 0,
        .path = @splat(0),
        .path_len = 0,
        .cut = false,
    };

    fn of(outcome: Answer.Outcome, path_count: u32, first: []const u8) Shown {
        var shown: Shown = .initial;
        shown.outcome = outcome;
        shown.path_count = path_count;
        if (outcome == .selected) {
            assert(path_count > 0);
            const kept = keptPrefix(first);
            @memcpy(shown.path[0..kept.len], kept);
            shown.path_len = @intCast(kept.len);
            shown.cut = kept.len < first.len;
        }
        return shown;
    }
};

/// One item of the event queue, in push order: an input action, or an
/// answer through the queue.
const Item = union(enum) {
    input: Action,
    answer: Shown,
};

const Deliveries = struct {
    items: [pending_count_max]Shown,
    count: u32,

    fn push(self: *Deliveries, shown: *const Shown) void {
        assert(self.count < pending_count_max);
        self.items[self.count] = shown.*;
        self.count += 1;
    }
};

pub const FileDialogModel = struct {
    /// The last completion routed, which the path shows; null before one.
    shown: ?Shown,
    /// The status shows a refusal, routed after `shown`.
    refused_last: bool,
    /// The queue the next drain routes, then the ring's answers.
    pending: [pending_count_max]Item,
    pending_count: u32,
    ringed: Deliveries,
    /// The outcome a modal dialog returned from `open`, which the tick
    /// queued for the next drain; its dialog holds its slot until then.
    carried: ?Shown,
    /// Dialogs awaiting an outcome, each holding a slot.
    slots_held: u32,
    /// A request routed in this drain, which the tick opens after it.
    requested: bool,
    opened_before: u32,
    /// Focus within the drain being routed; read from the window first.
    focus: ElementId,
    /// The ids the last left press landed in, innermost first.
    press_path: [press_path_len_max]ElementId,
    press_len: u32,
    /// Bytes of the status the app must show, formatted by the model.
    status_bytes: [64]u8,
    counts: Stats,

    /// The kinds file_dialog's swarm draws weights for, in this order.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .wait_ns, .tick_main, .present, .resize, .dialog,
    };

    /// Keys that move focus along the buttons and press them.
    pub const key_choices: []const gooey.input.KeyCode = &.{
        .tab, .space, .@"return", .escape,
    };

    /// Path lengths in bytes: short ones, ones either side of the app's
    /// 512-byte cut, and long ones that fill the dialog's budget.
    pub const dialog_path_lengths: []const u32 = &.{
        1, 9, 40, 509, 510, 511, 512, 513, 514, 515, 900, App.limits.events.dialog_path_bytes_max,
    };

    pub const Stats = struct {
        completions: u32,
        selected: u32,
        selected_many: u32,
        cancelled: u32,
        failed: u32,
        paths_cut: u32,
        /// Drains that routed more than one completion.
        drains_shared: u32,
        requested: u32,
        /// Requests refused while another waited for the tick.
        refused_waiting: u32,
        /// Requests refused while every slot was held.
        refused_full: u32,
        opened: u32,
        answered_at_open: u32,
        open_max: u32,

        const zero: Stats = std.mem.zeroes(Stats);

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d} requests: {d} opened (at most {d} open, {d} answered at " ++
                "open), {d} refused while one waited, {d} refused with every slot held; " ++
                "{d} completions: {d} selected ({d} of several paths, {d} cut), {d} " ++
                "cancelled, {d} failed; {d} drains routed more than one", .{
                self.requested,        self.opened,          self.open_max,
                self.answered_at_open, self.refused_waiting, self.refused_full,
                self.completions,      self.selected,        self.selected_many,
                self.paths_cut,        self.cancelled,       self.failed,
                self.drains_shared,
            });
        }
    };

    pub fn init(self: *FileDialogModel) void {
        self.shown = null;
        self.refused_last = false;
        self.pending_count = 0;
        self.ringed.count = 0;
        self.carried = null;
        self.slots_held = 0;
        self.requested = false;
        self.opened_before = 0;
        self.focus = .root;
        self.press_len = 0;
        self.status_bytes = @splat(0);
        self.counts = .zero;
        const state: file_dialog.State = .{};
        assert(state.status_len == 0);
        assert(state.path_len == 0);
    }

    pub fn stats(self: *const FileDialogModel) Stats {
        assert(self.pending_count <= pending_count_max);
        assert(self.slots_held <= slot_count_max);
        return self.counts;
    }

    /// Room for one more item in the queue or answer on the ring.
    pub fn pendingRoom(self: *const FileDialogModel) u32 {
        assert(self.pending_count <= pending_count_max);
        assert(self.ringed.count <= pending_count_max);
        return pending_count_max - @max(self.pending_count, self.ringed.count);
    }

    /// Record an action for the next drain. An answer armed for the next
    /// dialog shows nothing until that dialog opens.
    pub fn queue(self: *FileDialogModel, action: Action) void {
        assert(action != .tick_main);
        const answer = switch (action) {
            .dialog => |answer| answer,
            else => return self.pushItem(.{ .input = action }),
        };
        const first = if (answer.outcome == .selected) firstPath(answer.paths) else "";
        const shown = Shown.of(answer.outcome, answer.path_count, first);
        switch (answer.route) {
            .queue => self.pushItem(.{ .answer = shown }),
            .ring => self.ringed.push(&shown),
            .at_open => {},
        }
    }

    pub fn beginDrain(self: *FileDialogModel, window: *Window) void {
        assert(window.phase == .idle);
        assert(!self.requested);
        self.focus = window.focus;
        const dialogs = dialogsOf(window);
        self.opened_before = dialogs.opened_count;
        // A modal outcome the last tick queued leads the queue.
        if (self.carried != null) {
            assert(window.queue.count > 0);
            assert(window.queue.pending()[0] == .completion);
        }
    }

    /// Route the drain as the core does, then account for the dialog the
    /// tick opened after it, if a request was granted.
    pub fn endDrain(self: *FileDialogModel, window: *Window, published: bool) void {
        assert(window.queue.count <= 1);
        const frame = window.rendered();
        const completions_before = self.counts.completions;
        if (self.carried) |*carried| {
            self.complete(carried);
            self.carried = null;
        }
        for (self.pending[0..self.pending_count]) |*item| switch (item.*) {
            .input => |*action| {
                const events = vopr_events.lower(action);
                for (events.slice()) |*event| self.route(frame, event);
            },
            .answer => |*shown| self.complete(shown),
        };
        for (self.ringed.items[0..self.ringed.count]) |*shown| self.complete(shown);
        self.pending_count = 0;
        self.ringed.count = 0;
        if (self.counts.completions - completions_before > 1) self.counts.drains_shared += 1;
        self.openRequested(dialogsOf(window), published);
    }

    pub fn check(self: *FileDialogModel, state: *const file_dialog.State, step: u64) void {
        const status_expected = self.status();
        const path_expected: []const u8 = if (self.shown) |*shown|
            shown.path[0..shown.path_len]
        else
            "";
        const status_actual = state.status_bytes[0..state.status_len];
        const path_actual = state.path_bytes[0..state.path_len];
        if (std.mem.eql(u8, status_actual, status_expected) and
            std.mem.eql(u8, path_actual, path_expected)) return;
        std.debug.panic("vopr file_dialog model: after step {d} the app shows \"{s}\" " ++
            "\"{s}\"; the model expects \"{s}\" \"{s}\" ({d} slots held)", .{
            step,          status_actual,   path_actual, status_expected,
            path_expected, self.slots_held,
        });
    }

    /// Where the generator aims: the row of buttons.
    pub fn biasTarget(window: *Window) ?vopr.Bias {
        const frame = window.rendered();
        var buttons: ?Rect = null;
        for (frame.a11y[0..frame.a11y_count]) |*node| {
            if (node.role != .button) continue;
            buttons = if (buttons) |row| unite(row, node.bounds) else node.bounds;
        }
        return .{ .area = buttons orelse return null, .alternate = null };
    }

    fn pushItem(self: *FileDialogModel, item: Item) void {
        assert(self.pending_count < pending_count_max);
        self.pending[self.pending_count] = item;
        self.pending_count += 1;
    }

    /// The tick opened the drain's granted request, if any: it stays open
    /// or returns its outcome, which the tick queues for the next drain.
    fn openRequested(self: *FileDialogModel, dialogs: *const Dialogs, published: bool) void {
        if (!self.requested) {
            assert(dialogs.opened_count == self.opened_before);
            assert(dialogs.delivered_at_open == null);
            return;
        }
        self.requested = false;
        assert(dialogs.opened_count == self.opened_before + 1);
        assert(self.slots_held < slot_count_max);
        self.slots_held += 1;
        self.counts.opened = dialogs.opened_count;
        self.counts.open_max = dialogs.open_count_peak;
        const delivered = dialogs.delivered_at_open orelse return;
        assert(!published);
        self.counts.answered_at_open += 1;
        self.carried = Shown.of(delivered.outcome, delivered.path_count, delivered.first);
    }

    /// A button asks for a dialog: the core grants the drain's first
    /// request while a slot is free and refuses the rest.
    fn activate(self: *FileDialogModel) void {
        assert(self.slots_held <= slot_count_max);
        self.counts.requested += 1;
        if (self.requested) {
            self.counts.refused_waiting += 1;
            self.refused_last = true;
            return;
        }
        if (self.slots_held == slot_count_max) {
            self.counts.refused_full += 1;
            self.refused_last = true;
            return;
        }
        self.requested = true;
    }

    /// A completion frees its dialog's slot and shows its outcome.
    fn complete(self: *FileDialogModel, shown: *const Shown) void {
        assert(self.slots_held > 0);
        self.slots_held -= 1;
        self.shown = shown.*;
        self.refused_last = false;
        self.counts.completions += 1;
        switch (shown.outcome) {
            .selected => {
                self.counts.selected += 1;
                if (shown.path_count > 1) self.counts.selected_many += 1;
                if (shown.cut) self.counts.paths_cut += 1;
            },
            .cancelled => self.counts.cancelled += 1,
            .failed => self.counts.failed += 1,
        }
    }

    fn route(self: *FileDialogModel, frame: *const records.Frame, event: *const Event) void {
        switch (event.*) {
            .down => |down| self.press(frame, down),
            .up => |up| if (up.button == .left) self.release(frame, up.point),
            .key_down => |chord| self.key(frame, chord),
            .pointer_cancelled => self.press_len = 0,
            .moved, .key_up, .other => {},
        }
    }

    /// Tab moves focus; Enter or Space without Cmd, Ctrl, or Alt presses
    /// the focused button (`router.activates`).
    fn key(self: *FileDialogModel, frame: *const records.Frame, chord: Action.Chord) void {
        if (chord.key == .tab) {
            self.focus = vopr_frame.nextTabStop(frame, self.focus, chord.modifiers.shift);
            return;
        }
        const index = vopr_frame.findHit(frame, self.focus) orelse return;
        const m = chord.modifiers;
        const activates = chord.key == .@"return" or chord.key == .space;
        if (!activates or m.ctrl or m.alt or m.cmd) return;
        if (isButton(frame, index)) self.activate();
    }

    /// A press of any button focuses; a left press records its path.
    fn press(self: *FileDialogModel, frame: *const records.Frame, down: vopr_events.Press) void {
        const left = down.button == .left;
        if (left) self.press_len = 0;
        var focus_id: ElementId = .root;
        var index = vopr_frame.hitIndex(frame, down.point.x, down.point.y) orelse
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
    fn release(self: *FileDialogModel, frame: *const records.Frame, point: Point) void {
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
                if (isButton(frame, index)) self.activate();
                return;
            }
            index = record.parent;
        }
    }

    /// The status the app formats, written here from its strings: empty
    /// (the app shows its placeholder) before any completion or refusal.
    fn status(self: *FileDialogModel) []const u8 {
        if (self.refused_last) return busy_status;
        const shown = self.shown orelse return "";
        return switch (shown.outcome) {
            .selected => if (shown.path_count == 1)
                "Selected:"
            else
                std.fmt.bufPrint(&self.status_bytes, "Selected {d} paths; the first:", .{
                    shown.path_count,
                }) catch unreachable, // At most 1,024 paths: 34 of 64 bytes.
            .cancelled => "Cancelled.",
            .failed => "The dialog failed.",
        };
    }
};

fn dialogsOf(window: *Window) *const Dialogs {
    const service = window.file_dialog.?;
    return @ptrCast(@alignCast(service.context));
}

/// Whether record `index` is one of the app's buttons, every one of which
/// asks for a dialog.
fn isButton(frame: *const records.Frame, index: u32) bool {
    assert(index < frame.hit_count);
    const record = &frame.hits[index];
    if (record.on_click == records.index_none) return false;
    const node = vopr_frame.findA11y(frame, record.id) orelse return false;
    assert(node.role == .button);
    return true;
}

fn firstPath(paths: []const u8) []const u8 {
    assert(paths.len > 0);
    const end = std.mem.indexOfScalar(u8, paths, gooey.internals.events.Paths.separator) orelse
        paths.len;
    assert(end > 0);
    return paths[0..end];
}

/// The longest prefix of whole codepoints within `kept_bytes_max` bytes.
fn keptPrefix(path: []const u8) []const u8 {
    assert(std.unicode.utf8ValidateSlice(path));
    var view = std.unicode.Utf8View.initUnchecked(path).iterator();
    var end: usize = 0;
    // Each turn takes one codepoint of `path`.
    while (view.nextCodepointSlice()) |codepoint| {
        if (end + codepoint.len > kept_bytes_max) break;
        end += codepoint.len;
    }
    assert(end <= kept_bytes_max);
    return path[0..end];
}

fn unite(a: Rect, b: Rect) Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{
        .x = x,
        .y = y,
        .width = @max(a.x + a.width, b.x + b.width) - x,
        .height = @max(a.y + a.height, b.y + b.height) - y,
    };
}
