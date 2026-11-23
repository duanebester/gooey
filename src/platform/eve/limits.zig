const std = @import("std");
const limits_mod = @import("../../core/limits.zig");

const assert = std.debug.assert;
const AtlasLimits = limits_mod.AtlasLimits;
const PaintLimits = limits_mod.PaintLimits;
const ResourceLimits = limits_mod.ResourceLimits;

pub const EveLimits = struct {
    display_list_words_max: u32,
    display_list_words_frame_max: u32,
    display_list_frame_words: u32,
    display_list_bytes: u32,
    ram_g_bytes: u32,
    snapshot_scratch_bytes: u32,
    cell_page_bytes: u32,
    cell_page_count_max: u32,
    cell_page_cells_max: u32,
    cell_page_count_min: u32,
    image_texel_bytes: u32,
    atlas_size_max: u32,
    svg_icon_size_max: u32,

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
        assert(bt81x.ram_g_bytes / bt81x.image_texel_bytes <= 2047 * 2047);
    }

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

    pub fn spiBytesFrameMax(self: *const EveLimits, atlas: *const AtlasLimits) u64 {
        assert(atlas.upload_bytes_frame_max > 0);
        assert(self.display_list_bytes > 0);
        return @as(u64, self.display_list_bytes) + 4 + atlas.upload_bytes_frame_max;
    }

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

    pub fn check(self: *const EveLimits, limits: *const ResourceLimits) ?[]const u8 {
        assert(limits.paint.glyph_count_frame_max > 0);
        assert(self.display_list_words_frame_max <= self.display_list_words_max);
        if (self.checkAtlas(&limits.atlas)) |reason| return reason;
        if (2 * limits.paint.svg_count_frame_max > limits.atlas.svg_entry_count_max) {
            return "atlas.svg_entry_count_max is below 2 × paint.svg_count_frame_max: the " ++
                "EVE host keeps the icons of the frame on screen and the frame building";
        }
        if (2 * limits.paint.image_count_frame_max > limits.atlas.image_entry_count_max) {
            return "atlas.image_entry_count_max is below 2 × paint.image_count_frame_max: " ++
                "the EVE host keeps the images of the frame on screen and the frame building";
        }
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
    var atlas = ResourceLimits.embedded.atlas;
    atlas.image_size = 512;
    try testing.expect(chip.checkAtlas(&atlas) == null);
    atlas.image_size = 576;
    try testing.expect(chip.checkAtlas(&atlas) != null);
}

test "a profile fits the chip only if its paint limits fit the display list" {
    const chip = EveLimits.bt81x;
    const embedded = ResourceLimits.embedded;
    try testing.expectEqual(@as(u64, 1496), chip.paintWordsMin(&embedded.paint));
    try testing.expect(chip.check(&embedded) == null);
    try testing.expectEqual(@as(u64, 3716), chip.paintWordsMin(&ResourceLimits.nano.paint));
    try testing.expect(chip.check(&ResourceLimits.nano) != null);
    try testing.expect(chip.check(&ResourceLimits.small) != null);
    var limits = embedded;
    limits.paint.quad_count_frame_max += 20;
    const cap: u64 = chip.display_list_words_frame_max;
    try testing.expectEqual(cap, chip.paintWordsMin(&limits.paint));
    try testing.expect(chip.check(&limits) == null);
    limits.paint.svg_count_frame_max += 1;
    try testing.expect(chip.check(&limits) != null);
}

test "a profile fits the chip only if its caches hold two frames and fit the cells" {
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
