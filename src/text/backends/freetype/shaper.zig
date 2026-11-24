const std = @import("std");
const ft = @import("bindings.zig");
const types = @import("../../types.zig");
const FreeTypeFace = @import("face.zig").FreeTypeFace;

const ShapedGlyph = types.ShapedGlyph;
const ShapedRun = types.ShapedRun;

pub const HarfBuzzShaper = struct {
    allocator: std.mem.Allocator,
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

    pub fn shape(self: *Self, face: *const FreeTypeFace, text: []const u8, allocator: std.mem.Allocator) !ShapedRun {
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

        ft.hb_buffer_guess_segment_properties(self.hb_buffer);

        ft.hb_buffer_set_cluster_level(self.hb_buffer, .HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);

        ft.hb_shape(face.hb_font, self.hb_buffer, null, 0);

        var glyph_count: c_uint = 0;
        const glyph_infos = ft.hb_buffer_get_glyph_infos(self.hb_buffer, &glyph_count);
        const glyph_positions = ft.hb_buffer_get_glyph_positions(self.hb_buffer, &glyph_count);

        if (glyph_count == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        var glyph_buffer: std.ArrayList(ShapedGlyph) = .empty;
        defer glyph_buffer.deinit(allocator);
        try glyph_buffer.ensureTotalCapacity(allocator, glyph_count);

        var total_width: f32 = 0;

        for (0..glyph_count) |i| {
            const info = &glyph_infos[i];
            const pos = glyph_positions[i];

            const x_advance = ft.f26dot6ToFloat(pos.x_advance);
            const y_advance = ft.f26dot6ToFloat(pos.y_advance);
            const x_offset = ft.f26dot6ToFloat(pos.x_offset);
            const y_offset = ft.f26dot6ToFloat(pos.y_offset);

            const glyph_id = glyph_id_for_cluster(face, text, info);
            glyph_buffer.appendAssumeCapacity(.{
                .glyph_id = glyph_id,
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

        ft.hb_buffer_guess_segment_properties(self.hb_buffer);

        ft.hb_shape(face.hb_font, self.hb_buffer, null, 0);

        var glyph_count: c_uint = 0;
        const glyph_infos = ft.hb_buffer_get_glyph_infos(self.hb_buffer, &glyph_count);
        const glyph_positions = ft.hb_buffer_get_glyph_positions(self.hb_buffer, &glyph_count);

        if (glyph_count == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        var glyph_buffer: std.ArrayList(ShapedGlyph) = .empty;
        defer glyph_buffer.deinit(allocator);
        try glyph_buffer.ensureTotalCapacity(allocator, glyph_count);

        var total_width: f32 = 0;

        for (0..glyph_count) |i| {
            const info = &glyph_infos[i];
            const pos = glyph_positions[i];

            const x_advance = ft.f26dot6ToFloat(pos.x_advance);
            const y_advance = ft.f26dot6ToFloat(pos.y_advance);
            const x_offset = ft.f26dot6ToFloat(pos.x_offset);
            const y_offset = ft.f26dot6ToFloat(pos.y_offset);

            const glyph_id = glyph_id_for_cluster(face, text, info);
            glyph_buffer.appendAssumeCapacity(.{
                .glyph_id = glyph_id,
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

    inline fn glyph_id_for_cluster(
        face: *const FreeTypeFace,
        text: []const u8,
        info: *const ft.hb_glyph_info_t,
    ) u16 {
        if (info.codepoint == 0) {
            @branchHint(.unlikely);
            std.debug.assert(info.cluster < text.len);
            if (text[info.cluster] == '\t') return face.glyphIndex(' ');
        }
        return @intCast(info.codepoint);
    }
};
