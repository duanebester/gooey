const std = @import("std");
const guiz = @import("guiz");

pub fn main() !void {
    std.debug.print("Starting Guiz with Text...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try guiz.App.init(allocator);
    defer app.deinit();

    var window = try app.createWindow(.{
        .title = "Guiz - Text Rendering",
        .width = 800,
        .height = 600,
        .background_color = guiz.Color.init(0.95, 0.95, 0.95, 1.0),
    });
    defer window.deinit();

    // Initialize text system with Retina scale factor
    var text_system = try guiz.TextSystem.initWithScale(allocator, @floatCast(window.scale_factor));
    defer text_system.deinit();

    // Load a font
    try text_system.loadFont("Menlo", 24.0);

    const metrics = text_system.getMetrics().?;
    std.debug.print("Font loaded: ascender={d:.1}, descender={d:.1}, line_height={d:.1}\n", .{
        metrics.ascender,
        metrics.descender,
        metrics.line_height,
    });

    var scene = guiz.Scene.init(allocator);
    defer scene.deinit();

    // Draw a card background
    const card = guiz.Quad.rounded(50, 50, 700, 500, guiz.Hsla.white, 12);
    try scene.insertShadow(guiz.Shadow.forQuad(card, 10).withColor(guiz.Hsla.init(0, 0, 0, 0.2)));
    try scene.insertQuad(card);

    // Render some text
    const text = "Hello, Guiz!";
    var shaped = try text_system.shapeText(text);
    defer shaped.deinit(allocator);

    var pen_x: f32 = 100;
    const pen_y: f32 = 150;
    const scale: f32 = @floatCast(window.scale_factor);

    for (shaped.glyphs) |glyph| {
        const cached = try text_system.getGlyph(glyph.glyph_id);

        if (cached.region.width > 0 and cached.region.height > 0) {
            const atlas = text_system.getAtlas();
            const uv = cached.region.uv(atlas.size);

            // Bearings are in logical units, region size is in physical pixels
            const glyph_x = pen_x + glyph.x_offset + @as(f32, @floatFromInt(cached.bearing_x));
            const glyph_y = pen_y + glyph.y_offset - @as(f32, @floatFromInt(cached.bearing_y));

            // Size: physical pixels / scale = logical size
            const glyph_w = @as(f32, @floatFromInt(cached.region.width)) / scale;
            const glyph_h = @as(f32, @floatFromInt(cached.region.height)) / scale;

            try scene.insertGlyph(guiz.GlyphInstance.init(
                glyph_x,
                glyph_y,
                glyph_w,
                glyph_h,
                uv.u0,
                uv.v0,
                uv.u1,
                uv.v1,
                guiz.Hsla.black,
            ));
        }

        pen_x += glyph.x_advance;
    }

    scene.finish();

    // Set atlas once - renderer auto-syncs to GPU when generation changes
    window.setTextAtlas(text_system.getAtlas());
    window.setScene(&scene);

    std.debug.print("Glyphs: {}, Text width: {d:.1}px\n", .{ scene.glyphCount(), shaped.width });

    app.run(null);
}
