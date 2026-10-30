//! Text dumps of packed frames for goldens.
//!
//! A golden is plain text so a reviewer can read a diff: one line per paint
//! primitive in draw order, then hit records and the accessibility tree (see
//! `src/testing/goldens/`). Numbers print with two decimals and colours as
//! 8-bit RGBA, so float noise below 1/200 of a pixel or 1/510 of a channel
//! cannot change a golden, while any visible change does.
//!
//! Glyphs are folded into runs (consecutive glyphs sharing a colour, clip,
//! and top edge). A run prints its glyph count, its union bounds, and a hash
//! of every glyph's position, size, and, when the caller passes the glyph
//! atlas, the coverage at the centre of its atlas region. Atlas UVs are left
//! out: they record where a rasterizer packed a glyph, which is not behaviour
//! a port must keep. The synthetic text backend shades each glyph by its id
//! (`glyphShade`), so the sampled coverage tells "0" from "1" at one position.
//!
//! Storage is one fixed buffer reserved by the owner; writing past it panics
//! with the buffer's name and capacity (CLAUDE.md §2, §4).

const std = @import("std");
const scene_mod = @import("../scene/mod.zig");

const assert = std.debug.assert;

const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;
const BatchIterator = scene_mod.BatchIterator;

/// Fixed-capacity text sink. `bytes` is borrowed storage the owner reserved.
pub const TextBuffer = struct {
    bytes: []u8,
    len: u32,
    name: []const u8,

    pub fn init(bytes: []u8, name: []const u8) TextBuffer {
        assert(bytes.len > 0);
        assert(bytes.len <= std.math.maxInt(u32));
        return .{ .bytes = bytes, .len = 0, .name = name };
    }

    pub fn clear(self: *TextBuffer) void {
        assert(self.len <= self.bytes.len);
        self.len = 0;
    }

    pub fn slice(self: *const TextBuffer) []const u8 {
        assert(self.len <= self.bytes.len);
        return self.bytes[0..self.len];
    }

    pub fn print(self: *TextBuffer, comptime format: []const u8, args: anytype) void {
        assert(self.len <= self.bytes.len);
        const written = std.fmt.bufPrint(self.bytes[self.len..], format, args) catch {
            std.debug.panic("record dump '{s}' exhausted: capacity {d} bytes, {d} used", .{
                self.name,
                self.bytes.len,
                self.len,
            });
        };
        self.len += @intCast(written.len);
        assert(self.len <= self.bytes.len);
    }
};

/// Write every primitive of a finished scene in draw order.
/// A read-only view of a single-channel glyph atlas, `size` pixels square.
pub const GlyphAtlasView = struct {
    pixels: []const u8,
    size: u32,

    /// Coverage at the centre of a glyph's UV rectangle.
    fn sample(self: *const GlyphAtlasView, glyph: *const scene_mod.GlyphInstance) u8 {
        assert(self.size > 0);
        assert(self.pixels.len >= @as(u64, self.size) * self.size);
        const size: f32 = @floatFromInt(self.size);
        const u = (glyph.uv_left + glyph.uv_right) * 0.5;
        const v = (glyph.uv_top + glyph.uv_bottom) * 0.5;
        assert(u >= 0 and u <= 1);
        assert(v >= 0 and v <= 1);
        const x: u32 = @min(self.size - 1, @as(u32, @intFromFloat(u * size)));
        const y: u32 = @min(self.size - 1, @as(u32, @intFromFloat(v * size)));
        return self.pixels[@as(usize, y) * self.size + x];
    }
};

pub fn writeScene(out: *TextBuffer, scene: *const Scene, atlas: ?*const GlyphAtlasView) void {
    assert(scene.viewport_width >= 0);
    var iterator = BatchIterator.init(scene);
    var batch_count: u32 = 0;
    while (iterator.next()) |batch| : (batch_count += 1) {
        assert(batch_count < scene_limit_batches);
        switch (batch) {
            .shadow => |shadows| for (shadows) |*shadow| writeShadow(out, shadow),
            .quad => |quads| for (quads) |*quad| writeQuad(out, quad),
            .glyph => |glyphs| writeGlyphRuns(out, glyphs, atlas),
            .svg => |svgs| for (svgs) |*svg| writeSvg(out, svg),
            .image => |images| for (images) |*image| writeImage(out, image),
            .path => |paths| out.print("  path count={d}\n", .{paths.len}),
            .polyline => |lines| out.print("  polyline count={d}\n", .{lines.len}),
            .point_cloud => |clouds| out.print("  points count={d}\n", .{clouds.len}),
            .colored_point_cloud => |clouds| out.print("  colored_points count={d}\n", .{
                clouds.len,
            }),
        }
    }
}

/// Batches alternate kinds at most once per primitive, so this bounds the
/// loop by the scene's largest possible primitive count.
const scene_limit_batches: u32 = 1 << 20;

fn writeQuad(out: *TextBuffer, quad: *const scene_mod.Quad) void {
    out.print("  quad {f} fill={f}", .{
        Rect{
            .x = quad.bounds_origin_x,
            .y = quad.bounds_origin_y,
            .w = quad.bounds_size_width,
            .h = quad.bounds_size_height,
        },
        Rgba{ .color = quad.background },
    });
    const borders = quad.border_widths;
    if (borders.top + borders.right + borders.bottom + borders.left > 0) {
        out.print(" border={d:.2},{d:.2},{d:.2},{d:.2} {f}", .{
            borders.top,
            borders.right,
            borders.bottom,
            borders.left,
            Rgba{ .color = quad.border_color },
        });
    }
    const radii = quad.corner_radii;
    if (radii.top_left + radii.top_right + radii.bottom_left + radii.bottom_right > 0) {
        out.print(" radius={d:.2},{d:.2},{d:.2},{d:.2}", .{
            radii.top_left,
            radii.top_right,
            radii.bottom_right,
            radii.bottom_left,
        });
    }
    writeClip(out, quad.clip_origin_x, quad.clip_origin_y, quad.clip_size_width, quad.clip_size_height);
    out.print("\n", .{});
}

fn writeShadow(out: *TextBuffer, shadow: *const scene_mod.Shadow) void {
    out.print("  shadow {f} blur={d:.2} offset={d:.2},{d:.2} {f}\n", .{
        Rect{
            .x = shadow.content_origin_x,
            .y = shadow.content_origin_y,
            .w = shadow.content_size_width,
            .h = shadow.content_size_height,
        },
        shadow.blur_radius,
        shadow.offset_x,
        shadow.offset_y,
        Rgba{ .color = shadow.color },
    });
}

fn writeSvg(out: *TextBuffer, svg: *const scene_mod.SvgInstance) void {
    out.print("  svg {f} fill={f} stroke={f}", .{
        Rect{ .x = svg.pos_x, .y = svg.pos_y, .w = svg.size_x, .h = svg.size_y },
        Rgba{ .color = svg.color },
        Rgba{ .color = svg.stroke_color },
    });
    writeClip(out, svg.clip_x, svg.clip_y, svg.clip_width, svg.clip_height);
    out.print("\n", .{});
}

fn writeImage(out: *TextBuffer, image: *const scene_mod.ImageInstance) void {
    out.print("  image {f} tint={f}", .{
        Rect{ .x = image.pos_x, .y = image.pos_y, .w = image.dest_width, .h = image.dest_height },
        Rgba{ .color = image.tint },
    });
    writeClip(out, image.clip_x, image.clip_y, image.clip_width, image.clip_height);
    out.print("\n", .{});
}

/// Fold consecutive glyphs into runs; see the file comment.
fn writeGlyphRuns(
    out: *TextBuffer,
    glyphs: []const scene_mod.GlyphInstance,
    atlas: ?*const GlyphAtlasView,
) void {
    assert(glyphs.len > 0);
    var start: usize = 0;
    while (start < glyphs.len) {
        var end = start + 1;
        while (end < glyphs.len and sameRun(&glyphs[start], &glyphs[end])) end += 1;
        assert(end > start);
        writeGlyphRun(out, glyphs[start..end], atlas);
        start = end;
    }
}

fn sameRun(first: *const scene_mod.GlyphInstance, next: *const scene_mod.GlyphInstance) bool {
    if (first.pos_y != next.pos_y) return false;
    if (first.clip_x != next.clip_x or first.clip_y != next.clip_y) return false;
    if (first.clip_width != next.clip_width) return false;
    return std.meta.eql(first.color, next.color);
}

fn writeGlyphRun(
    out: *TextBuffer,
    run: []const scene_mod.GlyphInstance,
    atlas: ?*const GlyphAtlasView,
) void {
    assert(run.len > 0);
    var hasher = std.hash.Fnv1a_32.init();
    var left: f32 = run[0].pos_x;
    var top: f32 = run[0].pos_y;
    var right: f32 = run[0].pos_x + run[0].size_x;
    var bottom: f32 = run[0].pos_y + run[0].size_y;
    for (run) |*glyph| {
        left = @min(left, glyph.pos_x);
        top = @min(top, glyph.pos_y);
        right = @max(right, glyph.pos_x + glyph.size_x);
        bottom = @max(bottom, glyph.pos_y + glyph.size_y);
        const quantized = [4]i32{
            quantize(glyph.pos_x),
            quantize(glyph.pos_y),
            quantize(glyph.size_x),
            quantize(glyph.size_y),
        };
        hasher.update(std.mem.asBytes(&quantized));
        if (atlas) |view| hasher.update(&.{view.sample(glyph)});
    }
    assert(right >= left);
    out.print("  glyphs n={d} {f} color={f} hash={x:0>8}", .{
        run.len,
        Rect{ .x = left, .y = top, .w = right - left, .h = bottom - top },
        Rgba{ .color = run[0].color },
        hasher.final(),
    });
    writeClip(out, run[0].clip_x, run[0].clip_y, run[0].clip_width, run[0].clip_height);
    out.print("\n", .{});
}

/// Hundredths of a pixel, the precision every other field prints at.
fn quantize(value: f32) i32 {
    assert(std.math.isFinite(value));
    return @intFromFloat(@round(value * 100));
}

/// Primitives default to an unbounded clip (±1e9 or 99999 wide), which is
/// noise in a golden, so only a real clip prints.
fn writeClip(out: *TextBuffer, x: f32, y: f32, w: f32, h: f32) void {
    if (w >= 99999 or h >= 99999) return;
    out.print(" clip={f}", .{Rect{ .x = x, .y = y, .w = w, .h = h }});
}

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn format(self: Rect, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("({d:.2} {d:.2} {d:.2} {d:.2})", .{ self.x, self.y, self.w, self.h });
    }
};

pub const Rgba = struct {
    color: Hsla,

    pub fn format(self: Rgba, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const rgba = self.color.toColor();
        try writer.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            channel(rgba.r),
            channel(rgba.g),
            channel(rgba.b),
            channel(rgba.a),
        });
    }

    fn channel(value: f32) u8 {
        const clamped = std.math.clamp(value, 0, 1);
        return @intFromFloat(@round(clamped * 255));
    }
};

test "TextBuffer formats rects and colours deterministically" {
    var storage: [128]u8 = undefined;
    var out = TextBuffer.init(&storage, "test");
    out.print("{f} {f}", .{
        Rect{ .x = 1, .y = 2.004, .w = 3.5, .h = 0 },
        Rgba{ .color = Hsla.fromRgba(1, 0, 0, 0.5) },
    });
    try std.testing.expectEqualStrings("(1.00 2.00 3.50 0.00) #ff000080", out.slice());
}
