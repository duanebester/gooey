//! FreeType font face implementation
//!
//! Implements the FontFace interface using FreeType for glyph rasterization
//! and Fontconfig for font discovery on Linux.

const std = @import("std");
const ft = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
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

    /// Load a font by name using Fontconfig
    pub fn init(name: []const u8, size: f32) !Self {
        const library = try ensureLibraryInit();

        // Use Fontconfig to find the font file
        var font_path = try findFontPath(name, null) orelse {
            std.log.err("Font not found: {s}", .{name});
            return error.FontNotFound;
        };

        return initFromPath(library, font_path.pathSlice(), font_path.path_len, size);
    }

    /// Load a system font
    pub fn initSystem(style: SystemFont, size: f32) !Self {
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

        var font_path = try findFontPath(family, spacing) orelse {
            std.log.err("System font not found: {s}", .{family});
            return error.FontNotFound;
        };

        return initFromPath(library, font_path.pathSlice(), font_path.path_len, size);
    }

    const FontPathResult = struct {
        path_buf: [512]u8,
        path_len: usize,

        pub fn pathSlice(self: *const FontPathResult) [:0]const u8 {
            return self.path_buf[0..self.path_len :0];
        }
    };

    fn findFontPath(family: []const u8, spacing: ?c_int) !?FontPathResult {
        // Create Fontconfig pattern
        const pattern = ft.FcPatternCreate() orelse return error.FontconfigError;
        defer ft.FcPatternDestroy(pattern);

        // Add family name
        var family_buf: [256]u8 = undefined;
        if (family.len >= family_buf.len) return error.FontNameTooLong;
        @memcpy(family_buf[0..family.len], family);
        family_buf[family.len] = 0;

        _ = ft.FcPatternAddString(pattern, ft.FC_FAMILY, family_buf[0..family.len :0]);

        // Request scalable fonts
        _ = ft.FcPatternAddBool(pattern, ft.FC_SCALABLE, 1);

        // Add spacing constraint for monospace
        if (spacing) |sp| {
            _ = ft.FcPatternAddInteger(pattern, ft.FC_SPACING, sp);
        }

        // Apply default substitutions
        _ = ft.FcConfigSubstitute(null, pattern, .FcMatchPattern);
        ft.FcDefaultSubstitute(pattern);

        // Find best match
        var fc_result: ft.FcResult = undefined;
        const matched = ft.FcFontMatch(null, pattern, &fc_result) orelse {
            return null;
        };
        defer ft.FcPatternDestroy(matched);

        if (fc_result != .FcResultMatch) {
            return null;
        }

        // Get file path from matched pattern
        var file_path: ?[*:0]const ft.FcChar8 = null;
        const path_result = ft.FcPatternGetString(matched, ft.FC_FILE, 0, &file_path);

        if (path_result != .FcResultMatch or file_path == null) {
            return null;
        }

        // Calculate length
        var len: usize = 0;
        while (file_path.?[len] != 0) : (len += 1) {}

        // Copy path before pattern is destroyed (defer above)
        if (len >= 511) return error.FontPathTooLong;

        var font_result = FontPathResult{
            .path_buf = undefined,
            .path_len = len,
        };
        @memcpy(font_result.path_buf[0..len], file_path.?[0..len]);
        font_result.path_buf[len] = 0;

        return font_result;
    }

    fn initFromPath(library: ft.FT_Library, path: [:0]const u8, path_len: usize, size: f32) !Self {
        var ft_face: ft.FT_Face = undefined;
        const err = ft.FT_New_Face(library, path.ptr, 0, &ft_face);
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
            .advance_cache = [_]f32{ADVANCE_UNCACHED} ** ADVANCE_CACHE_SIZE,
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
    var face = try FreeTypeFace.initSystem(.monospace, 14.0);
    defer face.deinit();

    try std.testing.expect(face.metrics.ascender > 0);
    try std.testing.expect(face.metrics.line_height > 0);
}
