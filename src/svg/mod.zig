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
