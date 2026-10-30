//! Pack: paint records to renderer input (contract §8).
//!
//! Until the four-kind Scene lands in phase 5, pack targets the 0.3.1
//! `Scene`, so every existing renderer draws core frames unchanged. This is
//! the permanent boundary between emit and the renderers; only its output
//! type changes later. One pass over the records, one scene insert each.

const std = @import("std");
const records = @import("records.zig");
const scene_mod = @import("../scene/mod.zig");

const assert = std.debug.assert;

const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;

pub fn pack(frame: *const records.Frame, scene: *Scene) void {
    assert(frame.paint_count <= frame.paint.len);
    scene.clear();
    scene.viewport_width = frame.viewport_width;
    scene.viewport_height = frame.viewport_height;
    var clip_depth: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |*record| {
        switch (record.*) {
            .quad => |*quad| packQuad(scene, quad),
            .sprite => |*sprite| packSprite(scene, sprite),
            .mesh => std.debug.panic("mesh records are packed from phase 5", .{}),
            .clip_push => |bounds| {
                clip_depth += 1;
                scene.pushClip(.{
                    .x = bounds.x,
                    .y = bounds.y,
                    .width = bounds.width,
                    .height = bounds.height,
                }) catch |err| packFailed(frame, err);
            },
            .clip_pop => {
                assert(clip_depth > 0);
                clip_depth -= 1;
                scene.popClip();
            },
        }
    }
    assert(clip_depth == 0);
    scene.finish();
}

fn packQuad(scene: *Scene, quad: *const records.Quad) void {
    const corners = scene_mod.Corners{
        .top_left = quad.corners.top_left,
        .top_right = quad.corners.top_right,
        .bottom_right = quad.corners.bottom_right,
        .bottom_left = quad.corners.bottom_left,
    };
    if (quad.blur > 0) {
        scene.insertShadow(.{
            .content_origin_x = quad.bounds.x,
            .content_origin_y = quad.bounds.y,
            .content_size_width = quad.bounds.width,
            .content_size_height = quad.bounds.height,
            .blur_radius = quad.blur,
            .color = Hsla.fromColor(quad.fill),
            .offset_x = quad.offset_x,
            .offset_y = quad.offset_y,
            .corner_radii = corners,
        }) catch |err| std.debug.panic("pack: {s}", .{@errorName(err)});
        return;
    }
    const width = quad.border.width;
    const packed_quad = scene_mod.Quad{
        .bounds_origin_x = quad.bounds.x,
        .bounds_origin_y = quad.bounds.y,
        .bounds_size_width = quad.bounds.width,
        .bounds_size_height = quad.bounds.height,
        .background = Hsla.fromColor(quad.fill),
        .border_color = Hsla.fromColor(quad.border.color),
        .corner_radii = corners,
        .border_widths = .{ .top = width, .right = width, .bottom = width, .left = width },
    };
    const inserted = if (scene.hasActiveClip())
        scene.insertQuadClipped(packed_quad)
    else
        scene.insertQuad(packed_quad);
    inserted catch |err| std.debug.panic("pack: {s}", .{@errorName(err)});
}

fn packSprite(scene: *Scene, sprite: *const records.Sprite) void {
    const b = sprite.bounds;
    const uv = sprite.uv;
    switch (sprite.atlas) {
        .glyph => {
            const glyph = scene_mod.GlyphInstance.init(
                b.x,
                b.y,
                b.width,
                b.height,
                uv.x,
                uv.y,
                uv.x + uv.width,
                uv.y + uv.height,
                Hsla.fromColor(sprite.tint),
            );
            const inserted = if (scene.hasActiveClip())
                scene.insertGlyphClipped(glyph)
            else
                scene.insertGlyph(glyph);
            inserted catch |err| std.debug.panic("pack: {s}", .{@errorName(err)});
        },
        .svg => {
            const instance = scene_mod.SvgInstance.init(
                b.x,
                b.y,
                b.width,
                b.height,
                uv.x,
                uv.y,
                uv.x + uv.width,
                uv.y + uv.height,
                Hsla.fromColor(sprite.tint),
                Hsla.fromColor(sprite.secondary),
            );
            scene.insertSvgClipped(instance) catch |err| std.debug.panic("pack: {s}", .{
                @errorName(err),
            });
        },
        .glyph_color, .image => std.debug.panic("{t} sprites are packed from phase 4", .{
            sprite.atlas,
        }),
    }
}

fn packFailed(frame: *const records.Frame, err: anyerror) noreturn {
    std.debug.panic("pack failed in frame {d}: {s}", .{ frame.frame_number, @errorName(err) });
}
