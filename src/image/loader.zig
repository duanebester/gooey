//! Image Loader - Decodes images from various sources
//!
//! Provides platform-agnostic image loading with backends:
//! - macOS: ImageIO/CoreGraphics
//! - Web: Browser's Image API (future)
//!
//! Supports PNG, JPEG, and other common formats.

const std = @import("std");
const builtin = @import("builtin");
const atlas = @import("atlas.zig");
const ImageData = atlas.ImageData;
const ImageSource = atlas.ImageSource;

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
pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
    if (builtin.os.tag == .macos) {
        return loadFromMemoryMacOS(allocator, data);
    } else if (builtin.cpu.arch == .wasm32) {
        return loadFromMemoryWasm(allocator, data);
    } else {
        // Fallback: try PNG decoding
        return loadPng(allocator, data);
    }
}

/// Load image from file path
/// Note: Not supported on WASM - use embedded images or URL loading instead.
pub const loadFromPath = if (builtin.cpu.arch == .wasm32)
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
// macOS Backend (ImageIO/CoreGraphics)
// =============================================================================

fn loadFromMemoryMacOS(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
    const cf = struct {
        extern "c" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, length: isize) ?*anyopaque;
        extern "c" fn CFRelease(cf: *anyopaque) void;
        extern "c" fn CGImageSourceCreateWithData(data: *anyopaque, options: ?*anyopaque) ?*anyopaque;
        extern "c" fn CGImageSourceCreateImageAtIndex(source: *anyopaque, index: usize, options: ?*anyopaque) ?*anyopaque;
        extern "c" fn CGImageGetWidth(image: *anyopaque) usize;
        extern "c" fn CGImageGetHeight(image: *anyopaque) usize;
        extern "c" fn CGImageRelease(image: *anyopaque) void;
        extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
        extern "c" fn CGColorSpaceRelease(colorspace: *anyopaque) void;
        extern "c" fn CGBitmapContextCreate(
            data: ?*anyopaque,
            width: usize,
            height: usize,
            bitsPerComponent: usize,
            bytesPerRow: usize,
            colorspace: *anyopaque,
            bitmapInfo: u32,
        ) ?*anyopaque;
        extern "c" fn CGContextClearRect(context: *anyopaque, rect: extern struct { x: f64, y: f64, w: f64, h: f64 }) void;
        extern "c" fn CGContextDrawImage(context: *anyopaque, rect: extern struct { x: f64, y: f64, w: f64, h: f64 }, image: *anyopaque) void;
        extern "c" fn CGContextRelease(context: *anyopaque) void;
    };

    // Create CFData from bytes
    const cf_data = cf.CFDataCreate(null, data.ptr, @intCast(data.len)) orelse
        return LoadError.OutOfMemory;
    defer cf.CFRelease(cf_data);

    // Create image source
    const image_source = cf.CGImageSourceCreateWithData(cf_data, null) orelse
        return LoadError.InvalidFormat;
    defer cf.CFRelease(image_source);

    // Get CGImage
    const cg_image = cf.CGImageSourceCreateImageAtIndex(image_source, 0, null) orelse
        return LoadError.DecodeFailed;
    defer cf.CGImageRelease(cg_image);

    // Get dimensions
    const width = cf.CGImageGetWidth(cg_image);
    const height = cf.CGImageGetHeight(cg_image);

    if (width == 0 or height == 0) return LoadError.DecodeFailed;

    // Allocate output buffer
    const pixels = allocator.alloc(u8, width * height * 4) catch
        return LoadError.OutOfMemory;
    errdefer allocator.free(pixels);

    // Create color space
    const colorspace = cf.CGColorSpaceCreateDeviceRGB() orelse
        return LoadError.DecodeFailed;
    defer cf.CGColorSpaceRelease(colorspace);

    // Create bitmap context (RGBA, premultiplied alpha, native byte order)
    // kCGImageAlphaPremultipliedLast = 1, use native byte order (no byte order flag)
    const kCGImageAlphaPremultipliedLast: u32 = 1;
    const bitmap_info: u32 = kCGImageAlphaPremultipliedLast;

    const context = cf.CGBitmapContextCreate(
        pixels.ptr,
        width,
        height,
        8,
        width * 4,
        colorspace,
        bitmap_info,
    ) orelse return LoadError.DecodeFailed;
    defer cf.CGContextRelease(context);

    // Clear context to transparent before drawing (prevents default grey/white background)
    cf.CGContextClearRect(context, .{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(width),
        .h = @floatFromInt(height),
    });

    // Draw image into context
    cf.CGContextDrawImage(context, .{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(width),
        .h = @floatFromInt(height),
    }, cg_image);

    // Unpremultiply alpha
    unpremultiplyAlpha(pixels, width, height);

    return DecodedImage{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Convert premultiplied alpha to straight alpha
fn unpremultiplyAlpha(pixels: []u8, width: usize, height: usize) void {
    const pixel_count = width * height;
    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        const offset = i * 4;
        const a = pixels[offset + 3];
        if (a > 0 and a < 255) {
            const alpha_f: f32 = @as(f32, @floatFromInt(a)) / 255.0;
            pixels[offset + 0] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(pixels[offset + 0])) / alpha_f));
            pixels[offset + 1] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(pixels[offset + 1])) / alpha_f));
            pixels[offset + 2] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(pixels[offset + 2])) / alpha_f));
        }
    }
}

// =============================================================================
// WebAssembly Backend
// =============================================================================

/// Synchronous loading is not supported on WASM.
/// Use the async API instead:
///
/// ```
/// const wasm_loader = @import("platform/wgpu/web/image_loader.zig");
///
/// // Initialize once at startup
/// wasm_loader.init(allocator);
///
/// // Request async decode
/// _ = wasm_loader.loadFromMemoryAsync(image_bytes, myCallback);
///
/// fn myCallback(request_id: u32, result: ?wasm_loader.DecodedImage) void {
///     if (result) |decoded| {
///         // Use decoded.width, decoded.height, decoded.pixels
///         // Don't forget to call decoded.deinit(allocator) when done
///     } else {
///         // Decode failed
///     }
/// }
/// ```
fn loadFromMemoryWasm(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
    // Synchronous image decoding is not possible on WASM.
    // The browser's image decoding APIs (createImageBitmap) are async.
    // Use the async API in src/platform/wgpu/web/image_loader.zig instead.
    _ = allocator;
    _ = data;
    return LoadError.UnsupportedSource;
}

// =============================================================================
// Fallback PNG Decoder (minimal implementation)
// =============================================================================

fn loadPng(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
    // Check PNG signature
    const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &png_signature)) {
        return LoadError.InvalidFormat;
    }

    // For now, return error - full PNG decoding is complex
    // In production, you'd link stb_image or use a Zig PNG library
    _ = allocator;
    return LoadError.UnsupportedSource;
}

// =============================================================================
// Utility Functions
// =============================================================================

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

pub const ImageFormat = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,
};

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
