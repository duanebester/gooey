//! Web text shaper implementation
//!
//! Uses JavaScript Canvas2D APIs for text measurement with kerning support.
//! Falls back gracefully when advanced metrics aren't available.

const std = @import("std");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");
const shaper_mod = @import("../../shaper.zig");
const WebFontFace = @import("face.zig").WebFontFace;

const ShapedGlyph = types.ShapedGlyph;
const ShapedRun = types.ShapedRun;
const FontFace = font_face_mod.FontFace;
const Shaper = shaper_mod.Shaper;

// JS imports for text measurement
extern "env" fn measureText(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    text_ptr: [*]const u8,
    text_len: u32,
) f32;

/// Web-backed text shaper using Canvas2D for kerning detection
pub const WebShaper = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    /// Get as the generic Shaper interface
    pub fn asShaper(self: *Self) Shaper {
        const gen = struct {
            fn shapeFn(ptr: *anyopaque, face: FontFace, text: []const u8, allocator: std.mem.Allocator) anyerror!ShapedRun {
                const shaper: *Self = @ptrCast(@alignCast(ptr));
                const web_face: *WebFontFace = @ptrCast(@alignCast(face.ptr));
                return shaper.shape(web_face, text, allocator);
            }

            fn deinitFn(ptr: *anyopaque) void {
                const shaper: *Self = @ptrCast(@alignCast(ptr));
                shaper.deinit();
            }

            const vtable = Shaper.VTable{
                .shape = shapeFn,
                .deinit = deinitFn,
            };
        };

        return .{
            .ptr = self,
            .vtable = &gen.vtable,
            .allocator = self.allocator,
        };
    }

    /// Shape text using Canvas2D measurements for kerning
    pub fn shape(self: *Self, face: *const WebFontFace, text: []const u8, allocator: std.mem.Allocator) !ShapedRun {
        _ = self;
        if (text.len == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        const font_name = face.font_name_buf[0..face.font_name_len];
        const font_size = face.metrics.point_size;

        // Collect codepoints and byte positions
        var codepoints = std.ArrayList(u21){};
        defer codepoints.deinit(allocator);
        var byte_positions = std.ArrayList(u32){};
        defer byte_positions.deinit(allocator);

        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        var byte_idx: u32 = 0;
        while (iter.nextCodepoint()) |cp| {
            try codepoints.append(allocator, cp);
            try byte_positions.append(allocator, byte_idx);
            byte_idx = @intCast(iter.i);
        }

        const n = codepoints.items.len;
        if (n == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        var glyph_buffer = std.ArrayList(ShapedGlyph){};
        defer glyph_buffer.deinit(allocator);

        var char_buf: [4]u8 = undefined;
        var pair_buf: [8]u8 = undefined;
        var prev_width: f32 = 0;

        for (0..n) |i| {
            const cp = codepoints.items[i];
            const cluster = byte_positions.items[i];
            const char_len = std.unicode.utf8Encode(cp, &char_buf) catch continue;

            const char_width = measureText(
                font_name.ptr,
                @intCast(font_name.len),
                font_size,
                &char_buf,
                @intCast(char_len),
            );

            // Detect kerning by comparing pair width vs sum of individuals
            // Apply kerning to previous glyph's advance (like CoreText does)
            if (i > 0) {
                const prev_cp = codepoints.items[i - 1];
                const prev_len = std.unicode.utf8Encode(prev_cp, &pair_buf) catch 0;
                const curr_len = std.unicode.utf8Encode(cp, pair_buf[prev_len..]) catch 0;

                if (prev_len + curr_len > 0) {
                    const pair_width = measureText(
                        font_name.ptr,
                        @intCast(font_name.len),
                        font_size,
                        &pair_buf,
                        @intCast(prev_len + curr_len),
                    );
                    const kerning = pair_width - (prev_width + char_width);
                    if (@abs(kerning) > 0.1) {
                        // Adjust previous glyph's advance to include kerning
                        glyph_buffer.items[i - 1].x_advance += kerning;
                    }
                }
            }

            try glyph_buffer.append(allocator, .{
                .glyph_id = @truncate(cp),
                .x_offset = 0,
                .y_offset = 0,
                .x_advance = char_width,
                .y_advance = 0,
                .cluster = cluster,
                .font_ref = null,
                .is_color = isLikelyEmoji(cp),
            });

            prev_width = char_width;
        }

        const result = try glyph_buffer.toOwnedSlice(allocator);

        // Use full string measurement as authoritative width (captures ligatures)
        const total = measureText(font_name.ptr, @intCast(font_name.len), font_size, text.ptr, @intCast(text.len));

        return ShapedRun{ .glyphs = result, .width = total };
    }
};

fn isLikelyEmoji(cp: u21) bool {
    return (cp >= 0x1F300 and cp <= 0x1F9FF) or
        (cp >= 0x2600 and cp <= 0x26FF) or
        (cp >= 0x2700 and cp <= 0x27BF) or
        (cp >= 0x1F600 and cp <= 0x1F64F) or
        (cp >= 0x1F680 and cp <= 0x1F6FF);
}
