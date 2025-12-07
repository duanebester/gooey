const std = @import("std");
const gooey = @import("gooey");

const TextInput = gooey.TextInput;
const input = gooey.input;

// Global state for the demo (in a real app, use proper state management)
var g_username_input: ?*TextInput = null;
var g_password_input: ?*TextInput = null;
var g_text_system: ?*gooey.TextSystem = null;
var g_scale_factor: f32 = 1.0;

pub fn main() !void {
    std.debug.print("Starting gooey with TextInput...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try gooey.App.init(allocator);
    defer app.deinit();

    var window = try app.createWindow(.{
        .title = "gooey - TextInput Demo",
        .width = 800,
        .height = 600,
        .background_color = gooey.Color.init(0.95, 0.95, 0.95, 1.0),
    });
    defer window.deinit();

    window.setInputCallback(onInput);

    // Initialize text system with Retina scale factor
    var text_system = try gooey.TextSystem.initWithScale(allocator, @floatCast(window.scale_factor));
    defer text_system.deinit();
    g_text_system = &text_system;
    g_scale_factor = @floatCast(window.scale_factor);

    // Load a font
    try text_system.loadFont("Menlo", 16.0);

    // Create text inputs
    var username_input = TextInput.init(allocator, .{
        .x = 100,
        .y = 150,
        .width = 300,
        .height = 36,
    });
    defer username_input.deinit();
    username_input.setPlaceholder("Enter username...");
    username_input.focus(); // Start with focus
    g_username_input = &username_input;

    var password_input = TextInput.init(allocator, .{
        .x = 100,
        .y = 200,
        .width = 300,
        .height = 36,
    });
    defer password_input.deinit();
    password_input.setPlaceholder("Enter password...");
    g_password_input = &password_input;

    // Build initial scene
    var scene = gooey.Scene.init(allocator);
    defer scene.deinit();

    try buildScene(&scene, &text_system, @floatCast(window.scale_factor), &username_input, &password_input);

    window.setTextAtlas(text_system.getAtlas());
    window.setScene(&scene);

    std.debug.print("TextInput demo ready. Click to focus, type to enter text.\n", .{});
    std.debug.print("Supports: arrow keys, backspace, delete, Cmd+A (select all), Shift+arrows (selection)\n", .{});
    std.debug.print("IME input (emoji picker, dead keys, CJK) should also work!\n", .{});

    app.run(null);
}

fn buildScene(
    scene: *gooey.Scene,
    text_system: *gooey.TextSystem,
    scale_factor: f32,
    username_input: *TextInput,
    password_input: *TextInput,
) !void {
    scene.clear();

    // Draw a card background
    const card = gooey.Quad.rounded(50, 100, 400, 180, gooey.Hsla.white, 12);
    try scene.insertShadow(gooey.Shadow.forQuad(card, 10).withColor(gooey.Hsla.init(0, 0, 0, 0.15)));
    try scene.insertQuad(card);

    // Render title text
    try renderText(scene, text_system, "Hello, gooey!", 100, 130, scale_factor, gooey.Hsla.init(0, 0, 0.2, 1));

    // Render text inputs
    try username_input.render(scene, text_system, scale_factor);
    try password_input.render(scene, text_system, scale_factor);

    scene.finish();
}

/// Render text at the given baseline position
fn renderText(
    scene: *gooey.Scene,
    text_system: *gooey.TextSystem,
    text: []const u8,
    x: f32,
    baseline_y: f32,
    scale_factor: f32,
    color: gooey.Hsla,
) !void {
    var shaped = try text_system.shapeText(text);
    defer shaped.deinit(text_system.allocator);

    var pen_x = x;
    for (shaped.glyphs) |glyph| {
        const cached = try text_system.getGlyph(glyph.glyph_id);

        if (cached.region.width > 0 and cached.region.height > 0) {
            const atlas = text_system.getAtlas();
            const uv = cached.region.uv(atlas.size);

            const glyph_x = pen_x + glyph.x_offset + cached.bearing_x;
            const glyph_y = baseline_y + glyph.y_offset - cached.bearing_y;
            const glyph_w = @as(f32, @floatFromInt(cached.region.width)) / scale_factor;
            const glyph_h = cached.height;

            try scene.insertGlyph(gooey.GlyphInstance.init(
                glyph_x,
                glyph_y,
                glyph_w,
                glyph_h,
                uv.u0,
                uv.v0,
                uv.u1,
                uv.v1,
                color,
            ));
        }

        pen_x += glyph.x_advance;
    }
}

fn onInput(window: *gooey.Window, event: gooey.InputEvent) bool {
    // Route input to text inputs
    var consumed = false;

    if (g_username_input) |username| {
        if (username.handleInput(event)) {
            consumed = true;
        }
    }

    if (!consumed) {
        if (g_password_input) |password| {
            if (password.handleInput(event)) {
                consumed = true;
            }
        }
    }

    // Rebuild scene after input
    if (consumed) {
        if (g_text_system) |ts| {
            if (g_username_input) |username| {
                if (g_password_input) |password| {
                    if (window.scene) |scene| {
                        const mutable_scene: *gooey.Scene = @constCast(scene);
                        buildScene(mutable_scene, ts, g_scale_factor, username, password) catch {};
                        window.setTextAtlas(ts.getAtlas());
                    }
                }
            }
        }
    }

    // Cmd+Q to quit
    if (event == .key_down) {
        const k = event.key_down;
        if (k.key == .q and k.modifiers.cmd) {
            return true; // Signal quit
        }
    }

    return false;
}
