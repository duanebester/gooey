//! Watertightness fixture for analytic path anti-aliasing: donuts drawn the way
//! `charts` draws donut slices (one `fillTriangle` per triangle, two per arc
//! segment) and a pie fan, at fractional centres and radii, on a plain
//! background with no text.
//!
//! Every edge shared by two same-colour triangles must stay watertight: a
//! capture must contain no pixel inside a slice that shows the background.
//! Silhouette corners that slide along a shared edge used to leave such
//! pinholes (isolated background pixels) near the outer arcs.
const std = @import("std");
const assert = std.debug.assert;
const gooey = @import("gooey");
const ui = gooey.ui;
pub const std_options = gooey.std_options;
const State = struct {};
var state = State{};
const App = gooey.App(State, &state, render, .{
    .limits = .standard,
    .title = "Mesh pinholes",
    .width = 480,
    .height = 320,
});
pub const main = App.main;
comptime {
    _ = App;
}

/// Arc segments per full circle, as `charts` uses for pie and donut slices.
const arc_segment_count_circle: u32 = 64;
/// Slices per donut or pie; colours repeat from `palette`.
const slice_count: u32 = 5;
const palette = [_]u32{ 0x399dff, 0x4be0a0, 0xf24b64, 0xffc94b, 0xb57bff };

fn render(cx: *gooey.Cx) void {
    cx.render(ui.box(.{
        .width = 480,
        .height = 320,
        .background = ui.Color.hex(0x18202c),
    }, .{
        ui.canvas(480, 320, paint),
    }));
}

fn paint(ctx: *ui.DrawContext) void {
    // Fractional centres and radii put shared edges at many sub-pixel phases.
    donut(ctx, .{ .center = .{ 82.3, 82.7 }, .radius_outer = 72.4, .radius_inner = 43.1 });
    donut(ctx, .{ .center = .{ 240.5, 80.25 }, .radius_outer = 70, .radius_inner = 52.6 });
    donut(ctx, .{ .center = .{ 397.9, 81.1 }, .radius_outer = 71.3, .radius_inner = 30.2 });
    donut(ctx, .{ .center = .{ 82.6, 238.4 }, .radius_outer = 66.7, .radius_inner = 48.9 });
    donut(ctx, .{ .center = .{ 240.1, 239.6 }, .radius_outer = 73.9, .radius_inner = 61.3 });
    donut(ctx, .{ .center = .{ 397.4, 238.9 }, .radius_outer = 70.8, .radius_inner = 0 });
}

const DonutOptions = struct {
    center: [2]f32,
    radius_outer: f32,
    /// Zero draws a pie: a triangle fan from the centre.
    radius_inner: f32,
};

fn donut(ctx: *ui.DrawContext, options: DonutOptions) void {
    assert(options.radius_outer > options.radius_inner);
    assert(options.radius_inner >= 0);
    const slice_angle = 2.0 * std.math.pi / @as(f32, @floatFromInt(slice_count));
    // A gap of about two logical pixels between slices, as the dashboard draws.
    const pad_outer: f32 = 1.0 / options.radius_outer;
    const pad_inner: f32 = if (options.radius_inner > 0) 1.0 / options.radius_inner else 0;
    var slice: u32 = 0;
    while (slice < slice_count) : (slice += 1) {
        const base = -0.5 * std.math.pi + slice_angle * @as(f32, @floatFromInt(slice));
        const color = ui.Color.hex(palette[slice % palette.len]);
        donut_slice(ctx, &options, .{
            .angle_start_outer = base + pad_outer,
            .angle_end_outer = base + slice_angle - pad_outer,
            .angle_start_inner = base + pad_inner,
            .angle_end_inner = base + slice_angle - pad_inner,
        }, color);
    }
}

const SliceAngles = struct {
    angle_start_outer: f32,
    angle_end_outer: f32,
    angle_start_inner: f32,
    angle_end_inner: f32,
};

/// One slice, triangulated exactly as `charts` `PieChart.drawSlice` does.
fn donut_slice(
    ctx: *ui.DrawContext,
    options: *const DonutOptions,
    angles: SliceAngles,
    color: ui.Color,
) void {
    const span = angles.angle_end_outer - angles.angle_start_outer;
    assert(span > 0);
    assert(span < 2.0 * std.math.pi);
    const circle: f32 = @floatFromInt(arc_segment_count_circle);
    const segment_count: u32 = @max(2, @as(u32, @intFromFloat(
        @ceil(span / (2.0 * std.math.pi) * circle),
    )));
    assert(segment_count <= arc_segment_count_circle);
    const count: f32 = @floatFromInt(segment_count);
    const step_outer = span / count;
    const step_inner = (angles.angle_end_inner - angles.angle_start_inner) / count;
    const x = options.center[0];
    const y = options.center[1];
    const r_outer = options.radius_outer;
    const r_inner = options.radius_inner;
    var segment: u32 = 0;
    while (segment < segment_count) : (segment += 1) {
        const index_a: f32 = @floatFromInt(segment);
        const index_b: f32 = @floatFromInt(segment + 1);
        const outer_a = angles.angle_start_outer + index_a * step_outer;
        const outer_b = angles.angle_start_outer + index_b * step_outer;
        const outer_ax = x + r_outer * @cos(outer_a);
        const outer_ay = y + r_outer * @sin(outer_a);
        const outer_bx = x + r_outer * @cos(outer_b);
        const outer_by = y + r_outer * @sin(outer_b);
        if (r_inner > 0) {
            const inner_a = angles.angle_start_inner + index_a * step_inner;
            const inner_b = angles.angle_start_inner + index_b * step_inner;
            const inner_ax = x + r_inner * @cos(inner_a);
            const inner_ay = y + r_inner * @sin(inner_a);
            const inner_bx = x + r_inner * @cos(inner_b);
            const inner_by = y + r_inner * @sin(inner_b);
            ctx.fillTriangle(inner_ax, inner_ay, outer_ax, outer_ay, outer_bx, outer_by, color);
            ctx.fillTriangle(inner_ax, inner_ay, outer_bx, outer_by, inner_bx, inner_by, color);
        } else {
            ctx.fillTriangle(x, y, outer_ax, outer_ay, outer_bx, outer_by, color);
        }
    }
}
