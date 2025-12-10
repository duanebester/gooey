//! High-level text system combining all components
//!
//! Provides a unified API for text rendering with:
//! - Font loading and metrics
//! - Text shaping (simple and complex)
//! - Glyph caching and atlas management
//! - GPU-ready glyph data

const std = @import("std");
const types = @import("types.zig");
const font_face_mod = @import("font_face.zig");
const shaper_mod = @import("shaper.zig");
const cache_mod = @import("cache.zig");
const Atlas = @import("atlas.zig").Atlas;

// Backend imports (compile-time platform selection)
const coretext = @import("backends/coretext/mod.zig");

pub const FontFace = font_face_mod.FontFace;
pub const Metrics = types.Metrics;
pub const GlyphMetrics = types.GlyphMetrics;
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const TextMeasurement = types.TextMeasurement;
pub const SystemFont = types.SystemFont;
pub const CachedGlyph = cache_mod.CachedGlyph;

/// High-level text system
pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    cache: cache_mod.GlyphCache,
    /// Current font face (backend-specific storage)
    current_face: ?coretext.CoreTextFace,
    /// Complex shaper (optional, for ligatures/kerning)
    shaper: ?coretext.CoreTextShaper,
    scale_factor: f32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return initWithScale(allocator, 1.0);
    }

    pub fn initWithScale(allocator: std.mem.Allocator, scale: f32) !Self {
        return .{
            .allocator = allocator,
            .cache = try cache_mod.GlyphCache.init(allocator, scale),
            .current_face = null,
            .shaper = null,
            .scale_factor = scale,
        };
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        self.scale_factor = scale;
        self.cache.setScaleFactor(scale);
    }

    pub fn deinit(self: *Self) void {
        if (self.current_face) |*f| f.deinit();
        if (self.shaper) |*s| s.deinit();
        self.cache.deinit();
        self.* = undefined;
    }

    /// Load a font by name
    pub fn loadFont(self: *Self, name: []const u8, size: f32) !void {
        if (self.current_face) |*f| f.deinit();
        self.current_face = try coretext.CoreTextFace.init(name, size);
        self.cache.clear();
    }

    /// Load a system font
    pub fn loadSystemFont(self: *Self, style: SystemFont, size: f32) !void {
        if (self.current_face) |*f| f.deinit();
        self.current_face = try coretext.CoreTextFace.initSystem(style, size);
        self.cache.clear();
    }

    /// Get current font metrics
    pub fn getMetrics(self: *const Self) ?Metrics {
        if (self.current_face) |f| return f.metrics;
        return null;
    }

    /// Get the FontFace interface for the current font
    pub fn getFontFace(self: *Self) !FontFace {
        if (self.current_face) |*f| {
            return f.asFontFace();
        }
        return error.NoFontLoaded;
    }

    /// Shape text with proper kerning and ligature support
    pub fn shapeText(self: *Self, text: []const u8) !ShapedRun {
        // Use complex shaper for proper kerning
        return self.shapeTextComplex(text);
    }

    /// Shape text using complex shaper (ligatures, kerning)
    pub fn shapeTextComplex(self: *Self, text: []const u8) !ShapedRun {
        const face = self.current_face orelse return error.NoFontLoaded;

        // Lazy init shaper
        if (self.shaper == null) {
            self.shaper = coretext.CoreTextShaper.init(self.allocator);
        }

        return self.shaper.?.shape(&face, text, self.allocator);
    }

    /// Get cached glyph (renders if needed)
    pub fn getGlyph(self: *Self, glyph_id: u16) !CachedGlyph {
        const face = try self.getFontFace();
        return self.cache.getOrRender(face, glyph_id);
    }

    /// Simple width measurement
    pub fn measureText(self: *Self, text: []const u8) !f32 {
        const face = try self.getFontFace();
        return shaper_mod.measureSimple(face, text);
    }

    /// Extended text measurement with wrapping support
    pub fn measureTextEx(self: *Self, text: []const u8, max_width: ?f32) !TextMeasurement {
        const face = try self.getFontFace();
        var run = try shaper_mod.shapeSimple(self.allocator, face, text);
        defer run.deinit(self.allocator);

        if (max_width == null or run.width <= max_width.?) {
            return .{
                .width = run.width,
                .height = face.metrics.line_height,
                .line_count = 1,
            };
        }

        // Text wrapping measurement
        var current_width: f32 = 0;
        var max_line_width: f32 = 0;
        var line_count: u32 = 1;
        var word_width: f32 = 0;

        for (run.glyphs) |glyph| {
            const char_idx = glyph.cluster;
            const is_space = char_idx < text.len and text[char_idx] == ' ';
            const is_newline = char_idx < text.len and text[char_idx] == '\n';

            if (is_newline) {
                max_line_width = @max(max_line_width, current_width);
                current_width = 0;
                line_count += 1;
                word_width = 0;
                continue;
            }

            word_width += glyph.x_advance;

            if (is_space) {
                if (current_width + word_width > max_width.? and current_width > 0) {
                    max_line_width = @max(max_line_width, current_width);
                    current_width = word_width;
                    line_count += 1;
                } else {
                    current_width += word_width;
                }
                word_width = 0;
            }
        }

        current_width += word_width;
        max_line_width = @max(max_line_width, current_width);

        return .{
            .width = max_line_width,
            .height = face.metrics.line_height * @as(f32, @floatFromInt(line_count)),
            .line_count = line_count,
        };
    }

    /// Get the glyph atlas for GPU upload
    pub fn getAtlas(self: *const Self) *const Atlas {
        return self.cache.getAtlas();
    }

    /// Check if atlas needs re-upload
    pub fn atlasGeneration(self: *const Self) u32 {
        return self.cache.getGeneration();
    }
};
