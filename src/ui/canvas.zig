//! Canvas - Low-level custom drawing element
//!
//! Provides a callback-based API for custom vector graphics within
//! the Gooey UI tree. Use Canvas when you need to draw arbitrary shapes,
//! charts, or custom visualizations.
//!
//! ## Usage
//! ```zig
//! const ui = @import("gooey").ui;
//!
//! fn myPaint(ctx: *ui.DrawContext) void {
//!     // Background
//!     ctx.fillRect(0, 0, 200, 200, ui.Color.hex(0x1a1a2e));
//!
//!     // Custom path
//!     var star = ctx.beginPath(100, 10);
//!     _ = star.lineTo(120, 80).lineTo(190, 80).close();
//!     ctx.fillPath(&star, ui.Color.gold);
//!
//!     // Circle
//!     ctx.fillCircle(100, 100, 30, ui.Color.red);
//! }
//!
//! // In your UI:
//! pub fn view(b: *ui.Builder) void {
//!     ui.canvas(200, 200, myPaint).render(b);
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");

// Internal imports
const scene_mod = @import("../scene/mod.zig");
const path_mod = @import("../core/path.zig");
const gradient_mod = @import("../core/gradient.zig");
const styles = @import("styles.zig");
const builder_mod = @import("builder.zig");

// Re-exports for canvas users
pub const Path = path_mod.Path;
pub const Color = styles.Color;
pub const LinearGradient = gradient_mod.LinearGradient;
pub const RadialGradient = gradient_mod.RadialGradient;
pub const Gradient = gradient_mod.Gradient;
pub const LineCap = path_mod.LineCap;
pub const LineJoin = path_mod.LineJoin;
pub const StrokeStyle = path_mod.StrokeStyle;

// Scene types
const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;
const Bounds = scene_mod.Bounds;
const PathInstance = scene_mod.PathInstance;
const PathMesh = scene_mod.PathMesh;
const MeshRef = scene_mod.MeshRef;
const MeshPool = scene_mod.MeshPool;
const Quad = scene_mod.Quad;

// =============================================================================
// Constants (per CLAUDE.md: "put a limit on everything")
// =============================================================================

/// Maximum cached paths per DrawContext per frame
const MAX_CACHED_PATHS: usize = 256;

/// Maximum pending canvas elements per frame
pub const MAX_PENDING_CANVAS: usize = 64;

/// Default curve flattening tolerance (in pixels)
const DEFAULT_TOLERANCE: f32 = 0.5;

// =============================================================================
// CachedPath - Pre-tessellated path for repeated drawing
// =============================================================================

/// A cached path that can be drawn multiple times without re-tessellation.
/// Create via `DrawContext.cachePath()`.
pub const CachedPath = struct {
    mesh_ref: MeshRef,
    bounds: Bounds,
};

// =============================================================================
// PendingCanvas - Deferred canvas rendering info
// =============================================================================

/// Stores canvas info for deferred rendering after layout is complete.
/// Similar to PendingInput in builder.zig.
pub const PendingCanvas = struct {
    layout_id: u32,
    paint: *const fn (*DrawContext) void,
    scale: f32,
};

// =============================================================================
// DrawContext - Canvas drawing API
// =============================================================================

/// Drawing context passed to canvas paint callbacks.
/// Provides immediate-mode and cached-mode APIs for custom vector graphics.
pub const DrawContext = struct {
    scene: *Scene,
    bounds: Bounds,
    scale: f32,

    const Self = @This();

    // =========================================================================
    // Immediate Mode API (simple, tessellates every call)
    // =========================================================================

    /// Fill a rectangle with solid color.
    /// Uses optimized quad rendering (no tessellation).
    pub fn fillRect(self: *Self, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        // Assertions at API boundary (per CLAUDE.md)
        std.debug.assert(w >= 0 and h >= 0);
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

        const quad = Quad.filled(
            self.bounds.origin.x + x,
            self.bounds.origin.y + y,
            w,
            h,
            Hsla.fromColor(color),
        );
        self.scene.insertQuad(quad) catch {};
    }

    /// Fill a rounded rectangle with solid color.
    /// Uses optimized quad rendering with corner radius.
    pub fn fillRoundedRect(self: *Self, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
        std.debug.assert(w >= 0 and h >= 0);
        std.debug.assert(radius >= 0);

        var quad = Quad.filled(
            self.bounds.origin.x + x,
            self.bounds.origin.y + y,
            w,
            h,
            Hsla.fromColor(color),
        );
        quad.corner_radii = scene_mod.Corners.all(radius);
        self.scene.insertQuad(quad) catch {};
    }

    /// Stroke a rectangle outline.
    /// Uses optimized quad rendering with border.
    pub fn strokeRect(self: *Self, x: f32, y: f32, w: f32, h: f32, color: Color, stroke_width: f32) void {
        std.debug.assert(w >= 0 and h >= 0);
        std.debug.assert(stroke_width >= 0);

        const quad = Quad.filled(
            self.bounds.origin.x + x,
            self.bounds.origin.y + y,
            w,
            h,
            Hsla.transparent,
        ).withBorder(Hsla.fromColor(color), stroke_width);
        self.scene.insertQuad(quad) catch {};
    }

    /// Begin a new path at the given position.
    /// Returns a Path builder for fluent path construction.
    pub fn beginPath(self: *Self, x: f32, y: f32) Path {
        _ = self; // Scale will be used in fillPath
        var p = Path.init();
        _ = p.moveTo(x, y);
        return p;
    }

    /// Fill a path with solid color (immediate mode - tessellates every call).
    /// For repeated draws of the same path, use `cachePath()` + `fillCached()`.
    pub fn fillPath(self: *Self, p: *const Path, color: Color) void {
        const tolerance = DEFAULT_TOLERANCE / self.scale;

        const mesh = p.toMesh(self.scene.allocator, tolerance) catch |err| {
            if (builtin.mode == .Debug) {
                std.log.warn("Canvas: path tessellation failed: {}, skipping", .{err});
            }
            return;
        };

        self.scene.insertPathWithMesh(
            mesh,
            self.bounds.origin.x,
            self.bounds.origin.y,
            Hsla.fromColor(color),
        ) catch {};
    }

    /// Draw a filled circle.
    /// Uses cubic Bézier approximation (4 curves) for high quality.
    pub fn fillCircle(self: *Self, cx: f32, cy: f32, r: f32, color: Color) void {
        std.debug.assert(r >= 0);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        var p = self.beginPath(cx + r, cy);

        // Magic number for circle approximation with cubic Béziers
        // k = 4/3 * tan(π/8) ≈ 0.5522847498
        const k: f32 = 0.552284749831;

        // Four cubic Bézier curves for a full circle
        _ = p.cubicTo(cx + r, cy + r * k, cx + r * k, cy + r, cx, cy + r)
            .cubicTo(cx - r * k, cy + r, cx - r, cy + r * k, cx - r, cy)
            .cubicTo(cx - r, cy - r * k, cx - r * k, cy - r, cx, cy - r)
            .cubicTo(cx + r * k, cy - r, cx + r, cy - r * k, cx + r, cy)
            .closePath();

        self.fillPath(&p, color);
    }

    /// Draw a filled ellipse.
    pub fn fillEllipse(self: *Self, cx: f32, cy: f32, rx: f32, ry: f32, color: Color) void {
        std.debug.assert(rx >= 0 and ry >= 0);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        var p = self.beginPath(cx + rx, cy);

        const kx: f32 = 0.552284749831 * rx;
        const ky: f32 = 0.552284749831 * ry;

        _ = p.cubicTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)
            .cubicTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)
            .cubicTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)
            .cubicTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)
            .closePath();

        self.fillPath(&p, color);
    }

    // =========================================================================
    // Cached Mode API (for repeated draws of same path)
    // =========================================================================

    /// Cache a path for repeated drawing (avoids re-tessellation).
    /// Returns null if tessellation fails or cache is full.
    ///
    /// Use this when drawing the same shape multiple times per frame:
    /// ```zig
    /// var bar = ctx.beginPath(0, 0);
    /// _ = bar.lineTo(20, 0).lineTo(20, 100).lineTo(0, 100).close();
    ///
    /// if (ctx.cachePath(&bar)) |cached| {
    ///     for (0..50) |i| {
    ///         // Transform would go here (Phase 4)
    ///         ctx.fillCached(cached, colors[i]);
    ///     }
    /// }
    /// ```
    pub fn cachePath(self: *Self, p: *const Path) ?CachedPath {
        const tolerance = DEFAULT_TOLERANCE / self.scale;

        const mesh = p.toMesh(self.scene.allocator, tolerance) catch return null;
        const mesh_ref = self.scene.mesh_pool.allocateFrame(mesh) catch return null;

        return CachedPath{
            .mesh_ref = mesh_ref,
            .bounds = mesh.bounds,
        };
    }

    /// Fill a previously cached path (no tessellation, very fast).
    /// The cached path is drawn at the canvas origin.
    pub fn fillCached(self: *Self, cached: CachedPath, color: Color) void {
        const mesh = self.scene.mesh_pool.getMesh(cached.mesh_ref) orelse return;

        const instance = PathInstance.initWithBufferRanges(
            cached.mesh_ref,
            self.bounds.origin.x,
            self.bounds.origin.y,
            Hsla.fromColor(color),
            0, // vertex_offset - set by renderer
            0, // index_offset - set by renderer
            @intCast(mesh.indices.len),
        );

        self.scene.insertPath(instance) catch {};
    }

    /// Fill a cached path at a specific offset from canvas origin.
    pub fn fillCachedAt(self: *Self, cached: CachedPath, x: f32, y: f32, color: Color) void {
        const mesh = self.scene.mesh_pool.getMesh(cached.mesh_ref) orelse return;

        const instance = PathInstance.initWithBufferRanges(
            cached.mesh_ref,
            self.bounds.origin.x + x,
            self.bounds.origin.y + y,
            Hsla.fromColor(color),
            0,
            0,
            @intCast(mesh.indices.len),
        );

        self.scene.insertPath(instance) catch {};
    }

    // =========================================================================
    // Static Path API (for icons and compile-time known paths)
    // =========================================================================

    /// Fill a static path using persistent cache (survives across frames).
    /// Use for icons and other paths that don't change.
    ///
    /// The path is cached by its hash, so subsequent frames reuse the
    /// cached mesh without re-tessellation.
    pub fn fillStaticPath(self: *Self, p: *const Path, color: Color) void {
        const hash = p.hash();
        const tolerance = DEFAULT_TOLERANCE / self.scale;

        const mesh = p.toMesh(self.scene.allocator, tolerance) catch return;

        // Try persistent cache first
        const mesh_ref = self.scene.mesh_pool.getOrCreatePersistent(mesh, hash) catch {
            // Cache full, fall back to frame allocation
            const frame_ref = self.scene.mesh_pool.allocateFrame(mesh) catch return;
            const instance = PathInstance.initWithBufferRanges(
                frame_ref,
                self.bounds.origin.x,
                self.bounds.origin.y,
                Hsla.fromColor(color),
                0,
                0,
                @intCast(mesh.indices.len),
            );
            self.scene.insertPath(instance) catch {};
            return;
        };

        const instance = PathInstance.initWithBufferRanges(
            mesh_ref,
            self.bounds.origin.x,
            self.bounds.origin.y,
            Hsla.fromColor(color),
            0,
            0,
            @intCast(mesh.indices.len),
        );
        self.scene.insertPath(instance) catch {};
    }

    /// Fill a static path at a specific offset from canvas origin.
    pub fn fillStaticPathAt(self: *Self, p: *const Path, x: f32, y: f32, color: Color) void {
        const hash = p.hash();
        const tolerance = DEFAULT_TOLERANCE / self.scale;

        const mesh = p.toMesh(self.scene.allocator, tolerance) catch return;

        const mesh_ref = self.scene.mesh_pool.getOrCreatePersistent(mesh, hash) catch {
            const frame_ref = self.scene.mesh_pool.allocateFrame(mesh) catch return;
            const instance = PathInstance.initWithBufferRanges(
                frame_ref,
                self.bounds.origin.x + x,
                self.bounds.origin.y + y,
                Hsla.fromColor(color),
                0,
                0,
                @intCast(mesh.indices.len),
            );
            self.scene.insertPath(instance) catch {};
            return;
        };

        const instance = PathInstance.initWithBufferRanges(
            mesh_ref,
            self.bounds.origin.x + x,
            self.bounds.origin.y + y,
            Hsla.fromColor(color),
            0,
            0,
            @intCast(mesh.indices.len),
        );
        self.scene.insertPath(instance) catch {};
    }

    // =========================================================================
    // Convenience: Shape Methods
    // =========================================================================

    /// Draw a line from (x1, y1) to (x2, y2) with given width and color.
    /// Note: This creates a thin rectangle, not a true stroke (Phase 4).
    pub fn line(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, line_width: f32, color: Color) void {
        std.debug.assert(line_width > 0);

        const dx = x2 - x1;
        const dy = y2 - y1;
        const len = @sqrt(dx * dx + dy * dy);

        if (len < 0.001) return; // Degenerate line

        // Perpendicular unit vector
        const px = -dy / len * line_width * 0.5;
        const py = dx / len * line_width * 0.5;

        var p = self.beginPath(x1 + px, y1 + py);
        _ = p.lineTo(x2 + px, y2 + py)
            .lineTo(x2 - px, y2 - py)
            .lineTo(x1 - px, y1 - py)
            .closePath();

        self.fillPath(&p, color);
    }

    /// Draw a triangle with vertices at (x1,y1), (x2,y2), (x3,y3).
    pub fn fillTriangle(
        self: *Self,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        x3: f32,
        y3: f32,
        color: Color,
    ) void {
        var p = self.beginPath(x1, y1);
        _ = p.lineTo(x2, y2).lineTo(x3, y3).closePath();
        self.fillPath(&p, color);
    }

    // =========================================================================
    // Gradient Fill API
    // =========================================================================

    /// Fill a path with a linear gradient.
    /// Gradient coordinates are in path-local space (normalized to path bounds).
    /// Use start/end in [0,1] range for UV-based gradients, or path coordinates.
    pub fn fillPathLinearGradient(
        self: *Self,
        p: *const Path,
        grad: *const LinearGradient,
    ) void {
        std.debug.assert(grad.stop_count >= 2);

        const tolerance = DEFAULT_TOLERANCE / self.scale;

        const mesh = p.toMesh(self.scene.allocator, tolerance) catch |err| {
            if (builtin.mode == .Debug) {
                std.log.warn("Canvas: path tessellation failed: {}, skipping", .{err});
            }
            return;
        };

        const mesh_ref = self.scene.mesh_pool.allocateFrame(mesh) catch return;
        const frame_mesh = self.scene.mesh_pool.getMesh(mesh_ref);

        // Normalize gradient coordinates to UV space [0,1]
        // The mesh bounds define the coordinate space
        const bounds = frame_mesh.bounds;
        const w = if (bounds.size.width > 0) bounds.size.width else 1;
        const h = if (bounds.size.height > 0) bounds.size.height else 1;

        // Convert gradient coords from path space to UV space
        const start_u = (grad.start_x - bounds.origin.x) / w;
        const start_v = (grad.start_y - bounds.origin.y) / h;
        const end_u = (grad.end_x - bounds.origin.x) / w;
        const end_v = (grad.end_y - bounds.origin.y) / h;

        var instance = PathInstance.initWithBufferRanges(
            mesh_ref,
            self.bounds.origin.x,
            self.bounds.origin.y,
            Hsla.black, // Fallback color (gradient overrides)
            0,
            0,
            @intCast(frame_mesh.indices.len),
        );

        // Set linear gradient parameters
        instance = instance.withLinearGradient(
            start_u,
            start_v,
            end_u,
            end_v,
            grad.stop_count,
        );

        self.scene.insertPathWithLinearGradient(instance, grad.*) catch {};
    }

    /// Fill a path with a radial gradient.
    /// Gradient coordinates are in path-local space.
    pub fn fillPathRadialGradient(
        self: *Self,
        p: *const Path,
        grad: *const RadialGradient,
    ) void {
        std.debug.assert(grad.stop_count >= 2);

        const tolerance = DEFAULT_TOLERANCE / self.scale;

        const mesh = p.toMesh(self.scene.allocator, tolerance) catch |err| {
            if (builtin.mode == .Debug) {
                std.log.warn("Canvas: path tessellation failed: {}, skipping", .{err});
            }
            return;
        };

        const mesh_ref = self.scene.mesh_pool.allocateFrame(mesh) catch return;
        const frame_mesh = self.scene.mesh_pool.getMesh(mesh_ref);

        // Normalize gradient coordinates to UV space [0,1]
        const bounds = frame_mesh.bounds;
        const w = if (bounds.size.width > 0) bounds.size.width else 1;
        const h = if (bounds.size.height > 0) bounds.size.height else 1;

        // Convert center to UV space, normalize radius
        const center_u = (grad.center_x - bounds.origin.x) / w;
        const center_v = (grad.center_y - bounds.origin.y) / h;
        const radius_uv = grad.radius / @max(w, h);
        const inner_radius_uv = grad.inner_radius / @max(w, h);

        var instance = PathInstance.initWithBufferRanges(
            mesh_ref,
            self.bounds.origin.x,
            self.bounds.origin.y,
            Hsla.black,
            0,
            0,
            @intCast(frame_mesh.indices.len),
        );

        instance = instance.withRadialGradient(
            center_u,
            center_v,
            radius_uv,
            inner_radius_uv,
            grad.stop_count,
        );

        self.scene.insertPathWithRadialGradient(instance, grad.*) catch {};
    }

    /// Fill a rectangle with a linear gradient.
    /// This is a convenience method that creates a rect path and fills it.
    /// Gradient coordinates are treated as relative to the rect (local space),
    /// e.g., LinearGradient.horizontal(width) fills left-to-right.
    pub fn fillRectLinearGradient(
        self: *Self,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        grad: *const LinearGradient,
    ) void {
        std.debug.assert(w >= 0 and h >= 0);
        std.debug.assert(grad.stop_count >= 2);

        var p = self.beginPath(x, y);
        _ = p.lineTo(x + w, y)
            .lineTo(x + w, y + h)
            .lineTo(x, y + h)
            .closePath();

        // Translate gradient coordinates from rect-local space to canvas space
        var translated_grad = grad.*;
        translated_grad.start_x = grad.start_x + x;
        translated_grad.start_y = grad.start_y + y;
        translated_grad.end_x = grad.end_x + x;
        translated_grad.end_y = grad.end_y + y;

        self.fillPathLinearGradient(&p, &translated_grad);
    }

    /// Fill a rectangle with a radial gradient.
    /// Gradient coordinates are treated as relative to the rect (local space).
    pub fn fillRectRadialGradient(
        self: *Self,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        grad: *const RadialGradient,
    ) void {
        std.debug.assert(w >= 0 and h >= 0);
        std.debug.assert(grad.stop_count >= 2);

        var p = self.beginPath(x, y);
        _ = p.lineTo(x + w, y)
            .lineTo(x + w, y + h)
            .lineTo(x, y + h)
            .closePath();

        // Translate gradient coordinates from rect-local space to canvas space
        var translated_grad = grad.*;
        translated_grad.center_x = grad.center_x + x;
        translated_grad.center_y = grad.center_y + y;

        self.fillPathRadialGradient(&p, &translated_grad);
    }

    /// Fill a circle with a radial gradient.
    /// Convenient for creating circular gradient effects.
    pub fn fillCircleRadialGradient(
        self: *Self,
        cx: f32,
        cy: f32,
        r: f32,
        grad: *const RadialGradient,
    ) void {
        std.debug.assert(r >= 0);
        std.debug.assert(grad.stop_count >= 2);

        var p = self.beginPath(cx + r, cy);
        const k: f32 = 0.552284749831;

        _ = p.cubicTo(cx + r, cy + r * k, cx + r * k, cy + r, cx, cy + r)
            .cubicTo(cx - r * k, cy + r, cx - r, cy + r * k, cx - r, cy)
            .cubicTo(cx - r, cy - r * k, cx - r * k, cy - r, cx, cy - r)
            .cubicTo(cx + r * k, cy - r, cx + r, cy - r * k, cx + r, cy)
            .closePath();

        self.fillPathRadialGradient(&p, grad);
    }

    // =========================================================================
    // Stroke API (Phase 4)
    // =========================================================================

    /// Stroke a path outline with solid color.
    /// Converts the stroke to a filled polygon for rendering.
    pub fn strokePath(
        self: *Self,
        p: *const Path,
        stroke_width: f32,
        color: Color,
    ) void {
        self.strokePathStyled(p, stroke_width, color, .butt, .miter);
    }

    /// Stroke a path outline with custom line cap and join styles.
    pub fn strokePathStyled(
        self: *Self,
        p: *const Path,
        stroke_width: f32,
        color: Color,
        cap: LineCap,
        join: LineJoin,
    ) void {
        std.debug.assert(stroke_width > 0);

        const tolerance = DEFAULT_TOLERANCE / self.scale;

        const mesh = p.toStrokeMesh(
            self.scene.allocator,
            stroke_width,
            cap,
            join,
            tolerance,
        ) catch |err| {
            if (builtin.mode == .Debug) {
                std.log.warn("Canvas: stroke tessellation failed: {}, skipping", .{err});
            }
            return;
        };

        self.scene.insertPathWithMesh(
            mesh,
            self.bounds.origin.x,
            self.bounds.origin.y,
            Hsla.fromColor(color),
        ) catch {};
    }

    /// Stroke a circle outline.
    pub fn strokeCircle(self: *Self, cx: f32, cy: f32, r: f32, stroke_width: f32, color: Color) void {
        std.debug.assert(r >= 0);
        std.debug.assert(stroke_width > 0);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        var p = self.beginPath(cx + r, cy);

        const k: f32 = 0.552284749831;

        _ = p.cubicTo(cx + r, cy + r * k, cx + r * k, cy + r, cx, cy + r)
            .cubicTo(cx - r * k, cy + r, cx - r, cy + r * k, cx - r, cy)
            .cubicTo(cx - r, cy - r * k, cx - r * k, cy - r, cx, cy - r)
            .cubicTo(cx + r * k, cy - r, cx + r, cy - r * k, cx + r, cy)
            .closePath();

        self.strokePath(&p, stroke_width, color);
    }

    /// Stroke an ellipse outline.
    pub fn strokeEllipse(self: *Self, cx: f32, cy: f32, rx: f32, ry: f32, stroke_width: f32, color: Color) void {
        std.debug.assert(rx >= 0 and ry >= 0);
        std.debug.assert(stroke_width > 0);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        var p = self.beginPath(cx + rx, cy);

        const kx: f32 = 0.552284749831 * rx;
        const ky: f32 = 0.552284749831 * ry;

        _ = p.cubicTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)
            .cubicTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)
            .cubicTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)
            .cubicTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)
            .closePath();

        self.strokePath(&p, stroke_width, color);
    }

    /// Stroke a line from (x1, y1) to (x2, y2).
    /// Uses stroke expansion for proper line caps.
    pub fn strokeLine(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, stroke_width: f32, color: Color) void {
        std.debug.assert(stroke_width > 0);

        var p = self.beginPath(x1, y1);
        _ = p.lineTo(x2, y2);

        self.strokePath(&p, stroke_width, color);
    }

    /// Stroke a line with custom cap style.
    pub fn strokeLineStyled(
        self: *Self,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        stroke_width: f32,
        color: Color,
        cap: LineCap,
    ) void {
        std.debug.assert(stroke_width > 0);

        var p = self.beginPath(x1, y1);
        _ = p.lineTo(x2, y2);

        self.strokePathStyled(&p, stroke_width, color, cap, .miter);
    }

    // =========================================================================
    // Canvas Properties
    // =========================================================================

    /// Get canvas width in logical pixels
    pub fn width(self: *const Self) f32 {
        return self.bounds.size.width;
    }

    /// Get canvas height in logical pixels
    pub fn height(self: *const Self) f32 {
        return self.bounds.size.height;
    }

    /// Get the current scale factor (for high-DPI displays)
    pub fn getScale(self: *const Self) f32 {
        return self.scale;
    }
};

// =============================================================================
// Canvas Rendering Execution
// =============================================================================

/// Execute a pending canvas paint callback.
/// Called by the frame renderer after layout is complete.
pub fn executePendingCanvas(
    pending: PendingCanvas,
    scene: *Scene,
    bounds: Bounds,
) void {
    var ctx = DrawContext{
        .scene = scene,
        .bounds = bounds,
        .scale = pending.scale,
    };
    pending.paint(&ctx);
}

// =============================================================================
// Canvas Element
// =============================================================================

/// Canvas element for custom drawing.
///
/// Canvas provides a callback-based API for rendering custom vector graphics
/// within the UI tree. Use it for charts, diagrams, custom visualizations,
/// or any content that can't be expressed with standard UI components.
///
/// ## Example
/// ```zig
/// fn paintChart(ctx: *ui.DrawContext) void {
///     // Draw bars
///     for (0..10, data) |i, value| {
///         const x = @as(f32, @floatFromInt(i)) * 25;
///         const h = value * 2;
///         ctx.fillRect(x, 200 - h, 20, h, ui.Color.blue);
///     }
/// }
///
/// pub fn view(b: *ui.Builder) void {
///     ui.canvas(300, 200, paintChart).render(b);
/// }
/// ```
pub const Canvas = struct {
    width: f32,
    height: f32,
    paint: *const fn (*DrawContext) void,
    /// Optional explicit ID (defaults to auto-generated)
    id: ?[]const u8 = null,

    const Self = @This();

    /// Render the canvas into the UI tree.
    /// The paint callback will be invoked after layout is computed.
    pub fn render(self: Self, b: *builder_mod.Builder) void {
        // Generate or use explicit layout ID
        const layout_id = if (self.id) |id_str|
            @import("../layout/layout.zig").LayoutId.fromString(id_str)
        else
            b.generateId();

        // Get scale factor
        const scale: f32 = if (b.gooey) |g| g.scale_factor else 1.0;

        // Register pending canvas for deferred rendering
        b.registerPendingCanvas(.{
            .layout_id = layout_id.id,
            .paint = self.paint,
            .scale = scale,
        });

        // Create a box to reserve space in layout - use same layout_id!
        b.boxWithLayoutId(layout_id, .{
            .width = self.width,
            .height = self.height,
        }, .{});
    }
};

// =============================================================================
// Convenience Constructor
// =============================================================================

/// Create a canvas element with the given size and paint callback.
///
/// ## Example
/// ```zig
/// fn myPaint(ctx: *ui.DrawContext) void {
///     ctx.fillCircle(50, 50, 40, ui.Color.red);
/// }
///
/// pub fn view(b: *ui.Builder) void {
///     ui.canvas(100, 100, myPaint).render(b);
/// }
/// ```
pub fn canvas(w: f32, h: f32, paint: *const fn (*DrawContext) void) Canvas {
    return Canvas{
        .width = w,
        .height = h,
        .paint = paint,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "DrawContext fillRect assertions" {
    // Test would need a mock scene - just verify struct compiles
    const ctx_type = DrawContext;
    try std.testing.expect(@sizeOf(ctx_type) > 0);
}

test "Canvas struct layout" {
    const c = Canvas{
        .width = 200,
        .height = 100,
        .paint = undefined,
    };
    try std.testing.expectEqual(@as(f32, 200), c.width);
    try std.testing.expectEqual(@as(f32, 100), c.height);
}

test "PendingCanvas struct layout" {
    const pending = PendingCanvas{
        .layout_id = 42,
        .paint = undefined,
        .scale = 2.0,
    };
    try std.testing.expectEqual(@as(u32, 42), pending.layout_id);
    try std.testing.expectEqual(@as(f32, 2.0), pending.scale);
}

test "canvas convenience constructor" {
    const testPaint = struct {
        fn paint(_: *DrawContext) void {}
    }.paint;

    const c = canvas(300, 200, testPaint);
    try std.testing.expectEqual(@as(f32, 300), c.width);
    try std.testing.expectEqual(@as(f32, 200), c.height);
}

test "CachedPath struct size" {
    // Verify CachedPath is reasonably sized
    try std.testing.expect(@sizeOf(CachedPath) <= 32);
}
