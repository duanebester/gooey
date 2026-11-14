//! Image decoder - platform dispatcher
//!
//! Routes to platform-specific image decoding backends:
//! - CoreGraphics (macOS) - ImageIO/CoreGraphics
//! - libpng (Linux) - PNG decoding via libpng
//! - WIC (Windows) - Windows Imaging Component
//! - null (other platforms) - Returns UnsupportedSource
//!
//! Only the decode is here: `core/images.zig` reads files on its worker and
//! decodes the bytes into staging reserved at init. WASM has no decoder; the
//! web keeps the browser's image path.

const builtin = @import("builtin");
const interface_verify = @import("../core/interface_verify.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

const backend = if (is_wasm)
    @import("backends/null.zig")
else switch (builtin.os.tag) {
    .macos => @import("backends/coregraphics.zig"),
    .linux => @import("backends/libpng.zig"),
    .windows => @import("backends/wic/decoder.zig"),
    else => @import("backends/null.zig"),
};

// Compile-time interface verification
comptime {
    interface_verify.verifyImageLoaderModule(@This());
}

// =============================================================================
// Re-export types from backend
// =============================================================================

pub const DecodedImage = backend.DecodedImage;
pub const LoadError = backend.LoadError;

/// Decode image bytes (PNG, JPEG, etc.) into RGBA pixels from `allocator`.
pub const loadFromMemory = backend.loadFromMemory;
