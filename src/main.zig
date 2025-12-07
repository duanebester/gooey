//! Guiz Demo - Single Card with Shadow (Debug)

const std = @import("std");
const guiz = @import("guiz");

pub fn main() !void {
    std.debug.print("Starting Guiz...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try guiz.App.init(allocator);
    defer app.deinit();

    var window = try app.createWindow(.{
        .title = "Guiz - Shadow Debug",
        .width = 800,
        .height = 600,
        .background_color = guiz.Color.init(0.9, 0.9, 0.9, 1.0), // Light gray background
    });
    defer window.deinit();

    var scene = guiz.Scene.init(allocator);
    defer scene.deinit();

    // Card: 2/3 of screen, centered
    const card = guiz.Quad.rounded(133, 100, 533, 400, guiz.Hsla.white, 12);

    // Shadow behind it
    try scene.insertShadow(
        guiz.Shadow.drop(133, 100, 533, 400, 15)
            .withCornerRadius(12)
            .withColor(guiz.Hsla.init(0, 0, 0, 0.3))
            .withOffset(0, 0),
    );
    try scene.insertQuad(card);

    scene.finish();
    window.setScene(&scene);

    std.debug.print("Shadows: {}, Quads: {}\n", .{ scene.shadowCount(), scene.quadCount() });

    app.run(null);
}
