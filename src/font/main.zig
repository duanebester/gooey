//! Font rendering system for guiz
//!
//! Provides high-level text rendering with:
//! - Font loading and metrics
//! - Text shaping (ligatures, kerning)
//! - Glyph caching and atlas management
//! - GPU-ready glyph data

const std = @import("std");

pub const coretext = @import("coretext.zig");
pub const Face = @import("face.zig").Face;
pub const Metrics = @import("face.zig").Metrics;
pub const GlyphMetrics = @import("face.zig").GlyphMetrics;
pub const Atlas = @import("atlas.zig").Atlas;
pub const Region = @import("atlas.zig").Region;
pub const GlyphCache = @import("cache.zig").GlyphCache;
pub const CachedGlyph = @import("cache.zig").CachedGlyph;
pub const Shaper = @import("shaper.zig").Shaper;
pub const ShapedGlyph = @import("shaper.zig").ShapedGlyph;
pub const ShapedRun = @import("shaper.zig").ShapedRun;

/// High-level text system combining all components
pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    cache: GlyphCache,
    shaper: Shaper,
    current_face: ?Face,
    scale_factor: f32, // ADD

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return initWithScale(allocator, 1.0);
    }

    pub fn initWithScale(allocator: std.mem.Allocator, scale: f32) !Self {
        return .{
            .allocator = allocator,
            .cache = try GlyphCache.initWithScale(allocator, scale),
            .shaper = Shaper.init(allocator),
            .current_face = null,
            .scale_factor = scale,
        };
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        self.scale_factor = scale;
        self.cache.setScaleFactor(scale);
    }

    pub fn deinit(self: *Self) void {
        if (self.current_face) |*f| f.deinit();
        self.cache.deinit();
        self.shaper.deinit();
        self.* = undefined;
    }

    /// Load a font by name
    pub fn loadFont(self: *Self, name: []const u8, size: f32) !void {
        if (self.current_face) |*f| f.deinit();
        self.current_face = try Face.init(name, size);
        self.cache.clear();
    }

    /// Load a system font
    pub fn loadSystemFont(self: *Self, style: Face.SystemFont, size: f32) !void {
        if (self.current_face) |*f| f.deinit();
        self.current_face = try Face.initSystem(style, size);
        self.cache.clear();
    }

    /// Get current font metrics
    pub fn getMetrics(self: *const Self) ?Metrics {
        if (self.current_face) |f| return f.metrics;
        return null;
    }

    /// Measure text width
    pub fn measureText(self: *Self, text: []const u8) !f32 {
        const face = self.current_face orelse return error.NoFontLoaded;
        var run = try self.shaper.shapeSimple(&face, text);
        defer run.deinit(self.allocator);
        return run.width;
    }

    /// Shape text and get glyph positions
    pub fn shapeText(self: *Self, text: []const u8) !ShapedRun {
        const face = self.current_face orelse return error.NoFontLoaded;
        return self.shaper.shapeSimple(&face, text);
    }

    /// Get cached glyph (renders if needed)
    pub fn getGlyph(self: *Self, glyph_id: u16) !CachedGlyph {
        const face = self.current_face orelse return error.NoFontLoaded;
        return self.cache.getOrRender(&face, glyph_id);
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

/// Text style for rendering
pub const TextStyle = struct {
    /// Text color (HSLA)
    color: @import("../core/scene.zig").Hsla = .{ .h = 0, .s = 0, .l = 0, .a = 1 },
    /// Font size in points
    size: f32 = 14.0,
    /// Line height multiplier
    line_height: f32 = 1.2,
    /// Letter spacing adjustment
    letter_spacing: f32 = 0,
};

/// Positioned glyph ready for rendering
pub const PositionedGlyph = struct {
    /// Glyph ID
    glyph_id: u16,
    /// Screen X position
    x: f32,
    /// Screen Y position (baseline)
    y: f32,
    /// Cached glyph data (atlas region, etc.)
    cached: CachedGlyph,
};

test {
    std.testing.refAllDecls(@This());
}
