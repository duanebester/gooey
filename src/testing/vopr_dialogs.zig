const std = @import("std");
const gooey = @import("gooey");

const assert = std.debug.assert;

const internals = gooey.internals;
const events = internals.events;
const handler = internals.handler;
const tick = internals.tick;
const Window = internals.window.Window;
const EventLimits = internals.limits.EventLimits;

pub const answer_failure = error.DialogFailed;

pub const Answer = struct {
    route: Route,
    target: u32,
    outcome: Outcome,
    paths: []const u8,
    path_count: u32,

    pub const Route = enum { queue, ring, at_open };
    pub const Outcome = enum { selected, cancelled, failed };

    pub fn completion(self: *const Answer, request_id: u32) events.Completion {
        assert(self.route != .at_open);
        return .{ .request_id = request_id, .outcome = outcomeOf(self.outcome, .{
            .bytes = self.paths,
            .count = self.path_count,
        }) };
    }
};

pub const Delivered = struct {
    request_id: u32,
    outcome: Answer.Outcome,
    path_count: u32,
    first: []const u8,
};

pub fn Dialogs(comptime limits: EventLimits) type {
    comptime {
        assert(limits.dialog_count_max >= 1);
    }
    return struct {
        open: [limits.dialog_count_max]Open,
        open_count: u32,
        armed: ?Armed,
        armed_bytes: [limits.dialog_path_bytes_max]u8,
        delivered_at_open: ?Delivered,
        opened_count: u32,
        open_count_peak: u32,

        const Self = @This();

        pub const Open = struct { request_id: u32, many: bool };

        const Armed = struct { outcome: Answer.Outcome, len: u32, path_count: u32 };

        pub fn init(self: *Self) void {
            self.open_count = 0;
            self.armed = null;
            self.armed_bytes = @splat(0);
            self.delivered_at_open = null;
            self.opened_count = 0;
            self.open_count_peak = 0;
            assert(self.open.len == limits.dialog_count_max);
        }

        pub fn bind(self: *Self, window: *Window) void {
            assert(window.file_dialog == null);
            assert(self.opened_count == 0);
            window.file_dialog = .{ .context = self, .open = openDialog };
        }

        pub fn arm(self: *Self, answer: *const Answer) void {
            assert(answer.route == .at_open);
            assert(answer.paths.len <= self.armed_bytes.len);
            if (answer.outcome == .selected) assert(answer.path_count > 0);
            @memcpy(self.armed_bytes[0..answer.paths.len], answer.paths);
            self.armed = .{
                .outcome = answer.outcome,
                .len = @intCast(answer.paths.len),
                .path_count = answer.path_count,
            };
        }

        pub fn close(self: *Self, target: u32) Open {
            assert(target < self.open_count);
            assert(self.open_count <= self.open.len);
            const closed = self.open[target];
            var index = target;
            while (index + 1 < self.open_count) : (index += 1) {
                self.open[index] = self.open[index + 1];
            }
            self.open_count -= 1;
            return closed;
        }

        fn openDialog(
            context: *anyopaque,
            scratch: std.mem.Allocator,
            request_id: u32,
            request: handler.FileDialogRequest,
        ) ?events.Completion.Outcome {
            const self: *Self = @ptrCast(@alignCast(context));
            _ = scratch;
            assert(request_id < limits.dialog_count_max);
            assert(self.delivered_at_open == null);
            self.opened_count += 1;
            const many = tick.selectsMany(request);
            if (self.armed) |armed| {
                self.armed = null;
                return self.deliver(request_id, armed, many);
            }
            assert(self.open_count < limits.dialog_count_max);
            self.open[self.open_count] = .{ .request_id = request_id, .many = many };
            self.open_count += 1;
            self.open_count_peak = @max(self.open_count_peak, self.open_count);
            return null;
        }

        fn deliver(
            self: *Self,
            request_id: u32,
            armed: Armed,
            many: bool,
        ) events.Completion.Outcome {
            assert(armed.len <= self.armed_bytes.len);
            const bytes = self.armed_bytes[0..armed.len];
            const first_len = std.mem.indexOfScalar(u8, bytes, events.Paths.separator) orelse
                bytes.len;
            const one = armed.path_count == 1 or !many;
            const paths: events.Paths = if (armed.outcome != .selected)
                .{ .bytes = "", .count = 0 }
            else if (one)
                .{ .bytes = bytes[0..first_len], .count = 1 }
            else
                .{ .bytes = bytes, .count = armed.path_count };
            self.delivered_at_open = .{
                .request_id = request_id,
                .outcome = armed.outcome,
                .path_count = paths.count,
                .first = bytes[0..first_len],
            };
            return outcomeOf(armed.outcome, paths);
        }
    };
}

fn outcomeOf(outcome: Answer.Outcome, paths: events.Paths) events.Completion.Outcome {
    return switch (outcome) {
        .selected => blk: {
            assert(paths.count > 0);
            assert(paths.bytes.len >= 2 * paths.count - 1);
            break :blk .{ .file_selected = paths };
        },
        .cancelled => .cancelled,
        .failed => .{ .failed = answer_failure },
    };
}

const path_units = [_][]const u8{ "a", "b", "Z", ".", "/", " ", "é", "東" };

comptime {
    for (path_units) |unit| assert(std.mem.indexOfScalar(u8, unit, 0) == null);
}

pub const Written = struct { len: u32, count: u32 };

pub fn writePaths(target: []u8, options: struct {
    seed: u64,
    count_max: u32,
    lengths: []const u32,
}) Written {
    assert(target.len > 0);
    assert(options.count_max > 0);
    assert(options.lengths.len > 0);
    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();
    var len: u32 = 0;
    var count: u32 = 0;
    while (count < options.count_max) : (count += 1) {
        const separator: u32 = if (count > 0) 1 else 0;
        if (len + separator >= target.len) break;
        const room: u32 = @intCast(target.len - len - separator);
        const length_target = options.lengths[random.uintLessThan(usize, options.lengths.len)];
        if (separator == 1) target[len] = events.Paths.separator;
        len += separator;
        len += writePath(target[len..][0..@min(room, @max(length_target, 1))], random);
    }
    assert(count > 0);
    assert(len <= target.len);
    return .{ .len = len, .count = count };
}

fn writePath(target: []u8, random: std.Random) u32 {
    assert(target.len > 0);
    target[0] = '/';
    var len: u32 = 1;
    while (len < target.len) {
        const unit = path_units[random.uintLessThan(usize, path_units.len)];
        if (unit.len > target.len - len) break;
        @memcpy(target[len..][0..unit.len], unit);
        len += @intCast(unit.len);
    }
    assert(std.unicode.utf8ValidateSlice(target[0..len]));
    return len;
}
