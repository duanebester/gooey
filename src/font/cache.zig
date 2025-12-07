//! Glyph cache - maps (font_id, glyph_id, size) to atlas regions
//!
//! Renders glyphs on-demand and caches them in the texture atlas.

const std = @import("std");
const ct = @import("coretext.zig");
const Face = @import("face.zig").Face;
const Atlas = @import("atlas.zig").Atlas;
const Region = @import("atlas.zig").Region;

/// Key for glyph lookup
pub const GlyphKey = struct {
    /// Font identifier (pointer-based for now)
    font_ptr: usize,
    /// Glyph ID from the font
    glyph_id: u16,
    /// Font size in 1/64th points (for subpixel precision)
    size_fixed: u16,
    scale_fixed: u8,

    pub fn init(face: *const Face, glyph_id: u16, scale: f32) GlyphKey {
        return .{
            .font_ptr = @intFromPtr(face.ct_font),
            .glyph_id = glyph_id,
            .size_fixed = @intFromFloat(face.metrics.point_size * 64.0),
            .scale_fixed = @intFromFloat(@max(1.0, @min(4.0, scale))),
        };
    }
};

/// Cached glyph information
pub const CachedGlyph = struct {
    /// Region in the atlas
    region: Region,
    /// Horizontal bearing (offset from pen position to left edge)
    bearing_x: i16,
    /// Vertical bearing (offset from baseline to top edge)
    bearing_y: i16,
    /// Horizontal advance to next glyph
    advance_x: u16,
    /// Whether this glyph uses the color atlas (emoji)
    is_color: bool,
    scale: f32,
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

    pub fn init(allocator: std.mem.Allocator) !Self {
        const buffer_bytes = RENDER_BUFFER_SIZE * RENDER_BUFFER_SIZE;
        const render_buffer = try allocator.alloc(u8, buffer_bytes);
        @memset(render_buffer, 0);

        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(GlyphKey, CachedGlyph).init(allocator),
            .grayscale_atlas = try Atlas.init(allocator, .grayscale),
            .color_atlas = null,
            .render_buffer = render_buffer,
            .render_buffer_size = RENDER_BUFFER_SIZE,
        };
    }

    pub fn initWithScale(allocator: std.mem.Allocator, scale: f32) !Self {
        const buffer_bytes = RENDER_BUFFER_SIZE * RENDER_BUFFER_SIZE;
        const render_buffer = try allocator.alloc(u8, buffer_bytes);
        @memset(render_buffer, 0);

        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(GlyphKey, CachedGlyph).init(allocator),
            .grayscale_atlas = try Atlas.init(allocator, .grayscale),
            .color_atlas = null,
            .render_buffer = render_buffer,
            .render_buffer_size = RENDER_BUFFER_SIZE,
            .scale_factor = scale,
        };
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        if (self.scale_factor != scale) {
            self.scale_factor = scale;
            self.clear(); // Re-render all glyphs at new scale
        }
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
        self.grayscale_atlas.deinit();
        if (self.color_atlas) |*ca| ca.deinit();
        self.allocator.free(self.render_buffer);
        self.* = undefined;
    }

    /// Get a cached glyph, or render and cache it
    pub fn getOrRender(self: *Self, face: *const Face, glyph_id: u16) !CachedGlyph {
        const key = GlyphKey.init(face, glyph_id, self.scale_factor);

        if (self.map.get(key)) |cached| {
            return cached;
        }

        const glyph = try self.renderGlyph(face, glyph_id);
        try self.map.put(key, glyph);
        return glyph;
    }

    fn renderGlyph(self: *Self, face: *const Face, glyph_id: u16) !CachedGlyph {
        const scale = self.scale_factor;
        const metrics = face.glyphMetrics(glyph_id);

        // Handle empty glyphs (spaces, etc.)
        if (metrics.width < 1 or metrics.height < 1) {
            return CachedGlyph{
                .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .bearing_x = @intFromFloat(metrics.bearing_x),
                .bearing_y = @intFromFloat(metrics.bearing_y),
                .advance_x = @intFromFloat(metrics.advance_x),
                .is_color = false,
                .scale = scale,
            };
        }

        // Bitmap size in physical pixels (scaled)
        const padding: u32 = 2;
        const width: u32 = @as(u32, @intFromFloat(@ceil(metrics.width * scale))) + padding * 2;
        const height: u32 = @as(u32, @intFromFloat(@ceil(metrics.height * scale))) + padding * 2;

        const clamped_w = @min(width, self.render_buffer_size);
        const clamped_h = @min(height, self.render_buffer_size);

        @memset(self.render_buffer[0 .. clamped_w * clamped_h], 0);

        const color_space = ct.CGColorSpaceCreateDeviceGray() orelse return error.GraphicsError;
        defer ct.CGColorSpaceRelease(color_space);

        const context = ct.CGBitmapContextCreate(
            self.render_buffer.ptr,
            clamped_w,
            clamped_h,
            8,
            clamped_w,
            color_space,
            ct.kCGImageAlphaNone,
        ) orelse return error.GraphicsError;
        defer ct.CGContextRelease(context);

        // Rendering settings
        ct.CGContextSetAllowsAntialiasing(context, true);
        ct.CGContextSetShouldAntialias(context, true);
        ct.CGContextSetAllowsFontSmoothing(context, true);
        ct.CGContextSetShouldSmoothFonts(context, true);
        ct.CGContextSetGrayFillColor(context, 1.0, 1.0);

        // Identity text matrix
        ct.CGContextSetTextMatrix(context, ct.CGAffineTransform.identity);

        // Position: account for padding and bearing, scaled
        // CoreGraphics Y is bottom-up, so we position from bottom
        const pos_x: ct.CGFloat = @as(ct.CGFloat, @floatFromInt(padding)) - metrics.bearing_x * scale;
        const pos_y: ct.CGFloat = @as(ct.CGFloat, @floatFromInt(padding)) + (metrics.height - metrics.bearing_y) * scale;

        var glyph = glyph_id;
        const position = ct.CGPoint{ .x = pos_x, .y = pos_y };

        // Draw at scaled size by using a scaled font
        const scaled_font = ct.CTFontCreateCopyWithAttributes(
            face.ct_font,
            face.metrics.point_size * scale,
            null,
            null,
        ) orelse return error.FontError;
        defer ct.release(scaled_font);

        ct.CTFontDrawGlyphs(scaled_font, @ptrCast(&glyph), @ptrCast(&position), 1, context);

        // Reserve space in atlas
        const region = try self.grayscale_atlas.reserve(clamped_w, clamped_h) orelse blk: {
            try self.grayscale_atlas.grow();
            break :blk try self.grayscale_atlas.reserve(clamped_w, clamped_h) orelse
                return error.AtlasFull;
        };

        self.grayscale_atlas.set(region, self.render_buffer[0 .. clamped_w * clamped_h]);

        // Store region in PHYSICAL pixels (scaled)
        return CachedGlyph{
            .region = region,
            .bearing_x = @intFromFloat(metrics.bearing_x - @as(f32, @floatFromInt(padding)) / scale),
            .bearing_y = @intFromFloat(metrics.bearing_y + @as(f32, @floatFromInt(padding)) / scale),
            .advance_x = @intFromFloat(metrics.advance_x),
            .is_color = false,
            .scale = scale,
        };
    }

    /// Clear the cache (call when changing fonts)
    pub fn clear(self: *Self) void {
        self.map.clearRetainingCapacity();
        self.grayscale_atlas.clear();
        if (self.color_atlas) |*ca| ca.clear();
    }

    /// Get the grayscale atlas for GPU upload
    pub fn getAtlas(self: *const Self) *const Atlas {
        return &self.grayscale_atlas;
    }

    /// Get atlas generation (for detecting changes)
    pub fn getGeneration(self: *const Self) u32 {
        return self.grayscale_atlas.generation;
    }
};

test "glyph cache render" {
    var cache = try GlyphCache.init(std.testing.allocator);
    defer cache.deinit();

    var face = try Face.initSystem(.monospace, 14.0);
    defer face.deinit();

    const glyph_a = face.glyphIndex('A');
    const cached = try cache.getOrRender(&face, glyph_a);

    try std.testing.expect(cached.region.width > 0);
    try std.testing.expect(cached.region.height > 0);
}
