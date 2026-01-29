//! Image Loader Stub - For unsupported platforms
//!
//! Provides API compatibility for platforms without native image loading support.
//! All load operations return an error.

const std = @import("std");
const atlas = @import("../atlas.zig");
const ImageData = atlas.ImageData;

/// Result of image decoding
pub const DecodedImage = struct {
    width: u32,
    height: u32,
    /// RGBA pixel data (owned by allocator)
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn toImageData(self: *const DecodedImage) ImageData {
        return .{
            .width = self.width,
            .height = self.height,
            .pixels = self.pixels,
            .format = .rgba,
        };
    }
};

/// Load error types
pub const LoadError = error{
    FileNotFound,
    InvalidFormat,
    DecodeFailed,
    OutOfMemory,
    UnsupportedSource,
    IoError,
};

/// Load image from raw bytes
///
/// Returns UnsupportedSource on unsupported platforms.
pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
    _ = allocator;
    _ = data;
    return error.UnsupportedSource;
}
