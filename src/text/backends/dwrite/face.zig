//! DirectWrite font face implementation.
//!
//! Resolves a family name through the system font collection, wraps the
//! resulting `IDWriteFontFace`, and rasterizes glyphs through
//! `IDWriteGlyphRunAnalysis` into Gooey's grayscale atlas. All coordinates
//! are converted from DirectWrite's design units / DIPs into the physical
//! pixel space the glyph cache expects.

const std = @import("std");
const dw = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
const FontFace = font_face_mod.FontFace;

/// Process-shared DirectWrite factory, created on first use and never
/// destroyed (COM releases it at process exit along with the DLL).
var shared_factory: ?*dw.IDWriteFactory = null;

/// The process-wide factory, shared with the shaper so the first font load
/// and the first shape call each pay for `DWriteCreateFactory` only once.
pub fn factory() !*dw.IDWriteFactory {
    if (shared_factory) |f| return f;
    const f = dw.createFactory() orelse return error.DirectWriteInitFailed;
    shared_factory = f;
    return f;
}

/// UTF-8 → NUL-terminated UTF-16, allocated with the caller's allocator.
fn wideZ(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

pub const DirectWriteFace = struct {
    const Self = @This();
    const ADVANCE_UNCACHED: f32 = -1.0;

    font_face: *dw.IDWriteFontFace,
    /// Owned references released in `deinit`.
    font: ?*dw.IDWriteFont = null,
    family: ?*dw.IDWriteFontFamily = null,
    collection: ?*dw.IDWriteFontCollection = null,
    /// Design units per em, and the em size the face was created at.
    units_per_em: f32,
    point_size: f32,
    metrics: Metrics,
    advance_cache: [4096]f32,

    /// Load a font by family name (e.g. "Segoe UI").
    pub fn init(name: []const u8, size: f32) !Self {
        const f = try factory();
        const wide = try wideZ(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(wide);

        const collection = f.getSystemFontCollection() orelse return error.FontCollectionFailed;
        errdefer dw.release(dw.IDWriteFontCollection, collection);
        const index = collection.findFamilyName(wide.ptr) orelse return error.FontNotFound;
        return fromFamily(f, collection, index, size);
    }

    /// Load a system font by role.
    pub fn initSystem(style: SystemFont, size: f32) !Self {
        const f = try factory();
        const wide = try wideZ(std.heap.page_allocator, systemFamilyName(style));
        defer std.heap.page_allocator.free(wide);

        const collection = f.getSystemFontCollection() orelse return error.FontCollectionFailed;
        errdefer dw.release(dw.IDWriteFontCollection, collection);
        const index = collection.findFamilyName(wide.ptr) orelse
            // Fall back to the first family when the requested one is absent
            // (e.g. a minimal Windows install without the monospace face).
            (if (collection.vtable.GetFontFamilyCount(collection) > 0) @as(u32, 0) else return error.FontNotFound);
        return fromFamily(f, collection, index, size);
    }

    fn fromFamily(
        f: *dw.IDWriteFactory,
        collection: *dw.IDWriteFontCollection,
        index: u32,
        size: f32,
    ) !Self {
        _ = f;
        const family = collection.getFontFamily(index) orelse return error.FontNotFound;
        errdefer dw.release(dw.IDWriteFontFamily, family);
        const font = family.getFirstMatchingFont() orelse return error.FontNotFound;
        errdefer dw.release(dw.IDWriteFont, font);
        const face = font.createFontFace() orelse return error.FontLoadFailed;
        errdefer dw.release(dw.IDWriteFontFace, face);

        const dm = face.getMetrics();
        const upem: f32 = @floatFromInt(dm.designUnitsPerEm);
        const scale = size / upem;
        const ascender = @as(f32, @floatFromInt(dm.ascent)) * scale;
        const descender = @as(f32, @floatFromInt(dm.descent)) * scale;
        const line_gap = @as(f32, @floatFromInt(dm.lineGap)) * scale;
        const cap_height = if (dm.capHeight != 0)
            @as(f32, @floatFromInt(dm.capHeight)) * scale
        else
            ascender * 0.7;
        const x_height = if (dm.xHeight != 0)
            @as(f32, @floatFromInt(dm.xHeight)) * scale
        else
            ascender * 0.5;

        return .{
            .font_face = face,
            .font = font,
            .family = family,
            .collection = collection,
            .units_per_em = upem,
            .point_size = size,
            .metrics = .{
                .units_per_em = dm.designUnitsPerEm,
                .ascender = ascender,
                .descender = descender,
                .line_gap = line_gap,
                .cap_height = cap_height,
                .x_height = x_height,
                .underline_position = -@as(f32, @floatFromInt(dm.underlinePosition)) * scale,
                .underline_thickness = @as(f32, @floatFromInt(dm.underlineThickness)) * scale,
                .line_height = ascender + descender + line_gap,
                .point_size = size,
                .is_monospace = false,
                .cell_width = 0,
            },
            .advance_cache = @splat(ADVANCE_UNCACHED),
        };
    }

    pub fn deinit(self: *Self) void {
        dw.release(dw.IDWriteFontFace, self.font_face);
        dw.release(dw.IDWriteFont, self.font);
        dw.release(dw.IDWriteFontFamily, self.family);
        dw.release(dw.IDWriteFontCollection, self.collection);
        self.* = undefined;
    }

    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        const cps = [_]u32{@intCast(codepoint)};
        var idx: [1]u16 = .{0};
        if (!self.font_face.getGlyphIndices(&cps, &idx)) return 0;
        return idx[0];
    }

    pub fn glyphAdvance(self: *Self, glyph_id: u16) f32 {
        if (glyph_id < self.advance_cache.len) {
            const cached = self.advance_cache[glyph_id];
            if (cached != ADVANCE_UNCACHED) return cached;
        }
        const value = self.glyphMetrics(glyph_id).advance_x;
        if (glyph_id < self.advance_cache.len) self.advance_cache[glyph_id] = value;
        return value;
    }

    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        const indices = [_]u16{glyph_id};
        var dm: [1]dw.DWRITE_GLYPH_METRICS = undefined;
        if (!self.font_face.getDesignGlyphMetrics(&indices, &dm)) {
            return .{
                .glyph_id = glyph_id,
                .advance_x = 0,
                .advance_y = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .width = 0,
                .height = 0,
            };
        }
        const scale = self.point_size / self.units_per_em;
        const m = dm[0];
        return .{
            .glyph_id = glyph_id,
            .advance_x = @as(f32, @floatFromInt(m.advanceWidth)) * scale,
            .advance_y = @as(f32, @floatFromInt(m.advanceHeight)) * scale,
            .bearing_x = @as(f32, @floatFromInt(m.leftSideBearing)) * scale,
            .bearing_y = @as(f32, @floatFromInt(m.topSideBearing)) * scale,
            .width = (@as(f32, @floatFromInt(m.advanceWidth)) -
                @as(f32, @floatFromInt(m.leftSideBearing)) -
                @as(f32, @floatFromInt(m.rightSideBearing))) * scale,
            .height = (@as(f32, @floatFromInt(m.advanceHeight)) -
                @as(f32, @floatFromInt(m.topSideBearing)) -
                @as(f32, @floatFromInt(m.bottomSideBearing))) * scale,
        };
    }

    /// Rasterize one glyph into `buffer` as 8-bit coverage.
    ///
    /// DirectWrite's `CreateGlyphRunAnalysis` takes a baseline origin in DIPs;
    /// fractional pen positions are folded into that origin so the analyzer
    /// applies the same subpixel shift the other backends apply by translating
    /// the outline. `scale` converts DIPs to physical pixels.
    pub fn renderGlyphSubpixel(
        self: *const Self,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        std.debug.assert(font_size > 0);
        std.debug.assert(scale > 0);
        std.debug.assert(subpixel_x >= 0 and subpixel_x < 1.0);
        std.debug.assert(subpixel_y >= 0 and subpixel_y < 1.0);

        return renderGlyphFromFont(
            self.font_face,
            glyph_id,
            font_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    /// Rasterize from any `IDWriteFontFace` (fallback-font path).
    pub fn renderGlyphFromFont(
        font_face: *dw.IDWriteFontFace,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        const f = try factory();
        const dm = font_face.getMetrics();
        const upem: f32 = @floatFromInt(dm.designUnitsPerEm);
        const gm_scale = font_size / upem;

        const indices = [_]u16{glyph_id};
        var gm: [1]dw.DWRITE_GLYPH_METRICS = undefined;
        if (!font_face.getDesignGlyphMetrics(&indices, &gm)) return error.GlyphMetricsFailed;
        const advance_dip = @as(f32, @floatFromInt(gm[0].advanceWidth)) * gm_scale;

        const advances = [_]f32{advance_dip};
        const run = dw.DWRITE_GLYPH_RUN{
            .fontFace = font_face,
            .fontEmSize = font_size,
            .glyphCount = 1,
            .glyphIndices = &indices,
            .glyphAdvances = &advances,
            .glyphOffsets = null,
            .isSideways = 0,
            .bidiLevel = 0,
        };

        // pixelsPerDip = physical pixels per logical pixel. The baseline
        // carries the fractional offset in DIPs so the analyzer snaps the
        // outline at the right subpixel phase.
        const baseline_x = subpixel_x / scale;
        const baseline_y = (@as(f32, @floatFromInt(dm.ascent)) * gm_scale + subpixel_y) / scale;
        const analysis = f.createGlyphRunAnalysis(&run, scale, baseline_x, baseline_y) orelse
            return error.GlyphAnalysisFailed;
        defer dw.release(dw.IDWriteGlyphRunAnalysis, analysis);

        const bounds = analysis.getAlphaTextureBounds() orelse return error.GlyphAnalysisFailed;
        const w: u32 = @intCast(@max(bounds.right - bounds.left, 0));
        const h: u32 = @intCast(@max(bounds.bottom - bounds.top, 0));
        if (w * h > buffer.len or w * h > buffer_size) return error.GlyphBufferTooSmall;

        if (w * h > 0) {
            // NATURAL rendering produces a ClearType 3×1 texture: three bytes
            // of sub-pixel coverage per pixel. Rasterize into a scratch buffer
            // (caller's `buffer` is sized for 1 byte per pixel) and reduce to
            // one grayscale byte by averaging the channels, which also
            // neutralizes the colored ClearType fringes.
            const needed = w * h * 3;
            const scratch = std.heap.page_allocator.alloc(u8, needed) catch
                return error.GlyphRasterFailed;
            defer std.heap.page_allocator.free(scratch);
            if (!analysis.createAlphaTexture(&bounds, scratch.ptr, needed)) return error.GlyphRasterFailed;
            for (0..w * h) |i| {
                const r: u32 = scratch[i * 3];
                const g: u32 = scratch[i * 3 + 1];
                const b: u32 = scratch[i * 3 + 2];
                buffer[i] = @intCast((r + g + b) / 3);
            }
        }

        // The glyph bitmap's top edge relative to the pen baseline, in
        // device pixels. `GetAlphaTextureBounds` returns texture-space
        // coordinates (top measured from the texture origin, NOT from the
        // baseline), so the baseline distance must be recovered: the run was
        // placed with its baseline at `baseline_y` DIPs, i.e.
        // `baseline_y * scale` device pixels, and the bitmap top sits
        // `baseline_y * scale - bounds.top` pixels above that baseline.
        // Consumers (GlyphCache.offset_y -> emitGlyphsToScene) expect
        // `offset_y = distance from bitmap top UP to the baseline`, which is
        // exactly that value.
        const baseline_device_y = baseline_y * scale;
        const offset_top: i32 = @intFromFloat(@round(baseline_device_y - @as(f32, @floatFromInt(bounds.top))));

        return .{
            .width = w,
            .height = h,
            .offset_x = bounds.left,
            .offset_y = offset_top,
            .advance_x = advance_dip,
            .is_color = false,
        };
    }

    // Candidate families for the CJK fallback face, most-preferred first.
    // "Microsoft YaHei UI" ships with Windows 8.1+ (Simplified Chinese);
    // "Microsoft YaHei" is the pre-8.1 name; "SimSun" is the last-ditch
    // XP-era option present on every Windows install.
    const cjk_fallback_families = [_][]const u8{
        "Microsoft YaHei UI",
        "Microsoft YaHei",
        "SimSun",
    };

    /// Load the CJK fallback face at `size`. Returns `FontNotFound` when none
    /// of the candidates exist (e.g. a stripped-down install) — callers
    /// degrade to .notdef boxes, exactly as before this fallback existed.
    pub fn initCjkFallback(size: f32) !Self {
        for (cjk_fallback_families) |family_name| {
            return Self.init(family_name, size) catch continue;
        }
        return error.FontNotFound;
    }
};

fn systemFamilyName(style: SystemFont) []const u8 {
    return switch (style) {
        .monospace => "Consolas",
        .sans_serif, .system => "Segoe UI",
        .serif => "Times New Roman",
    };
}

test "system family names cover every style" {
    inline for (@typeInfo(SystemFont).@"enum".field_names) |name| {
        const style = @field(SystemFont, name);
        try std.testing.expect(systemFamilyName(style).len > 0);
    }
}
