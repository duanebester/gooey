const std = @import("std");
const gooey = @import("gooey");

pub fn main() !void {
    std.debug.print("Starting gooey with Text...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try gooey.App.init(allocator);
    defer app.deinit();

    var window = try app.createWindow(.{
        .title = "gooey - Text Rendering",
        .width = 800,
        .height = 600,
        .background_color = gooey.Color.init(0.95, 0.95, 0.95, 1.0),
    });
    defer window.deinit();

    window.setInputCallback(onInput);

    // Initialize text system with Retina scale factor
    var text_system = try gooey.TextSystem.initWithScale(allocator, @floatCast(window.scale_factor));
    defer text_system.deinit();

    // Load a font
    try text_system.loadFont("Menlo", 24.0);

    const metrics = text_system.getMetrics().?;
    std.debug.print("Font loaded: ascender={d:.1}, descender={d:.1}, line_height={d:.1}\n", .{
        metrics.ascender,
        metrics.descender,
        metrics.line_height,
    });

    var scene = gooey.Scene.init(allocator);
    defer scene.deinit();

    // Draw a card background
    const card = gooey.Quad.rounded(50, 50, 700, 500, gooey.Hsla.white, 12);
    try scene.insertShadow(gooey.Shadow.forQuad(card, 10).withColor(gooey.Hsla.init(0, 0, 0, 0.2)));
    try scene.insertQuad(card);

    // Render some text
    const text = "Hello, gooey!";
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

            try scene.insertGlyph(gooey.GlyphInstance.init(
                glyph_x,
                glyph_y,
                glyph_w,
                glyph_h,
                uv.u0,
                uv.v0,
                uv.u1,
                uv.v1,
                gooey.Hsla.black,
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

fn onInput(window: *gooey.Window, event: gooey.InputEvent) bool {
    switch (event) {
        .mouse_moved => |m| {
            if (window.scene) |scene| {
                const new_idx = scene.quadIndexAtPoint(
                    @floatCast(m.position.x),
                    @floatCast(m.position.y),
                );

                if (new_idx != window.hovered_quad_index) {
                    if (window.hovered_quad_index != null) {
                        std.debug.print("Mouse left quad\n", .{});
                    }
                    if (new_idx != null) {
                        std.debug.print("Mouse entered quad\n", .{});
                    }
                    window.hovered_quad_index = new_idx;
                }
            }
        },
        .mouse_entered => {
            std.debug.print("Mouse entered window\n", .{});
        },
        .mouse_exited => {
            std.debug.print("Mouse left window\n", .{});
            window.hovered_quad_index = null;
        },
        .mouse_down => |m| {
            std.debug.print("Click at ({d:.0}, {d:.0})\n", .{ m.position.x, m.position.y });

            if (m.click_count == 2) {
                std.debug.print("  Double-click!\n", .{});
            }
            if (m.modifiers.cmd) {
                std.debug.print("  Cmd+click!\n", .{});
            }
            if (m.modifiers.shift) {
                std.debug.print("  Shift+click!\n", .{});
            }
        },
        .scroll => |s| std.debug.print("Scroll delta: ({d:.1}, {d:.1})\n", .{ s.delta.x, s.delta.y }),
        .key_down => |k| {
            std.debug.print("Key down: {s}", .{@tagName(k.key)});

            if (k.characters) |chars| {
                std.debug.print(" chars='{s}'", .{chars});
            }
            if (k.modifiers.cmd) std.debug.print(" [cmd]", .{});
            if (k.modifiers.shift) std.debug.print(" [shift]", .{});
            if (k.modifiers.ctrl) std.debug.print(" [ctrl]", .{});
            if (k.modifiers.alt) std.debug.print(" [alt]", .{});
            if (k.is_repeat) std.debug.print(" (repeat)", .{});
            std.debug.print("\n", .{});

            // Example: Cmd+Q to quit
            if (k.key == .q and k.modifiers.cmd) {
                std.debug.print("Quit requested!\n", .{});
                return true;
            }
        },
        .key_up => |k| {
            std.debug.print("Key up: {s}\n", .{@tagName(k.key)});
        },
        .modifiers_changed => |m| {
            std.debug.print("Modifiers: cmd={} shift={} ctrl={} alt={}\n", .{
                m.cmd, m.shift, m.ctrl, m.alt,
            });
        },
        else => {},
    }
    return false;
}
