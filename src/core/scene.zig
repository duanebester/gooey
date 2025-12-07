//! Scene graph for collecting primitives before rendering
//! Similar to GPUI's scene.rs - collects all draw commands for a frame

const std = @import("std");

pub const DrawOrder = u32;

// ============================================================================
// Primitive Types (extern structs for GPU compatibility)
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

    // Common colors
    pub const transparent = Hsla{ .h = 0, .s = 0, .l = 0, .a = 0 };
    pub const white = Hsla{ .h = 0, .s = 0, .l = 1, .a = 1 };
    pub const black = Hsla{ .h = 0, .s = 0, .l = 0, .a = 1 };
    pub const red = Hsla{ .h = 0, .s = 1, .l = 0.5, .a = 1 };
    pub const green = Hsla{ .h = 0.333, .s = 1, .l = 0.5, .a = 1 };
    pub const blue = Hsla{ .h = 0.666, .s = 1, .l = 0.5, .a = 1 };
};

/// 2D point for GPU
pub const Point = extern struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }

    pub const zero = Point{ .x = 0, .y = 0 };
};

/// 2D size for GPU
pub const Size = extern struct {
    width: f32,
    height: f32,

    pub fn init(width: f32, height: f32) Size {
        return .{ .width = width, .height = height };
    }

    pub const zero = Size{ .width = 0, .height = 0 };
};

/// Bounds (origin + size) for GPU
pub const Bounds = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: f32, y: f32, width: f32, height: f32) Bounds {
        return .{
            .origin = Point.init(x, y),
            .size = Size.init(width, height),
        };
    }

    pub const zero = Bounds{ .origin = Point.zero, .size = Size.zero };
};

/// Corner radii for rounded rectangles
pub const Corners = extern struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(radius: f32) Corners {
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_right = radius,
            .bottom_left = radius,
        };
    }

    pub const zero = Corners{};
};

/// Edge widths (for borders)
pub const Edges = extern struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(width: f32) Edges {
        return .{ .top = width, .right = width, .bottom = width, .left = width };
    }

    pub const zero = Edges{};
};

/// Content mask for clipping
pub const ContentMask = extern struct {
    bounds: Bounds,

    pub fn infinite() ContentMask {
        return .{ .bounds = Bounds.init(-1e9, -1e9, 2e9, 2e9) };
    }
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
// Scene - collects primitives for rendering
// ============================================================================

pub const Scene = struct {
    allocator: std.mem.Allocator,
    shadows: std.ArrayList(Shadow),
    quads: std.ArrayList(Quad),
    next_order: DrawOrder,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .shadows = .{},
            .quads = .{},
            .next_order = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shadows.deinit(self.allocator);
        self.quads.deinit(self.allocator);
    }

    pub fn clear(self: *Self) void {
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.next_order = 0;
    }

    /// Insert a shadow (call BEFORE the quad it shadows)
    pub fn insertShadow(self: *Self, shadow: Shadow) !void {
        var s = shadow;
        s.order = self.next_order;
        self.next_order += 1;
        try self.shadows.append(self.allocator, s);
    }

    pub fn insertQuad(self: *Self, quad: Quad) !void {
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

    pub fn finish(self: *Self) void {
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
};
