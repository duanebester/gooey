//! The VOPR's model of the splitter example: the sidebar's width and the top
//! pane's share, which must follow every drag and key exactly. It catches
//! what the model-free invariants cannot: a capture that leaks to another
//! button, a move delivered after its gesture ended, a cancel that does not
//! restore, or a key that reaches the wrong splitter. Written from the
//! contract's pointer-capture rules, not from the router.

const std = @import("std");
const gooey = @import("gooey");
const splitter = @import("splitter_example");
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

/// Actions one drain can hold, as the queue's capacity.
const pending_count_max: u32 = splitter.App.limits.events.queue_count_max;

const panes_id = ElementId.root.child(.{ .name = "panes" });
const sidebar_splitter_id = panes_id.child(.{ .name = "sidebar splitter" });
const content_id = panes_id.child(.{ .name = "content" });
const top_splitter_id = content_id.child(.{ .name = "top splitter" });

pub const SplitterModel = struct {
    sidebar_width: f32,
    top_share: f32,
    sidebar_width_start: f32,
    top_share_start: f32,
    capture: ?Capture,
    /// Focus within the drain being applied; read from the window first.
    focus: ElementId,
    pending: [pending_count_max]Action,
    pending_count: u32,
    counts: Stats,

    /// The kinds splitter's swarm draws weights for, in this order. No
    /// text: the app has no text input.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .scroll, .wait_ns, .tick_main, .present, .drag, .resize, .cancel,
    };

    /// The splitters' keys, Tab, and Escape, with keys they ignore.
    pub const key_choices: []const input.KeyCode = &.{
        .tab, .escape, .left, .right, .up, .down, .home, .end, .space, .a,
    };

    pub const Stats = struct {
        /// Captures begun by each button.
        captures: [3]u32,
        /// Left captures on a splitter that moved its value.
        drags_moved: u32,
        cancels: u32,
        /// Presses that a capture already on left uncaptured.
        presses_during_capture: u32,
        /// Keys a focused splitter took.
        keys_taken: u32,

        const zero: Stats = .{
            .captures = @splat(0),
            .drags_moved = 0,
            .cancels = 0,
            .presses_during_capture = 0,
            .keys_taken = 0,
        };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("captures left {d} right {d} middle {d}; {d} drags moved, " ++
                "{d} cancels, {d} presses during a capture, {d} keys taken", .{
                self.captures[0],
                self.captures[1],
                self.captures[2],
                self.drags_moved,
                self.cancels,
                self.presses_during_capture,
                self.keys_taken,
            });
        }
    };

    const Capture = struct {
        id: ElementId,
        button: input.MouseButton,
        start: Point,
    };

    const Phase = enum { begin, move, end, cancel };

    pub fn init(self: *SplitterModel) void {
        const state: splitter.State = .{};
        self.sidebar_width = state.sidebar_width;
        self.top_share = state.top_share;
        self.sidebar_width_start = state.sidebar_width_start;
        self.top_share_start = state.top_share_start;
        self.capture = null;
        self.focus = .root;
        self.pending_count = 0;
        self.counts = .zero;
        assert(sidebar_splitter_id != top_splitter_id);
    }

    pub fn stats(self: *const SplitterModel) Stats {
        assert(self.pending_count <= pending_count_max);
        return self.counts;
    }

    pub fn pendingRoom(self: *const SplitterModel) u32 {
        assert(self.pending_count <= pending_count_max);
        return pending_count_max - self.pending_count;
    }

    /// Record an input action for the next drain; its text is not read.
    pub fn queue(self: *SplitterModel, action: Action) void {
        assert(self.pending_count < pending_count_max);
        assert(action != .tick_main);
        self.pending[self.pending_count] = action;
        self.pending_count += 1;
    }

    pub fn beginDrain(self: *SplitterModel, window: *Window) void {
        assert(window.phase == .idle);
        self.focus = window.focus;
    }

    pub fn endDrain(self: *SplitterModel, window: *Window, published: bool) void {
        _ = published;
        const frame = window.rendered();
        for (self.pending[0..self.pending_count]) |*action| {
            const events = vopr_events.lower(action);
            for (events.slice()) |*event| self.route(frame, event);
        }
        self.pending_count = 0;
    }

    pub fn check(self: *const SplitterModel, state: *const splitter.State, step: u64) void {
        if (state.sidebar_width == self.sidebar_width and state.top_share == self.top_share) return;
        std.debug.panic("vopr splitter model: after step {d} the app has sidebar width {d} " ++
            "and top share {d}; the model expects {d} and {d} (capture {?})", .{
            step,               state.sidebar_width, state.top_share,
            self.sidebar_width, self.top_share,      self.capture,
        });
    }

    /// Where the generator aims: the sidebar splitter, and a third of the
    /// time the top one.
    pub fn biasTarget(window: *Window) ?vopr.Bias {
        const frame = window.rendered();
        const sidebar = vopr_frame.findHit(frame, sidebar_splitter_id) orelse return null;
        const top = vopr_frame.findHit(frame, top_splitter_id);
        return .{
            .area = frame.hits[sidebar].bounds,
            .alternate = if (top) |index| frame.hits[index].bounds else null,
        };
    }

    fn route(self: *SplitterModel, frame: *const records.Frame, event: *const Event) void {
        switch (event.*) {
            .moved => |point| if (self.capture != null) self.deliver(frame, .move, point),
            .down => |event_press| self.press(frame, event_press),
            .up => |release| {
                const capture = self.capture orelse return;
                if (capture.button != release.button) return;
                self.deliver(frame, .end, release.point);
                self.capture = null;
            },
            .key_down => |chord| {
                if (chord.key == .escape and self.capture != null) {
                    self.cancel(frame);
                } else {
                    self.key(frame, chord);
                }
            },
            .pointer_cancelled => if (self.capture != null) self.cancel(frame),
            .key_up, .other => {},
        }
    }

    fn cancel(self: *SplitterModel, frame: *const records.Frame) void {
        const capture = self.capture.?;
        self.counts.cancels += 1;
        // A cancel restores the press's value; its point is not read.
        self.deliver(frame, .cancel, capture.start);
        self.capture = null;
    }

    fn press(self: *SplitterModel, frame: *const records.Frame, event: vopr_events.Press) void {
        const point = event.point;
        const deepest = vopr_frame.hitIndex(frame, point.x, point.y);
        if (self.capture != null) self.counts.presses_during_capture += 1;
        var focus_id: ElementId = .root;
        var gesture_id: ?ElementId = null;
        var index = deepest orelse records.index_none;
        var depth: u32 = 0;
        while (index != records.index_none) : (depth += 1) {
            assert(depth <= frame.hit_count);
            const record = &frame.hits[index];
            if (focus_id == .root and record.focusable) focus_id = record.id;
            const captures = record.on_pointer_drag != records.index_none;
            if (gesture_id == null and captures) gesture_id = record.id;
            index = record.parent;
        }
        const starts = self.capture == null and gesture_id != null;
        if (starts) {
            self.capture = .{ .id = gesture_id.?, .button = event.button, .start = point };
            self.counts.captures[@backingInt(event.button)] += 1;
        }
        self.focus = focus_id;
        if (starts) self.deliver(frame, .begin, point);
    }

    fn deliver(self: *SplitterModel, frame: *const records.Frame, phase: Phase, point: Point) void {
        const capture = self.capture.?;
        // Only the left button moves a splitter.
        if (capture.button != .left) return;
        if (capture.id == sidebar_splitter_id) {
            switch (phase) {
                .begin => self.sidebar_width_start = self.sidebar_width,
                .move, .end => self.sidebar_width = std.math.clamp(
                    self.sidebar_width_start + (point.x - capture.start.x),
                    splitter.sidebar_width_min,
                    splitter.sidebar_width_max,
                ),
                .cancel => self.sidebar_width = self.sidebar_width_start,
            }
        } else {
            assert(capture.id == top_splitter_id);
            self.deliverTop(frame, phase, point);
        }
        if (phase == .move and point.x != capture.start.x) self.counts.drags_moved += 1;
    }

    fn deliverTop(
        self: *SplitterModel,
        frame: *const records.Frame,
        phase: Phase,
        point: Point,
    ) void {
        const capture = self.capture.?;
        switch (phase) {
            .begin => self.top_share_start = self.top_share,
            .move, .end => {
                const content = vopr_frame.findHit(frame, content_id) orelse return;
                const free = frame.hits[content].bounds.height - splitter.splitter_size;
                if (free <= 0) return;
                const moved = (point.y - capture.start.y) / free;
                self.top_share = std.math.clamp(
                    self.top_share_start + moved,
                    splitter.share_min,
                    1 - splitter.share_min,
                );
            },
            .cancel => self.top_share = self.top_share_start,
        }
    }

    fn key(self: *SplitterModel, frame: *const records.Frame, chord: Action.Chord) void {
        if (vopr_frame.findHit(frame, self.focus) != null) {
            if (self.splitterKey(chord)) {
                self.counts.keys_taken += 1;
                return;
            }
        }
        if (chord.key == .tab) {
            self.focus = vopr_frame.nextTabStop(frame, self.focus, chord.modifiers.shift);
        }
    }

    /// Whether the focused splitter took `chord`, as `State.sidebarKey` and
    /// `State.topKey` do.
    fn splitterKey(self: *SplitterModel, chord: Action.Chord) bool {
        const shift = chord.modifiers.shift;
        if (self.focus == sidebar_splitter_id) {
            const step: f32 = if (shift) splitter.step_large else splitter.step_small;
            const width = switch (chord.key) {
                .left => self.sidebar_width - step,
                .right => self.sidebar_width + step,
                .home => splitter.sidebar_width_min,
                .end => splitter.sidebar_width_max,
                else => return false,
            };
            self.sidebar_width = std.math.clamp(
                width,
                splitter.sidebar_width_min,
                splitter.sidebar_width_max,
            );
            return true;
        }
        if (self.focus == top_splitter_id) {
            const step: f32 = if (shift) 0.2 else 0.05;
            const share = switch (chord.key) {
                .up => self.top_share - step,
                .down => self.top_share + step,
                .home => splitter.share_min,
                .end => 1 - splitter.share_min,
                else => return false,
            };
            self.top_share = std.math.clamp(share, splitter.share_min, 1 - splitter.share_min);
            return true;
        }
        return false;
    }
};
