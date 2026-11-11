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
const packed_mod = @import("../core/packed_frame.zig");

const assert = std.debug.assert;

const PackedFrame = packed_mod.PackedFrame;

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

/// A read-only view of a single-channel glyph atlas, `size` pixels square.
pub const GlyphAtlasView = struct {
    pixels: []const u8,
    size: u32,

    /// Coverage at the centre of a glyph's atlas rectangle (left, top, right,
    /// bottom in 0..1).
    fn sample(self: *const GlyphAtlasView, uv: [4]f32) u8 {
        assert(self.size > 0);
        assert(self.pixels.len >= @as(u64, self.size) * self.size);
        const size: f32 = @floatFromInt(self.size);
        const u = (uv[0] + uv[2]) * 0.5;
        const v = (uv[1] + uv[3]) * 0.5;
        assert(u >= 0 and u <= 1);
        assert(v >= 0 and v <= 1);
        const x: u32 = @min(self.size - 1, @as(u32, @intFromFloat(u * size)));
        const y: u32 = @min(self.size - 1, @as(u32, @intFromFloat(v * size)));
        return self.pixels[@as(usize, y) * self.size + x];
    }
};

/// Write every instance of a packed frame in draw order: one line per quad,
/// shadow, SVG, and image, one per glyph run, and one per run of consecutive
/// meshes of one topology.
pub fn writePacked(
    out: *TextBuffer,
    frame: *const PackedFrame,
    atlas: ?*const GlyphAtlasView,
) void {
    assert(frame.clip_count >= 1);
    var glyphs: GlyphRun = .{};
    var meshes: MeshRun = .{};
    for (frame.drawList()) |*draw| {
        const clip = frame.clips[draw.clip];
        if (draw.pipeline != .glyph) glyphs.flush(out);
        if (draw.pipeline != meshes.pipeline) meshes.flush(out);
        switch (draw.pipeline) {
            .quad => for (frame.drawRange(draw, .quad)) |*quad| writeQuad(out, quad, clip),
            .glyph => for (frame.drawRange(draw, .sprite)) |*sprite| {
                glyphs.add(out, sprite, clip, atlas);
            },
            .svg => for (frame.drawRange(draw, .sprite)) |*sprite| writeSvg(out, sprite, clip),
            .image => for (frame.drawRange(draw, .sprite)) |*sprite| {
                writeImage(out, sprite, clip);
            },
            .triangles, .strip_expanded, .point_instanced => meshes.add(draw),
        }
    }
    glyphs.flush(out);
    meshes.flush(out);
}

fn writeQuad(out: *TextBuffer, quad: *const packed_mod.Quad, clip: packed_mod.Rect) void {
    if (quad.blur > 0) {
        // Shadows print without their clip, as goldens recorded them.
        out.print("  shadow {f} blur={d:.2} offset={d:.2},{d:.2} {f}\n", .{
            rect(quad.bounds),
            quad.blur,
            quad.offset[0],
            quad.offset[1],
            Rgba{ .color = quad.fill },
        });
        return;
    }
    out.print("  quad {f} fill={f}", .{ rect(quad.bounds), Rgba{ .color = quad.fill } });
    const borders = quad.border_widths;
    if (borders[0] + borders[1] + borders[2] + borders[3] > 0) {
        out.print(" border={d:.2},{d:.2},{d:.2},{d:.2} {f}", .{
            borders[0],
            borders[1],
            borders[2],
            borders[3],
            Rgba{ .color = quad.border_color },
        });
    }
    const radii = quad.corners;
    if (radii[0] + radii[1] + radii[2] + radii[3] > 0) {
        out.print(" radius={d:.2},{d:.2},{d:.2},{d:.2}", .{
            radii[0],
            radii[1],
            radii[2],
            radii[3],
        });
    }
    writeClip(out, clip);
    out.print("\n", .{});
}

fn writeSvg(out: *TextBuffer, svg: *const packed_mod.Sprite, clip: packed_mod.Rect) void {
    out.print("  svg {f} fill={f} stroke={f}", .{
        rect(svg.bounds),
        Rgba{ .color = svg.tint },
        Rgba{ .color = svg.secondary },
    });
    writeClip(out, clip);
    out.print("\n", .{});
}

fn writeImage(out: *TextBuffer, image: *const packed_mod.Sprite, clip: packed_mod.Rect) void {
    out.print("  image {f} tint={f}", .{ rect(image.bounds), Rgba{ .color = image.tint } });
    writeClip(out, clip);
    out.print("\n", .{});
}

/// Consecutive glyphs folded into runs that share a colour, clip, and top
/// edge; see the file comment. A run ends at any other draw.
const GlyphRun = struct {
    count: u32 = 0,
    first: packed_mod.Sprite = undefined,
    clip: packed_mod.Rect = undefined,
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    hasher: std.hash.Fnv1a_32 = undefined,

    fn add(
        self: *GlyphRun,
        out: *TextBuffer,
        glyph: *const packed_mod.Sprite,
        clip: packed_mod.Rect,
        atlas: ?*const GlyphAtlasView,
    ) void {
        if (self.count > 0 and !self.joins(glyph, clip)) self.flush(out);
        const b = glyph.bounds;
        if (self.count == 0) {
            self.* = .{
                .first = glyph.*,
                .clip = clip,
                .left = b[0],
                .top = b[1],
                .right = b[0] + b[2],
                .bottom = b[1] + b[3],
                .hasher = std.hash.Fnv1a_32.init(),
            };
        }
        self.count += 1;
        self.left = @min(self.left, b[0]);
        self.top = @min(self.top, b[1]);
        self.right = @max(self.right, b[0] + b[2]);
        self.bottom = @max(self.bottom, b[1] + b[3]);
        const quantized = [4]i32{ quantize(b[0]), quantize(b[1]), quantize(b[2]), quantize(b[3]) };
        self.hasher.update(std.mem.asBytes(&quantized));
        if (atlas) |view| self.hasher.update(&.{view.sample(glyph.uv)});
    }

    fn joins(self: *const GlyphRun, next: *const packed_mod.Sprite, clip: packed_mod.Rect) bool {
        assert(self.count > 0);
        if (self.first.bounds[1] != next.bounds[1]) return false;
        if (self.clip[0] != clip[0] or self.clip[1] != clip[1] or self.clip[2] != clip[2]) {
            return false;
        }
        return std.mem.eql(f32, &self.first.tint, &next.tint);
    }

    fn flush(self: *GlyphRun, out: *TextBuffer) void {
        if (self.count == 0) return;
        assert(self.right >= self.left);
        const bounds = Rect{
            .x = self.left,
            .y = self.top,
            .w = self.right - self.left,
            .h = self.bottom - self.top,
        };
        out.print("  glyphs n={d} {f} color={f} hash={x:0>8}", .{
            self.count,
            bounds,
            Rgba{ .color = self.first.tint },
            self.hasher.final(),
        });
        writeClip(out, self.clip);
        out.print("\n", .{});
        self.count = 0;
    }
};

/// Consecutive meshes of one topology print as one count, whatever their
/// clips.
const MeshRun = struct {
    pipeline: ?packed_mod.Pipeline = null,
    count: u32 = 0,

    fn add(self: *MeshRun, draw: *const packed_mod.Draw) void {
        assert(draw.pipeline.kind() == .mesh);
        assert(self.pipeline == null or self.pipeline.? == draw.pipeline);
        self.pipeline = draw.pipeline;
        self.count += draw.count;
    }

    fn flush(self: *MeshRun, out: *TextBuffer) void {
        const pipeline = self.pipeline orelse return;
        const name = switch (pipeline) {
            .triangles => "path",
            .strip_expanded => "polyline",
            .point_instanced => "points",
            else => unreachable,
        };
        out.print("  {s} count={d}\n", .{ name, self.count });
        self.* = .{};
    }
};

fn rect(bounds: packed_mod.Rect) Rect {
    return .{ .x = bounds[0], .y = bounds[1], .w = bounds[2], .h = bounds[3] };
}

/// Hundredths of a pixel, the precision every other field prints at.
fn quantize(value: f32) i32 {
    assert(std.math.isFinite(value));
    return @intFromFloat(@round(value * 100));
}

/// The unbounded clip (`packed.clip_unbounded`) is noise in a golden, so
/// only a real clip prints.
fn writeClip(out: *TextBuffer, clip: packed_mod.Rect) void {
    if (clip[2] >= 99999 or clip[3] >= 99999) return;
    out.print(" clip={f}", .{rect(clip)});
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
    color: packed_mod.Rgba,

    pub fn format(self: Rgba, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const rgba = self.color;
        try writer.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            channel(rgba[0]),
            channel(rgba[1]),
            channel(rgba[2]),
            channel(rgba[3]),
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
        Rgba{ .color = .{ 1, 0, 0, 0.5 } },
    });
    try std.testing.expectEqualStrings("(1.00 2.00 3.50 0.00) #ff000080", out.slice());
}
