//! Mock font face for testing
//!
//! Provides a configurable FontFace implementation without platform dependencies.
//! Use this to test text layout, shaping, and rendering pipelines in isolation.
//!
//! Example:
//! ```zig
//! var mock = MockFontFace.init(std.testing.allocator);
//! defer mock.deinit();
//!
//! // Configure glyph mappings
//! try mock.setGlyphMapping('A', 65);
//! try mock.setGlyphMapping('B', 66);
//!
//! // Get FontFace interface
//! var face = mock.fontFace();
//!
//! try std.testing.expectEqual(@as(u16, 65), face.glyphIndex('A'));
//! try std.testing.expectEqual(@as(u32, 1), mock.glyph_index_count);
//! ```

const std = @import("std");
const text_types = @import("../text/types.zig");
const font_face_mod = @import("../text/font_face.zig");

pub const Metrics = text_types.Metrics;
pub const GlyphMetrics = text_types.GlyphMetrics;
pub const RasterizedGlyph = text_types.RasterizedGlyph;
pub const FontFace = font_face_mod.FontFace;

pub const MockFontFace = struct {
    // =========================================================================
    // Call Tracking
    // =========================================================================

    glyph_index_count: u32 = 0,
    glyph_advance_count: u32 = 0,
    glyph_metrics_count: u32 = 0,
    render_glyph_count: u32 = 0,
    deinit_count: u32 = 0,

    // =========================================================================
    // Last Values (for verification)
    // =========================================================================

    last_codepoint: ?u21 = null,
    last_glyph_id: ?u16 = null,
    last_font_size: ?f32 = null,
    last_scale: ?f32 = null,
    last_subpixel_x: ?f32 = null,
    last_subpixel_y: ?f32 = null,

    // =========================================================================
    // Configurable Behavior
    // =========================================================================

    /// Codepoint to glyph ID mapping
    glyph_map: std.AutoHashMap(u21, u16),

    /// Glyph ID to advance width mapping
    advance_map: std.AutoHashMap(u16, f32),

    /// Glyph ID to metrics mapping
    metrics_map: std.AutoHashMap(u16, GlyphMetrics),

    /// Default glyph ID for unmapped codepoints (0 = .notdef)
    default_glyph_id: u16 = 0,

    /// Default advance width for unmapped glyphs
    default_advance: f32 = 10.0,

    /// Default glyph metrics
    default_glyph_metrics: GlyphMetrics = .{
        .glyph_id = 0,
        .advance_x = 10.0,
        .advance_y = 0,
        .bearing_x = 0,
        .bearing_y = 10.0,
        .width = 8.0,
        .height = 12.0,
    },

    /// Font metrics (accessible via FontFace.metrics)
    metrics: Metrics = defaultMetrics(),

    // =========================================================================
    // Controllable Failures
    // =========================================================================

    should_fail_render: bool = false,
    render_error: anyerror = error.MockRenderFailure,

    /// Fill rendered glyph buffer with this value
    render_fill_value: u8 = 0xAA,

    /// Dimensions for rendered glyphs
    render_width: u32 = 10,
    render_height: u32 = 12,

    // =========================================================================
    // Internal State
    // =========================================================================

    allocator: std.mem.Allocator,

    const Self = @This();

    pub const Error = error{
        MockRenderFailure,
        BufferTooSmall,
    };

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .glyph_map = std.AutoHashMap(u21, u16).init(allocator),
            .advance_map = std.AutoHashMap(u16, f32).init(allocator),
            .metrics_map = std.AutoHashMap(u16, GlyphMetrics).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.deinit_count += 1;
        self.glyph_map.deinit();
        self.advance_map.deinit();
        self.metrics_map.deinit();
    }

    // =========================================================================
    // Configuration Methods
    // =========================================================================

    /// Map a codepoint to a glyph ID
    pub fn setGlyphMapping(self: *Self, codepoint: u21, glyph_id: u16) !void {
        try self.glyph_map.put(codepoint, glyph_id);
    }

    /// Set advance width for a glyph
    pub fn setGlyphAdvance(self: *Self, glyph_id: u16, advance: f32) !void {
        try self.advance_map.put(glyph_id, advance);
    }

    /// Set full metrics for a glyph
    pub fn setGlyphMetrics(self: *Self, glyph_id: u16, glyph_metrics: GlyphMetrics) !void {
        try self.metrics_map.put(glyph_id, glyph_metrics);
    }

    /// Configure as a simple ASCII font (A-Z, a-z, 0-9 mapped to sequential IDs)
    pub fn configureAsAsciiFont(self: *Self) !void {
        var id: u16 = 1;

        // Uppercase A-Z
        var c: u21 = 'A';
        while (c <= 'Z') : (c += 1) {
            try self.setGlyphMapping(c, id);
            id += 1;
        }

        // Lowercase a-z
        c = 'a';
        while (c <= 'z') : (c += 1) {
            try self.setGlyphMapping(c, id);
            id += 1;
        }

        // Digits 0-9
        c = '0';
        while (c <= '9') : (c += 1) {
            try self.setGlyphMapping(c, id);
            id += 1;
        }

        // Space
        try self.setGlyphMapping(' ', id);
    }

    /// Configure as a monospace font with uniform advance
    pub fn configureAsMonospace(self: *Self, cell_width: f32) void {
        self.default_advance = cell_width;
        self.metrics.is_monospace = true;
        self.metrics.cell_width = cell_width;
    }

    // =========================================================================
    // FontFace Interface Implementation
    // =========================================================================

    /// Get glyph ID for a codepoint
    pub fn glyphIndex(self: *Self, codepoint: u21) u16 {
        self.glyph_index_count += 1;
        self.last_codepoint = codepoint;

        return self.glyph_map.get(codepoint) orelse self.default_glyph_id;
    }

    /// Get advance width for a glyph
    pub fn glyphAdvance(self: *Self, glyph_id: u16) f32 {
        self.glyph_advance_count += 1;
        self.last_glyph_id = glyph_id;

        return self.advance_map.get(glyph_id) orelse self.default_advance;
    }

    /// Get metrics for a glyph
    pub fn glyphMetrics(self: *Self, glyph_id: u16) GlyphMetrics {
        self.glyph_metrics_count += 1;
        self.last_glyph_id = glyph_id;

        if (self.metrics_map.get(glyph_id)) |m| {
            return m;
        }

        // Return default metrics with the requested glyph_id
        var m = self.default_glyph_metrics;
        m.glyph_id = glyph_id;
        m.advance_x = self.advance_map.get(glyph_id) orelse self.default_advance;
        return m;
    }

    /// Render a glyph with subpixel positioning
    pub fn renderGlyphSubpixel(
        self: *Self,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) anyerror!RasterizedGlyph {
        self.render_glyph_count += 1;
        self.last_glyph_id = glyph_id;
        self.last_font_size = font_size;
        self.last_scale = scale;
        self.last_subpixel_x = subpixel_x;
        self.last_subpixel_y = subpixel_y;

        if (self.should_fail_render) {
            return self.render_error;
        }

        // Calculate buffer requirements (RGBA for color, grayscale otherwise)
        const w = self.render_width;
        const h = self.render_height;
        const required = w * h; // Grayscale

        if (buffer_size < required or buffer.len < required) {
            return Error.BufferTooSmall;
        }

        // Fill buffer with test pattern
        @memset(buffer[0..required], self.render_fill_value);

        const glyph_metrics = self.glyphMetrics(glyph_id);
        // Undo the count increment from glyphMetrics call
        self.glyph_metrics_count -= 1;

        return RasterizedGlyph{
            .width = w,
            .height = h,
            .offset_x = @intFromFloat(glyph_metrics.bearing_x * scale),
            .offset_y = @intFromFloat(glyph_metrics.bearing_y * scale),
            .advance_x = glyph_metrics.advance_x,
            .is_color = false,
        };
    }

    // =========================================================================
    // FontFace VTable Interface
    // =========================================================================

    /// Get a FontFace interface backed by this mock
    pub fn fontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    // =========================================================================
    // Test Utilities
    // =========================================================================

    /// Reset all counters and last values (for test isolation)
    pub fn reset(self: *Self) void {
        self.glyph_index_count = 0;
        self.glyph_advance_count = 0;
        self.glyph_metrics_count = 0;
        self.render_glyph_count = 0;
        // Don't reset deinit_count - that tracks actual deinit calls

        self.last_codepoint = null;
        self.last_glyph_id = null;
        self.last_font_size = null;
        self.last_scale = null;
        self.last_subpixel_x = null;
        self.last_subpixel_y = null;

        self.should_fail_render = false;
    }

    /// Clear all glyph mappings
    pub fn clearMappings(self: *Self) void {
        self.glyph_map.clearRetainingCapacity();
        self.advance_map.clearRetainingCapacity();
        self.metrics_map.clearRetainingCapacity();
    }

    /// Get total method calls (excluding deinit)
    pub fn totalCalls(self: *const Self) u32 {
        return self.glyph_index_count +
            self.glyph_advance_count +
            self.glyph_metrics_count +
            self.render_glyph_count;
    }

    // =========================================================================
    // Default Metrics
    // =========================================================================

    fn defaultMetrics() Metrics {
        return Metrics{
            .units_per_em = 1000,
            .ascender = 12.0,
            .descender = 3.0,
            .line_gap = 1.0,
            .cap_height = 10.0,
            .x_height = 7.0,
            .underline_position = -1.5,
            .underline_thickness = 1.0,
            .line_height = 16.0,
            .point_size = 12.0,
            .is_monospace = false,
            .cell_width = 0,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MockFontFace basic glyph lookup" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    try mock.setGlyphMapping('A', 65);
    try mock.setGlyphMapping('B', 66);

    try std.testing.expectEqual(@as(u16, 65), mock.glyphIndex('A'));
    try std.testing.expectEqual(@as(u16, 66), mock.glyphIndex('B'));
    try std.testing.expectEqual(@as(u16, 0), mock.glyphIndex('C')); // unmapped

    try std.testing.expectEqual(@as(u32, 3), mock.glyph_index_count);
    try std.testing.expectEqual(@as(u21, 'C'), mock.last_codepoint.?);
}

test "MockFontFace via FontFace interface" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    try mock.setGlyphMapping('X', 100);
    try mock.setGlyphAdvance(100, 15.0);

    var face = mock.fontFace();

    try std.testing.expectEqual(@as(u16, 100), face.glyphIndex('X'));
    try std.testing.expectEqual(@as(f32, 15.0), face.glyphAdvance(100));
    try std.testing.expectEqual(@as(u32, 1), mock.glyph_index_count);
    try std.testing.expectEqual(@as(u32, 1), mock.glyph_advance_count);
}

test "MockFontFace glyph metrics" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    const custom_metrics = GlyphMetrics{
        .glyph_id = 42,
        .advance_x = 20.0,
        .advance_y = 0,
        .bearing_x = 2.0,
        .bearing_y = 15.0,
        .width = 16.0,
        .height = 18.0,
    };
    try mock.setGlyphMetrics(42, custom_metrics);

    const result = mock.glyphMetrics(42);
    try std.testing.expectEqual(@as(f32, 20.0), result.advance_x);
    try std.testing.expectEqual(@as(f32, 2.0), result.bearing_x);
    try std.testing.expectEqual(@as(f32, 16.0), result.width);
}

test "MockFontFace render glyph" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    var buffer: [1024]u8 = undefined;

    const result = try mock.renderGlyphSubpixel(
        42,
        16.0,
        2.0,
        0.25,
        0.0,
        &buffer,
        1024,
    );

    try std.testing.expectEqual(@as(u32, 10), result.width);
    try std.testing.expectEqual(@as(u32, 12), result.height);
    try std.testing.expectEqual(@as(u32, 1), mock.render_glyph_count);
    try std.testing.expectEqual(@as(f32, 16.0), mock.last_font_size.?);
    try std.testing.expectEqual(@as(f32, 2.0), mock.last_scale.?);
    try std.testing.expectEqual(@as(f32, 0.25), mock.last_subpixel_x.?);

    // Verify buffer was filled
    try std.testing.expectEqual(@as(u8, 0xAA), buffer[0]);
}

test "MockFontFace render failure" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    mock.should_fail_render = true;
    mock.render_error = error.OutOfMemory;

    var buffer: [1024]u8 = undefined;
    const result = mock.renderGlyphSubpixel(1, 12.0, 1.0, 0, 0, &buffer, 1024);

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(u32, 1), mock.render_glyph_count);
}

test "MockFontFace buffer too small" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    var buffer: [10]u8 = undefined; // Too small for 10x12 glyph
    const result = mock.renderGlyphSubpixel(1, 12.0, 1.0, 0, 0, &buffer, 10);

    try std.testing.expectError(MockFontFace.Error.BufferTooSmall, result);
}

test "MockFontFace configureAsAsciiFont" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    try mock.configureAsAsciiFont();

    // A-Z should be 1-26
    try std.testing.expectEqual(@as(u16, 1), mock.glyphIndex('A'));
    try std.testing.expectEqual(@as(u16, 26), mock.glyphIndex('Z'));

    // a-z should be 27-52
    try std.testing.expectEqual(@as(u16, 27), mock.glyphIndex('a'));
    try std.testing.expectEqual(@as(u16, 52), mock.glyphIndex('z'));

    // 0-9 should be 53-62
    try std.testing.expectEqual(@as(u16, 53), mock.glyphIndex('0'));
    try std.testing.expectEqual(@as(u16, 62), mock.glyphIndex('9'));

    // Space should be 63
    try std.testing.expectEqual(@as(u16, 63), mock.glyphIndex(' '));
}

test "MockFontFace configureAsMonospace" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    mock.configureAsMonospace(8.0);

    try std.testing.expect(mock.metrics.is_monospace);
    try std.testing.expectEqual(@as(f32, 8.0), mock.metrics.cell_width);
    try std.testing.expectEqual(@as(f32, 8.0), mock.default_advance);
}

test "MockFontFace reset" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    _ = mock.glyphIndex('A');
    _ = mock.glyphAdvance(1);
    mock.should_fail_render = true;

    mock.reset();

    try std.testing.expectEqual(@as(u32, 0), mock.glyph_index_count);
    try std.testing.expectEqual(@as(u32, 0), mock.glyph_advance_count);
    try std.testing.expect(mock.last_codepoint == null);
    try std.testing.expect(!mock.should_fail_render);
}

test "MockFontFace metrics access" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    // Modify metrics
    mock.metrics.point_size = 24.0;
    mock.metrics.ascender = 20.0;

    // Access via FontFace interface
    const face = mock.fontFace();
    try std.testing.expectEqual(@as(f32, 24.0), face.metrics.point_size);
    try std.testing.expectEqual(@as(f32, 20.0), face.metrics.ascender);
}

test "MockFontFace totalCalls" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    _ = mock.glyphIndex('A');
    _ = mock.glyphIndex('B');
    _ = mock.glyphAdvance(1);
    _ = mock.glyphMetrics(1);

    try std.testing.expectEqual(@as(u32, 4), mock.totalCalls());
}

test "MockFontFace clearMappings" {
    var mock = MockFontFace.init(std.testing.allocator);
    defer mock.deinit();

    try mock.setGlyphMapping('A', 65);
    try std.testing.expectEqual(@as(u16, 65), mock.glyphIndex('A'));

    mock.clearMappings();

    try std.testing.expectEqual(@as(u16, 0), mock.glyphIndex('A')); // Now returns default
}
