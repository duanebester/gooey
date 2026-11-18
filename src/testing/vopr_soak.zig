//! `zig build vopr-soak -- [--hours H | --minutes M] [--jobs N] [--out DIR]`:
//! run the VOPR on random seeds for hours, one child process per seed,
//! because a failing seed panics and aborts its process.
//!
//! The build passes the `vopr` executable, built ReleaseSafe for throughput
//! with every assertion still on, as the first argument. Each worker thread
//! runs one child at a time with a fresh random seed until the deadline. A
//! failing seed (a nonzero exit, a signal, or a child past
//! `seed_timeout_seconds`) is appended to `DIR/results.txt` with its replay
//! command and the tail of its stderr; `DIR/progress.log` gets a line with
//! the running counts every `progress_interval_seconds` and at the end.
//!
//! Resource sketch: `jobs` children at once, each one VOPR process (about
//! 100 MiB resident); per child, at most `stderr_bytes_max` of captured
//! stderr held until it exits. The results file grows by at most
//! `stderr_tail_bytes_max` plus a header per failure.

const std = @import("std");

const assert = std.debug.assert;

const Io = std.Io;

/// Upper bound on worker threads, so a mistyped `--jobs` cannot fork-bomb.
const jobs_max: u32 = 64;
const minutes_max: u32 = 7 * 24 * 60;
/// A seed takes about a second; one past this is hung, and a finding.
const seed_timeout_seconds: i64 = 300;
const progress_interval_seconds: u32 = 60;
/// Stderr kept per child: a panic's trace is a few KiB, a verbose run more.
const stderr_bytes_max: usize = 4 * 1024 * 1024;
/// Bytes of a failing child's stderr copied into the results file.
const stderr_tail_bytes_max: usize = 16 * 1024;

const Options = struct {
    vopr_path: []const u8,
    minutes: u32,
    jobs: u32,
    out_dir: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const options = parseArgs(init.minimal.args.vector) orelse {
        std.debug.print("usage: vopr-soak VOPR [--hours H | --minutes M] [--jobs N] " ++
            "[--out DIR]\n", .{});
        return error.InvalidArguments;
    };
    const io = init.io;
    try Io.Dir.cwd().createDirPath(io, options.out_dir);
    var soak: Soak = undefined;
    try soak.open(io, &options);
    defer soak.close();

    soak.log("soak: {d} min, {d} jobs, vopr {s}\n", .{
        options.minutes,
        options.jobs,
        options.vopr_path,
    });
    var threads: [jobs_max]std.Thread = undefined;
    var started: u32 = 0;
    defer for (threads[0..started]) |thread| thread.join();
    while (started < options.jobs) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, Soak.work, .{ &soak, init.gpa });
    }
    soak.reportUntilDeadline();
}

fn parseArgs(args: []const [*:0]const u8) ?Options {
    if (args.len < 2) return null;
    var options: Options = .{
        .vopr_path = std.mem.span(args[1]),
        .minutes = 8 * 60,
        .jobs = defaultJobs(),
        .out_dir = "zig-out/vopr-soak",
    };
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (index + 1 == args.len) return null;
        const value = std.mem.span(args[index + 1]);
        index += 1;
        const number = std.fmt.parseInt(u32, value, 10) catch null;
        if (std.mem.eql(u8, arg, "--out")) {
            options.out_dir = value;
            continue;
        }
        const count = number orelse return null;
        if (std.mem.eql(u8, arg, "--hours")) {
            options.minutes = count *| 60;
        } else {
            if (std.mem.eql(u8, arg, "--minutes")) {
                options.minutes = count;
            } else {
                if (!std.mem.eql(u8, arg, "--jobs")) return null;
                options.jobs = count;
            }
        }
    }
    if (options.minutes == 0 or options.minutes > minutes_max) return null;
    if (options.jobs == 0 or options.jobs > jobs_max) return null;
    return options;
}

/// Half the cores: the soak shares the machine.
fn defaultJobs() u32 {
    const cores = std.Thread.getCpuCount() catch 2;
    const jobs: u32 = @intCast(@min(@max(cores / 2, 1), jobs_max));
    assert(jobs >= 1);
    return jobs;
}

const Soak = struct {
    io: Io,
    options: *const Options,
    deadline: Io.Timestamp,
    start: Io.Timestamp,
    mutex: Io.Mutex,
    results: Io.File,
    results_len: u64,
    progress: Io.File,
    progress_len: u64,
    passed: u64,
    failed: u64,
    running: u32,

    fn open(self: *Soak, io: Io, options: *const Options) !void {
        assert(options.minutes > 0);
        self.io = io;
        self.options = options;
        self.mutex = .init;
        self.passed = 0;
        self.failed = 0;
        self.running = options.jobs;
        self.start = Io.Timestamp.now(io, .awake);
        const minutes: i64 = options.minutes;
        self.deadline = self.start.addDuration(.fromSeconds(minutes * 60));
        self.results = try openAppend(io, options.out_dir, "results.txt");
        errdefer self.results.close(io);
        self.results_len = try self.results.length(io);
        self.progress = try openAppend(io, options.out_dir, "progress.log");
        self.progress_len = try self.progress.length(io);
    }

    fn close(self: *Soak) void {
        assert(self.running == 0);
        self.progress.close(self.io);
        self.results.close(self.io);
    }

    /// One worker: seeds until the deadline, one child each.
    fn work(self: *Soak, gpa: std.mem.Allocator) void {
        defer {
            self.mutex.lockUncancelable(self.io);
            self.running -= 1;
            self.mutex.unlock(self.io);
        }
        var seed_index: u64 = 0;
        while (self.beforeDeadline()) : (seed_index += 1) {
            assert(seed_index < std.math.maxInt(u64));
            var seed: u64 = 0;
            self.io.random(std.mem.asBytes(&seed));
            self.runSeed(gpa, seed);
        }
    }

    fn beforeDeadline(self: *const Soak) bool {
        const now = Io.Timestamp.now(self.io, .awake);
        return now.toNanoseconds() < self.deadline.toNanoseconds();
    }

    fn runSeed(self: *Soak, gpa: std.mem.Allocator, seed: u64) void {
        var seed_buffer: [24]u8 = undefined;
        const seed_text = std.fmt.bufPrint(&seed_buffer, "{d}", .{seed}) catch unreachable;
        const vopr = self.options.vopr_path;
        const argv = [_][]const u8{ vopr, seed_text };
        const timeout: Io.Clock.Duration = .{
            .raw = .fromSeconds(seed_timeout_seconds),
            .clock = .awake,
        };
        const result = std.process.run(gpa, self.io, .{
            .argv = &argv,
            .stdout_limit = .limited(stderr_bytes_max),
            .stderr_limit = .limited(stderr_bytes_max),
            .timeout = .{ .duration = timeout },
        }) catch |err| {
            self.recordFailure(seed, @errorName(err), "");
            return;
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        const passed = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (passed) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.passed += 1;
            return;
        }
        var term_buffer: [64]u8 = undefined;
        const term = std.fmt.bufPrint(&term_buffer, "{f}", .{result.term}) catch "failed";
        self.recordFailure(seed, term, result.stderr);
    }

    /// Append the seed, how it failed, its replay command, and the tail of
    /// its stderr to the results file.
    fn recordFailure(self: *Soak, seed: u64, how: []const u8, stderr: []const u8) void {
        const tail = stderr[stderr.len - @min(stderr.len, stderr_tail_bytes_max) ..];
        var header_buffer: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, "\n== seed {d}: {s}\n" ++
            "replay: zig build vopr -- {d} --verbose\n", .{ seed, how, seed }) catch unreachable;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.failed += 1;
        appendTo(self.io, self.results, &self.results_len, header);
        appendTo(self.io, self.results, &self.results_len, tail);
    }

    /// Log the counts every interval until the deadline and the workers end,
    /// checking each second so the last line follows the last child.
    fn reportUntilDeadline(self: *Soak) void {
        const second_count_max = (self.options.minutes + 1) * 60 + seed_timeout_seconds;
        var second: u64 = 1;
        while (second <= second_count_max) : (second += 1) {
            self.io.sleep(.fromSeconds(1), .awake) catch {};
            const done = self.finished();
            if (done or second % progress_interval_seconds == 0) {
                self.reportOnce();
                if (done) return;
            }
        }
        std.debug.panic("vopr-soak: workers still running {d} s after start", .{second});
    }

    fn finished(self: *Soak) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.running == 0;
    }

    fn reportOnce(self: *Soak) void {
        self.mutex.lockUncancelable(self.io);
        const passed = self.passed;
        const failed = self.failed;
        const running = self.running;
        self.mutex.unlock(self.io);
        const now = Io.Timestamp.now(self.io, .awake);
        const elapsed_s = @divFloor(self.start.durationTo(now).toNanoseconds(), std.time.ns_per_s);
        self.log("soak: {d} s, {d} seeds passed, {d} failed{s}\n", .{
            elapsed_s,
            passed,
            failed,
            if (running == 0) ", done" else "",
        });
    }

    fn log(self: *Soak, comptime format: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
        std.debug.print("{s}", .{line});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        appendTo(self.io, self.progress, &self.progress_len, line);
    }
};

fn openAppend(io: Io, dir_path: []const u8, name: []const u8) !Io.File {
    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ dir_path, name });
    return Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
}

/// Append at the file's end; a failed write is logged, not fatal, so one
/// full disk does not end an overnight run's other reporting.
fn appendTo(io: Io, file: Io.File, len: *u64, bytes: []const u8) void {
    file.writePositionalAll(io, bytes, len.*) catch |err| {
        std.log.err("vopr-soak: write failed: {s}", .{@errorName(err)});
        return;
    };
    len.* += bytes.len;
}
