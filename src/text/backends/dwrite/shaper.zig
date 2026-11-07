//! DirectWrite text shaping.
//!
//! Uses `IDWriteTextAnalyzer::GetGlyphs` + `GetGlyphPlacements` — the same
//! two-pass shape HarfBuzz performs for the Linux backend, driven by the
//! system shaper instead. Advances and offsets come back in DIPs at the
//! face's point size, which is the pixel scale the rest of the pipeline
//! expects at scale factor 1.0 (the glyph cache multiplies by the DPI scale
//! when rasterizing).
//!
//! Clusters: DirectWrite indexes clusters in UTF-16 units while `ShapedGlyph`
//! uses UTF-8 byte offsets, so the text is decoded once, recording the byte
//! offset of every UTF-16 unit to translate the cluster map back.

const std = @import("std");
const dw = @import("bindings.zig");
const types = @import("../../types.zig");
const face_mod = @import("face.zig");

const DirectWriteFace = face_mod.DirectWriteFace;
const ShapedGlyph = types.ShapedGlyph;
const ShapedRun = types.ShapedRun;

pub const DirectWriteShaper = struct {
    allocator: std.mem.Allocator,
    /// Created on first `shape` call. Kept optional so `init` stays
    /// infallible (the HarfBuzz shaper panics from `init` instead).
    analyzer: ?*dw.IDWriteTextAnalyzer = null,
    /// Lazily loaded CJK fallback face, owned here so `font_ref` pointers
    /// handed out in ShapedGlyphs stay valid for the shaper's lifetime.
    /// Null until a run first contains an uncovered codepoint, and stays
    /// null when no candidate family exists on this install (then glyphs
    /// degrade to .notdef as before).
    fallback_face: ?*face_mod.DirectWriteFace = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.analyzer) |a| dw.release(dw.IDWriteTextAnalyzer, a);
        if (self.fallback_face) |f| {
            f.deinit();
            self.allocator.destroy(f);
        }
        self.* = undefined;
    }

    /// Re-map .notdef glyphs against the CJK fallback face.
    ///
    /// For every glyph the primary face left at id 0, the cluster's leading
    /// codepoint is looked up in the fallback face; on a hit the glyph id is
    /// replaced and `font_ref` points at the fallback face, and its advance
    /// replaces the .notdef advance (width of the run stays consistent with
    /// what will actually be drawn). Codepoints the fallback also lacks keep
    /// their .notdef box.
    fn resolveFallbacks(
        self: *Self,
        face: *const face_mod.DirectWriteFace,
        utf16: []const u16,
        cluster_map: []const u16,
        glyphs: []ShapedGlyph,
    ) !void {
        // Cheap pre-pass: nothing to do when the primary face covered everything.
        var needs_fallback = false;
        for (glyphs) |g| {
            if (g.glyph_id == 0) {
                needs_fallback = true;
                break;
            }
        }
        if (!needs_fallback) return;

        if (self.fallback_face == null) {
            const f = face_mod.DirectWriteFace.initCjkFallback(face.point_size) catch return;
            const ptr = try self.allocator.create(face_mod.DirectWriteFace);
            ptr.* = f;
            self.fallback_face = ptr;
        }
        const fallback = self.fallback_face.?;

        // Decode the UTF-16 units of each uncovered cluster to codepoints for
        // the fallback face's index lookup.
        var codepoints: [1]u32 = undefined;
        var indices: [1]u16 = undefined;

        for (glyphs) |*g| {
            if (g.glyph_id != 0) continue;

            // The cluster's UTF-16 range: from this glyph's cluster offset to
            // the next distinct cluster offset (or end of text).
            const start16: usize = g.cluster;
            std.debug.assert(start16 <= utf16.len);
            var end16: usize = utf16.len;
            for (cluster_map, 0..) |cm, gi| {
                if (gi > 0 and glyphs[gi].cluster > g.cluster) {
                    end16 = cm;
                    break;
                }
            }
            if (start16 >= end16) continue;

            // UTF-16 → codepoint (surrogate pairs recombine here; CJK
            // extension-B characters arrive as pairs).
            const unit: u32 = utf16[start16];
            const cp: u32 = if (unit >= 0xD800 and unit < 0xDC00 and start16 + 1 < end16)
                0x10000 + ((unit - 0xD800) << 10) + (utf16[start16 + 1] - 0xDC00)
            else
                unit;

            codepoints[0] = cp;
            if (!fallback.font_face.getGlyphIndices(&codepoints, &indices)) continue;
            if (indices[0] == 0) continue; // fallback doesn't cover it either

            // Covered: replace glyph id, advance, and mark the font. The
            // fallback's design advance at the same point size keeps spacing
            // consistent with what getGlyphPlacements would have produced.
            g.glyph_id = indices[0];
            g.font_ref = fallback;
            g.x_advance = fallback.glyphAdvance(indices[0]);
        }
    }

    /// Shape one run of UTF-8 text against `face`.
    pub fn shape(
        self: *Self,
        face: *const DirectWriteFace,
        text: []const u8,
        allocator: std.mem.Allocator,
    ) !ShapedRun {
        if (text.len == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        // Lazily create the analyzer from the process-shared factory the
        // face loader uses, so the first shape and the first font load share
        // one DWriteCreateFactory round-trip.
        if (self.analyzer == null) {
            const f = face_mod.factory() catch return error.DirectWriteInitFailed;
            self.analyzer = f.createTextAnalyzer() orelse return error.ShaperInitFailed;
        }
        const analyzer = self.analyzer.?;

        // Decode UTF-8 → NUL-terminated UTF-16, recording each unit's source
        // byte offset (`utf16_offsets[utf16_len]` is the past-the-end offset).
        const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;

        var utf16_offsets: std.ArrayList(u32) = .empty;
        defer utf16_offsets.deinit(allocator);

        const utf16_z = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch
            return error.InvalidUtf8;
        defer allocator.free(utf16_z);

        var unit_index: u32 = 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            try utf16_offsets.append(allocator, unit_index);
            unit_index += std.unicode.utf16CodepointSequenceLength(cp) catch
                return error.InvalidUtf8;
        }
        try utf16_offsets.append(allocator, unit_index);

        const text_len: u32 = @intCast(utf16_z.len);

        // Pass 1: map text onto glyph indices. DirectWrite requires a
        // caller-provided upper bound; one glyph per UTF-16 unit is the
        // documented worst case, with slack for shaping expansion.
        const max_glyph_count: u32 = text_len * 3 / 2 + 16;

        const cluster_map = try allocator.alloc(u16, text_len);
        defer allocator.free(cluster_map);
        const text_props = try allocator.alloc(dw.DWRITE_SHAPING_TEXT_PROPERTIES, text_len);
        defer allocator.free(text_props);
        const glyph_indices = try allocator.alloc(u16, max_glyph_count);
        defer allocator.free(glyph_indices);
        const glyph_props = try allocator.alloc(dw.DWRITE_SHAPING_GLYPH_PROPERTIES, max_glyph_count);
        defer allocator.free(glyph_props);

        var actual_count: u32 = 0;
        if (!analyzer.getGlyphs(
            utf16_z.ptr,
            text_len,
            face.font_face,
            max_glyph_count,
            cluster_map.ptr,
            text_props.ptr,
            glyph_indices.ptr,
            glyph_props.ptr,
            &actual_count,
        )) return error.ShapingFailed;

        if (actual_count == 0) {
            return ShapedRun{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        // Pass 2: advances and offsets, in DIPs at the face's point size.
        const advances = try allocator.alloc(f32, actual_count);
        defer allocator.free(advances);
        const offsets = try allocator.alloc(dw.DWRITE_GLYPH_OFFSET, actual_count);
        defer allocator.free(offsets);

        if (!analyzer.getGlyphPlacements(
            utf16_z.ptr,
            cluster_map.ptr,
            text_props.ptr,
            text_len,
            glyph_indices.ptr,
            glyph_props.ptr,
            actual_count,
            face.font_face,
            face.point_size,
            advances.ptr,
            offsets.ptr,
        )) return error.ShapingFailed;

        const glyphs = try allocator.alloc(ShapedGlyph, actual_count);
        for (glyph_indices[0..actual_count], 0..) |gid, i| {
            // The cluster index is a UTF-16 offset; translate it to the
            // UTF-8 byte offset the shared glyph contract uses.
            const cluster16: usize = cluster_map[i];
            glyphs[i] = .{
                .glyph_id = gid,
                .x_offset = offsets[i].advanceOffset,
                .y_offset = offsets[i].ascenderOffset,
                .x_advance = advances[i],
                .y_advance = 0,
                .cluster = utf16_offsets.items[cluster16],
                .font_ref = null, // set below for fallback-covered glyphs
                .is_color = false, // TODO: detect color glyphs
            };
        }

        // Font fallback: glyphs left at id 0 (.notdef) by the primary face go
        // to the shared CJK fallback face. `resolveGlyphBatch` routes
        // `font_ref != null` glyphs through `GlyphCache.getOrRenderFallback`,
        // which rasterizes against the referenced face — the same contract
        // the macOS CoreText backend fulfills with its CTFontRef.
        try self.resolveFallbacks(face, utf16_z, cluster_map[0..actual_count], glyphs);

        // Width after fallback: replaced advances must be reflected so
        // measurement matches what will be drawn.
        var total_width: f32 = 0;
        for (glyphs) |g| total_width += g.x_advance;

        return ShapedRun{
            .glyphs = glyphs,
            .width = total_width,
        };
    }
};
