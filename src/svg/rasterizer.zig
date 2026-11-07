//! SVG Rasterizer - Platform dispatcher
//!
//! Routes to platform-specific SVG rasterization backends:
//! - CoreGraphics (macOS) - `backends/coregraphics.zig`
//! - Software scanline renderer (Linux and Windows) - `backends/software.zig`
//! - Canvas2D (Web/WASM) - `backends/canvas.zig`
//! - Unsupported platforms - `backends/null.zig`
//!
//! macOS and WASM delegate to their host's native 2D API; Linux and Windows
//! share a pure-Zig software rasterizer so neither needs an extra system
//! graphics library. All backends produce the same `RasterizedSvg` record and
//! the two-channel RGBA encoding consumed by `SvgAtlas`.

const builtin = @import("builtin");
const interface_verify = @import("../core/interface_verify.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

const backend = if (is_wasm)
    @import("backends/canvas.zig")
else switch (builtin.os.tag) {
    .macos => @import("backends/coregraphics.zig"),
    .linux, .windows => @import("backends/software.zig"),
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
