//! HarfBuzz text shaper implementation
//!
//! Provides full Unicode text shaping using HarfBuzz,
//! including support for ligatures, kerning, and complex scripts.

const std = @import("std");
const ft = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");
const shaper_mod = @import("../../shaper.zig");
const FreeTypeFace = @import("face.zig").FreeTypeFace;

const ShapedGlyph = types.ShapedGlyph;
const ShapedRun = types.ShapedRun;
const FontFace = font_face_mod.FontFace;
const Shaper = shaper_mod.Shaper;

/// HarfBuzz-backed text shaper
pub const HarfBuzzShaper = struct {
    allocator: std.mem.Allocator,
    /// Reusable HarfBuzz buffer
    hb_buffer: *ft.hb_buffer_t,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const buffer = ft.hb_buffer_create() orelse @panic("Failed to create HarfBuzz buffer");
        return .{
            .allocator = allocator,
            .hb_buffer = buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        ft.hb_buffer_destroy(self.hb_buffer);
        self.* = undefined;
    }

    /// Get as the generic Shaper interface
    pub fn asShaper(self: *Self) Shaper {
        const gen = struct {
            fn shapeFn(ptr: *anyopaque, face: FontFace, text: []const u8, allocator: std.mem.Allocator) anyerror!ShapedRun {
                const shaper: *Self = @ptrCast(@alignCast(ptr));
                // For complex shaping, we need the underlying FreeType face
                const ft_face: *FreeTypeFace = @ptrCast(@alignCast(face.ptr));
                return shaper.shape(ft_face, text, allocator);
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

    /// Full text shaping using HarfBuzz
    pub fn shape(self: *Self, face: *const FreeTypeFace, text: []const u8, allocator: std.mem.Allocator) !ShapedRun {
        if (text.len == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        // Reset buffer for reuse
        ft.hb_buffer_reset(self.hb_buffer);

        // Add UTF-8 text to buffer
        ft.hb_buffer_add_utf8(
            self.hb_buffer,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );

        // Let HarfBuzz guess direction, script, and language from text
        ft.hb_buffer_guess_segment_properties(self.hb_buffer);

        // Use monotone cluster level for proper cluster mapping
        ft.hb_buffer_set_cluster_level(self.hb_buffer, .HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);

        // Perform shaping
        ft.hb_shape(face.hb_font, self.hb_buffer, null, 0);

        // Get results
        var glyph_count: c_uint = 0;
        const glyph_infos = ft.hb_buffer_get_glyph_infos(self.hb_buffer, &glyph_count);
        const glyph_positions = ft.hb_buffer_get_glyph_positions(self.hb_buffer, &glyph_count);

        if (glyph_count == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        // Allocate output
        var glyph_buffer = std.ArrayList(ShapedGlyph){};
        defer glyph_buffer.deinit(allocator);
        try glyph_buffer.ensureTotalCapacity(allocator, glyph_count);

        var total_width: f32 = 0;

        for (0..glyph_count) |i| {
            const info = glyph_infos[i];
            const pos = glyph_positions[i];

            // HarfBuzz positions are in font units - scale by font size
            // The hb_ft bridge should handle scaling, but positions are still in 26.6
            const x_advance = ft.f26dot6ToFloat(pos.x_advance);
            const y_advance = ft.f26dot6ToFloat(pos.y_advance);
            const x_offset = ft.f26dot6ToFloat(pos.x_offset);
            const y_offset = ft.f26dot6ToFloat(pos.y_offset);

            glyph_buffer.appendAssumeCapacity(.{
                .glyph_id = @intCast(info.codepoint),
                .x_offset = x_offset,
                .y_offset = y_offset,
                .x_advance = x_advance,
                .y_advance = y_advance,
                .cluster = info.cluster,
                .font_ref = null, // No fallback font handling yet
                .is_color = false, // TODO: detect color glyphs
            });

            total_width += x_advance;
        }

        return ShapedRun{
            .glyphs = try glyph_buffer.toOwnedSlice(allocator),
            .width = total_width,
        };
    }

    /// Shape text with explicit direction
    pub fn shapeDirected(
        self: *Self,
        face: *const FreeTypeFace,
        text: []const u8,
        direction: ft.hb_direction_t,
        allocator: std.mem.Allocator,
    ) !ShapedRun {
        if (text.len == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        ft.hb_buffer_reset(self.hb_buffer);
        ft.hb_buffer_add_utf8(
            self.hb_buffer,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );

        ft.hb_buffer_set_direction(self.hb_buffer, direction);
        ft.hb_buffer_set_cluster_level(self.hb_buffer, .HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);

        // Let HarfBuzz guess script and language
        ft.hb_buffer_guess_segment_properties(self.hb_buffer);

        ft.hb_shape(face.hb_font, self.hb_buffer, null, 0);

        var glyph_count: c_uint = 0;
        const glyph_infos = ft.hb_buffer_get_glyph_infos(self.hb_buffer, &glyph_count);
        const glyph_positions = ft.hb_buffer_get_glyph_positions(self.hb_buffer, &glyph_count);

        if (glyph_count == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        var glyph_buffer = std.ArrayList(ShapedGlyph){};
        defer glyph_buffer.deinit(allocator);
        try glyph_buffer.ensureTotalCapacity(allocator, glyph_count);

        var total_width: f32 = 0;

        for (0..glyph_count) |i| {
            const info = glyph_infos[i];
            const pos = glyph_positions[i];

            const x_advance = ft.f26dot6ToFloat(pos.x_advance);
            const y_advance = ft.f26dot6ToFloat(pos.y_advance);
            const x_offset = ft.f26dot6ToFloat(pos.x_offset);
            const y_offset = ft.f26dot6ToFloat(pos.y_offset);

            glyph_buffer.appendAssumeCapacity(.{
                .glyph_id = @intCast(info.codepoint),
                .x_offset = x_offset,
                .y_offset = y_offset,
                .x_advance = x_advance,
                .y_advance = y_advance,
                .cluster = info.cluster,
                .font_ref = null,
                .is_color = false,
            });

            total_width += x_advance;
        }

        return ShapedRun{
            .glyphs = try glyph_buffer.toOwnedSlice(allocator),
            .width = total_width,
        };
    }
};
