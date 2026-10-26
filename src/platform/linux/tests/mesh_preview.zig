//! Deterministic visual fixture for all mesh topologies, fills, clips, and ordering.
const gooey = @import("gooey");
const ui = gooey.ui;
pub const std_options = gooey.std_options;
const State = struct {};
var state = State{};
const App = gooey.App(State, &state, render, .{
    .title = "Vulkan mesh contract",
    .width = 760,
    .height = 480,
});
pub const main = App.main;
pub const wasm_app = App;
comptime {
    _ = App;
}

fn render(cx: *gooey.Cx) void {
    cx.render(ui.box(.{
        .padding = .{ .all = 24 },
        .gap = 16,
        .direction = .column,
        .background = ui.Color.hex(0x18202c),
    }, .{
        ui.text("Mesh: gradients / strips / points / clipping", .{
            .size = 22,
            .color = ui.Color.white,
        }),
        ui.canvas(700, 370, paint),
    }));
}

fn paint(ctx: *ui.DrawContext) void {
    const red = ui.Color.hex(0xf24b64);
    const blue = ui.Color.hex(0x399dff);
    const green = ui.Color.hex(0x4be0a0);
    var linear = ui.LinearGradient.init(0, 0, 240, 0);
    _ = linear.addStopColor(0, red).addStopColor(0.45, green).addStopColor(1, blue);
    ctx.fillRectLinearGradient(10, 10, 240, 100, &linear);
    // Split path batches so a later gradient must retain its parallel-array index.
    ctx.fillRect(290, 10, 220, 100, ui.Color.hex(0x18202c));
    var radial = ui.RadialGradient.init(80, 50, 90);
    _ = radial.addStopColor(0, ui.Color.white).addStopColor(1, blue);
    ctx.fillRectRadialGradient(290, 10, 220, 100, &radial);
    const line = [_][2]f32{ .{ 10, 170 }, .{ 80, 125 }, .{ 190, 195 }, .{ 290, 140 } };
    ctx.polyline(&line, 7, green);
    ctx.pointCloud(&line, 9, red);
    const points = [_][2]f32{ .{ 360, 155 }, .{ 410, 180 }, .{ 470, 145 } };
    const colors = [_]ui.Color{ red, green, blue };
    ctx.pointCloudColoredArrays(&points, &colors, 16);
    // Interleaving must preserve this opaque quad above the line and markers.
    ctx.fillRect(72, 117, 16, 26, blue);
    var triangle = ctx.beginPath(10, 240);
    _ = triangle.lineTo(250, 240).lineTo(130, 340).closePath();
    ctx.fillPath(&triangle, green);
    // Points and a line cross the right canvas clip.
    const clipped = [_][2]f32{ .{ 688, 260 }, .{ 710, 300 } };
    ctx.pointCloudClipped(&clipped, 25, red);
    ctx.polylineClipped(&.{ .{ 600, 335 }, .{ 740, 335 } }, 9, blue);
}
