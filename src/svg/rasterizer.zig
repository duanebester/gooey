//! SVG Rasterizer - Platform dispatcher
//!
//! Routes to platform-specific SVG rasterization backends:
//! - CoreGraphics (macOS) - rasterizer_cg.zig
//! - Software renderer (Linux) - rasterizer_linux.zig
//! - Canvas2D (Web/WASM) - rasterizer_web.zig

const builtin = @import("builtin");
const interface_verify = @import("../core/interface_verify.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

const backend = if (is_wasm)
    @import("backends/canvas.zig")
else switch (builtin.os.tag) {
    .macos => @import("backends/coregraphics.zig"),
    .linux => @import("backends/cairo.zig"),
    else => @import("backends/null.zig"),
};

// Compile-time interface verification
comptime {
    interface_verify.verifySvgRasterizerModule(backend);
}

// Re-export types
pub const RasterizedSvg = backend.RasterizedSvg;
pub const RasterizeError = backend.RasterizeError;
pub const StrokeOptions = backend.StrokeOptions;

// Re-export functions
pub const rasterize = backend.rasterize;
pub const rasterizeWithOptions = backend.rasterizeWithOptions;
