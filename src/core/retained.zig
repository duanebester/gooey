//! The retained store: size-class slabs, generation-checked handles, and the
//! sweep (contract §3).
//!
//! Each slab is one reservation of `slot_count × stride` bytes plus metadata,
//! made at init. `retain` finds an entry by (element id, type) through an
//! open-addressing index, or claims a free slot and runs the type's `init`.
//! The sweep after each build releases `.frame` entries untouched for
//! `sweep_delay_frames` and `.scope` entries whose scope was not rendered;
//! `.owned` entries leave only through `release`.
//!
//! Performance sketch at `.standard` (2,048 / 1,024 / 256 / 64 slots): 0.9 MiB
//! of slab bytes plus 32 B of metadata and 16 B of index per slot (0.16 MiB).
//! A lookup hashes once and probes the index linearly; the index is at most
//! half full, so the expected probe count is under 2. The sweep visits every
//! slot once per tick (3,392 at `.standard`, a few microseconds), and rebuilds
//! a slab's index only when it released an entry.

const std = @import("std");
const id_mod = @import("id.zig");
const handler_mod = @import("handler.zig");

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;

pub const Lifetime = union(enum) {
    frame,
    scope: ElementId,
    owned,
};

/// A generation-checked handle to retained state. Handles are the same type
/// as entity handles, so a retained engine can be a handler target.
pub fn Handle(comptime T: type) type {
    return handler_mod.Entity(T);
}

pub const slab_alignment = 16;

pub const size_classes = [_]u32{ 64, 256, 1024, 4096 };

/// The size class index for `T`; a type above the largest class is a
/// compile error, and it belongs in a dedicated pool.
pub fn classOf(comptime T: type) u8 {
    if (@alignOf(T) > slab_alignment) {
        @compileError("retained type " ++ @typeName(T) ++ " needs alignment above 16");
    }
    for (size_classes, 0..) |size, index| {
        if (@sizeOf(T) <= size) return @intCast(index);
    }
    @compileError("retained type " ++ @typeName(T) ++ " is larger than 4 KiB; " ++
        "larger state uses a dedicated pool, such as the text engines");
}

const Meta = struct {
    id: ElementId,
    type_id: usize,
    lifetime: std.meta.Tag(Lifetime),
    scope: ElementId,
    touched_frame: u64,
    in_use: bool,
};

/// One fixed pool of equal-stride slots.
pub const Slab = struct {
    name: []const u8,
    stride: u32,
    bytes: []align(slab_alignment) u8,
    meta: []Meta,
    generations: []u32,
    /// Free slots, used as a stack.
    free: []u32,
    free_count: u32,
    /// Open addressing over slots: 0 is empty, else slot + 1.
    index: []u32,

    pub fn initInPlace(
        self: *Slab,
        gpa: std.mem.Allocator,
        name: []const u8,
        stride: u32,
        slot_count: u32,
    ) !void {
        assert(stride % slab_alignment == 0);
        assert(slot_count > 0);
        self.name = name;
        self.stride = stride;
        self.bytes = try gpa.alignedAlloc(
            u8,
            .fromByteUnits(slab_alignment),
            @as(usize, stride) * slot_count,
        );
        errdefer gpa.free(self.bytes);
        self.meta = try gpa.alloc(Meta, slot_count);
        errdefer gpa.free(self.meta);
        self.generations = try gpa.alloc(u32, slot_count);
        errdefer gpa.free(self.generations);
        self.free = try gpa.alloc(u32, slot_count);
        errdefer gpa.free(self.free);
        self.index = try gpa.alloc(u32, std.math.ceilPowerOfTwoAssert(u32, slot_count * 2));
        @memset(self.index, 0);
        @memset(self.generations, 0);
        for (self.meta, 0..) |*meta, slot| {
            meta.in_use = false;
            self.free[slot_count - 1 - slot] = @intCast(slot);
        }
        self.free_count = slot_count;
        assert(self.index.len >= slot_count * 2);
    }

    pub fn deinit(self: *Slab, gpa: std.mem.Allocator) void {
        assert(self.free_count <= self.meta.len);
        gpa.free(self.index);
        gpa.free(self.free);
        gpa.free(self.generations);
        gpa.free(self.meta);
        gpa.free(self.bytes);
        self.* = undefined;
    }

    pub fn slotCount(self: *const Slab) u32 {
        return @intCast(self.meta.len);
    }

    pub fn liveCount(self: *const Slab) u32 {
        assert(self.free_count <= self.meta.len);
        return self.slotCount() - self.free_count;
    }

    pub fn slotBytes(self: *const Slab, slot: u32) []align(slab_alignment) u8 {
        assert(slot < self.meta.len);
        const start = @as(usize, slot) * self.stride;
        return @alignCast(self.bytes[start..][0..self.stride]);
    }

    /// The slot holding (`id`, `type_id`), if any.
    pub fn find(self: *const Slab, id: ElementId, type_id: usize) ?u32 {
        const mask: u32 = @intCast(self.index.len - 1);
        var position = hashKey(id, type_id) & mask;
        var probes: u32 = 0;
        while (probes < self.index.len) : (probes += 1) {
            const entry = self.index[position];
            if (entry == 0) return null;
            const meta = &self.meta[entry - 1];
            assert(meta.in_use);
            if (meta.id == id and meta.type_id == type_id) return entry - 1;
            position = (position + 1) & mask;
        }
        unreachable; // The index is at most half full.
    }

    /// Claim a free slot for (`id`, `type_id`) and index it. The caller
    /// initializes the slot's bytes.
    pub fn claim(self: *Slab, id: ElementId, type_id: usize, lifetime: Lifetime, frame: u64) u32 {
        assert(self.find(id, type_id) == null);
        if (self.free_count == 0) {
            std.debug.panic("retained pool '{s}' exhausted ({d} slots): capacity {d}, " ++
                "{d} in use, 1 requested, frame {d}. Raise ResourceLimits.retained or .text.", .{
                self.name,
                self.meta.len,
                self.meta.len,
                self.meta.len,
                frame,
            });
        }
        self.free_count -= 1;
        const slot = self.free[self.free_count];
        assert(!self.meta[slot].in_use);
        self.meta[slot] = .{
            .id = id,
            .type_id = type_id,
            .lifetime = lifetime,
            .scope = if (lifetime == .scope) lifetime.scope else .root,
            .touched_frame = frame,
            .in_use = true,
        };
        self.insertIndex(slot);
        return slot;
    }

    pub fn touch(self: *Slab, slot: u32, lifetime: Lifetime, frame: u64) void {
        const meta = &self.meta[slot];
        assert(meta.in_use);
        assert(meta.lifetime == std.meta.activeTag(lifetime));
        if (lifetime == .scope) assert(meta.scope == lifetime.scope);
        meta.touched_frame = frame;
    }

    /// Release `slot`; its generation advances so old handles fail.
    pub fn releaseSlot(self: *Slab, slot: u32) void {
        assert(self.meta[slot].in_use);
        assert(self.free_count < self.meta.len);
        self.meta[slot].in_use = false;
        self.generations[slot] +%= 1;
        // Zero the bytes before another owner can read them (CLAUDE.md §21).
        @memset(self.slotBytes(slot), 0);
        self.free[self.free_count] = slot;
        self.free_count += 1;
    }

    /// Release expired `.frame` entries and `.scope` entries whose scope was
    /// not rendered this frame. `rendered` answers whether a scope id was
    /// rendered. Returns the number released.
    pub fn sweep(self: *Slab, frame: u64, delay_frames: u32, rendered: anytype) u32 {
        var released: u32 = 0;
        for (self.meta, 0..) |*meta, slot| {
            if (!meta.in_use) continue;
            const expired = switch (meta.lifetime) {
                .frame => frame - meta.touched_frame > delay_frames,
                .scope => !rendered.contains(meta.scope),
                .owned => false,
            };
            if (expired) {
                self.releaseSlot(@intCast(slot));
                released += 1;
            }
        }
        if (released > 0) self.rebuildIndex();
        assert(released <= self.meta.len);
        return released;
    }

    fn insertIndex(self: *Slab, slot: u32) void {
        const meta = &self.meta[slot];
        const mask: u32 = @intCast(self.index.len - 1);
        var position = hashKey(meta.id, meta.type_id) & mask;
        var probes: u32 = 0;
        while (self.index[position] != 0) : (probes += 1) {
            assert(probes < self.index.len);
            position = (position + 1) & mask;
        }
        self.index[position] = slot + 1;
    }

    fn rebuildIndex(self: *Slab) void {
        @memset(self.index, 0);
        for (self.meta, 0..) |*meta, slot| {
            if (meta.in_use) self.insertIndex(@intCast(slot));
        }
    }
};

fn hashKey(id: ElementId, type_id: usize) u32 {
    const mixed = @backingInt(id) ^ (@as(u64, type_id) *% 0x9e3779b97f4a7c15);
    return @truncate(mixed ^ (mixed >> 32));
}

pub const RetainedCapacity = struct {
    slot_counts: [size_classes.len]u32,
    sweep_delay_frames: u32,
};

/// The four size-class slabs.
pub const Retained = struct {
    slabs: [size_classes.len]Slab,
    sweep_delay_frames: u32,

    pub fn initInPlace(
        self: *Retained,
        gpa: std.mem.Allocator,
        capacity: *const RetainedCapacity,
    ) !void {
        assert(capacity.sweep_delay_frames > 0);
        const names = [_][]const u8{
            "retained 64 B",
            "retained 256 B",
            "retained 1 KiB",
            "retained 4 KiB",
        };
        var initialized: u32 = 0;
        errdefer for (self.slabs[0..initialized]) |*slab| slab.deinit(gpa);
        for (&self.slabs, size_classes, capacity.slot_counts, names) |*slab, size, count, name| {
            try slab.initInPlace(gpa, name, size, count);
            initialized += 1;
        }
        self.sweep_delay_frames = capacity.sweep_delay_frames;
        assert(initialized == size_classes.len);
    }

    pub fn deinit(self: *Retained, gpa: std.mem.Allocator) void {
        assert(self.sweep_delay_frames > 0);
        for (&self.slabs) |*slab| slab.deinit(gpa);
    }

    /// Find or create `T` for `id`. See `Cx.retain` for the public contract.
    pub fn retain(
        self: *Retained,
        comptime T: type,
        id: ElementId,
        lifetime: Lifetime,
        comptime init: fn (value: *T) void,
        frame: u64,
    ) Handle(T) {
        assert(id.isKeyed());
        const slab = &self.slabs[comptime classOf(T)];
        const type_id = handler_mod.typeId(T);
        if (slab.find(id, type_id)) |slot| {
            slab.touch(slot, lifetime, frame);
            return .{ .slot = slot, .generation = slab.generations[slot] };
        }
        const slot = slab.claim(id, type_id, lifetime, frame);
        const value: *T = @ptrCast(slab.slotBytes(slot).ptr);
        init(value);
        return .{ .slot = slot, .generation = slab.generations[slot] };
    }

    pub fn get(self: *Retained, comptime T: type, handle: Handle(T)) *T {
        const slab = &self.slabs[comptime classOf(T)];
        assert(handle.slot < slab.slotCount());
        assert(slab.meta[handle.slot].in_use);
        if (slab.generations[handle.slot] != handle.generation) {
            std.debug.panic("stale retained handle to {s}: slot {d} generation {d}, now {d}", .{
                @typeName(T),
                handle.slot,
                handle.generation,
                slab.generations[handle.slot],
            });
        }
        assert(slab.meta[handle.slot].type_id == handler_mod.typeId(T));
        return @ptrCast(slab.slotBytes(handle.slot).ptr);
    }

    pub fn release(self: *Retained, comptime T: type, handle: Handle(T)) void {
        _ = self.get(T, handle);
        const slab = &self.slabs[comptime classOf(T)];
        assert(slab.meta[handle.slot].lifetime == .owned);
        slab.releaseSlot(handle.slot);
        slab.rebuildIndex();
    }

    pub fn sweep(self: *Retained, frame: u64, rendered: anytype) u32 {
        var released: u32 = 0;
        for (&self.slabs) |*slab| released += slab.sweep(frame, self.sweep_delay_frames, rendered);
        return released;
    }
};

test "retained entries live by lifetime and old handles fail" {
    // Goal: the three lifetimes and generation checks. Method: retain one
    // entry per lifetime, sweep across frames, and compare handles.
    const Counter = struct {
        value: u32,
        fn init(self: *@This()) void {
            self.value = 7;
        }
    };
    var retained: Retained = undefined;
    try retained.initInPlace(std.testing.allocator, &.{
        .slot_counts = .{ 4, 1, 1, 1 },
        .sweep_delay_frames = 2,
    });
    defer retained.deinit(std.testing.allocator);
    const parent = ElementId.root.child(.{ .name = "parent" });
    const frame_id = parent.child(.{ .name = "f" });
    const scope_id = parent.child(.{ .name = "s" });
    const owned_id = parent.child(.{ .name = "o" });
    const frame_handle = retained.retain(Counter, frame_id, .frame, Counter.init, 1);
    _ = retained.retain(Counter, scope_id, .{ .scope = parent }, Counter.init, 1);
    const owned = retained.retain(Counter, owned_id, .owned, Counter.init, 1);
    retained.get(Counter, frame_handle).value += 1;
    try std.testing.expectEqual(@as(u32, 8), retained.get(Counter, frame_handle).value);
    const Rendered = struct {
        scope: ?ElementId,
        pub fn contains(self: @This(), id: ElementId) bool {
            return self.scope != null and self.scope.? == id;
        }
    };
    // Frame 3: the frame entry is within its delay; the scope is rendered.
    try std.testing.expectEqual(@as(u32, 0), retained.sweep(3, Rendered{ .scope = parent }));
    // Frame 4: the frame entry expires and the scope is gone.
    try std.testing.expectEqual(@as(u32, 2), retained.sweep(4, Rendered{ .scope = null }));
    const again = retained.retain(Counter, frame_id, .frame, Counter.init, 4);
    try std.testing.expect(again.generation != frame_handle.generation);
    try std.testing.expectEqual(@as(u32, 7), retained.get(Counter, again).value);
    retained.release(Counter, owned);
    try std.testing.expectEqual(@as(u32, 1), retained.slabs[0].liveCount());
}
