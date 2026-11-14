//! `zig build frame-trace-report -- <trace>...`: summarize frame traces
//! (`-Dframe-trace`, `src/core/frame_trace.zig`) as Markdown.
//!
//! Per trace it prints p50, p95, p99, and max of every phase in milliseconds,
//! the present cadence, missed refreshes, and the headroom against a 120 Hz
//! frame (8.33 ms). A trace is the native `frame-trace.csv` or a saved browser
//! console log: any text before `frame-trace,` on a line is ignored.
//!
//! Phases of one frame, from its row's timestamps:
//! - drain: tick → build (event routing and handlers)
//! - build, layout, emit: the main thread's phases; publish ends emit
//! - wait: publish → pack, the present-pacing wait on the render side
//! - pack, draw: the render side; draw ends when `presentBuilt` returns
//! - main: tick → publish; render: pack → done
//! - serial: main + render + wake, the work one frame in flight serializes,
//!   where wake is the previous frame's done → this frame's tick
//!
//! Missed refreshes: consecutive frames whose pack starts are `k` refresh
//! periods apart miss `k − 1` refreshes. `--refresh-hz=<hz>` gives the
//! display's refresh rate; without it the period is estimated from the median
//! pack-to-pack interval, snapped to a common display rate. A compositor's
//! frame callbacks jitter around the period (mutter: p10 15% short), so a low
//! percentile would snap to a faster rate; a 10th percentile under 3/4 of the
//! median instead means the app misses most refreshes, and it is used.
//!
//! Resource sketch: one trace holds at most `row_count_max` rows (3 MiB of
//! rows plus 8 MiB of text, both from the page allocator); the tool is a
//! host-side program, outside Gooey's runtime allocation rules.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

const assert = std.debug.assert;

const row_count_max: u32 = 32_768;
const file_bytes_max: u32 = 8 * 1024 * 1024;
const column_count: u32 = 13;
const frame_ms_target: f64 = 1000.0 / 120.0;
const rates_hz = [_]f64{ 30, 48, 50, 60, 72, 75, 90, 100, 120, 144, 165, 240 };

const Row = struct {
    frame: u64,
    tick: u64,
    build: u64,
    layout: u64,
    emit: u64,
    publish: u64,
    pack: u64,
    draw: u64,
    done: u64,
    paint_records: u64,
    nodes: u64,
    width_px: u64,
    height_px: u64,
};

const Phase = enum { drain, build, layout, emit, wait, pack, draw, main, render, serial };
const phase_count = std.enums.values(Phase).len;

const Trace = struct {
    rows: [row_count_max]Row,
    row_count: u32,
    meta: [256]u8,
    meta_len: u32,
};

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.vector;
    if (args.len < 2) {
        std.debug.print("usage: zig build frame-trace-report -- [--refresh-hz=<hz>] " ++
            "<frame-trace.csv>...\n", .{});
        std.process.exit(2);
    }
    var refresh_ms: ?f64 = null;
    const allocator = std.heap.page_allocator;
    const trace = allocator.create(Trace) catch {
        std.debug.print("frame-trace-report: out of memory\n", .{});
        std.process.exit(2);
    };
    defer allocator.destroy(trace);
    const contents = allocator.alloc(u8, file_bytes_max) catch {
        std.debug.print("frame-trace-report: out of memory\n", .{});
        std.process.exit(2);
    };
    defer allocator.free(contents);

    for (args[1..]) |arg| {
        const path = std.mem.span(arg);
        const flag = "--refresh-hz=";
        if (std.mem.startsWith(u8, path, flag)) {
            const hz = std.fmt.parseFloat(f64, path[flag.len..]) catch 0;
            if (!(hz >= 1 and hz <= 1000)) {
                std.debug.print("frame-trace-report: bad {s}\n", .{path});
                std.process.exit(2);
            }
            refresh_ms = 1000 / hz;
            continue;
        }
        const text = Dir.cwd().readFile(init.io, path, contents) catch |err| {
            std.debug.print("frame-trace-report: cannot read {s}: {s}\n", .{
                path,
                @errorName(err),
            });
            std.process.exit(2);
        };
        if (text.len == contents.len) {
            std.debug.print("frame-trace-report: {s} exceeds {d} bytes\n", .{
                path,
                file_bytes_max,
            });
            std.process.exit(2);
        }
        parse(trace, text) catch |err| {
            std.debug.print("frame-trace-report: {s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(2);
        };
        report(trace, path, refresh_ms);
    }
}

fn parse(trace: *Trace, text: []const u8) !void {
    trace.row_count = 0;
    trace.meta_len = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: u32 = 0;
    while (lines.next()) |raw| {
        line_count += 1;
        assert(line_count <= file_bytes_max);
        const marker = "frame-trace,";
        const start = if (std.mem.indexOf(u8, raw, marker)) |at| at + marker.len else 0;
        const line = std.mem.trim(u8, raw[start..], " \r\t");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            const length: u32 = @intCast(@min(line.len, trace.meta.len));
            @memcpy(trace.meta[0..length], line[0..length]);
            trace.meta_len = length;
            continue;
        }
        if (std.mem.startsWith(u8, line, "frame,")) continue;
        if (trace.row_count == row_count_max) return error.TooManyRows;
        trace.rows[trace.row_count] = try parseRow(line);
        trace.row_count += 1;
    }
    if (trace.row_count < 2) return error.TooFewRows;
}

fn parseRow(line: []const u8) !Row {
    var values: [column_count]u64 = undefined;
    var fields = std.mem.splitScalar(u8, line, ',');
    var index: u32 = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == column_count) return error.TooManyColumns;
        values[index] = try std.fmt.parseInt(u64, field, 10);
    }
    if (index != column_count) return error.TooFewColumns;
    const row = Row{
        .frame = values[0],
        .tick = values[1],
        .build = values[2],
        .layout = values[3],
        .emit = values[4],
        .publish = values[5],
        .pack = values[6],
        .draw = values[7],
        .done = values[8],
        .paint_records = values[9],
        .nodes = values[10],
        .width_px = values[11],
        .height_px = values[12],
    };
    if (!ordered(&row)) return error.UnorderedRow;
    return row;
}

/// Every stamp of a complete frame follows the one before it.
fn ordered(row: *const Row) bool {
    const stamps = [_]u64{
        row.tick, row.build, row.layout, row.emit, row.publish,
        row.pack, row.draw,  row.done,
    };
    for (stamps[1..], stamps[0 .. stamps.len - 1]) |later, earlier| {
        if (later < earlier) return false;
    }
    return true;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn phaseMs(rows: []const Row, index: usize, phase: Phase) ?f64 {
    const row = &rows[index];
    return switch (phase) {
        .drain => ms(row.build - row.tick),
        .build => ms(row.layout - row.build),
        .layout => ms(row.emit - row.layout),
        .emit => ms(row.publish - row.emit),
        .wait => ms(row.pack - row.publish),
        .pack => ms(row.draw - row.pack),
        .draw => ms(row.done - row.draw),
        .main => ms(row.publish - row.tick),
        .render => ms(row.done - row.pack),
        .serial => blk: {
            if (index == 0) break :blk null;
            const previous = &rows[index - 1];
            if (previous.frame + 1 != row.frame) break :blk null;
            if (row.tick < previous.done) break :blk null;
            break :blk ms(row.publish - row.tick) + ms(row.done - row.pack) +
                ms(row.tick - previous.done);
        },
    };
}

/// The value at `fraction` of the sorted `values` (nearest rank).
fn percentile(sorted: []const f64, fraction: f64) f64 {
    assert(sorted.len > 0);
    assert(fraction >= 0);
    assert(fraction <= 1);
    const last: f64 = @floatFromInt(sorted.len - 1);
    const rank: usize = @intFromFloat(@round(last * fraction));
    assert(rank < sorted.len);
    return sorted[rank];
}

fn report(trace: *const Trace, path: []const u8, refresh_ms: ?f64) void {
    const rows = trace.rows[0..trace.row_count];
    var scratch: [row_count_max]f64 = undefined;
    std.debug.print("\n### {s}\n\n{s}\n\n", .{ path, trace.meta[0..trace.meta_len] });
    const last = &rows[rows.len - 1];
    std.debug.print("{d} frames, {d} paint records and {d} nodes in the last, " ++
        "framebuffer {d}x{d} px\n\n", .{
        rows.len,
        last.paint_records,
        last.nodes,
        last.width_px,
        last.height_px,
    });
    std.debug.print("| Phase (ms) | p50 | p95 | p99 | max |\n" ++
        "| --- | ---: | ---: | ---: | ---: |\n", .{});
    for (0..phase_count) |phase_index| {
        const phase: Phase = @fromBackingInt(@intCast(phase_index));
        var count: usize = 0;
        for (0..rows.len) |index| {
            const value = phaseMs(rows, index, phase) orelse continue;
            scratch[count] = value;
            count += 1;
        }
        if (count == 0) continue;
        const values = scratch[0..count];
        std.sort.pdq(f64, values, {}, std.sort.asc(f64));
        std.debug.print("| {t} | {d:.3} | {d:.3} | {d:.3} | {d:.3} |\n", .{
            phase,
            percentile(values, 0.50),
            percentile(values, 0.95),
            percentile(values, 0.99),
            values[values.len - 1],
        });
    }
    reportCadence(rows, &scratch, refresh_ms);
    reportHeadroom(rows);
}

/// Present cadence: pack-to-pack intervals of consecutive frames.
fn reportCadence(rows: []const Row, scratch: *[row_count_max]f64, refresh_ms: ?f64) void {
    var count: usize = 0;
    for (rows[1..], rows[0 .. rows.len - 1]) |row, previous| {
        if (previous.frame + 1 != row.frame) continue;
        scratch[count] = ms(row.pack - previous.pack);
        count += 1;
    }
    if (count == 0) return;
    const intervals = scratch[0..count];
    var span_ms: f64 = 0;
    for (intervals) |interval| span_ms += interval;
    std.sort.pdq(f64, intervals, {}, std.sort.asc(f64));
    const period_ms = refresh_ms orelse estimatePeriod(intervals);
    var missed: u64 = 0;
    for (intervals) |interval| {
        const periods = @round(interval / period_ms);
        if (periods > 1) missed += @intFromFloat(periods - 1);
    }
    const seconds = span_ms / 1000;
    std.debug.print("\nPresent cadence: refresh {d:.2} ms ({d:.0} Hz, {s}), interval p50 " ++
        "{d:.2} / " ++
        "p95 {d:.2} / p99 {d:.2} / max {d:.2} ms, {d:.1} frames/s, missed refreshes " ++
        "{d} in {d:.1} s ({d:.1} per 30 s)\n", .{
        period_ms,
        1000 / period_ms,
        if (refresh_ms == null) "estimated" else "given",
        percentile(intervals, 0.50),
        percentile(intervals, 0.95),
        percentile(intervals, 0.99),
        intervals[intervals.len - 1],
        @as(f64, @floatFromInt(count)) / seconds,
        missed,
        seconds,
        @as(f64, @floatFromInt(missed)) * 30 / seconds,
    });
}

/// The refresh period from sorted pack-to-pack intervals (see the file comment).
fn estimatePeriod(sorted: []const f64) f64 {
    assert(sorted.len > 0);
    const median = percentile(sorted, 0.50);
    const low = percentile(sorted, 0.10);
    assert(low <= median);
    if (low < median * 0.75) return snapPeriod(low);
    return snapPeriod(median);
}

fn snapPeriod(measured_ms: f64) f64 {
    assert(measured_ms > 0);
    for (rates_hz) |rate| {
        const period = 1000 / rate;
        if (@abs(measured_ms - period) <= period * 0.08) return period;
    }
    return measured_ms;
}

/// How many frames fit 8.33 ms: on the main thread, on the render thread,
/// and serialized as one frame in flight does today; and how many of the
/// serialized misses moving draw off the main thread's path (design A)
/// would recover.
fn reportHeadroom(rows: []const Row) void {
    var main_fits: u64 = 0;
    var render_fits: u64 = 0;
    var serial_fits: u64 = 0;
    var serial_count: u64 = 0;
    var recovered: u64 = 0;
    for (0..rows.len) |index| {
        const main_ms = phaseMs(rows, index, .main).?;
        const render_ms = phaseMs(rows, index, .render).?;
        if (main_ms <= frame_ms_target) main_fits += 1;
        if (render_ms <= frame_ms_target) render_fits += 1;
        const serial_ms = phaseMs(rows, index, .serial) orelse continue;
        serial_count += 1;
        if (serial_ms <= frame_ms_target) {
            serial_fits += 1;
        } else {
            const draw_ms = phaseMs(rows, index, .draw).?;
            if (serial_ms - draw_ms <= frame_ms_target) recovered += 1;
        }
    }
    const total: f64 = @floatFromInt(rows.len);
    std.debug.print("120 Hz (8.33 ms): main fits {d:.1}%, render fits {d:.1}%, " ++
        "serialized fits {d:.1}% of {d}; overlap (A) would recover {d} of the {d} misses\n", .{
        @as(f64, @floatFromInt(main_fits)) * 100 / total,
        @as(f64, @floatFromInt(render_fits)) * 100 / total,
        if (serial_count > 0) @as(f64, @floatFromInt(serial_fits)) * 100 /
            @as(f64, @floatFromInt(serial_count)) else 0,
        serial_count,
        recovered,
        serial_count - serial_fits,
    });
}

test "percentile picks the nearest rank at both ends" {
    // Goal: p0 and p100 are the extremes, p50 of an odd count the middle.
    const sorted = [_]f64{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(f64, 1), percentile(&sorted, 0));
    try std.testing.expectEqual(@as(f64, 3), percentile(&sorted, 0.5));
    try std.testing.expectEqual(@as(f64, 5), percentile(&sorted, 1));
}

test "parseRow rejects a frame whose stamps run backwards" {
    // Goal: a row with pack before publish is corrupt and must not be averaged.
    try std.testing.expectError(
        error.UnorderedRow,
        parseRow("61,10,11,12,13,14,9,15,16,100,20,800,600"),
    );
    const row = try parseRow("61,10,11,12,13,14,15,16,17,100,20,800,600");
    try std.testing.expectEqual(@as(u64, 61), row.frame);
    try std.testing.expectError(error.TooFewColumns, parseRow("61,10,11"));
}

test "snapPeriod snaps near a display rate and keeps others" {
    // Goal: a 8.4 ms interval is 120 Hz; 23 ms is no listed rate.
    try std.testing.expectApproxEqAbs(1000.0 / 120.0, snapPeriod(8.4), 1e-9);
    try std.testing.expectApproxEqAbs(23.0, snapPeriod(23.0), 1e-9);
}

test "estimatePeriod keeps the median through compositor jitter" {
    // Goal: mutter's 60 Hz callbacks (p10 14.2 ms, p50 16.65 ms) are 60 Hz,
    // not the 72 Hz the 10th percentile snaps to; an app at half of 120 Hz
    // with some on-time frames is still 120 Hz.
    var jitter: [10]f64 = .{ 14.2, 15.0, 16.0, 16.6, 16.6, 16.65, 16.7, 17.0, 18.0, 19.0 };
    try std.testing.expectApproxEqAbs(1000.0 / 60.0, estimatePeriod(&jitter), 1e-9);
    var halved: [10]f64 = .{ 8.3, 8.4, 16.6, 16.6, 16.6, 16.7, 16.7, 16.7, 16.7, 16.8 };
    try std.testing.expectApproxEqAbs(1000.0 / 120.0, estimatePeriod(&halved), 1e-9);
}
