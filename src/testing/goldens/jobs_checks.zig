//! Background jobs (`Effects.spawn`) through a headless app: posts arrive as
//! handler calls in post order and wake the host, a full result pool holds
//! the worker back without losing a result, cancellation drops what was not
//! delivered, and shutdown cancels and joins every worker before
//! `on_deinit`, whatever the workers are doing. The example's fetch runs
//! end to end the same way.
//!
//! Workers are real threads on `std.testing.io`, so each check waits for
//! them with a bounded number of short sleeps rather than a fixed delay.

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

/// Posts `count` results numbered from `first`, then returns or fails.
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

/// A `Count` input posting `count` results from `first`.
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

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        _ = job_started_count.fetchAdd(1, .acq_rel);
        defer _ = job_returned_count.fetchAdd(1, .acq_rel);
        try job.io().sleep(.fromSeconds(input.seconds), .awake);
    }
};

/// Posts until `post` refuses, as fast as it can.
const Flood = struct {
    pub const Input = struct { unused: u8 };
    pub const Result = struct { value: u64 };

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
    done_count: u32 = 0,
    outcome: ?Effects.JobOutcome = null,
    last: ?gooey.JobId = null,
    init_saw_io: bool = false,

    fn onCount(self: *State, effects: *Effects) void {
        const result = effects.jobResult(Count).?;
        assert(effects.jobResult(Sleep) == null);
        assert(effects.jobDone() == null);
        assert(result.pad[59] == 7);
        assert(self.received_count < self.received.len);
        self.received[self.received_count] = result.value;
        self.received_count += 1;
    }

    fn onDone(self: *State, effects: *Effects) void {
        const done = effects.jobDone().?;
        assert(std.meta.eql(done.id, effects.jobId().?));
        self.done_count += 1;
        self.outcome = done.outcome;
    }

    fn onFlood(_: *State, effects: *Effects) void {
        assert(effects.jobResult(Flood) != null);
    }

    fn init(self: *State, init_value: gooey.Init, effects: *Effects) void {
        _ = init_value.io;
        self.init_saw_io = init_value.environ.count() == 0;
        // Spawning from on_init works: the workers are already running.
        self.last = effects.spawn(Count, &.{
            .first = 900,
            .count = 1,
            .fail = false,
            .gated = false,
            .gap_ms = 0,
        }, .{
            .on_result = effects.handler(State.onCount),
            .on_done = effects.handler(State.onDone),
        });
    }

    fn deinit(_: *State) void {
        deinit_saw_returned.store(job_returned_count.load(.acquire), .release);
        deinit_saw_started.store(job_started_count.load(.acquire), .release);
    }
};

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
    .jobs = &.{ Count, Sleep, Flood },
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

    /// Stop the app (cancelling and joining every worker, then `on_deinit`)
    /// and free it.
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

    fn spawn(self: *Harness, comptime Job: type, input: Job.Input) gooey.JobId {
        var effects = Effects.init(null, .root);
        effects.jobs = &self.app.window.jobs;
        const on_result = if (Job == Flood)
            effects.handler(State.onFlood)
        else
            effects.handler(State.onCount);
        return effects.spawn(Job, &input, .{
            .on_result = if (Job == Sleep) null else on_result,
            .on_done = effects.handler(State.onDone),
        });
    }

    /// Tick until `condition` holds, sleeping 1 ms between ticks.
    fn waitUntil(self: *Harness, condition: *const fn (*const State) bool) void {
        for (0..wait_count_max) |_| {
            self.tick();
            if (condition(&self.app.state)) return;
            testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        }
        std.debug.panic("jobs_checks: condition not reached in {d} ms", .{wait_count_max});
    }

    /// Sleep without ticking until the wake count reaches `count`.
    fn waitForWakes(self: *Harness, count: u32) void {
        for (0..wait_count_max) |_| {
            if (self.wake.count.load(.acquire) >= count) return;
            testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        }
        std.debug.panic("jobs_checks: {d} wakes not reached", .{count});
    }
};

fn finished(state: *const State) bool {
    return state.done_count > 0;
}

test "a job's posts arrive in post order as handler calls, then on_done once" {
    // Goal: the delivery contract and the wake. Method: spawn a job that
    // posts 5 numbered results from a copied input, overwrite the input,
    // and wait without ticking until 6 wakes (5 posts and the end) have
    // arrived; one tick then delivers all of them in order, with no render
    // deadline asked for, and on_init received the io and environment.
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
    // Goal: backpressure. Method: `nano` holds 8 results; a job posts 40
    // with no drain. It must stop at exactly 8 posts (8 wakes) and stay
    // there, then deliver all 40 in order as ticks free slots.
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
    // Goal: `cancelJob` semantics. Method: a job fills the pool (8 posts)
    // and blocks; cancel it before any drain. The drain drops the 8 held
    // results, which frees the pool, the blocked post returns false, and
    // the only call is on_done with `.cancelled`.
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

test "stop cancels a sleeping job and joins it before on_deinit" {
    // Goal: shutdown is prompt and ordered. Method: two jobs sleep for a
    // minute; stopping must cancel the sleeps, return within a second, and
    // run on_deinit only after both jobs returned.
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
    // Goal: no shutdown race leaks a worker, delivers after stop, or
    // deadlocks. Method: per round, one job floods the result pool (and
    // blocks), one counts with a gate, and one sleeps; stop at a varying
    // point; every job must have returned when on_deinit runs.
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
        harness.deinit();
        const started = deinit_saw_started.load(.acquire);
        try testing.expectEqual(started, deinit_saw_returned.load(.acquire));
        try testing.expectEqual(started, job_started_count.load(.acquire));
        try testing.expectEqual(started, job_returned_count.load(.acquire));
        try testing.expect(started >= 1);
        try testing.expect(started <= 1 + spawned);
        if (started == 1 + spawned) full_rounds += 1;
    }
    // Most rounds start every job before the stop; the check would pass
    // vacuously if none did.
    try testing.expect(full_rounds > 0);
}

test "the background example streams its fetch without polling" {
    // Goal: the example's fetch end to end. Method: click Fetch through the
    // handler, wait for on_done, and check that every chunk arrived in
    // order and nothing asked for a timed render.
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

/// A dialog service that selects the repository's `build.zig` at once.
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
    // Goal: dialogs and jobs compose through the one completion ring.
    // Method: the example's "Count lines" opens a scripted dialog that picks
    // `build.zig`; its completion spawns `CountLines`, whose result must
    // match the file's own byte and line counts, read here independently.
    const ExampleApp = background.App;
    const app = try testing.allocator.create(ExampleApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var context: u8 = 0;
    app.window.file_dialog = .{ .context = &context, .open = PicksBuildFile.open };
    var effects = Effects.init(null, .root);
    effects.jobs = &app.window.jobs;
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
