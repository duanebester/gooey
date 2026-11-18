//! A reference model of the drag_drop example for the VOPR: which list holds
//! each item, in what order, updated from every action the harness performs
//! and compared with `app.state` after every step. A mismatch panics with the
//! step and both states.
//!
//! The model is written from drag_drop's intended behaviour (its doc comment
//! and contract §5), not from its code:
//! - Every item is in exactly one list, with no duplicates, checked on the
//!   app's own state every step before it is compared.
//! - A drop moves the item to the end of the target list, keeping the order
//!   of the rest of both lists; a drop on the item's own list moves it to
//!   that list's end (`State.dropOn`: "as 0.3.1 did").
//! - A pointer drag is armed by a press on a card and starts once the
//!   pointer is more than `click_slop_px` from the press; a release over a
//!   list drops the card's payload there, a release anywhere else drops
//!   nothing, and a release before it started is a click (cards and lists
//!   have no click handler, so nothing changes). Escape cancels it.
//! - From the keyboard, Space (Shift allowed; not Ctrl, Alt, or Cmd) on a
//!   focused card picks it up and announces it. During the drag every key
//!   is the drag's: Tab and the arrows choose the next or previous list in
//!   tree order, from the chosen list or else the card, and focus it; Space
//!   or Enter drops on the chosen list, focuses it, and announces "<item>
//!   moved to <list>"; over no list they do nothing; Escape cancels and
//!   focuses the card; a press cancels it and lands as usual.
//! - Space on a card announces the pick-up even when a pointer drag holds
//!   the gesture and no keyboard drag starts (`State.pickUp` announces
//!   unconditionally).
//!
//! It does not model the core: the focus a drain starts from, hit records,
//! payloads (`drag_payload`), and drop targets are read from the window. It
//! folds consecutive moves as the queue does (`EventQueue.coalesce`), so a
//! drag that leaves the slop and comes back within one drain stays armed.
//! Events are applied in drain order after each `tickMain`, against the
//! frame the drain routed against (the rendered one, after the tick's flip).
//! After every drain the drag (phase, source, payload, keyboard target), the
//! focus when no build moved it, and the announcements pending for the next
//! build must match the core's. Pending announcements follow the live-region
//! rules (contract §4): drag_drop's are all assertive, so only the newest
//! one made since the last build survives, however many were made.

const std = @import("std");
const gooey = @import("gooey");
const drag_drop = @import("drag_drop_example");
const vopr = @import("vopr.zig");
const vopr_frame = @import("vopr_frame.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const Window = internals.window.Window;
const ElementId = records.ElementId;
const Action = vopr.Action;
const ItemId = drag_drop.ItemId;
const Side = drag_drop.Side;
const hitIndex = vopr_frame.hitIndex;
const findHit = vopr_frame.findHit;
const findA11y = vopr_frame.findA11y;
const nextTabStop = vopr_frame.nextTabStop;
const index_none = records.index_none;

const item_count: u32 = drag_drop.items.len;
/// Events one drain holds: the model folds them as the queue does, so it
/// holds exactly the queue's events.
const event_count_max: u32 = drag_drop.App.limits.events.queue_count_max;
/// Announcements between builds; the core fails fast past it.
/// Pending announcements at most: the polite FIFO and the assertive slot.
const announcement_count_max: u32 =
    drag_drop.App.limits.a11y.announcement_polite_pending_max + 1;
const click_slop_px: f32 = internals.window.Capture.click_slop_px;
const pick_up_prefix = "Picked up.";

comptime {
    assert(item_count > 0);
    assert(event_count_max >= 3);
    assert(announcement_count_max > 0);
}

pub const DragDropModel = struct {
    /// Item ids in each list, by `Side`, in display order.
    lists: [2]List,
    /// Focus within the drain being applied; read from the window first.
    focus: ElementId,
    /// The drag as the model expects it, across drains.
    drag: Drag,
    events: [event_count_max]Event,
    event_count: u32,
    /// The rendered frame when the drain began, to see the tick's flip.
    frame_number_begin: u64,
    /// Announcements expected pending for the next build, in order.
    announced: [announcement_count_max]Announcement,
    announced_count: u32,
    /// Announcements made since the last build, replaced ones included.
    announced_build_count: u32,
    /// Ticks the current drag has been active for, for `Stats`.
    drag_tick_count: u32,
    counts: Stats,
    step_last: u64,

    /// The kinds drag_drop's swarm draws weights for, in this order.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .text, .compose, .scroll, .wait_ns, .tick_main, .present, .drag,
    };

    /// How deep a run went, per seed.
    pub const Stats = struct {
        /// Pointer drags past the slop, and keyboard pick-ups that started.
        drags_started: u32,
        /// Drops delivered to a list, by pointer or keyboard.
        drags_completed: u32,
        /// Started drags that ended with no drop.
        drags_cancelled: u32,
        keyboard_drags: u32,
        keyboard_drops: u32,
        /// Presses on a card released before the drag started.
        clicks: u32,
        /// The most ticks one drag stayed active.
        drag_ticks_max: u32,
        /// The most announcements one drain made.
        announcements_drain_max: u32,
        /// The most announcements made between two builds, replaced ones
        /// included: what the pool held before the live-region rules.
        announcements_build_max: u32,
        /// The most announcements pending for a build at once.
        announcements_pending_max: u32,

        const zero: Stats = .{
            .drags_started = 0,
            .drags_completed = 0,
            .drags_cancelled = 0,
            .keyboard_drags = 0,
            .keyboard_drops = 0,
            .clicks = 0,
            .drag_ticks_max = 0,
            .announcements_drain_max = 0,
            .announcements_build_max = 0,
            .announcements_pending_max = 0,
        };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("drags {d} started, {d} completed, {d} cancelled; " ++
                "keyboard {d} drags, {d} drops; {d} clicks; longest drag {d} ticks; " ++
                "announcements {d} per drain max, {d} per build max, {d} pending max", .{
                self.drags_started,           self.drags_completed,
                self.drags_cancelled,         self.keyboard_drags,
                self.keyboard_drops,          self.clicks,
                self.drag_ticks_max,          self.announcements_drain_max,
                self.announcements_build_max, self.announcements_pending_max,
            });
        }
    };

    const List = struct {
        ids: [item_count]ItemId,
        count: u32,

        fn slice(self: *const List) []const ItemId {
            assert(self.count <= item_count);
            return self.ids[0..self.count];
        }
    };

    const Point = struct { x: f32, y: f32 };

    const Drag = struct {
        phase: enum { idle, armed, active },
        keyboard: bool,
        source: ElementId,
        payload: ItemId,
        type_id: usize,
        start: Point,
        /// The list a keyboard drag would drop on, or `.root`.
        over: ElementId,

        const idle: Drag = .{
            .phase = .idle,
            .keyboard = false,
            .source = .root,
            .payload = 0,
            .type_id = 0,
            .start = .{ .x = 0, .y = 0 },
            .over = .root,
        };
    };

    /// A queued input event, as far as drag_drop can tell them apart.
    const Event = union(enum) {
        moved: Point,
        dragged: Point,
        down: Point,
        up: Point,
        key_down: Action.Chord,
        key_up,
        /// Committed text or a composition: no handler of drag_drop's
        /// reads them.
        text,
        scroll,
    };

    const Announcement = union(enum) {
        pick_up,
        drop: struct { side: Side, id: ItemId },
    };

    pub fn init(self: *DragDropModel) void {
        self.lists[0] = .{ .ids = undefined, .count = item_count };
        for (0..item_count) |id| self.lists[0].ids[id] = @intCast(id);
        self.lists[1] = .{ .ids = undefined, .count = 0 };
        self.focus = .root;
        self.drag = .idle;
        self.event_count = 0;
        self.frame_number_begin = 0;
        self.announced_count = 0;
        self.announced_build_count = 0;
        self.drag_tick_count = 0;
        self.counts = .zero;
        self.step_last = 0;
        assert(self.lists[0].count + self.lists[1].count == item_count);
    }

    pub fn stats(self: *const DragDropModel) Stats {
        assert(self.counts.drags_completed + self.counts.drags_cancelled <=
            self.counts.drags_started);
        return self.counts;
    }

    /// Events the model can still record before the next drain.
    pub fn pendingRoom(self: *const DragDropModel) u32 {
        assert(self.event_count <= event_count_max);
        return event_count_max - self.event_count;
    }

    /// Record an input action as the events the harness delivers for it.
    pub fn queue(self: *DragDropModel, action: Action) void {
        switch (action) {
            .pointer => |pointer| {
                const point: Point = .{ .x = pointer.x, .y = pointer.y };
                self.push(.{ .moved = point });
                if (pointer.kind == .click) {
                    self.push(.{ .down = point });
                    self.push(.{ .up = point });
                }
            },
            .drag => |gesture| {
                const point: Point = .{ .x = gesture.x, .y = gesture.y };
                switch (gesture.kind) {
                    .press => {
                        self.push(.{ .moved = point });
                        self.push(.{ .down = point });
                    },
                    .move => self.push(.{ .dragged = point }),
                    .release => {
                        self.push(.{ .dragged = point });
                        self.push(.{ .up = point });
                    },
                }
            },
            .key => |chord| {
                self.push(.{ .key_down = chord });
                self.push(.key_up);
            },
            .text, .compose => self.push(.text),
            .scroll => self.push(.scroll),
            .wait_ns, .tick_main, .present => unreachable,
        }
    }

    /// Append an event, folding a move into a move, a held move into a
    /// held move, and a scroll into a scroll that it directly follows.
    fn push(self: *DragDropModel, event: Event) void {
        assert(self.event_count <= event_count_max);
        if (self.event_count > 0) {
            const last = &self.events[self.event_count - 1];
            const folds = switch (event) {
                .moved => last.* == .moved,
                .dragged => last.* == .dragged,
                .scroll => last.* == .scroll,
                else => false,
            };
            if (folds) {
                last.* = event;
                return;
            }
        }
        assert(self.event_count < event_count_max);
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    /// Before `tickMain`: the focus the drain starts from is the core's.
    pub fn beginDrain(self: *DragDropModel, window: *Window) void {
        assert(window.phase == .idle);
        if (window.queue.count != self.event_count) {
            std.debug.panic("vopr model: the queue holds {d} events after step {d}; " ++
                "the model folded them to {d}", .{
                window.queue.count,
                self.step_last,
                self.event_count,
            });
        }
        assert(window.keymap.len == 0);
        self.focus = window.focus;
        self.frame_number_begin = window.rendered().frame_number;
    }

    /// After `tickMain`: apply the drained events in order against the frame
    /// the drain routed against, then compare with the core.
    pub fn endDrain(self: *DragDropModel, window: *Window, published: bool) void {
        assert(window.phase == .idle);
        const frame = window.rendered();
        checkFrameShape(frame);
        if (frame.frame_number != self.frame_number_begin) self.followFlip(frame);
        const announced_before = self.announced_build_count;
        for (self.events[0..self.event_count]) |*event| self.route(frame, event);
        self.event_count = 0;
        const counts = &self.counts;
        const announced_drain = self.announced_build_count - announced_before;
        counts.announcements_drain_max = @max(counts.announcements_drain_max, announced_drain);
        counts.announcements_build_max =
            @max(counts.announcements_build_max, self.announced_build_count);
        counts.announcements_pending_max =
            @max(counts.announcements_pending_max, self.announced_count);
        if (published) {
            self.checkAnnouncements(&window.built().announcements);
            self.announced_count = 0;
            self.announced_build_count = 0;
            assert(window.announcements.count == 0);
        } else {
            self.checkAnnouncements(&window.announcements);
            if (window.focus != self.focus) {
                std.debug.panic("vopr model: focus is {x} after step {d}; the model " ++
                    "expected {x}", .{
                    @backingInt(window.focus),
                    self.step_last,
                    @backingInt(self.focus),
                });
            }
        }
        self.checkDrag(&window.drag);
        if (self.drag.phase == .active) {
            self.drag_tick_count += 1;
            counts.drag_ticks_max = @max(counts.drag_ticks_max, self.drag_tick_count);
        } else {
            self.drag_tick_count = 0;
        }
    }

    /// The tick flipped to a new frame: a keyboard drag's list that it no
    /// longer renders leaves the drag over nothing and focus on the card.
    fn followFlip(self: *DragDropModel, frame: *const records.Frame) void {
        if (!self.drag.keyboard) return;
        assert(self.drag.phase == .active);
        if (self.drag.over == .root) return;
        if (findHit(frame, self.drag.over)) |index| {
            if (frame.hits[index].drop_type == self.drag.type_id) return;
        }
        self.drag.over = .root;
        self.focus = self.drag.source;
    }

    fn route(self: *DragDropModel, frame: *const records.Frame, event: *const Event) void {
        switch (event.*) {
            .moved, .dragged => |point| self.pointerMoved(point),
            .down => |point| self.press(frame, point),
            .up => |point| self.release(frame, point),
            .key_down => |chord| {
                if (self.drag.keyboard) {
                    self.keyboardDragKey(frame, chord);
                } else {
                    if (chord.key == .escape and self.drag.phase != .idle) {
                        self.cancelPointerDrag();
                    } else {
                        self.keyToFocus(frame, chord);
                    }
                }
            },
            // A key's release, text, and the wheel reach no handler of
            // drag_drop's, and a keyboard drag takes them all.
            .key_up, .text, .scroll => {},
        }
    }

    /// An armed pointer drag starts once the pointer is past the slop.
    fn pointerMoved(self: *DragDropModel, point: Point) void {
        if (self.drag.phase != .armed) return;
        assert(!self.drag.keyboard);
        const dx = point.x - self.drag.start.x;
        const dy = point.y - self.drag.start.y;
        if (dx * dx + dy * dy <= click_slop_px * click_slop_px) return;
        self.drag.phase = .active;
        self.counts.drags_started += 1;
    }

    /// A press ends a keyboard drag, arms a drag of the card under it when
    /// no drag holds the gesture, and focuses the innermost focusable.
    fn press(self: *DragDropModel, frame: *const records.Frame, point: Point) void {
        if (self.drag.keyboard) {
            self.drag = .idle;
            self.counts.drags_cancelled += 1;
        }
        const deepest = hitIndex(frame, point.x, point.y) orelse index_none;
        var focus_id: ElementId = .root;
        var card: ?u32 = null;
        var index = deepest;
        var depth: u32 = 0;
        while (index != index_none) : (depth += 1) {
            assert(depth <= frame.hit_count);
            const record = &frame.hits[index];
            if (card == null and record.drag_type != 0) card = index;
            if (focus_id == .root and record.focusable) focus_id = record.id;
            index = record.parent;
        }
        if (self.drag.phase == .idle) {
            if (card) |found| {
                const record = &frame.hits[found];
                self.drag = .{
                    .phase = .armed,
                    .keyboard = false,
                    .source = record.id,
                    .payload = checkCard(frame, record),
                    .type_id = record.drag_type,
                    .start = point,
                    .over = .root,
                };
            }
        }
        self.focus = focus_id;
    }

    /// A release ends a pointer drag: a started one drops on the list under
    /// it, or on nothing; an armed one is a click, which nothing handles.
    fn release(self: *DragDropModel, frame: *const records.Frame, point: Point) void {
        if (self.drag.phase == .idle or self.drag.keyboard) return;
        const ended = self.drag;
        self.drag = .idle;
        if (ended.phase == .armed) {
            self.counts.clicks += 1;
            return;
        }
        const deepest = hitIndex(frame, point.x, point.y) orelse index_none;
        var index = deepest;
        var depth: u32 = 0;
        while (index != index_none) : (depth += 1) {
            assert(depth <= frame.hit_count);
            if (frame.hits[index].drop_type == ended.type_id) break;
            index = frame.hits[index].parent;
        }
        if (index == index_none) {
            self.counts.drags_cancelled += 1;
        } else {
            self.drop(frame, ended.payload, index, false);
        }
    }

    fn cancelPointerDrag(self: *DragDropModel) void {
        assert(!self.drag.keyboard);
        assert(self.drag.phase != .idle);
        if (self.drag.phase == .active) self.counts.drags_cancelled += 1;
        self.drag = .idle;
    }

    /// A key outside a keyboard drag: the focused card's handler, then Tab
    /// moves focus. No element of drag_drop's handles a click.
    fn keyToFocus(self: *DragDropModel, frame: *const records.Frame, chord: Action.Chord) void {
        const target = findHit(frame, self.focus) orelse {
            if (chord.key == .tab) {
                self.focus = nextTabStop(frame, self.focus, chord.modifiers.shift);
            }
            return;
        };
        var index = target;
        var depth: u32 = 0;
        while (index != index_none) : (depth += 1) {
            assert(depth <= frame.hit_count);
            const record = &frame.hits[index];
            // Only a card handles keys (`State.pickUp`), and it never stops
            // the key going further.
            if (record.on_key != index_none) self.pickUp(frame, record, chord);
            index = record.parent;
        }
        if (chord.key == .tab) self.focus = nextTabStop(frame, self.focus, chord.modifiers.shift);
    }

    /// Space on a card announces a pick-up and starts a keyboard drag of it,
    /// unless a drag already holds the gesture.
    fn pickUp(
        self: *DragDropModel,
        frame: *const records.Frame,
        record: *const records.HitRecord,
        chord: Action.Chord,
    ) void {
        assert(record.drag_type != 0);
        const modifiers = chord.modifiers;
        if (chord.key != .space) return;
        if (modifiers.cmd or modifiers.ctrl or modifiers.alt) return;
        if (self.drag.phase == .idle) {
            self.drag = .{
                .phase = .active,
                .keyboard = true,
                .source = record.id,
                .payload = checkCard(frame, record),
                .type_id = record.drag_type,
                .start = centreOf(record.bounds),
                .over = .root,
            };
            self.counts.drags_started += 1;
            self.counts.keyboard_drags += 1;
        }
        self.announce(.pick_up);
    }

    /// During a keyboard drag every key is the drag's.
    fn keyboardDragKey(
        self: *DragDropModel,
        frame: *const records.Frame,
        chord: Action.Chord,
    ) void {
        assert(self.drag.keyboard);
        assert(self.drag.phase == .active);
        switch (chord.key) {
            .tab => self.moveOver(frame, chord.modifiers.shift),
            .down, .right => self.moveOver(frame, false),
            .up, .left => self.moveOver(frame, true),
            .escape => {
                self.endKeyboardDrag();
                self.counts.drags_cancelled += 1;
            },
            else => {
                const modifiers = chord.modifiers;
                const plain = !modifiers.cmd and !modifiers.ctrl and !modifiers.alt;
                const activates = chord.key == .space or chord.key == .@"return";
                if (plain and activates) self.keyboardDrop(frame);
            },
        }
    }

    /// Choose the next list in tree order after the chosen one, or else the
    /// card (the previous with `backward`), wrapping, and focus it.
    fn moveOver(self: *DragDropModel, frame: *const records.Frame, backward: bool) void {
        const count = frame.hit_count;
        if (count == 0) return;
        const from_id = if (self.drag.over != .root) self.drag.over else self.drag.source;
        var index: u32 = findHit(frame, from_id) orelse if (backward) 0 else count - 1;
        var step: u32 = 0;
        while (step < count) : (step += 1) {
            index = if (backward) (index + count - 1) % count else (index + 1) % count;
            const record = &frame.hits[index];
            if (record.drop_type != self.drag.type_id) continue;
            if (!record.pointer or index < frame.modal_hit_start) continue;
            self.drag.over = record.id;
            self.focus = record.id;
            return;
        }
    }

    /// Drop on the chosen list, if it still renders; focus stays on it.
    fn keyboardDrop(self: *DragDropModel, frame: *const records.Frame) void {
        if (self.drag.over == .root) return;
        const target = findHit(frame, self.drag.over) orelse return;
        const ended = self.drag;
        self.endKeyboardDrag();
        if (frame.hits[target].focusable) self.focus = ended.over;
        self.drop(frame, ended.payload, target, true);
        self.counts.keyboard_drops += 1;
    }

    fn endKeyboardDrag(self: *DragDropModel) void {
        assert(self.drag.keyboard);
        self.focus = self.drag.source;
        self.drag = .idle;
    }

    fn drop(
        self: *DragDropModel,
        frame: *const records.Frame,
        id: ItemId,
        target: u32,
        keyboard: bool,
    ) void {
        assert(target < frame.hit_count);
        assert(id < item_count);
        const side = sideOf(frame, target);
        self.move(id, side);
        self.counts.drags_completed += 1;
        if (keyboard) self.announce(.{ .drop = .{ .side = side, .id = id } });
    }

    /// Remove `id` from whichever list holds it, keeping the rest in order,
    /// and append it to `side`'s list.
    fn move(self: *DragDropModel, id: ItemId, side: Side) void {
        assert(id < item_count);
        var removed = false;
        for (&self.lists) |*list| {
            const index = std.mem.indexOfScalar(ItemId, list.slice(), id) orelse continue;
            std.mem.copyForwards(
                ItemId,
                list.ids[index .. list.count - 1],
                list.ids[index + 1 .. list.count],
            );
            list.count -= 1;
            removed = true;
        }
        assert(removed);
        const list = &self.lists[@backingInt(side)];
        assert(list.count < item_count);
        list.ids[list.count] = id;
        list.count += 1;
        assert(self.lists[0].count + self.lists[1].count == item_count);
    }

    /// drag_drop's announcements are all assertive: a newer one replaces the
    /// pending one, and survivors keep their order, so it goes last.
    fn announce(self: *DragDropModel, announcement: Announcement) void {
        assert(self.announced_count <= 1);
        self.announced[0] = announcement;
        self.announced_count = 1;
        self.announced_build_count += 1;
        assert(self.announced_count <= announcement_count_max);
    }

    /// After every step: the app's lists must hold every item once, and
    /// exactly the model's lists.
    pub fn check(self: *DragDropModel, state: *const drag_drop.State, step: u64) void {
        self.step_last = step;
        checkPartition(state, step);
        for (0..2) |side_index| {
            const side: Side = @fromBackingInt(@intCast(side_index));
            const actual = state.list(side).slice();
            const expected = self.lists[side_index].slice();
            if (!std.mem.eql(ItemId, actual, expected)) {
                std.debug.panic("vopr model: after step {d} the {t} list holds {any}; " ++
                    "the model expected {any} (the other holds {any}, expected {any})", .{
                    step,
                    side,
                    actual,
                    expected,
                    state.list(other(side)).slice(),
                    self.lists[1 - side_index].slice(),
                });
            }
        }
    }

    fn checkDrag(self: *const DragDropModel, actual: *const internals.window.Drag) void {
        const expected = &self.drag;
        const phase_same = @backingInt(actual.phase) == @backingInt(expected.phase);
        var same = phase_same and actual.keyboard == expected.keyboard;
        if (same and expected.phase != .idle) {
            same = actual.payload == expected.payload and actual.source == expected.source;
        }
        if (same and expected.keyboard) same = actual.over == expected.over;
        if (same) return;
        std.debug.panic("vopr model: after step {d} the drag is {t} (keyboard {}, payload " ++
            "{d}, source {x}, over {x}); the model expected {t} (keyboard {}, payload {d}, " ++
            "source {x}, over {x})", .{
            self.step_last,             actual.phase,
            actual.keyboard,            actual.payload,
            @backingInt(actual.source), @backingInt(actual.over),
            expected.phase,             expected.keyboard,
            expected.payload,           @backingInt(expected.source),
            @backingInt(expected.over),
        });
    }

    /// The pool holds the pending announcements in order, all assertive.
    fn checkAnnouncements(self: *const DragDropModel, pool: *const records.Announcements) void {
        assert(self.announced_count <= announcement_count_max);
        if (pool.count != self.announced_count) {
            std.debug.panic("vopr model: {d} announcements pending after step {d}; the model " ++
                "expected {d}", .{ pool.count, self.step_last, self.announced_count });
        }
        for (self.announced[0..self.announced_count], pool.items[0..pool.count]) |want, item| {
            const text = pool.text(item);
            const matches = switch (want) {
                .pick_up => std.mem.startsWith(u8, text, pick_up_prefix),
                .drop => |dropped| isDropMessage(text, dropped.side, dropped.id),
            };
            if (!matches or item.live != .assertive) {
                const expected = switch (want) {
                    .pick_up => pick_up_prefix,
                    .drop => |dropped| drag_drop.items[dropped.id].name,
                };
                const title = switch (want) {
                    .pick_up => "",
                    .drop => |dropped| drag_drop.titles[@backingInt(dropped.side)],
                };
                std.debug.panic("vopr model: announcement \"{s}\" ({t}) after step {d}; " ++
                    "the model expected an assertive \"{s}{s}{s}...\"", .{
                    text,
                    item.live,
                    self.step_last,
                    expected,
                    if (title.len > 0) " moved to " else "",
                    title,
                });
            }
        }
    }
};

fn other(side: Side) Side {
    return if (side == .left) .right else .left;
}

fn centreOf(bounds: records.Rect) DragDropModel.Point {
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    return .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
}

/// "<item> moved to <list title>", as a keyboard drop announces it.
fn isDropMessage(text: []const u8, side: Side, id: ItemId) bool {
    assert(id < item_count);
    const name = drag_drop.items[id].name;
    const title = drag_drop.titles[@backingInt(side)];
    const middle = " moved to ";
    if (text.len != name.len + middle.len + title.len) return false;
    if (!std.mem.startsWith(u8, text, name)) return false;
    if (!std.mem.eql(u8, text[name.len..][0..middle.len], middle)) return false;
    return std.mem.endsWith(u8, text, title);
}

/// A card's payload is its item id, and its accessibility label the item's
/// name.
fn checkCard(frame: *const records.Frame, record: *const records.HitRecord) ItemId {
    assert(record.drag_type != 0);
    if (record.drag_payload >= item_count) {
        std.debug.panic("vopr model: a card carries payload {d}; drag_drop has {d} items", .{
            record.drag_payload,
            item_count,
        });
    }
    const id: ItemId = @intCast(record.drag_payload);
    const node = findA11y(frame, record.id) orelse
        std.debug.panic("vopr model: card {d} has no accessibility node", .{id});
    const label = frame.text(node.name) orelse "";
    if (!std.mem.eql(u8, label, drag_drop.items[id].name)) {
        std.debug.panic("vopr model: card with payload {d} is labelled \"{s}\", not \"{s}\"", .{
            id,
            label,
            drag_drop.items[id].name,
        });
    }
    return id;
}

/// Which list a drop target is, by its accessibility label.
fn sideOf(frame: *const records.Frame, target: u32) Side {
    assert(target < frame.hit_count);
    const record = &frame.hits[target];
    assert(record.drop_type != 0);
    const node = findA11y(frame, record.id) orelse
        std.debug.panic("vopr model: a drop target has no accessibility node", .{});
    const label = frame.text(node.name) orelse "";
    for (drag_drop.titles, 0..) |title, side| {
        if (std.mem.eql(u8, label, title)) return @fromBackingInt(@intCast(side));
    }
    std.debug.panic("vopr model: a drop target is labelled \"{s}\"", .{label});
}

/// What the model assumes of drag_drop's frames: no click handlers, pointer
/// captures, or scroll boxes, which it would otherwise have to model.
fn checkFrameShape(frame: *const records.Frame) void {
    assert(frame.hit_count <= frame.hits.len);
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.on_click != index_none or record.on_pointer_drag != index_none or
            record.scroll)
        {
            std.debug.panic("vopr model: drag_drop rendered a click handler, capture, or " ++
                "scroll box, which the model does not handle", .{});
        }
    }
}

/// Every item is in exactly one list, once.
fn checkPartition(state: *const drag_drop.State, step: u64) void {
    var seen: [item_count]u32 = @splat(0);
    var total: u32 = 0;
    for ([_]Side{ .left, .right }) |side| {
        for (state.list(side).slice()) |id| {
            if (id >= item_count) {
                std.debug.panic("vopr model: after step {d} the {t} list holds item {d}; " ++
                    "drag_drop has {d}", .{ step, side, id, item_count });
            }
            seen[id] += 1;
            total += 1;
        }
    }
    for (seen, 0..) |count, id| {
        if (count != 1) {
            std.debug.panic("vopr model: after step {d} item {d} is in {d} lists (left {any}, " ++
                "right {any})", .{
                step,
                id,
                count,
                state.list(.left).slice(),
                state.list(.right).slice(),
            });
        }
    }
    assert(total == item_count);
}
