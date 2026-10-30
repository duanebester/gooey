//! Synthetic shaper: one glyph per codepoint at the synthetic face's advance.
//!
//! No kerning, ligatures, or fallback fonts, so a run's width is exactly the
//! sum of its advances and goldens can be checked by hand.

const std = @import("std");
const types = @import("../../types.zig");
const SyntheticFace = @import("face.zig").SyntheticFace;

const assert = std.debug.assert;

const ShapedGlyph = types.ShapedGlyph;
const ShapedRun = types.ShapedRun;

pub const SyntheticShaper = struct {
    /// Number of runs shaped, for tests that count shaping work.
    shape_count: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return .{ .shape_count = 0 };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    /// Shape `text` into a glyph slice owned by `allocator`. Invalid UTF-8
    /// bytes shape as glyph 0 one byte at a time, like a missing glyph.
    pub fn shape(
        self: *Self,
        face: *const SyntheticFace,
        text: []const u8,
        allocator: std.mem.Allocator,
    ) !ShapedRun {
        assert(face.metrics.point_size > 0);
        self.shape_count += 1;
        if (text.len == 0) return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };

        const glyphs = try allocator.alloc(ShapedGlyph, codepointCount(text));
        var width: f32 = 0;
        var index: usize = 0;
        var offset: usize = 0;
        while (offset < text.len) : (index += 1) {
            assert(index < glyphs.len);
            const decoded = decode(text[offset..]);
            const glyph_id = face.glyphIndex(decoded.codepoint);
            const advance = face.glyphAdvance(glyph_id);
            glyphs[index] = .{
                .glyph_id = glyph_id,
                .x_offset = 0,
                .y_offset = 0,
                .x_advance = advance,
                .y_advance = 0,
                .cluster = @intCast(offset),
            };
            width += advance;
            offset += decoded.byte_count;
        }
        assert(index == glyphs.len);
        return ShapedRun{ .glyphs = glyphs, .width = width };
    }
};

const Decoded = struct { codepoint: u21, byte_count: u3 };

fn decode(bytes: []const u8) Decoded {
    assert(bytes.len > 0);
    const byte_count = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{
        .codepoint = 0,
        .byte_count = 1,
    };
    if (byte_count > bytes.len) return .{ .codepoint = 0, .byte_count = 1 };
    const codepoint = std.unicode.utf8Decode(bytes[0..byte_count]) catch return .{
        .codepoint = 0,
        .byte_count = 1,
    };
    return .{ .codepoint = codepoint, .byte_count = byte_count };
}

fn codepointCount(text: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) : (count += 1) {
        offset += decode(text[offset..]).byte_count;
    }
    assert(count <= text.len);
    return count;
}

test "synthetic shaping sums advances and keeps clusters" {
    var face = try SyntheticFace.initSystem(.sans_serif, 10, .regular);
    var shaper = SyntheticShaper.init(std.testing.allocator);
    var run = try shaper.shape(&face, "a\u{2212}b", std.testing.allocator);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try std.testing.expectEqual(@as(u32, 4), run.glyphs[2].cluster);
    try std.testing.expectApproxEqAbs(@as(f32, 17), run.width, 0.001);
}
