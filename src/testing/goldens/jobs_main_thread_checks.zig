//! Background jobs without workers, the path the web and `-fsingle-threaded`
//! builds take, checked natively: `addGoldens` in build.zig builds this file
//! and its `gooey` single-threaded. A spawned job runs whole on the main
//! thread after the drain that spawned it, its posts arrive in the next
//! drain, and a cancel can reach it only before it runs, when `run` is
//! skipped, or after, when what it posted is dropped.

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");

const Effects = gooey.Effects;
const testing = std.testing;
const assert = std.debug.assert;

comptime {
    // Otherwise these checks would run the worker path.
    assert(builtin.single_threaded);
}

// One thread: plain counters are enough for the job to report through.
var job_started_count: u32 = 0;
var job_saw_cancel_count: u32 = 0;

/// Posts `count` results numbered from `first`.
const Count = struct {
    pub const Input = struct { first: u32, count: u32 };
    pub const Result = struct { value: u32 };

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        job_started_count += 1;
        // Nothing can cancel a job while it runs on the main thread.
        if (job.cancelled()) job_saw_cancel_count += 1;
        for (0..input.count) |index| {
            const value = input.first + @as(u32, @intCast(index));
            if (!job.post(&.{ .value = value })) return error.Canceled;
        }
    }
};

const State = struct {
    received: [16]u32 = @splat(0),
    received_count: u32 = 0,
    done_count: u32 = 0,
    outcome: ?Effects.JobOutcome = null,

    fn onCount(self: *State, effects: *Effects) void {
        const result = effects.jobResult(Count).?;
        assert(self.received_count < self.received.len);
        self.received[self.received_count] = result.value;
        self.received_count += 1;
    }

    fn onDone(self: *State, effects: *Effects) void {
        self.done_count += 1;
        self.outcome = effects.jobDone().?.outcome;
    }
};

fn render(cx: *gooey.Cx) void {
    cx.render(gooey.ui.box(.{}, .{}));
}

const limits = gooey.ResourceLimits.nano;

const App = gooey.App(State, render, .{
    .title = "Jobs on the main thread",
    .width = 200,
    .height = 100,
    .limits = limits,
    .jobs = &.{Count},
});

const Harness = struct {
    app: *App,
    now: u64,

    fn init(self: *Harness) !void {
        job_started_count = 0;
        job_saw_cancel_count = 0;
        self.app = try testing.allocator.create(App);
        errdefer testing.allocator.destroy(self.app);
        try self.app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
        self.now = 0;
    }

    fn deinit(self: *Harness) void {
        self.app.deinitHeadless();
        testing.allocator.destroy(self.app);
    }

    fn tick(self: *Harness) void {
        self.now += 1_000_000;
        self.app.tick(self.now);
    }

    fn spawn(self: *Harness, first: u32, count: u32) gooey.JobId {
        var effects = Effects.init(null, .root);
        effects.jobs = &self.app.window.jobs;
        return effects.spawn(Count, &.{ .first = first, .count = count }, .{
            .on_result = effects.handler(State.onCount),
            .on_done = effects.handler(State.onDone),
        });
    }

    fn cancel(self: *Harness, id: gooey.JobId) void {
        var effects = Effects.init(null, .root);
        effects.jobs = &self.app.window.jobs;
        effects.cancelJob(id);
    }
};

test "a job runs after the drain that spawned it and delivers in the next" {
    // Goal: the no-worker schedule. Method: a spawn outside a tick does not
    // run; the next tick's drain runs it whole, which posts into the ring
    // but delivers nothing; the tick after delivers every result in post
    // order and then `on_done`, and frees the slot. Eight posts fill
    // `nano`'s result pool exactly, the most a job can post without a drain
    // (one more fails fast: a post cannot wait without workers).
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const result_count = limits.events.job_result_count_max;
    try testing.expectEqual(@as(u32, 8), result_count);
    _ = harness.spawn(40, result_count);
    try testing.expectEqual(@as(u32, 0), job_started_count);
    harness.tick();
    try testing.expectEqual(@as(u32, 1), job_started_count);
    try testing.expectEqual(@as(u32, 0), harness.app.state.received_count);
    try testing.expectEqual(@as(u32, 0), harness.app.state.done_count);
    harness.tick();
    const state = &harness.app.state;
    try testing.expectEqualSlices(u32, &.{ 40, 41, 42, 43, 44, 45, 46, 47 }, state.received[0..8]);
    try testing.expectEqual(@as(u32, 8), state.received_count);
    try testing.expectEqual(@as(u32, 1), state.done_count);
    try testing.expect(state.outcome.? == .finished);
    try testing.expectEqual(@as(u32, 0), job_saw_cancel_count);
    try testing.expectEqual(@as(u32, 0), harness.app.window.jobs.busyCount());
}

test "a job cancelled before its drain never runs, and its slot runs the next job" {
    // Goal: cancel before start. Method: spawn and cancel before any tick.
    // The drain must skip `run`, and the next deliver only `on_done` with
    // `.cancelled`. A second cancel and a cancel of the stale id then do
    // nothing: the next spawn takes the same slot under the next generation
    // and finishes with its results.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const id = harness.spawn(1, 3);
    harness.cancel(id);
    harness.cancel(id);
    harness.tick();
    try testing.expectEqual(@as(u32, 0), job_started_count);
    harness.tick();
    const state = &harness.app.state;
    try testing.expectEqual(@as(u32, 0), state.received_count);
    try testing.expectEqual(@as(u32, 1), state.done_count);
    try testing.expect(state.outcome.? == .cancelled);
    harness.cancel(id);
    harness.app.state = .{};
    const next = harness.spawn(5, 2);
    try testing.expectEqual(id.slot, next.slot);
    try testing.expectEqual(id.generation +% 1, next.generation);
    harness.tick();
    harness.tick();
    try testing.expectEqual(@as(u32, 1), job_started_count);
    try testing.expectEqualSlices(u32, &.{ 5, 6 }, state.received[0..state.received_count]);
    try testing.expect(state.outcome.? == .finished);
}

test "a cancel after the job ran and before the drain drops what it posted" {
    // Goal: cancel between the run and the delivery. Method: the first tick
    // runs the job, which posts three results; cancel before the next tick,
    // which must deliver none of them and report `.cancelled`.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const id = harness.spawn(1, 3);
    harness.tick();
    try testing.expectEqual(@as(u32, 1), job_started_count);
    harness.cancel(id);
    harness.tick();
    try testing.expectEqual(@as(u32, 0), harness.app.state.received_count);
    try testing.expectEqual(@as(u32, 1), harness.app.state.done_count);
    try testing.expect(harness.app.state.outcome.? == .cancelled);
    try testing.expectEqual(@as(u32, 0), harness.app.window.jobs.busyCount());
}
