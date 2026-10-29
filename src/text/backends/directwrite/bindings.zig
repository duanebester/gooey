//! Hand-written DirectWrite bindings for the Windows text backend.
//!
//! Only the subset of `dwrite.dll` the backend calls. Declared by hand for the
//! same reasons as `platform/windows/win32.zig`: Gooey takes no package
//! dependencies (CLAUDE.md §12) and the tree type-checks from any host.
//!
//! DirectWrite is COM. An interface pointer points at an object whose first
//! field is its vtable pointer, and every method takes the object as its first
//! argument. Each vtable below lists every slot of the interface, in the order
//! of the SDK headers (`dwrite.h`, `dwrite_1.h`, `dwrite_2.h`), because a
//! method is found by its slot index alone. Slots the backend never calls are
//! typed `Slot`. The comptime block at the end pins the slot index of every
//! method the backend does call, and the 64-bit layout of every structure.
//!
//! Released COM vtables and structures never change, so the declarations stay
//! correct once they match the headers. Naming follows the SDK so each
//! declaration can be checked against Microsoft's documentation by name.

const std = @import("std");
const assert = std.debug.assert;

// =============================================================================
// Scalar types
// =============================================================================

pub const BOOL = i32;
pub const HRESULT = i32;
pub const WCHAR = u16;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x8000_4002));
/// `HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER)`.
pub const E_NOT_SUFFICIENT_BUFFER: HRESULT = @bitCast(@as(u32, 0x8007_007A));

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

    pub fn eql(self: *const GUID, other: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(other));
    }
};

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

// =============================================================================
// Interface identifiers
// =============================================================================

pub const IID_IUnknown: GUID = .{
    .data1 = 0x0000_0000,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

pub const IID_IDWriteFactory2: GUID = .{
    .data1 = 0x0439_FC60,
    .data2 = 0xCA44,
    .data3 = 0x4994,
    .data4 = .{ 0x8D, 0xEE, 0x3A, 0x9A, 0xF7, 0xB7, 0x32, 0xEC },
};

pub const IID_IDWriteFontFace1: GUID = .{
    .data1 = 0xA71E_FDB4,
    .data2 = 0x9FDB,
    .data3 = 0x4838,
    .data4 = .{ 0xAD, 0x90, 0xCF, 0xC3, 0xBE, 0x8C, 0x3D, 0xAF },
};

pub const IID_IDWriteTextAnalysisSource: GUID = .{
    .data1 = 0x688E_1A58,
    .data2 = 0x5094,
    .data3 = 0x47C8,
    .data4 = .{ 0xAD, 0xC8, 0xFB, 0xCE, 0xA6, 0x0A, 0xE9, 0x2B },
};

pub const IID_IDWriteTextAnalysisSink: GUID = .{
    .data1 = 0x5810_CD44,
    .data2 = 0x0CA0,
    .data3 = 0x4701,
    .data4 = .{ 0xB3, 0xFA, 0xBE, 0xC5, 0x18, 0x2A, 0xE4, 0xF6 },
};

// =============================================================================
// Enumerations (C enums: 32 bits)
// =============================================================================

pub const DWRITE_FACTORY_TYPE_SHARED: u32 = 0;

pub const DWRITE_FONT_STYLE_NORMAL: u32 = 0;
pub const DWRITE_FONT_STYLE_OBLIQUE: u32 = 1;
pub const DWRITE_FONT_STYLE_ITALIC: u32 = 2;

pub const DWRITE_FONT_STRETCH_UNDEFINED: u32 = 0;
pub const DWRITE_FONT_STRETCH_ULTRA_EXPANDED: u32 = 9;

pub const DWRITE_FONT_SIMULATIONS_NONE: u32 = 0;

pub const DWRITE_READING_DIRECTION_LEFT_TO_RIGHT: u32 = 0;

pub const DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC: u32 = 5;
pub const DWRITE_MEASURING_MODE_NATURAL: u32 = 0;
pub const DWRITE_GRID_FIT_MODE_DISABLED: u32 = 1;
pub const DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 1;

/// With `DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE`, this texture type holds one
/// 8-bit coverage value per pixel, not the binary coverage its name suggests.
pub const DWRITE_TEXTURE_ALIASED_1x1: u32 = 0;

// =============================================================================
// Structures
// =============================================================================

pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};

pub const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};

pub const DWRITE_GLYPH_OFFSET = extern struct {
    advanceOffset: f32,
    ascenderOffset: f32,
};

pub const DWRITE_MATRIX = extern struct {
    m11: f32,
    m12: f32,
    m21: f32,
    m22: f32,
    dx: f32,
    dy: f32,
};

pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: *IDWriteFontFace,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: [*]const u16,
    glyphAdvances: ?[*]const f32,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
    isSideways: BOOL,
    bidiLevel: u32,
};

pub const DWRITE_SCRIPT_ANALYSIS = extern struct {
    script: u16,
    shapes: u32,
};

/// Bit fields in the headers; the shaper only passes these between calls.
pub const DWRITE_SHAPING_TEXT_PROPERTIES = extern struct { bits: u16 };
pub const DWRITE_SHAPING_GLYPH_PROPERTIES = extern struct { bits: u16 };

// =============================================================================
// Interfaces called by the backend
// =============================================================================

pub const IDWriteFactory2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IDWriteFactory2) callconv(.winapi) u32,
        GetSystemFontCollection: *const fn (
            *IDWriteFactory2,
            *?*IDWriteFontCollection,
            BOOL,
        ) callconv(.winapi) HRESULT,
        CreateCustomFontCollection: Slot,
        RegisterFontCollectionLoader: Slot,
        UnregisterFontCollectionLoader: Slot,
        CreateFontFileReference: Slot,
        CreateCustomFontFileReference: Slot,
        CreateFontFace: Slot,
        CreateRenderingParams: Slot,
        CreateMonitorRenderingParams: Slot,
        CreateCustomRenderingParams: Slot,
        RegisterFontFileLoader: Slot,
        UnregisterFontFileLoader: Slot,
        CreateTextFormat: Slot,
        CreateTypography: Slot,
        GetGdiInterop: Slot,
        CreateTextLayout: Slot,
        CreateGdiCompatibleTextLayout: Slot,
        CreateEllipsisTrimmingSign: Slot,
        CreateTextAnalyzer: *const fn (
            *IDWriteFactory2,
            *?*IDWriteTextAnalyzer,
        ) callconv(.winapi) HRESULT,
        CreateNumberSubstitution: Slot,
        CreateGlyphRunAnalysis: Slot,
        // IDWriteFactory1.
        GetEudcFontCollection: Slot,
        CreateCustomRenderingParams1: Slot,
        // IDWriteFactory2.
        GetSystemFontFallback: Slot,
        CreateFontFallbackBuilder: Slot,
        TranslateColorGlyphRun: Slot,
        CreateCustomRenderingParams2: Slot,
        CreateGlyphRunAnalysis2: *const fn (
            *IDWriteFactory2,
            *const DWRITE_GLYPH_RUN,
            ?*const DWRITE_MATRIX,
            u32, // DWRITE_RENDERING_MODE
            u32, // DWRITE_MEASURING_MODE
            u32, // DWRITE_GRID_FIT_MODE
            u32, // DWRITE_TEXT_ANTIALIAS_MODE
            f32, // baselineOriginX
            f32, // baselineOriginY
            *?*IDWriteGlyphRunAnalysis,
        ) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFactory2) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
        GetFontFamilyCount: Slot,
        GetFontFamily: *const fn (
            *IDWriteFontCollection,
            u32,
            *?*IDWriteFontFamily,
        ) callconv(.winapi) HRESULT,
        FindFamilyName: *const fn (
            *IDWriteFontCollection,
            [*:0]const WCHAR,
            *u32,
            *BOOL,
        ) callconv(.winapi) HRESULT,
        GetFontFromFontFace: Slot,
    };

    pub fn release(self: *IDWriteFontCollection) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
        // IDWriteFontList.
        GetFontCollection: Slot,
        GetFontCount: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
        GetFont: *const fn (
            *IDWriteFontFamily,
            u32,
            *?*IDWriteFont,
        ) callconv(.winapi) HRESULT,
        // IDWriteFontFamily.
        GetFamilyNames: Slot,
        GetFirstMatchingFont: Slot,
        GetMatchingFonts: Slot,
    };

    pub fn release(self: *IDWriteFontFamily) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IDWriteFont) callconv(.winapi) u32,
        GetFontFamily: Slot,
        GetWeight: *const fn (*IDWriteFont) callconv(.winapi) u32,
        GetStretch: *const fn (*IDWriteFont) callconv(.winapi) u32,
        GetStyle: *const fn (*IDWriteFont) callconv(.winapi) u32,
        IsSymbolFont: Slot,
        GetFaceNames: Slot,
        GetInformationalStrings: Slot,
        GetSimulations: *const fn (*IDWriteFont) callconv(.winapi) u32,
        GetMetrics: Slot,
        HasCharacter: Slot,
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFont) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (
            *IDWriteFontFace,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: Slot,
        Release: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
        GetType: Slot,
        GetFiles: Slot,
        GetIndex: Slot,
        GetSimulations: Slot,
        IsSymbolFont: Slot,
        GetMetrics: *const fn (*IDWriteFontFace, *DWRITE_FONT_METRICS) callconv(.winapi) void,
        GetGlyphCount: *const fn (*IDWriteFontFace) callconv(.winapi) u16,
        GetDesignGlyphMetrics: *const fn (
            *IDWriteFontFace,
            [*]const u16,
            u32,
            [*]DWRITE_GLYPH_METRICS,
            BOOL,
        ) callconv(.winapi) HRESULT,
        GetGlyphIndices: *const fn (
            *IDWriteFontFace,
            [*]const u32,
            u32,
            [*]u16,
        ) callconv(.winapi) HRESULT,
        TryGetFontTable: Slot,
        ReleaseFontTable: Slot,
        GetGlyphRunOutline: Slot,
        GetRecommendedRenderingMode: Slot,
        GetGdiCompatibleMetrics: Slot,
        GetGdiCompatibleGlyphMetrics: Slot,
    };

    pub fn release(self: *IDWriteFontFace) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontFace1 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IDWriteFontFace: 18 slots.
        base: [18]Slot,
        // IDWriteFontFace1.
        GetMetrics1: Slot,
        GetGdiCompatibleMetrics1: Slot,
        GetCaretMetrics: Slot,
        GetUnicodeRanges: Slot,
        IsMonospacedFont: *const fn (*IDWriteFontFace1) callconv(.winapi) BOOL,
    };

    pub fn release(self: *IDWriteFontFace1) void {
        // `Release` is slot 2 of every interface.
        const release_fn: *const fn (*IDWriteFontFace1) callconv(.winapi) u32 =
            @ptrCast(self.vtable.base[2]);
        _ = release_fn(self);
    }
};

pub const IDWriteTextAnalyzer = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IDWriteTextAnalyzer) callconv(.winapi) u32,
        AnalyzeScript: *const fn (
            *IDWriteTextAnalyzer,
            *IDWriteTextAnalysisSource,
            u32, // textPosition
            u32, // textLength
            *IDWriteTextAnalysisSink,
        ) callconv(.winapi) HRESULT,
        AnalyzeBidi: Slot,
        AnalyzeNumberSubstitution: Slot,
        AnalyzeLineBreakpoints: Slot,
        GetGlyphs: *const fn (
            *IDWriteTextAnalyzer,
            [*]const WCHAR, // textString
            u32, // textLength
            *IDWriteFontFace,
            BOOL, // isSideways
            BOOL, // isRightToLeft
            *const DWRITE_SCRIPT_ANALYSIS,
            ?[*:0]const WCHAR, // localeName
            ?*anyopaque, // numberSubstitution
            ?*const anyopaque, // features
            ?[*]const u32, // featureRangeLengths
            u32, // featureRanges
            u32, // maxGlyphCount
            [*]u16, // clusterMap
            [*]DWRITE_SHAPING_TEXT_PROPERTIES,
            [*]u16, // glyphIndices
            [*]DWRITE_SHAPING_GLYPH_PROPERTIES,
            *u32, // actualGlyphCount
        ) callconv(.winapi) HRESULT,
        GetGlyphPlacements: *const fn (
            *IDWriteTextAnalyzer,
            [*]const WCHAR, // textString
            [*]const u16, // clusterMap
            [*]DWRITE_SHAPING_TEXT_PROPERTIES,
            u32, // textLength
            [*]const u16, // glyphIndices
            [*]const DWRITE_SHAPING_GLYPH_PROPERTIES,
            u32, // glyphCount
            *IDWriteFontFace,
            f32, // fontEmSize
            BOOL, // isSideways
            BOOL, // isRightToLeft
            *const DWRITE_SCRIPT_ANALYSIS,
            ?[*:0]const WCHAR, // localeName
            ?*const anyopaque, // features
            ?[*]const u32, // featureRangeLengths
            u32, // featureRanges
            [*]f32, // glyphAdvances
            [*]DWRITE_GLYPH_OFFSET,
        ) callconv(.winapi) HRESULT,
        GetGdiCompatibleGlyphPlacements: Slot,
    };

    pub fn release(self: *IDWriteTextAnalyzer) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteGlyphRunAnalysis = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IDWriteGlyphRunAnalysis) callconv(.winapi) u32,
        GetAlphaTextureBounds: *const fn (
            *IDWriteGlyphRunAnalysis,
            u32, // DWRITE_TEXTURE_TYPE
            *RECT,
        ) callconv(.winapi) HRESULT,
        CreateAlphaTexture: *const fn (
            *IDWriteGlyphRunAnalysis,
            u32, // DWRITE_TEXTURE_TYPE
            *const RECT,
            [*]u8,
            u32, // bufferSize
        ) callconv(.winapi) HRESULT,
        GetAlphaBlendParams: Slot,
    };

    pub fn release(self: *IDWriteGlyphRunAnalysis) void {
        _ = self.vtable.Release(self);
    }
};

// =============================================================================
// Interfaces implemented by the backend
// =============================================================================

/// The text source `AnalyzeScript` reads from. The shaper implements it.
pub const IDWriteTextAnalysisSource = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (
            *IDWriteTextAnalysisSource,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
        Release: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
        GetTextAtPosition: *const fn (
            *IDWriteTextAnalysisSource,
            u32,
            *?[*]const WCHAR,
            *u32,
        ) callconv(.winapi) HRESULT,
        GetTextBeforePosition: *const fn (
            *IDWriteTextAnalysisSource,
            u32,
            *?[*]const WCHAR,
            *u32,
        ) callconv(.winapi) HRESULT,
        GetParagraphReadingDirection: *const fn (
            *IDWriteTextAnalysisSource,
        ) callconv(.winapi) u32,
        GetLocaleName: *const fn (
            *IDWriteTextAnalysisSource,
            u32,
            *u32,
            *?[*:0]const WCHAR,
        ) callconv(.winapi) HRESULT,
        GetNumberSubstitution: *const fn (
            *IDWriteTextAnalysisSource,
            u32,
            *u32,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

/// The sink `AnalyzeScript` reports script runs to. The shaper implements it.
pub const IDWriteTextAnalysisSink = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (
            *IDWriteTextAnalysisSink,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteTextAnalysisSink) callconv(.winapi) u32,
        Release: *const fn (*IDWriteTextAnalysisSink) callconv(.winapi) u32,
        SetScriptAnalysis: *const fn (
            *IDWriteTextAnalysisSink,
            u32,
            u32,
            *const DWRITE_SCRIPT_ANALYSIS,
        ) callconv(.winapi) HRESULT,
        SetLineBreakpoints: *const fn (
            *IDWriteTextAnalysisSink,
            u32,
            u32,
            *const anyopaque,
        ) callconv(.winapi) HRESULT,
        SetBidiLevel: *const fn (
            *IDWriteTextAnalysisSink,
            u32,
            u32,
            u8,
            u8,
        ) callconv(.winapi) HRESULT,
        SetNumberSubstitution: *const fn (
            *IDWriteTextAnalysisSink,
            u32,
            u32,
            ?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

// =============================================================================
// Functions
// =============================================================================

pub extern "dwrite" fn DWriteCreateFactory(
    factoryType: u32,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

// =============================================================================
// Layout pins
// =============================================================================

fn assertSlot(comptime VTable: type, comptime name: []const u8, comptime slot: u32) void {
    assert(@offsetOf(VTable, name) == slot * @sizeOf(usize));
}

comptime {
    // `x86_64-windows` only; see `docs/windows-port.md`.
    assert(@sizeOf(usize) == 8);

    assert(@sizeOf(GUID) == 16);
    assert(@sizeOf(RECT) == 16);
    assert(@sizeOf(DWRITE_FONT_METRICS) == 20);
    assert(@sizeOf(DWRITE_GLYPH_METRICS) == 28);
    assert(@sizeOf(DWRITE_GLYPH_OFFSET) == 8);
    assert(@sizeOf(DWRITE_MATRIX) == 24);
    assert(@sizeOf(DWRITE_GLYPH_RUN) == 48);
    assert(@offsetOf(DWRITE_GLYPH_RUN, "glyphIndices") == 16);
    assert(@offsetOf(DWRITE_GLYPH_RUN, "isSideways") == 40);
    assert(@sizeOf(DWRITE_SCRIPT_ANALYSIS) == 8);
    assert(@offsetOf(DWRITE_SCRIPT_ANALYSIS, "shapes") == 4);
    assert(@sizeOf(DWRITE_SHAPING_TEXT_PROPERTIES) == 2);
    assert(@sizeOf(DWRITE_SHAPING_GLYPH_PROPERTIES) == 2);

    assertSlot(IDWriteFactory2.VTable, "Release", 2);
    assertSlot(IDWriteFactory2.VTable, "GetSystemFontCollection", 3);
    assertSlot(IDWriteFactory2.VTable, "CreateTextAnalyzer", 21);
    assertSlot(IDWriteFactory2.VTable, "CreateGlyphRunAnalysis", 23);
    assertSlot(IDWriteFactory2.VTable, "GetSystemFontFallback", 26);
    assertSlot(IDWriteFactory2.VTable, "CreateGlyphRunAnalysis2", 30);
    assert(@sizeOf(IDWriteFactory2.VTable) == 31 * @sizeOf(usize));

    assertSlot(IDWriteFontCollection.VTable, "GetFontFamily", 4);
    assertSlot(IDWriteFontCollection.VTable, "FindFamilyName", 5);

    assertSlot(IDWriteFontFamily.VTable, "GetFontCount", 4);
    assertSlot(IDWriteFontFamily.VTable, "GetFont", 5);

    assertSlot(IDWriteFont.VTable, "GetWeight", 4);
    assertSlot(IDWriteFont.VTable, "GetStretch", 5);
    assertSlot(IDWriteFont.VTable, "GetStyle", 6);
    assertSlot(IDWriteFont.VTable, "GetSimulations", 10);
    assertSlot(IDWriteFont.VTable, "CreateFontFace", 13);

    assertSlot(IDWriteFontFace.VTable, "GetMetrics", 8);
    assertSlot(IDWriteFontFace.VTable, "GetGlyphCount", 9);
    assertSlot(IDWriteFontFace.VTable, "GetDesignGlyphMetrics", 10);
    assertSlot(IDWriteFontFace.VTable, "GetGlyphIndices", 11);
    assert(@sizeOf(IDWriteFontFace.VTable) == 18 * @sizeOf(usize));
    assertSlot(IDWriteFontFace1.VTable, "IsMonospacedFont", 22);

    assertSlot(IDWriteTextAnalyzer.VTable, "AnalyzeScript", 3);
    assertSlot(IDWriteTextAnalyzer.VTable, "GetGlyphs", 7);
    assertSlot(IDWriteTextAnalyzer.VTable, "GetGlyphPlacements", 8);

    assertSlot(IDWriteGlyphRunAnalysis.VTable, "GetAlphaTextureBounds", 3);
    assertSlot(IDWriteGlyphRunAnalysis.VTable, "CreateAlphaTexture", 4);

    assertSlot(IDWriteTextAnalysisSource.VTable, "GetNumberSubstitution", 7);
    assertSlot(IDWriteTextAnalysisSink.VTable, "SetNumberSubstitution", 6);
}
