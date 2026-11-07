//! Hand-written DirectWrite COM bindings for the Windows text backend.
//!
//! Zero-dependency, header-free: every interface is an `extern struct`
//! holding a pointer to its vtable, with unused slots kept as opaque
//! function pointers at the offsets the Windows SDK defines. Only the
//! subset Gooey needs is given a typed signature — factory creation,
//! system font collection lookup, `IDWriteFontFace` glyph metrics,
//! `IDWriteTextAnalyzer` shaping, and `IDWriteGlyphRunAnalysis`
//! grayscale rasterization.
//!
//! Layouts and IIDs follow `dwrite.h` / `dwrite_1.h`. `callconv(.winapi)`
//! is the x86-64 Microsoft ABI used by all COM methods.

const std = @import("std");

pub const BOOL = i32;
pub const HRESULT = i32;
pub const ULONG = u32;
pub const FLOAT = f32;
pub const UINT32 = u32;
pub const UINT16 = u16;
pub const INT16 = i16;
pub const INT32 = i32;

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

pub const IUnknownVTable = extern struct {
    QueryInterface: *const fn (*const anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*const anyopaque) callconv(.winapi) ULONG,
    Release: *const fn (*const anyopaque) callconv(.winapi) ULONG,
};

/// Every COM interface starts with the three IUnknown slots. A pointer to
/// any typed interface can be cast to `*IUnknown` for lifetime management.
pub const IUnknown = extern struct {
    vtable: *const IUnknownVTable,

    pub fn release(self: *const IUnknown) ULONG {
        return self.vtable.Release(@ptrCast(self));
    }
};

fn Release(comptime T: type, obj: ?*T) void {
    if (obj) |o| _ = (@as(*const IUnknown, @ptrCast(@alignCast(o)))).release();
}

pub const hrOk = struct {
    pub fn check(hr: HRESULT) bool {
        return hr >= 0;
    }
};

// =============================================================================
// Enums / value structs
// =============================================================================

pub const DWRITE_FACTORY_TYPE = enum(i32) { shared = 0, isolated = 1 };
pub const DWRITE_FONT_WEIGHT = enum(i32) { regular = 400, bold = 700 };
pub const DWRITE_FONT_STYLE = enum(i32) { normal = 0, oblique = 1, italic = 2 };
pub const DWRITE_FONT_STRETCH = enum(i32) { normal = 5 };
pub const DWRITE_RENDERING_MODE = enum(i32) {
    default = 0,
    aliased = 1,
    gdi_classic = 2,
    gdi_natural = 3,
    natural = 4,
    natural_symmetric = 5,
    outline = 6,
};
pub const DWRITE_MEASURING_MODE = enum(i32) { natural = 0, gdi_classic = 1, gdi_natural = 2 };
pub const DWRITE_TEXTURE_TYPE = enum(i32) { aliased_1x1 = 0, cleartype_3x1 = 1 };
pub const DWRITE_SCRIPT_SHAPES = enum(i32) { default = 0, no_visual = 1 };

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

pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: ?*IDWriteFontFace,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: [*]const u16,
    glyphAdvances: ?[*]const f32,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
    isSideways: BOOL,
    bidiLevel: u32,
};

pub const DWRITE_MATRIX = extern struct {
    m11: f32,
    m12: f32,
    m21: f32,
    m22: f32,
    dx: f32,
    dy: f32,
};

pub const DWRITE_SCRIPT_ANALYSIS = extern struct {
    script: u16,
    shapes: DWRITE_SCRIPT_SHAPES,
};

pub const DWRITE_SHAPING_TEXT_PROPERTIES = extern struct { bits: u16 };
pub const DWRITE_SHAPING_GLYPH_PROPERTIES = extern struct { bits: u16 };
pub const DWRITE_TYPOGRAPHIC_FEATURES = extern struct { unused: u32 };

// =============================================================================
// Interfaces (opaque slots keep the vtable offsets exact)
// =============================================================================

/// Placeholder for a vtable slot whose interface Gooey never calls. Declared
/// as `*const anyopaque` so the struct keeps its size and alignment without
/// inventing a signature for an API we do not use.
const Slot = *const anyopaque;

pub const IDWriteFontFile = opaque {};
pub const IDWriteFontFileLoader = opaque {};
pub const IDWriteFontCollectionLoader = opaque {};
pub const IDWriteNumberSubstitution = opaque {};
pub const IDWriteTextAnalysisSource = opaque {};
pub const IDWriteTextAnalysisSink = opaque {};
pub const IDWriteRenderingParams = opaque {};
pub const IDWriteTextFormat = opaque {};
pub const IDWriteTextLayout = opaque {};
pub const IDWriteTypography = opaque {};
pub const IDWriteLocalizedStrings = opaque {};
pub const IDWriteInlineObject = opaque {};
pub const ID2D1SimplifiedGeometrySink = opaque {};

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknownVTable,
        GetFontFamilyCount: *const fn (*const IDWriteFontCollection) callconv(.winapi) u32,
        GetFontFamily: *const fn (*const IDWriteFontCollection, u32, **IDWriteFontFamily) callconv(.winapi) HRESULT,
        FindFamilyName: *const fn (*const IDWriteFontCollection, ?[*:0]const u16, ?*u32, ?*BOOL) callconv(.winapi) HRESULT,
        GetFontFromFontFace: Slot,
    };

    pub fn findFamilyName(self: *const IDWriteFontCollection, name: [*:0]const u16) ?u32 {
        var index: u32 = 0;
        var exists: BOOL = 0;
        if (!hrOk.check(self.vtable.FindFamilyName(self, name, &index, &exists))) return null;
        return if (exists != 0) index else null;
    }

    pub fn getFontFamily(self: *const IDWriteFontCollection, index: u32) ?*IDWriteFontFamily {
        var family: *IDWriteFontFamily = undefined;
        if (!hrOk.check(self.vtable.GetFontFamily(self, index, &family))) return null;
        return family;
    }
};

pub const IDWriteFontList = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknownVTable,
        GetFontCollection: Slot,
        GetFontCount: *const fn (*const IDWriteFontList) callconv(.winapi) u32,
        GetFont: *const fn (*const IDWriteFontList, u32, **IDWriteFont) callconv(.winapi) HRESULT,
    };
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    /// `IDWriteFontFamily` derives from `IDWriteFontList`: the first four
    /// vtable slots are IUnknown (3) + the list methods (3).
    pub const VTable = extern struct {
        base: IUnknownVTable,
        GetFontCollection: Slot,
        GetFontCount: Slot,
        GetFont: Slot,
        GetFamilyNames: Slot,
        GetFirstMatchingFont: *const fn (
            *const IDWriteFontFamily,
            DWRITE_FONT_WEIGHT,
            DWRITE_FONT_STRETCH,
            DWRITE_FONT_STYLE,
            **IDWriteFont,
        ) callconv(.winapi) HRESULT,
        GetMatchingFonts: Slot,
    };

    pub fn getFirstMatchingFont(self: *const IDWriteFontFamily) ?*IDWriteFont {
        var font: *IDWriteFont = undefined;
        if (!hrOk.check(self.vtable.GetFirstMatchingFont(
            self,
            .regular,
            .normal,
            .normal,
            &font,
        ))) return null;
        return font;
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknownVTable,
        GetFontFamily: Slot,
        GetWeight: Slot,
        GetStretch: Slot,
        GetStyle: Slot,
        IsSymbolFont: Slot,
        GetFaceNames: Slot,
        GetInformationalStrings: Slot,
        GetSimulations: Slot,
        GetMetrics: Slot,
        HasCharacter: Slot,
        CreateFontFace: *const fn (*const IDWriteFont, **IDWriteFontFace) callconv(.winapi) HRESULT,
    };

    pub fn createFontFace(self: *const IDWriteFont) ?*IDWriteFontFace {
        var face: *IDWriteFontFace = undefined;
        if (!hrOk.check(self.vtable.CreateFontFace(self, &face))) return null;
        return face;
    }
};

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknownVTable,
        GetType: Slot,
        GetFiles: Slot,
        GetIndex: Slot,
        GetSimulations: Slot,
        IsSymbolFont: Slot,
        GetMetrics: *const fn (*const IDWriteFontFace, *DWRITE_FONT_METRICS) callconv(.winapi) void,
        GetGlyphCount: *const fn (*const IDWriteFontFace) callconv(.winapi) u16,
        GetDesignGlyphMetrics: *const fn (
            *const IDWriteFontFace,
            [*]const u16,
            u32,
            [*]DWRITE_GLYPH_METRICS,
            BOOL,
        ) callconv(.winapi) HRESULT,
        GetGlyphIndices: *const fn (*const IDWriteFontFace, [*]const u32, u32, [*]u16) callconv(.winapi) HRESULT,
        TryGetFontTable: Slot,
        ReleaseFontTable: Slot,
        GetGlyphRunOutline: Slot,
        GetRecommendedRenderingMode: Slot,
        GetGdiCompatibleMetrics: Slot,
        GetGdiCompatibleGlyphMetrics: Slot,
    };

    pub fn getMetrics(self: *const IDWriteFontFace) DWRITE_FONT_METRICS {
        var m: DWRITE_FONT_METRICS = undefined;
        self.vtable.GetMetrics(self, &m);
        return m;
    }

    pub fn getGlyphIndices(self: *const IDWriteFontFace, codepoints: []const u32, out: []u16) bool {
        return hrOk.check(self.vtable.GetGlyphIndices(
            self,
            @ptrCast(codepoints.ptr),
            @intCast(codepoints.len),
            @ptrCast(out.ptr),
        ));
    }

    pub fn getDesignGlyphMetrics(self: *const IDWriteFontFace, indices: []const u16, out: []DWRITE_GLYPH_METRICS) bool {
        return hrOk.check(self.vtable.GetDesignGlyphMetrics(
            self,
            @ptrCast(indices.ptr),
            @intCast(indices.len),
            @ptrCast(out.ptr),
            0,
        ));
    }
};

pub const IDWriteTextAnalyzer = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknownVTable,
        AnalyzeScript: Slot,
        AnalyzeBidi: Slot,
        AnalyzeNumberSubstitution: Slot,
        AnalyzeLineBreakpoints: Slot,
        GetGlyphs: *const fn (
            *const IDWriteTextAnalyzer,
            [*:0]const u16,
            u32,
            ?*IDWriteFontFace,
            BOOL,
            BOOL,
            ?*const DWRITE_SCRIPT_ANALYSIS,
            ?[*:0]const u16,
            ?*IDWriteNumberSubstitution,
            ?[*]const ?*const DWRITE_TYPOGRAPHIC_FEATURES,
            ?[*]const u32,
            u32,
            u32,
            [*]u16,
            [*]DWRITE_SHAPING_TEXT_PROPERTIES,
            [*]u16,
            [*]DWRITE_SHAPING_GLYPH_PROPERTIES,
            ?*u32,
        ) callconv(.winapi) HRESULT,
        GetGlyphPlacements: *const fn (
            *const IDWriteTextAnalyzer,
            [*:0]const u16,
            [*]const u16,
            [*]DWRITE_SHAPING_TEXT_PROPERTIES,
            u32,
            [*]const u16,
            [*]const DWRITE_SHAPING_GLYPH_PROPERTIES,
            u32,
            ?*IDWriteFontFace,
            f32,
            BOOL,
            BOOL,
            ?*const DWRITE_SCRIPT_ANALYSIS,
            ?[*:0]const u16,
            ?[*]const ?*const DWRITE_TYPOGRAPHIC_FEATURES,
            ?[*]const u32,
            u32,
            [*]f32,
            [*]DWRITE_GLYPH_OFFSET,
        ) callconv(.winapi) HRESULT,
        GetGdiCompatibleGlyphPlacements: Slot,
    };

    /// First shaping pass: map UTF-16 text onto glyph indices. `max_glyph_count`
    /// is an upper bound the caller allocates for (DirectWrite requires it).
    pub fn getGlyphs(
        self: *const IDWriteTextAnalyzer,
        text: [*:0]const u16,
        text_len: u32,
        face: *IDWriteFontFace,
        max_glyph_count: u32,
        cluster_map: [*]u16,
        text_props: [*]DWRITE_SHAPING_TEXT_PROPERTIES,
        glyph_indices: [*]u16,
        glyph_props: [*]DWRITE_SHAPING_GLYPH_PROPERTIES,
        actual_count: *u32,
    ) bool {
        const script = DWRITE_SCRIPT_ANALYSIS{ .script = 0, .shapes = .default };
        return hrOk.check(self.vtable.GetGlyphs(
            self,
            text,
            text_len,
            face,
            0,
            0,
            &script,
            null,
            null,
            null,
            null,
            0,
            max_glyph_count,
            cluster_map,
            text_props,
            glyph_indices,
            glyph_props,
            actual_count,
        ));
    }

    /// Second pass: advances and offsets in DIPs at `font_em_size`.
    pub fn getGlyphPlacements(
        self: *const IDWriteTextAnalyzer,
        text: [*:0]const u16,
        cluster_map: [*]const u16,
        text_props: [*]DWRITE_SHAPING_TEXT_PROPERTIES,
        text_len: u32,
        glyph_indices: [*]const u16,
        glyph_props: [*]const DWRITE_SHAPING_GLYPH_PROPERTIES,
        glyph_count: u32,
        face: *IDWriteFontFace,
        font_em_size: f32,
        advances: [*]f32,
        offsets: [*]DWRITE_GLYPH_OFFSET,
    ) bool {
        const script = DWRITE_SCRIPT_ANALYSIS{ .script = 0, .shapes = .default };
        return hrOk.check(self.vtable.GetGlyphPlacements(
            self,
            text,
            cluster_map,
            text_props,
            text_len,
            glyph_indices,
            glyph_props,
            glyph_count,
            face,
            font_em_size,
            0,
            0,
            &script,
            null,
            null,
            null,
            0,
            advances,
            offsets,
        ));
    }
};

pub const IDWriteGlyphRunAnalysis = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknownVTable,
        GetAlphaTextureBounds: *const fn (
            *const IDWriteGlyphRunAnalysis,
            DWRITE_TEXTURE_TYPE,
            *RECT,
        ) callconv(.winapi) HRESULT,
        CreateAlphaTexture: *const fn (
            *const IDWriteGlyphRunAnalysis,
            DWRITE_TEXTURE_TYPE,
            ?*const RECT,
            ?[*]u8,
            u32,
        ) callconv(.winapi) HRESULT,
        GetAlphaBlendParams: Slot,
    };

    /// Bounds of the analysis' ClearType 3×1 texture — the only texture type
    /// `DWRITE_RENDERING_MODE_NATURAL` produces. Each pixel is 3 bytes of
    /// sub-pixel coverage.
    pub fn getAlphaTextureBounds(self: *const IDWriteGlyphRunAnalysis) ?RECT {
        var r: RECT = undefined;
        if (!hrOk.check(self.vtable.GetAlphaTextureBounds(self, .cleartype_3x1, &r))) return null;
        return r;
    }

    pub fn createAlphaTexture(self: *const IDWriteGlyphRunAnalysis, bounds: *const RECT, out: [*]u8, size: u32) bool {
        return hrOk.check(self.vtable.CreateAlphaTexture(self, .cleartype_3x1, bounds, out, size));
    }
};

pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknownVTable,
        GetSystemFontCollection: *const fn (*const IDWriteFactory, **IDWriteFontCollection, BOOL) callconv(.winapi) HRESULT,
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
        CreateTextAnalyzer: *const fn (*const IDWriteFactory, **IDWriteTextAnalyzer) callconv(.winapi) HRESULT,
        CreateNumberSubstitution: Slot,
        CreateGlyphRunAnalysis: *const fn (
            *const IDWriteFactory,
            *const DWRITE_GLYPH_RUN,
            f32,
            ?*const DWRITE_MATRIX,
            DWRITE_RENDERING_MODE,
            DWRITE_MEASURING_MODE,
            f32,
            f32,
            **IDWriteGlyphRunAnalysis,
        ) callconv(.winapi) HRESULT,
    };

    pub fn getSystemFontCollection(self: *const IDWriteFactory) ?*IDWriteFontCollection {
        var collection: *IDWriteFontCollection = undefined;
        if (!hrOk.check(self.vtable.GetSystemFontCollection(self, &collection, 0))) return null;
        return collection;
    }

    pub fn createTextAnalyzer(self: *const IDWriteFactory) ?*IDWriteTextAnalyzer {
        var analyzer: *IDWriteTextAnalyzer = undefined;
        if (!hrOk.check(self.vtable.CreateTextAnalyzer(self, &analyzer))) return null;
        return analyzer;
    }

    pub fn createGlyphRunAnalysis(
        self: *const IDWriteFactory,
        glyph_run: *const DWRITE_GLYPH_RUN,
        pixels_per_dip: f32,
        baseline_x: f32,
        baseline_y: f32,
    ) ?*IDWriteGlyphRunAnalysis {
        var analysis: *IDWriteGlyphRunAnalysis = undefined;
        if (!hrOk.check(self.vtable.CreateGlyphRunAnalysis(
            self,
            glyph_run,
            pixels_per_dip,
            null,
            .natural,
            .natural,
            baseline_x,
            baseline_y,
            &analysis,
        ))) return null;
        return analysis;
    }
};

// =============================================================================
// Entry point
// =============================================================================

/// `IID_IDWriteFactory` = {b859ee5a-d838-4b5b-a2e8-1adc7d93db48}.
pub const IID_IDWriteFactory = GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

pub extern "dwrite" fn DWriteCreateFactory(
    factory_type: DWRITE_FACTORY_TYPE,
    iid: *const GUID,
    factory: **anyopaque,
) callconv(.winapi) HRESULT;

/// Create the process-shared factory. The returned pointer is cast by the
/// caller to `*IDWriteFactory`; its vtable slot layout is pinned above.
pub fn createFactory() ?*IDWriteFactory {
    var raw: *anyopaque = undefined;
    if (!hrOk.check(DWriteCreateFactory(.shared, &IID_IDWriteFactory, &raw))) return null;
    return @ptrCast(@alignCast(raw));
}

/// Release helper usable from any typed interface pointer.
pub fn release(comptime T: type, obj: ?*T) void {
    Release(T, obj);
}

// =============================================================================
// Tests
// =============================================================================

test "GUID layout and IID_IDWriteFactory byte order" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    try std.testing.expectEqual(@as(u32, 0xb859ee5a), IID_IDWriteFactory.Data1);
    try std.testing.expectEqual(@as(u16, 0xd838), IID_IDWriteFactory.Data2);
    try std.testing.expectEqual(@as(u8, 0xa2), IID_IDWriteFactory.Data4[0]);
}

test "DWRITE_FONT_METRICS and DWRITE_GLYPH_RUN match the SDK layout" {
    if (@sizeOf(usize) == 8) {
        // Ten UINT16/INT16 fields, naturally packed — 20 bytes.
        try std.testing.expectEqual(@as(usize, 20), @sizeOf(DWRITE_FONT_METRICS));
        // Seven 32-bit fields, naturally packed — 28 bytes.
        try std.testing.expectEqual(@as(usize, 28), @sizeOf(DWRITE_GLYPH_METRICS));
        try std.testing.expectEqual(@as(usize, 48), @sizeOf(DWRITE_GLYPH_RUN));
    }
}
