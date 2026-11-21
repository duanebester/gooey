//! The BT81x chip's fixed budgets, and how an app's `ResourceLimits` lays
//! out the chip's `RAM_G`. The chip facts do not change per app: a
//! 2048-command display list, 1 MiB of `RAM_G`, and 15 bitmap handles left
//! free of ROM fonts and the coprocessor. What changes is how the app's
//! `AtlasLimits` divides `RAM_G`:
//!
//! | `RAM_G` range | Holds | Size |
//! | --- | --- | --- |
//! | from 0 | glyph and icon cell pages (`cells.zig`), one handle each | 64 KiB a page |
//! | below the scratch | the image atlas mirror (`images.zig`), ARGB4 | `image_size² × 2` |
//! | top 64 KiB | `CMD_SNAPSHOT2` scratch, never written by Gooey | 64 KiB |
//!
//! Cell pages take what the image mirror leaves, up to 14 (handle 14 draws
//! images). `check` runs at comptime on the app's profile from the EVE host,
//! so a profile whose image atlas leaves fewer than `cell_page_count_min`
//! pages, whose atlases the cell keys cannot address, whose glyph and icon
//! caches outnumber the cells, or whose paint limits cannot fit the display
//! list (`paintWordsMin`) is a compile error.
//!
//! Per frame, the SPI bus carries the display list, the swap request, and
//! the frame's new cells and image rows: at most `RAM_DL` plus
//! `AtlasLimits.upload_bytes_frame_max` (`spiBytesFrameMax`). At 30 MHz that
//! is 2.2 ms for a full list; first frames and image landings take longer.

const std = @import("std");
const limits_mod = @import("../../core/limits.zig");

const assert = std.debug.assert;
const AtlasLimits = limits_mod.AtlasLimits;
const PaintLimits = limits_mod.PaintLimits;
const ResourceLimits = limits_mod.ResourceLimits;

pub const EveLimits = struct {
    /// `RAM_DL` in 32-bit commands.
    display_list_words_max: u32,
    /// Commands a frame's list may use, well below `RAM_DL`: the chip walks
    /// the whole list for every line within a budget of about 2048 clocks,
    /// and a line it cannot finish is dropped (`REG_UNDERRUN` counts them;
    /// on screen, torn and garbled lines). Measured on a BT817 driving the
    /// RVT70 (1024x600, 51 MHz pixel clock, 1344-pixel lines, so 1897 system
    /// clocks a line at 72 MHz), each list held 60 frames and gated on
    /// `REG_UNDERRUN`, not on what eyes catch: full-width bars, text rows,
    /// and a 960x576 BILINEAR image under text rows read 0 through 2048
    /// commands, 16 translucent full-screen layers under glyphs through
    /// 1792; 16 px glyphs spread over every line read 0 through 1888 and
    /// underran 150 to 180 lines a frame from 1920 (750 at 2048, where the
    /// tearing is visible; at 1920 it was not); 1x1 rects and points read 0
    /// through 1951 and 1952; a list of `NOP`s, the bare walk of the list,
    /// read 0 through 1824 and underran every line from 1828. The cap is
    /// 288 commands (16 %) below that floor, so a line keeps room for pixel
    /// work the measured lists did not combine with their length. The
    /// renderer logs `REG_UNDERRUN` every 5 s and warns when it moves.
    display_list_words_frame_max: u32,
    /// Commands every list spends outside its primitives: the preamble
    /// (`display_list.preamble_words`) and `DISPLAY`.
    display_list_frame_words: u32,
    /// Bytes of `RAM_DL`.
    display_list_bytes: u32,
    /// Bytes of `RAM_G`.
    ram_g_bytes: u32,
    /// `RAM_G` at the top left for `CMD_SNAPSHOT2` strips (1024x32 RGB565).
    snapshot_scratch_bytes: u32,
    cell_page_bytes: u32,
    /// Bitmap handles for cell pages (0..13); handle 14 draws images.
    cell_page_count_max: u32,
    /// Cells a page holds at most (`VERTEX2II` names 0..127).
    cell_page_cells_max: u32,
    /// Fewest cell pages a profile may leave: one page holds one size class,
    /// and counter's text alone uses five classes.
    cell_page_count_min: u32,
    /// Bytes per image texel in `RAM_G` (ARGB4).
    image_texel_bytes: u32,
    /// Largest atlas side a cell key can address (13 bits).
    atlas_size_max: u32,
    svg_icon_size_max: u32,

    /// The BT815, BT816, BT817, and BT818.
    pub const bt81x: EveLimits = .{
        .display_list_words_max = 2048,
        .display_list_words_frame_max = 1536,
        .display_list_frame_words = 8,
        .display_list_bytes = 8 * 1024,
        .ram_g_bytes = 1024 * 1024,
        .snapshot_scratch_bytes = 64 * 1024,
        .cell_page_bytes = 64 * 1024,
        .cell_page_count_max = 14,
        .cell_page_cells_max = 128,
        .cell_page_count_min = 6,
        .image_texel_bytes = 2,
        .atlas_size_max = 4096,
        .svg_icon_size_max = 128,
    };

    comptime {
        assert(bt81x.display_list_words_max * 4 == bt81x.display_list_bytes);
        assert(bt81x.display_list_words_frame_max <= bt81x.display_list_words_max);
        assert(bt81x.display_list_frame_words < bt81x.display_list_words_frame_max);
        assert(bt81x.cell_page_count_max * bt81x.cell_page_bytes +
            bt81x.snapshot_scratch_bytes <= bt81x.ram_g_bytes);
        assert(bt81x.svg_icon_size_max * bt81x.svg_icon_size_max <= bt81x.cell_page_bytes);
        // Any image atlas that leaves the minimum pages has a texel stride
        // (`image_size × 2`) within `BITMAP_LAYOUT`'s 12 bits.
        assert(bt81x.ram_g_bytes / bt81x.image_texel_bytes <= 2047 * 2047);
    }

    /// Where `atlas` puts each region of `RAM_G`. Assumes `check` passed.
    pub fn layout(self: *const EveLimits, atlas: *const AtlasLimits) RamLayout {
        const image_bytes = self.imageBytes(atlas);
        assert(image_bytes + self.snapshot_scratch_bytes < self.ram_g_bytes);
        const image_address = self.ram_g_bytes - self.snapshot_scratch_bytes - image_bytes;
        const pages = @min(image_address / self.cell_page_bytes, self.cell_page_count_max);
        const result: RamLayout = .{
            .cell_page_count = pages,
            .image_address = image_address,
            .image_bytes = image_bytes,
            .snapshot_address = self.ram_g_bytes - self.snapshot_scratch_bytes,
        };
        assert(result.cell_page_count * self.cell_page_bytes <= result.image_address);
        assert(result.image_address + result.image_bytes == result.snapshot_address);
        return result;
    }

    pub fn imageBytes(self: *const EveLimits, atlas: *const AtlasLimits) u32 {
        assert(atlas.image_size > 0);
        assert(atlas.image_size <= limits_mod.MAX_ATLAS_SIZE);
        return atlas.image_size * atlas.image_size * self.image_texel_bytes;
    }

    /// Most bytes one frame sends: the list, the swap request, and new cells
    /// and image rows, which the atlas upload budget bounds.
    pub fn spiBytesFrameMax(self: *const EveLimits, atlas: *const AtlasLimits) u64 {
        assert(atlas.upload_bytes_frame_max > 0);
        assert(self.display_list_bytes > 0);
        return @as(u64, self.display_list_bytes) + 4 + atlas.upload_bytes_frame_max;
    }

    /// Fewest list commands a frame drawing every primitive `paint` allows
    /// needs, each continuing a run whose state is already set: a rect's two
    /// vertices, a shadow's three rects, a glyph's or icon's one `VERTEX2II`,
    /// an image's one vertex, and a polyline's or point cloud's `BEGIN` plus
    /// one vertex per point. Paths are not drawn on EVE (they fail fast).
    pub fn paintWordsMin(self: *const EveLimits, paint: *const PaintLimits) u64 {
        assert(paint.glyph_count_frame_max > 0);
        assert(self.display_list_frame_words > 0);
        const words: u64 = @as(u64, self.display_list_frame_words) +
            2 * @as(u64, paint.quad_count_frame_max) +
            6 * @as(u64, paint.shadow_count_frame_max) +
            paint.glyph_count_frame_max + paint.svg_count_frame_max +
            paint.image_count_frame_max +
            paint.polyline_count_frame_max + paint.polyline_point_count_frame_max +
            paint.point_cloud_count_frame_max + paint.point_count_frame_max;
        assert(words > paint.glyph_count_frame_max);
        return words;
    }

    /// The first rule `limits` breaks on this chip, as a sentence naming the
    /// `ResourceLimits` field, or null. The EVE host runs it at comptime on
    /// the app's own budget; the debugger overlay's headroom is left out,
    /// since its shortcut needs a keyboard and the panel has only touch.
    pub fn check(self: *const EveLimits, limits: *const ResourceLimits) ?[]const u8 {
        assert(limits.paint.glyph_count_frame_max > 0);
        assert(self.display_list_words_frame_max <= self.display_list_words_max);
        if (self.checkAtlas(&limits.atlas)) |reason| return reason;
        // The atlases protect the frame on screen and the one building
        // (`AtlasUploads.protectShownFrame`), so their caches hold two frames.
        if (2 * limits.paint.svg_count_frame_max > limits.atlas.svg_entry_count_max) {
            return "atlas.svg_entry_count_max is below 2 × paint.svg_count_frame_max: the " ++
                "EVE host keeps the icons of the frame on screen and the frame building";
        }
        if (2 * limits.paint.image_count_frame_max > limits.atlas.image_entry_count_max) {
            return "atlas.image_entry_count_max is below 2 × paint.image_count_frame_max: " ++
                "the EVE host keeps the images of the frame on screen and the frame building";
        }
        // Every region two consecutive frames draw is resident in its atlas at
        // once, one glyph cache entry or icon (fill and stroke) each, so the
        // cells must at least outnumber what the caches name. Size classes
        // divide pages, so this is necessary, not sufficient (`cells.zig`).
        const regions = @as(u64, limits.text.glyph_cache_count_max) +
            2 * @as(u64, limits.atlas.svg_entry_count_max);
        const pages = self.layout(&limits.atlas).cell_page_count;
        if (regions > @as(u64, pages) * self.cell_page_cells_max) {
            return "text.glyph_cache_count_max + 2 × atlas.svg_entry_count_max is past the " ++
                "glyph cells the RAM_G layout holds (128 a page, at most 1280 at .embedded)";
        }
        if (self.paintWordsMin(&limits.paint) > self.display_list_words_frame_max) {
            return "the paint limits need more than the 1536 display-list commands a frame " ++
                "may use (EveLimits.paintWordsMin); use .embedded or lower paint counts";
        }
        return null;
    }

    /// The first rule `atlas` breaks on this chip, or null; the part of
    /// `check` the renderer repeats at init.
    pub fn checkAtlas(self: *const EveLimits, atlas: *const AtlasLimits) ?[]const u8 {
        assert(atlas.image_size > 0);
        assert(self.ram_g_bytes > self.snapshot_scratch_bytes);
        if (atlas.text_size > self.atlas_size_max) return "atlas.text_size is past 4096";
        if (atlas.svg_size > self.atlas_size_max) return "atlas.svg_size is past 4096";
        if (atlas.svg_icon_size_max > self.svg_icon_size_max) {
            return "atlas.svg_icon_size_max is past the 128 px largest EVE cell";
        }
        const room = self.ram_g_bytes - self.snapshot_scratch_bytes -
            self.cell_page_count_min * self.cell_page_bytes;
        if (@as(u64, atlas.image_size) * atlas.image_size * self.image_texel_bytes > room) {
            return "atlas.image_size leaves fewer than 6 glyph-cell pages of the 1 MiB " ++
                "RAM_G: its ARGB4 mirror takes image_size² × 2 bytes, at most 576 KiB. " ++
                "Use .embedded or lower atlas.image_size";
        }
        return null;
    }
};

/// One app's division of `RAM_G`.
pub const RamLayout = struct {
    cell_page_count: u32,
    image_address: u32,
    image_bytes: u32,
    snapshot_address: u32,
};

const testing = std.testing;

test "profiles divide RAM_G between cell pages and the image mirror, or fail the check" {
    const chip = EveLimits.bt81x;
    const embedded = chip.layout(&ResourceLimits.embedded.atlas);
    try testing.expectEqual(@as(u32, 10), embedded.cell_page_count);
    try testing.expectEqual(@as(u32, 288 * 1024), embedded.image_bytes);
    try testing.expectEqual(@as(u32, 960 * 1024), embedded.snapshot_address);
    try testing.expectEqual(@as(u32, 13), chip.layout(&ResourceLimits.nano.atlas).cell_page_count);
    try testing.expectEqual(@as(u32, 7), chip.layout(&ResourceLimits.small.atlas).cell_page_count);
    try testing.expect(chip.checkAtlas(&ResourceLimits.embedded.atlas) == null);
    try testing.expect(chip.checkAtlas(&ResourceLimits.nano.atlas) == null);
    try testing.expect(chip.checkAtlas(&ResourceLimits.small.atlas) == null);
    try testing.expect(chip.checkAtlas(&ResourceLimits.standard.atlas) != null);
    // The boundary: the largest multiple-of-64 side that leaves 6 pages, then the next.
    var atlas = ResourceLimits.embedded.atlas;
    atlas.image_size = 512;
    try testing.expect(chip.checkAtlas(&atlas) == null);
    atlas.image_size = 576;
    try testing.expect(chip.checkAtlas(&atlas) != null);
}

test "a profile fits the chip only if its paint limits fit the display list" {
    // .embedded needs 8 + 128 × 2 + 8 × 6 + 1024 + 16 + 8 + (4 + 64) +
    // (4 + 64) = 1496 commands; `.nano` (3,716) and `.small` do not fit.
    const chip = EveLimits.bt81x;
    const embedded = ResourceLimits.embedded;
    try testing.expectEqual(@as(u64, 1496), chip.paintWordsMin(&embedded.paint));
    try testing.expect(chip.check(&embedded) == null);
    try testing.expectEqual(@as(u64, 3716), chip.paintWordsMin(&ResourceLimits.nano.paint));
    try testing.expect(chip.check(&ResourceLimits.nano) != null);
    try testing.expect(chip.check(&ResourceLimits.small) != null);
    // 40 more commands reach the cap exactly; one more passes it.
    var limits = embedded;
    limits.paint.quad_count_frame_max += 20;
    const cap: u64 = chip.display_list_words_frame_max;
    try testing.expectEqual(cap, chip.paintWordsMin(&limits.paint));
    try testing.expect(chip.check(&limits) == null);
    limits.paint.svg_count_frame_max += 1;
    try testing.expect(chip.check(&limits) != null);
}

test "a profile fits the chip only if its caches hold two frames and fit the cells" {
    // The atlases protect two frames on EVE, and the glyph and icon caches
    // must not name more regions than the pages hold cells: .embedded needs
    // 512 + 2 × 64 = 640 regions against 10 pages × 128 = 1280 cells.
    const chip = EveLimits.bt81x;
    var limits = ResourceLimits.embedded;
    limits.atlas.image_entry_count_max = 2 * limits.paint.image_count_frame_max - 1;
    try testing.expect(chip.check(&limits) != null);
    limits = ResourceLimits.embedded;
    limits.atlas.svg_entry_count_max = 2 * limits.paint.svg_count_frame_max - 1;
    try testing.expect(chip.check(&limits) != null);
    limits = ResourceLimits.embedded;
    limits.text.glyph_cache_count_max = 1280 - 2 * limits.atlas.svg_entry_count_max;
    try testing.expect(chip.check(&limits) == null);
    limits.text.glyph_cache_count_max += 1;
    try testing.expect(chip.check(&limits) != null);
}
