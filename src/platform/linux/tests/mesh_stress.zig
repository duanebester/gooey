//! Reproducible geometry-budget workload: 64 polygons, an 8192-point line and
//! 4096 points of each kind. Alternating small frames exercise ring-buffer reuse.
const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
pub const std_options = gooey.std_options;
const point_count: u32 = 4096;
const line_count: u32 = 8192;
const State = struct {
    frame: u32 = 0,
    points: [point_count][2]f32 = undefined,
    colors: [point_count]ui.Color = undefined,
    line: [line_count][2]f32 = undefined,
};
var state = State{};
const App = gooey.App(State, &state, render, .{
    .title = "Mesh geometry budget stress",
    .width = 760,
    .height = 480,
    .limits = .large,
    .on_init = initialize,
});
pub const main = App.main;

fn initialize(_: *gooey.Cx) void {
    std.debug.assert(state.frame == 0);
    for (&state.points, &state.colors, 0..) |*point, *color, index| {
        point.* = .{ @floatFromInt(index % 128 * 5), @floatFromInt(@divFloor(index, 128) * 4) };
        color.* = if (index % 2 == 0) ui.Color.hex(0x4be0a0) else ui.Color.hex(0xf24b64);
    }
    for (&state.line, 0..) |*point, index| {
        point.* = .{
            @as(f32, @floatFromInt(index)) * 0.08,
            170 + 15 * @sin(@as(f32, @floatFromInt(index)) * 0.02),
        };
    }
}

fn render(cx: *gooey.Cx) void {
    std.debug.assert(state.frame <= 16);
    cx.render(ui.box(.{ .padding = .{ .all = 24 }, .background = ui.Color.hex(0x18202c) }, .{
        ui.canvas(700, 420, paint),
    }));
    if (state.frame < 16) {
        state.frame += 1;
        cx.notify();
    }
}

fn paint(ctx: *ui.DrawContext) void {
    const full = state.frame % 2 == 0;
    const count: usize = if (full) point_count else 1;
    ctx.pointCloud(state.points[0..count], 1.5, ui.Color.hex(0x399dff));
    ctx.pointCloudColoredArrays(state.points[0..count], state.colors[0..count], 0.7);
    ctx.polyline(state.line[0..if (full) line_count else 2], 2, ui.Color.hex(0x4be0a0));
    const paths: u32 = if (full) 64 else 1;
    for (0..paths) |index| {
        const x = 20 + @as(f32, @floatFromInt(index % 16)) * 40;
        const y = 230 + @as(f32, @floatFromInt(@divFloor(index, 16))) * 40;
        var path = ctx.beginPath(x + 14, y);
        for (1..32) |vertex| {
            const angle = @as(f32, @floatFromInt(vertex)) * (2 * std.math.pi / 32.0);
            _ = path.lineTo(x + 14 * @cos(angle), y + 14 * @sin(angle));
        }
        _ = path.closePath();
        ctx.fillPath(&path, ui.Color.hex(0x399dff));
    }
}
