//! Text shaper using CoreText for macOS
//!
//! Converts text strings into positioned glyphs, handling:
//! - Unicode normalization
//! - Ligatures (fi, fl, etc.)
//! - Kerning
//! - Complex scripts (Arabic, Devanagari, etc.)

const std = @import("std");
const ct = @import("coretext.zig");
const Face = @import("face.zig").Face;

/// A shaped glyph with positioning information
pub const ShapedGlyph = struct {
    /// Glyph ID in the font
    glyph_id: u16,
    /// Horizontal offset from pen position
    x_offset: f32,
    /// Vertical offset from baseline
    y_offset: f32,
    /// Horizontal advance for next glyph
    x_advance: f32,
    /// Vertical advance (usually 0)
    y_advance: f32,
    /// Index into original text (byte offset)
    cluster: u32,
};

/// Result of shaping a text run
pub const ShapedRun = struct {
    glyphs: []ShapedGlyph,
    /// Total advance width
    width: f32,

    pub fn deinit(self: *ShapedRun, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        self.* = undefined;
    }
};

/// Text shaper
pub const Shaper = struct {
    allocator: std.mem.Allocator,
    /// Reusable buffers
    utf16_buffer: std.ArrayList(ct.UniChar),
    glyph_buffer: std.ArrayList(ShapedGlyph),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .utf16_buffer = std.ArrayList(ct.UniChar){},
            .glyph_buffer = std.ArrayList(ShapedGlyph){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.utf16_buffer.deinit(self.allocator);
        self.glyph_buffer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Shape a text string using CoreText
    pub fn shape(self: *Self, face: *const Face, text: []const u8) !ShapedRun {
        if (text.len == 0) {
            return ShapedRun{
                .glyphs = &[_]ShapedGlyph{},
                .width = 0,
            };
        }

        // Convert UTF-8 to UTF-16 for CoreText
        self.utf16_buffer.clearRetainingCapacity();
        var cluster_map = std.ArrayList(u32).init(self.allocator);
        defer cluster_map.deinit();

        var byte_idx: u32 = 0;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            const start_byte = byte_idx;
            byte_idx = @intCast(iter.i);

            if (cp <= 0xFFFF) {
                try self.utf16_buffer.append(self.allocator, @intCast(cp));
                try cluster_map.append(self.allocator, start_byte);
            } else {
                // Surrogate pair
                const adjusted = cp - 0x10000;
                try self.utf16_buffer.append(self.allocator, @intCast(0xD800 + (adjusted >> 10)));
                try self.utf16_buffer.append(self.allocator, @intCast(0xDC00 + (adjusted & 0x3FF)));
                try cluster_map.append(self.allocator, start_byte);
                try cluster_map.append(self.allocator, start_byte);
            }
        }

        const utf16_len = self.utf16_buffer.items.len;
        if (utf16_len == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        // Create CFString from UTF-16
        const cf_string = blk: {
            const NSString = @import("objc").getClass("NSString") orelse return error.ClassNotFound;
            const ns_string = NSString.msgSend(
                @import("objc").Object,
                "alloc",
                .{},
            ).msgSend(
                @import("objc").Object,
                "initWithCharacters:length:",
                .{ self.utf16_buffer.items.ptr, utf16_len },
            );
            break :blk @as(ct.CFStringRef, @ptrCast(ns_string.value));
        };
        defer ct.release(cf_string);

        // Create attributed string with font
        const attrs = ct.CFDictionaryCreateMutable(null, 1, &ct.kCFTypeDictionaryKeyCallBacks, &ct.kCFTypeDictionaryValueCallBacks) orelse
            return error.AllocationFailed;
        defer ct.release(attrs);

        ct.CFDictionarySetValue(attrs, @ptrCast(ct.kCTFontAttributeName), @ptrCast(face.ct_font));

        const attr_string = ct.CFAttributedStringCreate(null, cf_string, @ptrCast(attrs)) orelse
            return error.AllocationFailed;
        defer ct.release(attr_string);

        // Create CTLine for shaping
        const line = ct.CTLineCreateWithAttributedString(attr_string) orelse
            return error.ShapingFailed;
        defer ct.release(line);

        // Get glyph runs
        const runs = ct.CTLineGetGlyphRuns(line);
        const run_count = ct.CFArrayGetCount(runs);

        self.glyph_buffer.clearRetainingCapacity();
        var total_width: f32 = 0;

        var run_idx: ct.CFIndex = 0;
        while (run_idx < run_count) : (run_idx += 1) {
            const run: ct.CTRunRef = @ptrCast(@constCast(ct.CFArrayGetValueAtIndex(runs, run_idx)));
            const glyph_count = ct.CTRunGetGlyphCount(run);

            if (glyph_count == 0) continue;

            // Get glyphs, positions, and advances
            const glyphs = try self.allocator.alloc(ct.CGGlyph, @intCast(glyph_count));
            defer self.allocator.free(glyphs);

            const positions = try self.allocator.alloc(ct.CGPoint, @intCast(glyph_count));
            defer self.allocator.free(positions);

            const advances = try self.allocator.alloc(ct.CGSize, @intCast(glyph_count));
            defer self.allocator.free(advances);

            const indices = try self.allocator.alloc(ct.CFIndex, @intCast(glyph_count));
            defer self.allocator.free(indices);

            const range = ct.CFRange.init(0, glyph_count);
            ct.CTRunGetGlyphs(run, range, glyphs.ptr);
            ct.CTRunGetPositions(run, range, positions.ptr);
            ct.CTRunGetAdvances(run, range, advances.ptr);
            ct.CTRunGetStringIndices(run, range, indices.ptr);

            // Convert to ShapedGlyph
            for (0..@intCast(glyph_count)) |i| {
                const cluster = if (indices[i] >= 0 and indices[i] < cluster_map.items.len)
                    cluster_map.items[@intCast(indices[i])]
                else
                    0;

                try self.glyph_buffer.append(self.allocator, .{
                    .glyph_id = glyphs[i],
                    .x_offset = @floatCast(positions[i].x),
                    .y_offset = @floatCast(positions[i].y),
                    .x_advance = @floatCast(advances[i].width),
                    .y_advance = @floatCast(advances[i].height),
                    .cluster = cluster,
                });

                total_width += @floatCast(advances[i].width);
            }
        }

        // Copy results
        const result = try self.allocator.alloc(ShapedGlyph, self.glyph_buffer.items.len);
        @memcpy(result, self.glyph_buffer.items);

        return ShapedRun{
            .glyphs = result,
            .width = total_width,
        };
    }

    /// Simple shape without full CoreText pipeline (faster for ASCII)
    pub fn shapeSimple(self: *Self, face: *const Face, text: []const u8) !ShapedRun {
        // Allocate a fresh buffer for this call to avoid race conditions
        var glyph_list = std.ArrayList(ShapedGlyph){};
        defer glyph_list.deinit(self.allocator);

        var total_width: f32 = 0;
        var byte_idx: u32 = 0;

        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            const start_byte = byte_idx;
            byte_idx = @intCast(iter.i);

            const glyph_id = face.glyphIndex(cp);
            const metrics = face.glyphMetrics(glyph_id);

            try glyph_list.append(self.allocator, .{
                .glyph_id = glyph_id,
                .x_offset = 0,
                .y_offset = 0,
                .x_advance = metrics.advance_x,
                .y_advance = 0,
                .cluster = start_byte,
            });

            total_width += metrics.advance_x;
        }

        // Transfer ownership of the backing array to the result
        const result = try glyph_list.toOwnedSlice(self.allocator);

        return ShapedRun{
            .glyphs = result,
            .width = total_width,
        };
    }
};
