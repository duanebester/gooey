//! SVG Rasterizer - Platform dispatcher
//!
//! Routes to platform-specific SVG rasterization backends:
//! - CoreGraphics (macOS) - rasterizer_cg.zig
//! - Canvas2D (Web/WASM) - rasterizer_web.zig

const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

const backend = if (is_wasm)
    @import("rasterizer_web.zig")
else switch (builtin.os.tag) {
    .macos => @import("rasterizer_cg.zig"),
    else => @compileError("SVG rasterization not supported on this platform"),
};

// Re-export types
pub const RasterizedSvg = backend.RasterizedSvg;
pub const RasterizeError = backend.RasterizeError;
pub const StrokeOptions = backend.StrokeOptions;

// Re-export functions
pub const rasterize = backend.rasterize;
pub const rasterizeWithOptions = backend.rasterizeWithOptions;
