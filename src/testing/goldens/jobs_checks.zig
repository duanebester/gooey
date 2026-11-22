//! Background jobs (`Effects.spawn`) through a headless app, as the core's
//! job and cancellation semantics promise: posts arrive as handler calls in
//! post order and wake the host, a full result pool holds the worker back
//! without losing a result, cancellation interrupts a job blocked in Io at
//! once and drops what was not delivered, a cancelled slot runs its next
//! job, and shutdown cancels and joins every worker before `on_deinit`.
//! `jobs_main_thread_checks.zig` covers the path without workers. Workers
//! are real threads on `std.testing.io`, so each check waits for them with a
//! bounded number of short sleeps rather than a fixed delay.

const std = @import("std");
const gooey = @import("gooey");
const background = @import("background_example");

const Effects = gooey.Effects;
const testing = std.testing;
const assert = std.debug.assert;

/// The most 1 ms waits a check spends on one condition: 10 s.
const wait_count_max: u32 = 10_000;

// Job bodies cannot reach `State`; they report to the checks through these.
var job_started_count: std.atomic.Value(u32) = .init(0);
var job_returned_count: std.atomic.Value(u32) = .init(0);
var job_gate_open: std.atomic.Value(bool) = .init(false);
var deinit_saw_returned: std.atomic.Value(u32) = .init(std.math.maxInt(u32));
var deinit_saw_started: std.atomic.Value(u32) = .init(std.math.maxInt(u32));
var job_io_cancelled_count: std.atomic.Value(u32) = .init(0);
var late_post_refused_count: std.atomic.Value(u32) = .init(0);

const Count = struct {
    pub const Input = struct {
        first: u32,
        count: u32,
        fail: bool,
        /// Wait for `job_gate_open` before posting.
        gated: bool,
        /// Sleep between posts, in milliseconds.
        gap_ms: u32,
    };
    pub const Result = struct { value: u32, pad: [60]u8 };
    /// These checks run on workers, whose posts wait for a drain, so `run`
    /// may post more; on the main thread a run past this fails fast.
    pub const posts_max: u32 = limits.events.job_result_count_max;

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        _ = job_started_count.fetchAdd(1, .acq_rel);
        defer _ = job_returned_count.fetchAdd(1, .acq_rel);
        const io = job.io();
        if (input.gated) {
            for (0..wait_count_max) |_| {
                if (job_gate_open.load(.acquire)) break;
                try io.sleep(.fromMilliseconds(1), .awake);
            }
        }
        for (0..input.count) |index| {
            const value = input.first + @as(u32, @intCast(index));
            const result: Result = .{ .value = value, .pad = @splat(7) };
            if (!job.post(&result)) return error.Canceled;
            if (input.gap_ms > 0) try io.sleep(.fromMilliseconds(input.gap_ms), .awake);
        }
        if (input.fail) return error.Boom;
    }
};

fn counting(first: u32, count: u32, flags: struct { fail: bool, gated: bool }) Count.Input {
    return .{
        .first = first,
        .count = count,
        .fail = flags.fail,
        .gated = flags.gated,
        .gap_ms = 0,
    };
}

/// Sleeps for a minute: only cancellation ends it early.
const Sleep = struct {
    pub const Input = struct { seconds: u32 };
    pub const Result = struct { never: u8 };
    pub const posts_max: u32 = 0;

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        _ = job_started_count.fetchAdd(1, .acq_rel);
        defer _ = job_returned_count.fetchAdd(1, .acq_rel);
        job.io().sleep(.fromSeconds(input.seconds), .awake) catch |err| {
            _ = job_io_cancelled_count.fetchAdd(1, .acq_rel);
            return err;
        };
    }
};

/// Connects to `port` on loopback and reads, from a peer that never writes:
/// only cancellation ends the read.
const Read = struct {
    pub const Input = struct { port: u16 };
    pub const Result = struct { never: u8 };
    pub const posts_max: u32 = 0;

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        _ = job_started_count.fetchAdd(1, .acq_rel);
        defer _ = job_returned_count.fetchAdd(1, .acq_rel);
        const io = job.io();
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(input.port) };
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var buffer: [16]u8 = undefined;
        var reader = stream.reader(io, &buffer);
        _ = reader.interface.takeByte() catch |err| switch (err) {
            error.ReadFailed => {
                const read_error = reader.err.?;
                if (read_error == error.Canceled) {
                    _ = job_io_cancelled_count.fetchAdd(1, .acq_rel);
                }
                return read_error;
            },
            error.EndOfStream => return error.EndOfStream,
        };
    }
};

const Spin = struct {
    pub const Input = struct { unused: u8 };
    pub const Result = struct { value: u32 };
    /// The one post after the cancel, which is refused.
    pub const posts_max: u32 = 1;

    /// Checks of `job.cancelled()`: well past the 10 s a check waits.
    const spin_count_max: u64 = 1 << 40;

    pub fn run(_: *const Input, job: *gooey.Job(Result)) !void {
        _ = job_started_count.fetchAdd(1, .acq_rel);
        defer _ = job_returned_count.fetchAdd(1, .acq_rel);
        var spins: u64 = 0;
        while (!job.cancelled()) : (spins += 1) {
            if (spins == spin_count_max) return error.NeverCancelled;
            std.atomic.spinLoopHint();
        }
        if (!job.post(&.{ .value = 1 })) _ = late_post_refused_count.fetchAdd(1, .acq_rel);
        job.io().sleep(.fromSeconds(60), .awake) catch |err| {
            _ = job_io_cancelled_count.fetchAdd(1, .acq_rel);
            return err;
        };
    }
};

const Flood = struct {
    pub const Input = struct { unused: u8 };
    pub const Result = struct { value: u64 };
    /// Workers only: it posts until the pool holds it back.
    pub const posts_max: u32 = limits.events.job_result_count_max;

    pub fn run(_: *const Input, job: *gooey.Job(Result)) void {
        _ = job_started_count.fetchAdd(1, .acq_rel);
        defer _ = job_returned_count.fetchAdd(1, .acq_rel);
        var value: u64 = 0;
        // Bounded: the pool holds `job_result_count_max` posts until a drain,
        // and the checks stop the app instead of draining.
        while (value < 1 << 32) : (value += 1) {
            if (!job.post(&.{ .value = value })) return;
        }
    }
};

const State = struct {
    received: [64]u32 = @splat(0),
    received_count: u32 = 0,
    /// Every delivery in order: a result's value, or `done_marker` plus the
    /// job's slot for its end.
    log: [64]u32 = @splat(0),
    log_count: u32 = 0,
    other_count: u32 = 0,
    done_count: u32 = 0,
    outcome: ?Effects.JobOutcome = null,
    last: ?gooey.JobId = null,
    init_saw_io: bool = false,
    /// The next `on_done` spawns a `Sleep`, as a chained job or a retry
    /// would, and records what the spawn returned.
    chain_on_done: bool = false,
    chained: ?gooey.JobId = null,
    chain_refused: bool = false,

    fn onCount(self: *State, effects: *Effects) void {
        const result = effects.jobResult(Count).?;
        assert(effects.jobResult(Sleep) == null);
        assert(effects.jobDone() == null);
        assert(result.pad[59] == 7);
        assert(self.received_count < self.received.len);
        self.received[self.received_count] = result.value;
        self.received_count += 1;
        self.record(result.value);
    }

    fn onDone(self: *State, effects: *Effects) void {
        const done = effects.jobDone().?;
        assert(std.meta.eql(done.id, effects.jobId().?));
        self.done_count += 1;
        self.outcome = done.outcome;
        self.record(done_marker + done.id.slot);
        if (self.chain_on_done) {
            self.chain_on_done = false;
            self.chainFrom(effects, done.id);
        }
    }

    /// Spawn the follow-up from `on_done`, then cancel the finished job's
    /// own id, which is stale and must not reach the follow-up.
    fn chainFrom(self: *State, effects: *Effects, finished_id: gooey.JobId) void {
        assert(self.chained == null);
        assert(!self.chain_refused);
        self.chained = effects.spawn(Sleep, &.{ .seconds = 60 }, .{
            .on_done = effects.handler(State.onDone),
        }) catch |err| switch (err) {
            error.JobBusy => blk: {
                self.chain_refused = true;
                break :blk null;
            },
        };
        effects.cancelJob(finished_id);
    }

    fn onFlood(_: *State, effects: *Effects) void {
        assert(effects.jobResult(Flood) != null);
    }

    fn onOther(self: *State, effects: *Effects) void {
        assert(effects.jobResult(Spin) != null);
        self.other_count += 1;
    }

    fn record(self: *State, entry: u32) void {
        if (self.log_count < self.log.len) {
            self.log[self.log_count] = entry;
            self.log_count += 1;
        }
    }

    fn init(self: *State, init_value: gooey.Init, effects: *Effects) void {
        _ = init_value.io;
        self.init_saw_io = init_value.environ.count() == 0;
        self.last = effects.spawn(Count, &.{
            .first = 900,
            .count = 1,
            .fail = false,
            .gated = false,
            .gap_ms = 0,
        }, .{
            .on_result = effects.handler(State.onCount),
            .on_done = effects.handler(State.onDone),
        }) catch |err| switch (err) {
            // The app's first spawn: every slot is free.
            error.JobBusy => unreachable,
        };
    }

    fn deinit(_: *State) void {
        deinit_saw_returned.store(job_returned_count.load(.acquire), .release);
        deinit_saw_started.store(job_started_count.load(.acquire), .release);
    }
};

/// What `State.log` records for a job's end, plus its slot.
const done_marker: u32 = 1_000;

fn render(cx: *gooey.Cx) void {
    cx.render(gooey.ui.box(.{}, .{}));
}

/// `nano` with four job slots, so a check can run three jobs beside the one
/// `on_init` spawned; the ring still holds every completion (2 dialogs, the
/// decode, 8 results, 4 ends: 15 of 16).
const limits = blk: {
    var budget = gooey.ResourceLimits.nano;
    budget.events.job_count_max = 4;
    break :blk budget;
};

const App = gooey.App(State, render, .{
    .title = "Jobs",
    .width = 200,
    .height = 100,
    .limits = limits,
    .jobs = &.{ Count, Sleep, Flood, Read, Spin },
    .on_init = State.init,
    .on_deinit = State.deinit,
});

const Wake = struct {
    count: std.atomic.Value(u32) = .init(0),

    fn wake(context: *anyopaque) void {
        const self: *Wake = @ptrCast(@alignCast(context));
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    fn service(self: *Wake) gooey.internals.window.WakeService {
        return .{ .context = self, .wake = wake };
    }
};

const Harness = struct {
    app: *App,
    now: u64,
    wake: Wake,

    fn init(self: *Harness) !void {
        job_started_count.store(0, .release);
        job_returned_count.store(0, .release);
        job_gate_open.store(false, .release);
        job_io_cancelled_count.store(0, .release);
        late_post_refused_count.store(0, .release);
        deinit_saw_returned.store(std.math.maxInt(u32), .release);
        self.app = try testing.allocator.create(App);
        errdefer testing.allocator.destroy(self.app);
        try self.app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
        self.now = 0;
        self.wake = .{};
        self.app.window.bindWake(self.wake.service());
        // Deliver the job on_init spawned, so each check starts clean.
        self.waitUntil(struct {
            fn done(state: *const State) bool {
                return state.done_count == 1;
            }
        }.done);
        assert(self.app.state.received[0] == 900);
        // Headless apps get the test io and an empty environment.
        assert(self.app.state.init_saw_io);
        self.app.state = .{};
    }

    fn deinit(self: *Harness) void {
        self.app.stop();
        self.app.window.bindWake(null);
        self.app.deinit();
        testing.allocator.destroy(self.app);
    }

    fn tick(self: *Harness) void {
        self.now += 1_000_000;
        self.app.tick(self.now);
    }

    /// Spawn a job every check expects to start: it keeps within the
    /// table, so a refusal is a failed check.
    fn spawn(self: *Harness, comptime Job: type, input: Job.Input) gooey.JobId {
        return self.trySpawn(Job, input) catch |err| {
            std.debug.panic("jobs_checks: spawn of {s} refused: {t}", .{ @typeName(Job), err });
        };
    }

    fn trySpawn(self: *Harness, comptime Job: type, input: Job.Input) !gooey.JobId {
        var effects = Effects.init(null, .root);
        effects.jobs = &self.app.window.jobs;
        const on_result: ?gooey.Handler = switch (Job) {
            Flood => effects.handler(State.onFlood),
            Count => effects.handler(State.onCount),
            Spin => effects.handler(State.onOther),
            else => null,
        };
        return effects.spawn(Job, &input, .{
            .on_result = on_result,
            .on_done = effects.handler(State.onDone),
        });
    }

    fn cancel(self: *Harness, id: gooey.JobId) void {
        var effects = Effects.init(null, .root);
        effects.jobs = &self.app.window.jobs;
        effects.cancelJob(id);
    }

    /// Tick until `done_count` reaches `count`, for at most `ms_max`
    /// milliseconds, and return the time it took; a check expects the
    /// count afterwards rather than panicking here.
    fn waitForDone(self: *Harness, count: u32, ms_max: u32) std.Io.Duration {
        const start = std.Io.Timestamp.now(testing.io, .awake);
        for (0..ms_max) |_| {
            self.tick();
            if (self.app.state.done_count >= count) break;
            testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        }
        return start.durationTo(std.Io.Timestamp.now(testing.io, .awake));
    }

    fn waitUntil(self: *Harness, condition: *const fn (*const State) bool) void {
        for (0..wait_count_max) |_| {
            self.tick();
            if (condition(&self.app.state)) return;
            testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        }
        std.debug.panic("jobs_checks: condition not reached in {d} ms", .{wait_count_max});
    }

    fn waitForWakes(self: *Harness, count: u32) void {
        for (0..wait_count_max) |_| {
            if (self.wake.count.load(.acquire) >= count) return;
            testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        }
        std.debug.panic("jobs_checks: {d} wakes not reached", .{count});
    }

    fn waitForStarted(_: *Harness, count: u32) void {
        for (0..wait_count_max) |_| {
            if (job_started_count.load(.acquire) >= count) return;
            testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        }
        std.debug.panic("jobs_checks: {d} started jobs not reached", .{count});
    }
};

fn finished(state: *const State) bool {
    return state.done_count > 0;
}

test "a job's posts arrive in post order as handler calls, then on_done once" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const wakes_before = harness.wake.count.load(.acquire);
    var input: Count.Input = counting(10, 5, .{ .fail = false, .gated = false });
    const id = harness.spawn(Count, input);
    input.first = 99;
    harness.waitForWakes(wakes_before + 6);
    harness.tick();
    const state = &harness.app.state;
    try testing.expectEqual(@as(u32, 5), state.received_count);
    try testing.expectEqualSlices(u32, &.{ 10, 11, 12, 13, 14 }, state.received[0..5]);
    try testing.expectEqual(@as(u32, 1), state.done_count);
    try testing.expect(state.outcome.? == .finished);
    try testing.expect(harness.app.window.renderDeadlineNs() == null);
    try testing.expectEqual(@as(u32, 0), harness.app.window.jobs.busyCount());
    // The finished job's id is stale: cancelling it does nothing.
    var effects = Effects.init(null, .root);
    effects.jobs = &harness.app.window.jobs;
    effects.cancelJob(id);
}

test "a job that fails reports its error after its results" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    _ = harness.spawn(Count, counting(1, 2, .{ .fail = true, .gated = false }));
    harness.waitUntil(finished);
    try testing.expectEqual(@as(u32, 2), harness.app.state.received_count);
    try testing.expectEqual(error.Boom, harness.app.state.outcome.?.failed);
}

test "a full result pool holds the worker back and loses nothing" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const pool_count = limits.events.job_result_count_max;
    try testing.expectEqual(@as(u32, 8), pool_count);
    const wakes_before = harness.wake.count.load(.acquire);
    _ = harness.spawn(Count, counting(0, 40, .{ .fail = false, .gated = false }));
    harness.waitForWakes(wakes_before + pool_count);
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectEqual(wakes_before + pool_count, harness.wake.count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), harness.app.state.received_count);
    harness.waitUntil(finished);
    const state = &harness.app.state;
    try testing.expectEqual(@as(u32, 40), state.received_count);
    for (state.received[0..40], 0..) |value, index| try testing.expectEqual(index, value);
    try testing.expect(state.outcome.? == .finished);
}

test "cancelling drops undelivered results and ends with cancelled" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const wakes_before = harness.wake.count.load(.acquire);
    const id = harness.spawn(Count, counting(0, 40, .{ .fail = false, .gated = false }));
    harness.waitForWakes(wakes_before + 8);
    var effects = Effects.init(null, .root);
    effects.jobs = &harness.app.window.jobs;
    effects.cancelJob(id);
    harness.waitUntil(finished);
    try testing.expectEqual(@as(u32, 0), harness.app.state.received_count);
    try testing.expect(harness.app.state.outcome.? == .cancelled);
    // The slot is free again under a new generation.
    const next = harness.spawn(Count, counting(5, 1, .{ .fail = false, .gated = false }));
    try testing.expect(!std.meta.eql(next, id));
}

/// The most a cancel may take to reach `on_done` from a job blocked in Io:
/// the job sleeps or reads for a minute, so only an interrupt meets it.
const cancel_ms_max: u32 = 1_000;

test "cancelling a job blocked in a sleep interrupts the sleep at once" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const id = harness.spawn(Sleep, .{ .seconds = 60 });
    // The job on_init spawned started first.
    harness.waitForStarted(2);
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    harness.cancel(id);
    const took = harness.waitForDone(1, cancel_ms_max);
    try testing.expectEqual(@as(u32, 1), harness.app.state.done_count);
    try testing.expect(took.toMilliseconds() < cancel_ms_max);
    try testing.expect(harness.app.state.outcome.? == .cancelled);
    try testing.expectEqual(@as(u32, 1), job_io_cancelled_count.load(.acquire));
    // The job and the one on_init spawned.
    try testing.expectEqual(@as(u32, 2), job_returned_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), harness.app.window.jobs.busyCount());
}

test "cancelling a job blocked in a socket read interrupts the read at once" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{});
    defer server.deinit(testing.io);
    const id = harness.spawn(Read, .{ .port = server.socket.address.getPort() });
    harness.waitForStarted(2);
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(u32, 1), job_returned_count.load(.acquire));
    harness.cancel(id);
    const took = harness.waitForDone(1, cancel_ms_max);
    try testing.expectEqual(@as(u32, 1), harness.app.state.done_count);
    try testing.expect(took.toMilliseconds() < cancel_ms_max);
    try testing.expect(harness.app.state.outcome.? == .cancelled);
    try testing.expectEqual(@as(u32, 1), job_io_cancelled_count.load(.acquire));
}

test "a job cancelled before its runner starts it never runs" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const pool = &harness.app.window.jobs;
    for (0..3) |round| {
        var gate: std.Io.Event = .unset;
        pool.runner_gate = &gate;
        const started_before = job_started_count.load(.acquire);
        const id = harness.spawn(Count, counting(@intCast(round), 1, .{
            .fail = false,
            .gated = false,
        }));
        try testing.io.sleep(.fromMilliseconds(5), .awake);
        harness.cancel(id);
        try testing.expectEqual(started_before, job_started_count.load(.acquire));
        gate.set(testing.io);
        _ = harness.waitForDone(1, wait_count_max);
        pool.runner_gate = null;
        const state = &harness.app.state;
        try testing.expectEqual(@as(u32, 1), state.done_count);
        try testing.expect(state.outcome.? == .cancelled);
        try testing.expectEqual(@as(u32, 0), state.received_count);
        try testing.expectEqual(started_before, job_started_count.load(.acquire));
        harness.app.state = .{};
        _ = harness.spawn(Count, counting(50, 1, .{ .fail = false, .gated = false }));
        harness.waitUntil(finished);
        try testing.expect(state.outcome.? == .finished);
        try testing.expectEqualSlices(u32, &.{50}, state.received[0..state.received_count]);
        harness.app.state = .{};
    }
}

test "a cancel racing the runner's start ends the job cancelled, 200 times" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    for (0..200) |round| {
        const id = harness.spawn(Count, counting(@intCast(round), 1, .{
            .fail = false,
            .gated = false,
        }));
        harness.cancel(id);
        _ = harness.waitForDone(1, wait_count_max);
        try testing.expectEqual(@as(u32, 1), harness.app.state.done_count);
        try testing.expect(harness.app.state.outcome.? == .cancelled);
        try testing.expectEqual(@as(u32, 0), harness.app.state.received_count);
        harness.app.state = .{};
    }
    try testing.expectEqual(job_started_count.load(.acquire), job_returned_count.load(.acquire));
}

test "a cancel after a job's results and end were posted drops them, and the slot runs on" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const wakes_before = harness.wake.count.load(.acquire);
    const id = harness.spawn(Count, counting(10, 3, .{ .fail = false, .gated = false }));
    harness.waitForWakes(wakes_before + 4);
    try testing.expectEqual(@as(u32, 2), job_returned_count.load(.acquire));
    harness.cancel(id);
    harness.tick();
    const state = &harness.app.state;
    try testing.expectEqual(@as(u32, 0), state.received_count);
    try testing.expectEqual(@as(u32, 1), state.done_count);
    try testing.expect(state.outcome.? == .cancelled);
    harness.app.state = .{};
    var input = counting(20, 3, .{ .fail = false, .gated = false });
    input.gap_ms = 5;
    const next = harness.spawn(Count, input);
    try testing.expectEqual(id.slot, next.slot);
    try testing.expectEqual(id.generation +% 1, next.generation);
    harness.waitUntil(finished);
    try testing.expect(state.outcome.? == .finished);
    try testing.expectEqualSlices(u32, &.{ 20, 21, 22 }, state.received[0..state.received_count]);
}

test "a post after the cancel is refused and the job's next Io call is interrupted" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const id = harness.spawn(Spin, .{ .unused = 0 });
    harness.waitForStarted(2);
    harness.cancel(id);
    const took = harness.waitForDone(1, cancel_ms_max);
    try testing.expectEqual(@as(u32, 1), harness.app.state.done_count);
    try testing.expect(took.toMilliseconds() < cancel_ms_max);
    try testing.expect(harness.app.state.outcome.? == .cancelled);
    try testing.expectEqual(@as(u32, 1), late_post_refused_count.load(.acquire));
    try testing.expectEqual(@as(u32, 1), job_io_cancelled_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), harness.app.state.other_count);
}

test "a slot interrupted 50 times keeps running jobs to the end" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var last: ?gooey.JobId = null;
    for (0..50) |round| {
        const id = harness.spawn(Sleep, .{ .seconds = 60 });
        try testing.expectEqual(@as(u32, 0), id.slot);
        if (last) |previous| try testing.expectEqual(previous.generation +% 1, id.generation);
        harness.waitForStarted(@intCast(round + 2));
        harness.cancel(id);
        const took = harness.waitForDone(1, cancel_ms_max);
        try testing.expectEqual(@as(u32, 1), harness.app.state.done_count);
        try testing.expect(took.toMilliseconds() < cancel_ms_max);
        try testing.expect(harness.app.state.outcome.? == .cancelled);
        harness.app.state = .{};
        last = id;
    }
    try testing.expectEqual(@as(u32, 50), job_io_cancelled_count.load(.acquire));
    _ = harness.spawn(Count, counting(7, 2, .{ .fail = false, .gated = false }));
    harness.waitUntil(finished);
    try testing.expect(harness.app.state.outcome.? == .finished);
    try testing.expectEqualSlices(u32, &.{ 7, 8 }, harness.app.state.received[0..2]);
}

test "a full job table frees a cancelled job's slot only when its on_done is delivered" {
    // Fill the table exactly, then spawn one more: once a panic, which a
    // click per spawn reached (the VOPR's jobs app, seed 1), now
    // `error.JobBusy`, which claims nothing. A cancelled job whose end was
    // pushed still holds its slot, so a spawn before the drain that
    // delivers its `on_done` is refused too; the one after takes its slot.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const pool = &harness.app.window.jobs;
    const slot_count = limits.events.job_count_max;
    var ids: [slot_count]gooey.JobId = undefined;
    for (&ids) |*id| id.* = harness.spawn(Sleep, .{ .seconds = 60 });
    try testing.expectEqual(slot_count, pool.busyCount());
    try testing.expectEqual(slot_count - 1, ids[slot_count - 1].slot);
    const spawned_before = pool.spawned_count;
    try testing.expectError(error.JobBusy, harness.trySpawn(Sleep, .{ .seconds = 60 }));
    try testing.expectEqual(spawned_before, pool.spawned_count);
    try testing.expectEqual(slot_count, pool.busyCount());
    harness.waitForStarted(1 + slot_count);
    const wakes_before = harness.wake.count.load(.acquire);
    harness.cancel(ids[2]);
    harness.waitForWakes(wakes_before + 1);
    try testing.expectEqual(@as(u32, 2), job_returned_count.load(.acquire));
    try testing.expectEqual(slot_count, pool.busyCount());
    try testing.expectError(error.JobBusy, harness.trySpawn(Sleep, .{ .seconds = 60 }));
    try testing.expectEqual(@as(u32, 0), harness.app.state.done_count);
    harness.tick();
    try testing.expectEqual(@as(u32, 1), harness.app.state.done_count);
    try testing.expectEqual(slot_count - 1, harness.app.window.jobs.busyCount());
    const next = harness.spawn(Sleep, .{ .seconds = 60 });
    try testing.expectEqual(ids[2].slot, next.slot);
    try testing.expectEqual(ids[2].generation +% 1, next.generation);
    try testing.expectEqual(slot_count, harness.app.window.jobs.busyCount());
}

test "a spawn from on_done takes the finishing job's slot in a full table" {
    // Goal: `on_done` can chain a job or retry one with every other slot
    // busy. Method: fill the table exactly, cancel one job, and let its
    // `on_done` spawn a follow-up, which `JobBusy` refused while the slot was
    // freed only after `on_done`. The follow-up must take that slot under the
    // next generation; the finished job's stale id, cancelled from `on_done`,
    // must leave it running; and with the table full again one more spawn is
    // refused, while the live id still cancels the follow-up.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const pool = &harness.app.window.jobs;
    const slot_count = limits.events.job_count_max;
    var ids: [slot_count]gooey.JobId = undefined;
    for (&ids) |*id| id.* = harness.spawn(Sleep, .{ .seconds = 60 });
    try testing.expectEqual(slot_count, pool.busyCount());
    harness.waitForStarted(1 + slot_count);
    harness.app.state.chain_on_done = true;
    harness.cancel(ids[1]);
    _ = harness.waitForDone(1, wait_count_max);
    const state = &harness.app.state;
    try testing.expectEqual(@as(u32, 1), state.done_count);
    try testing.expect(state.outcome.? == .cancelled);
    try testing.expect(!state.chain_refused);
    const chained = state.chained.?;
    try testing.expectEqual(ids[1].slot, chained.slot);
    try testing.expectEqual(ids[1].generation +% 1, chained.generation);
    try testing.expectEqual(slot_count, pool.busyCount());
    try testing.expectError(error.JobBusy, harness.trySpawn(Sleep, .{ .seconds = 60 }));
    harness.waitForStarted(2 + slot_count);
    harness.tick();
    try testing.expectEqual(gooey.internals.jobs.Phase.running, pool.phaseOf(chained.slot));
    // The job `on_init` spawned and the cancelled one; not the follow-up.
    try testing.expectEqual(@as(u32, 2), job_returned_count.load(.acquire));
    harness.cancel(chained);
    _ = harness.waitForDone(2, wait_count_max);
    try testing.expectEqual(@as(u32, 2), state.done_count);
    try testing.expect(state.outcome.? == .cancelled);
    try testing.expectEqual(slot_count - 1, pool.busyCount());
}

test "two jobs' deliveries keep each job's post order and end it after its results" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var first = counting(100, 5, .{ .fail = false, .gated = false });
    first.gap_ms = 2;
    var second = counting(200, 5, .{ .fail = false, .gated = false });
    second.gap_ms = 2;
    const first_id = harness.spawn(Count, first);
    const second_id = harness.spawn(Count, second);
    _ = harness.waitForDone(2, wait_count_max);
    const state = &harness.app.state;
    try testing.expectEqual(@as(u32, 2), state.done_count);
    try testing.expectEqual(@as(u32, 12), state.log_count);
    for ([_]struct { base: u32, slot: u32 }{
        .{ .base = 100, .slot = first_id.slot },
        .{ .base = 200, .slot = second_id.slot },
    }) |job| {
        var next: u32 = job.base;
        for (state.log[0..state.log_count]) |entry| {
            if (entry == done_marker + job.slot) {
                try testing.expectEqual(job.base + 5, next);
            } else if (entry >= job.base and entry < job.base + 5) {
                try testing.expectEqual(next, entry);
                next += 1;
            }
        }
        try testing.expectEqual(job.base + 5, next);
    }
}

test "stop cancels a sleeping job and joins it before on_deinit" {
    var harness: Harness = undefined;
    try harness.init();
    const start = std.Io.Timestamp.now(testing.io, .awake);
    _ = harness.spawn(Sleep, .{ .seconds = 60 });
    _ = harness.spawn(Sleep, .{ .seconds = 60 });
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    const returned_before = job_returned_count.load(.acquire);
    harness.deinit();
    const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));
    try testing.expect(elapsed.toNanoseconds() < std.time.ns_per_s);
    try testing.expectEqual(returned_before + 2, deinit_saw_returned.load(.acquire));
}

test "stop races a job blocked in post and one posting in a loop, 200 times" {
    var full_rounds: u32 = 0;
    for (0..200) |round| {
        var harness: Harness = undefined;
        try harness.init();
        const spawned = 3;
        _ = harness.spawn(Flood, .{ .unused = 0 });
        _ = harness.spawn(Count, counting(0, 20, .{ .fail = false, .gated = true }));
        if (round % 2 == 0) job_gate_open.store(true, .release);
        if (round % 3 == 0) harness.tick();
        if (round % 5 == 0) try testing.io.sleep(.fromMilliseconds(1), .awake);
        // One more, so a stop can land as its worker wakes: a job whose
        // worker has not started it when the app stops never runs.
        _ = harness.spawn(Sleep, .{ .seconds = 60 });
        if (round % 4 == 1) harness.waitForStarted(1 + spawned);
        harness.deinit();
        const started = deinit_saw_started.load(.acquire);
        try testing.expectEqual(started, deinit_saw_returned.load(.acquire));
        try testing.expectEqual(started, job_started_count.load(.acquire));
        try testing.expectEqual(started, job_returned_count.load(.acquire));
        try testing.expect(started >= 1);
        try testing.expect(started <= 1 + spawned);
        if (started == 1 + spawned) full_rounds += 1;
    }
    // The waiting rounds start every job before the stop.
    try testing.expect(full_rounds >= 50);
}

test "stop interrupts a job blocked in a socket read and one blocked in a post" {
    var harness: Harness = undefined;
    try harness.init();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{});
    defer server.deinit(testing.io);
    const wakes_before = harness.wake.count.load(.acquire);
    _ = harness.spawn(Read, .{ .port = server.socket.address.getPort() });
    _ = harness.spawn(Flood, .{ .unused = 0 });
    _ = harness.spawn(Sleep, .{ .seconds = 60 });
    harness.waitForStarted(1 + 3);
    harness.waitForWakes(wakes_before + limits.events.job_result_count_max);
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    const start = std.Io.Timestamp.now(testing.io, .awake);
    harness.deinit();
    const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));
    try testing.expect(elapsed.toMilliseconds() < cancel_ms_max);
    try testing.expectEqual(@as(u32, 1 + 3), deinit_saw_returned.load(.acquire));
}

test "stop races a cancel's interrupt, 200 times" {
    for (0..200) |round| {
        var harness: Harness = undefined;
        try harness.init();
        const id = harness.spawn(Sleep, .{ .seconds = 60 });
        if (round % 2 == 0) _ = harness.spawn(Sleep, .{ .seconds = 60 });
        if (round % 4 < 2) harness.waitForStarted(2);
        harness.cancel(id);
        if (round % 3 == 0) try testing.io.sleep(.fromMilliseconds(1), .awake);
        harness.deinit();
        const started = deinit_saw_started.load(.acquire);
        try testing.expectEqual(started, deinit_saw_returned.load(.acquire));
        try testing.expectEqual(started, job_returned_count.load(.acquire));
    }
}

test "the background example streams its fetch without polling" {
    const ExampleApp = background.App;
    const app = try testing.allocator.create(ExampleApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var effects = Effects.init(null, .root);
    effects.jobs = &app.window.jobs;
    app.state.startFetch(&effects);
    try testing.expect(app.state.fetch != null);
    var now: u64 = 0;
    for (0..wait_count_max) |_| {
        now += 1_000_000;
        app.tick(now);
        if (app.state.fetch == null) break;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(app.state.fetch == null);
    try testing.expectEqual(@as(u32, 10), app.state.chunks);
    const reply = app.state.reply[0..app.state.reply_len];
    try testing.expect(std.mem.startsWith(u8, reply, "Gooey runs"));
    try testing.expect(std.mem.endsWith(u8, reply, "runs once."));
    try testing.expect(app.window.renderDeadlineNs() == null);
}

const PicksBuildFile = struct {
    fn open(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: u32,
        _: gooey.internals.handler.FileDialogRequest,
    ) ?gooey.internals.events.Completion.Outcome {
        return .{ .file_selected = .{ .bytes = "build.zig", .count = 1 } };
    }
};

test "a file dialog's completion spawns the job that reads the file" {
    const ExampleApp = background.App;
    const app = try testing.allocator.create(ExampleApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var context: u8 = 0;
    app.window.file_dialog = .{ .context = &context, .open = PicksBuildFile.open };
    var effects = Effects.init(null, .root);
    effects.jobs = &app.window.jobs;
    // The router's view of the window's dialogs, as `router.call` sets it.
    effects.dialogs = .{
        .pending = &app.window.pending_dialog,
        .slots = app.window.dialog_handlers,
    };
    app.state.pickFile(&effects);
    app.window.pending_dialog = effects.file_dialog;
    var now: u64 = 1_000_000;
    app.tick(now);
    for (0..wait_count_max) |_| {
        now += 1_000_000;
        app.tick(now);
        if (app.state.counting == false and app.state.status_len > 0) break;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    const cwd = std.Io.Dir.cwd();
    const contents = try cwd.readFileAlloc(testing.io, "build.zig", testing.allocator, .unlimited);
    defer testing.allocator.free(contents);
    var expected: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&expected, "{d} lines, {d} bytes.", .{
        std.mem.countScalar(u8, contents, '\n'),
        contents.len,
    });
    try testing.expectEqualStrings(text, app.state.status_bytes[0..app.state.status_len]);
}
