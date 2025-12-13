//! Scene graph for collecting primitives before rendering
//! Similar to GPUI's scene.rs - collects all draw commands for a frame
//!
//! GPU Type Alignment Notes:
//! ========================
//! The primitive types (Point, Size, Bounds, Corners, Edges) are `extern struct`
//! types designed for direct upload to Metal GPU buffers. They have specific
//! memory layouts that match Metal shader expectations.
//!
//! These types are defined in geometry.zig as Gpu* types and re-exported here
//! for backward compatibility. For new code, prefer importing from geometry.zig.
//!
//! Rendering Primitives:
//! ====================
//! - Hsla: Color in HSLA format (GPU-optimized for shaders)
//! - Quad: Rectangle primitive with background, border, corners
//! - Shadow: Drop shadow with blur, offset, color
//! - GlyphInstance: Single glyph for text rendering
//!
//! Scene:
//! =====
//! Collects all primitives for a frame, handles z-ordering and clipping.

const std = @import("std");
const geometry = @import("geometry.zig");

pub const DrawOrder = u32;

// ============================================================================
// GPU Geometry Types (re-exported from geometry.zig)
// ============================================================================

/// 2D point for GPU - extern struct for Metal buffer compatibility
pub const Point = geometry.GpuPoint;

/// 2D size for GPU - extern struct for Metal buffer compatibility
pub const Size = geometry.GpuSize;

/// Bounds (origin + size) for GPU - extern struct for Metal buffer compatibility
pub const Bounds = geometry.GpuBounds;

/// Corner radii for rounded rectangles - extern struct for Metal buffer compatibility
pub const Corners = geometry.GpuCorners;

/// Edge widths (for borders) - extern struct for Metal buffer compatibility
pub const Edges = geometry.GpuEdges;

// ============================================================================
// HSLA Color (GPU-optimized)
// ============================================================================

/// HSLA color format - matches Metal shader expectations
pub const Hsla = extern struct {
    h: f32, // Hue [0, 1]
    s: f32, // Saturation [0, 1]
    l: f32, // Lightness [0, 1]
    a: f32, // Alpha [0, 1]

    pub fn init(h: f32, s: f32, l: f32, a: f32) Hsla {
        return .{ .h = h, .s = s, .l = l, .a = a };
    }

    /// Convert from RGBA to HSLA
    pub fn fromRgba(r: f32, g: f32, b: f32, a: f32) Hsla {
        const max_c = @max(r, @max(g, b));
        const min_c = @min(r, @min(g, b));
        const l = (max_c + min_c) / 2.0;

        if (max_c == min_c) {
            return .{ .h = 0, .s = 0, .l = l, .a = a };
        }

        const d = max_c - min_c;
        const s = if (l > 0.5) d / (2.0 - max_c - min_c) else d / (max_c + min_c);

        var h: f32 = 0;
        if (max_c == r) {
            h = (g - b) / d + (if (g < b) @as(f32, 6.0) else @as(f32, 0.0));
        } else if (max_c == g) {
            h = (b - r) / d + 2.0;
        } else {
            h = (r - g) / d + 4.0;
        }
        h /= 6.0;

        return .{ .h = h, .s = s, .l = l, .a = a };
    }

    /// Convert from geometry.Color to Hsla
    pub fn fromColor(c: geometry.Color) Hsla {
        return fromRgba(c.r, c.g, c.b, c.a);
    }

    // Common colors
    pub const transparent = Hsla{ .h = 0, .s = 0, .l = 0, .a = 0 };
    pub const white = Hsla{ .h = 0, .s = 0, .l = 1, .a = 1 };
    pub const black = Hsla{ .h = 0, .s = 0, .l = 0, .a = 1 };
    pub const red = Hsla{ .h = 0, .s = 1, .l = 0.5, .a = 1 };
    pub const green = Hsla{ .h = 0.333, .s = 1, .l = 0.5, .a = 1 };
    pub const blue = Hsla{ .h = 0.666, .s = 1, .l = 0.5, .a = 1 };
};

// ============================================================================
// Content Mask (for clipping)
// ============================================================================

/// Content mask for clipping (used for clip stack)
pub const ContentMask = struct {
    /// The clip bounds in screen coordinates
    bounds: ClipBounds,

    pub const ClipBounds = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,

        /// Intersect two clip bounds, returning the overlapping region
        pub fn intersect(a: ClipBounds, b: ClipBounds) ClipBounds {
            const x = @max(a.x, b.x);
            const y = @max(a.y, b.y);
            const right = @min(a.x + a.width, b.x + b.width);
            const bottom = @min(a.y + a.height, b.y + b.height);
            return .{
                .x = x,
                .y = y,
                .width = @max(0, right - x),
                .height = @max(0, bottom - y),
            };
        }
    };

    /// Default mask that clips nothing (effectively infinite)
    pub const none = ContentMask{
        .bounds = .{ .x = 0, .y = 0, .width = 99999, .height = 99999 },
    };
};

/// Quad - the fundamental UI rectangle primitive
/// Layout matches Metal shader exactly (with float4 alignment padding)
pub const Quad = extern struct {
    order: DrawOrder = 0,
    _pad0: u32 = 0,
    bounds_origin_x: f32 = 0,
    bounds_origin_y: f32 = 0,
    bounds_size_width: f32 = 0,
    bounds_size_height: f32 = 0,
    clip_origin_x: f32 = -1e9,
    clip_origin_y: f32 = -1e9,
    clip_size_width: f32 = 2e9,
    clip_size_height: f32 = 2e9,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    background: Hsla = Hsla.transparent,
    border_color: Hsla = Hsla.transparent,
    corner_radii: Corners = Corners.zero,
    border_widths: Edges = Edges.zero,

    pub fn filled(x: f32, y: f32, width: f32, height: f32, color: Hsla) Quad {
        return .{
            .bounds_origin_x = x,
            .bounds_origin_y = y,
            .bounds_size_width = width,
            .bounds_size_height = height,
            .background = color,
        };
    }

    pub fn rounded(x: f32, y: f32, width: f32, height: f32, color: Hsla, radius: f32) Quad {
        return .{
            .bounds_origin_x = x,
            .bounds_origin_y = y,
            .bounds_size_width = width,
            .bounds_size_height = height,
            .background = color,
            .corner_radii = Corners.all(radius),
        };
    }

    pub fn withBorder(self: Quad, color: Hsla, width: f32) Quad {
        var q = self;
        q.border_color = color;
        q.border_widths = Edges.all(width);
        return q;
    }

    /// Create a quad with explicit clip bounds
    pub fn withClipBounds(self: Quad, clip: ContentMask.ClipBounds) Quad {
        var q = self;
        q.clip_origin_x = clip.x;
        q.clip_origin_y = clip.y;
        q.clip_size_width = clip.width;
        q.clip_size_height = clip.height;
        return q;
    }
};

// ============================================================================
// Shadow Primitive
// ============================================================================

/// Shadow - drop shadow behind UI elements
/// Renders as an expanded, blurred rounded rectangle using SDF.
///
/// Memory layout must match Metal shader exactly.
/// float4 types require 16-byte alignment in Metal!
pub const Shadow = extern struct {
    // Offset 0
    order: DrawOrder = 0,
    _pad0: u32 = 0,

    // Offset 8
    content_origin_x: f32 = 0,
    content_origin_y: f32 = 0,

    // Offset 16
    content_size_width: f32 = 0,
    content_size_height: f32 = 0,

    // Offset 24 - need padding to reach 32 for float4 alignment
    blur_radius: f32 = 10.0,
    offset_x: f32 = 0,

    // Offset 32 (16-byte aligned for float4)
    corner_radii: Corners = Corners.zero,

    // Offset 48 (16-byte aligned for float4)
    color: Hsla = Hsla.init(0, 0, 0, 0.25),

    // Offset 64
    offset_y: f32 = 4.0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
    _pad3: f32 = 0,

    // Total: 80 bytes

    pub fn drop(x: f32, y: f32, width: f32, height: f32, blur: f32) Shadow {
        return .{
            .content_origin_x = x,
            .content_origin_y = y,
            .content_size_width = width,
            .content_size_height = height,
            .blur_radius = blur,
            .color = Hsla.init(0, 0, 0, 0.25),
            .offset_y = blur * 0.4,
        };
    }

    pub fn forQuad(quad: Quad, blur: f32) Shadow {
        return .{
            .content_origin_x = quad.bounds_origin_x,
            .content_origin_y = quad.bounds_origin_y,
            .content_size_width = quad.bounds_size_width,
            .content_size_height = quad.bounds_size_height,
            .corner_radii = quad.corner_radii,
            .blur_radius = blur,
            .color = Hsla.init(0, 0, 0, 0.25),
            .offset_y = blur * 0.4,
        };
    }

    pub fn withColor(self: Shadow, c: Hsla) Shadow {
        var s = self;
        s.color = c;
        return s;
    }

    pub fn withOffset(self: Shadow, x: f32, y: f32) Shadow {
        var s = self;
        s.offset_x = x;
        s.offset_y = y;
        return s;
    }

    pub fn withCornerRadius(self: Shadow, radius: f32) Shadow {
        var s = self;
        s.corner_radii = Corners.all(radius);
        return s;
    }
};

// ============================================================================
// Text/Glyph Primitive
// ============================================================================

/// A single glyph instance for GPU rendering
/// Layout matches Metal shader (must be 16-byte aligned)
pub const GlyphInstance = extern struct {
    // Screen position (top-left of glyph quad)
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    // Glyph size in pixels
    size_x: f32 = 0,
    size_y: f32 = 0,
    // Atlas UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Color (HSLA)
    color: Hsla = Hsla.black,
    // Clip bounds (content mask) - defaults to no clipping
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    pub fn init(
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        uv_left: f32,
        uv_top: f32,
        uv_right: f32,
        uv_bottom: f32,
        color: Hsla,
    ) GlyphInstance {
        return .{
            .pos_x = x,
            .pos_y = y,
            .size_x = width,
            .size_y = height,
            .uv_left = uv_left,
            .uv_top = uv_top,
            .uv_right = uv_right,
            .uv_bottom = uv_bottom,
            .color = color,
        };
    }

    /// Create a glyph with explicit clip bounds
    pub fn withClipBounds(self: GlyphInstance, clip: ContentMask.ClipBounds) GlyphInstance {
        var g = self;
        g.clip_x = clip.x;
        g.clip_y = clip.y;
        g.clip_width = clip.width;
        g.clip_height = clip.height;
        return g;
    }
};

// ============================================================================
// Scene - collects primitives for rendering
// ============================================================================

pub const Scene = struct {
    allocator: std.mem.Allocator,
    shadows: std.ArrayList(Shadow),
    quads: std.ArrayList(Quad),
    glyphs: std.ArrayList(GlyphInstance),
    next_order: DrawOrder,
    // Clip mask stack for nested clipping regions
    clip_stack: std.ArrayList(ContentMask.ClipBounds),
    // Track if out-of-order inserts occurred (requiring sort)
    needs_sort: bool,

    // Viewport culling
    viewport_width: f32,
    viewport_height: f32,
    culling_enabled: bool,

    // Stats tracking (optional)
    stats: ?*@import("render_stats.zig").RenderStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .shadows = .{},
            .quads = .{},
            .glyphs = .{},
            .next_order = 0,
            .clip_stack = .{},
            .needs_sort = false,
            // Viewport culling - disabled by default (0 = no culling)
            .viewport_width = 0,
            .viewport_height = 0,
            .culling_enabled = false,
            .stats = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shadows.deinit(self.allocator);
        self.quads.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.clip_stack.deinit(self.allocator);
    }

    pub fn clear(self: *Self) void {
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();
        self.next_order = 0;
        self.needs_sort = false;
    }

    // ========================================================================
    // Clip Stack Management
    // ========================================================================

    /// Push a clip region onto the stack (intersects with current clip)
    pub fn pushClip(self: *Self, bounds: ContentMask.ClipBounds) !void {
        const current = self.currentClip();
        const intersected = ContentMask.ClipBounds.intersect(current, bounds);
        try self.clip_stack.append(self.allocator, intersected);
    }

    /// Pop the current clip region from the stack
    pub fn popClip(self: *Self) void {
        if (self.clip_stack.items.len > 0) {
            _ = self.clip_stack.pop();
        }
    }

    /// Get the current clip bounds (or no-clip if stack is empty)
    pub fn currentClip(self: *const Self) ContentMask.ClipBounds {
        if (self.clip_stack.items.len > 0) {
            return self.clip_stack.items[self.clip_stack.items.len - 1];
        }
        return ContentMask.none.bounds;
    }

    // ========================================================================
    // Glyph Insertion
    // ========================================================================

    /// Insert a glyph without clipping
    pub fn insertGlyph(self: *Self, glyph: GlyphInstance) !void {
        try self.glyphs.append(self.allocator, glyph);
    }

    /// Insert a glyph with the current clip mask applied
    pub fn insertGlyphClipped(self: *Self, glyph: GlyphInstance) !void {
        const clip = self.currentClip();
        try self.glyphs.append(self.allocator, glyph.withClipBounds(clip));
    }

    pub fn glyphCount(self: *const Self) usize {
        return self.glyphs.items.len;
    }

    pub fn getGlyphs(self: *const Self) []const GlyphInstance {
        return self.glyphs.items;
    }

    /// Insert a shadow (call BEFORE the quad it shadows)
    pub fn insertShadow(self: *Self, shadow: Shadow) !void {
        // Fast viewport cull - account for blur radius and offset
        if (self.culling_enabled) {
            const expand = shadow.blur_radius * 2; // Shadow extends beyond content
            const left = shadow.content_origin_x + shadow.offset_x - expand;
            const top = shadow.content_origin_y + shadow.offset_y - expand;
            const right = left + shadow.content_size_width + expand * 2;
            const bottom = top + shadow.content_size_height + expand * 2;

            if (right < 0 or left > self.viewport_width or
                bottom < 0 or top > self.viewport_height)
            {
                if (self.stats) |s| s.recordShadowsCulled(1);
                return;
            }
        }

        var s = shadow;
        s.order = self.next_order;
        self.next_order += 1;
        try self.shadows.append(self.allocator, s);
    }

    pub fn insertQuad(self: *Self, quad: Quad) !void {
        // Fast viewport cull - skip if completely outside viewport
        if (self.culling_enabled) {
            const right = quad.bounds_origin_x + quad.bounds_size_width;
            const bottom = quad.bounds_origin_y + quad.bounds_size_height;

            if (right < 0 or quad.bounds_origin_x > self.viewport_width or
                bottom < 0 or quad.bounds_origin_y > self.viewport_height)
            {
                // Quad is fully outside viewport - skip it
                if (self.stats) |s| s.recordQuadsCulled(1);
                return;
            }
        }

        var q = quad;
        q.order = self.next_order;
        self.next_order += 1;
        try self.quads.append(self.allocator, q);
    }

    /// Insert a quad with its shadow in one call
    pub fn insertQuadWithShadow(self: *Self, quad: Quad, blur_radius: f32) !void {
        try self.insertShadow(Shadow.forQuad(quad, blur_radius));
        try self.insertQuad(quad);
    }

    /// Check if there's an active clip (clip stack is not empty)
    pub fn hasActiveClip(self: *const Self) bool {
        return self.clip_stack.items.len > 0;
    }

    /// Insert a quad with the current clip mask applied
    pub fn insertQuadClipped(self: *Self, quad: Quad) !void {
        const clip = self.currentClip();

        // Cull against clip bounds (even tighter than viewport)
        const right = quad.bounds_origin_x + quad.bounds_size_width;
        const bottom = quad.bounds_origin_y + quad.bounds_size_height;

        if (right < clip.x or quad.bounds_origin_x > clip.x + clip.width or
            bottom < clip.y or quad.bounds_origin_y > clip.y + clip.height)
        {
            // Quad is fully outside clip region - skip entirely
            if (self.stats) |s| s.recordQuadsCulled(1);
            return;
        }

        // Also check viewport if enabled
        if (self.culling_enabled) {
            if (right < 0 or quad.bounds_origin_x > self.viewport_width or
                bottom < 0 or quad.bounds_origin_y > self.viewport_height)
            {
                if (self.stats) |s| s.recordQuadsCulled(1);
                return;
            }
        }

        var q = quad.withClipBounds(clip);
        q.order = self.next_order;
        self.next_order += 1;
        try self.quads.append(self.allocator, q);
    }

    /// Finalize the scene for rendering.
    /// Sorts primitives by draw order only if out-of-order inserts occurred.
    pub fn finish(self: *Self) void {
        // Fast path: elements are inserted in order via next_order, no sort needed
        if (!self.needs_sort) return;

        // Slow path: sort by draw order (future: if insertWithOrder is added)
        std.sort.pdq(Shadow, self.shadows.items, {}, struct {
            fn lessThan(_: void, a: Shadow, b: Shadow) bool {
                return a.order < b.order;
            }
        }.lessThan);
        std.sort.pdq(Quad, self.quads.items, {}, struct {
            fn lessThan(_: void, a: Quad, b: Quad) bool {
                return a.order < b.order;
            }
        }.lessThan);
    }

    pub fn shadowCount(self: *const Self) usize {
        return self.shadows.items.len;
    }

    pub fn quadCount(self: *const Self) usize {
        return self.quads.items.len;
    }

    pub fn getShadows(self: *const Self) []const Shadow {
        return self.shadows.items;
    }

    pub fn getQuads(self: *const Self) []const Quad {
        return self.quads.items;
    }

    /// Check if a point is inside a quad bounds
    fn quadContainsPoint(quad: Quad, x: f32, y: f32) bool {
        return x >= quad.bounds_origin_x and
            x <= quad.bounds_origin_x + quad.bounds_size_width and
            y >= quad.bounds_origin_y and
            y <= quad.bounds_origin_y + quad.bounds_size_height;
    }

    /// Find quad at point, returns index (for stable reference)
    pub fn quadIndexAtPoint(self: *const Self, x: f32, y: f32) ?usize {
        var i = self.quads.items.len;
        while (i > 0) {
            i -= 1;
            if (quadContainsPoint(self.quads.items[i], x, y)) {
                return i;
            }
        }
        return null;
    }

    /// Set viewport for culling. Call this before inserting primitives.
    pub fn setViewport(self: *Self, width: f32, height: f32) void {
        self.viewport_width = width;
        self.viewport_height = height;
    }

    /// Disable viewport culling
    pub fn disableCulling(self: *Self) void {
        self.culling_enabled = false;
    }

    /// Enabled viewport culling
    /// Primitives fully outside the viewport will be skipped.
    pub fn enableCulling(self: *Self) void {
        self.culling_enabled = true;
    }

    /// Attach stats tracker (optional)
    pub fn setStats(self: *Self, stats: *@import("render_stats.zig").RenderStats) void {
        self.stats = stats;
    }
};

test "Scene finish skips sort when elements are in order" {
    const testing = std.testing;
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    // Insert elements in order (normal case)
    try scene.insertQuad(.{ .bounds_origin_x = 0, .bounds_origin_y = 0, .bounds_size_width = 10, .bounds_size_height = 10 });
    try scene.insertQuad(.{ .bounds_origin_x = 10, .bounds_origin_y = 10, .bounds_size_width = 10, .bounds_size_height = 10 });
    try scene.insertQuad(.{ .bounds_origin_x = 20, .bounds_origin_y = 20, .bounds_size_width = 10, .bounds_size_height = 10 });

    // needs_sort should be false
    try testing.expect(!scene.needs_sort);

    // finish() should be a no-op (fast path)
    scene.finish();

    // Verify order is preserved
    try testing.expectEqual(@as(DrawOrder, 0), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[1].order);
    try testing.expectEqual(@as(DrawOrder, 2), scene.quads.items[2].order);
}
