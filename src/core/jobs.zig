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

pub const threaded = !builtin.single_threaded and !builtin.cpu.arch.isWasm();

pub const Mode = enum {
    workers,
    main_thread,
    stepped,

    pub const host: Mode = if (threaded) .workers else .main_thread;
};

pub const value_alignment: u32 = 16;

const input_type_depth_max: u32 = 256;

pub const JobId = struct {
    slot: u32,
    generation: u32,
};

pub const Outcome = union(enum) {
    finished,
    cancelled,
    failed: anyerror,
};

pub const SpawnError = error{JobBusy};

pub const Done = struct {
    id: JobId,
    outcome: Outcome,
};

pub const Handlers = struct {
    on_result: ?Handler = null,
    on_done: Handler,
};

pub fn Job(comptime Result: type) type {
    return extern struct {
        pool: *Pool,
        slot: u32,

        const Self = @This();

        pub fn io(self: *const Self) std.Io {
            assert(self.slot < self.pool.slots.len);
            return self.pool.io;
        }

        pub fn cancelled(self: *const Self) bool {
            assert(self.slot < self.pool.slots.len);
            return self.pool.cancelRequested(self.slot);
        }

        pub fn post(self: *Self, result: *const Result) bool {
            assert(self.slot < self.pool.slots.len);
            return self.pool.post(self.slot, std.mem.asBytes(result));
        }
    };
}

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
        if (!@hasDecl(Spec, "posts_max")) {
            @compileError("gooey job " ++ name ++ " needs `pub const posts_max: u32`, the " ++
                "most results one run posts; on the main thread (the web, single-threaded " ++
                "builds) jobs start only while that many result slots are free");
        }
        if (@TypeOf(Spec.posts_max) != u32) {
            @compileError("gooey job " ++ name ++ ": posts_max must be a `u32`");
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

const Block = struct { bytes: [value_alignment]u8 align(value_alignment) };

comptime {
    assert(@sizeOf(Block) == value_alignment);
    assert(@alignOf(Block) == value_alignment);
}

const Slot = struct {
    busy: bool,
    queued: bool,
    queued_order: u64,
    posts_max: u32,
    posted_count: u32,
    type_id: usize,
    handlers: Handlers,
    generation: u32,
    run: ?RunFn,
    cancel: std.atomic.Value(bool),
    phase: std.atomic.Value(Phase),
    start: std.Io.Semaphore,
    interrupt: std.Io.Semaphore,
    group: std.Io.Group,
};

pub const Phase = enum(u8) {
    idle,
    pending,
    skipped,
    running,
    interrupting,
};

pub const Delivery = struct {
    handler: Handler,
    type_id: usize,
    id: JobId,
    result: ?[*]align(value_alignment) const u8,
    done: ?Done,
};

pub const Pool = struct {
    io: std.Io,
    mode: Mode,
    type_ids: []const usize,
    slots: []Slot,
    input_blocks: []Block,
    input_stride: u32,
    input_used_max: u32,
    result_blocks: []Block,
    result_stride: u32,
    result_used_max: u32,
    result_free_list: []u32,
    result_free_count: u32,
    result_mutex: std.Io.Mutex,
    result_free: std.Io.Semaphore,
    completions: *events.CompletionRing,
    wake_mutex: std.Io.Mutex,
    wake: ?images.WakeService,
    stopping: std.atomic.Value(bool),
    stopped: bool,
    group: std.Io.Group,
    spawned_count: u64,
    runner_gate: ?*std.Io.Event,

    pub fn initInPlace(
        self: *Pool,
        gpa: std.mem.Allocator,
        io: std.Io,
        completions: *events.CompletionRing,
        limits: *const limits_mod.EventLimits,
        type_ids: []const usize,
        mode: Mode,
    ) !void {
        assert(limits.job_count_max > 0);
        assert(limits.job_result_count_max > 0);
        if (mode == .workers) assert(threaded);
        self.io = io;
        self.mode = mode;
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
        if (self.workers()) try self.startWorkers();
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
                .queued_order = 0,
                .posts_max = 0,
                .posted_count = 0,
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

    fn startWorkers(self: *Pool) !void {
        assert(self.workers());
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
        for (self.slots) |*slot| slot.group.cancel(self.io);
        return err;
    }

    pub fn stop(self: *Pool) void {
        if (self.stopped) return;
        assert(self.type_ids.len > 0);
        self.stopping.store(true, .release);
        if (self.workers()) self.group.cancel(self.io);
        self.stopped = true;
        assert(self.group.token.load(.acquire) == null);
        for (self.slots) |*slot| assert(slot.group.token.load(.acquire) == null);
    }

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        self.stop();
        assert(self.stopped);
        if (self.type_ids.len > 0) self.release(gpa);
        self.* = undefined;
    }

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

    pub fn spawn(
        self: *Pool,
        type_id: usize,
        run: RunFn,
        posts_max: u32,
        input: []const u8,
        handlers: Handlers,
    ) SpawnError!JobId {
        assert(type_id != 0);
        assert(posts_max <= self.result_free_list.len);
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
        const index = self.freeSlot() orelse {
            assert(self.busyCount() == self.slots.len);
            return error.JobBusy;
        };
        const slot = &self.slots[index];
        assert(!slot.busy);
        @memcpy(self.inputSlot(index)[0..input.len], input);
        self.input_used_max = @max(self.input_used_max, @as(u32, @intCast(input.len)));
        slot.busy = true;
        slot.type_id = type_id;
        slot.handlers = handlers;
        slot.run = run;
        slot.posts_max = posts_max;
        slot.posted_count = 0;
        slot.cancel.store(false, .release);
        assert(slot.phase.load(.acquire) == .idle);
        slot.phase.store(.pending, .release);
        self.spawned_count += 1;
        switch (self.mode) {
            .workers => if (self.workers()) slot.start.post(self.io),
            .main_thread => {
                slot.queued = true;
                slot.queued_order = self.spawned_count - 1;
            },
            .stepped => {},
        }
        assert(slot.busy);
        return .{ .slot = index, .generation = slot.generation };
    }

    pub fn cancel(self: *Pool, id: JobId) void {
        assert(id.slot < self.slots.len);
        const slot = &self.slots[id.slot];
        if (!slot.busy) return;
        if (slot.generation != id.generation) return;
        slot.cancel.store(true, .release);
        if (slot.phase.cmpxchgStrong(.pending, .skipped, .acq_rel, .acquire)) |phase| {
            if (self.mode == .main_thread) assert(phase != .running);
            if (phase != .running) return;
            if (slot.phase.cmpxchgStrong(.running, .interrupting, .acq_rel, .acquire)) |now| {
                assert(now == .idle);
                return;
            }
            if (self.workers()) slot.interrupt.post(self.io);
        }
    }

    pub fn busyCount(self: *const Pool) u32 {
        var count: u32 = 0;
        for (self.slots) |*slot| count += @intFromBool(slot.busy);
        assert(count <= self.slots.len);
        return count;
    }

    pub fn runQueued(self: *Pool) bool {
        if (self.mode != .main_thread) return false;
        assert(self.result_free_count == self.result_free_list.len);
        var ran = false;
        var turn: u32 = 0;
        while (turn < self.slots.len) : (turn += 1) {
            const index = self.queuedOldest() orelse break;
            const slot = &self.slots[index];
            if (slot.posts_max > self.result_free_count) {
                assert(ran);
                break;
            }
            assert(slot.busy);
            slot.queued = false;
            const whole = self.runSlot(index);
            assert(whole);
            ran = true;
        }
        return ran;
    }

    fn queuedOldest(self: *const Pool) ?u32 {
        assert(self.mode == .main_thread);
        var oldest: ?u32 = null;
        for (self.slots, 0..) |*slot, index| {
            if (!slot.queued) continue;
            if (oldest) |current| {
                assert(slot.queued_order != self.slots[current].queued_order);
                if (slot.queued_order < self.slots[current].queued_order) {
                    oldest = @intCast(index);
                }
            } else {
                oldest = @intCast(index);
            }
        }
        return oldest;
    }

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
            .done => return self.deliveryDone(entry, cancelled),
        }
    }

    fn deliveryDone(self: *Pool, entry: *const JobEntry, cancelled: bool) Delivery {
        assert(entry.kind == .done);
        assert(entry.result_index == JobEntry.result_index_none);
        const slot = &self.slots[entry.slot];
        const id = JobId{ .slot = entry.slot, .generation = entry.generation };
        const outcome: Outcome = if (cancelled) .cancelled else switch (entry.outcome) {
            .finished => .finished,
            .cancelled => .cancelled,
            .failed => .{ .failed = entry.failure },
        };
        const done_delivery = Delivery{
            .handler = slot.handlers.on_done,
            .type_id = slot.type_id,
            .id = id,
            .result = null,
            .done = .{ .id = id, .outcome = outcome },
        };
        assert(!slot.queued);
        assert(slot.phase.load(.acquire) == .idle);
        slot.busy = false;
        slot.run = null;
        slot.generation +%= 1;
        assert(slot.generation != id.generation);
        return done_delivery;
    }

    pub fn finishDelivery(self: *Pool, entry: *const JobEntry) void {
        assert(entry.slot < self.slots.len);
        const slot = &self.slots[entry.slot];
        switch (entry.kind) {
            .result => {
                assert(slot.busy);
                assert(slot.generation == entry.generation);
                self.releaseResult(entry.result_index);
            },
            .done => assert(slot.generation == entry.generation +% 1),
        }
    }

    fn releaseResult(self: *Pool, index: u32) void {
        assert(index < self.result_free_list.len);
        self.result_mutex.lockUncancelable(self.io);
        assert(self.result_free_count < self.result_free_list.len);
        self.result_free_list[self.result_free_count] = index;
        self.result_free_count += 1;
        self.result_mutex.unlock(self.io);
        if (self.workers()) self.result_free.post(self.io);
    }

    pub fn phaseOf(self: *const Pool, index: u32) Phase {
        assert(index < self.slots.len);
        return self.slots[index].phase.load(.acquire);
    }

    inline fn workers(self: *const Pool) bool {
        return threaded and self.mode == .workers;
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

    fn runnerMain(self: *Pool, index: u32) std.Io.Cancelable!void {
        assert(self.workers());
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        while (!self.stopping.load(.acquire)) {
            try slot.start.wait(self.io);
            if (self.runner_gate) |gate| try gate.wait(self.io);
            if (self.stopping.load(.acquire)) return;
            if (!self.runSlot(index)) return;
        }
    }

    fn runSlot(self: *Pool, index: u32) bool {
        if (!self.beginRun(index)) return true;
        const slot = &self.slots[index];
        var job = Job(void){ .pool = self, .slot = index };
        const returned = slot.run.?(self.inputSlot(index).ptr, @ptrCast(&job));
        return self.endRun(index, returned);
    }

    pub fn beginRun(self: *Pool, index: u32) bool {
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

    pub fn endRun(self: *Pool, index: u32, returned: anyerror!void) bool {
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        const generation = slot.generation;
        if (slot.phase.cmpxchgStrong(.running, .idle, .acq_rel, .acquire)) |phase| {
            assert(phase == .interrupting);
            assert(self.mode != .main_thread);
            return false;
        }
        self.pushEnd(index, generation, returned);
        return true;
    }

    pub fn finishInterrupt(self: *Pool, index: u32) void {
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        assert(slot.phase.load(.acquire) == .interrupting);
        assert(slot.cancel.load(.acquire));
        const generation = slot.generation;
        slot.phase.store(.idle, .release);
        self.pushEnd(index, generation, error.Canceled);
    }

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

    fn interrupterMain(self: *Pool, index: u32) std.Io.Cancelable!void {
        assert(self.workers());
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        defer slot.group.cancel(self.io);
        while (!self.stopping.load(.acquire)) {
            try slot.interrupt.wait(self.io);
            self.interruptRunner(index);
        }
    }

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

    pub fn post(self: *Pool, index: u32, bytes: []const u8) bool {
        assert(index < self.slots.len);
        assert(bytes.len <= self.result_stride);
        const phase = self.slots[index].phase.load(.acquire);
        assert(phase == .running or phase == .interrupting);
        if (self.cancelRequested(index)) return false;
        if (self.mode == .stepped) assert(self.result_free_count > 0);
        if (self.mode == .main_thread) self.countPost(index);
        if (self.workers()) {
            self.result_free.wait(self.io) catch {
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

    fn countPost(self: *Pool, index: u32) void {
        assert(self.mode == .main_thread);
        const slot = &self.slots[index];
        assert(slot.posted_count <= slot.posts_max);
        if (slot.posted_count == slot.posts_max) {
            std.debug.panic("job {s} posted more than its posts_max {d} in one run; " ++
                "without threads a post cannot wait for a drain. Raise {s}.posts_max " ++
                "(at most ResourceLimits.events.job_result_count_max {d}).", .{
                handler_mod.typeName(slot.type_id),
                slot.posts_max,
                handler_mod.typeName(slot.type_id),
                self.result_free_list.len,
            });
        }
        slot.posted_count += 1;
    }

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

    fn claimResult(self: *Pool, index: u32, size: u32) u32 {
        assert(index < self.slots.len);
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        self.result_used_max = @max(self.result_used_max, size);
        assert(self.result_free_count > 0);
        self.result_free_count -= 1;
        const result_index = self.result_free_list[self.result_free_count];
        assert(result_index < self.result_free_list.len);
        return result_index;
    }
};
