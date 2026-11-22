//! The VOPR's jobs app and its model. The app's buttons spawn background
//! jobs (`Effects.spawn`), plain or chained (`on_done` spawns a successor
//! when the job finishes), and cancel the job a row shows; each row keeps
//! its job's id after the job ends, so its Cancel is then a stale cancel,
//! often against a slot another job reuses. A result may ask `on_result` to
//! cancel a row, so cancels also land inside a drain's deliveries.
//!
//! No thread runs a job. In `jobs` (`jobs.Mode.stepped`) the harness plays
//! each slot's runner and interrupter (`Action.job`): it takes a spawn, posts
//! results it makes up while a result slot is free, and ends the run as it
//! chooses, at seed-chosen points between input, `tickMain`, and
//! `presentBuilt`; a job left running across frames can be cancelled, and
//! then its posts are refused and the interrupter ends it. In
//! `jobs_main_thread` (`.main_thread`) the drain runs `Work.run` itself.
//!
//! The model is written from the jobs contract, not from `jobs.zig`: it
//! keeps its own job table (slots, generations, phases, cancel flags, held
//! results) and the deliveries pushed since the last drain, and routes each
//! drain as the core must: input in queue order, then the deliveries in push
//! order, then, on the main thread, the queued jobs in spawn order while
//! their `posts_max` result slots are free. It predicts `on_result` calls in post order,
//! exactly one `on_done` per job with its outcome (`.cancelled` whenever a
//! cancel lands before the end is delivered), the results a cancel drops,
//! which spawns `error.JobBusy` refuses, and every row the app shows. It
//! checks the app's state after every step, and the core's job table and
//! completion ring, byte for byte, around every drain.

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

/// `nano` with three job slots and four result slots: a few clicks fill
/// both, and three main-thread jobs of up to three posts each outrun the
/// results one drain frees.
pub const limits = blk: {
    var budget = gooey.ResourceLimits.nano;
    budget.events.job_count_max = 3;
    budget.events.job_result_count_max = 4;
    break :blk budget;
};

const slot_count: u32 = limits.events.job_count_max;
const result_count_max: u32 = limits.events.job_result_count_max;
/// Rows the app shows: one more than the slots, so a granted spawn always
/// finds a row whose job ended, and an ended job's id stays on screen until
/// a later spawn needs its row.
pub const row_count: u32 = slot_count + 1;
/// Results one job posts on the main thread at most (`Work.run`).
const post_count_max: u32 = 3;
/// Deliveries waiting for a drain at most: every held result and one end
/// per slot, as `ResourceLimits.check` reserves on the completion ring.
const entry_count_max: u32 = result_count_max + slot_count;
/// Input actions one drain can hold, as the queue's capacity.
const pending_count_max: u32 = limits.events.queue_count_max;
/// Ids one press lands in: one per box on the path to the root.
const press_path_len_max: u32 = internals.window.box_depth_ceiling;
/// The app's buttons, in tree order: Spawn, Spawn chain, then each row's
/// Cancel.
const button_count: u32 = 2 + row_count;

comptime {
    assert(post_count_max <= result_count_max);
    assert(post_count_max * slot_count > result_count_max);
    assert(row_count > slot_count);
}

/// The app's one job type. On the main thread `run` posts what its input
/// says; in `.stepped` the harness plays every run and `run` is never called.
pub const Work = struct {
    pub const Input = struct {
        number: u32,
        post_count: u32,
        fails: bool,
        chain: bool,
    };
    pub const Result = struct {
        value: u32,
        /// The row `on_result` cancels, plus one; 0 for none.
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

/// What spawn number `number` asks of its job; a pure function, so the
/// model predicts it.
pub fn inputOf(number: u32, chain: bool) Work.Input {
    assert(number > 0);
    return .{
        .number = number,
        .post_count = number % (post_count_max + 1),
        .fails = number % 5 == 4,
        .chain = chain,
    };
}

/// The main-thread run's `index`-th result: the first result of every
/// third job asks `on_result` to cancel a row.
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
    /// The spawn's number, from 1; 0 for an empty row.
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

/// The last thing the app did, which its status line shows.
pub const Status = enum { idle, spawned, refused, cancel_sent, result, ended };

pub const State = struct {
    rows: [row_count]Row = @splat(.empty),
    /// Spawns granted, which number them from 1.
    spawned: u32 = 0,
    refused: u32 = 0,
    results: u32 = 0,
    ended: u32 = 0,
    /// Deliveries for a job no row shows running; the contract keeps it 0.
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

    /// A chained job that finished spawns its successor here, while its own
    /// slot is still held: with the other slots busy, that is refused.
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

    /// Cancel the row's job, whatever its state: an ended job's id is stale.
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

/// Bytes of one row's text at most: "#" and 10 digits, " cancelled: ", 10
/// digits, " results, last ", and 10 digits.
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
            // The longest text, three u32s of 10 digits and "cancelled", is
            // 58 bytes (`row_text_bytes_max`), so the buffer always holds it.
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

/// One job slot as the contract describes it.
const Slot = struct {
    busy: bool,
    generation: u32,
    phase: Phase,
    cancel: bool,
    /// `.main_thread`: spawned and not yet run by a drain.
    queued: bool,
    /// The spawn's place among all spawns, for the main thread's order.
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

/// One delivery waiting for a drain: a result, or a job's end.
const Entry = struct {
    slot: u32,
    generation: u32,
    kind: enum { result, done },
    result: Work.Result,
    /// For `.done`: how the run ended, before a later cancel overrides it.
    outcome: EndOutcome,
};

const EndOutcome = enum { finished, cancelled, failed };

const ButtonKind = union(enum) { spawn, spawn_chain, cancel: u32 };

pub fn JobsModel(comptime runs: jobs.Mode) type {
    comptime assert(runs != .workers);
    return struct {
        slots: [slot_count]Slot,
        /// Deliveries pushed since the last drain, in push order.
        entries: [entry_count_max]Entry,
        entry_count: u32,
        /// Result slots claimed and not yet delivered or dropped.
        results_held: u32,
        /// Spawns granted since init, as the core counts them.
        spawn_count: u64,
        /// What the app must show.
        expected: State,
        /// Input the next drain routes, in queue order.
        pending: [pending_count_max]Action,
        pending_count: u32,
        /// Focus within the drain being routed; read from the window first.
        focus: ElementId,
        /// The ids the last left press landed in, innermost first.
        press_path: [press_path_len_max]ElementId,
        press_len: u32,
        counts: Stats,

        const Self = @This();

        /// Who runs the app's jobs (`Vopr.job_runs`).
        pub const job_runs = runs;
        /// What the harness posts for the app's job (`Action.job`).
        pub const JobResult = Work.Result;
        pub const job_row_count = row_count;

        /// The kinds jobs' swarm draws weights for, in this order: on the
        /// main thread there are no workers to step.
        pub const action_kinds: []const vopr.ActionKind = switch (runs) {
            .stepped => &.{ .pointer, .key, .wait_ns, .tick_main, .present, .resize, .job },
            .main_thread => &.{ .pointer, .key, .wait_ns, .tick_main, .present, .resize },
            .workers => unreachable,
        };

        /// Keys that move focus along the buttons and press them.
        pub const key_choices: []const gooey.input.KeyCode = &.{
            .tab, .space, .@"return", .escape,
        };

        pub const Stats = struct {
            spawned: u32,
            chained: u32,
            refused: u32,
            /// Refusals of a chained job's successor, inside `on_done`.
            refused_chain: u32,
            results_delivered: u32,
            results_dropped: u32,
            /// Posts of a cancelled running job, which return false.
            posts_refused: u32,
            finished: u32,
            cancelled: u32,
            failed: u32,
            /// Cancels of a job no runner had taken: `run` never ran.
            cancels_skipped: u32,
            /// Cancels of a running job, which its interrupter ended.
            cancels_interrupting: u32,
            /// Cancels after the job's end was pushed, before it arrived.
            cancels_late: u32,
            /// Cancels of an id whose slot was free, or held by a later job.
            cancels_stale_free: u32,
            cancels_stale_reused: u32,
            /// Cancels from `on_result`, inside a drain's deliveries.
            cancels_in_delivery: u32,
            /// Main-thread drains that left a job queued behind held results.
            runs_deferred: u32,
            /// Main-thread runs that started beside another run's results.
            runs_batched: u32,
            results_held_max: u32,

            const zero: Stats = std.mem.zeroes(Stats);

            pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                try writer.print("{d} spawned ({d} chained), {d} refused ({d} in on_done); " ++
                    "{d} results delivered, {d} dropped, {d} posts refused, at most {d} " ++
                    "held; ends: {d} finished, {d} cancelled, {d} failed; cancels: {d} " ++
                    "skipped, {d} interrupting, {d} late, {d} stale (free), {d} stale " ++
                    "(reused), {d} in delivery; {d} runs deferred, {d} batched", .{
                    self.spawned,              self.chained,             self.refused,
                    self.refused_chain,        self.results_delivered,   self.results_dropped,
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

        /// Room for one more input action in the queue.
        pub fn pendingRoom(self: *const Self) u32 {
            assert(self.pending_count <= pending_count_max);
            return pending_count_max - self.pending_count;
        }

        /// Record input for the next drain; apply a worker's step now, as
        /// the harness does.
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

        /// The ring holds exactly the deliveries the model expects.
        pub fn beginDrain(self: *Self, window: *Window) void {
            assert(window.phase == .idle);
            self.focus = window.focus;
            checkRing(self, window);
            checkPool(self, &window.jobs);
        }

        /// Route the drain as the core must, then run the main thread's
        /// queued jobs, and compare the core's job table.
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

        /// Where the generator aims: every button.
        pub fn biasTarget(window: *Window) ?vopr.Bias {
            const frame = window.rendered();
            var buttons: ?Rect = null;
            for (frame.a11y[0..frame.a11y_count]) |*node| {
                if (node.role != .button) continue;
                buttons = if (buttons) |area| unite(area, node.bounds) else node.bounds;
            }
            return .{ .area = buttons orelse return null, .alternate = null };
        }

        /// A worker's step the harness took: a runner taking a spawn, a
        /// post, or a run's end, which for a cancelled job is the
        /// interrupter's.
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

        /// Pushed here and checked against the ring at the next drain
        /// (`checkRing`).
        fn push(self: *Self, entry: Entry) void {
            assert(entry.slot < slot_count);
            assert(self.slots[entry.slot].busy);
            if (entry.kind == .done) assert(self.slots[entry.slot].phase == .idle);
            assert(self.entry_count < entry_count_max);
            self.entries[self.entry_count] = entry;
            self.entry_count += 1;
        }

        /// One delivery: `on_result` unless the job was cancelled first,
        /// which drops it; `on_done`, with `.cancelled` if any cancel landed
        /// first, then the slot frees under its next generation.
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
                    self.appDone(id, outcome);
                    // After `on_done` returns: a spawn inside it found this
                    // slot held.
                    slot.busy = false;
                    slot.generation +%= 1;
                },
            }
        }

        /// The main thread runs its queued jobs in spawn order, each only
        /// while `Work.posts_max` result slots are free, so no post finds
        /// the pool full; the first that does not fit, and every later
        /// spawn, waits for the next drain.
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

        /// `Effects.spawn`: the lowest free slot, or `error.JobBusy`.
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

        /// `Effects.cancelJob`: a live id marks its job and moves it out of
        /// `pending` or `running`; a stale one does nothing.
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
            const row = runningRow(app, id) orelse unreachable; // Delivered only while busy.
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
            const row = runningRow(app, id) orelse unreachable; // One end per job.
            app.rows[row].status = switch (outcome) {
                .finished => .finished,
                .cancelled => .cancelled,
                .failed => .failed,
            };
            if (!app.rows[row].chain) return;
            if (outcome != .finished) return;
            self.counts.chained += 1;
            const refused_before = app.refused;
            self.appSpawn(false);
            if (app.refused > refused_before) self.counts.refused_chain += 1;
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

        /// Tab moves focus; Enter or Space without Cmd, Ctrl, or Alt
        /// presses the focused button (`router.activates`).
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

        /// A press of any button focuses; a left press records its path.
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

        /// A left release clicks the innermost `on_click` under it that the
        /// left press also landed in.
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

/// The core's job table matches the model's, slot by slot, and so does the
/// count of held result slots.
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

/// The completion ring holds exactly the model's deliveries, in order, and
/// each held result slot the bytes posted to it.
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

/// Which button record `index` is: its rank among the click records, in
/// tree order, which is the app's button order.
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

/// The row a spawn takes, as the app chooses it: the oldest that is not
/// running, empty first, lowest index on a tie. More rows than slots, so one
/// is never running.
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
    return best orelse unreachable; // More rows than slots: one is not running.
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
