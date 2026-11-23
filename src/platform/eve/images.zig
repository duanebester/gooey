const std = @import("std");
const chip_mod = @import("chip.zig");
const cells_mod = @import("cells.zig");
const reservation = @import("../../core/reservation.zig");

const assert = std.debug.assert;
const Chip = chip_mod.Chip;
const Region = cells_mod.Region;

pub const pending_count_max: u32 = 16;
pub const texel_bytes: u32 = 2;

pub const ImageMirror = struct {
    texels: []u8 = &.{},
    size: u32 = 0,
    address: u32 = 0,
    rows_used: u32 = 0,
    pending: [pending_count_max]Region = undefined,
    pending_count: u32 = 0,
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

    pub fn stride(self: *const Self) u32 {
        assert(self.size > 0);
        return self.size * texel_bytes;
    }

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

    pub fn forgetAll(self: *Self) void {
        assert(self.rows_used <= self.size);
        self.resend_all = self.rows_used > 0;
        self.pending_count = 0;
    }

    pub fn sourceOf(self: *const Self, region: Region) u32 {
        assert(region.x < self.size);
        assert(region.y < self.size);
        return self.address + region.y * self.stride() + region.x * texel_bytes;
    }

    fn writeRegion(self: *Self, chip: *Chip, region: Region) chip_mod.Error!u64 {
        assert(region.w > 0);
        assert(region.h > 0);
        const row_bytes = region.w * texel_bytes;
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

fn nibble(value: u8) u4 {
    const level = (@as(u32, value) * 15 + 127) / 255;
    assert(level <= 15);
    return @intCast(level);
}

const testing = std.testing;

test "uploads convert to rounded ARGB4 and flush only their rectangle" {
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
    try testing.expectEqual(@as(u64, 0), try mirror.flush(&chip));
    mirror.forgetAll();
    try testing.expectEqual(@as(u64, 3 * 8), try mirror.flush(&chip));
}

test "the upload queue fills exactly, then the next upload fails fast" {
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
