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
const MouseButton = gooey.input.MouseButton;
const nextTabStop = vopr_frame.nextTabStop;
const index_none = records.index_none;

const item_count: u32 = drag_drop.items.len;
const event_count_max: u32 = drag_drop.App.limits.events.queue_count_max;
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
    lists: [2]List,
    focus: ElementId,
    drag: Drag,
    events: [event_count_max]Event,
    event_count: u32,
    frame_number_begin: u64,
    announced: [announcement_count_max]Announcement,
    announced_count: u32,
    announced_build_count: u32,
    drag_tick_count: u32,
    counts: Stats,
    step_last: u64,

    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .text, .compose, .scroll, .wait_ns, .tick_main, .present, .drag,
        .resize,
    };

    pub const Stats = struct {
        drags_started: u32,
        drags_completed: u32,
        drags_cancelled: u32,
        keyboard_drags: u32,
        keyboard_drops: u32,
        clicks: u32,
        drag_ticks_max: u32,
        announcements_drain_max: u32,
        announcements_build_max: u32,
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
        button: MouseButton,
        over: ElementId,

        const idle: Drag = .{
            .phase = .idle,
            .keyboard = false,
            .source = .root,
            .payload = 0,
            .type_id = 0,
            .start = .{ .x = 0, .y = 0 },
            .button = .left,
            .over = .root,
        };
    };

    const Press = struct { point: Point, button: MouseButton };

    const Event = union(enum) {
        moved: Point,
        dragged: Press,
        down: Press,
        up: Press,
        key_down: Action.Chord,
        key_up,
        text,
        scroll,
        resize,
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

    pub fn pendingRoom(self: *const DragDropModel) u32 {
        assert(self.event_count <= event_count_max);
        return event_count_max - self.event_count;
    }

    pub fn queue(self: *DragDropModel, action: Action) void {
        switch (action) {
            .pointer => |pointer| {
                const point: Point = .{ .x = pointer.x, .y = pointer.y };
                const held: Press = .{ .point = point, .button = pointer.button };
                if (pointer.releases_held) {
                    self.push(.{ .dragged = held });
                    self.push(.{ .up = held });
                }
                switch (pointer.kind) {
                    .move => self.push(.{ .moved = point }),
                    .press => {
                        self.push(.{ .moved = point });
                        self.push(.{ .down = held });
                    },
                    .release => {
                        self.push(.{ .dragged = held });
                        self.push(.{ .up = held });
                    },
                    .click => {
                        self.push(.{ .moved = point });
                        self.push(.{ .down = held });
                        self.push(.{ .up = held });
                    },
                }
            },
            .drag => |gesture| {
                const point: Point = .{ .x = gesture.x, .y = gesture.y };
                const held: Press = .{ .point = point, .button = gesture.button };
                switch (gesture.kind) {
                    .press => {
                        if (gesture.releases_held) {
                            self.push(.{ .dragged = held });
                            self.push(.{ .up = held });
                        }
                        self.push(.{ .moved = point });
                        self.push(.{ .down = held });
                    },
                    .move => self.push(.{ .dragged = held }),
                    .release => {
                        self.push(.{ .dragged = held });
                        self.push(.{ .up = held });
                    },
                }
            },
            .key => |chord| {
                self.push(.{ .key_down = chord });
                self.push(.key_up);
            },
            .text, .compose => self.push(.text),
            .scroll => self.push(.scroll),
            .resize => self.push(.resize),
            .wait_ns, .tick_main, .present, .cancel, .image, .dialog, .job => unreachable,
        }
    }

    fn push(self: *DragDropModel, event: Event) void {
        assert(self.event_count <= event_count_max);
        if (self.event_count > 0) {
            const last = &self.events[self.event_count - 1];
            const folds = switch (event) {
                .moved => last.* == .moved,
                .dragged => |moved| last.* == .dragged and last.dragged.button == moved.button,
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
            .moved => |point| self.pointerMoved(point),
            .dragged => |held| self.pointerMoved(held.point),
            .down => |press_event| self.press(frame, press_event),
            .up => |release_event| self.release(frame, release_event),
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
            .key_up, .text, .scroll, .resize => {},
        }
    }

    fn pointerMoved(self: *DragDropModel, point: Point) void {
        if (self.drag.phase != .armed) return;
        assert(!self.drag.keyboard);
        const dx = point.x - self.drag.start.x;
        const dy = point.y - self.drag.start.y;
        if (dx * dx + dy * dy <= click_slop_px * click_slop_px) return;
        self.drag.phase = .active;
        self.counts.drags_started += 1;
    }

    fn press(self: *DragDropModel, frame: *const records.Frame, event: Press) void {
        const point = event.point;
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
                    .button = event.button,
                    .over = .root,
                };
            }
        }
        self.focus = focus_id;
    }

    fn release(self: *DragDropModel, frame: *const records.Frame, event: Press) void {
        const point = event.point;
        if (self.drag.phase == .idle or self.drag.keyboard) return;
        if (self.drag.button != event.button) return;
        const ended = self.drag;
        self.drag = .idle;
        if (ended.phase == .armed) {
            if (event.button == .left) self.counts.clicks += 1;
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
            if (record.on_key != index_none) self.pickUp(frame, record, chord);
            index = record.parent;
        }
        if (chord.key == .tab) self.focus = nextTabStop(frame, self.focus, chord.modifiers.shift);
    }

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
        if (self.drag.phase != .idle) return;
        self.drag = .{
            .phase = .active,
            .keyboard = true,
            .source = record.id,
            .payload = checkCard(frame, record),
            .type_id = record.drag_type,
            .start = centreOf(record.bounds),
            .button = .left,
            .over = .root,
        };
        self.counts.drags_started += 1;
        self.counts.keyboard_drags += 1;
        self.announce(.pick_up);
    }

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

    fn announce(self: *DragDropModel, announcement: Announcement) void {
        assert(self.announced_count <= 1);
        self.announced[0] = announcement;
        self.announced_count = 1;
        self.announced_build_count += 1;
        assert(self.announced_count <= announcement_count_max);
    }

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
        if (same and expected.phase != .idle and !expected.keyboard) {
            same = actual.button == expected.button;
        }
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
