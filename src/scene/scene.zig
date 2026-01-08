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
const geometry = @import("../core/geometry.zig");
const svg_instance_mod = @import("svg_instance.zig");
pub const SvgInstance = svg_instance_mod.SvgInstance;
const image_instance_mod = @import("image_instance.zig");
pub const ImageInstance = image_instance_mod.ImageInstance;
const path_instance_mod = @import("path_instance.zig");
pub const PathInstance = path_instance_mod.PathInstance;
const mesh_pool_mod = @import("mesh_pool.zig");
pub const MeshPool = mesh_pool_mod.MeshPool;
pub const MeshRef = mesh_pool_mod.MeshRef;
const path_mesh_mod = @import("path_mesh.zig");
pub const PathMesh = path_mesh_mod.PathMesh;
pub const PathVertex = path_mesh_mod.PathVertex;
const gradient_uniforms_mod = @import("gradient_uniforms.zig");
pub const GradientUniforms = gradient_uniforms_mod.GradientUniforms;
const gradient_mod = @import("../core/gradient.zig");
pub const LinearGradient = gradient_mod.LinearGradient;
pub const RadialGradient = gradient_mod.RadialGradient;

// ============================================================================
// Hard Limits (static memory allocation policy)
// ============================================================================

/// Maximum quads per frame - fail fast if exceeded
pub const MAX_QUADS_PER_FRAME = 65536;

/// Maximum glyphs per frame - fail fast if exceeded
pub const MAX_GLYPHS_PER_FRAME = 65536;

/// Maximum shadows per frame - fail fast if exceeded
pub const MAX_SHADOWS_PER_FRAME = 4096;

/// Maximum SVG instances per frame - fail fast if exceeded
pub const MAX_SVGS_PER_FRAME = 8192;

/// Maximum image instances per frame - fail fast if exceeded
pub const MAX_IMAGES_PER_FRAME = 4096;

/// Maximum path instances per frame - fail fast if exceeded
pub const MAX_PATHS_PER_FRAME = 4096;

/// Maximum clip stack depth - fail fast if exceeded
pub const MAX_CLIP_STACK_DEPTH = 32;

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
        // Assert valid bounds: dimensions must be non-negative
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        return .{
            .bounds_origin_x = x,
            .bounds_origin_y = y,
            .bounds_size_width = width,
            .bounds_size_height = height,
            .background = color,
        };
    }

    pub fn rounded(x: f32, y: f32, width: f32, height: f32, color: Hsla, radius: f32) Quad {
        // Assert valid bounds: dimensions and radius must be non-negative
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        std.debug.assert(radius >= 0);
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
        // Assert valid border width
        std.debug.assert(width >= 0);
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

comptime {
    // Quad must be 112 bytes for proper GPU buffer alignment
    if (@sizeOf(Quad) != 112) {
        @compileError(std.fmt.comptimePrint(
            "Quad must be 112 bytes, got {}",
            .{@sizeOf(Quad)},
        ));
    }
    // Verify background is at 16-byte aligned offset for Metal float4
    if (@offsetOf(Quad, "background") != 48) {
        @compileError(std.fmt.comptimePrint(
            "Quad.background must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(Quad, "background")},
        ));
    }
}

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
        // Assert valid bounds: dimensions and blur must be non-negative
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        std.debug.assert(blur >= 0);
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
        // Assert valid blur radius
        std.debug.assert(blur >= 0);
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
        // Assert valid corner radius
        std.debug.assert(radius >= 0);
        var s = self;
        s.corner_radii = Corners.all(radius);
        return s;
    }
};

comptime {
    // Shadow must be 80 bytes for proper GPU buffer alignment
    if (@sizeOf(Shadow) != 80) {
        @compileError(std.fmt.comptimePrint(
            "Shadow must be 80 bytes, got {}",
            .{@sizeOf(Shadow)},
        ));
    }
    // Verify corner_radii is at 16-byte aligned offset for Metal float4
    if (@offsetOf(Shadow, "corner_radii") != 32) {
        @compileError(std.fmt.comptimePrint(
            "Shadow.corner_radii must be at offset 32 for Metal float4 alignment, got {}",
            .{@offsetOf(Shadow, "corner_radii")},
        ));
    }
    // Verify color is at 16-byte aligned offset for Metal float4
    if (@offsetOf(Shadow, "color") != 48) {
        @compileError(std.fmt.comptimePrint(
            "Shadow.color must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(Shadow, "color")},
        ));
    }
}

// ============================================================================
// Text/Glyph Primitive
// ============================================================================

/// A single glyph instance for GPU rendering
/// Layout matches Metal shader (must be 16-byte aligned)
pub const GlyphInstance = extern struct {
    // Draw order for z-index interleaving
    order: DrawOrder = 0,
    _pad0: u32 = 0,
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
    // Padding to align color (float4) to 16-byte boundary
    // Without this, color is at offset 40; Metal requires float4 at 16-byte aligned offset (48)
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    // Color (HSLA) - must be at 16-byte aligned offset for Metal float4
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
        // Assert valid size: dimensions must be non-negative
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        // Assert valid UV coordinates: must be in normalized range [0, 1]
        std.debug.assert(uv_left >= 0 and uv_left <= 1);
        std.debug.assert(uv_top >= 0 and uv_top <= 1);
        std.debug.assert(uv_right >= 0 and uv_right <= 1);
        std.debug.assert(uv_bottom >= 0 and uv_bottom <= 1);
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

comptime {
    if (@sizeOf(GlyphInstance) != 80) {
        @compileError(std.fmt.comptimePrint(
            "GlyphInstance must be 80 bytes, got {}",
            .{@sizeOf(GlyphInstance)},
        ));
    }
    // Verify color is at 16-byte aligned offset for Metal float4
    if (@offsetOf(GlyphInstance, "color") != 48) {
        @compileError(std.fmt.comptimePrint(
            "GlyphInstance.color must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(GlyphInstance, "color")},
        ));
    }
}

// ============================================================================
// Scene - collects primitives for rendering
// ============================================================================

pub const Scene = struct {
    allocator: std.mem.Allocator,
    // Using ArrayListUnmanaged for static memory allocation policy:
    // Pre-allocate at init, no dynamic growth during rendering
    shadows: std.ArrayListUnmanaged(Shadow),
    quads: std.ArrayListUnmanaged(Quad),
    glyphs: std.ArrayListUnmanaged(GlyphInstance),
    svg_instances: std.ArrayListUnmanaged(SvgInstance),
    images: std.ArrayListUnmanaged(ImageInstance),
    path_instances: std.ArrayListUnmanaged(PathInstance),
    /// Parallel array of gradient data for path instances (same index as path_instances)
    /// If path_instances[i].hasGradient(), use path_gradients[i] for stop data
    path_gradients: std.ArrayListUnmanaged(GradientUniforms),
    mesh_pool: MeshPool,
    next_order: DrawOrder,
    // Clip mask stack for nested clipping regions
    clip_stack: std.ArrayListUnmanaged(ContentMask.ClipBounds),
    // Per-array dirty flags: track which arrays had out-of-order inserts (requiring sort)
    needs_sort_shadows: bool,
    needs_sort_quads: bool,
    needs_sort_glyphs: bool,
    needs_sort_svgs: bool,
    needs_sort_images: bool,
    needs_sort_paths: bool,

    // Viewport culling
    viewport_width: f32,
    viewport_height: f32,
    culling_enabled: bool,

    // Stats tracking (optional)
    stats: ?*@import("../debug/render_stats.zig").RenderStats,

    const Self = @This();

    /// Initialize scene without pre-allocation (for tests or simple usage).
    /// For production, prefer initCapacity() to avoid allocations during rendering.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .shadows = .{},
            .quads = .{},
            .glyphs = .{},
            .svg_instances = .{},
            .images = .{},
            .path_instances = .{},
            .path_gradients = .{},
            .mesh_pool = MeshPool.init(allocator),
            .next_order = 0,
            .clip_stack = .{},
            .needs_sort_shadows = false,
            .needs_sort_quads = false,
            .needs_sort_glyphs = false,
            .needs_sort_svgs = false,
            .needs_sort_images = false,
            .needs_sort_paths = false,
            // Viewport culling - disabled by default (0 = no culling)
            .viewport_width = 0,
            .viewport_height = 0,
            .culling_enabled = false,
            .stats = null,
        };
    }

    /// Initialize scene with pre-allocated capacity for all primitive arrays.
    /// This eliminates dynamic allocation during frame rendering.
    /// Uses the hard limits defined at module level.
    pub fn initCapacity(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .shadows = .{},
            .quads = .{},
            .glyphs = .{},
            .svg_instances = .{},
            .images = .{},
            .path_instances = .{},
            .path_gradients = .{},
            .mesh_pool = MeshPool.init(allocator),
            .next_order = 0,
            .clip_stack = .{},
            .needs_sort_shadows = false,
            .needs_sort_quads = false,
            .needs_sort_glyphs = false,
            .needs_sort_svgs = false,
            .needs_sort_images = false,
            .needs_sort_paths = false,
            .viewport_width = 0,
            .viewport_height = 0,
            .culling_enabled = false,
            .stats = null,
        };

        // Pre-allocate all arrays to their maximum capacity
        try self.shadows.ensureTotalCapacity(allocator, MAX_SHADOWS_PER_FRAME);
        try self.quads.ensureTotalCapacity(allocator, MAX_QUADS_PER_FRAME);
        try self.glyphs.ensureTotalCapacity(allocator, MAX_GLYPHS_PER_FRAME);
        try self.svg_instances.ensureTotalCapacity(allocator, MAX_SVGS_PER_FRAME);
        try self.images.ensureTotalCapacity(allocator, MAX_IMAGES_PER_FRAME);
        try self.path_instances.ensureTotalCapacity(allocator, MAX_PATHS_PER_FRAME);
        try self.path_gradients.ensureTotalCapacity(allocator, MAX_PATHS_PER_FRAME);
        try self.clip_stack.ensureTotalCapacity(allocator, MAX_CLIP_STACK_DEPTH);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.shadows.deinit(self.allocator);
        self.quads.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.svg_instances.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.path_instances.deinit(self.allocator);
        self.path_gradients.deinit(self.allocator);
        self.clip_stack.deinit(self.allocator);
        self.mesh_pool.deinit();
    }

    pub fn clear(self: *Self) void {
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.svg_instances.clearRetainingCapacity();
        self.images.clearRetainingCapacity();
        self.path_instances.clearRetainingCapacity();
        self.path_gradients.clearRetainingCapacity();
        self.mesh_pool.resetFrame();
        self.clip_stack.clearRetainingCapacity();
        self.next_order = 0;
        self.needs_sort_shadows = false;
        self.needs_sort_quads = false;
        self.needs_sort_glyphs = false;
        self.needs_sort_svgs = false;
        self.needs_sort_images = false;
        self.needs_sort_paths = false;
    }

    // ========================================================================
    // Clip Stack Management
    // ========================================================================

    /// Push a clip region onto the stack (intersects with current clip)
    pub fn pushClip(self: *Self, bounds: ContentMask.ClipBounds) !void {
        std.debug.assert(self.clip_stack.items.len < MAX_CLIP_STACK_DEPTH);
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
    // Draw Order Management
    // ========================================================================

    /// Reserve a draw order for later use (e.g., for deferred SVG/image rendering).
    /// This allows primitives to maintain correct z-ordering even when their
    /// actual insertion is deferred until after layout computation.
    pub fn reserveOrder(self: *Self) DrawOrder {
        const order = self.next_order;
        self.next_order += 1;
        return order;
    }

    // ========================================================================
    // SVG Insertion
    // ========================================================================

    /// Insert an SVG instance without clipping
    pub fn insertSvg(self: *Self, instance: SvgInstance) !void {
        std.debug.assert(self.svg_instances.items.len < MAX_SVGS_PER_FRAME);
        var inst = instance;
        inst.order = self.next_order;
        self.next_order += 1;
        try self.svg_instances.append(self.allocator, inst);
    }

    /// Insert an SVG instance with the current clip mask applied
    pub fn insertSvgClipped(self: *Self, instance: SvgInstance) !void {
        std.debug.assert(self.svg_instances.items.len < MAX_SVGS_PER_FRAME);
        const clip = self.currentClip();
        var inst = instance.withClip(clip.x, clip.y, clip.width, clip.height);
        inst.order = self.next_order;
        self.next_order += 1;
        try self.svg_instances.append(self.allocator, inst);
    }

    /// Insert an SVG instance with a pre-reserved draw order and saved clip bounds.
    /// Use this when the draw order was reserved earlier via reserveOrder().
    /// The clip bounds should be captured at the same time as the draw order.
    pub fn insertSvgWithOrder(self: *Self, instance: SvgInstance, order: DrawOrder, clip: ContentMask.ClipBounds) !void {
        std.debug.assert(self.svg_instances.items.len < MAX_SVGS_PER_FRAME);
        var inst = instance.withClip(clip.x, clip.y, clip.width, clip.height);
        inst.order = order;
        self.needs_sort_svgs = true; // Out-of-order insert requires sorting
        try self.svg_instances.append(self.allocator, inst);
    }

    pub fn svgCount(self: *const Self) usize {
        return self.svg_instances.items.len;
    }

    pub fn getSvgInstances(self: *const Self) []const SvgInstance {
        return self.svg_instances.items;
    }

    // ========================================================================
    // Image Insertion
    // ========================================================================

    /// Insert an image instance without clipping
    pub fn insertImage(self: *Self, instance: ImageInstance) !void {
        std.debug.assert(self.images.items.len < MAX_IMAGES_PER_FRAME);
        var inst = instance;
        inst.order = self.next_order;
        self.next_order += 1;
        try self.images.append(self.allocator, inst);
    }

    /// Insert an image instance with the current clip mask applied
    pub fn insertImageClipped(self: *Self, instance: ImageInstance) !void {
        std.debug.assert(self.images.items.len < MAX_IMAGES_PER_FRAME);
        const clip = self.currentClip();
        var inst = instance.withClip(clip.x, clip.y, clip.width, clip.height);
        inst.order = self.next_order;
        self.next_order += 1;
        try self.images.append(self.allocator, inst);
    }

    /// Insert an image instance with a pre-reserved draw order and saved clip bounds.
    /// Use this when the draw order was reserved earlier via reserveOrder().
    /// The clip bounds should be captured at the same time as the draw order.
    pub fn insertImageWithOrder(self: *Self, instance: ImageInstance, order: DrawOrder, clip: ContentMask.ClipBounds) !void {
        std.debug.assert(self.images.items.len < MAX_IMAGES_PER_FRAME);
        var inst = instance.withClip(clip.x, clip.y, clip.width, clip.height);
        inst.order = order;
        self.needs_sort_images = true; // Out-of-order insert requires sorting
        try self.images.append(self.allocator, inst);
    }

    pub fn imageCount(self: *const Self) usize {
        return self.images.items.len;
    }

    pub fn getImages(self: *const Self) []const ImageInstance {
        return self.images.items;
    }

    // ========================================================================
    // Path Insertion
    // ========================================================================

    /// Insert a path instance without clipping
    pub fn insertPath(self: *Self, instance: PathInstance) !void {
        std.debug.assert(self.path_instances.items.len < MAX_PATHS_PER_FRAME);
        std.debug.assert(instance.index_count > 0);

        var inst = instance;
        inst.order = self.next_order;
        self.next_order += 1;
        try self.path_instances.append(self.allocator, inst);
        // Append empty gradient (will be populated if instance has gradient)
        try self.path_gradients.append(self.allocator, GradientUniforms.none());
    }

    /// Insert a path instance with the current clip mask applied
    pub fn insertPathClipped(self: *Self, instance: PathInstance) !void {
        std.debug.assert(self.path_instances.items.len < MAX_PATHS_PER_FRAME);
        std.debug.assert(instance.index_count > 0);

        const clip = self.currentClip();
        var inst = instance.withClipBounds(clip);
        inst.order = self.next_order;
        self.next_order += 1;
        try self.path_instances.append(self.allocator, inst);
        try self.path_gradients.append(self.allocator, GradientUniforms.none());
    }

    /// Insert a path instance with a pre-reserved draw order
    pub fn insertPathWithOrder(self: *Self, instance: PathInstance, order: DrawOrder, clip: ContentMask.ClipBounds) !void {
        std.debug.assert(self.path_instances.items.len < MAX_PATHS_PER_FRAME);
        std.debug.assert(instance.index_count > 0);

        var inst = instance.withClipBounds(clip);
        inst.order = order;
        self.needs_sort_paths = true; // Out-of-order insert requires sorting
        try self.path_instances.append(self.allocator, inst);
        try self.path_gradients.append(self.allocator, GradientUniforms.none());
    }

    /// Insert a path instance with a linear gradient fill
    pub fn insertPathWithLinearGradient(
        self: *Self,
        instance: PathInstance,
        gradient: LinearGradient,
    ) !void {
        std.debug.assert(self.path_instances.items.len < MAX_PATHS_PER_FRAME);
        std.debug.assert(instance.index_count > 0);
        std.debug.assert(gradient.stop_count >= 2);

        const clip = self.currentClip();
        var inst = instance.withClipBounds(clip);
        inst.order = self.next_order;
        self.next_order += 1;
        try self.path_instances.append(self.allocator, inst);
        try self.path_gradients.append(self.allocator, GradientUniforms.fromLinear(gradient));
    }

    /// Insert a path instance with a radial gradient fill
    pub fn insertPathWithRadialGradient(
        self: *Self,
        instance: PathInstance,
        gradient: RadialGradient,
    ) !void {
        std.debug.assert(self.path_instances.items.len < MAX_PATHS_PER_FRAME);
        std.debug.assert(instance.index_count > 0);
        std.debug.assert(gradient.stop_count >= 2);

        const clip = self.currentClip();
        var inst = instance.withClipBounds(clip);
        inst.order = self.next_order;
        self.next_order += 1;
        try self.path_instances.append(self.allocator, inst);
        try self.path_gradients.append(self.allocator, GradientUniforms.fromRadial(gradient));
    }

    /// Insert a path with a mesh, allocating the mesh in the frame pool
    /// This is a convenience method that handles mesh allocation
    pub fn insertPathWithMesh(
        self: *Self,
        mesh: PathMesh,
        offset_x: f32,
        offset_y: f32,
        fill_color: Hsla,
    ) !void {
        std.debug.assert(!mesh.isEmpty());

        // Allocate mesh in frame pool
        const mesh_ref = try self.mesh_pool.allocateFrame(mesh);

        const inst = PathInstance.initWithBufferRanges(
            mesh_ref,
            offset_x,
            offset_y,
            fill_color,
            0, // vertex_offset - to be set by renderer
            0, // index_offset - to be set by renderer
            @intCast(mesh.indices.len),
        );

        try self.insertPathClipped(inst);
    }

    /// Get mesh pool for external use (e.g., caching persistent meshes)
    pub fn getMeshPool(self: *Self) *MeshPool {
        return &self.mesh_pool;
    }

    pub fn pathCount(self: *const Self) usize {
        return self.path_instances.items.len;
    }

    pub fn getPathInstances(self: *const Self) []const PathInstance {
        return self.path_instances.items;
    }

    /// Get gradient uniforms for path instances (parallel array)
    pub fn getPathGradients(self: *const Self) []const GradientUniforms {
        return self.path_gradients.items;
    }

    // ========================================================================
    // Glyph Insertion
    // ========================================================================

    /// Insert a glyph without clipping
    pub fn insertGlyph(self: *Self, glyph: GlyphInstance) !void {
        std.debug.assert(self.glyphs.items.len < MAX_GLYPHS_PER_FRAME);
        var g = glyph;
        g.order = self.next_order;
        self.next_order += 1;
        try self.glyphs.append(self.allocator, g);

        // Track inserted glyphs for profiler
        if (self.stats) |s| s.recordGlyphs(1);
    }

    /// Insert a glyph with the current clip mask applied
    pub fn insertGlyphClipped(self: *Self, glyph: GlyphInstance) !void {
        std.debug.assert(self.glyphs.items.len < MAX_GLYPHS_PER_FRAME);
        const clip = self.currentClip();
        var g = glyph.withClipBounds(clip);
        g.order = self.next_order;
        self.next_order += 1;
        try self.glyphs.append(self.allocator, g);

        // Track inserted glyphs for profiler
        if (self.stats) |s| s.recordGlyphs(1);
    }

    pub fn glyphCount(self: *const Self) usize {
        return self.glyphs.items.len;
    }

    pub fn getGlyphs(self: *const Self) []const GlyphInstance {
        return self.glyphs.items;
    }

    /// Insert a shadow (call BEFORE the quad it shadows)
    pub fn insertShadow(self: *Self, shadow: Shadow) !void {
        std.debug.assert(self.shadows.items.len < MAX_SHADOWS_PER_FRAME);
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
        std.debug.assert(self.quads.items.len < MAX_QUADS_PER_FRAME);
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

        // Track inserted quads for profiler
        if (self.stats) |s| s.recordQuads(1);
    }

    /// Insert a quad with a caller-specified draw order (for overlays, debug UI, etc.)
    /// This preserves the quad's order field and triggers sorting in finish().
    pub fn insertQuadWithOrder(self: *Self, quad: Quad) !void {
        std.debug.assert(self.quads.items.len < MAX_QUADS_PER_FRAME);
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

        // Preserve caller's order - this will require sorting
        self.needs_sort_quads = true;
        try self.quads.append(self.allocator, quad);

        // Track inserted quads for profiler
        if (self.stats) |s| s.recordQuads(1);
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
        std.debug.assert(self.quads.items.len < MAX_QUADS_PER_FRAME);
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

        // Track inserted quads for profiler
        if (self.stats) |s| s.recordQuads(1);
    }

    /// Finalize the scene for rendering.
    /// Sorts primitives by draw order only for arrays that had out-of-order inserts.
    pub fn finish(self: *Self) void {
        // Only sort arrays that had out-of-order inserts
        if (self.needs_sort_shadows) {
            std.sort.pdq(Shadow, self.shadows.items, {}, struct {
                fn lessThan(_: void, a: Shadow, b: Shadow) bool {
                    return a.order < b.order;
                }
            }.lessThan);
        }
        if (self.needs_sort_quads) {
            std.sort.pdq(Quad, self.quads.items, {}, struct {
                fn lessThan(_: void, a: Quad, b: Quad) bool {
                    return a.order < b.order;
                }
            }.lessThan);
        }
        if (self.needs_sort_glyphs) {
            std.sort.pdq(GlyphInstance, self.glyphs.items, {}, struct {
                fn lessThan(_: void, a: GlyphInstance, b: GlyphInstance) bool {
                    return a.order < b.order;
                }
            }.lessThan);
        }
        if (self.needs_sort_svgs) {
            std.sort.pdq(SvgInstance, self.svg_instances.items, {}, struct {
                fn lessThan(_: void, a: SvgInstance, b: SvgInstance) bool {
                    return a.order < b.order;
                }
            }.lessThan);
        }
        if (self.needs_sort_images) {
            std.sort.pdq(ImageInstance, self.images.items, {}, struct {
                fn lessThan(_: void, a: ImageInstance, b: ImageInstance) bool {
                    return a.order < b.order;
                }
            }.lessThan);
        }
        if (self.needs_sort_paths) {
            // Sort both path_instances and path_gradients together to maintain parallel alignment
            const n = self.path_instances.items.len;
            if (n > 1) {
                // Simple in-place parallel sort using selection sort for correctness
                // (path counts per frame are typically small, so O(n²) is acceptable)
                var i: usize = 0;
                while (i < n - 1) : (i += 1) {
                    var min_idx = i;
                    var j = i + 1;
                    while (j < n) : (j += 1) {
                        if (self.path_instances.items[j].order < self.path_instances.items[min_idx].order) {
                            min_idx = j;
                        }
                    }
                    if (min_idx != i) {
                        // Swap both arrays at the same indices
                        const tmp_path = self.path_instances.items[i];
                        self.path_instances.items[i] = self.path_instances.items[min_idx];
                        self.path_instances.items[min_idx] = tmp_path;

                        const tmp_grad = self.path_gradients.items[i];
                        self.path_gradients.items[i] = self.path_gradients.items[min_idx];
                        self.path_gradients.items[min_idx] = tmp_grad;
                    }
                }
            }
        }
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
    pub fn setStats(self: *Self, stats: *@import("../debug/render_stats.zig").RenderStats) void {
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

    // needs_sort_quads should be false
    try testing.expect(!scene.needs_sort_quads);

    // finish() should be a no-op (fast path)
    scene.finish();

    // Verify order is preserved
    try testing.expectEqual(@as(DrawOrder, 0), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[1].order);
    try testing.expectEqual(@as(DrawOrder, 2), scene.quads.items[2].order);
}

test "insertQuadWithOrder preserves draw order and triggers sort" {
    const testing = std.testing;
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    // Insert regular quads first (orders 0, 1, 2)
    try scene.insertQuad(.{ .bounds_origin_x = 0, .bounds_origin_y = 0, .bounds_size_width = 10, .bounds_size_height = 10 });
    try scene.insertQuad(.{ .bounds_origin_x = 10, .bounds_origin_y = 10, .bounds_size_width = 10, .bounds_size_height = 10 });
    try scene.insertQuad(.{ .bounds_origin_x = 20, .bounds_origin_y = 20, .bounds_size_width = 10, .bounds_size_height = 10 });

    // needs_sort_quads should be false after regular inserts
    try testing.expect(!scene.needs_sort_quads);

    // Insert a quad with a high explicit order (like debug overlay)
    const DEBUG_ORDER: DrawOrder = 0xFFFF_FF00;
    var overlay_quad = Quad.filled(50, 50, 100, 100, Hsla.red);
    overlay_quad.order = DEBUG_ORDER;
    try scene.insertQuadWithOrder(overlay_quad);

    // needs_sort_quads should now be true
    try testing.expect(scene.needs_sort_quads);

    // The overlay quad should have its order preserved
    try testing.expectEqual(DEBUG_ORDER, scene.quads.items[3].order);

    // After finish(), quads should be sorted by order
    scene.finish();

    // Regular quads (0, 1, 2) should come before overlay (DEBUG_ORDER)
    try testing.expectEqual(@as(DrawOrder, 0), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[1].order);
    try testing.expectEqual(@as(DrawOrder, 2), scene.quads.items[2].order);
    try testing.expectEqual(DEBUG_ORDER, scene.quads.items[3].order);
}

test "insertQuadWithOrder interleaves correctly with BatchIterator" {
    const testing = std.testing;
    const batch_iter = @import("batch_iterator.zig");

    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    // Insert: quad(0), glyph(1), quad(2), then overlay quad with high order
    try scene.insertQuad(Quad.filled(0, 0, 100, 100, Hsla.red));
    try scene.insertGlyph(GlyphInstance.init(0, 0, 10, 10, 0, 0, 1, 1, Hsla.black));
    try scene.insertQuad(Quad.filled(10, 10, 100, 100, Hsla.green));

    // Insert debug overlay with explicit high order
    var overlay = Quad.filled(50, 50, 200, 200, Hsla.blue);
    overlay.order = 1000;
    try scene.insertQuadWithOrder(overlay);

    // Finish to sort
    scene.finish();

    // Verify batch iterator yields in correct order
    var iter = batch_iter.BatchIterator.init(&scene);

    // First batch: quad at order 0
    const batch1 = iter.next().?;
    try testing.expect(batch1 == .quad);
    try testing.expectEqual(@as(usize, 1), batch1.quad.len);

    // Second batch: glyph at order 1
    const batch2 = iter.next().?;
    try testing.expect(batch2 == .glyph);

    // Third batch: quads at orders 2 and 1000 (coalesced - no other type between them)
    const batch3 = iter.next().?;
    try testing.expect(batch3 == .quad);
    try testing.expectEqual(@as(usize, 2), batch3.quad.len);
    try testing.expectEqual(@as(DrawOrder, 2), batch3.quad[0].order);
    try testing.expectEqual(@as(DrawOrder, 1000), batch3.quad[1].order);

    // No more batches
    try testing.expect(iter.next() == null);
}
