//! Background jobs: `Effects.spawn`.
//!
//! A job is a type in `Config.jobs` with an `Input`, a `Result`, and
//! `run(input: *const Input, job: *Job(Result)) !void`. A handler spawns one
//! with an input; the input is copied into the job's slot, so the job never
//! sees `State` (`Input` holds no pointers, checked at comptime). `run`
//! executes off the main thread and talks back only through `job.post`,
//! which copies a result into a result slot, pushes it onto the window's
//! completion ring, and wakes the host. The next drain calls the job's
//! `on_result` handler with each result in post order and then `on_done`
//! once, with how `run` ended.
//!
//! Threading: natively, each of the `events.job_count_max` job slots has two
//! tasks, started at init with `io.concurrent` and only when `Config.jobs` is
//! non-empty: a runner, alone in the slot's own `std.Io.Group`, that runs the
//! slot's jobs, and an interrupter, in the pool's group, that waits for a
//! cancel to reach a running job. A spawn claims a free slot and posts its
//! runner's semaphore; a full table fails fast. On the web and in
//! single-threaded builds there are no workers: a spawned job runs to
//! completion on the main thread after the drain that spawned it
//! (`runQueued`), and its posts are delivered in the next drain.
//!
//! Cancellation (`cancel`, from `Effects.cancelJob`): the main thread marks
//! the job and moves its `Phase` with one compare-and-swap, never waiting.
//! A job its runner has not started is `skipped`: the runner reports
//! `.cancelled` without calling `run`. A running job is `interrupting`: its
//! slot's interrupter cancels the runner's group, so the job's next or
//! current Io cancellation point (a sleep, a socket or file read, a blocked
//! post) returns `error.Canceled` at once; `run` unwinds, the runner task
//! ends, and the interrupter starts the slot's next runner and pushes the
//! job's end. Exactly one of runner and interrupter pushes it, whichever
//! moves `Phase` out of `running`. A job computing without Io stops when it
//! next checks `job.cancelled()` or posts. Without workers nothing runs
//! while a handler can cancel, so a cancel only ever skips a queued job.
//!
//! A cancelled task must end (`std.Io` cancels a whole future or group, and
//! offers no way to interrupt a task that then continues), so the next
//! runner is a new task. That is the one task the pool asks the io for after
//! init: `Io.Threaded` takes its record from the io's own allocator, not
//! Gooey's, once per cancel that interrupts a running job. Failing to start
//! it fails fast, as a full table does.
//!
//! Overload: a post that finds every result slot held waits on its runner
//! (a cancelable semaphore) until a drain frees one; the main thread never
//! waits. Without workers a post cannot wait, so it fails fast instead.
//!
//! Shutdown (`stop`, from `App.stop`): `stopping` is set and the pool's
//! group is cancelled; each interrupter then cancels its runner's group,
//! which makes every Io cancellation point in a job, a blocked post, and an
//! idle runner's wait return `error.Canceled`, and every task is awaited.
//! Deliveries still in the ring are never routed.
//!
//! Resource sketch at `.standard`: 8 slots of 4 KiB input and 32 result
//! slots of 4 KiB, 160 KiB reserved from fresh pages and zeroed up to their
//! high-water marks on release; 16 tasks (8 runners and 8
//! interrupters, idle in a semaphore wait) whose stacks are the io's default.
//! Per tick the main thread routes at most `job_result_count_max +
//! job_count_max` deliveries, copying nothing; a cancel is two atomic
//! operations and at most one semaphore post.

const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");
const handler_mod = @import("handler.zig");
const limits_mod = @import("limits.zig");
const reservation = @import("reservation.zig");
const images = @import("images.zig");

const assert = std.debug.assert;

const Handler = handler_mod.Handler;
const JobEntry = events.JobEntry;

/// Whether jobs run on worker threads. Without threads (the web, and
/// `-fsingle-threaded`) they run on the main thread after the drain.
pub const threaded = !builtin.single_threaded and !builtin.cpu.arch.isWasm();

/// Alignment of every input and result slot; a job type that needs more is
/// a compile error.
pub const value_alignment: u32 = 16;

/// Nesting `checkSpec` walks inside an `Input` type looking for pointers.
const input_type_depth_max: u32 = 256;

/// A running or finished job: its slot and the generation it was spawned
/// in. Ids of jobs that have delivered `on_done` are stale; cancelling one
/// does nothing.
pub const JobId = struct {
    slot: u32,
    generation: u32,
};

/// How a job ended. A job that was cancelled reports `.cancelled` however
/// `run` returned.
pub const Outcome = union(enum) {
    finished,
    cancelled,
    failed: anyerror,
};

/// What `on_done` receives (`Effects.jobDone`).
pub const Done = struct {
    id: JobId,
    outcome: Outcome,
};

/// The handlers a spawn delivers to: root-state handlers, from
/// `effects.handler(State.method)`.
pub const Handlers = struct {
    /// Called once per posted result, in post order; null drops results.
    on_result: ?Handler = null,
    /// Called once, last, when `run` returns.
    on_done: Handler,
};

/// A job's handle to the framework, passed to `run` on its worker.
pub fn Job(comptime Result: type) type {
    // Extern, so every instantiation has the same layout: the worker builds
    // one handle and `erasedRun` reads it as the job's own type.
    return extern struct {
        pool: *Pool,
        slot: u32,

        const Self = @This();

        /// The app's io (`Init.io`): sleeps, files, sockets. Natively, its
        /// cancellation points return `error.Canceled` once
        /// `Effects.cancelJob` cancels this job or the app shuts down.
        pub fn io(self: *const Self) std.Io {
            assert(self.slot < self.pool.slots.len);
            return self.pool.io;
        }

        /// Whether `Effects.cancelJob` cancelled this job or the app is
        /// shutting down. A job that loops without Io calls checks it.
        pub fn cancelled(self: *const Self) bool {
            assert(self.slot < self.pool.slots.len);
            return self.pool.cancelRequested(self.slot);
        }

        /// Deliver `result` to the job's `on_result`, copied now. Waits while
        /// every result slot is held. Returns false, delivering nothing, once
        /// the job is cancelled or the app is shutting down: `run` returns.
        pub fn post(self: *Self, result: *const Result) bool {
            assert(self.slot < self.pool.slots.len);
            return self.pool.post(self.slot, std.mem.asBytes(result));
        }
    };
}

/// Reject a job type that cannot work, naming it and the problem.
pub fn checkSpec(comptime Spec: type) void {
    comptime {
        const name = @typeName(Spec);
        if (@typeInfo(Spec) != .@"struct") @compileError("gooey job " ++ name ++
            " is not a struct with Input, Result, and run");
        if (!@hasDecl(Spec, "Input") or !@hasDecl(Spec, "Result") or !@hasDecl(Spec, "run")) {
            @compileError("gooey job " ++ name ++ " needs `pub const Input`, " ++
                "`pub const Result`, and `pub fn run(input: *const Input, " ++
                "job: *gooey.Job(Result)) !void`");
        }
        if (@alignOf(Spec.Input) > value_alignment or @alignOf(Spec.Result) > value_alignment) {
            @compileError("gooey job " ++ name ++ ": Input and Result need alignment of " ++
                "at most 16");
        }
        checkRun(Spec);
        checkPointerFree(Spec.Input, name);
    }
}

fn checkRun(comptime Spec: type) void {
    const name = @typeName(Spec);
    const help = "gooey job " ++ name ++ ": run must be `pub fn run(input: *const Input, " ++
        "job: *gooey.Job(Result)) !void` (or `void`)";
    const info = @typeInfo(@TypeOf(Spec.run));
    if (info != .@"fn") @compileError(help);
    const params = info.@"fn".param_types;
    if (params.len != 2) @compileError(help);
    if (params[0] != *const Spec.Input) @compileError(help);
    if (params[1] != *Job(Spec.Result)) @compileError(help);
    const Return = info.@"fn".return_type orelse @compileError(help);
    switch (@typeInfo(Return)) {
        .void => {},
        .error_union => |union_info| if (union_info.payload != void) @compileError(help),
        else => @compileError(help),
    }
}

/// `Input` is copied into the job's slot and must not reach `State` or any
/// other memory the main thread owns: no pointer or
/// slice anywhere inside it. Large data goes through an app-owned buffer the
/// input names by index. An explicit stack, not recursion.
fn checkPointerFree(comptime Input: type, comptime job_name: []const u8) void {
    var stack: [input_type_depth_max]type = undefined;
    var count: u32 = 1;
    stack[0] = Input;
    var visited: u32 = 0;
    while (count > 0) : (visited += 1) {
        if (visited == input_type_depth_max) @compileError("gooey job " ++ job_name ++
            ": Input nests more than 256 types deep");
        count -= 1;
        const T = stack[count];
        const problem = "gooey job " ++ job_name ++ ": Input contains " ++ @typeName(T) ++
            ", which can point into State; copy the data into Input, or keep it in an " ++
            "app-owned buffer and pass its index";
        switch (@typeInfo(T)) {
            .pointer, .@"fn", .@"opaque", .@"anyframe", .frame => @compileError(problem),
            .array => |info| {
                stack[count] = info.child;
                count += 1;
            },
            .vector => |info| {
                stack[count] = info.child;
                count += 1;
            },
            .optional => |info| {
                stack[count] = info.child;
                count += 1;
            },
            .@"struct" => |info| for (info.field_types) |Field| {
                if (count == input_type_depth_max) @compileError("gooey job " ++ job_name ++
                    ": Input has too many nested fields to check");
                stack[count] = Field;
                count += 1;
            },
            .@"union" => |info| for (info.field_types) |Field| {
                if (count == input_type_depth_max) @compileError("gooey job " ++ job_name ++
                    ": Input has too many nested fields to check");
                stack[count] = Field;
                count += 1;
            },
            .error_union => |info| {
                stack[count] = info.payload;
                count += 1;
            },
            else => {},
        }
    }
}

/// The type-erased entry the worker calls: `Spec.run` on the slot's input.
pub const RunFn = *const fn (
    input: [*]align(value_alignment) const u8,
    job: *anyopaque,
) anyerror!void;

pub fn erasedRun(comptime Spec: type) RunFn {
    comptime checkSpec(Spec);
    return struct {
        fn run(input: [*]align(value_alignment) const u8, job: *anyopaque) anyerror!void {
            const typed: *const Spec.Input = @ptrCast(input);
            const handle: *Job(Spec.Result) = @ptrCast(@alignCast(job));
            assert(handle.slot < handle.pool.slots.len);
            return Spec.run(typed, handle);
        }
    }.run;
}

/// The unit of input and result storage: 16 bytes at 16-byte alignment.
const Block = struct { bytes: [value_alignment]u8 align(value_alignment) };

comptime {
    assert(@sizeOf(Block) == value_alignment);
    assert(@alignOf(Block) == value_alignment);
}

const Slot = struct {
    // Main thread only.
    busy: bool,
    /// Set by a spawn without workers; `runQueued` runs it.
    queued: bool,
    type_id: usize,
    handlers: Handlers,
    // Written by the main thread before `start` is posted and not again
    // until `on_done` is delivered, so the runner and interrupter read them
    // unlocked.
    generation: u32,
    run: ?RunFn,
    // Shared.
    cancel: std.atomic.Value(bool),
    phase: std.atomic.Value(Phase),
    /// One permit per spawn of this slot.
    start: std.Io.Semaphore,
    /// One permit per cancel that found the job `running`.
    interrupt: std.Io.Semaphore,
    /// The slot's runner and nothing else, so cancelling the group
    /// interrupts this job's Io and no other.
    group: std.Io.Group,
};

/// Where a busy slot's job is. The main thread, the runner, and the
/// interrupter each move it only by compare-and-swap from the phase they
/// expect, so a cancel and the job's end cannot both claim it.
const Phase = enum(u8) {
    /// No job, or the job's end is pushed and `on_done` not yet delivered.
    idle,
    /// Spawned; the runner has not taken it.
    pending,
    /// Cancelled while pending: the runner reports `.cancelled` and never
    /// calls `run`.
    skipped,
    /// In `run`. The runner moves it to `idle` when `run` returns.
    running,
    /// Cancelled while running: the interrupter owns the job's end.
    interrupting,
};

/// What the router delivers for one `JobEntry`, or null when the entry is a
/// result of a cancelled job, which is dropped.
pub const Delivery = struct {
    handler: Handler,
    type_id: usize,
    id: JobId,
    /// The posted bytes, for `on_result`; valid until `finishDelivery`.
    result: ?[*]align(value_alignment) const u8,
    /// For `on_done`.
    done: ?Done,
};

pub const Pool = struct {
    io: std.Io,
    /// `Config.jobs`'s `handler.typeId`s; static storage.
    type_ids: []const usize,
    /// Empty when the app registers no jobs.
    slots: []Slot,
    input_blocks: []Block,
    input_stride: u32,
    /// Bytes ever written per input slot, zeroed on release.
    input_used_max: u32,
    result_blocks: []Block,
    result_stride: u32,
    /// Written by workers under `result_mutex`; read after they are joined.
    result_used_max: u32,
    /// Free result slot indexes, `result_free_count` of them, under
    /// `result_mutex`.
    result_free_list: []u32,
    result_free_count: u32,
    result_mutex: std.Io.Mutex,
    /// One permit per free result slot; posts wait on it.
    result_free: std.Io.Semaphore,
    completions: *events.CompletionRing,
    wake_mutex: std.Io.Mutex,
    wake: ?images.WakeService,
    stopping: std.atomic.Value(bool),
    stopped: bool,
    group: std.Io.Group,
    /// Spawns since init, for tests and diagnostics.
    spawned_count: u64,
    /// Tests only: when set, a runner that has taken a spawn waits on it
    /// before it starts the job, so a check can cancel a job that is
    /// certainly not running yet. Set before the spawn and cleared after
    /// the job's `on_done`; the start semaphore orders both for the runner.
    runner_gate: ?*std.Io.Event,

    /// Reserve the slots and result storage and start the workers. An app
    /// with no `type_ids` reserves nothing and starts no thread.
    pub fn initInPlace(
        self: *Pool,
        gpa: std.mem.Allocator,
        io: std.Io,
        completions: *events.CompletionRing,
        limits: *const limits_mod.EventLimits,
        type_ids: []const usize,
    ) !void {
        assert(limits.job_count_max > 0);
        assert(limits.job_result_count_max > 0);
        self.io = io;
        self.type_ids = type_ids;
        self.completions = completions;
        self.input_stride = std.mem.alignForward(u32, limits.job_input_bytes_max, value_alignment);
        self.result_stride =
            std.mem.alignForward(u32, limits.job_result_bytes_max, value_alignment);
        self.input_used_max = 0;
        self.result_used_max = 0;
        self.result_mutex = .init;
        self.wake_mutex = .init;
        self.wake = null;
        self.stopping = .init(false);
        self.stopped = type_ids.len == 0;
        self.group = .init;
        self.spawned_count = 0;
        self.runner_gate = null;
        self.slots = &.{};
        self.input_blocks = &.{};
        self.result_blocks = &.{};
        self.result_free_list = &.{};
        self.result_free_count = 0;
        self.result_free = .{ .permits = 0 };
        if (type_ids.len == 0) return;
        try self.reserve(gpa, limits);
        errdefer self.release(gpa);
        if (threaded) try self.startWorkers();
        assert(self.slots.len == limits.job_count_max);
        assert(self.result_free_count == limits.job_result_count_max);
    }

    fn reserve(self: *Pool, gpa: std.mem.Allocator, limits: *const limits_mod.EventLimits) !void {
        self.slots = try gpa.alloc(Slot, limits.job_count_max);
        errdefer gpa.free(self.slots);
        for (self.slots) |*slot| {
            slot.* = .{
                .busy = false,
                .queued = false,
                .type_id = 0,
                .handlers = undefined,
                .generation = 0,
                .run = null,
                .cancel = .init(false),
                .phase = .init(.idle),
                .start = .{ .permits = 0 },
                .interrupt = .{ .permits = 0 },
                .group = .init,
            };
        }
        self.result_free_list = try gpa.alloc(u32, limits.job_result_count_max);
        errdefer gpa.free(self.result_free_list);
        for (self.result_free_list, 0..) |*index, value| index.* = @intCast(value);
        self.result_free_count = limits.job_result_count_max;
        self.result_free = .{ .permits = limits.job_result_count_max };
        const input_count = @divExact(self.input_stride, value_alignment) * limits.job_count_max;
        self.input_blocks = try reservation.reserve(Block, input_count);
        errdefer reservation.release(Block, self.input_blocks, 0);
        const result_count = @divExact(self.result_stride, value_alignment) *
            limits.job_result_count_max;
        self.result_blocks = try reservation.reserve(Block, result_count);
    }

    /// Free what `reserve` took, zeroing the used prefix of every slot.
    fn release(self: *Pool, gpa: std.mem.Allocator) void {
        assert(self.type_ids.len > 0);
        assert(self.input_used_max <= self.input_stride);
        assert(self.result_used_max <= self.result_stride);
        const input_bytes = std.mem.sliceAsBytes(self.input_blocks);
        for (0..self.slots.len) |index| {
            @memset(input_bytes[index * self.input_stride ..][0..self.input_used_max], 0);
        }
        const result_bytes = std.mem.sliceAsBytes(self.result_blocks);
        for (0..self.result_free_list.len) |index| {
            @memset(result_bytes[index * self.result_stride ..][0..self.result_used_max], 0);
        }
        reservation.release(Block, self.input_blocks, 0);
        reservation.release(Block, self.result_blocks, 0);
        gpa.free(self.result_free_list);
        gpa.free(self.slots);
    }

    /// Per slot, a runner in the slot's group and an interrupter in the
    /// pool's, so `stop` cancels every interrupter together and each of
    /// them its runner. An io that cannot run them all concurrently is a
    /// capacity error at init.
    fn startWorkers(self: *Pool) !void {
        assert(threaded);
        assert(!self.stopping.load(.acquire));
        for (self.slots, 0..) |*slot, index| {
            const slot_index: u32 = @intCast(index);
            slot.group.concurrent(self.io, runnerMain, .{ self, slot_index }) catch |err| {
                return self.startWorkersFailed(slot_index, err);
            };
            self.group.concurrent(self.io, interrupterMain, .{ self, slot_index }) catch |err| {
                return self.startWorkersFailed(slot_index, err);
            };
        }
    }

    /// Stop the tasks `startWorkers` started before slot `index` failed.
    fn startWorkersFailed(
        self: *Pool,
        index: u32,
        err: std.Io.ConcurrentError,
    ) std.Io.ConcurrentError {
        assert(index < self.slots.len);
        std.log.err("gooey jobs: cannot start the tasks of slot {d} of {d}: {t}. Lower " ++
            "ResourceLimits.events.job_count_max or give the io more threads.", .{
            index + 1,
            self.slots.len,
            err,
        });
        self.stopping.store(true, .release);
        self.group.cancel(self.io);
        // The failing slot's runner may have started without its
        // interrupter; every other slot's interrupter already cancelled its
        // runner, which leaves its group empty.
        for (self.slots) |*slot| slot.group.cancel(self.io);
        return err;
    }

    /// Cancel every job, wait for every worker, and stop delivering. Main
    /// thread, from `App.stop` before `on_deinit`. Idempotent.
    pub fn stop(self: *Pool) void {
        if (self.stopped) return;
        assert(self.type_ids.len > 0);
        self.stopping.store(true, .release);
        if (threaded) self.group.cancel(self.io);
        self.stopped = true;
        assert(self.group.token.load(.acquire) == null);
        // Each interrupter cancelled its runner's group before it returned.
        for (self.slots) |*slot| assert(slot.group.token.load(.acquire) == null);
    }

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        self.stop();
        assert(self.stopped);
        if (self.type_ids.len > 0) self.release(gpa);
        self.* = undefined;
    }

    /// Bind or unbind the host's wake. Workers call it under the same lock,
    /// so a host may unbind while a job runs.
    pub fn bindWake(self: *Pool, service: ?images.WakeService) void {
        self.wake_mutex.lockUncancelable(self.io);
        defer self.wake_mutex.unlock(self.io);
        if (service != null) assert(self.wake == null);
        self.wake = service;
    }

    fn wakeHost(self: *Pool) void {
        self.wake_mutex.lockUncancelable(self.io);
        defer self.wake_mutex.unlock(self.io);
        if (self.wake) |service| service.wake(service.context);
    }

    /// Claim a slot, copy `input` into it, and start `run`. A job type not in
    /// `Config.jobs`, or a full table, is a programmer error.
    pub fn spawn(
        self: *Pool,
        type_id: usize,
        run: RunFn,
        input: []const u8,
        handlers: Handlers,
    ) JobId {
        assert(type_id != 0);
        assert(!self.stopping.load(.acquire));
        if (std.mem.indexOfScalar(usize, self.type_ids, type_id) == null) std.debug.panic(
            "effects.spawn: job type {s} is not in Config.jobs",
            .{handler_mod.typeName(type_id)},
        );
        if (input.len > self.input_stride) std.debug.panic("effects.spawn({s}): Input of " ++
            "{d} bytes exceeds ResourceLimits.events.job_input_bytes_max {d}", .{
            handler_mod.typeName(type_id),
            input.len,
            self.input_stride,
        });
        const index = self.freeSlot() orelse std.debug.panic("events pool 'jobs' exhausted: " ++
            "capacity {d}, {d} in use, 1 requested ({s}). Raise " ++
            "ResourceLimits.events.job_count_max.", .{
            self.slots.len,
            self.slots.len,
            handler_mod.typeName(type_id),
        });
        const slot = &self.slots[index];
        @memcpy(self.inputSlot(index)[0..input.len], input);
        self.input_used_max = @max(self.input_used_max, @as(u32, @intCast(input.len)));
        slot.busy = true;
        slot.type_id = type_id;
        slot.handlers = handlers;
        slot.run = run;
        slot.cancel.store(false, .release);
        assert(slot.phase.load(.acquire) == .idle);
        slot.phase.store(.pending, .release);
        self.spawned_count += 1;
        if (threaded) slot.start.post(self.io) else slot.queued = true;
        assert(slot.busy);
        return .{ .slot = index, .generation = slot.generation };
    }

    /// Stop job `id`: its posts return false, results not yet delivered
    /// are dropped, and its `on_done` reports `.cancelled`. A job not yet
    /// started never runs; a running one has its Io interrupted by its
    /// slot's interrupter. Never waits. A stale id (the job already
    /// delivered `on_done`) or a second cancel does nothing.
    pub fn cancel(self: *Pool, id: JobId) void {
        assert(id.slot < self.slots.len);
        const slot = &self.slots[id.slot];
        if (!slot.busy) return;
        if (slot.generation != id.generation) return;
        slot.cancel.store(true, .release);
        if (slot.phase.cmpxchgStrong(.pending, .skipped, .acq_rel, .acquire)) |phase| {
            // Without workers a job runs only inside `runQueued`.
            if (!threaded) assert(phase != .running);
            if (phase != .running) return;
            if (slot.phase.cmpxchgStrong(.running, .interrupting, .acq_rel, .acquire)) |now| {
                // The job returned in between; its end is the runner's.
                assert(now == .idle);
                return;
            }
            slot.interrupt.post(self.io);
        }
    }

    /// Whether any job is running or waiting to deliver.
    pub fn busyCount(self: *const Pool) u32 {
        var count: u32 = 0;
        for (self.slots) |*slot| count += @intFromBool(slot.busy);
        assert(count <= self.slots.len);
        return count;
    }

    /// Run the jobs spawned since the last drain on this thread, when there
    /// are no workers. Returns whether any ran. Bounded by the slot count.
    pub fn runQueued(self: *Pool) bool {
        if (threaded) return false;
        var ran = false;
        for (self.slots, 0..) |*slot, index| {
            if (!slot.queued) continue;
            assert(slot.busy);
            slot.queued = false;
            // Nothing interrupts a job on the main thread.
            const whole = self.runSlot(@intCast(index));
            assert(whole);
            ran = true;
        }
        return ran;
    }

    /// What to call for `entry`, or null for a cancelled job's result, whose
    /// slot is freed here. The router calls `finishDelivery` after the
    /// handler returns.
    pub fn delivery(self: *Pool, entry: *const JobEntry) ?Delivery {
        assert(entry.slot < self.slots.len);
        const slot = &self.slots[entry.slot];
        assert(slot.busy);
        assert(slot.generation == entry.generation);
        const id = JobId{ .slot = entry.slot, .generation = entry.generation };
        const cancelled = slot.cancel.load(.acquire);
        switch (entry.kind) {
            .result => {
                assert(entry.result_index < self.result_free_list.len);
                const handler = slot.handlers.on_result orelse {
                    self.releaseResult(entry.result_index);
                    return null;
                };
                if (cancelled) {
                    self.releaseResult(entry.result_index);
                    return null;
                }
                return .{
                    .handler = handler,
                    .type_id = slot.type_id,
                    .id = id,
                    .result = self.resultSlot(entry.result_index).ptr,
                    .done = null,
                };
            },
            .done => {
                const outcome: Outcome = if (cancelled) .cancelled else switch (entry.outcome) {
                    .finished => .finished,
                    .cancelled => .cancelled,
                    .failed => .{ .failed = entry.failure },
                };
                return .{
                    .handler = slot.handlers.on_done,
                    .type_id = slot.type_id,
                    .id = id,
                    .result = null,
                    .done = .{ .id = id, .outcome = outcome },
                };
            },
        }
    }

    /// Free what a delivered entry held: its result slot, or, after
    /// `on_done`, the job's slot, under a new generation.
    pub fn finishDelivery(self: *Pool, entry: *const JobEntry) void {
        const slot = &self.slots[entry.slot];
        assert(slot.busy);
        assert(slot.generation == entry.generation);
        switch (entry.kind) {
            .result => self.releaseResult(entry.result_index),
            .done => {
                assert(!slot.queued);
                assert(slot.phase.load(.acquire) == .idle);
                slot.busy = false;
                slot.run = null;
                slot.generation +%= 1;
            },
        }
    }

    fn releaseResult(self: *Pool, index: u32) void {
        assert(index < self.result_free_list.len);
        self.result_mutex.lockUncancelable(self.io);
        assert(self.result_free_count < self.result_free_list.len);
        self.result_free_list[self.result_free_count] = index;
        self.result_free_count += 1;
        self.result_mutex.unlock(self.io);
        if (threaded) self.result_free.post(self.io);
    }

    fn freeSlot(self: *const Pool) ?u32 {
        for (self.slots, 0..) |*slot, index| {
            if (!slot.busy) return @intCast(index);
        }
        return null;
    }

    fn inputSlot(self: *const Pool, index: u32) []align(value_alignment) u8 {
        assert(index < self.slots.len);
        const blocks = @divExact(self.input_stride, value_alignment);
        return std.mem.sliceAsBytes(self.input_blocks[index * blocks ..][0..blocks]);
    }

    fn resultSlot(self: *const Pool, index: u32) []align(value_alignment) u8 {
        assert(index < self.result_free_list.len);
        const blocks = @divExact(self.result_stride, value_alignment);
        return std.mem.sliceAsBytes(self.result_blocks[index * blocks ..][0..blocks]);
    }

    /// One runner: wait for a spawn of its slot, run it, deliver its end.
    /// Each turn runs one job. The task ends at `stop` (`stopping` is set
    /// before any group is cancelled, and the wait is cancelable) or when an
    /// interrupter claims the job, which then starts the next runner.
    fn runnerMain(self: *Pool, index: u32) std.Io.Cancelable!void {
        assert(threaded);
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        while (!self.stopping.load(.acquire)) {
            try slot.start.wait(self.io);
            if (self.runner_gate) |gate| try gate.wait(self.io);
            if (self.stopping.load(.acquire)) return;
            if (!self.runSlot(index)) return;
        }
    }

    /// Run the slot's job, or skip it when it was cancelled first, and push
    /// its end. Returns false when an interrupter claimed the job while
    /// `run` ran: the interrupter pushes the end, and this runner must end.
    fn runSlot(self: *Pool, index: u32) bool {
        if (!self.beginRun(index)) return true;
        const slot = &self.slots[index];
        var job = Job(void){ .pool = self, .slot = index };
        const returned = slot.run.?(self.inputSlot(index).ptr, @ptrCast(&job));
        return self.endRun(index, returned);
    }

    /// A runner takes the slot's spawn. Returns true when the job moved
    /// from `pending` to `running` and `run` must be called; false when a
    /// cancel skipped it first, whose `.cancelled` end this pushed without
    /// running it.
    fn beginRun(self: *Pool, index: u32) bool {
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        const generation = slot.generation;
        if (slot.phase.cmpxchgStrong(.pending, .running, .acq_rel, .acquire)) |phase| {
            assert(phase == .skipped);
            assert(slot.cancel.load(.acquire));
            slot.phase.store(.idle, .release);
            self.pushEnd(index, generation, error.Canceled);
            return false;
        }
        return true;
    }

    /// The slot's `run` returned `returned`: move the job from `running` to
    /// `idle` and push its end. Returns false, pushing nothing, when a
    /// cancel claimed the job first (`interrupting`): its interrupter owns
    /// the end (`finishInterrupt`).
    fn endRun(self: *Pool, index: u32, returned: anyerror!void) bool {
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        const generation = slot.generation;
        if (slot.phase.cmpxchgStrong(.running, .idle, .acq_rel, .acquire)) |phase| {
            assert(phase == .interrupting);
            assert(threaded);
            return false;
        }
        // `idle` before the push: once `on_done` is delivered the main
        // thread may spawn into the slot, which sets `pending`.
        self.pushEnd(index, generation, returned);
        return true;
    }

    /// The interrupted job's `run` has returned: move it from
    /// `interrupting` to `idle` and push its end as `.cancelled`.
    fn finishInterrupt(self: *Pool, index: u32) void {
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        assert(slot.phase.load(.acquire) == .interrupting);
        assert(slot.cancel.load(.acquire));
        const generation = slot.generation;
        slot.phase.store(.idle, .release);
        self.pushEnd(index, generation, error.Canceled);
    }

    /// Push the end of the slot's job, which returned `returned`, unless the
    /// app is stopping: nothing is delivered then.
    fn pushEnd(self: *Pool, index: u32, generation: u32, returned: anyerror!void) void {
        assert(index < self.slots.len);
        assert(self.slots[index].phase.load(.acquire) == .idle);
        var entry = JobEntry{
            .slot = index,
            .generation = generation,
            .kind = .done,
            .result_index = JobEntry.result_index_none,
            .outcome = .finished,
            .failure = error.Unexpected,
        };
        if (returned) |_| {} else |err| switch (err) {
            error.Canceled => entry.outcome = .cancelled,
            else => {
                entry.outcome = .failed;
                entry.failure = err;
            },
        }
        if (self.stopping.load(.acquire)) return;
        self.completions.pushJob(entry);
        self.wakeHost();
    }

    /// One interrupter: wait for a cancel to reach the slot's running job,
    /// then interrupt it. At `stop` the wait returns `error.Canceled`, and
    /// the interrupter cancels its runner's group before it returns, so
    /// awaiting the pool's group awaits every runner too.
    fn interrupterMain(self: *Pool, index: u32) std.Io.Cancelable!void {
        assert(threaded);
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        defer slot.group.cancel(self.io);
        while (!self.stopping.load(.acquire)) {
            try slot.interrupt.wait(self.io);
            self.interruptRunner(index);
        }
    }

    /// Cancel the slot's runner group, which makes the job's Io calls return
    /// `error.Canceled` and waits until the runner task has ended; start the
    /// next runner, then deliver the job's end as `.cancelled`. A job that
    /// ignores the cancel holds this interrupter, and no other slot, until
    /// `run` returns.
    fn interruptRunner(self: *Pool, index: u32) void {
        const slot = &self.slots[index];
        assert(slot.phase.load(.acquire) == .interrupting);
        assert(slot.cancel.load(.acquire));
        slot.group.cancel(self.io);
        assert(slot.group.token.load(.acquire) == null);
        if (self.stopping.load(.acquire)) return;
        slot.group.concurrent(self.io, runnerMain, .{ self, index }) catch |err| {
            std.debug.panic("gooey jobs: cannot restart the runner of slot {d} of {d} " ++
                "after cancelling job {s}: {t}. Give the io more threads.", .{
                index + 1,
                self.slots.len,
                handler_mod.typeName(slot.type_id),
                err,
            });
        };
        self.finishInterrupt(index);
    }

    fn cancelRequested(self: *const Pool, index: u32) bool {
        if (self.stopping.load(.acquire)) return true;
        return self.slots[index].cancel.load(.acquire);
    }

    fn post(self: *Pool, index: u32, bytes: []const u8) bool {
        assert(bytes.len <= self.result_stride);
        if (self.cancelRequested(index)) return false;
        if (threaded) {
            self.result_free.wait(self.io) catch {
                // A cancel or shutdown: re-arm the request so the job's next
                // Io call sees it too, and unwind.
                self.io.recancel();
                return false;
            };
            if (self.cancelRequested(index)) {
                self.result_free.post(self.io);
                return false;
            }
        }
        self.pushResult(index, bytes);
        return true;
    }

    /// Copy `bytes` into a free result slot and push it onto the ring for
    /// the next drain: a post that may go ahead, without its wait.
    fn pushResult(self: *Pool, index: u32, bytes: []const u8) void {
        assert(index < self.slots.len);
        assert(bytes.len <= self.result_stride);
        const result_index = self.claimResult(index, @intCast(bytes.len));
        @memcpy(self.resultSlot(result_index)[0..bytes.len], bytes);
        self.completions.pushJob(.{
            .slot = index,
            .generation = self.slots[index].generation,
            .kind = .result,
            .result_index = result_index,
            .outcome = .finished,
            .failure = error.Unexpected,
        });
        self.wakeHost();
    }

    /// Take a free result slot. With workers the semaphore already reserved
    /// one; without them a post cannot wait for a drain, so a full pool is a
    /// capacity-planning error.
    fn claimResult(self: *Pool, index: u32, size: u32) u32 {
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        self.result_used_max = @max(self.result_used_max, size);
        if (self.result_free_count == 0) {
            assert(!threaded);
            std.debug.panic("events pool 'job results' exhausted: capacity {d}, {d} " ++
                "in use, 1 requested by job {s}; without threads a post cannot wait " ++
                "for a drain. Raise ResourceLimits.events.job_result_count_max.", .{
                self.result_free_list.len,
                self.result_free_list.len,
                handler_mod.typeName(self.slots[index].type_id),
            });
        }
        self.result_free_count -= 1;
        const result_index = self.result_free_list[self.result_free_count];
        assert(result_index < self.result_free_list.len);
        return result_index;
    }
};
