//! DirectWrite font face implementation.
//!
//! Implements the FontFace interface with DirectWrite: the system font
//! collection for discovery, design metrics for measurement, and
//! `IDWriteGlyphRunAnalysis` for grayscale rasterization. No Direct2D, GDI, or
//! render target is involved; DirectWrite writes coverage straight into the
//! glyph cache's render buffer.
//!
//! Units match the CoreText backend: one font size unit is one logical pixel
//! (one DirectWrite DIP), and rasterization runs at `font_size * scale` device
//! pixels.

const std = @import("std");
const assert = std.debug.assert;
const dw = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");
const font_match = @import("../../font_match.zig");
const limits = @import("../../../core/limits.zig");

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
const FontVariant = types.FontVariant;
const FontFace = font_face_mod.FontFace;

/// Substitutions and capacity failures log warnings; failures no input
/// should cause log errors. See `shaper.zig`.
const log = std.log.scoped(.directwrite);

/// Longest family name `init` accepts, in UTF-8 bytes. A UTF-8 name never has
/// more UTF-16 code units than bytes, so the UTF-16 buffer is this plus one
/// for the terminator. Installed family names are far shorter.
const family_name_bytes_max: u32 = 255;

/// Families for the system styles and the CSS generic names. These ship with
/// every supported Windows release.
const family_sans_serif = "Segoe UI";
const family_monospace = "Consolas";
const family_serif = "Times New Roman";

/// CSS `font-stretch` percentage for each `DWRITE_FONT_STRETCH` value, with
/// Fontconfig's rounding of the fractional widths so equal requests rank alike.
const stretch_percent_by_dwrite_stretch = [_]u16{ 100, 50, 63, 75, 87, 100, 113, 125, 150, 200 };

comptime {
    assert(stretch_percent_by_dwrite_stretch.len == dw.DWRITE_FONT_STRETCH_ULTRA_EXPANDED + 1);
    assert(family_name_bytes_max < std.math.maxInt(u16));
}

/// DirectWrite-backed font face.
pub const DirectWriteFace = struct {
    /// The process-wide shared factory; this face holds one reference.
    factory: *dw.IDWriteFactory2,
    font_face: *dw.IDWriteFontFace,
    /// Stateless and thread-safe; the shaper borrows it.
    text_analyzer: *dw.IDWriteTextAnalyzer,
    metrics: Metrics,
    design_units_per_em: u16,
    /// Glyph ids at or past this are not in the font.
    glyph_count: u16,

    const Self = @This();

    /// Load one variant of a family by name (e.g., "Segoe UI", "Cascadia Code").
    ///
    /// Selection: the name resolves to an installed family, the family's real
    /// faces are listed, and `font_match.select` picks one by the CSS font
    /// matching rule, as the FreeType and CoreText backends do. Fallback
    /// policy: nothing is synthesized, and DirectWrite's simulated faces are
    /// skipped. A family without the requested weight or slant renders with
    /// the face CSS matching picks, with a warning. A family that is not
    /// installed renders as Segoe UI, with a warning, as Fontconfig and
    /// CoreText substitute a default family.
    pub fn init(name: []const u8, size: f32, variant: FontVariant) !Self {
        assert(name.len > 0);
        assert(size > 0);
        return initFamily(familyForGenericName(name), size, variant);
    }

    /// Load one variant of a system family, with the same policy as `init`.
    pub fn initSystem(style: SystemFont, size: f32, variant: FontVariant) !Self {
        assert(size > 0);
        const family = switch (style) {
            .monospace => family_monospace,
            .sans_serif, .system => family_sans_serif,
            .serif => family_serif,
        };
        return initFamily(family, size, variant);
    }

    fn initFamily(family: []const u8, size: f32, variant: FontVariant) !Self {
        assert(family.len > 0);
        assert(size > 0);

        const factory = try createFactory();
        errdefer factory.release();

        const font_face = try createFontFace(factory, family, variant);
        errdefer font_face.release();

        var text_analyzer: ?*dw.IDWriteTextAnalyzer = null;
        const result = factory.vtable.CreateTextAnalyzer(factory, &text_analyzer);
        if (!dw.succeeded(result)) {
            logFailure("CreateTextAnalyzer", result);
            return error.TextAnalyzerCreateFailed;
        }
        assert(text_analyzer != null);
        errdefer text_analyzer.?.release();

        var font_metrics: dw.DWRITE_FONT_METRICS = undefined;
        font_face.vtable.GetMetrics(font_face, &font_metrics);
        if (font_metrics.designUnitsPerEm == 0) {
            log.err("font '{s}' reports 0 design units per em", .{family});
            return error.FontMetricsInvalid;
        }

        const self: Self = .{
            .factory = factory,
            .font_face = font_face,
            .text_analyzer = text_analyzer.?,
            .metrics = computeMetrics(font_face, &font_metrics, size),
            .design_units_per_em = font_metrics.designUnitsPerEm,
            .glyph_count = font_face.vtable.GetGlyphCount(font_face),
        };
        assert(self.metrics.point_size == size);
        assert(self.metrics.line_height > 0);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.text_analyzer.release();
        self.font_face.release();
        self.factory.release();
        self.* = undefined;
    }

    /// Get as the generic FontFace interface.
    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    /// Glyph id for a Unicode codepoint; 0 (.notdef) when the font lacks it.
    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        const codepoints = [1]u32{codepoint};
        var glyph_ids = [1]u16{0};
        const result = self.font_face.vtable.GetGlyphIndices(
            self.font_face,
            &codepoints,
            1,
            &glyph_ids,
        );
        // Fails only for invalid arguments: a codepoint the font lacks maps
        // to glyph 0 with S_OK, and every argument here is valid by type.
        assert(dw.succeeded(result));
        if (glyph_ids[0] != 0) assert(glyph_ids[0] < self.glyph_count);
        return glyph_ids[0];
    }

    /// Advance width at the loaded size, in logical pixels.
    pub fn glyphAdvance(self: *const Self, glyph_id: u16) f32 {
        return self.glyphMetrics(glyph_id).advance_x;
    }

    /// Metrics at the loaded size, in logical pixels, y up from the baseline.
    /// A glyph id outside the font reports zero metrics.
    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        if (glyph_id < self.glyph_count) {
            const design = designGlyphMetrics(self.font_face, glyph_id);
            return scaleGlyphMetrics(glyph_id, &design, self.unitScale(self.metrics.point_size));
        } else {
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
    }

    /// Render a glyph at `font_size * scale` device pixels, shifted right by
    /// `subpixel_x` and up by `subpixel_y` device pixels, into `buffer` as
    /// tightly packed 8-bit coverage rows.
    ///
    /// `buffer_size` is the capacity of `buffer` in bytes. A glyph wider or
    /// taller than `limits.MAX_GLYPH_SIZE` fails with `GlyphTooLarge` rather
    /// than being cropped.
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
        assert(font_size > 0);
        assert(scale > 0);
        assert(subpixel_x >= 0);
        assert(subpixel_x < 1.0);
        assert(subpixel_y >= 0);
        assert(subpixel_y < 1.0);
        assert(buffer.len >= buffer_size);
        if (glyph_id >= self.glyph_count) return error.GlyphNotInFont;

        const design = designGlyphMetrics(self.font_face, glyph_id);
        const advance_x = @as(f32, @floatFromInt(design.advanceWidth)) * self.unitScale(font_size);

        const analysis = try createGlyphRunAnalysis(self.factory, self.font_face, .{
            .glyph_id = glyph_id,
            .size_px = font_size * scale,
            .subpixel_x = subpixel_x,
            .subpixel_y = subpixel_y,
        });
        defer analysis.release();

        var bounds: dw.RECT = undefined;
        const bounds_result = analysis.vtable.GetAlphaTextureBounds(
            analysis,
            dw.DWRITE_TEXTURE_ALIASED_1x1,
            &bounds,
        );
        if (!dw.succeeded(bounds_result)) {
            logFailure("GetAlphaTextureBounds", bounds_result);
            return error.GlyphRasterizeFailed;
        }

        // Spaces and other blank glyphs cover no pixels.
        if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) {
            return .{
                .width = 0,
                .height = 0,
                .offset_x = 0,
                .offset_y = 0,
                .advance_x = advance_x,
                .is_color = false,
            };
        }

        try rasterize(analysis, &bounds, buffer[0..buffer_size], .{
            .glyph_id = glyph_id,
            .size_px = font_size * scale,
        });
        // Bounds are relative to the pen in device pixels, y down; the cache
        // wants the top edge as a height above the baseline.
        return .{
            .width = @intCast(bounds.right - bounds.left),
            .height = @intCast(bounds.bottom - bounds.top),
            .offset_x = bounds.left,
            .offset_y = -bounds.top,
            .advance_x = advance_x,
            .is_color = false,
        };
    }

    /// Design units to logical pixels at `font_size`.
    fn unitScale(self: *const Self, font_size: f32) f32 {
        assert(font_size > 0);
        assert(self.design_units_per_em > 0);
        return font_size / @as(f32, @floatFromInt(self.design_units_per_em));
    }
};

// =============================================================================
// Font discovery
// =============================================================================

/// The family that stands in for a CSS generic name, or `name` itself.
fn familyForGenericName(name: []const u8) []const u8 {
    assert(name.len > 0);
    if (std.ascii.eqlIgnoreCase(name, "monospace")) return family_monospace;
    if (std.ascii.eqlIgnoreCase(name, "serif")) return family_serif;
    if (std.ascii.eqlIgnoreCase(name, "sans-serif")) return family_sans_serif;
    if (std.ascii.eqlIgnoreCase(name, "system-ui")) return family_sans_serif;
    return name;
}

/// A reference to the process-wide shared factory. DirectWrite owns the
/// singleton; each caller holds and releases one reference.
fn createFactory() !*dw.IDWriteFactory2 {
    var factory: ?*anyopaque = null;
    const result = dw.DWriteCreateFactory(
        dw.DWRITE_FACTORY_TYPE_SHARED,
        &dw.IID_IDWriteFactory2,
        &factory,
    );
    if (!dw.succeeded(result)) {
        // IDWriteFactory2 needs Windows 8.1; Gooey supports Windows 10 and later.
        logFailure("DWriteCreateFactory(IDWriteFactory2)", result);
        return error.DirectWriteUnavailable;
    }
    assert(factory != null);
    return @ptrCast(@alignCast(factory.?));
}

/// The font face CSS matching selects for `variant` within `family`, or
/// within Segoe UI when `family` is not installed.
fn createFontFace(
    factory: *dw.IDWriteFactory2,
    family: []const u8,
    variant: FontVariant,
) !*dw.IDWriteFontFace {
    assert(family.len > 0);

    var collection: ?*dw.IDWriteFontCollection = null;
    const collection_result = factory.vtable.GetSystemFontCollection(
        factory,
        &collection,
        dw.FALSE,
    );
    if (!dw.succeeded(collection_result)) {
        logFailure("GetSystemFontCollection", collection_result);
        return error.FontCollectionUnavailable;
    }
    assert(collection != null);
    defer collection.?.release();

    const font_family = try findFamily(collection.?, family);
    defer font_family.release();

    const font = try selectFont(font_family, family, variant);
    defer font.release();

    var font_face: ?*dw.IDWriteFontFace = null;
    const face_result = font.vtable.CreateFontFace(font, &font_face);
    if (!dw.succeeded(face_result)) {
        logFailure("CreateFontFace", face_result);
        return error.FontLoadFailed;
    }
    assert(font_face != null);
    return font_face.?;
}

/// `family` from the collection, or Segoe UI with a warning when `family` is
/// not installed.
fn findFamily(collection: *dw.IDWriteFontCollection, family: []const u8) !*dw.IDWriteFontFamily {
    assert(family.len > 0);
    var index = try findFamilyIndex(collection, family);
    if (index == null) {
        log.warn("font family '{s}' is not installed; using '{s}'", .{
            family,
            family_sans_serif,
        });
        index = try findFamilyIndex(collection, family_sans_serif);
    }
    if (index == null) {
        log.err("font family '{s}' is not installed", .{family_sans_serif});
        return error.FontNotFound;
    }

    var font_family: ?*dw.IDWriteFontFamily = null;
    const result = collection.vtable.GetFontFamily(collection, index.?, &font_family);
    if (!dw.succeeded(result)) {
        logFailure("GetFontFamily", result);
        return error.FontNotFound;
    }
    assert(font_family != null);
    return font_family.?;
}

/// Index of the family named `family` (UTF-8), or null when not installed.
fn findFamilyIndex(collection: *dw.IDWriteFontCollection, family: []const u8) !?u32 {
    assert(family.len > 0);
    if (family.len > family_name_bytes_max) return error.FontNameTooLong;

    var name_utf16: [family_name_bytes_max + 1]u16 = undefined;
    const name_count = std.unicode.utf8ToUtf16Le(&name_utf16, family) catch {
        return error.InvalidFontName;
    };
    assert(name_count <= family.len);
    name_utf16[name_count] = 0;

    var index: u32 = 0;
    var exists: dw.BOOL = dw.FALSE;
    const result = collection.vtable.FindFamilyName(
        collection,
        name_utf16[0..name_count :0],
        &index,
        &exists,
    );
    if (!dw.succeeded(result)) {
        logFailure("FindFamilyName", result);
        return error.FontNotFound;
    }
    return if (exists != dw.FALSE) index else null;
}

/// The face of `font_family` CSS matching picks for `variant`. Simulated
/// faces are skipped: nothing is synthesized, as on the other backends.
fn selectFont(
    font_family: *dw.IDWriteFontFamily,
    family: []const u8,
    variant: FontVariant,
) !*dw.IDWriteFont {
    const listed_count = font_family.vtable.GetFontCount(font_family);
    const considered_count = @min(listed_count, font_match.candidate_count_max);
    if (listed_count > considered_count) {
        log.warn("font family '{s}' lists {d} faces; matching considers the first {d}", .{
            family,
            listed_count,
            considered_count,
        });
    }

    var candidates: [font_match.candidate_count_max]font_match.Candidate = undefined;
    var font_indices: [font_match.candidate_count_max]u32 = undefined;
    var candidate_count: u32 = 0;
    var font_index: u32 = 0;
    while (font_index < considered_count) : (font_index += 1) {
        const font = try familyFont(font_family, font_index);
        defer font.release();

        if (font.vtable.GetSimulations(font) != dw.DWRITE_FONT_SIMULATIONS_NONE) continue;
        candidates[candidate_count] = fontCandidate(font);
        font_indices[candidate_count] = font_index;
        candidate_count += 1;
    }
    assert(candidate_count <= considered_count);

    const index = font_match.select(
        candidates[0..candidate_count],
        variant,
        font_match.stretch_normal,
    ) orelse {
        log.err("font family '{s}' has no unsimulated faces", .{family});
        return error.FontNotFound;
    };
    assert(index < candidate_count);
    warnInexactFace(family, variant, candidates[index]);
    return familyFont(font_family, font_indices[index]);
}

fn familyFont(font_family: *dw.IDWriteFontFamily, index: u32) !*dw.IDWriteFont {
    var font: ?*dw.IDWriteFont = null;
    const result = font_family.vtable.GetFont(font_family, index, &font);
    if (!dw.succeeded(result)) {
        logFailure("GetFont", result);
        return error.FontNotFound;
    }
    assert(font != null);
    return font.?;
}

/// A face's CSS weight, slant, and width. DirectWrite weights are already
/// CSS weights; its nine widths map to CSS `font-stretch` percentages.
fn fontCandidate(font: *dw.IDWriteFont) font_match.Candidate {
    const weight = std.math.clamp(font.vtable.GetWeight(font), 1, 1000);
    const stretch_raw = font.vtable.GetStretch(font);
    const stretch = if (stretch_raw < stretch_percent_by_dwrite_stretch.len)
        stretch_percent_by_dwrite_stretch[stretch_raw]
    else
        font_match.stretch_normal;
    const slant: font_match.Slant = switch (font.vtable.GetStyle(font)) {
        dw.DWRITE_FONT_STYLE_NORMAL => .upright,
        dw.DWRITE_FONT_STYLE_ITALIC => .italic,
        else => .oblique,
    };

    const candidate: font_match.Candidate = .{
        .weight = @intCast(weight),
        .slant = slant,
        .stretch = stretch,
    };
    assert(candidate.stretch >= font_match.stretch_min);
    assert(candidate.stretch <= font_match.stretch_max);
    return candidate;
}

/// Log when the chosen face's weight class or slant differs from the
/// request, so a family without that face does not fall back silently.
fn warnInexactFace(family: []const u8, variant: FontVariant, chosen: font_match.Candidate) void {
    const weight_requested = variant.weight().cssWeight();
    if (font_match.weightClass(chosen.weight) != weight_requested) {
        log.warn("font '{s}' has no {d} face for '{s}'; using weight {d}", .{
            family,
            weight_requested,
            @tagName(variant),
            chosen.weight,
        });
    }
    if (!font_match.slantMatches(chosen.slant, variant.isItalic())) {
        log.warn("font '{s}' has no {s} face for '{s}'; using an {s} face", .{
            family,
            if (variant.isItalic()) "italic" else "upright",
            @tagName(variant),
            @tagName(chosen.slant),
        });
    }
}

// =============================================================================
// Metrics
// =============================================================================

fn computeMetrics(
    font_face: *dw.IDWriteFontFace,
    font_metrics: *const dw.DWRITE_FONT_METRICS,
    size: f32,
) Metrics {
    assert(font_metrics.designUnitsPerEm > 0);
    assert(size > 0);
    const unit_scale = size / @as(f32, @floatFromInt(font_metrics.designUnitsPerEm));

    const ascender = @as(f32, @floatFromInt(font_metrics.ascent)) * unit_scale;
    const descender = @as(f32, @floatFromInt(font_metrics.descent)) * unit_scale;
    // A negative line gap is malformed; CoreText and FreeType report >= 0.
    const line_gap = @as(f32, @floatFromInt(@max(0, font_metrics.lineGap))) * unit_scale;

    const glyph_m = glyphForCodepoint(font_face, 'M');
    const glyph_zero = glyphForCodepoint(font_face, '0');
    const advance_m = designGlyphMetrics(font_face, glyph_m).advanceWidth;
    const advance_zero = designGlyphMetrics(font_face, glyph_zero).advanceWidth;
    const cell_width = @as(f32, @floatFromInt(@max(advance_m, advance_zero))) * unit_scale;
    const underline_position = font_metrics.underlinePosition;
    const underline_thickness = font_metrics.underlineThickness;

    const metrics: Metrics = .{
        .units_per_em = font_metrics.designUnitsPerEm,
        .ascender = ascender,
        .descender = descender,
        .line_gap = line_gap,
        .cap_height = @as(f32, @floatFromInt(font_metrics.capHeight)) * unit_scale,
        .x_height = @as(f32, @floatFromInt(font_metrics.xHeight)) * unit_scale,
        // Positive is above the baseline, as in `Metrics`.
        .underline_position = @as(f32, @floatFromInt(underline_position)) * unit_scale,
        .underline_thickness = @as(f32, @floatFromInt(underline_thickness)) * unit_scale,
        .line_height = ascender + descender + line_gap,
        .point_size = size,
        .is_monospace = isMonospaced(font_face),
        .cell_width = cell_width,
    };
    assert(metrics.ascender >= 0);
    assert(metrics.line_height >= metrics.ascender);
    return metrics;
}

fn glyphForCodepoint(font_face: *dw.IDWriteFontFace, codepoint: u21) u16 {
    const codepoints = [1]u32{codepoint};
    var glyph_ids = [1]u16{0};
    const result = font_face.vtable.GetGlyphIndices(font_face, &codepoints, 1, &glyph_ids);
    // Fails only for invalid arguments; see `DirectWriteFace.glyphIndex`.
    assert(dw.succeeded(result));
    return glyph_ids[0];
}

/// `IsMonospacedFont` lives on `IDWriteFontFace1`, which every face has on
/// the Windows releases that provide `IDWriteFactory2`.
fn isMonospaced(font_face: *dw.IDWriteFontFace) bool {
    var face1: ?*anyopaque = null;
    const result = font_face.vtable.QueryInterface(font_face, &dw.IID_IDWriteFontFace1, &face1);
    if (!dw.succeeded(result)) {
        logFailure("QueryInterface(IDWriteFontFace1)", result);
        return false;
    }
    assert(face1 != null);
    const font_face1: *dw.IDWriteFontFace1 = @ptrCast(@alignCast(face1.?));
    defer font_face1.release();
    return font_face1.vtable.IsMonospacedFont(font_face1) != dw.FALSE;
}

/// Design metrics for a glyph id the caller has checked against the font.
fn designGlyphMetrics(font_face: *dw.IDWriteFontFace, glyph_id: u16) dw.DWRITE_GLYPH_METRICS {
    const glyph_ids = [1]u16{glyph_id};
    var design: [1]dw.DWRITE_GLYPH_METRICS = undefined;
    const result = font_face.vtable.GetDesignGlyphMetrics(
        font_face,
        &glyph_ids,
        1,
        &design,
        dw.FALSE,
    );
    // Fails only for a glyph id outside the font, which callers rule out.
    assert(dw.succeeded(result));
    return design[0];
}

fn scaleGlyphMetrics(
    glyph_id: u16,
    design: *const dw.DWRITE_GLYPH_METRICS,
    unit_scale: f32,
) GlyphMetrics {
    assert(unit_scale > 0);
    // Ink box from the bearings: advance minus both side bearings. Signed
    // 64-bit so negative bearings cannot overflow.
    const advance_width: i64 = design.advanceWidth;
    const advance_height: i64 = design.advanceHeight;
    const ink_width = advance_width - design.leftSideBearing - design.rightSideBearing;
    const ink_height = advance_height - design.topSideBearing - design.bottomSideBearing;
    const ink_top = @as(i64, design.verticalOriginY) - design.topSideBearing;

    const metrics: GlyphMetrics = .{
        .glyph_id = glyph_id,
        .advance_x = @as(f32, @floatFromInt(advance_width)) * unit_scale,
        .advance_y = 0,
        .bearing_x = @as(f32, @floatFromInt(design.leftSideBearing)) * unit_scale,
        .bearing_y = @as(f32, @floatFromInt(ink_top)) * unit_scale,
        .width = @as(f32, @floatFromInt(@max(0, ink_width))) * unit_scale,
        .height = @as(f32, @floatFromInt(@max(0, ink_height))) * unit_scale,
    };
    assert(metrics.advance_x >= 0);
    assert(metrics.width >= 0);
    return metrics;
}

// =============================================================================
// Rasterization
// =============================================================================

const GlyphRunOptions = struct {
    glyph_id: u16,
    /// Em size in device pixels.
    size_px: f32,
    subpixel_x: f32,
    subpixel_y: f32,
};

/// Grayscale, unhinted analysis of one glyph. Symmetric antialiasing with
/// grid fitting disabled keeps the outline faithful to the subpixel origin,
/// which the cache relies on to tell its subpixel variants apart.
fn createGlyphRunAnalysis(
    factory: *dw.IDWriteFactory2,
    font_face: *dw.IDWriteFontFace,
    options: GlyphRunOptions,
) !*dw.IDWriteGlyphRunAnalysis {
    assert(options.size_px > 0);
    assert(options.subpixel_x >= 0);

    const glyph_ids = [1]u16{options.glyph_id};
    const glyph_advances = [1]f32{0};
    const glyph_run: dw.DWRITE_GLYPH_RUN = .{
        .fontFace = font_face,
        .fontEmSize = options.size_px,
        .glyphCount = 1,
        .glyphIndices = &glyph_ids,
        .glyphAdvances = &glyph_advances,
        .glyphOffsets = null,
        .isSideways = dw.FALSE,
        .bidiLevel = 0,
    };

    var analysis: ?*dw.IDWriteGlyphRunAnalysis = null;
    const result = factory.vtable.CreateGlyphRunAnalysis2(
        factory,
        &glyph_run,
        null,
        dw.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
        dw.DWRITE_MEASURING_MODE_NATURAL,
        dw.DWRITE_GRID_FIT_MODE_DISABLED,
        dw.DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE,
        options.subpixel_x,
        // DirectWrite's y axis points down; `subpixel_y` raises the glyph.
        -options.subpixel_y,
        &analysis,
    );
    if (!dw.succeeded(result)) {
        logFailure("CreateGlyphRunAnalysis", result);
        return error.GlyphRasterizeFailed;
    }
    assert(analysis != null);
    return analysis.?;
}

const RasterizeContext = struct {
    glyph_id: u16,
    size_px: f32,
};

/// Write `bounds`' coverage into `target` as packed rows of `width` bytes.
fn rasterize(
    analysis: *dw.IDWriteGlyphRunAnalysis,
    bounds: *const dw.RECT,
    target: []u8,
    context: RasterizeContext,
) !void {
    assert(bounds.right > bounds.left);
    assert(bounds.bottom > bounds.top);
    const width: u32 = @intCast(bounds.right - bounds.left);
    const height: u32 = @intCast(bounds.bottom - bounds.top);
    if (width > limits.MAX_GLYPH_SIZE or height > limits.MAX_GLYPH_SIZE) {
        log.warn(
            "glyph {d} at {d:.1} px is {d}x{d} device pixels; MAX_GLYPH_SIZE is {d}",
            .{ context.glyph_id, context.size_px, width, height, limits.MAX_GLYPH_SIZE },
        );
        return error.GlyphTooLarge;
    }

    const byte_count = width * height;
    assert(byte_count <= target.len);
    const result = analysis.vtable.CreateAlphaTexture(
        analysis,
        dw.DWRITE_TEXTURE_ALIASED_1x1,
        bounds,
        target.ptr,
        byte_count,
    );
    if (!dw.succeeded(result)) {
        logFailure("CreateAlphaTexture", result);
        return error.GlyphRasterizeFailed;
    }
}

fn logFailure(operation: []const u8, result: dw.HRESULT) void {
    assert(!dw.succeeded(result));
    log.err("DirectWrite {s} failed: HRESULT 0x{X:0>8}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
}
