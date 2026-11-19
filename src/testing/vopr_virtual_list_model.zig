//! The VOPR's model of the virtual_list example. The app keeps no state of
//! its own (its `State` has no fields; Top, Bottom, and Jump only scroll),
//! so the model checks nothing an app model would. It measures how deep a
//! seed went through the list, from the rendered frames, and it tells the
//! generator where the list and its scrollbar are, so pointer, wheel, and
//! drag actions mostly land there (`biasTarget`).
//!
//! Depth, per seed:
//! - rows seen: distinct messages any rendered frame built;
//! - the furthest row index and scroll offset reached;
//! - rows entered: rows a rendered frame built that the one before did not,
//!   which is the List's recycling (each such row is built fresh, and a
//!   row that left the view has its keyed state swept);
//! - the most rows one frame built.
//! Rows are found by their keyed boxes' hit records, whose parent is the
//! list's record (`components.List` keys each row's box by its index).

const std = @import("std");
const gooey = @import("gooey");
const virtual_list = @import("virtual_list_example");
const vopr = @import("vopr.zig");
const vopr_frame = @import("vopr_frame.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const Window = internals.window.Window;
const ElementId = records.ElementId;
const ScrollState = internals.window.ScrollState;
const Action = vopr.Action;

const row_count: u32 = virtual_list.message_count;
const RowSet = std.StaticBitSet(row_count);

pub const VirtualListModel = struct {
    list_id: ElementId,
    /// Each row's box id and index, sorted by id for lookup.
    rows: [row_count]Row,
    /// The rendered frame `observe` last read.
    frame_number_seen: u64,
    visible: RowSet,
    seen: RowSet,
    counts: Stats,

    /// The kinds virtual_list's swarm draws weights for, in this order. No
    /// text: the app has no text input.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .scroll, .wait_ns, .tick_main, .present, .drag, .resize,
    };

    pub const Stats = struct {
        frames: u32,
        rows_seen: u32,
        row_index_max: u32,
        offset_max: f32,
        rows_entered: u32,
        rows_frame_max: u32,

        const zero: Stats = .{
            .frames = 0,
            .rows_seen = 0,
            .row_index_max = 0,
            .offset_max = 0,
            .rows_entered = 0,
            .rows_frame_max = 0,
        };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d} frames; rows {d} seen, furthest index {d}, " ++
                "{d} entered, {d} per frame max; furthest offset {d:.1}", .{
                self.frames,
                self.rows_seen,
                self.row_index_max,
                self.rows_entered,
                self.rows_frame_max,
                self.offset_max,
            });
        }
    };

    const Row = struct { id: ElementId, index: u32 };

    pub fn init(self: *VirtualListModel) void {
        self.list_id = ElementId.root.child(.{ .name = "page" }).child(.{ .name = "chat-list" });
        for (&self.rows, 0..) |*row, index| {
            row.* = .{ .id = self.list_id.child(.{ .index = index }), .index = @intCast(index) };
        }
        std.sort.pdq(Row, &self.rows, {}, rowLess);
        self.frame_number_seen = 0;
        self.visible = .empty;
        self.seen = .empty;
        self.counts = .zero;
        assert(self.rows[0].id != self.list_id);
    }

    fn rowLess(_: void, a: Row, b: Row) bool {
        return @backingInt(a.id) < @backingInt(b.id);
    }

    pub fn stats(self: *const VirtualListModel) Stats {
        assert(self.counts.rows_seen <= row_count);
        return self.counts;
    }

    /// The model keeps no events, so only the queue bounds input.
    pub fn pendingRoom(_: *const VirtualListModel) u32 {
        return virtual_list.App.limits.events.queue_count_max;
    }

    pub fn queue(_: *VirtualListModel, action: Action) void {
        assert(action != .tick_main);
        assert(action != .present);
    }

    pub fn beginDrain(_: *VirtualListModel, window: *Window) void {
        assert(window.phase == .idle);
    }

    /// After `tickMain`, whose flip may have made a new frame rendered.
    pub fn endDrain(self: *VirtualListModel, window: *Window, published: bool) void {
        _ = published;
        self.observe(window);
    }

    pub fn check(_: *VirtualListModel, state: *const virtual_list.State, step: u64) void {
        _ = state;
        _ = step;
    }

    /// Where the generator aims: the list's box and its vertical bar.
    pub fn biasTarget(window: *Window) ?vopr.Bias {
        const frame = window.rendered();
        const list_id = ElementId.root.child(.{ .name = "page" }).child(.{ .name = "chat-list" });
        const index = vopr_frame.findHit(frame, list_id) orelse return null;
        const scroll = window.retained.findConst(ScrollState, list_id);
        const bar = if (scroll) |state| state.track(.y) else null;
        return .{ .area = frame.hits[index].bounds, .alternate = bar };
    }

    /// Count the rows of a newly rendered frame.
    fn observe(self: *VirtualListModel, window: *Window) void {
        const frame = window.rendered();
        if (frame.frame_number == self.frame_number_seen) return;
        self.frame_number_seen = frame.frame_number;
        self.counts.frames += 1;
        const list_index = vopr_frame.findHit(frame, self.list_id) orelse {
            self.visible = .empty;
            return;
        };
        var visible: RowSet = .empty;
        var frame_rows: u32 = 0;
        for (frame.hits[0..frame.hit_count]) |*record| {
            if (record.parent != list_index) continue;
            const index = self.rowIndex(record.id) orelse continue;
            visible.set(index);
            frame_rows += 1;
            if (!self.visible.isSet(index)) self.counts.rows_entered += 1;
            self.counts.row_index_max = @max(self.counts.row_index_max, index);
        }
        self.visible = visible;
        self.seen.setUnion(visible);
        self.counts.rows_seen = @intCast(self.seen.count());
        self.counts.rows_frame_max = @max(self.counts.rows_frame_max, frame_rows);
        if (window.retained.findConst(ScrollState, self.list_id)) |state| {
            self.counts.offset_max = @max(self.counts.offset_max, state.offset_y);
        }
    }

    fn rowIndex(self: *const VirtualListModel, id: ElementId) ?u32 {
        var low: usize = 0;
        var high: usize = self.rows.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = @backingInt(self.rows[middle].id);
            if (candidate == @backingInt(id)) return self.rows[middle].index;
            if (candidate < @backingInt(id)) low = middle + 1 else high = middle;
        }
        return null;
    }
};
