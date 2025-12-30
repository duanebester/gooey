//! FreeType, HarfBuzz, and Fontconfig bindings for Linux text rendering
//!
//! Provides low-level access to:
//! - FreeType: Font loading and glyph rasterization
//! - HarfBuzz: Complex text shaping (ligatures, kerning, scripts)
//! - Fontconfig: Font discovery and matching

const std = @import("std");

// ============================================================================
// FreeType Types
// ============================================================================

pub const FT_Error = c_int;
pub const FT_Int = c_int;
pub const FT_UInt = c_uint;
pub const FT_Long = c_long;
pub const FT_ULong = c_ulong;
pub const FT_Short = c_short;
pub const FT_UShort = c_ushort;
pub const FT_Int32 = i32;
pub const FT_UInt32 = u32;
pub const FT_Fixed = c_long; // 16.16 fixed-point
pub const FT_Pos = c_long; // 26.6 fixed-point for positions
pub const FT_F26Dot6 = c_long; // 26.6 fixed-point

pub const FT_Library = *opaque {};
pub const FT_Face = *FT_FaceRec;
pub const FT_GlyphSlot = *FT_GlyphSlotRec;
pub const FT_Size = *FT_SizeRec;
pub const FT_CharMap = *FT_CharMapRec;
pub const FT_Glyph = *FT_GlyphRec;
pub const FT_BitmapGlyph = *FT_BitmapGlyphRec;

// FreeType face flags
pub const FT_FACE_FLAG_SCALABLE: FT_Long = 1 << 0;
pub const FT_FACE_FLAG_FIXED_SIZES: FT_Long = 1 << 1;
pub const FT_FACE_FLAG_FIXED_WIDTH: FT_Long = 1 << 2;
pub const FT_FACE_FLAG_SFNT: FT_Long = 1 << 3;
pub const FT_FACE_FLAG_HORIZONTAL: FT_Long = 1 << 4;
pub const FT_FACE_FLAG_VERTICAL: FT_Long = 1 << 5;
pub const FT_FACE_FLAG_KERNING: FT_Long = 1 << 6;
pub const FT_FACE_FLAG_COLOR: FT_Long = 1 << 14;

// FreeType load flags
pub const FT_LOAD_DEFAULT: FT_Int32 = 0;
pub const FT_LOAD_NO_SCALE: FT_Int32 = 1 << 0;
pub const FT_LOAD_NO_HINTING: FT_Int32 = 1 << 1;
pub const FT_LOAD_RENDER: FT_Int32 = 1 << 2;
pub const FT_LOAD_NO_BITMAP: FT_Int32 = 1 << 3;
pub const FT_LOAD_VERTICAL_LAYOUT: FT_Int32 = 1 << 4;
pub const FT_LOAD_FORCE_AUTOHINT: FT_Int32 = 1 << 5;
pub const FT_LOAD_CROP_BITMAP: FT_Int32 = 1 << 6;
pub const FT_LOAD_PEDANTIC: FT_Int32 = 1 << 7;
pub const FT_LOAD_IGNORE_GLOBAL_ADVANCE_WIDTH: FT_Int32 = 1 << 9;
pub const FT_LOAD_NO_RECURSE: FT_Int32 = 1 << 10;
pub const FT_LOAD_IGNORE_TRANSFORM: FT_Int32 = 1 << 11;
pub const FT_LOAD_MONOCHROME: FT_Int32 = 1 << 12;
pub const FT_LOAD_LINEAR_DESIGN: FT_Int32 = 1 << 13;
pub const FT_LOAD_COLOR: FT_Int32 = 1 << 20;

// FreeType render modes
pub const FT_Render_Mode = enum(c_int) {
    FT_RENDER_MODE_NORMAL = 0, // Grayscale (8-bit anti-aliased)
    FT_RENDER_MODE_LIGHT = 1, // Light hinting
    FT_RENDER_MODE_MONO = 2, // Monochrome (1-bit)
    FT_RENDER_MODE_LCD = 3, // Horizontal LCD subpixel
    FT_RENDER_MODE_LCD_V = 4, // Vertical LCD subpixel
    FT_RENDER_MODE_SDF = 5, // Signed distance field
};

// FreeType pixel modes (bitmap formats)
pub const FT_Pixel_Mode = enum(u8) {
    FT_PIXEL_MODE_NONE = 0,
    FT_PIXEL_MODE_MONO = 1, // 1 bit per pixel
    FT_PIXEL_MODE_GRAY = 2, // 8 bits per pixel (grayscale)
    FT_PIXEL_MODE_GRAY2 = 3, // 2 bits per pixel
    FT_PIXEL_MODE_GRAY4 = 4, // 4 bits per pixel
    FT_PIXEL_MODE_LCD = 5, // 8 bits per pixel (LCD)
    FT_PIXEL_MODE_LCD_V = 6, // 8 bits per pixel (vertical LCD)
    FT_PIXEL_MODE_BGRA = 7, // 32 bits per pixel (color emoji)
};

// FreeType glyph format
pub const FT_Glyph_Format = enum(c_uint) {
    FT_GLYPH_FORMAT_NONE = 0,
    FT_GLYPH_FORMAT_COMPOSITE = ftMakeTag('c', 'o', 'm', 'p'),
    FT_GLYPH_FORMAT_BITMAP = ftMakeTag('b', 'i', 't', 's'),
    FT_GLYPH_FORMAT_OUTLINE = ftMakeTag('o', 'u', 't', 'l'),
    FT_GLYPH_FORMAT_PLOTTER = ftMakeTag('p', 'l', 'o', 't'),
    FT_GLYPH_FORMAT_SVG = ftMakeTag('S', 'V', 'G', ' '),
};

fn ftMakeTag(a: u8, b: u8, c: u8, d: u8) c_uint {
    return (@as(c_uint, a) << 24) | (@as(c_uint, b) << 16) | (@as(c_uint, c) << 8) | @as(c_uint, d);
}

// FreeType vector (2D point)
pub const FT_Vector = extern struct {
    x: FT_Pos,
    y: FT_Pos,
};

// FreeType bounding box
pub const FT_BBox = extern struct {
    xMin: FT_Pos,
    yMin: FT_Pos,
    xMax: FT_Pos,
    yMax: FT_Pos,
};

// FreeType bitmap
pub const FT_Bitmap = extern struct {
    rows: c_uint,
    width: c_uint,
    pitch: c_int,
    buffer: [*]u8,
    num_grays: c_ushort,
    pixel_mode: FT_Pixel_Mode,
    palette_mode: u8,
    palette: ?*anyopaque,
};

// FreeType glyph metrics (in 26.6 fixed-point)
pub const FT_Glyph_Metrics = extern struct {
    width: FT_Pos,
    height: FT_Pos,
    horiBearingX: FT_Pos,
    horiBearingY: FT_Pos,
    horiAdvance: FT_Pos,
    vertBearingX: FT_Pos,
    vertBearingY: FT_Pos,
    vertAdvance: FT_Pos,
};

// FreeType size metrics
pub const FT_Size_Metrics = extern struct {
    x_ppem: FT_UShort, // Horizontal pixels per EM
    y_ppem: FT_UShort, // Vertical pixels per EM
    x_scale: FT_Fixed, // Scaling for horizontal
    y_scale: FT_Fixed, // Scaling for vertical
    ascender: FT_Pos, // Ascender in 26.6 frac. pixels
    descender: FT_Pos, // Descender in 26.6 frac. pixels
    height: FT_Pos, // Text height in 26.6 frac. pixels
    max_advance: FT_Pos, // Max horizontal advance
};

// FreeType size record
pub const FT_SizeRec = extern struct {
    face: FT_Face,
    generic: FT_Generic,
    metrics: FT_Size_Metrics,
    internal: ?*anyopaque,
};

// FreeType generic (for client data)
pub const FT_Generic = extern struct {
    data: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
};

// FreeType glyph slot
pub const FT_GlyphSlotRec = extern struct {
    library: FT_Library,
    face: FT_Face,
    next: ?FT_GlyphSlot,
    glyph_index: FT_UInt,
    generic: FT_Generic,
    metrics: FT_Glyph_Metrics,
    linearHoriAdvance: FT_Fixed,
    linearVertAdvance: FT_Fixed,
    advance: FT_Vector,
    format: FT_Glyph_Format,
    bitmap: FT_Bitmap,
    bitmap_left: FT_Int,
    bitmap_top: FT_Int,
    outline: FT_Outline,
    num_subglyphs: FT_UInt,
    subglyphs: ?*anyopaque,
    control_data: ?*anyopaque,
    control_len: c_long,
    lsb_delta: FT_Pos,
    rsb_delta: FT_Pos,
    other: ?*anyopaque,
    internal: ?*anyopaque,
};

// FreeType outline
pub const FT_Outline = extern struct {
    n_contours: c_short,
    n_points: c_short,
    points: ?[*]FT_Vector,
    tags: ?[*]u8,
    contours: ?[*]c_short,
    flags: c_int,
};

// FreeType charmap
pub const FT_CharMapRec = extern struct {
    face: FT_Face,
    encoding: FT_Encoding,
    platform_id: FT_UShort,
    encoding_id: FT_UShort,
};

pub const FT_Encoding = enum(c_uint) {
    FT_ENCODING_NONE = 0,
    FT_ENCODING_MS_SYMBOL = ftMakeTag('s', 'y', 'm', 'b'),
    FT_ENCODING_UNICODE = ftMakeTag('u', 'n', 'i', 'c'),
    FT_ENCODING_SJIS = ftMakeTag('s', 'j', 'i', 's'),
    FT_ENCODING_PRC = ftMakeTag('g', 'b', ' ', ' '),
    FT_ENCODING_BIG5 = ftMakeTag('b', 'i', 'g', '5'),
    FT_ENCODING_WANSUNG = ftMakeTag('w', 'a', 'n', 's'),
    FT_ENCODING_JOHAB = ftMakeTag('j', 'o', 'h', 'a'),
    FT_ENCODING_ADOBE_STANDARD = ftMakeTag('A', 'D', 'O', 'B'),
    FT_ENCODING_ADOBE_EXPERT = ftMakeTag('A', 'D', 'B', 'E'),
    FT_ENCODING_ADOBE_CUSTOM = ftMakeTag('A', 'D', 'B', 'C'),
    FT_ENCODING_ADOBE_LATIN_1 = ftMakeTag('l', 'a', 't', '1'),
    FT_ENCODING_OLD_LATIN_2 = ftMakeTag('l', 'a', 't', '2'),
    FT_ENCODING_APPLE_ROMAN = ftMakeTag('a', 'r', 'm', 'n'),
};

// FreeType face record
pub const FT_FaceRec = extern struct {
    num_faces: FT_Long,
    face_index: FT_Long,
    face_flags: FT_Long,
    style_flags: FT_Long,
    num_glyphs: FT_Long,
    family_name: ?[*:0]u8,
    style_name: ?[*:0]u8,
    num_fixed_sizes: FT_Int,
    available_sizes: ?*anyopaque,
    num_charmaps: FT_Int,
    charmaps: ?[*]FT_CharMap,
    generic: FT_Generic,
    bbox: FT_BBox,
    units_per_EM: FT_UShort,
    ascender: FT_Short,
    descender: FT_Short,
    height: FT_Short,
    max_advance_width: FT_Short,
    max_advance_height: FT_Short,
    underline_position: FT_Short,
    underline_thickness: FT_Short,
    glyph: FT_GlyphSlot,
    size: FT_Size,
    charmap: ?FT_CharMap,
    // Internal fields follow (private)
};

// FreeType glyph record (for FT_Get_Glyph)
pub const FT_GlyphRec = extern struct {
    library: FT_Library,
    clazz: ?*anyopaque,
    format: FT_Glyph_Format,
    advance: FT_Vector,
};

// FreeType bitmap glyph
pub const FT_BitmapGlyphRec = extern struct {
    root: FT_GlyphRec,
    left: FT_Int,
    top: FT_Int,
    bitmap: FT_Bitmap,
};

// FreeType 2x2 transformation matrix
pub const FT_Matrix = extern struct {
    xx: FT_Fixed,
    xy: FT_Fixed,
    yx: FT_Fixed,
    yy: FT_Fixed,
};

// ============================================================================
// FreeType Functions
// ============================================================================

pub extern "c" fn FT_Init_FreeType(alibrary: *FT_Library) FT_Error;
pub extern "c" fn FT_Done_FreeType(library: FT_Library) FT_Error;

pub extern "c" fn FT_New_Face(
    library: FT_Library,
    filepathname: [*:0]const u8,
    face_index: FT_Long,
    aface: *FT_Face,
) FT_Error;

pub extern "c" fn FT_New_Memory_Face(
    library: FT_Library,
    file_base: [*]const u8,
    file_size: FT_Long,
    face_index: FT_Long,
    aface: *FT_Face,
) FT_Error;

pub extern "c" fn FT_Done_Face(face: FT_Face) FT_Error;

pub extern "c" fn FT_Set_Char_Size(
    face: FT_Face,
    char_width: FT_F26Dot6, // In 1/64th points (0 = same as height)
    char_height: FT_F26Dot6, // In 1/64th points
    horz_resolution: FT_UInt, // DPI (0 = default 72)
    vert_resolution: FT_UInt, // DPI (0 = default 72)
) FT_Error;

pub extern "c" fn FT_Set_Pixel_Sizes(
    face: FT_Face,
    pixel_width: FT_UInt, // 0 = same as height
    pixel_height: FT_UInt,
) FT_Error;

pub extern "c" fn FT_Get_Char_Index(face: FT_Face, charcode: FT_ULong) FT_UInt;

pub extern "c" fn FT_Load_Glyph(
    face: FT_Face,
    glyph_index: FT_UInt,
    load_flags: FT_Int32,
) FT_Error;

pub extern "c" fn FT_Load_Char(
    face: FT_Face,
    char_code: FT_ULong,
    load_flags: FT_Int32,
) FT_Error;

pub extern "c" fn FT_Render_Glyph(
    slot: FT_GlyphSlot,
    render_mode: FT_Render_Mode,
) FT_Error;

pub extern "c" fn FT_Get_Glyph(
    slot: FT_GlyphSlot,
    aglyph: *FT_Glyph,
) FT_Error;

pub extern "c" fn FT_Glyph_To_Bitmap(
    the_glyph: *FT_Glyph,
    render_mode: FT_Render_Mode,
    origin: ?*FT_Vector, // Optional subpixel offset (26.6)
    destroy: c_int, // 1 to destroy original glyph
) FT_Error;

pub extern "c" fn FT_Done_Glyph(glyph: FT_Glyph) void;

pub extern "c" fn FT_Set_Transform(
    face: FT_Face,
    matrix: ?*const FT_Matrix,
    delta: ?*const FT_Vector,
) void;

pub extern "c" fn FT_Get_Kerning(
    face: FT_Face,
    left_glyph: FT_UInt,
    right_glyph: FT_UInt,
    kern_mode: FT_UInt,
    akerning: *FT_Vector,
) FT_Error;

// Kerning modes
pub const FT_KERNING_DEFAULT: FT_UInt = 0;
pub const FT_KERNING_UNFITTED: FT_UInt = 1;
pub const FT_KERNING_UNSCALED: FT_UInt = 2;

// ============================================================================
// HarfBuzz Types
// ============================================================================

pub const hb_bool_t = c_int;
pub const hb_codepoint_t = u32;
pub const hb_position_t = i32;
pub const hb_mask_t = u32;
pub const hb_tag_t = u32;

pub const hb_buffer_t = opaque {};
pub const hb_font_t = opaque {};
pub const hb_face_t = opaque {};
pub const hb_feature_t = extern struct {
    tag: hb_tag_t,
    value: u32,
    start: c_uint,
    end: c_uint,
};

pub const hb_direction_t = enum(c_int) {
    HB_DIRECTION_INVALID = 0,
    HB_DIRECTION_LTR = 4,
    HB_DIRECTION_RTL = 5,
    HB_DIRECTION_TTB = 6,
    HB_DIRECTION_BTT = 7,
};

pub const hb_script_t = enum(c_uint) {
    HB_SCRIPT_COMMON = hbMakeTag('Z', 'y', 'y', 'y'),
    HB_SCRIPT_INHERITED = hbMakeTag('Z', 'i', 'n', 'h'),
    HB_SCRIPT_UNKNOWN = hbMakeTag('Z', 'z', 'z', 'z'),
    HB_SCRIPT_ARABIC = hbMakeTag('A', 'r', 'a', 'b'),
    HB_SCRIPT_ARMENIAN = hbMakeTag('A', 'r', 'm', 'n'),
    HB_SCRIPT_BENGALI = hbMakeTag('B', 'e', 'n', 'g'),
    HB_SCRIPT_CYRILLIC = hbMakeTag('C', 'y', 'r', 'l'),
    HB_SCRIPT_DEVANAGARI = hbMakeTag('D', 'e', 'v', 'a'),
    HB_SCRIPT_GEORGIAN = hbMakeTag('G', 'e', 'o', 'r'),
    HB_SCRIPT_GREEK = hbMakeTag('G', 'r', 'e', 'k'),
    HB_SCRIPT_GUJARATI = hbMakeTag('G', 'u', 'j', 'r'),
    HB_SCRIPT_GURMUKHI = hbMakeTag('G', 'u', 'r', 'u'),
    HB_SCRIPT_HANGUL = hbMakeTag('H', 'a', 'n', 'g'),
    HB_SCRIPT_HAN = hbMakeTag('H', 'a', 'n', 'i'),
    HB_SCRIPT_HEBREW = hbMakeTag('H', 'e', 'b', 'r'),
    HB_SCRIPT_HIRAGANA = hbMakeTag('H', 'i', 'r', 'a'),
    HB_SCRIPT_KANNADA = hbMakeTag('K', 'n', 'd', 'a'),
    HB_SCRIPT_KATAKANA = hbMakeTag('K', 'a', 'n', 'a'),
    HB_SCRIPT_LAO = hbMakeTag('L', 'a', 'o', 'o'),
    HB_SCRIPT_LATIN = hbMakeTag('L', 'a', 't', 'n'),
    HB_SCRIPT_MALAYALAM = hbMakeTag('M', 'l', 'y', 'm'),
    HB_SCRIPT_ORIYA = hbMakeTag('O', 'r', 'y', 'a'),
    HB_SCRIPT_TAMIL = hbMakeTag('T', 'a', 'm', 'l'),
    HB_SCRIPT_TELUGU = hbMakeTag('T', 'e', 'l', 'u'),
    HB_SCRIPT_THAI = hbMakeTag('T', 'h', 'a', 'i'),
    HB_SCRIPT_TIBETAN = hbMakeTag('T', 'i', 'b', 't'),
    HB_SCRIPT_BOPOMOFO = hbMakeTag('B', 'o', 'p', 'o'),
    HB_SCRIPT_BRAILLE = hbMakeTag('B', 'r', 'a', 'i'),
    HB_SCRIPT_CANADIAN_SYLLABICS = hbMakeTag('C', 'a', 'n', 's'),
    HB_SCRIPT_CHEROKEE = hbMakeTag('C', 'h', 'e', 'r'),
    HB_SCRIPT_ETHIOPIC = hbMakeTag('E', 't', 'h', 'i'),
    HB_SCRIPT_KHMER = hbMakeTag('K', 'h', 'm', 'r'),
    HB_SCRIPT_MONGOLIAN = hbMakeTag('M', 'o', 'n', 'g'),
    HB_SCRIPT_MYANMAR = hbMakeTag('M', 'y', 'm', 'r'),
    HB_SCRIPT_OGHAM = hbMakeTag('O', 'g', 'a', 'm'),
    HB_SCRIPT_RUNIC = hbMakeTag('R', 'u', 'n', 'r'),
    HB_SCRIPT_SINHALA = hbMakeTag('S', 'i', 'n', 'h'),
    HB_SCRIPT_SYRIAC = hbMakeTag('S', 'y', 'r', 'c'),
    HB_SCRIPT_THAANA = hbMakeTag('T', 'h', 'a', 'a'),
    HB_SCRIPT_YI = hbMakeTag('Y', 'i', 'i', 'i'),
    _,
};

fn hbMakeTag(a: u8, b: u8, c: u8, d: u8) c_uint {
    return (@as(c_uint, a) << 24) | (@as(c_uint, b) << 16) | (@as(c_uint, c) << 8) | @as(c_uint, d);
}

// Glyph info from shaping
pub const hb_glyph_info_t = extern struct {
    codepoint: hb_codepoint_t, // Input: Unicode; Output: glyph ID
    mask: hb_mask_t,
    cluster: u32, // Byte index in original text
    var1: u32, // Reserved
    var2: u32, // Reserved
};

// Glyph position from shaping
pub const hb_glyph_position_t = extern struct {
    x_advance: hb_position_t, // Horizontal advance (26.6 fixed)
    y_advance: hb_position_t, // Vertical advance (26.6 fixed)
    x_offset: hb_position_t, // Horizontal offset (26.6 fixed)
    y_offset: hb_position_t, // Vertical offset (26.6 fixed)
    var_: u32, // Reserved
};

pub const hb_buffer_content_type_t = enum(c_int) {
    HB_BUFFER_CONTENT_TYPE_INVALID = 0,
    HB_BUFFER_CONTENT_TYPE_UNICODE = 1,
    HB_BUFFER_CONTENT_TYPE_GLYPHS = 2,
};

pub const hb_buffer_cluster_level_t = enum(c_int) {
    HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES = 0,
    HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS = 1,
    HB_BUFFER_CLUSTER_LEVEL_CHARACTERS = 2,
};

/// Alias for default cluster level
pub const HB_BUFFER_CLUSTER_LEVEL_DEFAULT = hb_buffer_cluster_level_t.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES;

// ============================================================================
// HarfBuzz Functions
// ============================================================================

// Buffer management
pub extern "c" fn hb_buffer_create() ?*hb_buffer_t;
pub extern "c" fn hb_buffer_destroy(buffer: *hb_buffer_t) void;
pub extern "c" fn hb_buffer_reset(buffer: *hb_buffer_t) void;
pub extern "c" fn hb_buffer_clear_contents(buffer: *hb_buffer_t) void;

// Buffer properties
pub extern "c" fn hb_buffer_set_direction(buffer: *hb_buffer_t, direction: hb_direction_t) void;
pub extern "c" fn hb_buffer_set_script(buffer: *hb_buffer_t, script: hb_script_t) void;
pub extern "c" fn hb_buffer_set_language(buffer: *hb_buffer_t, language: ?*anyopaque) void;
pub extern "c" fn hb_buffer_set_cluster_level(buffer: *hb_buffer_t, cluster_level: hb_buffer_cluster_level_t) void;
pub extern "c" fn hb_buffer_guess_segment_properties(buffer: *hb_buffer_t) void;

// Adding text
pub extern "c" fn hb_buffer_add_utf8(
    buffer: *hb_buffer_t,
    text: [*]const u8,
    text_length: c_int, // -1 for null-terminated
    item_offset: c_uint, // Usually 0
    item_length: c_int, // -1 for remainder
) void;

pub extern "c" fn hb_buffer_add_utf32(
    buffer: *hb_buffer_t,
    text: [*]const u32,
    text_length: c_int,
    item_offset: c_uint,
    item_length: c_int,
) void;

// Getting results
pub extern "c" fn hb_buffer_get_length(buffer: *hb_buffer_t) c_uint;

pub extern "c" fn hb_buffer_get_glyph_infos(
    buffer: *hb_buffer_t,
    length: *c_uint,
) [*]hb_glyph_info_t;

pub extern "c" fn hb_buffer_get_glyph_positions(
    buffer: *hb_buffer_t,
    length: *c_uint,
) [*]hb_glyph_position_t;

// Shaping
pub extern "c" fn hb_shape(
    font: *hb_font_t,
    buffer: *hb_buffer_t,
    features: ?[*]const hb_feature_t,
    num_features: c_uint,
) void;

// Font creation
pub extern "c" fn hb_font_create(face: *hb_face_t) ?*hb_font_t;
pub extern "c" fn hb_font_destroy(font: *hb_font_t) void;
pub extern "c" fn hb_font_set_scale(font: *hb_font_t, x_scale: c_int, y_scale: c_int) void;
pub extern "c" fn hb_font_set_ppem(font: *hb_font_t, x_ppem: c_uint, y_ppem: c_uint) void;

// Face creation
pub extern "c" fn hb_face_create_for_tables(
    reference_table_func: ?*anyopaque,
    user_data: ?*anyopaque,
    destroy: ?*anyopaque,
) ?*hb_face_t;
pub extern "c" fn hb_face_destroy(face: *hb_face_t) void;
pub extern "c" fn hb_face_set_upem(face: *hb_face_t, upem: c_uint) void;

// HarfBuzz <-> FreeType bridge
pub extern "c" fn hb_ft_font_create_referenced(ft_face: FT_Face) ?*hb_font_t;
pub extern "c" fn hb_ft_font_set_funcs(font: *hb_font_t) void;
pub extern "c" fn hb_ft_font_changed(font: *hb_font_t) void;

// ============================================================================
// Fontconfig Types
// ============================================================================

pub const FcConfig = opaque {};
pub const FcPattern = opaque {};
pub const FcFontSet = opaque {};
pub const FcObjectSet = opaque {};
pub const FcCharSet = opaque {};
pub const FcLangSet = opaque {};

pub const FcChar8 = u8;
pub const FcChar32 = u32;
pub const FcBool = c_int;

pub const FC_FAMILY = "family";
pub const FC_STYLE = "style";
pub const FC_SLANT = "slant";
pub const FC_WEIGHT = "weight";
pub const FC_SIZE = "size";
pub const FC_PIXEL_SIZE = "pixelsize";
pub const FC_SPACING = "spacing";
pub const FC_FILE = "file";
pub const FC_INDEX = "index";
pub const FC_SCALABLE = "scalable";
pub const FC_FONTFORMAT = "fontformat";

// Fontconfig weight values
pub const FC_WEIGHT_THIN: c_int = 0;
pub const FC_WEIGHT_EXTRALIGHT: c_int = 40;
pub const FC_WEIGHT_LIGHT: c_int = 50;
pub const FC_WEIGHT_REGULAR: c_int = 80;
pub const FC_WEIGHT_MEDIUM: c_int = 100;
pub const FC_WEIGHT_SEMIBOLD: c_int = 180;
pub const FC_WEIGHT_BOLD: c_int = 200;
pub const FC_WEIGHT_EXTRABOLD: c_int = 205;
pub const FC_WEIGHT_BLACK: c_int = 210;

// Fontconfig slant values
pub const FC_SLANT_ROMAN: c_int = 0;
pub const FC_SLANT_ITALIC: c_int = 100;
pub const FC_SLANT_OBLIQUE: c_int = 110;

// Fontconfig spacing values
pub const FC_PROPORTIONAL: c_int = 0;
pub const FC_DUAL: c_int = 90;
pub const FC_MONO: c_int = 100;
pub const FC_CHARCELL: c_int = 110;

pub const FcResult = enum(c_int) {
    FcResultMatch = 0,
    FcResultNoMatch = 1,
    FcResultTypeMismatch = 2,
    FcResultNoId = 3,
    FcResultOutOfMemory = 4,
};

pub const FcMatchKind = enum(c_int) {
    FcMatchPattern = 0,
    FcMatchFont = 1,
    FcMatchScan = 2,
};

// ============================================================================
// Fontconfig Functions
// ============================================================================

pub extern "c" fn FcInitLoadConfigAndFonts() ?*FcConfig;
pub extern "c" fn FcConfigDestroy(config: *FcConfig) void;
pub extern "c" fn FcConfigGetCurrent() ?*FcConfig;

pub extern "c" fn FcPatternCreate() ?*FcPattern;
pub extern "c" fn FcPatternDestroy(p: *FcPattern) void;
pub extern "c" fn FcPatternDuplicate(p: *FcPattern) ?*FcPattern;

pub extern "c" fn FcPatternAddString(
    p: *FcPattern,
    object: [*:0]const u8,
    s: [*:0]const u8,
) FcBool;

pub extern "c" fn FcPatternAddInteger(
    p: *FcPattern,
    object: [*:0]const u8,
    i: c_int,
) FcBool;

pub extern "c" fn FcPatternAddDouble(
    p: *FcPattern,
    object: [*:0]const u8,
    d: f64,
) FcBool;

pub extern "c" fn FcPatternAddBool(
    p: *FcPattern,
    object: [*:0]const u8,
    b: FcBool,
) FcBool;

pub extern "c" fn FcPatternGetString(
    p: *FcPattern,
    object: [*:0]const u8,
    n: c_int,
    s: *?[*:0]const FcChar8,
) FcResult;

pub extern "c" fn FcPatternGetInteger(
    p: *FcPattern,
    object: [*:0]const u8,
    n: c_int,
    i: *c_int,
) FcResult;

pub extern "c" fn FcPatternGetDouble(
    p: *FcPattern,
    object: [*:0]const u8,
    n: c_int,
    d: *f64,
) FcResult;

pub extern "c" fn FcConfigSubstitute(
    config: ?*FcConfig,
    p: *FcPattern,
    kind: FcMatchKind,
) FcBool;

pub extern "c" fn FcDefaultSubstitute(pattern: *FcPattern) void;

pub extern "c" fn FcFontMatch(
    config: ?*FcConfig,
    p: *FcPattern,
    result: *FcResult,
) ?*FcPattern;

pub extern "c" fn FcFontList(
    config: ?*FcConfig,
    p: *FcPattern,
    os: *FcObjectSet,
) ?*FcFontSet;

pub extern "c" fn FcFontSetDestroy(fs: *FcFontSet) void;

pub extern "c" fn FcObjectSetCreate() ?*FcObjectSet;
pub extern "c" fn FcObjectSetDestroy(os: *FcObjectSet) void;
pub extern "c" fn FcObjectSetAdd(os: *FcObjectSet, object: [*:0]const u8) FcBool;

pub extern "c" fn FcNameParse(name: [*:0]const u8) ?*FcPattern;

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert FreeType 26.6 fixed-point to float
pub inline fn f26dot6ToFloat(value: FT_Pos) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}

/// Convert float to FreeType 26.6 fixed-point
pub inline fn floatToF26dot6(value: f32) FT_F26Dot6 {
    return @intFromFloat(value * 64.0);
}

/// Convert FreeType 16.16 fixed-point to float
pub inline fn fixedToFloat(value: FT_Fixed) f32 {
    return @as(f32, @floatFromInt(value)) / 65536.0;
}

/// Convert float to FreeType 16.16 fixed-point
pub inline fn floatToFixed(value: f32) FT_Fixed {
    return @intFromFloat(value * 65536.0);
}

/// Check if a FreeType face is monospace
pub inline fn isMonospace(face: FT_Face) bool {
    return (face.face_flags & FT_FACE_FLAG_FIXED_WIDTH) != 0;
}

/// Check if a FreeType face has kerning
pub inline fn hasKerning(face: FT_Face) bool {
    return (face.face_flags & FT_FACE_FLAG_KERNING) != 0;
}

/// Check if a FreeType face is scalable
pub inline fn isScalable(face: FT_Face) bool {
    return (face.face_flags & FT_FACE_FLAG_SCALABLE) != 0;
}

/// Check if a FreeType face has color glyphs
pub inline fn hasColor(face: FT_Face) bool {
    return (face.face_flags & FT_FACE_FLAG_COLOR) != 0;
}

/// Get the error string for a FreeType error (basic)
pub fn ftErrorString(err: FT_Error) []const u8 {
    return switch (err) {
        0 => "no error",
        0x01 => "cannot open resource",
        0x02 => "unknown file format",
        0x03 => "broken file",
        0x04 => "invalid FreeType version",
        0x05 => "module version too low",
        0x06 => "invalid argument",
        0x07 => "unimplemented feature",
        0x08 => "broken table",
        0x09 => "broken offset within table",
        0x0A => "array allocation size too large",
        0x0B => "missing module",
        0x0C => "missing property",
        0x10 => "invalid glyph index",
        0x11 => "invalid character code",
        0x12 => "unsupported glyph image format",
        0x13 => "cannot render glyph",
        0x14 => "invalid outline",
        0x15 => "invalid composite glyph",
        0x16 => "too many hints",
        0x17 => "invalid pixel size",
        0x20 => "invalid handle",
        0x21 => "invalid library handle",
        0x22 => "invalid driver handle",
        0x23 => "invalid face handle",
        0x24 => "invalid size handle",
        0x25 => "invalid glyph slot handle",
        0x26 => "invalid charmap handle",
        0x27 => "invalid cache manager handle",
        0x28 => "invalid stream handle",
        0x51 => "too many modules",
        0x52 => "too many extensions",
        0x53 => "out of memory",
        0x54 => "unlisted object",
        else => "unknown error",
    };
}
