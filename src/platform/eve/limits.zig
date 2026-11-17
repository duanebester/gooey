//! The BT81x chip's fixed budgets, and how an app's `ResourceLimits` lays
//! out the chip's `RAM_G` (CLAUDE.md §2).
//!
//! The chip facts do not change per app: a 2048-command display list, 1 MiB
//! of `RAM_G`, and 15 bitmap handles left free of ROM fonts and the
//! coprocessor. What changes is how the app's `AtlasLimits` divides `RAM_G`:
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
//! pages, or whose atlases the cell keys cannot address, is a compile error.
//!
//! Per frame, the SPI bus carries the display list, the swap request, and
//! the frame's new cells and image rows: at most `RAM_DL` plus
//! `AtlasLimits.upload_bytes_frame_max` (`spiBytesFrameMax`). At 30 MHz that
//! is 2.2 ms for a full list; first frames and image landings take longer.

const std = @import("std");
const limits_mod = @import("../../core/limits.zig");

const assert = std.debug.assert;
const AtlasLimits = limits_mod.AtlasLimits;
const ResourceLimits = limits_mod.ResourceLimits;

pub const EveLimits = struct {
    /// `RAM_DL` in 32-bit commands.
    display_list_words_max: u32,
    /// Bytes of `RAM_DL`.
    display_list_bytes: u32,
    /// Bytes of `RAM_G`.
    ram_g_bytes: u32,
    /// `RAM_G` at the top left for `CMD_SNAPSHOT2` strips (1024x32 RGB565).
    snapshot_scratch_bytes: u32,
    /// One cell page, one bitmap handle.
    cell_page_bytes: u32,
    /// Bitmap handles for cell pages (0..13); handle 14 draws images.
    cell_page_count_max: u32,
    /// Fewest cell pages a profile may leave: one page holds one size class,
    /// and counter's text alone uses five classes.
    cell_page_count_min: u32,
    /// Bytes per image texel in `RAM_G` (ARGB4).
    image_texel_bytes: u32,
    /// Largest atlas side a cell key can address (13 bits).
    atlas_size_max: u32,
    /// Largest SVG icon side a cell holds.
    svg_icon_size_max: u32,

    /// The BT815, BT816, BT817, and BT818.
    pub const bt81x: EveLimits = .{
        .display_list_words_max = 2048,
        .display_list_bytes = 8 * 1024,
        .ram_g_bytes = 1024 * 1024,
        .snapshot_scratch_bytes = 64 * 1024,
        .cell_page_bytes = 64 * 1024,
        .cell_page_count_max = 14,
        .cell_page_count_min = 6,
        .image_texel_bytes = 2,
        .atlas_size_max = 4096,
        .svg_icon_size_max = 128,
    };

    comptime {
        assert(bt81x.display_list_words_max * 4 == bt81x.display_list_bytes);
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

    /// The image atlas mirror's bytes in `RAM_G`.
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

    /// The first rule `atlas` breaks on this chip, as a sentence naming the
    /// `ResourceLimits` field, or null. The EVE host runs it at comptime on
    /// the app's profile; the renderer again at init.
    pub fn check(self: *const EveLimits, atlas: *const AtlasLimits) ?[]const u8 {
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

/// One app's division of `RAM_G` (see the file comment).
pub const RamLayout = struct {
    cell_page_count: u32,
    image_address: u32,
    image_bytes: u32,
    snapshot_address: u32,
};

const testing = std.testing;

test "profiles divide RAM_G between cell pages and the image mirror, or fail the check" {
    // Goal: the image atlas and the cell pages never overlap, the scratch
    // stays free, and a profile that leaves too few pages is refused. The
    // embedded image atlas (384²) takes 288 KiB, leaving 10 pages; nano's
    // (256²) 128 KiB, 13 pages; small's (512²) 512 KiB, 7 pages; standard's
    // (1024²) 2 MiB does not fit at all.
    const chip = EveLimits.bt81x;
    const embedded = chip.layout(&ResourceLimits.embedded.atlas);
    try testing.expectEqual(@as(u32, 10), embedded.cell_page_count);
    try testing.expectEqual(@as(u32, 288 * 1024), embedded.image_bytes);
    try testing.expectEqual(@as(u32, 960 * 1024), embedded.snapshot_address);
    try testing.expectEqual(@as(u32, 13), chip.layout(&ResourceLimits.nano.atlas).cell_page_count);
    try testing.expectEqual(@as(u32, 7), chip.layout(&ResourceLimits.small.atlas).cell_page_count);
    try testing.expect(chip.check(&ResourceLimits.embedded.atlas) == null);
    try testing.expect(chip.check(&ResourceLimits.nano.atlas) == null);
    try testing.expect(chip.check(&ResourceLimits.small.atlas) == null);
    try testing.expect(chip.check(&ResourceLimits.standard.atlas) != null);
    // The boundary: the largest multiple-of-64 side that leaves 6 pages, then the next.
    var atlas = ResourceLimits.embedded.atlas;
    atlas.image_size = 512;
    try testing.expect(chip.check(&atlas) == null);
    atlas.image_size = 576;
    try testing.expect(chip.check(&atlas) != null);
}
