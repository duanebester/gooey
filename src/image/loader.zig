//! Platform image-decode dispatcher; `core/images.zig` reads files on its
//! worker and decodes into staging reserved at init. WASM keeps `null.zig`.

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

comptime {
    interface_verify.verifyImageLoaderModule(@This());
}

pub const DecodedImage = backend.DecodedImage;
pub const LoadError = backend.LoadError;

/// Decode image bytes (PNG, JPEG, etc.) into RGBA pixels from `allocator`.
pub const loadFromMemory = backend.loadFromMemory;
