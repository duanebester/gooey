//! CoreText bindings for font rendering on macOS
//!
//! Provides low-level access to Apple's text rendering system.
//! CoreText handles font loading, glyph rendering, and text shaping.

const std = @import("std");

// ============================================================================
// CoreFoundation Types
// ============================================================================

pub const CFIndex = isize;
pub const CFTypeID = c_ulong;
pub const CFTypeRef = *anyopaque;
pub const CFAllocatorRef = ?*anyopaque;
pub const CFStringRef = *anyopaque;
pub const CFDataRef = *anyopaque;
pub const CFDictionaryRef = *anyopaque;
pub const CFMutableDictionaryRef = *anyopaque;
pub const CFArrayRef = *anyopaque;
pub const CFURLRef = *anyopaque;
pub const CFNumberRef = *anyopaque;
pub const CFBooleanRef = *anyopaque;
pub const CFAttributedStringRef = *anyopaque;

pub const UniChar = u16;

pub const CGFloat = f64;
pub const CGGlyph = u16;

pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,

    pub const zero = CGPoint{ .x = 0, .y = 0 };
};

pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,

    pub const zero = CGSize{ .width = 0, .height = 0 };
};

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,

    pub const zero = CGRect{ .origin = CGPoint.zero, .size = CGSize.zero };
};

pub const CGAffineTransform = extern struct {
    a: CGFloat,
    b: CGFloat,
    c: CGFloat,
    d: CGFloat,
    tx: CGFloat,
    ty: CGFloat,

    pub const identity = CGAffineTransform{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };
};

// ============================================================================
// CoreGraphics Context
// ============================================================================

pub const CGContextRef = *anyopaque;
pub const CGColorSpaceRef = *anyopaque;
pub const CGImageRef = *anyopaque;
pub const CGBitmapInfo = u32;

// CGBitmapInfo values
pub const kCGBitmapAlphaInfoMask: CGBitmapInfo = 0x1F;
pub const kCGBitmapByteOrderMask: CGBitmapInfo = 0x7000;
pub const kCGBitmapByteOrder32Little: CGBitmapInfo = 2 << 12;
pub const kCGBitmapByteOrder32Big: CGBitmapInfo = 4 << 12;

// CGImageAlphaInfo values
pub const kCGImageAlphaNone: CGBitmapInfo = 0;
pub const kCGImageAlphaPremultipliedLast: CGBitmapInfo = 1;
pub const kCGImageAlphaPremultipliedFirst: CGBitmapInfo = 2;
pub const kCGImageAlphaLast: CGBitmapInfo = 3;
pub const kCGImageAlphaFirst: CGBitmapInfo = 4;
pub const kCGImageAlphaNoneSkipLast: CGBitmapInfo = 5;
pub const kCGImageAlphaNoneSkipFirst: CGBitmapInfo = 6;
pub const kCGImageAlphaOnly: CGBitmapInfo = 7;

// ============================================================================
// CoreText Types
// ============================================================================

pub const CTFontRef = *anyopaque;
pub const CTFontDescriptorRef = *anyopaque;
pub const CTLineRef = *anyopaque;
pub const CTRunRef = *anyopaque;

// CTFontSymbolicTraits
pub const CTFontSymbolicTraits = u32;
pub const kCTFontTraitItalic: CTFontSymbolicTraits = 1 << 0;
pub const kCTFontTraitBold: CTFontSymbolicTraits = 1 << 1;
pub const kCTFontTraitMonoSpace: CTFontSymbolicTraits = 1 << 10;

// ============================================================================
// CoreFoundation Functions
// ============================================================================

pub extern "c" fn CFRelease(cf: CFTypeRef) void;
pub extern "c" fn CFRetain(cf: CFTypeRef) CFTypeRef;

pub extern "c" fn CFStringCreateWithCString(
    allocator: CFAllocatorRef,
    cStr: [*:0]const u8,
    encoding: u32,
) ?CFStringRef;

pub extern "c" fn CFStringGetLength(theString: CFStringRef) CFIndex;

pub extern "c" fn CFStringGetCharacters(
    theString: CFStringRef,
    range: CFRange,
    buffer: [*]UniChar,
) void;

pub const kCFStringEncodingUTF8: u32 = 0x08000100;

pub const CFRange = extern struct {
    location: CFIndex,
    length: CFIndex,

    pub fn init(loc: CFIndex, len: CFIndex) CFRange {
        return .{ .location = loc, .length = len };
    }
};

// Dictionary functions
pub extern "c" fn CFDictionaryCreateMutable(
    allocator: CFAllocatorRef,
    capacity: CFIndex,
    keyCallBacks: ?*const anyopaque,
    valueCallBacks: ?*const anyopaque,
) ?CFMutableDictionaryRef;

pub extern "c" fn CFDictionarySetValue(
    theDict: CFMutableDictionaryRef,
    key: *const anyopaque,
    value: *const anyopaque,
) void;

// Array functions
pub extern "c" fn CFArrayGetCount(theArray: CFArrayRef) CFIndex;
pub extern "c" fn CFArrayGetValueAtIndex(theArray: CFArrayRef, idx: CFIndex) *const anyopaque;

// Dictionary callbacks
pub extern "c" var kCFTypeDictionaryKeyCallBacks: anyopaque;
pub extern "c" var kCFTypeDictionaryValueCallBacks: anyopaque;

// ============================================================================
// CoreGraphics Functions
// ============================================================================

pub extern "c" fn CGColorSpaceCreateDeviceGray() ?CGColorSpaceRef;
pub extern "c" fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;
pub extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;

pub extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bitsPerComponent: usize,
    bytesPerRow: usize,
    space: ?CGColorSpaceRef,
    bitmapInfo: CGBitmapInfo,
) ?CGContextRef;

pub extern "c" fn CGContextRelease(c: CGContextRef) void;
pub extern "c" fn CGContextSetGrayFillColor(c: CGContextRef, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextSetRGBFillColor(c: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern "c" fn CGContextFillRect(c: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextSetTextMatrix(c: CGContextRef, t: CGAffineTransform) void;
pub extern "c" fn CGContextSetAllowsAntialiasing(c: CGContextRef, allowsAntialiasing: bool) void;
pub extern "c" fn CGContextSetShouldAntialias(c: CGContextRef, shouldAntialias: bool) void;
pub extern "c" fn CGContextSetAllowsFontSmoothing(c: CGContextRef, allowsFontSmoothing: bool) void;
pub extern "c" fn CGContextSetShouldSmoothFonts(c: CGContextRef, shouldSmoothFonts: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelPositioning(c: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelPositionFonts(c: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelQuantization(c: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(c: CGContextRef, should: bool) void;

// ============================================================================
// CoreText Functions
// ============================================================================

pub extern "c" fn CTFontCreateWithName(
    name: CFStringRef,
    size: CGFloat,
    matrix: ?*const CGAffineTransform,
) ?CTFontRef;

pub extern "c" fn CTFontCreateWithFontDescriptor(
    descriptor: CTFontDescriptorRef,
    size: CGFloat,
    matrix: ?*const CGAffineTransform,
) ?CTFontRef;

// Font metrics
pub extern "c" fn CTFontGetAscent(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetDescent(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetLeading(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetUnitsPerEm(font: CTFontRef) c_uint;
pub extern "c" fn CTFontGetCapHeight(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetXHeight(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetSize(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetUnderlinePosition(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetUnderlineThickness(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetBoundingBox(font: CTFontRef) CGRect;
pub extern "c" fn CTFontGetSymbolicTraits(font: CTFontRef) CTFontSymbolicTraits;

// Glyph operations
pub extern "c" fn CTFontGetGlyphsForCharacters(
    font: CTFontRef,
    characters: [*]const UniChar,
    glyphs: [*]CGGlyph,
    count: CFIndex,
) bool;

pub extern "c" fn CTFontGetAdvancesForGlyphs(
    font: CTFontRef,
    orientation: CTFontOrientation,
    glyphs: [*]const CGGlyph,
    advances: ?[*]CGSize,
    count: CFIndex,
) f64;

pub extern "c" fn CTFontGetBoundingRectsForGlyphs(
    font: CTFontRef,
    orientation: CTFontOrientation,
    glyphs: [*]const CGGlyph,
    boundingRects: ?[*]CGRect,
    count: CFIndex,
) CGRect;

pub const CTFontOrientation = enum(u32) {
    default = 0,
    horizontal = 1,
    vertical = 2,
};

// Font drawing
pub extern "c" fn CTFontDrawGlyphs(
    font: CTFontRef,
    glyphs: [*]const CGGlyph,
    positions: [*]const CGPoint,
    count: usize,
    context: CGContextRef,
) void;

// Line/Run operations (text shaping)
pub extern "c" fn CTLineCreateWithAttributedString(attrString: CFAttributedStringRef) ?CTLineRef;
pub extern "c" fn CTLineGetGlyphRuns(line: CTLineRef) CFArrayRef;
pub extern "c" fn CTLineGetGlyphCount(line: CTLineRef) CFIndex;
pub extern "c" fn CTLineGetTypographicBounds(
    line: CTLineRef,
    ascent: ?*CGFloat,
    descent: ?*CGFloat,
    leading: ?*CGFloat,
) f64;

pub extern "c" fn CTRunGetGlyphCount(run: CTRunRef) CFIndex;
pub extern "c" fn CTRunGetGlyphs(run: CTRunRef, range: CFRange, buffer: [*]CGGlyph) void;
pub extern "c" fn CTRunGetPositions(run: CTRunRef, range: CFRange, buffer: [*]CGPoint) void;
pub extern "c" fn CTRunGetAdvances(run: CTRunRef, range: CFRange, buffer: [*]CGSize) void;
pub extern "c" fn CTRunGetStringIndices(run: CTRunRef, range: CFRange, buffer: [*]CFIndex) void;

// Attributed string keys
pub extern "c" var kCTFontAttributeName: CFStringRef;
pub extern "c" var kCTForegroundColorAttributeName: CFStringRef;

// CFAttributedString
pub extern "c" fn CFAttributedStringCreate(
    allocator: CFAllocatorRef,
    str: CFStringRef,
    attributes: ?CFDictionaryRef,
) ?CFAttributedStringRef;

pub extern "c" fn CTFontCreateCopyWithAttributes(
    font: CTFontRef,
    size: CGFloat,
    matrix: ?*const CGAffineTransform,
    attributes: ?CTFontDescriptorRef,
) ?CTFontRef;

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a CFString from a Zig string slice (must be null-terminated or short)
pub fn createCFString(comptime str: []const u8) ?CFStringRef {
    const terminated = str ++ [_]u8{0};
    return CFStringCreateWithCString(null, terminated[0 .. terminated.len - 1 :0], kCFStringEncodingUTF8);
}

/// Create a CFString from a runtime string (copies to buffer)
pub fn createCFStringRuntime(str: []const u8) ?CFStringRef {
    if (str.len >= 4096) return null;
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return CFStringCreateWithCString(null, buf[0..str.len :0], kCFStringEncodingUTF8);
}

/// Release a CoreFoundation object
pub fn release(ref: anytype) void {
    CFRelease(@ptrCast(ref));
}
