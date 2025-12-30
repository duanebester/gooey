//! Glyph cache - maps (font_id, glyph_id, size, subpixel) to atlas regions
//!
//! Renders glyphs on-demand using the FontFace interface and caches
//! them in the texture atlas.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const font_face_mod = @import("font_face.zig");
const platform = @import("../platform/mod.zig");

const Atlas = @import("atlas.zig").Atlas;
const Region = @import("atlas.zig").Region;

const FontFace = font_face_mod.FontFace;
const RasterizedGlyph = types.RasterizedGlyph;
const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;
const SUBPIXEL_VARIANTS_Y = types.SUBPIXEL_VARIANTS_Y;

const is_wasm = platform.is_wasm;
const is_linux = platform.is_linux;

/// Key for glyph lookup - includes subpixel variant
pub const GlyphKey = struct {
    /// Font identifier (pointer-based)
    font_ptr: usize,
    /// Glyph ID from the font
    glyph_id: u16,
    /// Font size in 1/64th points (for subpixel precision)
    size_fixed: u16,
    /// Scale factor (1-4x)
    scale_fixed: u8,
    /// Subpixel X variant (0 to SUBPIXEL_VARIANTS_X - 1)
    subpixel_x: u8,
    /// Subpixel Y variant (0 to SUBPIXEL_VARIANTS_Y - 1)
    subpixel_y: u8,

    pub inline fn init(face: FontFace, glyph_id: u16, scale: f32, subpixel_x: u8, subpixel_y: u8) GlyphKey {
        return .{
            .font_ptr = @intFromPtr(face.ptr),
            .glyph_id = glyph_id,
            .size_fixed = @intFromFloat(face.metrics.point_size * 64.0),
            .scale_fixed = @intFromFloat(@max(1.0, @min(4.0, scale))),
            .subpixel_x = subpixel_x,
            .subpixel_y = subpixel_y,
        };
    }

    /// Create key for a fallback font (uses raw CTFontRef pointer)
    pub inline fn initWithFontPtr(font_ptr: usize, glyph_id: u16, size: f32, scale: f32, subpixel_x: u8, subpixel_y: u8) GlyphKey {
        return .{
            .font_ptr = font_ptr,
            .glyph_id = glyph_id,
            .size_fixed = @intFromFloat(size * 64.0),
            .scale_fixed = @intFromFloat(@max(1.0, @min(4.0, scale))),
            .subpixel_x = subpixel_x,
            .subpixel_y = subpixel_y,
        };
    }
};

/// Cached glyph information
pub const CachedGlyph = struct {
    /// Region in the atlas (physical pixels)
    region: Region,
    /// Horizontal offset from pen position to glyph left edge (physical pixels)
    offset_x: i32,
    /// Vertical offset from baseline to glyph top edge (physical pixels)
    offset_y: i32,
    /// Horizontal advance to next glyph (logical pixels)
    advance_x: f32,
    /// Whether this glyph uses the color atlas (emoji)
    is_color: bool,
};

/// Glyph cache with atlas management
pub const GlyphCache = struct {
    allocator: std.mem.Allocator,
    /// Glyph lookup table
    map: std.AutoHashMap(GlyphKey, CachedGlyph),
    /// Grayscale atlas for regular text
    grayscale_atlas: Atlas,
    /// Color atlas for emoji (optional)
    color_atlas: ?Atlas,
    /// Reusable bitmap buffer for rendering
    render_buffer: []u8,
    render_buffer_size: u32,
    scale_factor: f32,

    const Self = @This();
    const RENDER_BUFFER_SIZE: u32 = 256; // Max glyph size

    pub fn init(allocator: std.mem.Allocator, scale: f32) !Self {
        const buffer_bytes = RENDER_BUFFER_SIZE * RENDER_BUFFER_SIZE;
        const render_buffer = try allocator.alloc(u8, buffer_bytes);
        @memset(render_buffer, 0);

        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(GlyphKey, CachedGlyph).init(allocator),
            .grayscale_atlas = try Atlas.init(allocator, .grayscale),
            .color_atlas = null,
            .render_buffer = render_buffer,
            .render_buffer_size = buffer_bytes,
            .scale_factor = scale,
        };
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        if (self.scale_factor != scale) {
            self.scale_factor = scale;
            self.clear();
        }
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
        self.grayscale_atlas.deinit();
        if (self.color_atlas) |*ca| ca.deinit();
        self.allocator.free(self.render_buffer);
        self.* = undefined;
    }

    /// Reserve space in the atlas, with eviction on overflow.
    /// When the atlas is at max size and can't fit the glyph,
    /// clears the entire cache and tries again.
    fn reserveWithEviction(self: *Self, width: u32, height: u32) !Region {
        // First attempt: try to reserve directly
        if (try self.grayscale_atlas.reserve(width, height)) |region| {
            return region;
        }

        // No space - try to grow the atlas
        self.grayscale_atlas.grow() catch |err| {
            if (err == error.AtlasFull) {
                // Atlas is at max size and full - evict everything and retry
                self.clear();

                // After clearing, we should definitely have space
                if (try self.grayscale_atlas.reserve(width, height)) |region| {
                    return region;
                }
                // If we still can't fit after clearing, the glyph is too large
                return error.GlyphTooLarge;
            }
            return err;
        };

        // Growth succeeded - try reserve again
        return try self.grayscale_atlas.reserve(width, height) orelse error.GlyphTooLarge;
    }

    /// Get a cached glyph with subpixel variant, or render and cache it
    pub inline fn getOrRenderSubpixel(
        self: *Self,
        face: FontFace,
        glyph_id: u16,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        const key = GlyphKey.init(face, glyph_id, self.scale_factor, subpixel_x, subpixel_y);

        if (self.map.get(key)) |cached| {
            return cached;
        }

        const glyph = try self.renderGlyphSubpixel(face, glyph_id, subpixel_x, subpixel_y);
        try self.map.put(key, glyph);
        return glyph;
    }

    /// Legacy: get glyph without subpixel variant (uses variant 0,0)
    pub inline fn getOrRender(self: *Self, face: FontFace, glyph_id: u16) !CachedGlyph {
        return self.getOrRenderSubpixel(face, glyph_id, 0, 0);
    }

    fn renderGlyphSubpixel(
        self: *Self,
        face: FontFace,
        glyph_id: u16,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        @memset(self.render_buffer, 0);

        // Calculate subpixel shift (0.0, 0.25, 0.5, or 0.75)
        const subpixel_shift_x = @as(f32, @floatFromInt(subpixel_x)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_X));
        const subpixel_shift_y = @as(f32, @floatFromInt(subpixel_y)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_Y));

        // Use the FontFace interface to render with subpixel shift
        const rasterized = try face.renderGlyphSubpixel(
            glyph_id,
            self.scale_factor,
            subpixel_shift_x,
            subpixel_shift_y,
            self.render_buffer,
            self.render_buffer_size,
        );

        // Handle empty glyphs (spaces, etc.)
        if (rasterized.width == 0 or rasterized.height == 0) {
            return CachedGlyph{
                .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .offset_x = rasterized.offset_x,
                .offset_y = rasterized.offset_y,
                .advance_x = rasterized.advance_x,
                .is_color = rasterized.is_color,
            };
        }

        // Reserve space in atlas with eviction support
        const region = try self.reserveWithEviction(rasterized.width, rasterized.height);

        // Copy rasterized data to atlas
        self.grayscale_atlas.set(region, self.render_buffer[0 .. rasterized.width * rasterized.height]);

        return CachedGlyph{
            .region = region,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .advance_x = rasterized.advance_x,
            .is_color = rasterized.is_color,
        };
    }

    /// Get a cached glyph for a fallback font (specified by raw CTFontRef)
    pub fn getOrRenderFallback(
        self: *Self,
        font_ptr: *anyopaque,
        glyph_id: u16,
        font_size: f32,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        const key = GlyphKey.initWithFontPtr(
            @intFromPtr(font_ptr),
            glyph_id,
            font_size,
            self.scale_factor,
            subpixel_x,
            subpixel_y,
        );

        if (self.map.get(key)) |cached| {
            return cached;
        }

        const glyph = try self.renderFallbackGlyph(font_ptr, glyph_id, subpixel_x, subpixel_y);
        try self.map.put(key, glyph);
        return glyph;
    }

    fn renderFallbackGlyph(
        self: *Self,
        font_ptr: *anyopaque,
        glyph_id: u16,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        // Fallback fonts are only supported on native platforms
        // On web, the browser handles font fallback automatically
        if (is_wasm) {
            return error.FallbackNotSupported;
        }

        @memset(self.render_buffer, 0);

        const subpixel_shift_x = @as(f32, @floatFromInt(subpixel_x)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_X));
        const subpixel_shift_y = @as(f32, @floatFromInt(subpixel_y)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_Y));

        // Platform-specific fallback rendering
        const rasterized = if (is_linux) blk: {
            const FreeTypeFace = @import("backends/freetype/face.zig").FreeTypeFace;
            break :blk try FreeTypeFace.renderGlyphFromFont(
                @ptrCast(@alignCast(font_ptr)),
                glyph_id,
                self.scale_factor,
                subpixel_shift_x,
                subpixel_shift_y,
                self.render_buffer,
                self.render_buffer_size,
            );
        } else blk: {
            const CoreTextFace = @import("backends/coretext/face.zig").CoreTextFace;
            break :blk try CoreTextFace.renderGlyphFromFont(
                font_ptr,
                glyph_id,
                self.scale_factor,
                subpixel_shift_x,
                subpixel_shift_y,
                self.render_buffer,
                self.render_buffer_size,
            );
        };

        if (rasterized.width == 0 or rasterized.height == 0) {
            return CachedGlyph{
                .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .offset_x = rasterized.offset_x,
                .offset_y = rasterized.offset_y,
                .advance_x = rasterized.advance_x,
                .is_color = rasterized.is_color,
            };
        }

        // Reserve space in atlas with eviction support
        const region = try self.reserveWithEviction(rasterized.width, rasterized.height);

        self.grayscale_atlas.set(region, self.render_buffer[0 .. rasterized.width * rasterized.height]);

        return CachedGlyph{
            .region = region,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .advance_x = rasterized.advance_x,
            .is_color = rasterized.is_color,
        };
    }

    /// Clear the cache (call when changing fonts)
    pub fn clear(self: *Self) void {
        self.map.clearRetainingCapacity();
        self.grayscale_atlas.clear();
        if (self.color_atlas) |*ca| ca.clear();
    }

    /// Get the grayscale atlas for GPU upload
    pub inline fn getAtlas(self: *const Self) *const Atlas {
        return &self.grayscale_atlas;
    }

    /// Get atlas generation (for detecting changes)
    pub inline fn getGeneration(self: *const Self) u32 {
        return self.grayscale_atlas.generation;
    }
};
