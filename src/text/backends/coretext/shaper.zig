//! CoreText text shaper implementation
//!
//! Provides full Unicode text shaping using Apple's CoreText framework,
//! including support for ligatures, kerning, and complex scripts.

const std = @import("std");
const ct = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");
const shaper_mod = @import("../../shaper.zig");
const CoreTextFace = @import("face.zig").CoreTextFace;

const ShapedGlyph = types.ShapedGlyph;
const ShapedRun = types.ShapedRun;
const FontFace = font_face_mod.FontFace;
const Shaper = shaper_mod.Shaper;

/// CoreText-backed text shaper
pub const CoreTextShaper = struct {
    allocator: std.mem.Allocator,
    /// Reusable UTF-16 buffer
    utf16_buffer: std.ArrayList(ct.UniChar),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .utf16_buffer = std.ArrayList(ct.UniChar){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.utf16_buffer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Get as the generic Shaper interface
    /// Note: Requires a CoreTextFace, not a generic FontFace
    pub fn asShaper(self: *Self) Shaper {
        const gen = struct {
            fn shapeFn(ptr: *anyopaque, face: FontFace, text: []const u8, allocator: std.mem.Allocator) anyerror!ShapedRun {
                const shaper: *Self = @ptrCast(@alignCast(ptr));
                // For complex shaping, we need the underlying CoreText font
                // This cast is safe because CoreTextShaper only works with CoreTextFace
                const ct_face: *CoreTextFace = @ptrCast(@alignCast(face.ptr));
                return shaper.shape(ct_face, text, allocator);
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

    /// Full text shaping using CoreText
    pub fn shape(self: *Self, face: *const CoreTextFace, text: []const u8, allocator: std.mem.Allocator) !ShapedRun {
        if (text.len == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        // Convert UTF-8 to UTF-16
        self.utf16_buffer.clearRetainingCapacity();
        var cluster_map = std.ArrayList(u32){};
        defer cluster_map.deinit(allocator);

        var byte_idx: u32 = 0;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            const start_byte = byte_idx;
            byte_idx = @intCast(iter.i);

            if (cp <= 0xFFFF) {
                try self.utf16_buffer.append(self.allocator, @intCast(cp));
                try cluster_map.append(allocator, start_byte);
            } else {
                const adjusted = cp - 0x10000;
                try self.utf16_buffer.append(self.allocator, @intCast(0xD800 + (adjusted >> 10)));
                try self.utf16_buffer.append(self.allocator, @intCast(0xDC00 + (adjusted & 0x3FF)));
                try cluster_map.append(allocator, start_byte);
                try cluster_map.append(allocator, start_byte);
            }
        }

        const utf16_len = self.utf16_buffer.items.len;
        if (utf16_len == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        // Create CFString from UTF-16
        const cf_string = blk: {
            const objc = @import("objc");
            const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
            const ns_string = NSString.msgSend(
                objc.Object,
                "alloc",
                .{},
            ).msgSend(
                objc.Object,
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

        var glyph_buffer = std.ArrayList(ShapedGlyph){};
        defer glyph_buffer.deinit(allocator);

        var total_width: f32 = 0;

        var run_idx: ct.CFIndex = 0;
        while (run_idx < run_count) : (run_idx += 1) {
            const run: ct.CTRunRef = @ptrCast(@constCast(ct.CFArrayGetValueAtIndex(runs, run_idx)));
            const glyph_count = ct.CTRunGetGlyphCount(run);

            if (glyph_count == 0) continue;

            const glyphs = try allocator.alloc(ct.CGGlyph, @intCast(glyph_count));
            defer allocator.free(glyphs);

            const positions = try allocator.alloc(ct.CGPoint, @intCast(glyph_count));
            defer allocator.free(positions);

            const advances = try allocator.alloc(ct.CGSize, @intCast(glyph_count));
            defer allocator.free(advances);

            const indices = try allocator.alloc(ct.CFIndex, @intCast(glyph_count));
            defer allocator.free(indices);

            const range = ct.CFRange.init(0, glyph_count);
            ct.CTRunGetGlyphs(run, range, glyphs.ptr);
            ct.CTRunGetPositions(run, range, positions.ptr);
            ct.CTRunGetAdvances(run, range, advances.ptr);
            ct.CTRunGetStringIndices(run, range, indices.ptr);

            for (0..@intCast(glyph_count)) |i| {
                const cluster = if (indices[i] >= 0 and indices[i] < cluster_map.items.len)
                    cluster_map.items[@intCast(indices[i])]
                else
                    0;

                // Don't use positions[i].x as offset - advances already include kerning!
                // Or calculate relative offset from previous position
                const x_offset: f32 = if (i == 0)
                    @floatCast(positions[i].x) // First glyph: use as-is
                else
                    0; // Subsequent glyphs: just use advance

                try glyph_buffer.append(allocator, .{
                    .glyph_id = glyphs[i],
                    .x_offset = x_offset,
                    .y_offset = @floatCast(positions[i].y),
                    .x_advance = @floatCast(advances[i].width),
                    .y_advance = @floatCast(advances[i].height),
                    .cluster = cluster,
                });

                total_width += @floatCast(advances[i].width);
            }
        }

        const result = try glyph_buffer.toOwnedSlice(allocator);

        return ShapedRun{
            .glyphs = result,
            .width = total_width,
        };
    }
};
