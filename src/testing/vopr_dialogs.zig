//! The VOPR's platform file dialogs: a `FileDialogService` whose dialogs the
//! seed answers. A dialog stays open, as a portal's does, until a later
//! `.dialog` action answers it with paths, a cancel, or a failure, through
//! the event queue (the Linux host's route) or the completion ring (a worker
//! thread's); or the seed arms an answer that the next dialog returns at
//! once from `open`, as a modal dialog does on macOS and Windows. Dialogs
//! stay open up to the whole dialog table: the core refuses a request when
//! every slot is in use (`Effects.openFileDialog`), so the service never
//! needs to refuse one itself.

const std = @import("std");
const gooey = @import("gooey");

const assert = std.debug.assert;

const internals = gooey.internals;
const events = internals.events;
const handler = internals.handler;
const tick = internals.tick;
const Window = internals.window.Window;
const EventLimits = internals.limits.EventLimits;

/// The error a failed answer carries; the apps show any failure alike.
pub const answer_failure = error.DialogFailed;

/// One seeded answer: `paths` holds `path_count` NUL-joined paths when
/// `outcome` is `.selected`, and is empty otherwise.
pub const Answer = struct {
    route: Route,
    /// The open dialog answered, in open order; 0 for `.at_open`.
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

/// What a dialog returned from `open`, for the model: an armed answer.
/// `first` is the first path, valid until the next `arm`.
pub const Delivered = struct {
    request_id: u32,
    outcome: Answer.Outcome,
    path_count: u32,
    first: []const u8,
};

pub fn Dialogs(comptime limits: EventLimits) type {
    comptime {
        assert(limits.dialog_count_max >= 1);
        assert(limits.dialog_path_bytes_max <= limits.text_bytes_max);
    }
    return struct {
        /// Dialogs awaiting an answer, in open order.
        open: [limits.dialog_count_max]Open,
        open_count: u32,
        /// The answer the next dialog returns from `open`, if armed.
        armed: ?Armed,
        armed_bytes: [limits.dialog_path_bytes_max]u8,
        /// What `open` returned in the drain that just ran; the harness
        /// clears it after the tick.
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

        /// Stand in for the platform's dialogs, as a host binds its own.
        pub fn bind(self: *Self, window: *Window) void {
            assert(window.file_dialog == null);
            assert(self.opened_count == 0);
            window.file_dialog = .{ .context = self, .open = openDialog };
        }

        /// Keep `answer` for the next dialog to return at once.
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

        /// Close open dialog `target` (in open order) for the harness to
        /// answer, keeping the others in order.
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

        /// The core's call, in its drain: return the armed answer, or stay
        /// open for a later answer.
        fn openDialog(
            context: *anyopaque,
            scratch: std.mem.Allocator,
            request_id: u32,
            request: handler.FileDialogRequest,
        ) ?events.Completion.Outcome {
            const self: *Self = @ptrCast(@alignCast(context));
            _ = scratch; // Answers live in the harness's own storage.
            assert(request_id < limits.dialog_count_max);
            assert(self.delivered_at_open == null);
            self.opened_count += 1;
            const many = tick.selectsMany(request);
            if (self.armed) |armed| {
                self.armed = null;
                return self.deliver(request_id, armed, many);
            }
            // The core claimed a free slot for this request, and every
            // dialog open here holds another.
            assert(self.open_count < limits.dialog_count_max);
            self.open[self.open_count] = .{ .request_id = request_id, .many = many };
            self.open_count += 1;
            self.open_count_peak = @max(self.open_count_peak, self.open_count);
            return null;
        }

        /// A modal dialog that selects one path returns only the first of
        /// the armed paths.
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

/// Units a path is made of: ASCII, and two- and three-byte UTF-8, so a cut
/// at a byte budget can fall inside a codepoint. Never NUL.
const path_units = [_][]const u8{ "a", "b", "Z", ".", "/", " ", "é", "東" };

comptime {
    for (path_units) |unit| assert(std.mem.indexOfScalar(u8, unit, 0) == null);
}

pub const Written = struct { len: u32, count: u32 };

/// Write up to `count_max` NUL-joined paths into `target`, each starting
/// with "/" and as close to a length from `lengths` (bytes, drawn from the
/// seed's PRNG) as whole units allow. At least one path, of at least one
/// byte, always fits.
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

/// One path filling `target` with whole units; returns its length.
fn writePath(target: []u8, random: std.Random) u32 {
    assert(target.len > 0);
    target[0] = '/';
    var len: u32 = 1;
    // Each turn writes a unit or ends: a unit is at least one byte.
    while (len < target.len) {
        const unit = path_units[random.uintLessThan(usize, path_units.len)];
        if (unit.len > target.len - len) break;
        @memcpy(target[len..][0..unit.len], unit);
        len += @intCast(unit.len);
    }
    assert(std.unicode.utf8ValidateSlice(target[0..len]));
    return len;
}
