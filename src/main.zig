//! Guiz Demo Application
//! Displays a window with a Metal-rendered background

const std = @import("std");
const guiz = @import("guiz");

pub fn main() !void {
    std.debug.print("Starting Guiz...\n", .{});

    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the application
    var app = try guiz.App.init(allocator);
    defer app.deinit();

    // Create a window with custom options
    // DisplayLink is enabled by default for vsync
    const window = try app.createWindow(.{
        .title = "Guiz - GPU UI Framework",
        .width = 1024,
        .height = 768,
        .background_color = guiz.Color.init(0.1, 0.1, 0.15, 1.0),
        // .use_display_link = true, // default
    });
    defer window.deinit();

    std.debug.print("Window created: {s}\n", .{window.title});
    std.debug.print("Size: {d}x{d}\n", .{ window.size.width, window.size.height });

    // Run the application event loop
    // Rendering now happens automatically via CVDisplayLink!
    app.run(null);

    std.debug.print("Guiz shutting down.\n", .{});
}
