//! Text shaping - converts text strings into positioned glyphs
//!
//! Provides both a simple shaper (works with any FontFace) and an interface
//! for complex platform-specific shaping (ligatures, kerning, RTL, etc.)

const std = @import("std");
const types = @import("types.zig");
const font_face = @import("font_face.zig");

pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const FontFace = font_face.FontFace;

/// Shaper interface for complex text shaping
/// Platform backends implement this for full Unicode support
pub const Shaper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        /// Full text shaping with ligatures, kerning, etc.
        shape: *const fn (ptr: *anyopaque, face: FontFace, text: []const u8, allocator: std.mem.Allocator) anyerror!ShapedRun,
        /// Release resources
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn shape(self: Shaper, face: FontFace, text: []const u8) !ShapedRun {
        return self.vtable.shape(self.ptr, face, text, self.allocator);
    }

    pub fn deinit(self: *Shaper) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }
};

/// Simple text shaping - works with any FontFace implementation
/// Does not handle ligatures, kerning, or complex scripts
/// Fast path for ASCII and simple Unicode text
pub fn shapeSimple(allocator: std.mem.Allocator, face: FontFace, text: []const u8) !ShapedRun {
    if (text.len == 0) {
        return ShapedRun{
            .glyphs = &[_]ShapedGlyph{},
            .width = 0,
        };
    }

    var glyph_list = std.ArrayList(ShapedGlyph){};
    defer glyph_list.deinit(allocator);

    var total_width: f32 = 0;
    var byte_idx: u32 = 0;

    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const start_byte = byte_idx;
        byte_idx = @intCast(iter.i);

        const glyph_id = face.glyphIndex(cp);
        const metrics = face.glyphMetrics(glyph_id);

        try glyph_list.append(allocator, .{
            .glyph_id = glyph_id,
            .x_offset = 0,
            .y_offset = 0,
            .x_advance = metrics.advance_x,
            .y_advance = 0,
            .cluster = start_byte,
        });

        total_width += metrics.advance_x;
    }

    // Transfer ownership
    const result = try glyph_list.toOwnedSlice(allocator);

    return ShapedRun{
        .glyphs = result,
        .width = total_width,
    };
}

/// Measure text width without full shaping (convenience)
/// Uses glyphAdvance for fast cached lookups instead of full glyphMetrics
pub fn measureSimple(face: FontFace, text: []const u8) f32 {
    var total_width: f32 = 0;

    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const glyph_id = face.glyphIndex(cp);
        total_width += face.glyphAdvance(glyph_id);
    }

    return total_width;
}
