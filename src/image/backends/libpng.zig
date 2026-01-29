//! Image Loader - Linux libpng Backend
//!
//! Decodes PNG images using libpng on Linux systems.
//! JPEG and other formats are currently unsupported but can be added.

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

/// Load image from raw bytes (PNG, JPEG, etc.)
pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
    // Detect format
    const format = detectFormat(data) orelse return LoadError.InvalidFormat;

    return switch (format) {
        .png => loadPng(allocator, data),
        .jpeg => LoadError.UnsupportedSource, // TODO: Add libjpeg support
        else => LoadError.UnsupportedSource,
    };
}

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

// =============================================================================
// libpng Implementation
// =============================================================================

const png = struct {
    // libpng types
    const png_structp = ?*anyopaque;
    const png_infop = ?*anyopaque;
    const png_bytep = [*]u8;
    const png_bytepp = [*][*]u8;

    // libpng functions
    extern "c" fn png_create_read_struct(
        user_png_ver: [*:0]const u8,
        error_ptr: ?*anyopaque,
        error_fn: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
        warn_fn: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
    ) png_structp;
    extern "c" fn png_create_info_struct(png_ptr: png_structp) png_infop;
    extern "c" fn png_destroy_read_struct(
        png_ptr_ptr: *png_structp,
        info_ptr_ptr: *png_infop,
        end_info_ptr_ptr: *png_infop,
    ) void;
    extern "c" fn png_read_info(png_ptr: png_structp, info_ptr: png_infop) void;
    extern "c" fn png_get_image_width(png_ptr: png_structp, info_ptr: png_infop) u32;
    extern "c" fn png_get_image_height(png_ptr: png_structp, info_ptr: png_infop) u32;
    extern "c" fn png_get_color_type(png_ptr: png_structp, info_ptr: png_infop) u8;
    extern "c" fn png_get_bit_depth(png_ptr: png_structp, info_ptr: png_infop) u8;
    extern "c" fn png_set_expand(png_ptr: png_structp) void;
    extern "c" fn png_set_strip_16(png_ptr: png_structp) void;
    extern "c" fn png_set_gray_to_rgb(png_ptr: png_structp) void;
    extern "c" fn png_set_add_alpha(png_ptr: png_structp, filler: u32, flags: c_int) void;
    extern "c" fn png_read_update_info(png_ptr: png_structp, info_ptr: png_infop) void;
    extern "c" fn png_read_image(png_ptr: png_structp, row_pointers: png_bytepp) void;
    extern "c" fn png_read_end(png_ptr: png_structp, info_ptr: png_infop) void;

    const PNG_COLOR_TYPE_GRAY: u8 = 0;
    const PNG_COLOR_TYPE_RGB: u8 = 2;
    const PNG_COLOR_TYPE_PALETTE: u8 = 3;
    const PNG_COLOR_TYPE_GRAY_ALPHA: u8 = 4;
    const PNG_COLOR_TYPE_RGBA: u8 = 6;
    const PNG_FILLER_AFTER: c_int = 1;
};

const libc = struct {
    extern "c" fn fmemopen(buf: ?*const anyopaque, size: usize, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fclose(stream: *anyopaque) c_int;
    extern "c" fn png_init_io(png_ptr: png.png_structp, fp: *anyopaque) void;
};

/// PNG loading using libpng
fn loadPng(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
    // Check PNG signature
    const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &png_signature)) {
        return LoadError.InvalidFormat;
    }

    // Create PNG read struct
    var png_ptr = png.png_create_read_struct("1.6.0", null, null, null);
    if (png_ptr == null) {
        return LoadError.OutOfMemory;
    }

    var info_ptr = png.png_create_info_struct(png_ptr);
    if (info_ptr == null) {
        var null_info: png.png_infop = null;
        png.png_destroy_read_struct(&png_ptr, &null_info, &null_info);
        return LoadError.OutOfMemory;
    }

    defer {
        var null_info: png.png_infop = null;
        png.png_destroy_read_struct(&png_ptr, &info_ptr, &null_info);
    }

    // Use memory-based reading - create a simple FILE* wrapper using fmemopen
    const fp = libc.fmemopen(@ptrCast(data.ptr), data.len, "rb") orelse {
        return LoadError.IoError;
    };
    defer _ = libc.fclose(fp);

    libc.png_init_io(png_ptr, fp);

    // Read PNG info
    png.png_read_info(png_ptr, info_ptr);

    const width = png.png_get_image_width(png_ptr, info_ptr);
    const height = png.png_get_image_height(png_ptr, info_ptr);
    const color_type = png.png_get_color_type(png_ptr, info_ptr);
    const bit_depth = png.png_get_bit_depth(png_ptr, info_ptr);

    if (width == 0 or height == 0) {
        return LoadError.DecodeFailed;
    }

    // Transform to RGBA
    if (bit_depth == 16) {
        png.png_set_strip_16(png_ptr);
    }

    if (color_type == png.PNG_COLOR_TYPE_PALETTE) {
        png.png_set_expand(png_ptr);
    }

    if (color_type == png.PNG_COLOR_TYPE_GRAY and bit_depth < 8) {
        png.png_set_expand(png_ptr);
    }

    if (color_type == png.PNG_COLOR_TYPE_GRAY or color_type == png.PNG_COLOR_TYPE_GRAY_ALPHA) {
        png.png_set_gray_to_rgb(png_ptr);
    }

    if (color_type == png.PNG_COLOR_TYPE_RGB or color_type == png.PNG_COLOR_TYPE_GRAY or color_type == png.PNG_COLOR_TYPE_PALETTE) {
        png.png_set_add_alpha(png_ptr, 0xFF, png.PNG_FILLER_AFTER);
    }

    png.png_read_update_info(png_ptr, info_ptr);

    // Allocate output buffer
    const pixels = allocator.alloc(u8, width * height * 4) catch {
        return LoadError.OutOfMemory;
    };
    errdefer allocator.free(pixels);

    // Allocate row pointers
    const row_pointers = allocator.alloc([*]u8, height) catch {
        return LoadError.OutOfMemory;
    };
    defer allocator.free(row_pointers);

    for (0..height) |y| {
        row_pointers[y] = pixels.ptr + y * width * 4;
    }

    // Read image data
    png.png_read_image(png_ptr, row_pointers.ptr);
    png.png_read_end(png_ptr, null);

    return DecodedImage{
        .width = width,
        .height = height,
        .pixels = pixels,
        .allocator = allocator,
    };
}
