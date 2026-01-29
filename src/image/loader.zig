//! Image Loader - Platform dispatcher
//!
//! Routes to platform-specific image loading backends:
//! - CoreGraphics (macOS) - ImageIO/CoreGraphics
//! - libpng (Linux) - PNG decoding via libpng
//! - null (other platforms) - Returns UnsupportedSource
//!
//! Note: WASM image loading is async and handled separately in
//! `platform/web/image_loader.zig`. The sync API here returns
//! UnsupportedSource on WASM.

const std = @import("std");
const builtin = @import("builtin");
const atlas = @import("atlas.zig");
const ImageData = atlas.ImageData;
const ImageSource = atlas.ImageSource;
const interface_verify = @import("../core/interface_verify.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

const backend = if (is_wasm)
    @import("backends/null.zig")
else switch (builtin.os.tag) {
    .macos => @import("backends/coregraphics.zig"),
    .linux => @import("backends/libpng.zig"),
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

// =============================================================================
// Public API
// =============================================================================

/// Load image from source
pub fn load(allocator: std.mem.Allocator, source: ImageSource) LoadError!DecodedImage {
    return switch (source) {
        .embedded => |data| loadFromMemory(allocator, data),
        .path => |path| loadFromPath(allocator, path),
        .url => LoadError.UnsupportedSource, // TODO: async URL loading
        .data => |data| loadFromImageData(allocator, data),
    };
}

/// Load image from raw bytes (PNG, JPEG, etc.)
pub const loadFromMemory = backend.loadFromMemory;

/// Load image from file path
/// Note: Not supported on WASM - use embedded images or URL loading instead.
pub const loadFromPath = if (is_wasm)
    loadFromPathUnsupported
else
    loadFromPathNative;

fn loadFromPathUnsupported(_: std.mem.Allocator, _: []const u8) LoadError!DecodedImage {
    return LoadError.UnsupportedSource;
}

fn loadFromPathNative(allocator: std.mem.Allocator, path: []const u8) LoadError!DecodedImage {
    // Read file into memory
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => LoadError.FileNotFound,
            else => LoadError.IoError,
        };
    };
    defer file.close();

    const stat = file.stat() catch return LoadError.IoError;
    const data = allocator.alloc(u8, stat.size) catch return LoadError.OutOfMemory;
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch return LoadError.IoError;
    if (bytes_read != stat.size) return LoadError.IoError;

    return loadFromMemory(allocator, data);
}

/// Load from pre-decoded ImageData (just converts format if needed)
pub fn loadFromImageData(allocator: std.mem.Allocator, data: ImageData) LoadError!DecodedImage {
    const rgba = data.toRgba(allocator) catch return LoadError.OutOfMemory;
    return DecodedImage{
        .width = data.width,
        .height = data.height,
        .pixels = rgba,
        .allocator = allocator,
    };
}

// =============================================================================
// Utility Functions
// =============================================================================

pub const ImageFormat = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,
};

/// Detect image format from magic bytes
pub fn detectFormat(data: []const u8) ?ImageFormat {
    if (data.len < 8) return null;

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (std.mem.eql(u8, data[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' })) {
        return .png;
    }

    // JPEG: FF D8 FF
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return .jpeg;
    }

    // GIF: GIF87a or GIF89a
    if (data.len >= 6 and std.mem.eql(u8, data[0..3], "GIF")) {
        return .gif;
    }

    // WebP: RIFF....WEBP
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) {
        return .webp;
    }

    // BMP: BM
    if (data.len >= 2 and data[0] == 'B' and data[1] == 'M') {
        return .bmp;
    }

    return null;
}

/// Create a solid color image (useful for placeholders)
pub fn createSolidColor(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) LoadError!DecodedImage {
    const pixels = allocator.alloc(u8, width * height * 4) catch
        return LoadError.OutOfMemory;

    var i: usize = 0;
    while (i < width * height) : (i += 1) {
        const offset = i * 4;
        pixels[offset + 0] = r;
        pixels[offset + 1] = g;
        pixels[offset + 2] = b;
        pixels[offset + 3] = a;
    }

    return DecodedImage{
        .width = width,
        .height = height,
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Create a checkerboard pattern (useful for transparency indication)
pub fn createCheckerboard(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    cell_size: u32,
) LoadError!DecodedImage {
    const pixels = allocator.alloc(u8, width * height * 4) catch
        return LoadError.OutOfMemory;

    const light = [4]u8{ 255, 255, 255, 255 };
    const dark = [4]u8{ 204, 204, 204, 255 };

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const cell_x = x / cell_size;
            const cell_y = y / cell_size;
            const is_light = (cell_x + cell_y) % 2 == 0;
            const color = if (is_light) light else dark;

            const offset = (y * width + x) * 4;
            @memcpy(pixels[offset..][0..4], &color);
        }
    }

    return DecodedImage{
        .width = width,
        .height = height,
        .pixels = pixels,
        .allocator = allocator,
    };
}
