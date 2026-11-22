const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const Button = components.Button;

const reply_bytes_max = 900;

const reply_chunks = [_][]const u8{
    "Gooey runs handlers on the main thread. ",
    "This reply comes from a job ",
    "on a worker thread, ",
    "streamed in chunks: ",
    "each `job.post` copies one ",
    "into a result slot and wakes the loop, ",
    "and the next drain hands it to `onChunk`. ",
    "No timer polls, ",
    "so between chunks the window is idle. ",
    "When `run` returns, `onFetched` runs once.",
};

pub const Fetch = struct {
    pub const Input = struct {
        delay_ms: u32,
        chunk_gap_ms: u32,
    };
    pub const Result = struct {
        len: u16,
        bytes: [64]u8,
    };

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        const io = job.io();
        try io.sleep(.fromMilliseconds(input.delay_ms), .awake);
        for (reply_chunks) |chunk| {
            std.debug.assert(chunk.len <= 64);
            var result: Result = .{ .len = @intCast(chunk.len), .bytes = @splat(0) };
            @memcpy(result.bytes[0..chunk.len], chunk);
            if (!job.post(&result)) return;
            try io.sleep(.fromMilliseconds(input.chunk_gap_ms), .awake);
        }
    }
};

pub const CountLines = struct {
    pub const Input = struct {
        path_len: u16,
        path: [path_bytes_max]u8,
    };
    pub const Result = struct {
        bytes: u64,
        lines: u64,
    };

    const file_bytes_max: u64 = 1 << 30;
    const buffer_bytes = 16 * 1024;

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        const io = job.io();
        const path = input.path[0..input.path_len];
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buffer: [buffer_bytes]u8 = undefined;
        var counted: Result = .{ .bytes = 0, .lines = 0 };
        // Bounded by `file_bytes_max`; a read returns at least one byte or
        // ends the stream.
        while (counted.bytes < file_bytes_max) {
            if (job.cancelled()) return error.Canceled;
            const read = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            counted.bytes += read;
            counted.lines += std.mem.countScalar(u8, buffer[0..read], '\n');
        }
        _ = job.post(&counted);
    }
};

const path_bytes_max = 512;

pub const State = struct {
    reply: [reply_bytes_max]u8 = @splat(0),
    reply_len: u32 = 0,
    status_bytes: [96]u8 = @splat(0),
    status_len: u32 = 0,
    fetch: ?gooey.JobId = null,
    counting: bool = false,
    chunks: u32 = 0,

    pub fn startFetch(self: *State, effects: *Effects) void {
        if (self.fetch != null) return;
        self.reply_len = 0;
        self.chunks = 0;
        self.fetch = effects.spawn(Fetch, &.{ .delay_ms = 600, .chunk_gap_ms = 120 }, .{
            .on_result = effects.handler(State.onChunk),
            .on_done = effects.handler(State.onFetched),
        }) catch |err| switch (err) {
            error.JobBusy => return self.setStatus("Every job slot is busy.", .{}),
        };
        self.setStatus("Fetching\u{2026}", .{});
    }

    pub fn cancelFetch(self: *State, effects: *Effects) void {
        const id = self.fetch orelse return;
        effects.cancelJob(id);
        self.setStatus("Cancelling\u{2026}", .{});
    }

    pub fn onChunk(self: *State, effects: *Effects) void {
        const chunk = effects.jobResult(Fetch).?;
        std.debug.assert(chunk.len <= chunk.bytes.len);
        const room = reply_bytes_max - self.reply_len;
        const kept = @min(room, chunk.len);
        @memcpy(self.reply[self.reply_len..][0..kept], chunk.bytes[0..kept]);
        self.reply_len += kept;
        self.chunks += 1;
        self.setStatus("Received {d} of {d} chunks\u{2026}", .{ self.chunks, reply_chunks.len });
    }

    pub fn onFetched(self: *State, effects: *Effects) void {
        const done = effects.jobDone().?;
        std.debug.assert(std.meta.eql(done.id, self.fetch.?));
        self.fetch = null;
        switch (done.outcome) {
            .finished => self.setStatus("Done: {d} chunks.", .{self.chunks}),
            .cancelled => self.setStatus("Cancelled after {d} chunks.", .{self.chunks}),
            .failed => |err| self.setStatus("Failed: {t}.", .{err}),
        }
    }

    pub fn pickFile(self: *State, effects: *Effects) void {
        if (self.counting) return;
        effects.openFileDialog(.{
            .kind = .{ .open = .{ .files = true, .directories = false, .multiple = false } },
            .on_complete = effects.handler(State.onPicked),
        }) catch |err| switch (err) {
            error.DialogBusy => self.setStatus("A file dialog is already open.", .{}),
        };
    }

    pub fn onPicked(self: *State, effects: *Effects) void {
        const completion = effects.completionEvent().?;
        switch (completion.outcome) {
            .file_selected => |paths| {
                const path = paths.first();
                if (path.len > path_bytes_max) {
                    self.setStatus("That path is longer than {d} bytes.", .{path_bytes_max});
                    return;
                }
                var input: CountLines.Input = .{
                    .path_len = @intCast(path.len),
                    .path = @splat(0),
                };
                @memcpy(input.path[0..path.len], path);
                _ = effects.spawn(CountLines, &input, .{
                    .on_result = effects.handler(State.onCounted),
                    .on_done = effects.handler(State.onCountDone),
                }) catch |err| switch (err) {
                    error.JobBusy => return self.setStatus("Every job slot is busy.", .{}),
                };
                self.counting = true;
                self.setStatus("Counting lines\u{2026}", .{});
            },
            .cancelled => {},
            .failed => |err| self.setStatus("The dialog failed: {t}.", .{err}),
        }
    }

    pub fn onCounted(self: *State, effects: *Effects) void {
        const counted = effects.jobResult(CountLines).?;
        self.setStatus("{d} lines, {d} bytes.", .{ counted.lines, counted.bytes });
    }

    pub fn onCountDone(self: *State, effects: *Effects) void {
        self.counting = false;
        switch (effects.jobDone().?.outcome) {
            .finished, .cancelled => {},
            .failed => |err| self.setStatus("Counting failed: {t}.", .{err}),
        }
    }

    pub fn deinit(self: *State) void {
        // Every job has returned by now, so nothing else reaches `State`.
        if (self.fetch != null) std.log.info("background: quit with a fetch in flight", .{});
    }

    fn setStatus(self: *State, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_bytes, format, args) catch
            self.status_bytes[0..0];
        self.status_len = @intCast(text.len);
    }

    fn status(self: *const State) []const u8 {
        if (self.status_len == 0) return "Idle.";
        return self.status_bytes[0..self.status_len];
    }
};

pub const App = gooey.App(State, render, .{
    .title = "Background work",
    .width = 640,
    .height = 360,
    .limits = .small,
    .jobs = &.{ Fetch, CountLines },
    .on_deinit = State.deinit,
});

pub const main = App.main;

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(24),
        .gap = 16,
    } }, .{
        ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            Button{
                .label = "Fetch",
                .disabled = s.fetch != null,
                .on_click = cx.on(State.startFetch, .{}),
            },
            Button{
                .label = "Cancel",
                .variant = .secondary,
                .disabled = s.fetch == null,
                .on_click = cx.on(State.cancelFetch, .{}),
            },
            // The web binds no file dialog service.
            if (builtin.cpu.arch.isWasm()) null else Button{
                .label = "Count lines\u{2026}",
                .variant = .secondary,
                .disabled = s.counting,
                .on_click = cx.on(State.pickFile, .{}),
            },
        }),
        ui.text(s.status(), .{ .size = 16 }),
        ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .padding = .all(12),
            .background = .surface,
            .corner_radius = .all(6),
        } }, .{
            ui.text(s.reply[0..s.reply_len], .{ .size = 14, .wrap = .words }),
        }),
    }));
}
