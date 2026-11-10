//! Hand-written WIC (Windows Imaging Component) bindings for the Windows image
//! backend.
//!
//! Only the subset of `windowscodecs.dll` and `ole32.dll` the backend calls.
//! Declared by hand for the same reasons as the DirectWrite bindings: Gooey
//! takes no package dependencies (CLAUDE.md §12) and the tree type-checks from
//! any host.
//!
//! WIC is COM. Each vtable below lists every slot of its interface in the order
//! of `wincodec.h` and `objidl.h`, because a method is found by its slot index
//! alone. Slots the backend never calls are typed `Slot`. The comptime block at
//! the end pins the slot of every method the backend calls and the size of
//! every vtable, so a missing or extra slot fails to compile.
//!
//! Released COM vtables never change, so the declarations stay correct once
//! they match the headers. Naming follows the SDK so each declaration can be
//! checked against Microsoft's documentation by name.

const std = @import("std");
const assert = std.debug.assert;

// =============================================================================
// Scalar types
// =============================================================================

pub const HRESULT = i32;

pub const S_OK: HRESULT = 0;
/// `CoInitializeEx`: COM was already initialized on this thread, same model.
pub const S_FALSE: HRESULT = 1;
/// `CoInitializeEx`: COM was already initialized on this thread as an STA.
pub const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x8001_0106));
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007_000E));
/// No installed decoder recognizes the data.
pub const WINCODEC_ERR_COMPONENTNOTFOUND: HRESULT = @bitCast(@as(u32, 0x8898_2F50));
pub const WINCODEC_ERR_UNKNOWNIMAGEFORMAT: HRESULT = @bitCast(@as(u32, 0x8898_2F07));

/// `SUCCEEDED`: every non-negative `HRESULT` reports success.
pub fn succeeded(result: HRESULT) bool {
    return result >= 0;
}

/// A vtable slot the backend never calls. It only holds its place.
pub const Slot = *const anyopaque;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub const WICRect = extern struct {
    X: i32,
    Y: i32,
    Width: i32,
    Height: i32,
};

// =============================================================================
// Class and interface identifiers
// =============================================================================

/// `CLSID_WICImagingFactory1`: available since Windows 7, and every interface
/// the backend uses is on it.
pub const CLSID_WICImagingFactory: GUID = .{
    .data1 = 0xCACA_F262,
    .data2 = 0x9370,
    .data3 = 0x4615,
    .data4 = .{ 0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A },
};

pub const IID_IWICImagingFactory: GUID = .{
    .data1 = 0xEC5E_C8A9,
    .data2 = 0xC395,
    .data3 = 0x4314,
    .data4 = .{ 0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70 },
};

/// Four bytes per pixel in R, G, B, A order, with straight (not premultiplied)
/// alpha: the layout `ImageData.format == .rgba` promises.
pub const GUID_WICPixelFormat32bppRGBA: GUID = .{
    .data1 = 0xF5C7_AD2D,
    .data2 = 0x6A8D,
    .data3 = 0x43DD,
    .data4 = .{ 0xA7, 0xA8, 0xA2, 0x99, 0x35, 0x26, 0x1A, 0xE9 },
};

// =============================================================================
// Enumerations (C enums: 32 bits)
// =============================================================================

pub const COINIT_MULTITHREADED: u32 = 0x0;
pub const CLSCTX_INPROC_SERVER: u32 = 0x1;

pub const WICDecodeMetadataCacheOnDemand: u32 = 0;
pub const WICBitmapDitherTypeNone: u32 = 0;
pub const WICBitmapPaletteTypeCustom: u32 = 0;

// =============================================================================
// Interfaces
// =============================================================================

pub const IWICImagingFactory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IWICImagingFactory) callconv(.winapi) u32,
        CreateDecoderFromFilename: Slot,
        CreateDecoderFromStream: *const fn (
            *IWICImagingFactory,
            *IWICStream, // An IWICStream is an IStream.
            ?*const GUID, // pguidVendor
            u32, // WICDecodeOptions
            *?*IWICBitmapDecoder,
        ) callconv(.winapi) HRESULT,
        CreateDecoderFromFileHandle: Slot,
        CreateComponentInfo: Slot,
        CreateDecoder: Slot,
        CreateEncoder: Slot,
        CreatePalette: Slot,
        CreateFormatConverter: *const fn (
            *IWICImagingFactory,
            *?*IWICFormatConverter,
        ) callconv(.winapi) HRESULT,
        CreateBitmapScaler: Slot,
        CreateBitmapClipper: Slot,
        CreateBitmapFlipRotator: Slot,
        CreateStream: *const fn (
            *IWICImagingFactory,
            *?*IWICStream,
        ) callconv(.winapi) HRESULT,
        CreateColorContext: Slot,
        CreateColorTransformer: Slot,
        CreateBitmap: Slot,
        CreateBitmapFromSource: Slot,
        CreateBitmapFromSourceRect: Slot,
        CreateBitmapFromMemory: Slot,
        CreateBitmapFromHBITMAP: Slot,
        CreateBitmapFromHICON: Slot,
        CreateComponentEnumerator: Slot,
        CreateFastMetadataEncoderFromDecoder: Slot,
        CreateFastMetadataEncoderFromFrameDecode: Slot,
        CreateQueryWriter: Slot,
        CreateQueryWriterFromReader: Slot,
    };

    pub fn release(self: *IWICImagingFactory) void {
        _ = self.vtable.Release(self);
    }
};

pub const IWICStream = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IWICStream) callconv(.winapi) u32,
        // ISequentialStream.
        Read: Slot,
        Write: Slot,
        // IStream.
        Seek: Slot,
        SetSize: Slot,
        CopyTo: Slot,
        Commit: Slot,
        Revert: Slot,
        LockRegion: Slot,
        UnlockRegion: Slot,
        Stat: Slot,
        Clone: Slot,
        // IWICStream.
        InitializeFromIStream: Slot,
        InitializeFromFilename: Slot,
        /// The header types the buffer as writable because the stream supports
        /// `Write`. Decoders only read and seek, and the backend never writes,
        /// so the buffer is declared `const` here.
        InitializeFromMemory: *const fn (
            *IWICStream,
            [*]const u8,
            u32, // cbBufferSize
        ) callconv(.winapi) HRESULT,
        InitializeFromIStreamRegion: Slot,
    };

    pub fn release(self: *IWICStream) void {
        _ = self.vtable.Release(self);
    }
};

pub const IWICBitmapDecoder = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IWICBitmapDecoder) callconv(.winapi) u32,
        QueryCapability: Slot,
        Initialize: Slot,
        GetContainerFormat: Slot,
        GetDecoderInfo: Slot,
        CopyPalette: Slot,
        GetMetadataQueryReader: Slot,
        GetPreview: Slot,
        GetColorContexts: Slot,
        GetThumbnail: Slot,
        GetFrameCount: Slot,
        GetFrame: *const fn (
            *IWICBitmapDecoder,
            u32, // index
            *?*IWICBitmapFrameDecode,
        ) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICBitmapDecoder) void {
        _ = self.vtable.Release(self);
    }
};

/// The base of every bitmap interface. Only passed between calls, so it stays
/// opaque; `IWICBitmapFrameDecode.source` and `IWICFormatConverter` cover the
/// methods the backend calls.
pub const IWICBitmapSource = opaque {};

pub const IWICBitmapFrameDecode = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IWICBitmapFrameDecode) callconv(.winapi) u32,
        // IWICBitmapSource.
        GetSize: *const fn (*IWICBitmapFrameDecode, *u32, *u32) callconv(.winapi) HRESULT,
        GetPixelFormat: Slot,
        GetResolution: Slot,
        CopyPalette: Slot,
        CopyPixels: Slot,
        // IWICBitmapFrameDecode.
        GetMetadataQueryReader: Slot,
        GetColorContexts: Slot,
        GetThumbnail: Slot,
    };

    pub fn release(self: *IWICBitmapFrameDecode) void {
        _ = self.vtable.Release(self);
    }

    /// COM single inheritance: a derived interface pointer is also a pointer
    /// to each of its bases.
    pub fn source(self: *IWICBitmapFrameDecode) *IWICBitmapSource {
        return @ptrCast(self);
    }
};

pub const IWICFormatConverter = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IWICFormatConverter) callconv(.winapi) u32,
        // IWICBitmapSource.
        GetSize: Slot,
        GetPixelFormat: Slot,
        GetResolution: Slot,
        CopyPalette: Slot,
        CopyPixels: *const fn (
            *IWICFormatConverter,
            ?*const WICRect, // null copies the whole bitmap
            u32, // cbStride
            u32, // cbBufferSize
            [*]u8,
        ) callconv(.winapi) HRESULT,
        // IWICFormatConverter.
        Initialize: *const fn (
            *IWICFormatConverter,
            *IWICBitmapSource,
            *const GUID, // dstFormat
            u32, // WICBitmapDitherType
            ?*anyopaque, // pIPalette
            f64, // alphaThresholdPercent
            u32, // WICBitmapPaletteType
        ) callconv(.winapi) HRESULT,
        CanConvert: Slot,
    };

    pub fn release(self: *IWICFormatConverter) void {
        _ = self.vtable.Release(self);
    }
};

// =============================================================================
// Functions
// =============================================================================

pub extern "ole32" fn CoInitializeEx(
    pvReserved: ?*anyopaque,
    dwCoInit: u32,
) callconv(.winapi) HRESULT;

pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

pub extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

// =============================================================================
// Layout pins
// =============================================================================

fn assertSlot(comptime VTable: type, comptime name: []const u8, comptime slot: u32) void {
    assert(@offsetOf(VTable, name) == slot * @sizeOf(usize));
}

fn assertSlotCount(comptime VTable: type, comptime count: u32) void {
    assert(@sizeOf(VTable) == count * @sizeOf(usize));
}

comptime {
    // `x86_64-windows` only; see `docs/windows-port.md`.
    assert(@sizeOf(usize) == 8);

    assert(@sizeOf(GUID) == 16);
    assert(@sizeOf(WICRect) == 16);

    assertSlot(IWICImagingFactory.VTable, "Release", 2);
    assertSlot(IWICImagingFactory.VTable, "CreateDecoderFromStream", 4);
    assertSlot(IWICImagingFactory.VTable, "CreateFormatConverter", 10);
    assertSlot(IWICImagingFactory.VTable, "CreateStream", 14);
    assertSlotCount(IWICImagingFactory.VTable, 28);

    assertSlot(IWICStream.VTable, "Release", 2);
    assertSlot(IWICStream.VTable, "InitializeFromMemory", 16);
    assertSlotCount(IWICStream.VTable, 18);

    assertSlot(IWICBitmapDecoder.VTable, "Release", 2);
    assertSlot(IWICBitmapDecoder.VTable, "GetFrame", 13);
    assertSlotCount(IWICBitmapDecoder.VTable, 14);

    assertSlot(IWICBitmapFrameDecode.VTable, "Release", 2);
    assertSlot(IWICBitmapFrameDecode.VTable, "GetSize", 3);
    assertSlotCount(IWICBitmapFrameDecode.VTable, 11);

    assertSlot(IWICFormatConverter.VTable, "Release", 2);
    assertSlot(IWICFormatConverter.VTable, "CopyPixels", 7);
    assertSlot(IWICFormatConverter.VTable, "Initialize", 8);
    assertSlotCount(IWICFormatConverter.VTable, 10);
}
