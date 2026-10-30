//! DirectWrite backend tests against the system's real DirectWrite.
//!
//! They load fonts that ship with every supported Windows release (Segoe UI,
//! Consolas), so they run on any Windows host and nowhere else.

const std = @import("std");
const testing = std.testing;
const limits = @import("../../../core/limits.zig");
const DirectWriteFace = @import("face.zig").DirectWriteFace;
const shaper_mod = @import("shaper.zig");
const DirectWriteShaper = shaper_mod.DirectWriteShaper;

const buffer_bytes = limits.MAX_GLYPH_SIZE * limits.MAX_GLYPH_SIZE;

/// Render at the face's 16 px with no vertical shift.
fn render(
    face: *const DirectWriteFace,
    glyph_id: u16,
    scale: f32,
    subpixel_x: f32,
    buffer: []u8,
) !@import("../../types.zig").RasterizedGlyph {
    const size: f32 = 16.0;
    return face.renderGlyphSubpixel(glyph_id, size, scale, subpixel_x, 0, buffer, buffer_bytes);
}

fn createShaper() !*DirectWriteShaper {
    const shaper = try testing.allocator.create(DirectWriteShaper);
    shaper.* = DirectWriteShaper.init(testing.allocator);
    return shaper;
}

fn destroyShaper(shaper: *DirectWriteShaper) void {
    shaper.deinit();
    testing.allocator.destroy(shaper);
}

test "system faces load with plausible metrics" {
    // Goal: font discovery and metric scaling. Methodology: the sans-serif
    // and monospace system faces at 16 px, checked against properties every
    // text face has, and monospace detection on both.
    var sans = try DirectWriteFace.initSystem(.sans_serif, 16.0, .regular);
    defer sans.deinit();
    try testing.expect(sans.metrics.ascender > 8);
    try testing.expect(sans.metrics.ascender < 32);
    try testing.expect(sans.metrics.descender > 0);
    try testing.expect(sans.metrics.cap_height > sans.metrics.x_height);
    try testing.expect(sans.metrics.underline_position < 0);
    try testing.expect(!sans.metrics.is_monospace);
    try testing.expectEqual(@as(f32, 16.0), sans.metrics.point_size);

    var mono = try DirectWriteFace.initSystem(.monospace, 16.0, .regular);
    defer mono.deinit();
    try testing.expect(mono.metrics.is_monospace);
    const advance_i = mono.glyphAdvance(mono.glyphIndex('i'));
    try testing.expectApproxEqAbs(mono.metrics.cell_width, advance_i, 0.001);
}

test "variants select distinct faces and unknown families fall back" {
    // Goal: CSS matching over DirectWrite's family list, and the documented
    // fallback for a family that is not installed. Methodology: Segoe UI has
    // real bold and italic faces, which differ from regular in advance width;
    // an unknown family must load exactly Segoe UI's regular face.
    var regular = try DirectWriteFace.init("Segoe UI", 16.0, .regular);
    defer regular.deinit();
    var bold = try DirectWriteFace.init("Segoe UI", 16.0, .bold);
    defer bold.deinit();
    var italic = try DirectWriteFace.init("sans-serif", 16.0, .italic);
    defer italic.deinit();

    const glyph_regular = regular.glyphIndex('m');
    const advance_regular = regular.glyphAdvance(glyph_regular);
    try testing.expect(glyph_regular != 0);
    try testing.expect(bold.glyphAdvance(bold.glyphIndex('m')) > advance_regular);
    try testing.expect(italic.glyphIndex('m') != 0);

    var unknown = try DirectWriteFace.init("No Such Family Gooey", 16.0, .regular);
    defer unknown.deinit();
    try testing.expectEqual(regular.metrics.ascender, unknown.metrics.ascender);
    try testing.expectEqual(advance_regular, unknown.glyphAdvance(glyph_regular));
}

test "glyph lookup and metrics at the font's boundaries" {
    // Goal: the .notdef and out-of-range paths. Methodology: a noncharacter
    // maps to glyph 0, and a glyph id past the font reports zero metrics and
    // refuses to rasterize.
    var face = try DirectWriteFace.initSystem(.sans_serif, 16.0, .regular);
    defer face.deinit();
    try testing.expectEqual(@as(u16, 0), face.glyphIndex(0x10FFFF));

    const outside = face.glyph_count;
    try testing.expectEqual(@as(f32, 0), face.glyphMetrics(outside).advance_x);
    var buffer: [16]u8 = undefined;
    try testing.expectError(
        error.GlyphNotInFont,
        face.renderGlyphSubpixel(outside, 16.0, 1.0, 0, 0, &buffer, buffer.len),
    );

    const metrics_h = face.glyphMetrics(face.glyphIndex('H'));
    try testing.expect(metrics_h.width > 0);
    try testing.expectApproxEqAbs(face.metrics.cap_height, metrics_h.bearing_y, 0.5);
}

test "rasterization covers the glyph, honors subpixel shifts, and bounds size" {
    // Goal: the coverage bitmap and its placement contract. Methodology:
    // 'H' at 16 px has ink whose top sits near the cap height above the
    // baseline; a half-pixel shift changes the bitmap; a space has an
    // advance but no pixels; a glyph past MAX_GLYPH_SIZE comes back blank,
    // not cropped; a buffer too small for the glyph is refused, not overrun.
    var face = try DirectWriteFace.initSystem(.sans_serif, 16.0, .regular);
    defer face.deinit();
    const buffer = try testing.allocator.alloc(u8, buffer_bytes);
    defer testing.allocator.free(buffer);

    const glyph_h = face.glyphIndex('H');
    const at_zero = try render(&face, glyph_h, 1.0, 0, buffer);
    try testing.expect(at_zero.width > 4);
    try testing.expect(at_zero.height > 8);
    try testing.expect(at_zero.offset_y >= 10);
    try testing.expect(at_zero.offset_y <= 13);
    try testing.expect(!at_zero.is_color);
    const pixels_zero = buffer[0 .. at_zero.width * at_zero.height];
    try testing.expect(std.mem.max(u8, pixels_zero) == 255);
    const copy = try testing.allocator.dupe(u8, pixels_zero);
    defer testing.allocator.free(copy);

    const at_half = try render(&face, glyph_h, 1.0, 0.5, buffer);
    const pixels_half = buffer[0 .. at_half.width * at_half.height];
    const same_size = at_half.width == at_zero.width and at_half.height == at_zero.height;
    try testing.expect(!(same_size and std.mem.eql(u8, copy, pixels_half)));

    // Twice the scale doubles the device size and keeps the logical advance.
    const at_double = try render(&face, glyph_h, 2.0, 0, buffer);
    try testing.expect(at_double.height >= at_zero.height * 2 - 2);
    try testing.expectApproxEqAbs(at_zero.advance_x, at_double.advance_x, 0.001);

    const space = try render(&face, face.glyphIndex(' '), 1.0, 0, buffer);
    try testing.expectEqual(@as(u32, 0), space.width);
    try testing.expect(space.advance_x > 0);

    // Over MAX_GLYPH_SIZE (256 px): blank with its advance, so only this
    // glyph is missing from its run. Just under it still rasterizes.
    const oversized = try face.renderGlyphSubpixel(glyph_h, 400.0, 1.0, 0, 0, buffer, buffer_bytes);
    try testing.expectEqual(@as(u32, 0), oversized.width);
    try testing.expectEqual(@as(u32, 0), oversized.height);
    try testing.expectApproxEqAbs(at_zero.advance_x * 25.0, oversized.advance_x, 0.01);
    const largest = try face.renderGlyphSubpixel(glyph_h, 200.0, 1.0, 0, 0, buffer, buffer_bytes);
    try testing.expect(largest.height > 128);
    try testing.expect(largest.height <= limits.MAX_GLYPH_SIZE);

    const glyph_bytes = at_zero.width * at_zero.height;
    try testing.expectError(
        error.GlyphTooLarge,
        face.renderGlyphSubpixel(glyph_h, 16.0, 1.0, 0, 0, buffer, glyph_bytes - 1),
    );
    const exact = try face.renderGlyphSubpixel(glyph_h, 16.0, 1.0, 0, 0, buffer, glyph_bytes);
    try testing.expectEqual(at_zero.width, exact.width);
}

test "shaping maps glyphs to UTF-8 clusters across scripts" {
    // Goal: script itemization and cluster mapping. Methodology: Latin plus
    // Greek forces two script runs; a two-byte and a four-byte character
    // check byte offsets; widths must equal the summed advances.
    var face = try DirectWriteFace.initSystem(.sans_serif, 16.0, .regular);
    defer face.deinit();
    const shaper = try createShaper();
    defer destroyShaper(shaper);

    var latin_greek = try shaper.shape(&face, "ab αβ", testing.allocator);
    defer latin_greek.deinit(testing.allocator);
    try testing.expect(shaper.script_run_count >= 2);
    try testing.expectEqual(@as(usize, 5), latin_greek.glyphs.len);
    const expected_clusters = [_]u32{ 0, 1, 2, 3, 5 };
    var width: f32 = 0;
    for (latin_greek.glyphs, expected_clusters) |glyph, cluster| {
        try testing.expectEqual(cluster, glyph.cluster);
        try testing.expect(glyph.glyph_id != 0);
        width += glyph.x_advance;
    }
    try testing.expectApproxEqAbs(width, latin_greek.width, 0.001);

    var plain = try shaper.shape(&face, "H", testing.allocator);
    defer plain.deinit(testing.allocator);
    try testing.expectApproxEqAbs(face.glyphAdvance(face.glyphIndex('H')), plain.width, 0.001);

    var multibyte = try shaper.shape(&face, "é😀x", testing.allocator);
    defer multibyte.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), multibyte.glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 2), multibyte.glyphs[1].cluster);
    try testing.expectEqual(@as(u32, 6), multibyte.glyphs[multibyte.glyphs.len - 1].cluster);

    var empty = try shaper.shape(&face, "", testing.allocator);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.glyphs.len);
    try testing.expectError(error.InvalidUtf8, shaper.shape(&face, "\xff", testing.allocator));
}

test "shaping capacity: exactly full succeeds, one unit more fails" {
    // Goal: the documented capacity contract. Methodology: fill the UTF-16
    // buffer exactly with ASCII, then exceed it by one unit, then by a
    // surrogate pair that would straddle the last slot; the shaper stays
    // usable after each failure.
    var face = try DirectWriteFace.initSystem(.sans_serif, 16.0, .regular);
    defer face.deinit();
    const shaper = try createShaper();
    defer destroyShaper(shaper);

    const count_max = shaper_mod.text_utf16_count_max;
    const text = try testing.allocator.alloc(u8, count_max + 4);
    defer testing.allocator.free(text);
    @memset(text, 'a');

    var full = try shaper.shape(&face, text[0..count_max], testing.allocator);
    defer full.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, count_max), full.glyphs.len);
    try testing.expectEqual(@as(u32, count_max - 1), full.glyphs[count_max - 1].cluster);

    try testing.expectError(
        error.TextTooLong,
        shaper.shape(&face, text[0 .. count_max + 1], testing.allocator),
    );

    // 2047 ASCII units leave one slot; the emoji needs two.
    @memcpy(text[count_max - 1 ..][0..4], "😀");
    try testing.expectError(
        error.TextTooLong,
        shaper.shape(&face, text[0 .. count_max + 3], testing.allocator),
    );

    var after = try shaper.shape(&face, "ok", testing.allocator);
    defer after.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), after.glyphs.len);
}
