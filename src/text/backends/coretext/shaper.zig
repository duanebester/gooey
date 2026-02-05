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

    /// Pre-allocated buffers for glyph data (eliminates per-shape allocations)
    glyph_buf: [MAX_GLYPHS_PER_RUN]ct.CGGlyph,
    position_buf: [MAX_GLYPHS_PER_RUN]ct.CGPoint,
    advance_buf: [MAX_GLYPHS_PER_RUN]ct.CGSize,
    index_buf: [MAX_GLYPHS_PER_RUN]ct.CFIndex,

    /// Pre-allocated cluster map buffer
    cluster_buf: [MAX_CLUSTER_MAP]u32,

    const Self = @This();

    /// Maximum glyphs per CTRun (covers most text scenarios)
    const MAX_GLYPHS_PER_RUN: usize = 1024;
    /// Maximum UTF-16 units for cluster mapping (~2KB UTF-8 text)
    const MAX_CLUSTER_MAP: usize = 2048;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .utf16_buffer = std.ArrayList(ct.UniChar){},
            .glyph_buf = undefined,
            .position_buf = undefined,
            .advance_buf = undefined,
            .index_buf = undefined,
            .cluster_buf = undefined,
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

        // Convert UTF-8 to UTF-16 using pre-allocated cluster buffer
        self.utf16_buffer.clearRetainingCapacity();
        var cluster_count: usize = 0;

        var byte_idx: u32 = 0;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            const start_byte = byte_idx;
            byte_idx = @intCast(iter.i);

            if (cp <= 0xFFFF) {
                try self.utf16_buffer.append(self.allocator, @intCast(cp));
                if (cluster_count >= MAX_CLUSTER_MAP) return error.TextTooLong;
                self.cluster_buf[cluster_count] = start_byte;
                cluster_count += 1;
            } else {
                const adjusted = cp - 0x10000;
                try self.utf16_buffer.append(self.allocator, @intCast(0xD800 + (adjusted >> 10)));
                try self.utf16_buffer.append(self.allocator, @intCast(0xDC00 + (adjusted & 0x3FF)));
                if (cluster_count + 1 >= MAX_CLUSTER_MAP) return error.TextTooLong;
                self.cluster_buf[cluster_count] = start_byte;
                self.cluster_buf[cluster_count + 1] = start_byte;
                cluster_count += 2;
            }
        }

        const cluster_map = self.cluster_buf[0..cluster_count];

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

            // Check against pre-allocated buffer limits
            if (glyph_count > MAX_GLYPHS_PER_RUN) return error.RunTooLong;

            // Get the font actually used for this run (may be a fallback font)
            const run_attrs = ct.CTRunGetAttributes(run);
            const run_font: ?ct.CTFontRef = if (ct.CFDictionaryGetValue(run_attrs, @ptrCast(ct.kCTFontAttributeName))) |f|
                @ptrCast(@constCast(f))
            else
                null;

            // Check if this run uses a fallback font
            const is_fallback = if (run_font) |rf| @intFromPtr(rf) != @intFromPtr(face.ct_font) else false;

            // Check if this is a color font (emoji)
            const is_color = if (run_font) |rf| blk: {
                const traits = ct.CTFontGetSymbolicTraits(rf);
                break :blk (traits & ct.kCTFontTraitColorGlyphs) != 0;
            } else false;

            // Use pre-allocated buffers instead of per-call allocation
            const glyph_count_usize: usize = @intCast(glyph_count);
            const glyphs = self.glyph_buf[0..glyph_count_usize];
            const positions = self.position_buf[0..glyph_count_usize];
            const advances = self.advance_buf[0..glyph_count_usize];
            const indices = self.index_buf[0..glyph_count_usize];

            const range = ct.CFRange.init(0, glyph_count);
            ct.CTRunGetGlyphs(run, range, glyphs.ptr);
            ct.CTRunGetPositions(run, range, positions.ptr);
            ct.CTRunGetAdvances(run, range, advances.ptr);
            ct.CTRunGetStringIndices(run, range, indices.ptr);

            for (0..@intCast(glyph_count)) |i| {
                const cluster = if (indices[i] >= 0 and indices[i] < cluster_map.len)
                    cluster_map[@intCast(indices[i])]
                else
                    0;

                // Calculate relative offset within the run
                // positions[i] is absolute from line start, so we need relative offset
                const x_offset: f32 = if (i == 0)
                    0 // First glyph of run: no offset, advances handle positioning
                else
                    @floatCast(positions[i].x - positions[i - 1].x - advances[i - 1].width);

                try glyph_buffer.append(allocator, .{
                    .glyph_id = glyphs[i],
                    .x_offset = x_offset,
                    .y_offset = @floatCast(positions[i].y),
                    .x_advance = @floatCast(advances[i].width),
                    .y_advance = @floatCast(advances[i].height),
                    .cluster = cluster,
                    // Store font reference if this is a fallback font
                    // We must retain it since CTLine will be released
                    .font_ref = if (is_fallback and run_font != null) blk: {
                        _ = ct.CFRetain(@ptrCast(run_font.?));
                        break :blk run_font;
                    } else null,
                    .is_color = is_color,
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
