//! Entity pools: the app's typed fixed pools (contract §7, decision 17).
//!
//! Every type in `Config.entities` gets one pool of
//! `limits.entities.count_per_type_max` slots, reserved at init. A slot is
//! free, live, or removed. `Effects.create` claims a free slot at once, so a
//! handler can store the handle it returns. `Effects.remove` only marks the
//! slot: handlers later in the same drain were built from a frame that still
//! names it, so they still reach the value. The tick frees removed slots after
//! the drain and before the build, bumping each slot's generation and zeroing
//! its bytes (CLAUDE.md §21), so a handle kept past removal is stale.
//!
//! The pool is not generic: values are `stride` bytes apart and the typed
//! side (`Effects`, `Cx.get`) casts. Removal releases nothing else; the app
//! releases `.owned` handles kept in the entity before removing it.
//!
//! Resource sketch at `.nano` (16 slots) for a 24-byte type: 384 bytes of
//! values plus 13 bytes of bookkeeping per slot. `create`, `remove`, and
//! `get` are O(1); `freeRemoved` visits only the slots removed this drain.

const std = @import("std");

const assert = std.debug.assert;

/// The alignment of every pool's value storage; a type that needs more is a
/// compile error in `App`.
pub const value_alignment = 16;

pub const SlotState = enum(u8) { free, live, removed };

/// Why a handle does not name a live or removed value.
pub const HandleProblem = enum { out_of_range, stale, never_created };

pub const Pool = struct {
    name: []const u8,
    stride: u32,
    bytes: []align(value_alignment) u8,
    generations: []u32,
    states: []SlotState,
    /// Free slots, used as a stack.
    free: []u32,
    free_count: u32,
    /// Slots marked by `remove` since the last `freeRemoved`.
    removed: []u32,
    removed_count: u32,

    pub fn initInPlace(
        self: *Pool,
        gpa: std.mem.Allocator,
        name: []const u8,
        stride: u32,
        count: u32,
    ) !void {
        assert(name.len > 0);
        assert(count > 0);
        const bytes_total = @as(usize, stride) * count;
        self.bytes = try gpa.alignedAlloc(u8, .fromByteUnits(value_alignment), bytes_total);
        errdefer gpa.free(self.bytes);
        self.generations = try gpa.alloc(u32, count);
        errdefer gpa.free(self.generations);
        self.states = try gpa.alloc(SlotState, count);
        errdefer gpa.free(self.states);
        self.free = try gpa.alloc(u32, count);
        errdefer gpa.free(self.free);
        self.removed = try gpa.alloc(u32, count);

        self.name = name;
        self.stride = stride;
        // Values are not zeroed here (CLAUDE.md §21): `create` writes each
        // one whole, and `freeRemoved` zeroes what it releases.
        @memset(self.generations, 0);
        @memset(self.states, .free);
        // Slot 0 on top, so slots are claimed in order.
        for (self.free, 0..) |*slot, index| slot.* = count - 1 - @as(u32, @intCast(index));
        self.free_count = count;
        self.removed_count = 0;
        assert(self.capacity() == count);
    }

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        assert(self.free_count + self.liveCount() <= self.capacity());
        gpa.free(self.removed);
        gpa.free(self.free);
        gpa.free(self.states);
        gpa.free(self.generations);
        gpa.free(self.bytes);
    }

    pub fn capacity(self: *const Pool) u32 {
        return @intCast(self.generations.len);
    }

    /// Claim a free slot, or null when every slot is live or removed.
    pub fn claim(self: *Pool) ?u32 {
        assert(self.free_count <= self.capacity());
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const slot = self.free[self.free_count];
        assert(slot < self.capacity());
        assert(self.states[slot] == .free);
        self.states[slot] = .live;
        return slot;
    }

    /// Whether `slot` at `generation` names a value: live, or removed this
    /// drain and not yet freed.
    pub fn check(self: *const Pool, slot: u32, generation: u32) ?HandleProblem {
        if (slot >= self.capacity()) return .out_of_range;
        if (self.generations[slot] != generation) return .stale;
        if (self.states[slot] == .free) return .never_created;
        return null;
    }

    /// Mark a live slot for `freeRemoved`. Returns false when it is already
    /// marked: removing twice in one drain.
    pub fn markRemoved(self: *Pool, slot: u32) bool {
        assert(slot < self.capacity());
        assert(self.states[slot] != .free);
        if (self.states[slot] == .removed) return false;
        assert(self.removed_count < self.capacity());
        self.states[slot] = .removed;
        self.removed[self.removed_count] = slot;
        self.removed_count += 1;
        return true;
    }

    /// Free every slot marked since the last call: zero it, bump its
    /// generation, and return it to the free stack. Runs between the drain
    /// and the build, when no handler or build reads entity values.
    pub fn freeRemoved(self: *Pool) void {
        assert(self.removed_count <= self.capacity());
        for (self.removed[0..self.removed_count]) |slot| {
            assert(self.states[slot] == .removed);
            assert(self.free_count < self.capacity());
            @memset(self.valueBytes(slot), 0);
            // Wraps after 2^32 reuses of one slot; a handle that old is
            // beyond any realistic lifetime.
            self.generations[slot] +%= 1;
            self.states[slot] = .free;
            self.free[self.free_count] = slot;
            self.free_count += 1;
        }
        self.removed_count = 0;
    }

    pub fn valueBytes(self: *const Pool, slot: u32) []u8 {
        assert(slot < self.capacity());
        const start = @as(usize, slot) * self.stride;
        return self.bytes[start..][0..self.stride];
    }

    fn liveCount(self: *const Pool) u32 {
        var count: u32 = 0;
        for (self.states) |state| count += @intFromBool(state != .free);
        return count;
    }
};

test "a pool fills exactly, refuses one more, and reuses a freed slot one generation on" {
    // Goal: the capacity, staleness, and reuse rules. Method: fill a
    // three-slot pool, claim a fourth, remove the middle slot, check that
    // its old handle still resolves until the free, then not after; reclaim
    // it and check that it is zeroed with the next generation.
    var pool: Pool = undefined;
    try pool.initInPlace(std.testing.allocator, "Test", 16, 3);
    defer pool.deinit(std.testing.allocator);

    for (0..3) |expected| {
        const slot = pool.claim().?;
        try std.testing.expectEqual(@as(u32, @intCast(expected)), slot);
        @memset(pool.valueBytes(slot), 0xab);
    }
    try std.testing.expectEqual(@as(?u32, null), pool.claim());

    try std.testing.expect(pool.markRemoved(1));
    try std.testing.expect(!pool.markRemoved(1));
    // Removed but not yet freed: a handler later in the drain still reaches it.
    try std.testing.expectEqual(@as(?HandleProblem, null), pool.check(1, 0));
    try std.testing.expectEqual(@as(?u32, null), pool.claim());

    pool.freeRemoved();
    try std.testing.expectEqual(@as(?HandleProblem, .stale), pool.check(1, 0));
    try std.testing.expectEqual(@as(?HandleProblem, .never_created), pool.check(1, 1));
    try std.testing.expectEqual(@as(?HandleProblem, .out_of_range), pool.check(3, 0));

    try std.testing.expectEqual(@as(?u32, 1), pool.claim());
    try std.testing.expectEqual(@as(?HandleProblem, null), pool.check(1, 1));
    for (pool.valueBytes(1)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (pool.valueBytes(0)) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    try std.testing.expectEqual(@as(?u32, null), pool.claim());
}
