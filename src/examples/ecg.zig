//! ECG: a sweep-style monitor trace, for embedded panels.
//!
//! A synthetic ECG redrawn every frame as one polyline, a heart-rate readout
//! that the buttons change from 30 to 180 BPM, and a sweep that erases ahead
//! of itself like a bedside monitor. Written for the EVE backend
//! (`-Dlinux-backend=eve`), where the trace is one `LINE_STRIP`; it runs on
//! every backend.
//!
//! The trace is a function of the frame clock (`cx.now`), not a sample
//! buffer, so render keeps no history: the sample at column `x` is the
//! signal at the time the sweep last passed `x`. The signal is a sum of
//! Gaussian P, Q, R, S, and T waves with fixed widths (QRS about 80 ms).
//!
//! Resource sketch: one polyline of at most `trace_point_count_max` points
//! per frame (two pieces either side of the erase gap), within the embedded
//! profile's 1,024 polyline points; grid lines are about 46 quads.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Painter = gooey.Painter;
const Button = components.Button;

const assert = std.debug.assert;

pub const State = struct {
    heart_rate_bpm: u32 = 72,
    /// The frame clock of the build being painted, in nanoseconds. Render
    /// stamps it so the paint function, which has no `Cx`, sees the same time.
    frame_ns: u64 = 0,

    pub fn faster(self: *State) void {
        assert(self.heart_rate_bpm >= heart_rate_bpm_min);
        self.heart_rate_bpm = @min(self.heart_rate_bpm + 10, heart_rate_bpm_max);
    }

    pub fn slower(self: *State) void {
        assert(self.heart_rate_bpm <= heart_rate_bpm_max);
        self.heart_rate_bpm = @max(self.heart_rate_bpm - 10, heart_rate_bpm_min);
    }
};

pub const App = gooey.App(State, render, .{
    .title = "ECG",
    .width = 1024,
    .height = 600,
    .limits = .embedded,
});

/// The generated entry point (contract §7).
pub const main = App.main;

const heart_rate_bpm_min: u32 = 30;
const heart_rate_bpm_max: u32 = 180;
/// Standard paper speed, 25 mm/s, on a 7" 1024 px panel (about 6.6 px/mm).
const sweep_px_per_second: f32 = 166;
/// Pixels between trace samples. Two keep the trace under 512 vertices.
const sample_spacing_px: f32 = 2;
/// Width blanked ahead of the sweep, like a monitor's erase bar.
const erase_gap_px: f32 = 24;
const trace_point_count_max: usize = 1024;
const grid_px: f32 = 33; // 5 mm.
/// Pixels per millivolt: 10 mm/mV.
const px_per_millivolt: f32 = 66;

const background = ui.Color.rgb(0.04, 0.06, 0.05);
const grid_color = ui.Color.rgb(0.10, 0.22, 0.14);
const trace_color = ui.Color.rgb(0.30, 1.0, 0.45);
const label_color = ui.Color.rgb(0.75, 0.85, 0.78);

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    s.frame_ns = cx.now();
    // The trace follows the clock, so every frame renders.
    cx.requestRenderAfter(0);
    var digits: [16]u8 = undefined;
    const rate = std.fmt.bufPrint(&digits, "{d} BPM", .{s.heart_rate_bpm}) catch unreachable;
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(16),
        .gap = 12,
        .background = .{ .rgba = background },
    } }, .{
        ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .direction = .row,
            .gap = 16,
            .alignment = .center_cross,
        } }, .{
            ui.text("ECG  Lead II", .{ .size = 24, .color = .{ .rgba = label_color } }),
            ui.text(rate, .{ .size = 32, .color = .{ .rgba = trace_color } }),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
            Button{ .label = "Slower", .size = .large, .on_click = cx.on(State.slower, .{}) },
            Button{ .label = "Faster", .size = .large, .on_click = cx.on(State.faster, .{}) },
        }),
        ui.paint(State, s, paintTrace, .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } }),
    }));
}

fn paintTrace(s: *const State, painter: *Painter) void {
    const bounds = painter.bounds;
    assert(bounds.width >= 0);
    assert(s.heart_rate_bpm >= heart_rate_bpm_min);
    paintGrid(painter);
    const column_count: usize = @intFromFloat(@floor(bounds.width / sample_spacing_px));
    if (column_count < 2) return;
    assert(column_count <= trace_point_count_max);
    const seconds = @as(f64, @floatFromInt(s.frame_ns)) / std.time.ns_per_s;
    const sweep_seconds = bounds.width / sweep_px_per_second;
    const head_px: f32 = @floatCast(@mod(seconds, sweep_seconds) * sweep_px_per_second);
    var points: [trace_point_count_max][2]f32 = undefined;
    var count: usize = 0;
    for (0..column_count) |column| {
        const x = @as(f32, @floatFromInt(column)) * sample_spacing_px;
        const ahead = x - head_px;
        if (ahead > 0 and ahead < erase_gap_px) {
            // The erase gap ends the piece before it.
            if (count >= 2) painter.polyline(points[0..count], 2, trace_color);
            count = 0;
            continue;
        }
        const age = if (ahead <= 0) -ahead else bounds.width - ahead;
        const sample_seconds = seconds - age / sweep_px_per_second;
        const millivolts = signalMillivolts(sample_seconds, s.heart_rate_bpm);
        const middle = bounds.y + bounds.height * 0.55;
        points[count] = .{ bounds.x + x, middle - millivolts * px_per_millivolt };
        count += 1;
    }
    if (count >= 2) painter.polyline(points[0..count], 2, trace_color);
}

/// Grid lines every 5 mm, as on ECG paper.
fn paintGrid(painter: *Painter) void {
    const bounds = painter.bounds;
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    const line_count_max: u32 = 64;
    var line_index: u32 = 0;
    while (line_index < line_count_max) : (line_index += 1) {
        const offset = @as(f32, @floatFromInt(line_index)) * grid_px;
        if (offset > bounds.width) break;
        const line_box: @TypeOf(bounds) = .{
            .x = bounds.x + offset,
            .y = bounds.y,
            .width = 1,
            .height = bounds.height,
        };
        painter.fill(line_box, grid_color);
    }
    line_index = 0;
    while (line_index < line_count_max) : (line_index += 1) {
        const offset = @as(f32, @floatFromInt(line_index)) * grid_px;
        if (offset > bounds.height) break;
        const line_box: @TypeOf(bounds) = .{
            .x = bounds.x,
            .y = bounds.y + offset,
            .width = bounds.width,
            .height = 1,
        };
        painter.fill(line_box, grid_color);
    }
}

/// R peak time after the beat starts, at rates up to 75 BPM.
const r_wave_seconds: f32 = 0.22;

/// Millivolts at `seconds` for a steady rhythm of `heart_rate_bpm`.
/// Wave positions shrink at fast rates (the PR and QT intervals shorten), so
/// the T wave ends before the next beat; wave widths do not.
fn signalMillivolts(seconds: f64, heart_rate_bpm: u32) f32 {
    assert(heart_rate_bpm >= heart_rate_bpm_min);
    assert(heart_rate_bpm <= heart_rate_bpm_max);
    const period = 60 / @as(f64, @floatFromInt(heart_rate_bpm));
    const in_beat: f32 = @floatCast(@mod(seconds, period));
    const scale: f32 = @floatCast(@min(1, period / 0.8));
    // Center (s, at 75 BPM), amplitude (mV), and width (s) of each wave.
    const waves = [_][3]f32{
        .{ 0.10, 0.15, 0.022 }, // P.
        .{ 0.20, -0.12, 0.008 }, // Q.
        .{ r_wave_seconds, 1.20, 0.009 }, // R.
        .{ 0.24, -0.25, 0.009 }, // S.
        .{ 0.44, 0.30, 0.040 }, // T.
    };
    var value: f32 = 0;
    for (waves) |wave| {
        const distance = (in_beat - wave[0] * scale) / wave[2];
        value += wave[1] * @exp(-0.5 * distance * distance);
    }
    assert(!std.math.isNan(value));
    return value;
}

test "the R wave peaks near 1.2 mV and the baseline stays near zero" {
    // Goal: the synthetic signal has its R peak where the sweep expects it, at
    // the top of the 30 to 180 BPM range as well. Methodology: sample at the R
    // centre and mid-diastole at both ends of the range.
    for ([_]u32{ heart_rate_bpm_min, heart_rate_bpm_max }) |bpm| {
        const period = 60 / @as(f64, @floatFromInt(bpm));
        const scale = @min(1, period / 0.8);
        const peak = signalMillivolts(r_wave_seconds * scale, bpm);
        try std.testing.expect(peak > 1.0);
        try std.testing.expect(peak < 1.3);
    }
    const baseline = signalMillivolts(0.7, 60);
    try std.testing.expect(@abs(baseline) < 0.05);
}
