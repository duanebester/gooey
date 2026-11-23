const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");

const Effects = gooey.Effects;
const testing = std.testing;
const assert = std.debug.assert;

comptime {
    assert(builtin.single_threaded);
}

var job_started_count: u32 = 0;
var job_saw_cancel_count: u32 = 0;

const Count = struct {
    pub const Input = struct { first: u32, count: u32 };
    pub const Result = struct { value: u32 };
    pub const posts_max: u32 = limits.events.job_result_count_max;

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        job_started_count += 1;
        if (job.cancelled()) job_saw_cancel_count += 1;
        for (0..input.count) |index| {
            const value = input.first + @as(u32, @intCast(index));
            if (!job.post(&.{ .value = value })) return error.Canceled;
        }
    }
};

const Small = struct {
    pub const Input = struct { first: u32, count: u32 };
    pub const Result = struct { value: u32 };
    pub const posts_max: u32 = 4;

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        assert(input.count <= posts_max);
        job_started_count += 1;
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

    fn onSmall(self: *State, effects: *Effects) void {
        const result = effects.jobResult(Small).?;
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
    .jobs = &.{ Count, Small },
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
        }) catch |err| std.debug.panic("jobs_main_thread_checks: spawn refused: {t}", .{err});
    }

    fn spawnSmall(self: *Harness, first: u32, count: u32) gooey.JobId {
        var effects = Effects.init(null, .root);
        effects.jobs = &self.app.window.jobs;
        return effects.spawn(Small, &.{ .first = first, .count = count }, .{
            .on_result = effects.handler(State.onSmall),
            .on_done = effects.handler(State.onDone),
        }) catch |err| std.debug.panic("jobs_main_thread_checks: spawn refused: {t}", .{err});
    }

    fn cancel(self: *Harness, id: gooey.JobId) void {
        var effects = Effects.init(null, .root);
        effects.jobs = &self.app.window.jobs;
        effects.cancelJob(id);
    }
};

test "a job runs after the drain that spawned it and delivers in the next" {
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

test "jobs one drain spawns that together post past the result slots run over two drains" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const post_count = 5;
    comptime assert(post_count <= limits.events.job_result_count_max);
    comptime assert(2 * post_count > limits.events.job_result_count_max);
    _ = harness.spawn(10, post_count);
    _ = harness.spawn(20, post_count);
    harness.tick();
    try testing.expectEqual(@as(u32, 1), job_started_count);
    try testing.expectEqual(@as(u32, 2), harness.app.window.jobs.busyCount());
    harness.tick();
    const state = &harness.app.state;
    try testing.expectEqual(@as(u32, 2), job_started_count);
    try testing.expectEqualSlices(u32, &.{ 10, 11, 12, 13, 14 }, state.received[0..5]);
    try testing.expectEqual(@as(u32, 1), state.done_count);
    harness.tick();
    try testing.expectEqual(@as(u32, 10), state.received_count);
    try testing.expectEqualSlices(u32, &.{ 20, 21, 22, 23, 24 }, state.received[5..10]);
    try testing.expectEqual(@as(u32, 2), state.done_count);
    try testing.expect(state.outcome.? == .finished);
    try testing.expectEqual(@as(u32, 0), harness.app.window.jobs.busyCount());
}

test "jobs whose posts_max fit the result slots together run in one drain" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    comptime assert(2 * Small.posts_max == limits.events.job_result_count_max);
    _ = harness.spawnSmall(10, 4);
    _ = harness.spawnSmall(20, 4);
    harness.tick();
    try testing.expectEqual(@as(u32, 2), job_started_count);
    try testing.expectEqual(@as(u32, 0), harness.app.window.jobs.result_free_count);
    harness.tick();
    const state = &harness.app.state;
    try testing.expectEqual(@as(u32, 8), state.received_count);
    try testing.expectEqualSlices(u32, &.{ 10, 11, 12, 13, 20, 21, 22, 23 }, state.received[0..8]);
    try testing.expectEqual(@as(u32, 2), state.done_count);
    harness.app.state = .{};
    _ = harness.spawnSmall(30, 1);
    _ = harness.spawn(40, 1);
    harness.tick();
    try testing.expectEqual(@as(u32, 3), job_started_count);
    harness.tick();
    try testing.expectEqual(@as(u32, 4), job_started_count);
    try testing.expectEqualSlices(u32, &.{30}, state.received[0..state.received_count]);
    harness.tick();
    try testing.expectEqualSlices(u32, &.{ 30, 40 }, state.received[0..state.received_count]);
    try testing.expectEqual(@as(u32, 2), state.done_count);
    try testing.expectEqual(@as(u32, 0), harness.app.window.jobs.busyCount());
}
