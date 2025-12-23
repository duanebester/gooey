//! SVG rendering module
//!
//! Provides atlas-cached SVG icon rendering with platform-specific rasterization:
//! - macOS: CoreGraphics (CGPath, CGContext)
//! - Web: Canvas2D (Path2D, OffscreenCanvas)

pub const SvgAtlas = @import("atlas.zig").SvgAtlas;
pub const SvgKey = @import("atlas.zig").SvgKey;
pub const CachedSvg = @import("atlas.zig").CachedSvg;

pub const rasterize = @import("rasterizer.zig").rasterize;
pub const rasterizeWithOptions = @import("rasterizer.zig").rasterizeWithOptions;
pub const RasterizedSvg = @import("rasterizer.zig").RasterizedSvg;
pub const RasterizeError = @import("rasterizer.zig").RasterizeError;
pub const StrokeOptions = @import("rasterizer.zig").StrokeOptions;
