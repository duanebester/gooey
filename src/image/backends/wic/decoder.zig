//! Image Loader - Windows WIC Backend
//!
//! Decodes images with the Windows Imaging Component, a system API, so no
//! codec is vendored (CLAUDE.md §12). WIC sniffs the container itself: PNG,
//! JPEG, GIF, BMP, TIFF, and ICO decode on every supported Windows release, and
//! WebP or HEIF wherever their system codecs are installed. Like the
//! CoreGraphics backend, a multi-frame image yields its first frame, and EXIF
//! orientation and embedded color profiles are not applied.
//!
//! The decoded frame converts straight to `GUID_WICPixelFormat32bppRGBA`, which
//! is the `ImageData.format == .rgba` layout (straight alpha), so the pixels
//! need no swizzle and no unpremultiply pass.
//!
//! Threading: `loadFromMemory` runs on the frame thread for embedded and path
//! sources, and on `Io.Group` worker threads for URL sources. WIC objects must
//! be created on a thread where COM is initialized, so each call enters COM for
//! its own duration and leaves it balanced. A thread that already initialized
//! COM, in either model, keeps its model; the call only borrows it.
//!
//! Memory: the pixel buffer is allocated from the caller's allocator because
//! the `DecodedImage` contract shared with the other backends returns owned
//! pixels. It is bounded by `image_side_max` in each dimension: at most 1 GiB
//! transient for one decode, and `width * height * 4` bytes in practice.
//! WIC's own objects live for the call and are released before it returns.

const std = @import("std");
const assert = std.debug.assert;
const interface_verify = @import("../../../core/interface_verify.zig");
const atlas = @import("../../atlas.zig");
const wic = @import("bindings.zig");

const ImageData = atlas.ImageData;
const log = std.log.scoped(.image_wic);

// Compile-time interface verification
comptime {
    interface_verify.verifyImageLoaderModule(@This());
}

/// Largest accepted width or height in pixels. WIC sizes `CopyPixels` buffers
/// in 32 bits, so the full RGBA frame must fit a `u32` byte count.
pub const image_side_max: u32 = 16_384;

const bytes_per_pixel: u32 = 4;

comptime {
    const frame_bytes_max: u64 = @as(u64, image_side_max) * image_side_max * bytes_per_pixel;
    assert(frame_bytes_max <= std.math.maxInt(u32));
}

/// Result of image decoding
pub const DecodedImage = struct {
    width: u32,
    height: u32,
    /// RGBA pixel data (owned by allocator)
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        assert(self.pixels.len == pixelBytes(.{ .width = self.width, .height = self.height }));
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn toImageData(self: *const DecodedImage) ImageData {
        assert(self.width > 0);
        assert(self.pixels.len == pixelBytes(.{ .width = self.width, .height = self.height }));
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

/// Decodes the first frame of an encoded image into straight-alpha RGBA.
///
/// - `InvalidFormat`: empty data, or no installed codec claims it. Codecs
///   probe the header before claiming, so a PNG signature over an invalid
///   header is also `InvalidFormat`.
/// - `UnsupportedSource`: the data or the frame exceeds the 32-bit sizes WIC
///   takes (`image_side_max` per side).
/// - `DecodeFailed`: a claimed frame reports no pixels or fails later in WIC,
///   or COM could not start. A PNG truncated or corrupt inside its pixel data
///   is not an error: WIC decodes what it can and the rest is transparent
///   black.
pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) LoadError!DecodedImage {
    if (data.len == 0) return error.InvalidFormat;
    if (data.len > std.math.maxInt(u32)) return error.UnsupportedSource;

    const com_entered = try comEnter();
    defer if (com_entered) wic.CoUninitialize();

    const factory = try createFactory();
    defer factory.release();

    const stream = try createStream(factory, data);
    defer stream.release();

    const decoder = try createDecoder(factory, stream);
    defer decoder.release();

    const frame = try firstFrame(decoder);
    defer frame.release();

    const size = try frameSize(frame);
    assert(size.width <= image_side_max);
    assert(size.height <= image_side_max);

    const converter = try createConverter(factory, frame);
    defer converter.release();

    const image = try copyPixels(allocator, converter, size);
    assert(image.width == size.width);
    assert(image.height == size.height);
    return image;
}

const FrameSize = struct {
    width: u32,
    height: u32,
};

/// Bytes in a tightly packed RGBA frame; `image_side_max` keeps it in `u32`.
fn pixelBytes(size: FrameSize) usize {
    assert(size.width <= image_side_max);
    assert(size.height <= image_side_max);
    return @as(usize, size.width) * size.height * bytes_per_pixel;
}

/// Enters COM on the calling thread. Returns whether the caller must balance
/// the entry with `CoUninitialize`: every successful `CoInitializeEx`,
/// including `S_FALSE`, needs one. `RPC_E_CHANGED_MODE` means the thread is
/// already an STA, where WIC works just as well, and that entry is not ours.
fn comEnter() LoadError!bool {
    const result = wic.CoInitializeEx(null, wic.COINIT_MULTITHREADED);
    if (result == wic.RPC_E_CHANGED_MODE) return false;
    if (wic.succeeded(result)) {
        assert(result == wic.S_OK or result == wic.S_FALSE);
        return true;
    }
    return loadError("CoInitializeEx", result);
}

fn createFactory() LoadError!*wic.IWICImagingFactory {
    var factory: ?*anyopaque = null;
    const result = wic.CoCreateInstance(
        &wic.CLSID_WICImagingFactory,
        null,
        wic.CLSCTX_INPROC_SERVER,
        &wic.IID_IWICImagingFactory,
        &factory,
    );
    if (!wic.succeeded(result)) return loadError("CoCreateInstance", result);
    assert(factory != null);
    // COM interface pointers point at a vtable pointer, so they are aligned.
    assert(std.mem.isAligned(@intFromPtr(factory.?), @alignOf(wic.IWICImagingFactory)));
    return @ptrCast(@alignCast(factory.?));
}

/// Wraps `data` without copying. The stream borrows the bytes, so it must be
/// released before `data` goes out of scope; `loadFromMemory` guarantees that.
fn createStream(factory: *wic.IWICImagingFactory, data: []const u8) LoadError!*wic.IWICStream {
    assert(data.len > 0);
    assert(data.len <= std.math.maxInt(u32));

    var stream: ?*wic.IWICStream = null;
    const create_result = factory.vtable.CreateStream(factory, &stream);
    if (!wic.succeeded(create_result)) return loadError("CreateStream", create_result);
    assert(stream != null);
    errdefer stream.?.release();

    const data_len: u32 = @intCast(data.len);
    const init_result = stream.?.vtable.InitializeFromMemory(stream.?, data.ptr, data_len);
    if (!wic.succeeded(init_result)) return loadError("InitializeFromMemory", init_result);
    return stream.?;
}

fn createDecoder(
    factory: *wic.IWICImagingFactory,
    stream: *wic.IWICStream,
) LoadError!*wic.IWICBitmapDecoder {
    var decoder: ?*wic.IWICBitmapDecoder = null;
    const result = factory.vtable.CreateDecoderFromStream(
        factory,
        stream,
        null,
        wic.WICDecodeMetadataCacheOnDemand,
        &decoder,
    );
    if (!wic.succeeded(result)) return loadError("CreateDecoderFromStream", result);
    assert(decoder != null);
    return decoder.?;
}

fn firstFrame(decoder: *wic.IWICBitmapDecoder) LoadError!*wic.IWICBitmapFrameDecode {
    var frame: ?*wic.IWICBitmapFrameDecode = null;
    const result = decoder.vtable.GetFrame(decoder, 0, &frame);
    if (!wic.succeeded(result)) return loadError("GetFrame", result);
    assert(frame != null);
    return frame.?;
}

/// Reads and validates the frame's dimensions before any pixel buffer exists,
/// so an oversized header is rejected without allocating.
fn frameSize(frame: *wic.IWICBitmapFrameDecode) LoadError!FrameSize {
    var width: u32 = 0;
    var height: u32 = 0;
    const result = frame.vtable.GetSize(frame, &width, &height);
    if (!wic.succeeded(result)) return loadError("GetSize", result);

    if (width == 0) return error.DecodeFailed;
    if (height == 0) return error.DecodeFailed;
    if (width > image_side_max) return error.UnsupportedSource;
    if (height > image_side_max) return error.UnsupportedSource;
    assert(pixelBytes(.{ .width = width, .height = height }) <= std.math.maxInt(u32));
    return .{ .width = width, .height = height };
}

fn createConverter(
    factory: *wic.IWICImagingFactory,
    frame: *wic.IWICBitmapFrameDecode,
) LoadError!*wic.IWICFormatConverter {
    var converter: ?*wic.IWICFormatConverter = null;
    const create_result = factory.vtable.CreateFormatConverter(factory, &converter);
    if (!wic.succeeded(create_result)) return loadError("CreateFormatConverter", create_result);
    assert(converter != null);
    errdefer converter.?.release();

    const init_result = converter.?.vtable.Initialize(
        converter.?,
        frame.source(),
        &wic.GUID_WICPixelFormat32bppRGBA,
        wic.WICBitmapDitherTypeNone,
        null,
        0.0,
        wic.WICBitmapPaletteTypeCustom,
    );
    if (!wic.succeeded(init_result)) return loadError("FormatConverter.Initialize", init_result);
    return converter.?;
}

/// Decodes the whole frame into a tightly packed buffer: a stride of exactly
/// `width * 4` bytes, which is what the image atlas reads.
///
/// WIC's PNG decoder reports success for a stream truncated or corrupt inside
/// its pixel data and leaves the rows it could not decode to the output
/// buffer. The buffer is zeroed first so those rows are transparent black,
/// deterministically, rather than whatever the allocator last held
/// (CLAUDE.md §21).
fn copyPixels(
    allocator: std.mem.Allocator,
    converter: *wic.IWICFormatConverter,
    size: FrameSize,
) LoadError!DecodedImage {
    assert(size.width > 0);
    assert(size.width <= image_side_max);
    assert(size.height > 0);
    assert(size.height <= image_side_max);

    const stride_bytes: u32 = size.width * bytes_per_pixel;
    const frame_bytes: u32 = stride_bytes * size.height;

    const pixels = allocator.alloc(u8, frame_bytes) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    const result = converter.vtable.CopyPixels(
        converter,
        null,
        stride_bytes,
        frame_bytes,
        pixels.ptr,
    );
    if (!wic.succeeded(result)) return loadError("CopyPixels", result);

    assert(pixels.len == pixelBytes(size));
    return .{
        .width = size.width,
        .height = size.height,
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Classifies a failed `HRESULT`. Unrecognized data is the caller's input
/// problem; anything else is logged with its code, which names the cause in
/// Microsoft's documentation.
fn loadError(operation: []const u8, result: wic.HRESULT) LoadError {
    assert(operation.len > 0);
    assert(!wic.succeeded(result));

    if (result == wic.E_OUTOFMEMORY) return error.OutOfMemory;
    if (result == wic.WINCODEC_ERR_COMPONENTNOTFOUND) return error.InvalidFormat;
    if (result == wic.WINCODEC_ERR_UNKNOWNIMAGEFORMAT) return error.InvalidFormat;

    const code: u32 = @bitCast(result);
    log.debug("{s} failed: HRESULT 0x{X:0>8}", .{ operation, code });
    return error.DecodeFailed;
}
