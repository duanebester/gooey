//! FreeType font face implementation
//!
//! Implements the FontFace interface using FreeType for glyph rasterization
//! and Fontconfig for font discovery on Linux.

const std = @import("std");
const ft = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");
const font_match = @import("../../font_match.zig");

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
const FontVariant = types.FontVariant;
const FontFace = font_face_mod.FontFace;

/// Global FreeType library instance (initialized once)
var global_ft_library: ?ft.FT_Library = null;
var library_init_error: ?ft.FT_Error = null;

/// Initialize the global FreeType library
fn ensureLibraryInit() !ft.FT_Library {
    if (global_ft_library) |lib| return lib;
    if (library_init_error) |err| {
        std.log.err("FreeType library init failed: {s}", .{ft.ftErrorString(err)});
        return error.FreeTypeInitFailed;
    }

    var lib: ft.FT_Library = undefined;
    const err = ft.FT_Init_FreeType(&lib);
    if (err != 0) {
        library_init_error = err;
        std.log.err("FreeType init error: {s}", .{ft.ftErrorString(err)});
        return error.FreeTypeInitFailed;
    }

    global_ft_library = lib;
    return lib;
}

/// Maximum glyph ID for advance cache (covers most fonts)
const ADVANCE_CACHE_SIZE: usize = 4096;
/// Sentinel value for uncached advances
const ADVANCE_UNCACHED: f32 = -1.0;

/// FreeType-backed font face
pub const FreeTypeFace = struct {
    /// FreeType face handle
    ft_face: ft.FT_Face,
    /// HarfBuzz font (paired with FT_Face for shaping)
    hb_font: *ft.hb_font_t,
    /// Cached metrics
    metrics: Metrics,
    /// Font size in points
    point_size: f32,
    /// Font file path (for debugging)
    font_path_buf: [512]u8,
    font_path_len: usize,
    /// Glyph advance cache - avoids expensive FT_Load_Glyph calls during measurement
    /// Index by glyph_id, stores advance_x. ADVANCE_UNCACHED means not yet loaded.
    advance_cache: [ADVANCE_CACHE_SIZE]f32,

    const Self = @This();

    /// Load one variant of a family by name using Fontconfig.
    ///
    /// Selection: Fontconfig resolves `name` to an installed family, then the
    /// family's real faces are listed and `font_match.select` picks one by the
    /// CSS font matching rule. Fallback policy: nothing is synthesized. A
    /// family without the requested weight or slant renders with the face CSS
    /// matching picks, and init logs a warning naming the request and the face.
    pub fn init(name: []const u8, size: f32, variant: FontVariant) !Self {
        const library = try ensureLibraryInit();

        const font_path = try findFontPath(name, null, variant) orelse {
            std.log.err("Font not found: {s} ({s})", .{ name, @tagName(variant) });
            return error.FontNotFound;
        };
        return initFromPath(library, &font_path, size);
    }

    /// Load one variant of a system family, with the same policy as `init`.
    pub fn initSystem(style: SystemFont, size: f32, variant: FontVariant) !Self {
        const library = try ensureLibraryInit();

        // Map system font style to Fontconfig pattern
        const family = switch (style) {
            .monospace => "monospace",
            .sans_serif => "sans-serif",
            .serif => "serif",
            .system => "sans-serif",
        };

        const spacing: ?c_int = switch (style) {
            .monospace => ft.FC_MONO,
            else => null,
        };

        const font_path = try findFontPath(family, spacing, variant) orelse {
            std.log.err("System font not found: {s} ({s})", .{ family, @tagName(variant) });
            return error.FontNotFound;
        };
        return initFromPath(library, &font_path, size);
    }

    const FontPathResult = struct {
        path_buf: [512]u8,
        path_len: usize,
        /// Face index within the file: a collection member, or a named
        /// instance of a variable font (Fontconfig encodes both in `FC_INDEX`).
        face_index: c_int,

        pub fn pathSlice(self: *const FontPathResult) [:0]const u8 {
            return self.path_buf[0..self.path_len :0];
        }
    };

    /// Resolve `family` to an installed family, then pick the variant's face
    /// from that family's face list. Falls back to Fontconfig's own match only
    /// when the list is empty, which a family Fontconfig just matched cannot
    /// normally produce.
    fn findFontPath(family: []const u8, spacing: ?c_int, variant: FontVariant) !?FontPathResult {
        std.debug.assert(family.len > 0);

        const matched = try matchFamily(family, spacing) orelse return null;
        defer ft.FcPatternDestroy(matched);

        var resolved_family: ?[*:0]const ft.FcChar8 = null;
        if (ft.FcPatternGetString(matched, ft.FC_FAMILY, 0, &resolved_family) != .FcResultMatch) {
            resolved_family = null;
        }

        // Keep the resolved face's width, so a condensed family stays condensed.
        const matched_candidate = faceCandidate(matched);
        const stretch = if (matched_candidate) |c| c.stretch else font_match.stretch_normal;

        if (resolved_family) |resolved| {
            const font_set = try listFamilyFaces(resolved, spacing);
            defer ft.FcFontSetDestroy(font_set);

            if (try selectFace(font_set, variant, stretch)) |selection| {
                warnInexactFace(family, variant, selection.candidate);
                return selection.path;
            }
        }

        const result = try copyFontPath(matched) orelse return null;
        if (matched_candidate) |candidate| warnInexactFace(family, variant, candidate);
        return result;
    }

    /// Fontconfig's best match for the family alone (weight and slant left at
    /// their defaults), which resolves generic names like "sans-serif".
    fn matchFamily(family: []const u8, spacing: ?c_int) !?*ft.FcPattern {
        const pattern = ft.FcPatternCreate() orelse return error.FontconfigError;
        defer ft.FcPatternDestroy(pattern);

        var family_buf: [256]u8 = undefined;
        if (family.len >= family_buf.len) return error.FontNameTooLong;
        @memcpy(family_buf[0..family.len], family);
        family_buf[family.len] = 0;

        _ = ft.FcPatternAddString(pattern, ft.FC_FAMILY, family_buf[0..family.len :0]);
        _ = ft.FcPatternAddBool(pattern, ft.FC_SCALABLE, 1);
        if (spacing) |sp| {
            _ = ft.FcPatternAddInteger(pattern, ft.FC_SPACING, sp);
        }

        _ = ft.FcConfigSubstitute(null, pattern, .FcMatchPattern);
        ft.FcDefaultSubstitute(pattern);

        var fc_result: ft.FcResult = undefined;
        const matched = ft.FcFontMatch(null, pattern, &fc_result) orelse return null;
        if (fc_result != .FcResultMatch) {
            ft.FcPatternDestroy(matched);
            return null;
        }
        return matched;
    }

    /// Every scalable face of one family, with the properties selection needs.
    /// Listing bypasses Fontconfig's synthetic-style rules, so each face
    /// reports its real weight and slant. The caller destroys the set.
    fn listFamilyFaces(family: [*:0]const ft.FcChar8, spacing: ?c_int) !*ft.FcFontSet {
        const pattern = ft.FcPatternCreate() orelse return error.FontconfigError;
        defer ft.FcPatternDestroy(pattern);

        _ = ft.FcPatternAddString(pattern, ft.FC_FAMILY, family);
        _ = ft.FcPatternAddBool(pattern, ft.FC_SCALABLE, 1);
        if (spacing) |sp| {
            _ = ft.FcPatternAddInteger(pattern, ft.FC_SPACING, sp);
        }

        const object_set = ft.FcObjectSetCreate() orelse return error.FontconfigError;
        defer ft.FcObjectSetDestroy(object_set);

        const objects = [_][*:0]const u8{
            ft.FC_FILE,
            ft.FC_INDEX,
            ft.FC_WEIGHT,
            ft.FC_SLANT,
            ft.FC_WIDTH,
        };
        for (objects) |object| {
            if (ft.FcObjectSetAdd(object_set, object) == 0) return error.FontconfigError;
        }

        const font_set = ft.FcFontList(null, pattern, object_set) orelse {
            return error.FontconfigError;
        };
        std.debug.assert(font_set.nfont >= 0);
        return font_set;
    }

    const FaceSelection = struct {
        path: FontPathResult,
        candidate: font_match.Candidate,
    };

    /// The face of `font_set` CSS matching picks for `variant`, or null when
    /// no listed face has a usable weight and slant.
    fn selectFace(
        font_set: *const ft.FcFontSet,
        variant: FontVariant,
        stretch: u16,
    ) !?FaceSelection {
        const listed_count: u32 = @intCast(font_set.nfont);
        const considered_count = @min(listed_count, font_match.candidate_count_max);
        if (listed_count > considered_count) {
            std.log.warn("font family lists {d} faces; matching considers the first {d}", .{
                listed_count,
                considered_count,
            });
        }

        var candidates: [font_match.candidate_count_max]font_match.Candidate = undefined;
        var patterns: [font_match.candidate_count_max]*ft.FcPattern = undefined;
        var candidate_count: u32 = 0;
        for (font_set.fonts[0..considered_count]) |pattern| {
            // A variable font's default instance reports a weight range; its
            // named instances are listed separately with single weights.
            const candidate = faceCandidate(pattern) orelse continue;
            candidates[candidate_count] = candidate;
            patterns[candidate_count] = pattern;
            candidate_count += 1;
        }
        std.debug.assert(candidate_count <= considered_count);

        const index = font_match.select(candidates[0..candidate_count], variant, stretch) orelse {
            return null;
        };
        std.debug.assert(index < candidate_count);
        const path = try copyFontPath(patterns[index]) orelse return null;
        return .{ .path = path, .candidate = candidates[index] };
    }

    /// A face's CSS weight, slant, and width, or null when the weight or slant
    /// is missing or a range. A missing or ranged width counts as normal.
    fn faceCandidate(pattern: *ft.FcPattern) ?font_match.Candidate {
        var fc_weight: c_int = 0;
        if (ft.FcPatternGetInteger(pattern, ft.FC_WEIGHT, 0, &fc_weight) != .FcResultMatch) {
            return null;
        }
        var fc_slant: c_int = 0;
        if (ft.FcPatternGetInteger(pattern, ft.FC_SLANT, 0, &fc_slant) != .FcResultMatch) {
            return null;
        }

        // Fontconfig widths are already CSS `font-stretch` percentages.
        var fc_width: c_int = font_match.stretch_normal;
        if (ft.FcPatternGetInteger(pattern, ft.FC_WIDTH, 0, &fc_width) != .FcResultMatch) {
            fc_width = font_match.stretch_normal;
        }
        const stretch = std.math.clamp(fc_width, font_match.stretch_min, font_match.stretch_max);

        const css_weight = std.math.clamp(ft.FcWeightToOpenType(fc_weight), 1, 1000);
        const slant: font_match.Slant = switch (fc_slant) {
            ft.FC_SLANT_ROMAN => .upright,
            ft.FC_SLANT_ITALIC => .italic,
            else => .oblique,
        };
        const candidate: font_match.Candidate = .{
            .weight = @intCast(css_weight),
            .slant = slant,
            .stretch = @intCast(stretch),
        };
        std.debug.assert(candidate.weight >= 1);
        std.debug.assert(candidate.weight <= 1000);
        return candidate;
    }

    /// Copy a pattern's file path and face index out before it is destroyed.
    fn copyFontPath(pattern: *ft.FcPattern) !?FontPathResult {
        var file_path: ?[*:0]const ft.FcChar8 = null;
        const path_result = ft.FcPatternGetString(pattern, ft.FC_FILE, 0, &file_path);
        if (path_result != .FcResultMatch or file_path == null) {
            return null;
        }

        var face_index: c_int = 0;
        if (ft.FcPatternGetInteger(pattern, ft.FC_INDEX, 0, &face_index) != .FcResultMatch) {
            face_index = 0;
        }
        std.debug.assert(face_index >= 0);

        const path = std.mem.span(file_path.?);
        if (path.len >= 511) return error.FontPathTooLong;

        var font_result = FontPathResult{
            .path_buf = undefined,
            .path_len = path.len,
            .face_index = face_index,
        };
        @memcpy(font_result.path_buf[0..path.len], path);
        font_result.path_buf[path.len] = 0;
        std.debug.assert(font_result.pathSlice().len == path.len);
        return font_result;
    }

    /// Log when the chosen face's weight class or slant differs from the
    /// request, so a family without that face does not fall back silently.
    fn warnInexactFace(
        family: []const u8,
        variant: FontVariant,
        chosen: font_match.Candidate,
    ) void {
        const weight_requested = variant.weight().cssWeight();
        const weight_class = font_match.weightClass(chosen.weight);
        if (weight_class != weight_requested) {
            std.log.warn("font '{s}' has no {d} face for '{s}'; using weight {d}", .{
                family,
                weight_requested,
                @tagName(variant),
                chosen.weight,
            });
        }
        if (!font_match.slantMatches(chosen.slant, variant.isItalic())) {
            std.log.warn("font '{s}' has no {s} face for '{s}'; using an {s} face", .{
                family,
                if (variant.isItalic()) "italic" else "upright",
                @tagName(variant),
                @tagName(chosen.slant),
            });
        }
    }

    fn initFromPath(library: ft.FT_Library, font_path: *const FontPathResult, size: f32) !Self {
        const path = font_path.pathSlice();
        const path_len = font_path.path_len;
        var ft_face: ft.FT_Face = undefined;
        const err = ft.FT_New_Face(library, path.ptr, font_path.face_index, &ft_face);
        if (err != 0) {
            std.log.err("FreeType face load error: {s}", .{ft.ftErrorString(err)});
            return error.FontLoadFailed;
        }
        errdefer _ = ft.FT_Done_Face(ft_face);

        // Set character size (in 1/64th points at 72 DPI for 1:1 point-to-pixel)
        // Using 96 DPI is more common on Linux
        const size_f26d6 = ft.floatToF26dot6(size);
        const size_err = ft.FT_Set_Char_Size(ft_face, 0, size_f26d6, 96, 96);
        if (size_err != 0) {
            std.log.err("FreeType set size error: {s}", .{ft.ftErrorString(size_err)});
            return error.FontSizeError;
        }

        // Create HarfBuzz font from FreeType face
        const hb_font = ft.hb_ft_font_create_referenced(ft_face) orelse {
            return error.HarfBuzzError;
        };
        errdefer ft.hb_font_destroy(hb_font);

        // Set up HarfBuzz to use FreeType functions
        ft.hb_ft_font_set_funcs(hb_font);

        var self = Self{
            .ft_face = ft_face,
            .hb_font = hb_font,
            .metrics = undefined,
            .point_size = size,
            .font_path_buf = undefined,
            .font_path_len = @min(path_len, 511),
            .advance_cache = @as([ADVANCE_CACHE_SIZE]f32, @splat(ADVANCE_UNCACHED)),
        };

        // Store path for debugging
        @memcpy(self.font_path_buf[0..self.font_path_len], path[0..self.font_path_len]);
        self.font_path_buf[self.font_path_len] = 0;

        // Compute metrics
        self.metrics = computeMetrics(ft_face, size);

        return self;
    }

    pub fn deinit(self: *Self) void {
        ft.hb_font_destroy(self.hb_font);
        _ = ft.FT_Done_Face(self.ft_face);
        self.* = undefined;
    }

    /// Get as the generic FontFace interface
    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    /// Get glyph ID for a Unicode codepoint
    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        const glyph_idx = ft.FT_Get_Char_Index(self.ft_face, @intCast(codepoint));
        return @intCast(glyph_idx);
    }

    /// Get advance width for a glyph (fast path for text measurement)
    /// Uses cached value if available, otherwise loads and caches
    pub fn glyphAdvance(self: *Self, glyph_id: u16) f32 {
        // Check cache first (fast path)
        if (glyph_id < ADVANCE_CACHE_SIZE) {
            const cached = self.advance_cache[glyph_id];
            if (cached != ADVANCE_UNCACHED) {
                return cached;
            }
        }

        // Cache miss - load glyph with minimal work (no hinting, no bitmap)
        const err = ft.FT_Load_Glyph(self.ft_face, glyph_id, ft.FT_LOAD_NO_HINTING | ft.FT_LOAD_NO_BITMAP);
        if (err != 0) {
            return 0;
        }

        const advance = ft.f26dot6ToFloat(self.ft_face.glyph.metrics.horiAdvance);

        // Cache for future lookups
        if (glyph_id < ADVANCE_CACHE_SIZE) {
            // Cast away const for caching (cache is logically mutable even on const self)
            const mutable_self = @constCast(self);
            mutable_self.advance_cache[glyph_id] = advance;
        }

        return advance;
    }

    /// Get metrics for a specific glyph (full metrics, slower path)
    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        // Load glyph without rendering (just get metrics)
        const err = ft.FT_Load_Glyph(self.ft_face, glyph_id, ft.FT_LOAD_DEFAULT);
        if (err != 0) {
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

        const slot = self.ft_face.glyph;
        const m = slot.metrics;
        const advance_x = ft.f26dot6ToFloat(m.horiAdvance);

        // Update advance cache while we have it
        if (glyph_id < ADVANCE_CACHE_SIZE) {
            const mutable_self = @constCast(self);
            mutable_self.advance_cache[glyph_id] = advance_x;
        }

        // Convert from 26.6 fixed-point to float
        return .{
            .glyph_id = glyph_id,
            .advance_x = advance_x,
            .advance_y = ft.f26dot6ToFloat(m.vertAdvance),
            .bearing_x = ft.f26dot6ToFloat(m.horiBearingX),
            .bearing_y = ft.f26dot6ToFloat(m.horiBearingY),
            .width = ft.f26dot6ToFloat(m.width),
            .height = ft.f26dot6ToFloat(m.height),
        };
    }

    /// Render a glyph with subpixel positioning
    /// subpixel_x and subpixel_y are in range [0.0, 1.0)
    ///
    /// Uses FreeType's native bitmap output with its positioning values.
    /// offset_x = bitmap_left (horizontal offset from pen to left edge)
    /// offset_y = bitmap_top (vertical offset from baseline to top edge, positive = above)
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

        return renderGlyphInternal(
            self.ft_face,
            glyph_id,
            font_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    /// Render a glyph from any FT_Face (for fallback fonts)
    /// This is a static method that can render glyphs from fonts not owned by this face
    pub fn renderGlyphFromFont(
        ft_face: ft.FT_Face,
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

        return renderGlyphInternal(
            ft_face,
            glyph_id,
            font_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    fn computeMetrics(face: ft.FT_Face, size: f32) Metrics {
        const size_metrics = face.size.metrics;

        // Convert from 26.6 fixed-point
        const ascender = ft.f26dot6ToFloat(size_metrics.ascender);
        const descender = -ft.f26dot6ToFloat(size_metrics.descender); // FreeType descender is negative
        const height = ft.f26dot6ToFloat(size_metrics.height);
        const line_gap = height - ascender - descender;

        // Get x-height and cap-height from OS/2 table if available
        // Fall back to estimates based on ascender
        var x_height = ascender * 0.5;
        var cap_height = ascender * 0.7;

        // Try to get 'x' and 'H' metrics for better estimates
        const x_glyph = ft.FT_Get_Char_Index(face, 'x');
        if (x_glyph != 0) {
            if (ft.FT_Load_Glyph(face, x_glyph, ft.FT_LOAD_DEFAULT) == 0) {
                x_height = ft.f26dot6ToFloat(face.glyph.metrics.height);
            }
        }

        const h_glyph = ft.FT_Get_Char_Index(face, 'H');
        if (h_glyph != 0) {
            if (ft.FT_Load_Glyph(face, h_glyph, ft.FT_LOAD_DEFAULT) == 0) {
                cap_height = ft.f26dot6ToFloat(face.glyph.metrics.height);
            }
        }

        // Underline metrics (from face, need scaling)
        const scale_factor = size / @as(f32, @floatFromInt(face.units_per_EM));
        const underline_position = @as(f32, @floatFromInt(face.underline_position)) * scale_factor;
        const underline_thickness = @max(1.0, @as(f32, @floatFromInt(face.underline_thickness)) * scale_factor);

        // Cell width for monospace (check 'M' and '0')
        var cell_width: f32 = 0;
        const m_glyph = ft.FT_Get_Char_Index(face, 'M');
        if (m_glyph != 0) {
            if (ft.FT_Load_Glyph(face, m_glyph, ft.FT_LOAD_DEFAULT) == 0) {
                cell_width = ft.f26dot6ToFloat(face.glyph.metrics.horiAdvance);
            }
        }

        const zero_glyph = ft.FT_Get_Char_Index(face, '0');
        if (zero_glyph != 0) {
            if (ft.FT_Load_Glyph(face, zero_glyph, ft.FT_LOAD_DEFAULT) == 0) {
                const zero_advance = ft.f26dot6ToFloat(face.glyph.metrics.horiAdvance);
                cell_width = @max(cell_width, zero_advance);
            }
        }

        return .{
            .units_per_em = face.units_per_EM,
            .ascender = ascender,
            .descender = descender,
            .line_gap = line_gap,
            .cap_height = cap_height,
            .x_height = x_height,
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
            .line_height = height,
            .point_size = size,
            .is_monospace = ft.isMonospace(face),
            .cell_width = cell_width,
        };
    }
};

// =============================================================================
// Shared Internal Functions
// =============================================================================

/// Internal glyph rendering implementation shared by both public methods
fn renderGlyphInternal(
    ft_face: ft.FT_Face,
    glyph_id: u16,
    point_size: f32,
    scale: f32,
    subpixel_x: f32,
    subpixel_y: f32,
    buffer: []u8,
    buffer_size: u32,
) !RasterizedGlyph {
    _ = buffer_size;

    // Assertions for input validation
    std.debug.assert(scale > 0);
    std.debug.assert(point_size > 0);

    // Apply subpixel offset via FT_Set_Transform
    const subpixel_offset_x = ft.floatToF26dot6(subpixel_x * scale);
    const subpixel_offset_y = ft.floatToF26dot6(subpixel_y * scale);

    const delta = ft.FT_Vector{
        .x = subpixel_offset_x,
        .y = subpixel_offset_y,
    };

    ft.FT_Set_Transform(ft_face, null, &delta);

    // Set scaled size for rendering (point_size * scale = physical pixels)
    const scaled_size = point_size * scale;
    const size_f26d6 = ft.floatToF26dot6(scaled_size);
    _ = ft.FT_Set_Char_Size(ft_face, 0, size_f26d6, 96, 96);

    // Load the glyph at scaled size to get correct metrics
    var load_flags = ft.FT_LOAD_DEFAULT;
    if (ft.hasColor(ft_face)) {
        load_flags |= ft.FT_LOAD_COLOR;
    }

    const load_err = ft.FT_Load_Glyph(ft_face, glyph_id, load_flags);
    if (load_err != 0) {
        ft.FT_Set_Transform(ft_face, null, null);
        _ = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size), 96, 96);
        return error.GlyphLoadFailed;
    }

    const slot = ft_face.glyph;

    // Get metrics from the scaled glyph, then convert advance back to logical units
    const scaled_advance = ft.f26dot6ToFloat(slot.metrics.horiAdvance);
    const advance_x = scaled_advance / scale;
    const width_f = ft.f26dot6ToFloat(slot.metrics.width);
    const height_f = ft.f26dot6ToFloat(slot.metrics.height);

    // Handle empty glyphs (spaces, etc.)
    if (width_f < 1 or height_f < 1) {
        ft.FT_Set_Transform(ft_face, null, null);
        _ = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size), 96, 96);
        return RasterizedGlyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .advance_x = advance_x,
            .is_color = false,
        };
    }

    // Render to bitmap if not already
    if (slot.format != .FT_GLYPH_FORMAT_BITMAP) {
        const render_err = ft.FT_Render_Glyph(slot, .FT_RENDER_MODE_NORMAL);
        if (render_err != 0) {
            ft.FT_Set_Transform(ft_face, null, null);
            _ = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size), 96, 96);
            return error.GlyphRenderFailed;
        }
    }

    // Reset transform for future operations
    ft.FT_Set_Transform(ft_face, null, null);
    _ = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size), 96, 96);

    const bitmap = slot.bitmap;
    const width = bitmap.width;
    const height = bitmap.rows;
    const is_color = bitmap.pixel_mode == .FT_PIXEL_MODE_BGRA;

    std.debug.assert(width <= 256); // Reasonable glyph size limit
    std.debug.assert(height <= 256);

    // Copy bitmap to output buffer
    if (width > 0 and height > 0) {
        const src_pitch: usize = if (bitmap.pitch < 0)
            @intCast(-bitmap.pitch)
        else
            @intCast(bitmap.pitch);

        const bytes_per_pixel: usize = if (is_color) 4 else 1;
        const dst_pitch = width * bytes_per_pixel;

        var y: usize = 0;
        while (y < height) : (y += 1) {
            const src_row = bitmap.buffer + y * src_pitch;
            const dst_row = buffer.ptr + y * dst_pitch;

            if (is_color) {
                @memcpy(dst_row[0 .. width * 4], src_row[0 .. width * 4]);
            } else {
                @memcpy(dst_row[0..width], src_row[0..width]);
            }
        }
    }

    // Use FreeType's native bitmap positioning
    // bitmap_left: horizontal offset from pen position to left edge of bitmap
    // bitmap_top: vertical offset from baseline to top edge of bitmap (positive = above)
    return RasterizedGlyph{
        .width = width,
        .height = height,
        .offset_x = slot.bitmap_left,
        .offset_y = slot.bitmap_top,
        .advance_x = advance_x,
        .is_color = is_color,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "load system font" {
    var face = try FreeTypeFace.initSystem(.monospace, 14.0, .regular);
    defer face.deinit();

    try std.testing.expect(face.metrics.ascender > 0);
    try std.testing.expect(face.metrics.line_height > 0);
}
