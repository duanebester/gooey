const std = @import("std");
const Scene = @import("../core/scene.zig").Scene;
const GlyphInstance = @import("../core/scene.zig").GlyphInstance;
const TextSystem = @import("text_system.zig").TextSystem;
const Hsla = @import("../core/mod.zig").Hsla;

pub const RenderTextOptions = struct {
    /// Use clipped glyph insertion (respects active clip rect)
    clipped: bool = true,
};

/// Render text at the given position and return the rendered width.
///
/// This is the canonical text rendering function - all elements should use this.
pub fn renderText(
    scene: *Scene,
    text_system: *TextSystem,
    text: []const u8,
    x: f32,
    baseline_y: f32,
    scale_factor: f32,
    color: Hsla,
    options: RenderTextOptions,
) !f32 {
    if (text.len == 0) return 0;

    var shaped = try text_system.shapeText(text);
    defer shaped.deinit(text_system.allocator);
    //std.debug.print("renderText: baseline_y={d:.1}, scale={d:.1}\n", .{ baseline_y, scale_factor });

    var pen_x = x;
    for (shaped.glyphs, 0..) |glyph, i| {
        _ = i;
        const cached = try text_system.getGlyph(glyph.glyph_id);

        if (cached.region.width > 0 and cached.region.height > 0) {
            const atlas = text_system.getAtlas();
            const uv = cached.region.uv(atlas.size);

            const glyph_w = @as(f32, @floatFromInt(cached.region.width)) / scale_factor;
            const glyph_h = @as(f32, @floatFromInt(cached.region.height)) / scale_factor;

            // Pixel-aligned positioning - bearings are in logical pixels
            const glyph_x = @floor(pen_x + glyph.x_offset) + cached.bearing_x;
            const glyph_y = @floor(baseline_y + glyph.y_offset) - cached.bearing_y;

            // const bottom = glyph_y + glyph_h;
            // if (i < 5) {
            //     std.debug.print("  glyph[{}]: glyph_h={d:.1}, glyph_y={d:.1}, bottom={d:.1}\n", .{ i, glyph_h, glyph_y, bottom });
            // }

            const instance = GlyphInstance.init(
                glyph_x,
                glyph_y,
                glyph_w,
                glyph_h,
                uv.u0,
                uv.v0,
                uv.u1,
                uv.v1,
                color,
            );

            if (options.clipped) {
                try scene.insertGlyphClipped(instance);
            } else {
                try scene.insertGlyph(instance);
            }
        }

        pen_x += glyph.x_advance;
    }

    return shaped.width;
}
