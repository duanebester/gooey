const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");
const vopr = @import("vopr.zig");
const vopr_events = @import("vopr_events.zig");
const vopr_frame = @import("vopr_frame.zig");

const assert = std.debug.assert;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const Button = components.Button;
const internals = gooey.internals;
const records = internals.records;
const jobs = internals.jobs;
const Window = internals.window.Window;
const ElementId = records.ElementId;
const Rect = records.Rect;
const Action = vopr.Action;
const Event = vopr_events.Event;
const Point = vopr_events.Point;
const Phase = jobs.Phase;

pub const limits = blk: {
    var budget = gooey.ResourceLimits.nano;
    budget.events.job_count_max = 3;
    budget.events.job_result_count_max = 4;
    break :blk budget;
};

const slot_count: u32 = limits.events.job_count_max;
const result_count_max: u32 = limits.events.job_result_count_max;
pub const row_count: u32 = slot_count + 1;
const post_count_max: u32 = 3;
const entry_count_max: u32 = result_count_max + slot_count;
const pending_count_max: u32 = limits.events.queue_count_max;
const press_path_len_max: u32 = internals.window.box_depth_ceiling;
const button_count: u32 = 2 + row_count;

comptime {
    assert(post_count_max <= result_count_max);
    assert(post_count_max * slot_count > result_count_max);
    assert(row_count > slot_count);
}

pub const Work = struct {
    pub const Input = struct {
        number: u32,
        post_count: u32,
        fails: bool,
        chain: bool,
    };
    pub const Result = struct {
        value: u32,
        cancel_row: u32,
    };
    pub const posts_max: u32 = post_count_max;

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        assert(input.number > 0);
        assert(input.post_count <= post_count_max);
        for (0..input.post_count) |index| {
            const result = resultOf(input.number, @intCast(index));
            if (!job.post(&result)) return error.Canceled;
        }
        if (input.fails) return error.WorkFailed;
    }
};

pub fn inputOf(number: u32, chain: bool) Work.Input {
    assert(number > 0);
    return .{
        .number = number,
        .post_count = number % (post_count_max + 1),
        .fails = number % 5 == 4,
        .chain = chain,
    };
}

pub fn resultOf(number: u32, index: u32) Work.Result {
    assert(number > 0);
    assert(index < post_count_max);
    const cancels = number % 3 == 0 and index == 0;
    return .{
        .value = number * 10 + index,
        .cancel_row = if (cancels) 1 + number % row_count else 0,
    };
}

pub const RowStatus = enum { empty, running, finished, cancelled, failed };

pub const Row = struct {
    id: gooey.JobId,
    number: u32,
    chain: bool,
    status: RowStatus,
    result_count: u32,
    value_last: u32,

    const empty: Row = .{
        .id = .{ .slot = 0, .generation = 0 },
        .number = 0,
        .chain = false,
        .status = .empty,
        .result_count = 0,
        .value_last = 0,
    };
};

pub const Status = enum { idle, spawned, refused, cancel_sent, result, ended };

pub const State = struct {
    rows: [row_count]Row = @splat(.empty),
    spawned: u32 = 0,
    refused: u32 = 0,
    results: u32 = 0,
    ended: u32 = 0,
    stray: u32 = 0,
    status: Status = .idle,

    pub fn spawnPlain(self: *State, effects: *Effects) void {
        assert(self.ended <= self.spawned);
        self.spawn(effects, false);
    }

    pub fn spawnChain(self: *State, effects: *Effects) void {
        assert(self.stray == 0);
        self.spawn(effects, true);
    }

    pub fn cancel(self: *State, row: u32, effects: *Effects) void {
        assert(row < row_count);
        self.cancelRow(row, effects);
        self.status = .cancel_sent;
    }

    pub fn onResult(self: *State, effects: *Effects) void {
        const result = effects.jobResult(Work).?;
        assert(effects.jobDone() == null);
        self.results += 1;
        self.status = .result;
        const row = runningRow(self, effects.jobId().?) orelse {
            self.stray += 1;
            return;
        };
        self.rows[row].result_count += 1;
        self.rows[row].value_last = result.value;
        if (result.cancel_row > 0) self.cancelRow(result.cancel_row - 1, effects);
    }

    pub fn onDone(self: *State, effects: *Effects) void {
        const done = effects.jobDone().?;
        assert(std.meta.eql(done.id, effects.jobId().?));
        self.ended += 1;
        self.status = .ended;
        const row = runningRow(self, done.id) orelse {
            self.stray += 1;
            return;
        };
        self.rows[row].status = switch (done.outcome) {
            .finished => .finished,
            .cancelled => .cancelled,
            .failed => .failed,
        };
        if (self.rows[row].chain and done.outcome == .finished) self.spawn(effects, false);
    }

    fn spawn(self: *State, effects: *Effects, chain: bool) void {
        const number = self.spawned + 1;
        const id = effects.spawn(Work, &inputOf(number, chain), .{
            .on_result = effects.handler(State.onResult),
            .on_done = effects.handler(State.onDone),
        }) catch |err| switch (err) {
            error.JobBusy => {
                self.refused += 1;
                self.status = .refused;
                return;
            },
        };
        const row = rowFree(self);
        assert(self.rows[row].status != .running);
        self.rows[row] = .{
            .id = id,
            .number = number,
            .chain = chain,
            .status = .running,
            .result_count = 0,
            .value_last = 0,
        };
        self.spawned = number;
        self.status = .spawned;
    }

    fn cancelRow(self: *State, row: u32, effects: *Effects) void {
        assert(row < row_count);
        if (self.rows[row].status == .empty) return;
        effects.cancelJob(self.rows[row].id);
    }
};

pub const App = gooey.App(State, render, .{
    .title = "VOPR jobs",
    .width = 640,
    .height = 320,
    .limits = limits,
    .jobs = &.{Work},
});

const row_text_bytes_max: u32 = 1 + 10 + 12 + 10 + 15 + 10;

comptime {
    assert(row_text_bytes_max == 58);
}

const cancel_keys = [row_count][]const u8{ "cancel-0", "cancel-1", "cancel-2", "cancel-3" };

fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(16),
        .gap = 8,
    } }, .{
        ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            Button{ .label = "Spawn", .on_click = cx.on(State.spawnPlain, .{}) },
            Button{ .label = "Spawn chain", .on_click = cx.on(State.spawnChain, .{}) },
        }),
        Rows{},
        ui.text(@tagName(s.status), .{ .size = 13 }),
    }));
}

const Rows = struct {
    pub fn render(_: Rows, cx: *Cx) void {
        const s = cx.state(State);
        for (s.rows, 0..) |row, index| {
            var bytes: [row_text_bytes_max]u8 = undefined;
            const text = std.fmt.bufPrint(&bytes, "#{d} {t}: {d} results, last {d}", .{
                row.number,
                row.status,
                row.result_count,
                row.value_last,
            }) catch unreachable;
            assert(text.len > 0);
            cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
                Button{
                    .label = "Cancel",
                    .key = cancel_keys[index],
                    .size = .small,
                    .on_click = cx.on(State.cancel, .{ .arg = @as(u32, @intCast(index)) }),
                },
                ui.text(text, .{ .size = 13 }),
            }));
        }
    }
};

const Slot = struct {
    busy: bool,
    generation: u32,
    phase: Phase,
    cancel: bool,
    queued: bool,
    order: u64,
    input: Work.Input,

    const free: Slot = .{
        .busy = false,
        .generation = 0,
        .phase = .idle,
        .cancel = false,
        .queued = false,
        .order = 0,
        .input = .{ .number = 0, .post_count = 0, .fails = false, .chain = false },
    };
};

const Entry = struct {
    slot: u32,
    generation: u32,
    kind: enum { result, done },
    result: Work.Result,
    outcome: EndOutcome,
};

const EndOutcome = enum { finished, cancelled, failed };

const ButtonKind = union(enum) { spawn, spawn_chain, cancel: u32 };

pub fn JobsModel(comptime runs: jobs.Mode) type {
    comptime assert(runs != .workers);
    return struct {
        slots: [slot_count]Slot,
        entries: [entry_count_max]Entry,
        entry_count: u32,
        results_held: u32,
        spawn_count: u64,
        expected: State,
        pending: [pending_count_max]Action,
        pending_count: u32,
        focus: ElementId,
        press_path: [press_path_len_max]ElementId,
        press_len: u32,
        counts: Stats,

        const Self = @This();

        pub const job_runs = runs;
        pub const JobResult = Work.Result;
        pub const job_row_count = row_count;

        pub const action_kinds: []const vopr.ActionKind = switch (runs) {
            .stepped => &.{ .pointer, .key, .wait_ns, .tick_main, .present, .resize, .job },
            .main_thread => &.{ .pointer, .key, .wait_ns, .tick_main, .present, .resize },
            .workers => unreachable,
        };

        pub const key_choices: []const gooey.input.KeyCode = &.{
            .tab, .space, .@"return", .escape,
        };

        pub const Stats = struct {
            spawned: u32,
            chained: u32,
            refused: u32,
            chained_full: u32,
            results_delivered: u32,
            results_dropped: u32,
            posts_refused: u32,
            finished: u32,
            cancelled: u32,
            failed: u32,
            cancels_skipped: u32,
            cancels_interrupting: u32,
            cancels_late: u32,
            cancels_stale_free: u32,
            cancels_stale_reused: u32,
            cancels_in_delivery: u32,
            runs_deferred: u32,
            runs_batched: u32,
            results_held_max: u32,

            const zero: Stats = std.mem.zeroes(Stats);

            pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                try writer.print("{d} spawned ({d} chained, {d} into a full table), " ++
                    "{d} refused; " ++
                    "{d} results delivered, {d} dropped, {d} posts refused, at most {d} " ++
                    "held; ends: {d} finished, {d} cancelled, {d} failed; cancels: {d} " ++
                    "skipped, {d} interrupting, {d} late, {d} stale (free), {d} stale " ++
                    "(reused), {d} in delivery; {d} runs deferred, {d} batched", .{
                    self.spawned,              self.chained,             self.chained_full,
                    self.refused,              self.results_delivered,   self.results_dropped,
                    self.posts_refused,        self.results_held_max,    self.finished,
                    self.cancelled,            self.failed,              self.cancels_skipped,
                    self.cancels_interrupting, self.cancels_late,        self.cancels_stale_free,
                    self.cancels_stale_reused, self.cancels_in_delivery, self.runs_deferred,
                    self.runs_batched,
                });
            }
        };

        pub fn init(self: *Self) void {
            self.slots = @splat(.free);
            self.entry_count = 0;
            self.results_held = 0;
            self.spawn_count = 0;
            self.expected = .{};
            self.pending_count = 0;
            self.focus = .root;
            self.press_len = 0;
            self.counts = .zero;
            assert(self.expected.spawned == 0);
            assert(self.expected.rows[0].status == .empty);
        }

        pub fn stats(self: *const Self) Stats {
            assert(self.entry_count <= entry_count_max);
            assert(self.results_held <= result_count_max);
            return self.counts;
        }

        pub fn pendingRoom(self: *const Self) u32 {
            assert(self.pending_count <= pending_count_max);
            return pending_count_max - self.pending_count;
        }

        pub fn queue(self: *Self, action: Action) void {
            assert(action != .tick_main);
            switch (action) {
                .job => |turn| {
                    assert(runs == .stepped);
                    self.takeTurn(&turn);
                },
                else => {
                    assert(self.pending_count < pending_count_max);
                    self.pending[self.pending_count] = action;
                    self.pending_count += 1;
                },
            }
        }

        pub fn beginDrain(self: *Self, window: *Window) void {
            assert(window.phase == .idle);
            self.focus = window.focus;
            checkRing(self, window);
            checkPool(self, &window.jobs);
        }

        pub fn endDrain(self: *Self, window: *Window, published: bool) void {
            _ = published;
            assert(window.queue.count == 0);
            const frame = window.rendered();
            var inbox: [entry_count_max]Entry = undefined;
            const inbox_count = self.entry_count;
            @memcpy(inbox[0..inbox_count], self.entries[0..inbox_count]);
            self.entry_count = 0;
            for (self.pending[0..self.pending_count]) |*action| {
                const events = vopr_events.lower(action);
                for (events.slice()) |*event| self.route(frame, event);
            }
            self.pending_count = 0;
            for (inbox[0..inbox_count]) |*entry| self.deliver(entry);
            if (runs == .main_thread) self.runQueued();
            checkRing(self, window);
            checkPool(self, &window.jobs);
        }

        pub fn check(self: *const Self, state: *const State, step_index: u64) void {
            if (std.meta.eql(self.expected, state.*)) return;
            const expected = &self.expected;
            std.debug.panic("vopr jobs model: after step {d} the app shows {d} spawned, " ++
                "{d} refused, {d} results, {d} ended, {d} stray, status {t}; the model " ++
                "expects {d}, {d}, {d}, {d}, {d}, {t}; rows: {any} vs {any}", .{
                step_index,       state.spawned,    state.refused,  state.results,
                state.ended,      state.stray,      state.status,   expected.spawned,
                expected.refused, expected.results, expected.ended, expected.stray,
                expected.status,  state.rows,       expected.rows,
            });
        }

        pub fn biasTarget(window: *Window) ?vopr.Bias {
            const frame = window.rendered();
            var buttons: ?Rect = null;
            for (frame.a11y[0..frame.a11y_count]) |*node| {
                if (node.role != .button) continue;
                buttons = if (buttons) |area| unite(area, node.bounds) else node.bounds;
            }
            return .{ .area = buttons orelse return null, .alternate = null };
        }

        fn takeTurn(self: *Self, job: *const Action.JobStep) void {
            assert(job.slot < slot_count);
            const slot = &self.slots[job.slot];
            assert(slot.busy);
            switch (job.kind) {
                .start => switch (slot.phase) {
                    .pending => slot.phase = .running,
                    .skipped => self.end(job.slot, .cancelled),
                    else => unreachable,
                },
                .post => switch (slot.phase) {
                    .running => self.post(job.slot, .{
                        .value = job.value,
                        .cancel_row = job.cancel_row,
                    }),
                    .interrupting => self.counts.posts_refused += 1,
                    else => unreachable,
                },
                .end => switch (slot.phase) {
                    .running => self.end(job.slot, switch (job.outcome) {
                        .finished => .finished,
                        .failed => .failed,
                        .canceled => .cancelled,
                    }),
                    .interrupting => self.end(job.slot, .cancelled),
                    else => unreachable,
                },
            }
        }

        fn post(self: *Self, index: u32, result: Work.Result) void {
            const slot = &self.slots[index];
            assert(slot.phase == .running);
            assert(!slot.cancel);
            assert(self.results_held < result_count_max);
            self.results_held += 1;
            self.counts.results_held_max = @max(self.counts.results_held_max, self.results_held);
            self.push(.{
                .slot = index,
                .generation = slot.generation,
                .kind = .result,
                .result = result,
                .outcome = .finished,
            });
        }

        fn end(self: *Self, index: u32, outcome: EndOutcome) void {
            const slot = &self.slots[index];
            assert(slot.phase != .idle);
            slot.phase = .idle;
            self.push(.{
                .slot = index,
                .generation = slot.generation,
                .kind = .done,
                .result = .{ .value = 0, .cancel_row = 0 },
                .outcome = outcome,
            });
        }

        fn push(self: *Self, entry: Entry) void {
            assert(entry.slot < slot_count);
            assert(self.slots[entry.slot].busy);
            if (entry.kind == .done) assert(self.slots[entry.slot].phase == .idle);
            assert(self.entry_count < entry_count_max);
            self.entries[self.entry_count] = entry;
            self.entry_count += 1;
        }

        fn deliver(self: *Self, entry: *const Entry) void {
            const slot = &self.slots[entry.slot];
            assert(slot.busy);
            assert(slot.generation == entry.generation);
            const id: gooey.JobId = .{ .slot = entry.slot, .generation = entry.generation };
            switch (entry.kind) {
                .result => {
                    assert(self.results_held > 0);
                    self.results_held -= 1;
                    if (slot.cancel) {
                        self.counts.results_dropped += 1;
                        return;
                    }
                    self.counts.results_delivered += 1;
                    self.appResult(id, &entry.result);
                },
                .done => {
                    assert(slot.phase == .idle);
                    assert(!slot.queued);
                    const outcome = if (slot.cancel) .cancelled else entry.outcome;
                    switch (outcome) {
                        .finished => self.counts.finished += 1,
                        .cancelled => self.counts.cancelled += 1,
                        .failed => self.counts.failed += 1,
                    }
                    slot.busy = false;
                    slot.generation +%= 1;
                    self.appDone(id, outcome);
                },
            }
        }

        fn runQueued(self: *Self) void {
            var turn: u32 = 0;
            while (turn < slot_count) : (turn += 1) {
                const index = self.queuedOldest() orelse return;
                if (self.results_held + Work.posts_max > result_count_max) {
                    self.counts.runs_deferred += 1;
                    return;
                }
                if (self.results_held > 0) self.counts.runs_batched += 1;
                const slot = &self.slots[index];
                slot.queued = false;
                if (slot.phase == .skipped) {
                    self.end(index, .cancelled);
                    continue;
                }
                assert(slot.phase == .pending);
                assert(!slot.cancel);
                slot.phase = .running;
                for (0..slot.input.post_count) |post_index| {
                    self.post(index, resultOf(slot.input.number, @intCast(post_index)));
                }
                self.end(index, if (slot.input.fails) .failed else .finished);
            }
        }

        fn queuedOldest(self: *const Self) ?u32 {
            assert(runs == .main_thread);
            var oldest: ?u32 = null;
            for (&self.slots, 0..) |*slot, index| {
                if (!slot.queued) continue;
                if (oldest) |current| {
                    if (slot.order < self.slots[current].order) oldest = @intCast(index);
                } else {
                    oldest = @intCast(index);
                }
            }
            return oldest;
        }

        fn busyCount(self: *const Self) u32 {
            var count: u32 = 0;
            for (&self.slots) |*slot| count += @intFromBool(slot.busy);
            assert(count <= slot_count);
            if (count == 0) assert(self.results_held == 0);
            return count;
        }

        fn spawnJob(self: *Self, input: Work.Input) ?gooey.JobId {
            assert(input.number > 0);
            assert(input.post_count <= post_count_max);
            for (&self.slots, 0..) |*slot, index| {
                if (slot.busy) continue;
                assert(slot.phase == .idle);
                slot.busy = true;
                slot.phase = .pending;
                slot.cancel = false;
                slot.queued = runs == .main_thread;
                slot.order = self.spawn_count;
                slot.input = input;
                self.spawn_count += 1;
                return .{ .slot = @intCast(index), .generation = slot.generation };
            }
            return null;
        }

        fn cancelJob(self: *Self, id: gooey.JobId) void {
            assert(id.slot < slot_count);
            const slot = &self.slots[id.slot];
            if (!slot.busy) {
                self.counts.cancels_stale_free += 1;
                return;
            }
            if (slot.generation != id.generation) {
                self.counts.cancels_stale_reused += 1;
                return;
            }
            slot.cancel = true;
            switch (slot.phase) {
                .pending => {
                    slot.phase = .skipped;
                    self.counts.cancels_skipped += 1;
                },
                .running => {
                    assert(runs == .stepped);
                    slot.phase = .interrupting;
                    self.counts.cancels_interrupting += 1;
                },
                .idle => self.counts.cancels_late += 1,
                .skipped, .interrupting => {},
            }
        }

        fn appSpawn(self: *Self, chain: bool) void {
            const app = &self.expected;
            assert(app.stray == 0);
            assert(app.spawned == self.spawn_count);
            const number = app.spawned + 1;
            const id = self.spawnJob(inputOf(number, chain)) orelse {
                app.refused += 1;
                app.status = .refused;
                self.counts.refused += 1;
                return;
            };
            const row = rowFree(app);
            app.rows[row] = .{
                .id = id,
                .number = number,
                .chain = chain,
                .status = .running,
                .result_count = 0,
                .value_last = 0,
            };
            app.spawned = number;
            app.status = .spawned;
            self.counts.spawned += 1;
        }

        fn appCancel(self: *Self, row: u32) void {
            assert(row < row_count);
            assert(self.expected.rows.len == row_count);
            const shown = &self.expected.rows[row];
            if (shown.status == .empty) return;
            self.cancelJob(shown.id);
        }

        fn appResult(self: *Self, id: gooey.JobId, result: *const Work.Result) void {
            const app = &self.expected;
            app.results += 1;
            app.status = .result;
            const row = runningRow(app, id) orelse unreachable;
            app.rows[row].result_count += 1;
            app.rows[row].value_last = result.value;
            if (result.cancel_row > 0) {
                self.counts.cancels_in_delivery += 1;
                self.appCancel(result.cancel_row - 1);
            }
        }

        fn appDone(self: *Self, id: gooey.JobId, outcome: EndOutcome) void {
            const app = &self.expected;
            app.ended += 1;
            app.status = .ended;
            const row = runningRow(app, id) orelse unreachable;
            app.rows[row].status = switch (outcome) {
                .finished => .finished,
                .cancelled => .cancelled,
                .failed => .failed,
            };
            if (!app.rows[row].chain) return;
            if (outcome != .finished) return;
            self.counts.chained += 1;
            assert(!self.slots[id.slot].busy);
            const full = self.busyCount() == slot_count - 1;
            const refused_before = app.refused;
            self.appSpawn(false);
            assert(app.refused == refused_before);
            if (full) {
                assert(self.slots[id.slot].busy);
                assert(self.slots[id.slot].generation == id.generation +% 1);
                self.counts.chained_full += 1;
            }
        }

        fn activate(self: *Self, button: ButtonKind) void {
            if (button == .cancel) assert(button.cancel < row_count);
            assert(self.expected.stray == 0);
            switch (button) {
                .spawn => self.appSpawn(false),
                .spawn_chain => self.appSpawn(true),
                .cancel => |row| {
                    self.appCancel(row);
                    self.expected.status = .cancel_sent;
                },
            }
        }

        fn route(self: *Self, frame: *const records.Frame, event: *const Event) void {
            assert(frame.hit_count <= frame.hits.len);
            assert(self.press_len <= press_path_len_max);
            switch (event.*) {
                .down => |down| self.press(frame, down),
                .up => |up| if (up.button == .left) self.release(frame, up.point),
                .key_down => |chord| self.key(frame, chord),
                .pointer_cancelled => self.press_len = 0,
                .moved, .key_up, .other => {},
            }
        }

        fn key(self: *Self, frame: *const records.Frame, chord: Action.Chord) void {
            assert(frame.modal_hit_start <= frame.hit_count);
            if (chord.key == .tab) {
                self.focus = vopr_frame.nextTabStop(frame, self.focus, chord.modifiers.shift);
                return;
            }
            const index = vopr_frame.findHit(frame, self.focus) orelse return;
            const m = chord.modifiers;
            const activates = chord.key == .@"return" or chord.key == .space;
            if (!activates or m.ctrl or m.alt or m.cmd) return;
            if (buttonOf(frame, index)) |button| self.activate(button);
        }

        fn press(self: *Self, frame: *const records.Frame, down: vopr_events.Press) void {
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

        fn release(self: *Self, frame: *const records.Frame, point: Point) void {
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
                    if (buttonOf(frame, index)) |button| self.activate(button);
                    return;
                }
                index = record.parent;
            }
        }
    };
}

fn checkPool(model: anytype, pool: *const jobs.Pool) void {
    assert(pool.slots.len == slot_count);
    assert(pool.mode == @TypeOf(model.*).job_runs);
    for (pool.slots, &model.slots, 0..) |*actual, *expected, index| {
        const phase = actual.phase.load(.acquire);
        const same = actual.busy == expected.busy and
            actual.generation == expected.generation and
            phase == expected.phase and
            actual.queued == expected.queued and
            (!expected.busy or actual.cancel.load(.acquire) == expected.cancel);
        if (same) continue;
        std.debug.panic("vopr jobs model: slot {d} is busy {}, generation {d}, {t}, " ++
            "queued {}, cancel {}; the model expects {}, {d}, {t}, {}, {}", .{
            index,          actual.busy,       actual.generation, phase,
            actual.queued,  actual.cancel.raw, expected.busy,     expected.generation,
            expected.phase, expected.queued,   expected.cancel,
        });
    }
    const held = result_count_max - pool.result_free_count;
    if (held != model.results_held) {
        std.debug.panic("vopr jobs model: {d} result slots held; the model expects {d}", .{
            held,
            model.results_held,
        });
    }
}

fn checkRing(model: anytype, window: *Window) void {
    const ring = &window.completions;
    const tail = ring.tail.load(.monotonic);
    const count = ring.head.load(.acquire) -% tail;
    if (count != model.entry_count) {
        std.debug.panic("vopr jobs model: {d} deliveries on the ring; the model expects {d}", .{
            count,
            model.entry_count,
        });
    }
    const mask: u32 = @intCast(ring.slots.len - 1);
    for (model.entries[0..model.entry_count], 0..) |*expected, offset| {
        const slot = &ring.slots[(tail +% @as(u32, @intCast(offset))) & mask];
        assert(slot.kind == .job);
        checkEntry(&window.jobs, &slot.job, expected, @intCast(offset));
    }
}

fn checkEntry(
    pool: *const jobs.Pool,
    actual: *const internals.events.JobEntry,
    expected: *const Entry,
    offset: u32,
) void {
    var same = actual.slot == expected.slot and actual.generation == expected.generation;
    switch (expected.kind) {
        .result => {
            same = same and actual.kind == .result;
            if (same) {
                const bytes = std.mem.sliceAsBytes(pool.result_blocks)[actual.result_index *
                    pool.result_stride ..][0..@sizeOf(Work.Result)];
                same = std.mem.eql(u8, bytes, std.mem.asBytes(&expected.result));
            }
        },
        .done => {
            same = same and actual.kind == .done;
            same = same and @backingInt(actual.outcome) == @backingInt(expected.outcome);
            if (same and expected.outcome == .failed) same = actual.failure == error.WorkFailed;
        },
    }
    if (same) return;
    std.debug.panic("vopr jobs model: delivery {d} on the ring is {t} of slot {d} " ++
        "generation {d}; the model expects {t} of slot {d} generation {d} ({t})", .{
        offset,        actual.kind,   actual.slot,         actual.generation,
        expected.kind, expected.slot, expected.generation, expected.outcome,
    });
}

fn buttonOf(frame: *const records.Frame, index: u32) ?ButtonKind {
    assert(index < frame.hit_count);
    if (frame.hits[index].on_click == records.index_none) return null;
    const node = vopr_frame.findA11y(frame, frame.hits[index].id) orelse return null;
    assert(node.role == .button);
    var rank: u32 = 0;
    var total: u32 = 0;
    for (frame.hits[0..frame.hit_count], 0..) |*record, other| {
        if (record.on_click == records.index_none) continue;
        if (other < index) rank += 1;
        total += 1;
    }
    assert(total == button_count);
    return switch (rank) {
        0 => .spawn,
        1 => .spawn_chain,
        else => .{ .cancel = rank - 2 },
    };
}

fn runningRow(app: *const State, id: gooey.JobId) ?u32 {
    assert(id.slot < slot_count);
    for (app.rows, 0..) |row, index| {
        if (row.status == .running and std.meta.eql(row.id, id)) return @intCast(index);
    }
    return null;
}

fn rowFree(app: *const State) u32 {
    assert(app.rows.len == row_count);
    var best: ?u32 = null;
    for (app.rows, 0..) |row, index| {
        if (row.status == .running) continue;
        if (best) |current| {
            if (row.number < app.rows[current].number) best = @intCast(index);
        } else {
            best = @intCast(index);
        }
    }
    return best orelse unreachable;
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
