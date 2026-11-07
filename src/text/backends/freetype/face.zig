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

/// Cap on faces opened per primary face for character fallback. Text mixing
/// more than this many scripts/emoji in one font's gaps is extremely rare;
/// codepoints beyond it shape as .notdef.
const MAX_OPEN_FALLBACK_FACES: usize = 8;

/// Minimal spin mutex. `std.Thread.Mutex` no longer exists in Zig 0.17 and
/// `std.Io.Mutex` needs an `Io` handle this backend does not carry; the
/// critical sections (one hash lookup or one FT_Load_Glyph) are short and
/// contention only arises when multiple windows shape fallback text at once.
const SpinMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinMutex) void {
        while (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

/// A face opened on demand to cover characters the primary face lacks.
const FallbackFace = struct {
    ft_face: ft.FT_Face,
    /// Face carries color glyphs (emoji); its bitmaps raster as BGRA.
    is_color: bool,
};

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
    /// Allocator for fallback state. The freetype backend links libc, so the
    /// C allocator is always available here.
    allocator: std.mem.Allocator,
    /// Faces opened on demand for characters the primary face lacks.
    fallback_faces: std.ArrayList(FallbackFace) = .empty,
    /// Resolved per-codepoint fallback: index into `fallback_faces`, or null
    /// when no installed font covers the codepoint (avoids re-querying
    /// Fontconfig for every frame).
    fallback_map: std.AutoHashMapUnmanaged(u21, ?u32) = .empty,
    /// Serializes fallback lookups; shaping may run on several threads.
    fallback_mutex: SpinMutex = .{},

    const Self = @This();

    /// Load a font by name using Fontconfig
    pub fn init(name: []const u8, size: f32) !Self {
        const library = try ensureLibraryInit();

        // Use Fontconfig to find the font file
        var font_path = try findFontPath(name, null) orelse {
            std.log.err("Font not found: {s}", .{name});
            return error.FontNotFound;
        };

        return initFromPath(library, font_path.pathSlice(), font_path.path_len, font_path.face_index, size);
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

        return initFromPath(library, font_path.pathSlice(), font_path.path_len, font_path.face_index, size);
    }

    const FontPathResult = struct {
        path_buf: [512]u8,
        path_len: usize,
        /// Face index within the file (.ttc collections carry several faces;
        /// Fontconfig reports which one matched via FC_INDEX).
        face_index: u32 = 0,

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

        // Face index within the file (nonzero for non-first faces of a .ttc).
        var face_index: c_int = 0;
        if (ft.FcPatternGetInteger(matched, ft.FC_INDEX, 0, &face_index) != .FcResultMatch or face_index < 0) {
            face_index = 0;
        }

        // Calculate length
        var len: usize = 0;
        while (file_path.?[len] != 0) : (len += 1) {}

        // Copy path before pattern is destroyed (defer above)
        if (len >= 511) return error.FontPathTooLong;

        var font_result = FontPathResult{
            .path_buf = undefined,
            .path_len = len,
            .face_index = @intCast(face_index),
        };
        @memcpy(font_result.path_buf[0..len], file_path.?[0..len]);
        font_result.path_buf[len] = 0;

        return font_result;
    }

    fn initFromPath(library: ft.FT_Library, path: [:0]const u8, path_len: usize, face_index: u32, size: f32) !Self {
        var ft_face: ft.FT_Face = undefined;
        const err = ft.FT_New_Face(library, path.ptr, @intCast(face_index), &ft_face);
        if (err != 0) {
            std.log.err("FreeType face load error: {s}", .{ft.ftErrorString(err)});
            return error.FontLoadFailed;
        }
        errdefer _ = ft.FT_Done_Face(ft_face);

        // Set character size (in 1/64th points at 72 DPI for 1:1 point-to-pixel)
        // Using 96 DPI is more common on Linux
        applyCharSize(ft_face, size, 1.0) catch {
            std.log.err("FreeType set size error: {s}", .{"no usable size for font"});
            return error.FontSizeError;
        };

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
            .allocator = std.heap.c_allocator,
        };

        // Store path for debugging
        @memcpy(self.font_path_buf[0..self.font_path_len], path[0..self.font_path_len]);
        self.font_path_buf[self.font_path_len] = 0;

        // Compute metrics
        self.metrics = computeMetrics(ft_face, size);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.fallback_mutex.lock();
        for (self.fallback_faces.items) |fb| {
            _ = ft.FT_Done_Face(fb.ft_face);
        }
        self.fallback_faces.deinit(self.allocator);
        self.fallback_map.deinit(self.allocator);
        self.fallback_mutex.unlock();
        ft.hb_font_destroy(self.hb_font);
        _ = ft.FT_Done_Face(self.ft_face);
        self.* = undefined;
    }

    /// Get as the generic FontFace interface
    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    /// A glyph resolved from a fallback face for a codepoint the primary
    /// face does not cover.
    pub const FallbackGlyph = struct {
        /// Raw FT_Face; the cache's `getOrRenderFallback` accepts it as
        /// `font_ref` and rasterizes through `renderGlyphFromFont`.
        ft_face: ft.FT_Face,
        glyph_id: u16,
        /// Advance in logical pixels at the primary face's current size.
        advance: f32,
        /// Glyph comes from a color (emoji) font.
        is_color: bool,
    };

    /// Resolve `codepoint` against the fallback faces, opening a face via
    /// Fontconfig on first request. HarfBuzz only shapes within one font, so
    /// this supplies what CoreText provides implicitly on macOS.
    /// Takes `*const Self` like `glyphAdvance` (callers hold a const face);
    /// the lookup state is mutated through `@constCast`.
    pub fn getFallbackGlyph(self: *const Self, codepoint: u21) ?FallbackGlyph {
        const mutable_self = @constCast(self);
        mutable_self.fallback_mutex.lock();
        defer mutable_self.fallback_mutex.unlock();

        const index: u32 = blk: {
            if (mutable_self.fallback_map.get(codepoint)) |maybe_index| {
                if (maybe_index) |i| break :blk i;
                return null; // A previous lookup found no covering font.
            }
            break :blk mutable_self.loadFallbackFaceLocked(codepoint) orelse {
                // Remember the miss so per-frame shaping stops re-querying.
                mutable_self.fallback_map.put(mutable_self.allocator, codepoint, null) catch {};
                return null;
            };
        };

        const fb = mutable_self.fallback_faces.items[index];
        const glyph_idx = ft.FT_Get_Char_Index(fb.ft_face, @intCast(codepoint));
        if (glyph_idx == 0) return null;

        // Load for the advance, then rescale it from the fallback face's
        // ppem (bitmap-strike faces sit at strike size, not text size).
        if (ft.FT_Load_Glyph(fb.ft_face, glyph_idx, ft.FT_LOAD_NO_HINTING) != 0) return null;
        const fb_ppem: f32 = @floatFromInt(fb.ft_face.size.metrics.x_ppem);
        const primary_ppem: f32 = @floatFromInt(mutable_self.ft_face.size.metrics.x_ppem);
        var advance = ft.f26dot6ToFloat(fb.ft_face.glyph.metrics.horiAdvance);
        if (fb_ppem > 0 and primary_ppem > 0) {
            advance *= primary_ppem / fb_ppem;
        }

        return .{
            .ft_face = fb.ft_face,
            .glyph_id = @intCast(glyph_idx),
            .advance = advance,
            .is_color = fb.is_color,
        };
    }

    /// Query Fontconfig for a font covering `codepoint`, open it at the
    /// primary face's size, and register it. Caller holds `fallback_mutex`.
    /// Returns the index into `fallback_faces`.
    fn loadFallbackFaceLocked(self: *Self, codepoint: u21) ?u32 {
        if (self.fallback_faces.items.len >= MAX_OPEN_FALLBACK_FACES) return null;

        const match = findFontForChar(codepoint) orelse return null;

        const library = global_ft_library orelse return null;
        var ft_face: ft.FT_Face = undefined;
        if (ft.FT_New_Face(library, match.pathSlice(), @intCast(match.face_index), &ft_face) != 0) {
            std.log.warn("Fallback font '{s}' failed to open", .{match.pathSlice()});
            return null;
        }

        // Match the primary face's pixel size so advances and rasters line up.
        const primary_ppem = self.ft_face.size.metrics.x_ppem;
        if (ft.FT_Set_Pixel_Sizes(ft_face, 0, @intCast(primary_ppem)) != 0) {
            // Bitmap-only fonts (Noto Color Emoji) reject arbitrary sizes;
            // sit at the nearest embedded strike and rescale advances at use.
            selectNearestStrike(ft_face, @floatFromInt(primary_ppem)) catch {
                std.log.warn("Fallback font '{s}' has no usable size", .{match.pathSlice()});
                _ = ft.FT_Done_Face(ft_face);
                return null;
            };
        }

        self.fallback_faces.append(self.allocator, .{
            .ft_face = ft_face,
            .is_color = ft.hasColor(ft_face),
        }) catch {
            _ = ft.FT_Done_Face(ft_face);
            return null;
        };
        const index: u32 = @intCast(self.fallback_faces.items.len - 1);
        self.fallback_map.put(self.allocator, codepoint, index) catch {};
        return index;
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

/// Set a face's size to `point_size * scale` pixels at 96 DPI. Bitmap-only
/// fonts (e.g. Noto Color Emoji) reject arbitrary char sizes; those fall
/// back to the nearest embedded strike, and callers derive the render scale
/// from `size.metrics` at use time.
fn applyCharSize(ft_face: ft.FT_Face, point_size: f32, scale: f32) !void {
    std.debug.assert(point_size > 0);
    std.debug.assert(scale > 0);
    const err = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size * scale), 96, 96);
    if (err != 0) {
        const target_ppem = point_size * scale * (96.0 / 72.0);
        try selectNearestStrike(ft_face, target_ppem);
    }
}

/// Restore the idle size after a temporary scaled render. Errors are ignored
/// on purpose: a failed restore leaves the face at whatever usable size it
/// has, which the next render sets again anyway.
fn restoreCharSize(ft_face: ft.FT_Face, point_size: f32) void {
    applyCharSize(ft_face, point_size, 1.0) catch {};
}

/// Select the embedded bitmap strike whose ppem is closest to `target_ppem`.
fn selectNearestStrike(ft_face: ft.FT_Face, target_ppem: f32) !void {
    if (ft_face.num_fixed_sizes <= 0 or ft_face.available_sizes == null) {
        return error.NoBitmapStrikes;
    }
    const strikes: [*]ft.FT_Bitmap_Size = @ptrCast(@alignCast(ft_face.available_sizes.?));
    const count: usize = @intCast(ft_face.num_fixed_sizes);
    var best: usize = 0;
    var best_diff: f32 = std.math.floatMax(f32);
    for (0..count) |i| {
        const ppem = @as(f32, @floatFromInt(strikes[i].y_ppem)) / 64.0;
        const diff = @abs(ppem - target_ppem);
        if (diff < best_diff) {
            best_diff = diff;
            best = i;
        }
    }
    if (ft.FT_Select_Size(ft_face, @intCast(best)) != 0) {
        return error.StrikeSelectFailed;
    }
}

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
    applyCharSize(ft_face, point_size, scale) catch {
        ft.FT_Set_Transform(ft_face, null, null);
        restoreCharSize(ft_face, point_size);
        return error.FontSizeError;
    };

    // Load the glyph at scaled size to get correct metrics
    var load_flags = ft.FT_LOAD_DEFAULT;
    if (ft.hasColor(ft_face)) {
        load_flags |= ft.FT_LOAD_COLOR;
    }

    const load_err = ft.FT_Load_Glyph(ft_face, glyph_id, load_flags);
    if (load_err != 0) {
        ft.FT_Set_Transform(ft_face, null, null);
        restoreCharSize(ft_face, point_size);
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
        restoreCharSize(ft_face, point_size);
        return RasterizedGlyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .advance_x = advance_x,
            .is_color = false,
        };
    }

    // Color glyphs (emoji) come back as BGRA strikes — bitmap-strike faces
    // deliver them at strike size, so they are converted to an alpha mask at
    // the requested size instead of being copied raw.
    if (slot.bitmap.pixel_mode == .FT_PIXEL_MODE_BGRA) {
        const result = renderColorGlyphAsMask(ft_face, slot, point_size, scale, buffer);
        ft.FT_Set_Transform(ft_face, null, null);
        restoreCharSize(ft_face, point_size);
        return result;
    }

    // Render to bitmap if not already
    if (slot.format != .FT_GLYPH_FORMAT_BITMAP) {
        const render_err = ft.FT_Render_Glyph(slot, .FT_RENDER_MODE_NORMAL);
        if (render_err != 0) {
            ft.FT_Set_Transform(ft_face, null, null);
            restoreCharSize(ft_face, point_size);
            return error.GlyphRenderFailed;
        }
    }

    // Reset transform for future operations
    ft.FT_Set_Transform(ft_face, null, null);
    restoreCharSize(ft_face, point_size);

    const bitmap = slot.bitmap;
    const width = bitmap.width;
    const height = bitmap.rows;

    std.debug.assert(width <= 256); // Reasonable glyph size limit
    std.debug.assert(height <= 256);

    // Copy bitmap to output buffer
    if (width > 0 and height > 0) {
        if (@as(usize, width) * height > buffer.len) {
            return error.GlyphTooLarge;
        }

        const src_pitch: usize = if (bitmap.pitch < 0)
            @intCast(-bitmap.pitch)
        else
            @intCast(bitmap.pitch);

        var y: usize = 0;
        while (y < height) : (y += 1) {
            const src_row = bitmap.buffer + y * src_pitch;
            const dst_row = buffer.ptr + y * width;
            @memcpy(dst_row[0..width], src_row[0..width]);
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
        .is_color = false,
    };
}

/// Convert a BGRA color-glyph bitmap (emoji) into a single-channel alpha
/// coverage mask at the requested text size, downscaled from the strike the
/// bitmap-only font provides. The atlas pipeline is single-channel, so the
/// color channels are dropped; the glyph draws tinted with the text color
/// rather than as tofu or an oversized strike.
fn renderColorGlyphAsMask(
    ft_face: ft.FT_Face,
    slot: ft.FT_GlyphSlot,
    point_size: f32,
    scale: f32,
    buffer: []u8,
) !RasterizedGlyph {
    const bitmap = slot.bitmap;
    const src_w = bitmap.width;
    const src_h = bitmap.rows;
    if (src_w == 0 or src_h == 0) {
        return error.GlyphRenderFailed;
    }

    // Strike faces sit at strike ppem; scale the mask to the requested size.
    const strike_ppem: f32 = @floatFromInt(ft_face.size.metrics.y_ppem);
    const target_ppem = point_size * scale * (96.0 / 72.0);
    var dst_w: u32 = src_w;
    var dst_h: u32 = src_h;
    if (strike_ppem > 0 and target_ppem > 0 and @abs(strike_ppem - target_ppem) > 0.5) {
        const ratio = target_ppem / strike_ppem;
        dst_w = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(src_w)) * ratio))));
        dst_h = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(src_h)) * ratio))));
    }

    // Jointly clamp to the 256px glyph limit and the render buffer capacity.
    const pixel_cap: usize = @min(buffer.len, 256 * 256);
    if (dst_w > 256 or dst_h > 256 or @as(usize, dst_w) * dst_h > pixel_cap) {
        const w_f: f32 = @floatFromInt(dst_w);
        const h_f: f32 = @floatFromInt(dst_h);
        var k = @min(256.0 / @max(w_f, h_f), @sqrt(@as(f32, @floatFromInt(pixel_cap)) / (w_f * h_f)));
        if (!(k > 0)) k = 0.01; // Guard NaN (w_f*h_f == 0 cannot happen here).
        dst_w = @max(1, @as(u32, @intFromFloat(w_f * k)));
        dst_h = @max(1, @as(u32, @intFromFloat(h_f * k)));
    }
    if (@as(usize, dst_w) * dst_h > buffer.len) {
        return error.GlyphTooLarge;
    }

    const src_pitch: usize = if (bitmap.pitch < 0)
        @intCast(-bitmap.pitch)
    else
        @intCast(bitmap.pitch);

    bgraToAlphaMask(bitmap.buffer, src_w, src_h, src_pitch, buffer[0 .. @as(usize, dst_w) * dst_h], dst_w, dst_h);

    // Positions and advance were measured at strike size; rescale to the
    // requested size and back to logical pixels.
    const sx: f32 = @as(f32, @floatFromInt(dst_w)) / @as(f32, @floatFromInt(src_w));
    const sy: f32 = @as(f32, @floatFromInt(dst_h)) / @as(f32, @floatFromInt(src_h));
    const advance_scale: f32 = if (strike_ppem > 0) target_ppem / strike_ppem else 1.0;

    return RasterizedGlyph{
        .width = dst_w,
        .height = dst_h,
        .offset_x = @intFromFloat(@round(@as(f32, @floatFromInt(slot.bitmap_left)) * sx)),
        .offset_y = @intFromFloat(@round(@as(f32, @floatFromInt(slot.bitmap_top)) * sy)),
        .advance_x = scaledAdvanceForColorGlyph(slot, advance_scale) / scale,
        .is_color = true,
    };
}

/// Advance of a color strike glyph in logical pixels, rescaled from the
/// strike's ppem to the requested size. Precomputed from `slot.metrics`.
fn scaledAdvanceForColorGlyph(slot: ft.FT_GlyphSlot, advance_scale: f32) f32 {
    return ft.f26dot6ToFloat(slot.metrics.horiAdvance) * advance_scale;
}

/// Box-filter a BGRA bitmap down (or 1:1 copy it up) into an alpha mask,
/// sampling the alpha channel as coverage.
fn bgraToAlphaMask(
    src: [*]const u8,
    src_w: u32,
    src_h: u32,
    src_pitch: usize,
    dst: []u8,
    dst_w: u32,
    dst_h: u32,
) void {
    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        const y0: u64 = @as(u64, dy) * src_h / dst_h;
        const y1: u64 = @max(y0 + 1, (@as(u64, dy) + 1) * src_h / dst_h);
        var dx: u32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const x0: u64 = @as(u64, dx) * src_w / dst_w;
            const x1: u64 = @max(x0 + 1, (@as(u64, dx) + 1) * src_w / dst_w);
            var sum: u32 = 0;
            var count: u32 = 0;
            var sy = y0;
            while (sy < y1) : (sy += 1) {
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    // BGRA layout: alpha is byte 3.
                    sum += src[@as(usize, @intCast(sy)) * src_pitch + @as(usize, @intCast(sx)) * 4 + 3];
                    count += 1;
                }
            }
            dst[@as(usize, dy) * dst_w + dx] = if (count > 0) @intCast(sum / count) else 0;
        }
    }
}

// =============================================================================
// Fontconfig Character Fallback
// =============================================================================

const FcMatchResult = struct {
    path_buf: [512]u8,
    path_len: usize,
    face_index: u32 = 0,

    pub fn pathSlice(self: *const FcMatchResult) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }
};

/// Find an installed font covering `codepoint` via Fontconfig. The pattern
/// carries only FC_CHARSET, so any family with coverage can win.
fn findFontForChar(codepoint: u21) ?FcMatchResult {
    const charset = ft.FcCharSetCreate() orelse return null;
    defer ft.FcCharSetDestroy(charset);
    _ = ft.FcCharSetAddChar(charset, @intCast(codepoint));

    const pattern = ft.FcPatternCreate() orelse return null;
    defer ft.FcPatternDestroy(pattern);

    _ = ft.FcPatternAddCharSet(pattern, ft.FC_CHARSET, charset);
    _ = ft.FcConfigSubstitute(null, pattern, .FcMatchPattern);
    ft.FcDefaultSubstitute(pattern);

    var fc_result: ft.FcResult = undefined;
    const matched = ft.FcFontMatch(null, pattern, &fc_result) orelse return null;
    defer ft.FcPatternDestroy(matched);
    if (fc_result != .FcResultMatch) return null;

    // FcFontMatch is best-effort: verify the winner actually covers the char.
    var matched_charset: ?*ft.FcCharSet = null;
    if (ft.FcPatternGetCharSet(matched, ft.FC_CHARSET, 0, &matched_charset) == .FcResultMatch) {
        if (matched_charset) |mc| {
            if (ft.FcCharSetHasChar(mc, @intCast(codepoint)) == 0) return null;
        }
    }

    var file_path: ?[*:0]const ft.FcChar8 = null;
    if (ft.FcPatternGetString(matched, ft.FC_FILE, 0, &file_path) != .FcResultMatch or file_path == null) {
        return null;
    }

    var index: c_int = 0;
    if (ft.FcPatternGetInteger(matched, ft.FC_INDEX, 0, &index) != .FcResultMatch or index < 0) {
        index = 0;
    }

    var len: usize = 0;
    while (file_path.?[len] != 0) : (len += 1) {}
    if (len >= 511) return null;

    var result = FcMatchResult{
        .path_buf = undefined,
        .path_len = len,
        .face_index = @intCast(index),
    };
    @memcpy(result.path_buf[0..len], file_path.?[0..len]);
    result.path_buf[len] = 0;
    return result;
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
