//! SVG Rendering Module
//!
//! Provides atlas-cached SVG icon rendering with platform-specific rasterization.
//!
//! ## Platform Backends
//!
//! - **macOS**: CoreGraphics (CGPath, CGContext) - `backends/coregraphics.zig`
//! - **Linux**: Cairo software renderer - `backends/cairo.zig`
//! - **Web**: Canvas2D (Path2D, OffscreenCanvas) - `backends/canvas.zig`
//!
//! ## Usage
//!
//! ```zig
//! const svg = @import("gooey").svg;
//!
//! // Rasterize an SVG icon
//! const result = try svg.rasterize(svg_data, 32, 32, allocator);
//! defer allocator.free(result.pixels);
//! ```

const builtin = @import("builtin");

// =============================================================================
// Path Parsing & Flattening
// =============================================================================
//
// Path parser, element parser (circle/rect/line/polyline/polygon/ellipse),
// bezier flattening, and arc flattening. Lifted out of `scene/svg.zig` in
// PR 2 (cleanup plan §"PR 2 — SVG consolidation") so the codebase has
// exactly one SVG module. Vector math reuses `core.Vec2` / `core.IndexSlice`
// — there is no longer a parallel `Vec2` declaration here.

pub const path = @import("path.zig");

// Re-exports of the public SVG-parsing surface. Backends (CoreGraphics,
// Cairo, Canvas2D) and tests reach for these via `svg_mod.SvgPath` etc.
pub const Vec2 = path.Vec2;
pub const IndexSlice = path.IndexSlice;
pub const PathCommand = path.PathCommand;
pub const CubicBez = path.CubicBez;
pub const QuadraticBez = path.QuadraticBez;
pub const SvgPath = path.SvgPath;
pub const PathParser = path.PathParser;
pub const SvgElementParser = path.SvgElementParser;
pub const flattenArc = path.flattenArc;
pub const flattenPath = path.flattenPath;

// =============================================================================
// Atlas (Caching)
// =============================================================================

pub const SvgAtlas = @import("atlas.zig").SvgAtlas;
pub const SvgKey = @import("atlas.zig").SvgKey;
pub const CachedSvg = @import("atlas.zig").CachedSvg;

// =============================================================================
// Rasterizer (Platform-dispatched)
// =============================================================================

pub const rasterizer = @import("rasterizer.zig");
pub const rasterize = rasterizer.rasterize;
pub const rasterizeWithOptions = rasterizer.rasterizeWithOptions;
pub const RasterizedSvg = rasterizer.RasterizedSvg;
pub const RasterizeError = rasterizer.RasterizeError;
pub const StrokeOptions = rasterizer.StrokeOptions;

// =============================================================================
// Platform Backends (for advanced usage)
// =============================================================================

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Platform-specific backends for direct access
pub const backends = struct {
    /// CoreGraphics backend (macOS)
    pub const coregraphics = if (!is_wasm and builtin.os.tag == .macos)
        @import("backends/coregraphics.zig")
    else
        struct {};

    /// Cairo backend (Linux)
    pub const cairo = if (!is_wasm and builtin.os.tag == .linux)
        @import("backends/cairo.zig")
    else
        struct {};

    /// Canvas2D backend (Web/WASM)
    pub const canvas = if (is_wasm)
        @import("backends/canvas.zig")
    else
        struct {};

    /// Null/stub backend (unsupported platforms)
    pub const null_backend = @import("backends/null.zig");
};
