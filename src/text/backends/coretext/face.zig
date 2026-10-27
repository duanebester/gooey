//! CoreText font face implementation
//!
//! Implements the FontFace interface using Apple's CoreText framework.

const std = @import("std");
const ct = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");
const font_match = @import("../../font_match.zig");

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
const FontVariant = types.FontVariant;
const FontFace = font_face_mod.FontFace;

/// CoreText-backed font face
pub const CoreTextFace = struct {
    /// CoreText font reference
    ct_font: ct.CTFontRef,
    /// Cached metrics
    metrics: Metrics,

    const Self = @This();

    /// Load one variant of a font by name (e.g., "SF Mono", "SF Pro", "Helvetica Neue").
    ///
    /// Selection: the name resolves to a family, the family's faces are
    /// listed, and `font_match.select` picks one by the CSS font matching rule,
    /// the same rule Fontconfig selection and the browser use. Fallback policy:
    /// nothing is synthesized. A family without the requested weight or slant
    /// renders with the face CSS matching picks, and init logs a warning when
    /// its weight class or slant differs. See `createVariantFont`.
    pub fn init(name: []const u8, size: f32, variant: FontVariant) !Self {
        std.debug.assert(size > 0);
        std.debug.assert(name.len > 0);

        const cf_name = ct.createCFStringRuntime(name) orelse return error.InvalidFontName;
        defer ct.release(cf_name);

        const base = ct.CTFontCreateWithName(cf_name, @floatCast(size), null) orelse
            return error.FontNotFound;
        const font = selectVariant(base, size, variant);

        return Self{
            .ct_font = font,
            .metrics = computeMetrics(font, size),
        };
    }

    /// Load one variant of a system font, with the same policy as `init`.
    pub fn initSystem(style: SystemFont, size: f32, variant: FontVariant) !Self {
        std.debug.assert(size > 0);

        const base = switch (style) {
            .monospace => blk: {
                // Use system API for monospace - SF Mono needs this to work correctly
                const f = ct.CTFontCreateUIFontForLanguage(
                    ct.kCTFontUIFontUserFixedPitch,
                    @floatCast(size),
                    null,
                ) orelse return error.FontNotFound;
                break :blk f;
            },
            else => blk: {
                const name = switch (style) {
                    .monospace => unreachable,
                    .sans_serif => "SF Pro",
                    .serif => "New York",
                    .system => ".AppleSystemUIFont",
                };
                const cf_name = ct.createCFStringRuntime(name) orelse return error.InvalidFontName;
                defer ct.release(cf_name);
                break :blk ct.CTFontCreateWithName(cf_name, @floatCast(size), null) orelse
                    return error.FontNotFound;
            },
        };
        const font = selectVariant(base, size, variant);

        return Self{
            .ct_font = font,
            .metrics = computeMetrics(font, size),
        };
    }

    pub fn deinit(self: *Self) void {
        ct.release(self.ct_font);
        self.* = undefined;
    }

    /// Take ownership of `base` and return the font for `variant`: `base`
    /// itself for `.regular` or when no other face can be created, else a new
    /// font (and `base` is released).
    fn selectVariant(base: ct.CTFontRef, size: f32, variant: FontVariant) ct.CTFontRef {
        if (variant == .regular) return base;

        const font = createVariantFont(base, size, variant) orelse base;
        if (font != base) ct.release(base);

        const traits = ct.CTFontCopyTraits(font);
        defer ct.release(traits);
        warnInexactFace(variant, traitsCandidate(traits));
        return font;
    }

    /// Create `variant` within `base`'s family, or null when CoreText cannot.
    ///
    /// Listed families pick a face by CSS matching. Hidden system families
    /// (names starting with '.', such as `.AppleSystemUIFont` and the system
    /// monospace) do not list through a family descriptor, so they request the
    /// variant's weight and slant as traits on `base`'s own descriptor; SF has
    /// real faces at every weight, so medium and semibold get their own faces
    /// rather than the bold symbolic trait's on/off choice.
    fn createVariantFont(base: ct.CTFontRef, size: f32, variant: FontVariant) ?ct.CTFontRef {
        std.debug.assert(variant != .regular);
        std.debug.assert(size > 0);

        const family = ct.CTFontCopyFamilyName(base) orelse return null;
        defer ct.release(family);

        if (isHiddenFamily(family)) {
            return createFromBaseTraits(base, size, variant);
        }

        // Keep the resolved face's width, so a condensed family stays condensed.
        const base_traits = ct.CTFontCopyTraits(base);
        defer ct.release(base_traits);
        const stretch = traitsCandidate(base_traits).stretch;
        return createFromFamilyList(family, size, variant, stretch);
    }

    /// List `family`'s faces and create the one CSS matching picks.
    fn createFromFamilyList(
        family: ct.CFStringRef,
        size: f32,
        variant: FontVariant,
        stretch: u16,
    ) ?ct.CTFontRef {
        const attrs = createDictionary() orelse return null;
        defer ct.release(attrs);
        ct.CFDictionarySetValue(attrs, @ptrCast(ct.kCTFontFamilyNameAttribute), @ptrCast(family));

        const descriptor = ct.CTFontDescriptorCreateWithAttributes(attrs) orelse return null;
        defer ct.release(descriptor);

        const matches = ct.CTFontDescriptorCreateMatchingFontDescriptors(descriptor, null) orelse
            return null;
        defer ct.release(matches);

        const listed_count: u32 = @intCast(ct.CFArrayGetCount(matches));
        const considered_count = @min(listed_count, font_match.candidate_count_max);
        if (listed_count > considered_count) {
            std.log.warn("font family lists {d} faces; matching considers the first {d}", .{
                listed_count,
                considered_count,
            });
        }

        var candidates: [font_match.candidate_count_max]font_match.Candidate = undefined;
        var listed_index: [font_match.candidate_count_max]u32 = undefined;
        var candidate_count: u32 = 0;
        var index: u32 = 0;
        while (index < considered_count) : (index += 1) {
            const face = listedDescriptor(matches, index);
            const traits = ct.CTFontDescriptorCopyAttribute(face, ct.kCTFontTraitsAttribute) orelse
                continue;
            defer ct.release(traits);
            candidates[candidate_count] = traitsCandidate(traits);
            listed_index[candidate_count] = index;
            candidate_count += 1;
        }
        std.debug.assert(candidate_count <= considered_count);

        const chosen = font_match.select(candidates[0..candidate_count], variant, stretch) orelse
            return null;
        std.debug.assert(chosen < candidate_count);
        const face = listedDescriptor(matches, listed_index[chosen]);
        return ct.CTFontCreateWithFontDescriptor(face, @floatCast(size), null);
    }

    fn listedDescriptor(matches: ct.CFArrayRef, index: u32) ct.CTFontDescriptorRef {
        std.debug.assert(index < ct.CFArrayGetCount(matches));
        return @constCast(ct.CFArrayGetValueAtIndex(matches, index));
    }

    /// Copy `base`'s descriptor with the variant's weight and slant as traits.
    fn createFromBaseTraits(base: ct.CTFontRef, size: f32, variant: FontVariant) ?ct.CTFontRef {
        const weight_value: f64 = coreTextWeight(variant.weight().cssWeight());
        const weight = ct.CFNumberCreate(null, ct.kCFNumberFloat64Type, &weight_value) orelse
            return null;
        defer ct.release(weight);

        const symbolic_value: i32 = if (variant.isItalic()) @intCast(ct.kCTFontTraitItalic) else 0;
        const symbolic = ct.CFNumberCreate(null, ct.kCFNumberSInt32Type, &symbolic_value) orelse
            return null;
        defer ct.release(symbolic);

        const traits = createDictionary() orelse return null;
        defer ct.release(traits);
        ct.CFDictionarySetValue(traits, @ptrCast(ct.kCTFontWeightTrait), @ptrCast(weight));
        ct.CFDictionarySetValue(traits, @ptrCast(ct.kCTFontSymbolicTrait), @ptrCast(symbolic));

        const attrs = createDictionary() orelse return null;
        defer ct.release(attrs);
        ct.CFDictionarySetValue(attrs, @ptrCast(ct.kCTFontTraitsAttribute), @ptrCast(traits));

        const base_descriptor = ct.CTFontCopyFontDescriptor(base);
        defer ct.release(base_descriptor);

        const descriptor = ct.CTFontDescriptorCreateCopyWithAttributes(base_descriptor, attrs);
        defer ct.release(descriptor);

        return ct.CTFontCreateWithFontDescriptor(descriptor, @floatCast(size), null);
    }

    fn createDictionary() ?ct.CFMutableDictionaryRef {
        const key_callbacks = &ct.kCFTypeDictionaryKeyCallBacks;
        const value_callbacks = &ct.kCFTypeDictionaryValueCallBacks;
        return ct.CFDictionaryCreateMutable(null, 2, key_callbacks, value_callbacks);
    }

    fn isHiddenFamily(family: ct.CFStringRef) bool {
        if (ct.CFStringGetLength(family) == 0) return false;
        var first: [1]ct.UniChar = undefined;
        ct.CFStringGetCharacters(family, ct.CFRange.init(0, 1), &first);
        return first[0] == '.';
    }

    /// A CoreText traits dictionary as a CSS match candidate. Missing traits
    /// count as regular, upright, and normal width.
    fn traitsCandidate(traits: ct.CFDictionaryRef) font_match.Candidate {
        const weight = traitFloat(traits, ct.kCTFontWeightTrait) orelse 0.0;
        const width = traitFloat(traits, ct.kCTFontWidthTrait) orelse 0.0;

        var symbolic: i64 = 0;
        if (ct.CFDictionaryGetValue(traits, @ptrCast(ct.kCTFontSymbolicTrait))) |value| {
            if (ct.CFNumberGetValue(@constCast(value), ct.kCFNumberSInt64Type, &symbolic) == 0) {
                symbolic = 0;
            }
        }
        const symbolic_bits: ct.CTFontSymbolicTraits = @truncate(@as(u64, @bitCast(symbolic)));
        const italic = (symbolic_bits & ct.kCTFontTraitItalic) != 0;

        const candidate: font_match.Candidate = .{
            .weight = cssWeight(weight),
            .slant = if (italic) .italic else .upright,
            .stretch = cssStretch(width),
        };
        std.debug.assert(candidate.weight >= 1);
        std.debug.assert(candidate.stretch >= font_match.stretch_min);
        return candidate;
    }

    fn traitFloat(traits: ct.CFDictionaryRef, key: ct.CFStringRef) ?f64 {
        const value = ct.CFDictionaryGetValue(traits, @ptrCast(key)) orelse return null;
        var result: f64 = 0;
        if (ct.CFNumberGetValue(@constCast(value), ct.kCFNumberFloat64Type, &result) == 0) {
            return null;
        }
        return result;
    }

    /// `kCTFontWeightTrait` values of AppKit's `NSFontWeight` constants at
    /// each CSS hundred, UltraLight (100) through Black (900). Weights convert
    /// both ways by piecewise linear interpolation over this table.
    const weight_table = [_]struct { core_text: f64, css: f64 }{
        .{ .core_text = -0.8, .css = 100 },
        .{ .core_text = -0.6, .css = 200 },
        .{ .core_text = -0.4, .css = 300 },
        .{ .core_text = 0.0, .css = 400 },
        .{ .core_text = 0.23, .css = 500 },
        .{ .core_text = 0.3, .css = 600 },
        .{ .core_text = 0.4, .css = 700 },
        .{ .core_text = 0.56, .css = 800 },
        .{ .core_text = 0.62, .css = 900 },
    };

    /// CSS weight (100...900) for a `kCTFontWeightTrait` value.
    fn cssWeight(core_text: f64) u16 {
        const first = weight_table[0];
        const last = weight_table[weight_table.len - 1];
        if (core_text <= first.core_text) return @intFromFloat(first.css);
        if (core_text >= last.core_text) return @intFromFloat(last.css);
        for (weight_table[1..], 1..) |upper, index| {
            if (core_text <= upper.core_text) {
                const lower = weight_table[index - 1];
                const t = (core_text - lower.core_text) / (upper.core_text - lower.core_text);
                return @intFromFloat(@round(lower.css + t * (upper.css - lower.css)));
            }
        }
        unreachable; // The table is sorted and `core_text` is below its last entry.
    }

    /// `kCTFontWeightTrait` value (-1...1) for a CSS weight (100...900).
    fn coreTextWeight(css: u16) f64 {
        std.debug.assert(css >= 100);
        std.debug.assert(css <= 900);
        const css_float: f64 = @floatFromInt(css);
        for (weight_table[1..], 1..) |upper, index| {
            if (css_float <= upper.css) {
                const lower = weight_table[index - 1];
                const t = (css_float - lower.css) / (upper.css - lower.css);
                return lower.core_text + t * (upper.core_text - lower.core_text);
            }
        }
        unreachable; // 900 is the table's last CSS weight.
    }

    /// CSS `font-stretch` percentage for a `kCTFontWidthTrait` value (-1...1):
    /// -1 is ultra-condensed (50%), 0 normal (100%), 1 ultra-expanded (200%).
    fn cssStretch(width: f64) u16 {
        const clamped = std.math.clamp(width, -1.0, 1.0);
        const percent = if (clamped <= 0) 100 + clamped * 50 else 100 + clamped * 100;
        const result: u16 = @intFromFloat(@round(percent));
        std.debug.assert(result >= font_match.stretch_min);
        std.debug.assert(result <= font_match.stretch_max);
        return result;
    }

    /// Log when the chosen face's weight class or slant differs from the
    /// request, so a family without that face does not fall back silently.
    fn warnInexactFace(variant: FontVariant, chosen: font_match.Candidate) void {
        const weight_requested = variant.weight().cssWeight();
        if (font_match.weightClass(chosen.weight) != weight_requested) {
            std.log.warn("font has no {d} face for '{s}'; using weight {d}", .{
                weight_requested,
                @tagName(variant),
                chosen.weight,
            });
        }
        if (!font_match.slantMatches(chosen.slant, variant.isItalic())) {
            std.log.warn("font has no italic face for '{s}'; using an upright face", .{
                @tagName(variant),
            });
        }
    }

    /// Get as the generic FontFace interface
    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    /// Get glyph ID for a Unicode codepoint
    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        var utf16_buf: [2]ct.UniChar = undefined;
        var count: usize = 1;

        if (codepoint <= 0xFFFF) {
            utf16_buf[0] = @intCast(codepoint);
        } else {
            const adjusted = codepoint - 0x10000;
            utf16_buf[0] = @intCast(0xD800 + (adjusted >> 10));
            utf16_buf[1] = @intCast(0xDC00 + (adjusted & 0x3FF));
            count = 2;
        }

        var glyph: ct.CGGlyph = 0;
        const success = ct.CTFontGetGlyphsForCharacters(
            self.ct_font,
            &utf16_buf,
            @ptrCast(&glyph),
            @intCast(count),
        );

        return if (success) glyph else 0;
    }

    /// Get advance width for a glyph (fast path for text measurement)
    /// Uses CTFontGetAdvancesForGlyphs which is optimized for this use case
    pub fn glyphAdvance(self: *const Self, glyph_id: u16) f32 {
        var glyph = glyph_id;
        var advance: ct.CGSize = undefined;
        _ = ct.CTFontGetAdvancesForGlyphs(
            self.ct_font,
            .horizontal,
            @ptrCast(&glyph),
            @ptrCast(&advance),
            1,
        );
        return @floatCast(advance.width);
    }

    /// Get metrics for a specific glyph
    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        return getGlyphMetricsFromFont(self.ct_font, glyph_id);
    }

    /// Render a glyph with subpixel positioning
    /// subpixel_x and subpixel_y are in range [0.0, 1.0)
    pub fn renderGlyphSubpixel(
        self: *const Self,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        std.debug.assert(font_size > 0);
        std.debug.assert(scale > 0);
        std.debug.assert(subpixel_x >= 0 and subpixel_x < 1.0);
        std.debug.assert(subpixel_y >= 0 and subpixel_y < 1.0);

        return renderGlyphInternal(
            self.ct_font,
            glyph_id,
            font_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    /// Render a glyph from any CTFontRef (for fallback fonts)
    /// This is a static method that can render glyphs from fonts not owned by this face
    pub fn renderGlyphFromFont(
        ct_font: ct.CTFontRef,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        std.debug.assert(font_size > 0);
        std.debug.assert(scale > 0);
        std.debug.assert(subpixel_x >= 0 and subpixel_x < 1.0);
        std.debug.assert(subpixel_y >= 0 and subpixel_y < 1.0);

        return renderGlyphInternal(
            ct_font,
            glyph_id,
            font_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    fn computeMetrics(font: ct.CTFontRef, size: f32) Metrics {
        const ascender: f32 = @floatCast(ct.CTFontGetAscent(font));
        const descender: f32 = @floatCast(ct.CTFontGetDescent(font));
        const line_gap: f32 = @floatCast(ct.CTFontGetLeading(font));
        const traits = ct.CTFontGetSymbolicTraits(font);
        const is_monospace = (traits & ct.kCTFontTraitMonoSpace) != 0;

        var test_chars = [_]ct.UniChar{ 'M', '0' };
        var glyphs: [2]ct.CGGlyph = undefined;
        _ = ct.CTFontGetGlyphsForCharacters(font, &test_chars, &glyphs, 2);

        var advances: [2]ct.CGSize = undefined;
        _ = ct.CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, 2);

        const cell_width: f32 = @floatCast(@max(advances[0].width, advances[1].width));

        return .{
            .units_per_em = ct.CTFontGetUnitsPerEm(font),
            .ascender = ascender,
            .descender = descender,
            .line_gap = line_gap,
            .cap_height = @floatCast(ct.CTFontGetCapHeight(font)),
            .x_height = @floatCast(ct.CTFontGetXHeight(font)),
            .underline_position = @floatCast(ct.CTFontGetUnderlinePosition(font)),
            .underline_thickness = @floatCast(ct.CTFontGetUnderlineThickness(font)),
            .line_height = ascender + descender + line_gap,
            .point_size = size,
            .is_monospace = is_monospace,
            .cell_width = cell_width,
        };
    }
};

// =============================================================================
// Shared Internal Functions
// =============================================================================

/// Get glyph metrics from any CTFontRef
fn getGlyphMetricsFromFont(ct_font: ct.CTFontRef, glyph_id: u16) GlyphMetrics {
    var glyph = glyph_id;
    var advance: ct.CGSize = undefined;
    var bounds: ct.CGRect = undefined;

    _ = ct.CTFontGetAdvancesForGlyphs(
        ct_font,
        .horizontal,
        @ptrCast(&glyph),
        @ptrCast(&advance),
        1,
    );

    _ = ct.CTFontGetBoundingRectsForGlyphs(
        ct_font,
        .horizontal,
        @ptrCast(&glyph),
        @ptrCast(&bounds),
        1,
    );

    return .{
        .glyph_id = glyph_id,
        .advance_x = @floatCast(advance.width),
        .advance_y = @floatCast(advance.height),
        .bearing_x = @floatCast(bounds.origin.x),
        .bearing_y = @floatCast(bounds.origin.y + bounds.size.height),
        .width = @floatCast(bounds.size.width),
        .height = @floatCast(bounds.size.height),
    };
}

/// Internal glyph rendering implementation shared by both public methods
/// Renders a glyph from any CTFontRef with subpixel positioning
fn renderGlyphInternal(
    ct_font: ct.CTFontRef,
    glyph_id: u16,
    font_size: f32,
    scale: f32,
    subpixel_x: f32,
    subpixel_y: f32,
    buffer: []u8,
    buffer_size: u32,
) !RasterizedGlyph {
    // Assertions for input validation
    std.debug.assert(scale > 0);
    std.debug.assert(font_size > 0);
    std.debug.assert(buffer.len >= buffer_size);

    // Create scaled font first - we need metrics at the target size
    const scaled_font = ct.CTFontCreateCopyWithAttributes(
        ct_font,
        font_size * scale,
        null,
        null,
    ) orelse return error.FontError;
    defer ct.release(scaled_font);

    // Get metrics from the scaled font so bounds are correct for the target size
    const glyph_metrics = getGlyphMetricsFromFont(scaled_font, glyph_id);
    const padding: u32 = 2;
    const padding_f: f32 = @floatFromInt(padding);

    // Handle empty glyphs (spaces, etc.)
    if (glyph_metrics.width < 1 or glyph_metrics.height < 1) {
        // Return advance scaled back to logical units (font_size, not font_size * scale)
        return RasterizedGlyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .advance_x = glyph_metrics.advance_x / scale,
            .is_color = false,
        };
    }

    // Raster bounds in physical pixels
    // Metrics are already at scaled size, so no additional scaling needed
    const raster_left = @floor(glyph_metrics.bearing_x);
    const raster_top = @floor(glyph_metrics.bearing_y);
    const raster_right = @ceil(glyph_metrics.bearing_x + glyph_metrics.width);
    const raster_bottom = @ceil(glyph_metrics.bearing_y - glyph_metrics.height);

    // Bitmap size with padding for antialiasing
    var width: u32 = @intFromFloat(raster_right - raster_left + padding_f * 2);
    var height: u32 = @intFromFloat(raster_top - raster_bottom + padding_f * 2);

    // Add extra pixel when subpixel variant is non-zero
    if (subpixel_x > 0) width += 1;
    if (subpixel_y > 0) height += 1;

    const clamped_w = @min(width, buffer_size);
    const clamped_h = @min(height, buffer_size);

    std.debug.assert(clamped_w > 0);
    std.debug.assert(clamped_h > 0);

    // Create CoreGraphics context
    const color_space = ct.CGColorSpaceCreateDeviceGray() orelse return error.GraphicsError;
    defer ct.CGColorSpaceRelease(color_space);

    const context = ct.CGBitmapContextCreate(
        buffer.ptr,
        clamped_w,
        clamped_h,
        8,
        clamped_w,
        color_space,
        ct.kCGImageAlphaNone,
    ) orelse return error.GraphicsError;
    defer ct.CGContextRelease(context);

    // Configure rendering for quality
    ct.CGContextSetAllowsAntialiasing(context, true);
    ct.CGContextSetShouldAntialias(context, true);
    ct.CGContextSetAllowsFontSmoothing(context, true);
    ct.CGContextSetShouldSmoothFonts(context, true);
    ct.CGContextSetGrayFillColor(context, 1.0, 1.0);
    ct.CGContextSetAllowsFontSubpixelPositioning(context, true);
    ct.CGContextSetShouldSubpixelPositionFonts(context, true);
    ct.CGContextSetAllowsFontSubpixelQuantization(context, false);
    ct.CGContextSetShouldSubpixelQuantizeFonts(context, false);

    // Move origin to account for glyph bounds (like GPUI does)
    // The context origin is bottom-left, Y increases upward
    ct.CGContextTranslateCTM(
        context,
        -raster_left + padding_f + subpixel_x,
        -raster_bottom + padding_f + subpixel_y,
    );
    ct.CGContextSetTextMatrix(context, ct.CGAffineTransform.identity);

    // Draw glyph at origin - the context translation positions it correctly
    var glyph = glyph_id;
    const position = ct.CGPoint{ .x = 0, .y = 0 };
    ct.CTFontDrawGlyphs(scaled_font, @ptrCast(&glyph), @ptrCast(&position), 1, context);

    // Return offsets directly from font metrics - no bitmap scanning needed
    // offset_x: where to place bitmap left edge relative to pen (physical pixels)
    // offset_y: where to place bitmap top edge relative to baseline (physical pixels, positive = above)
    // advance_x is returned in logical units (at font_size), not physical pixels
    return RasterizedGlyph{
        .width = clamped_w,
        .height = clamped_h,
        .offset_x = @intFromFloat(raster_left - padding_f),
        .offset_y = @intFromFloat(raster_top + padding_f),
        .advance_x = glyph_metrics.advance_x / scale,
        .is_color = false,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "load system font" {
    var face = try CoreTextFace.initSystem(.monospace, 14.0, .regular);
    defer face.deinit();

    try std.testing.expect(face.metrics.ascender > 0);
    try std.testing.expect(face.metrics.line_height > 0);
}
