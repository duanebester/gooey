const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("gooey_build_options");
const input = @import("../input/mod.zig");

const assert = std.debug.assert;

pub const Scenario = @TypeOf(build_options.frame_trace);
pub const scenario: Scenario = build_options.frame_trace;
pub const enabled = scenario != .off;
pub const seconds: u32 = build_options.frame_trace_seconds;

pub const entry_count_max: u32 = 32_768;
pub const warmup_frame_count: u32 = 60;
const scroll_reverse_frames: u32 = 60;
const scroll_step_px: f64 = 40;
const typing_run_count: u32 = 48;
const typing_text = "the quick brown fox jumps over the lazy dog ";

pub const file_name = "frame-trace.csv";

comptime {
    assert(seconds > 0);
    assert(@as(u64, seconds) * 500 <= entry_count_max);
    assert(typing_run_count <= 2 * typing_text.len);
    assert(@sizeOf(Entry) == 96);
}

pub const Entry = extern struct {
    frame_number: u64,
    tick_ns: u64,
    build_ns: u64,
    layout_ns: u64,
    emit_ns: u64,
    publish_ns: u64,
    pack_ns: u64,
    draw_ns: u64,
    done_ns: u64,
    paint_count: u32,
    node_count: u32,
    viewport_width_px: u32,
    viewport_height_px: u32,
    present_ns: u64,
};

pub const present_dropped: u64 = 1;

pub const Trace = struct {
    entries: []Entry,
    io: std.Io,
    start_ns: u64,
    tick_ns: u64,
    step_count: u32,
    finished: bool,
};

pub const State = if (enabled) Trace else void;

pub fn init(state: *State, gpa: std.mem.Allocator, io: std.Io) !void {
    if (comptime !enabled) return;
    state.entries = try gpa.alloc(Entry, entry_count_max);
    state.io = io;
    state.start_ns = 0;
    state.tick_ns = 0;
    state.step_count = 0;
    state.finished = false;
    assert(state.entries.len == entry_count_max);
}

pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
    if (comptime !enabled) return;
    gpa.free(state.entries);
}

pub fn stamp(state: *const State) u64 {
    if (comptime !enabled) return 0;
    const ns = std.Io.Timestamp.now(state.io, .awake).toNanoseconds();
    assert(ns > 0);
    return @intCast(ns);
}

pub fn entry(state: *State, frame_number: u64) ?*Entry {
    if (comptime !enabled) return null;
    assert(frame_number > 0);
    if (frame_number > state.entries.len) return null;
    return &state.entries[@intCast(frame_number - 1)];
}

pub const Mark = enum { build, layout, emit, publish, pack, draw, done };

pub fn mark(state: *State, frame_number: u64, which: Mark) void {
    if (comptime !enabled) return;
    const target = entry(state, frame_number) orelse return;
    const now = stamp(state);
    switch (which) {
        .build => {
            target.* = std.mem.zeroes(Entry);
            target.frame_number = frame_number;
            target.tick_ns = state.tick_ns;
            target.build_ns = now;
        },
        .layout => target.layout_ns = now,
        .emit => target.emit_ns = now,
        .publish => target.publish_ns = now,
        .pack => target.pack_ns = now,
        .draw => target.draw_ns = now,
        .done => target.done_ns = now,
    }
    assert(target.frame_number == frame_number);
}

pub fn notePresented(state: *State, frame_number: u64, present_ns: u64) void {
    if (comptime !enabled) return;
    const target = entry(state, frame_number) orelse return;
    assert(target.frame_number == frame_number);
    assert(target.done_ns > 0);
    assert(present_ns >= present_dropped);
    target.present_ns = present_ns;
}

pub fn noteFrame(state: *State, frame_number: u64, counts: struct {
    paint_count: u32,
    node_count: u32,
    viewport_width_px: u32,
    viewport_height_px: u32,
}) void {
    if (comptime !enabled) return;
    const target = entry(state, frame_number) orelse return;
    assert(target.frame_number == frame_number);
    target.paint_count = counts.paint_count;
    target.node_count = counts.node_count;
    target.viewport_width_px = counts.viewport_width_px;
    target.viewport_height_px = counts.viewport_height_px;
}

pub const TickAction = enum { none, quit };

pub fn beginTick(state: *State, window: anytype, in_flight: bool) TickAction {
    if (comptime !enabled) return .none;
    state.tick_ns = stamp(state);
    if (state.start_ns == 0) state.start_ns = state.tick_ns;
    if (state.finished) return .none;
    if (in_flight) return .none;
    const elapsed_ns = state.tick_ns - state.start_ns;
    const table_full = window.frame_number + 1 > state.entries.len;
    if (elapsed_ns >= @as(u64, seconds) * std.time.ns_per_s or table_full) {
        state.finished = true;
        dump(state, window.frame_number);
        return .quit;
    }
    drive(state, window);
    return .none;
}

fn drive(state: *State, window: anytype) void {
    if (scenario == .passive) return;
    const step = state.step_count;
    state.step_count += 1;
    window.render_requested = true;
    const centre = input.events.MouseEvent{
        .position = .{ .x = window.width / 2, .y = window.height / 2 },
        .button = .left,
        .click_count = 1,
        .modifiers = .{},
    };
    switch (scenario) {
        .off, .passive, .redraw => {},
        .scroll => {
            const forward = (step / scroll_reverse_frames) % 2 == 0;
            const delta: f64 = if (forward) scroll_step_px else -scroll_step_px;
            if (step == 0) window.queue.push(.{ .input = .{ .mouse_moved = centre } });
            window.queue.push(.{ .input = .{ .scroll = .{
                .position = centre.position,
                .delta = .{ .x = 0, .y = delta },
                .modifiers = .{},
            } } });
        },
        .typing => {
            if (step == 0) {
                window.queue.push(.{ .input = .{ .mouse_down = centre } });
                window.queue.push(.{ .input = .{ .mouse_up = centre } });
                return;
            }
            const position = (step - 1) % (2 * typing_run_count);
            if (position < typing_run_count) {
                const index = position % typing_text.len;
                window.queue.push(.{ .input = .{ .text_input = .{
                    .text = typing_text[index..][0..1],
                } } });
            } else {
                window.queue.push(.{ .input = .{ .key_down = .{
                    .key = .delete,
                    .modifiers = .{},
                    .characters = null,
                    .characters_ignoring_modifiers = null,
                    .is_repeat = false,
                } } });
            }
        },
    }
}

const renderer_name: []const u8 = switch (builtin.os.tag) {
    .macos => "metal",
    .linux => @tagName(build_options.linux_backend),
    .windows => @tagName(build_options.windows_renderer),
    .freestanding => "webgpu",
    else => "unknown",
};

const header = "frame,tick_ns,build_ns,layout_ns,emit_ns,publish_ns,pack_ns,draw_ns," ++
    "done_ns,paint_records,nodes,viewport_width_px,viewport_height_px,present_ns";

fn dump(state: *State, frame_count: u64) void {
    assert(frame_count <= state.entries.len);
    if (comptime builtin.os.tag == .freestanding) {
        const logged = dumpLines(state, frame_count, LogSink{});
        std.log.info("frame trace: logged {d} frames", .{logged});
        return;
    }
    const file = std.Io.Dir.cwd().createFile(state.io, file_name, .{}) catch |err| {
        std.log.err("frame trace: cannot create {s}: {s}", .{ file_name, @errorName(err) });
        return;
    };
    defer file.close(state.io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(state.io, &buffer);
    const written = dumpLines(state, frame_count, FileSink{ .writer = &writer.interface });
    writer.flush() catch |err| {
        std.log.err("frame trace: writing {s} failed: {s}", .{ file_name, @errorName(err) });
        return;
    };
    std.log.info("frame trace: wrote {d} frames to {s}", .{ written, file_name });
}

const FileSink = struct {
    writer: *std.Io.Writer,

    fn line(self: FileSink, text: []const u8) void {
        self.writer.writeAll(text) catch return;
        self.writer.writeByte('\n') catch return;
    }
};

const LogSink = struct {
    fn line(_: LogSink, text: []const u8) void {
        std.log.info("frame-trace,{s}", .{text});
    }
};

fn dumpLines(state: *const State, frame_count: u64, sink: anytype) u64 {
    var line_buffer: [512]u8 = undefined;
    const meta = std.fmt.bufPrint(&line_buffer, "# gooey frame trace: scenario={t} " ++
        "seconds={d} os={t} arch={t} renderer={s} optimize={t}", .{
        scenario,
        seconds,
        builtin.os.tag,
        builtin.cpu.arch,
        renderer_name,
        builtin.mode,
    }) catch unreachable;
    sink.line(meta);
    sink.line(header);
    var written: u64 = 0;
    var index: u64 = warmup_frame_count;
    while (index < frame_count) : (index += 1) {
        assert(index < state.entries.len);
        const e = &state.entries[@intCast(index)];
        if (e.done_ns == 0) continue;
        assert(e.frame_number == index + 1);
        const row = std.fmt.bufPrint(&line_buffer, "{d},{d},{d},{d},{d},{d},{d},{d},{d}," ++
            "{d},{d},{d},{d},{d}", .{
            e.frame_number,
            relative(state, e.tick_ns),
            relative(state, e.build_ns),
            relative(state, e.layout_ns),
            relative(state, e.emit_ns),
            relative(state, e.publish_ns),
            relative(state, e.pack_ns),
            relative(state, e.draw_ns),
            relative(state, e.done_ns),
            e.paint_count,
            e.node_count,
            e.viewport_width_px,
            e.viewport_height_px,
            presentRelative(state, e.present_ns),
        }) catch unreachable;
        sink.line(row);
        written += 1;
    }
    assert(written <= frame_count);
    return written;
}

fn presentRelative(state: *const State, ns: u64) u64 {
    if (ns <= present_dropped) return ns;
    return relative(state, ns);
}

fn relative(state: *const State, ns: u64) u64 {
    assert(ns >= state.start_ns);
    return ns - state.start_ns;
}
