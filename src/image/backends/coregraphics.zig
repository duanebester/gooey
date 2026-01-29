//! Image Loader - macOS CoreGraphics Backend
//!
//! Uses ImageIO and CoreGraphics to decode images. Supports PNG, JPEG, GIF,
//! WebP, BMP, and other formats supported by the system.

const std = @import("std");
const interface_verify = @import("../../core/interface_verify.zig");
const atlas = @import("../atlas.zig");
const ImageData = atlas.ImageData;

// Compile-time interface verification
comptime {
    interface_verify.verifyImageLoaderModule(@This());
}

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

/// Supported image formats
pub const ImageFormat = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,
};

// =============================================================================
// CoreFoundation/CoreGraphics External Declarations
// =============================================================================

const cf = struct {
    extern "c" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, length: isize) ?*anyopaque;
    extern "c" fn CFRelease(cf_obj: *anyopaque) void;
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

// =============================================================================
// Public API
// =============================================================================

/// Load image from raw bytes (PNG, JPEG, etc.) using CoreGraphics
pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
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

// =============================================================================
// Internal Helpers
// =============================================================================

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
