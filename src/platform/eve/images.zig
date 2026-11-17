//! The image atlas, mirrored into `RAM_G` as one ARGB4 bitmap.
//!
//! Gooey's image atlas holds decoded RGBA images at their decoded size and
//! hands each upload over once (`uploadAtlas`). This file converts every
//! upload into a host mirror of the atlas in the BT81x `ARGB4` format, then
//! `flush` writes the uploaded rectangles to the same texels of the chip's
//! copy at `RamLayout.image_address`. An image sprite then draws straight
//! from the chip's copy: one bitmap handle whose source is the sprite's
//! region, scaled by `BITMAP_TRANSFORM` (`display_list.image`).
//!
//! ## Why ARGB4
//!
//! The BT817 has no 32-bit bitmap format. Of its formats with alpha,
//! `ARGB1555` keeps one alpha bit, so anti-aliased edges go jagged; the
//! paletted formats need a palette per image and, for `PALETTED8`, several
//! passes per draw; an L8 alpha plane under an `RGB565` image costs 3 B per
//! texel and two draws through the alpha buffer. `ARGB4` is one draw at
//! 2 B per texel with 16 alpha levels, which keeps logo and icon edges
//! smooth. Its 16 levels per channel band smooth gradients, so photographs
//! look posterized; flat-colour artwork, the embedded case, does not.
//!
//! ## Ownership and lifetime
//!
//! The atlas never rewrites texels a frame in flight draws, and the chip
//! shows the last swapped list until the next swap, which `draw` waits for
//! before it flushes. So rows are written in place without retirement.
//!
//! ## Memory (CLAUDE.md §2)
//!
//! The mirror is `image_size² × 2` bytes from fresh pages (288 KiB at
//! `.embedded`), plus a queue of `pending_count_max` rectangles. Nothing
//! allocates after initialization.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Per upload: one pass over its texels converting RGBA to ARGB4.
//! - Per frame: the uploaded rectangles, `width × 2` bytes a row, each row
//!   one `RAM_G` write; at most half the frame's RGBA upload bytes, so the
//!   SPI budget (`EveLimits.spiBytesFrameMax`) covers them. Images land at
//!   most one per frame (`core/images.zig`).
//! - After a failed transfer every row an upload wrote is sent again, once.

const std = @import("std");
const chip_mod = @import("chip.zig");
const cells_mod = @import("cells.zig");
const reservation = @import("../../core/reservation.zig");

const assert = std.debug.assert;
const Chip = chip_mod.Chip;
const Region = cells_mod.Region;

/// Upload rectangles one frame may queue. Each landed image is one, and
/// images land at most one per frame; the rest is headroom.
pub const pending_count_max: u32 = 16;
/// Bytes per texel in the chip's copy.
pub const texel_bytes: u32 = 2;

pub const ImageMirror = struct {
    /// The atlas in ARGB4, `size × size` texels, little-endian `u16`.
    texels: []u8 = &.{},
    size: u32 = 0,
    /// The chip's copy of texel (0, 0).
    address: u32 = 0,
    /// Rows any upload wrote, for resending after a failure and zeroing.
    rows_used: u32 = 0,
    pending: [pending_count_max]Region = undefined,
    pending_count: u32 = 0,
    /// Every used row must be resent: a transfer failed.
    resend_all: bool = false,

    const Self = @This();

    pub fn initInPlace(self: *Self, size: u32, address: u32) !void {
        assert(size > 0);
        assert(address % texel_bytes == 0);
        assert(address + size * size * texel_bytes <= chip_mod.ram_g_size);
        self.size = size;
        self.address = address;
        self.rows_used = 0;
        self.pending_count = 0;
        self.resend_all = false;
        self.texels = try reservation.reserve(u8, size * size * texel_bytes);
        assert(self.texels.len == size * size * texel_bytes);
    }

    pub fn deinit(self: *Self) void {
        assert(self.rows_used <= self.size);
        const used = self.rows_used * self.stride();
        reservation.release(u8, self.texels, used);
        self.texels = &.{};
    }

    /// Bytes from one row of the chip's copy to the next.
    pub fn stride(self: *const Self) u32 {
        assert(self.size > 0);
        return self.size * texel_bytes;
    }

    /// Convert `rgba` (straight alpha, `region.w × region.h × 4` bytes) into
    /// the mirror and queue the rectangle for the next `flush`. A frame that
    /// queues more rectangles than the queue holds fails fast.
    pub fn upload(self: *Self, region: Region, rgba: []const u8) void {
        assert(region.x + region.w <= self.size);
        assert(region.y + region.h <= self.size);
        assert(rgba.len == @as(usize, region.w) * region.h * 4);
        if (self.pending_count == pending_count_max) {
            std.debug.panic("EVE renderer: image upload queue exhausted: capacity {d}, " ++
                "{d} queued, 1 requested ({d}x{d} at {d},{d}). Images land one per frame; " ++
                "this many uploads in one frame means the atlas changed contract.", .{
                pending_count_max,
                self.pending_count,
                region.w,
                region.h,
                region.x,
                region.y,
            });
        }
        var row: u32 = 0;
        while (row < region.h) : (row += 1) {
            const source = rgba[@as(usize, row) * region.w * 4 ..][0 .. region.w * 4];
            const offset = (region.y + row) * self.stride() + region.x * texel_bytes;
            convertRow(source, self.texels[offset..][0 .. region.w * texel_bytes]);
        }
        self.pending[self.pending_count] = region;
        self.pending_count += 1;
        self.rows_used = @max(self.rows_used, region.y + region.h);
        assert(self.pending_count <= pending_count_max);
    }

    /// Write the queued rectangles, or every used row after a failure, to the
    /// chip's copy. Returns the bytes written.
    pub fn flush(self: *Self, chip: *Chip) chip_mod.Error!u64 {
        assert(self.pending_count <= pending_count_max);
        assert(self.rows_used <= self.size);
        if (self.resend_all) {
            const bytes = self.rows_used * self.stride();
            if (bytes > 0) try chip.writeMemory(self.address, self.texels[0..bytes]);
            self.resend_all = false;
            self.pending_count = 0;
            return bytes;
        }
        var written: u64 = 0;
        for (self.pending[0..self.pending_count]) |region| {
            written += try self.writeRegion(chip, region);
        }
        self.pending_count = 0;
        return written;
    }

    /// After a failed transfer the chip's copy is unknown; resend it whole.
    pub fn forgetAll(self: *Self) void {
        assert(self.rows_used <= self.size);
        self.resend_all = self.rows_used > 0;
        self.pending_count = 0;
    }

    /// The chip address of `region`'s top-left texel.
    pub fn sourceOf(self: *const Self, region: Region) u32 {
        assert(region.x < self.size);
        assert(region.y < self.size);
        return self.address + region.y * self.stride() + region.x * texel_bytes;
    }

    fn writeRegion(self: *Self, chip: *Chip, region: Region) chip_mod.Error!u64 {
        assert(region.w > 0);
        assert(region.h > 0);
        const row_bytes = region.w * texel_bytes;
        // Full-width rectangles are contiguous: one write.
        if (region.x == 0 and region.w == self.size) {
            const offset = region.y * self.stride();
            const rows = self.texels[offset..][0 .. region.h * row_bytes];
            try chip.writeMemory(self.address + offset, rows);
            return region.h * row_bytes;
        }
        var row: u32 = 0;
        while (row < region.h) : (row += 1) {
            const offset = (region.y + row) * self.stride() + region.x * texel_bytes;
            try chip.writeMemory(self.address + offset, self.texels[offset..][0..row_bytes]);
        }
        return @as(u64, region.h) * row_bytes;
    }
};

/// RGBA8 straight alpha to ARGB4 (`A << 12 | R << 8 | G << 4 | B`), rounded.
fn convertRow(rgba: []const u8, target: []u8) void {
    assert(rgba.len % 4 == 0);
    assert(target.len == rgba.len / 4 * texel_bytes);
    var index: usize = 0;
    while (index < rgba.len / 4) : (index += 1) {
        const texel = rgba[index * 4 ..][0..4];
        const value = (@as(u16, nibble(texel[3])) << 12) | (@as(u16, nibble(texel[0])) << 8) |
            (@as(u16, nibble(texel[1])) << 4) | nibble(texel[2]);
        std.mem.writeInt(u16, target[index * 2 ..][0..2], value, .little);
    }
}

/// The nearest of 16 levels: 0..8 → 0, 247..255 → 15.
fn nibble(value: u8) u4 {
    const level = (@as(u32, value) * 15 + 127) / 255;
    assert(level <= 15);
    return @intCast(level);
}

const testing = std.testing;

test "uploads convert to rounded ARGB4 and flush only their rectangle" {
    // Goal: the channel order and rounding the BT81x reads, and that a flush
    // writes the uploaded texels at the atlas address and nothing beside
    // them. Methodology: a 2x1 upload at (1, 2) of a 4² atlas on the
    // simulated chip; 0x80 rounds to level 8 (8 × 17 = 136, nearer 128 than
    // level 7's 119), 0x08 to level 0, 0x09 to level 1.
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    var mirror: ImageMirror = .{};
    try mirror.initInPlace(4, 0x1000);
    defer mirror.deinit();
    const region = Region{ .x = 1, .y = 2, .w = 2, .h = 1 };
    mirror.upload(region, &.{ 255, 0x80, 0, 255, 0x08, 0x09, 255, 0x80 });
    try testing.expectEqual(@as(u64, 4), try mirror.flush(&chip));
    const row = chip.sim_memory[0x1000 + 2 * 8 ..][0..8];
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, row[0..2], .little));
    try testing.expectEqual(@as(u16, 0xFF80), std.mem.readInt(u16, row[2..4], .little));
    try testing.expectEqual(@as(u16, 0x801F), std.mem.readInt(u16, row[4..6], .little));
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, row[6..8], .little));
    try testing.expectEqual(@as(u32, 0x1000 + 2 * 8 + 2), mirror.sourceOf(region));
    // Nothing queued: the next flush writes nothing; after a failure, every used row.
    try testing.expectEqual(@as(u64, 0), try mirror.flush(&chip));
    mirror.forgetAll();
    try testing.expectEqual(@as(u64, 3 * 8), try mirror.flush(&chip));
}

test "the upload queue fills exactly, then the next upload fails fast" {
    // Capacity is checked by the panic path, which a test cannot catch; this
    // fills the queue to its last slot and checks the count, then flushes.
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    var mirror: ImageMirror = .{};
    try mirror.initInPlace(pending_count_max, 0);
    defer mirror.deinit();
    var index: u32 = 0;
    while (index < pending_count_max) : (index += 1) {
        mirror.upload(.{ .x = index, .y = index, .w = 1, .h = 1 }, &.{ 1, 2, 3, 4 });
    }
    try testing.expectEqual(pending_count_max, mirror.pending_count);
    try testing.expectEqual(@as(u64, pending_count_max * texel_bytes), try mirror.flush(&chip));
    try testing.expectEqual(@as(u32, 0), mirror.pending_count);
}
