const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const backing = std.heap.page_allocator;

const page_granular = !builtin.target.cpu.arch.isWasm();

pub fn reserve(comptime T: type, count: u32) error{OutOfMemory}![]T {
    comptime assert(@sizeOf(T) > 0);
    assert(count > 0);
    const byte_count = @as(usize, count) * @sizeOf(T);
    const alignment: std.mem.Alignment = comptime .fromByteUnits(if (page_granular)
        @max(@alignOf(T), std.heap.page_size_min)
    else
        @alignOf(T));
    const bytes = backing.rawAlloc(byte_count, alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    if (page_granular) assert(std.mem.isAligned(@intFromPtr(bytes), std.heap.page_size_min));
    const items: [*]T = @ptrCast(@alignCast(bytes));
    return items[0..count];
}

pub fn reserveZeroed(comptime T: type, count: u32) error{OutOfMemory}![]T {
    const items = try reserve(T, count);
    if (!page_granular) @memset(std.mem.sliceAsBytes(items), 0);
    assert(items.len == count);
    return items;
}

pub fn release(comptime T: type, items: []T, used_count_max: usize) void {
    assert(items.len > 0);
    assert(used_count_max <= items.len);
    @memset(std.mem.sliceAsBytes(items[0..used_count_max]), 0);
    const alignment: std.mem.Alignment = comptime .fromByteUnits(if (page_granular)
        @max(@alignOf(T), std.heap.page_size_min)
    else
        @alignOf(T));
    backing.rawFree(std.mem.sliceAsBytes(items), alignment, @returnAddress());
}

pub fn reserveList(comptime T: type, count: u32) error{OutOfMemory}!std.ArrayList(T) {
    const list = std.ArrayList(T).initBuffer(try reserve(T, count));
    assert(list.items.len == 0);
    assert(list.capacity == count);
    return list;
}

pub fn releaseList(comptime T: type, list: *std.ArrayList(T), used_count_max: usize) void {
    assert(list.items.len <= list.capacity);
    const used = @max(used_count_max, list.items.len);
    release(T, list.allocatedSlice(), used);
    list.* = .empty;
}

test "a reservation reads zero, holds its count, and releases after a partial write" {
    const count: u32 = @intCast(std.heap.page_size_min / @sizeOf(u64) + 1);
    const items = try reserve(u64, count);
    try std.testing.expectEqual(@as(usize, count), items.len);
    for (items) |item| try std.testing.expectEqual(@as(u64, 0), item);
    if (page_granular) {
        try std.testing.expect(std.mem.isAligned(@intFromPtr(items.ptr), std.heap.page_size_min));
    }
    @memset(items[0..3], 0xFFFF_FFFF_FFFF_FFFF);
    release(u64, items, 3);
}

test "reserveList has exact capacity and releases with its high-water mark" {
    var list = try reserveList(u32, 5);
    try std.testing.expectEqual(@as(usize, 5), list.capacity);
    list.appendSliceAssumeCapacity(&.{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(usize, 0), list.unusedCapacitySlice().len);
    list.clearRetainingCapacity();
    releaseList(u32, &list, 5);
    try std.testing.expectEqual(@as(usize, 0), list.capacity);
}
