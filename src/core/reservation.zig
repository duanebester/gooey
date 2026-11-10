//! Budget-sized CPU reservations that cost resident memory only where written.
//!
//! Every pool sized from `ResourceLimits` is reserved during initialization
//! (CLAUDE.md §2), but a frame typically uses a small prefix of it: counter
//! fills 22 of 16,384 layout elements. Pages become resident when first
//! written, so a reservation must not be written at init:
//!
//! - Storage comes straight from the page allocator, not the app's `gpa`.
//!   Fresh anonymous pages are zero by kernel contract (CLAUDE.md §21 counts
//!   them as zeroed) and stay non-resident until a frame writes them. A general
//!   allocator may instead hand back recycled, already-dirty memory, and release
//!   builds would then depend on malloc's region behaviour.
//! - `rawAlloc` skips `Allocator.alloc`'s safe-mode `@memset(undefined)`, which
//!   writes 0xAA over the whole reservation in Debug and ReleaseSafe builds and
//!   made Debug residency equal to the full budget. Nothing is zeroed at init.
//! - `release` zeroes the prefix the owner ever used, its high-water mark,
//!   before the storage returns to the allocator and a different owner could
//!   read it. The cost is proportional to use, never to capacity.
//!
//! Owners must read only what they wrote: lists read `items[0..len]`, and
//! scratch buffers are written before they are read within the same frame.
//!
//! There is no allocation-lifecycle guard yet (CLAUDE.md §2 SHOULD), so the
//! "initialization only" rule is enforced by the callers, which reserve from
//! their `init` functions.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The page allocator: `mmap` natively, `memory.grow` pages on WASM.
const backing = std.heap.page_allocator;

/// Natively every reservation is page-granular, so no other object shares its
/// pages and its residency is exactly what its owner wrote. WASM's page
/// allocator rounds small requests to size classes, and a 64 KiB alignment per
/// list would cost linear memory the browser cannot return.
const page_granular = !builtin.target.cpu.arch.isWasm();

/// Reserve `count` elements of `T` without writing them.
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

/// Zero `items[0..used_count_max]`, the prefix any owner ever wrote, then return
/// the reservation to the page allocator.
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

/// An empty list whose capacity is a fresh reservation of `count` elements.
/// The list must never grow past it: its storage is not owned by any `gpa`.
pub fn reserveList(comptime T: type, count: u32) error{OutOfMemory}!std.ArrayList(T) {
    const list = std.ArrayList(T).initBuffer(try reserve(T, count));
    assert(list.items.len == 0);
    assert(list.capacity == count);
    return list;
}

/// Release a list made by `reserveList`. `used_count_max` is the owner's
/// high-water mark; the current length counts too.
pub fn releaseList(comptime T: type, list: *std.ArrayList(T), used_count_max: usize) void {
    assert(list.items.len <= list.capacity);
    const used = @max(used_count_max, list.items.len);
    release(T, list.allocatedSlice(), used);
    list.* = .empty;
}

test "a reservation reads zero, holds its count, and releases after a partial write" {
    // Goal: the two properties callers rely on. Methodology: reserve more than
    // a page, check every byte reads zero (fresh pages, no 0xAA fill), write a
    // prefix, and release with that prefix as the high-water mark. A capacity
    // of exactly one past a page boundary checks the count-to-bytes conversion.
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
    // Goal: lists see the whole reservation as capacity and never more, and
    // `releaseList` accepts a high-water mark above the current length (a
    // cleared list) as well as the current length itself.
    var list = try reserveList(u32, 5);
    try std.testing.expectEqual(@as(usize, 5), list.capacity);
    list.appendSliceAssumeCapacity(&.{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(usize, 0), list.unusedCapacitySlice().len);
    list.clearRetainingCapacity();
    releaseList(u32, &list, 5);
    try std.testing.expectEqual(@as(usize, 0), list.capacity);
}
