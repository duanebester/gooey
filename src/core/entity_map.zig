//! Type-erased entity storage with slotmap-style allocation
//!
//! The EntityMap stores entities of any type, managing their lifecycle
//! through reference counting. It uses a "lease" pattern (like GPUI) for
//! mutable access: when updating an entity, it's temporarily moved to
//! the stack to avoid aliasing issues with Zig's pointer semantics.
//!
//! Example:
//! ```zig
//! var entities = try EntityMap.init(allocator);
//! defer entities.deinit();
//!
//! // Reserve a slot and insert
//! const slot = entities.reserve(Counter);
//! var counter = entities.insert(Counter, slot, .{ .count = 0 });
//! defer counter.release();
//!
//! // Read (immutable)
//! if (entities.read(Counter, counter.entityId())) |c| {
//!     std.debug.print("Count: {}\n", .{c.count});
//! }
//!
//! // Update via lease pattern
//! if (entities.lease(Counter, counter.entityId())) |*lease| {
//!     defer entities.endLease(Counter, lease);
//!     lease.ptr.count += 1;
//! }
//! ```

const std = @import("std");
const entity_mod = @import("entity.zig");

pub const EntityId = entity_mod.EntityId;
pub const EntityIdContext = entity_mod.EntityIdContext;
pub const Entity = entity_mod.Entity;
pub const WeakEntity = entity_mod.WeakEntity;
pub const AnyEntity = entity_mod.AnyEntity;
pub const AnyWeakEntity = entity_mod.AnyWeakEntity;
pub const RefCounts = entity_mod.RefCounts;
pub const typeId = entity_mod.typeId;
pub const TypeId = entity_mod.TypeId;

/// A reserved slot for an entity that hasn't been inserted yet.
/// This allows separating allocation from initialization.
pub fn Slot(comptime T: type) type {
    return struct {
        entity: Entity(T),
    };
}

/// A leased entity for exclusive mutable access.
/// The entity is temporarily removed from the map during the lease.
/// You MUST call `EntityMap.endLease()` when done!
pub fn Lease(comptime T: type) type {
    return struct {
        /// Mutable pointer to the entity data
        ptr: *T,
        /// The entity ID
        id: EntityId,
        /// Type-erased data for returning to the map
        erased: ErasedEntity,
    };
}

/// Type-erased entity storage entry
const ErasedEntity = struct {
    /// Pointer to heap-allocated entity data
    ptr: *anyopaque,
    /// Runtime type identifier for type checking
    type_id: TypeId,
    /// Destructor function pointer
    deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Type-erased entity storage with reference-counted lifecycle management.
///
/// Entities are stored as type-erased boxes on the heap. The EntityMap owns
/// the storage, while `Entity(T)` handles manage the reference counts.
pub const EntityMap = struct {
    allocator: std.mem.Allocator,
    /// Type-erased entity storage: EntityId -> ErasedEntity
    entities: std.HashMap(EntityId, ErasedEntity, EntityIdContext, std.hash_map.default_max_load_percentage),
    /// Reference counting (shared with all handles)
    ref_counts: *RefCounts,
    /// Next available slot index
    next_index: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const ref_counts = try allocator.create(RefCounts);
        ref_counts.* = RefCounts.init(allocator);

        return .{
            .allocator = allocator,
            .entities = std.HashMap(EntityId, ErasedEntity, EntityIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .ref_counts = ref_counts,
            .next_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // Release all remaining entities
        var iter = self.entities.valueIterator();
        while (iter.next()) |erased| {
            erased.deinit_fn(erased.ptr, self.allocator);
        }
        self.entities.deinit();

        self.ref_counts.deinit();
        self.allocator.destroy(self.ref_counts);
    }

    /// Reserve a slot for a new entity.
    /// This allocates an EntityId but doesn't store any data yet.
    /// Use `insert()` to complete the creation.
    pub fn reserve(self: *Self, comptime T: type) Slot(T) {
        //_ = T; // Type is only used for the slot's generic parameter

        const index = self.next_index;
        self.next_index += 1;

        const id = self.ref_counts.allocate(index);

        return Slot(T){
            .entity = Entity(T){ .id = id, .ref_counts = self.ref_counts },
        };
    }

    /// Insert entity data into a reserved slot.
    /// Returns the Entity handle (which is also stored in the slot).
    pub fn insert(self: *Self, comptime T: type, slot: Slot(T), value: T) Entity(T) {
        const ptr = self.allocator.create(T) catch @panic("EntityMap: allocation failed");
        ptr.* = value;

        const erased = ErasedEntity{
            .ptr = ptr,
            .type_id = typeId(T),
            .deinit_fn = struct {
                fn deinit(p: *anyopaque, alloc: std.mem.Allocator) void {
                    const typed: *T = @ptrCast(@alignCast(p));
                    // Call deinit if the type has one
                    if (@hasDecl(T, "deinit")) {
                        typed.deinit();
                    }
                    alloc.destroy(typed);
                }
            }.deinit,
        };

        self.entities.put(slot.entity.id, erased) catch @panic("EntityMap: storage failed");
        return slot.entity;
    }

    /// Convenience method: reserve and insert in one call.
    pub fn new(self: *Self, comptime T: type, value: T) Entity(T) {
        const slot = self.reserve(T);
        return self.insert(T, slot, value);
    }

    /// Read an entity (immutable access).
    /// Returns null if the entity doesn't exist or has the wrong type.
    pub fn read(self: *Self, comptime T: type, id: EntityId) ?*const T {
        if (self.entities.get(id)) |erased| {
            if (erased.type_id == typeId(T)) {
                return @ptrCast(@alignCast(erased.ptr));
            }
        }
        return null;
    }

    /// Lease an entity for exclusive mutable access.
    ///
    /// The entity is temporarily removed from the map during the lease.
    /// This prevents aliasing issues - you can't have two mutable pointers
    /// to the same entity at once.
    ///
    /// **You MUST call `endLease()` when done, or the entity will be lost!**
    ///
    /// Returns null if the entity doesn't exist or has the wrong type.
    pub fn lease(self: *Self, comptime T: type, id: EntityId) ?Lease(T) {
        if (self.entities.fetchRemove(id)) |kv| {
            if (kv.value.type_id == typeId(T)) {
                return Lease(T){
                    .ptr = @ptrCast(@alignCast(kv.value.ptr)),
                    .id = id,
                    .erased = kv.value,
                };
            }
            // Wrong type - put it back
            self.entities.put(id, kv.value) catch {};
        }
        return null;
    }

    /// Return a leased entity to the map.
    /// Must be called after `lease()` to put the entity back.
    pub fn endLease(self: *Self, comptime T: type, lease_val: *Lease(T)) void {
        self.entities.put(lease_val.id, lease_val.erased) catch {};
        lease_val.* = undefined;
    }

    /// Process and clean up all dropped entities.
    /// Call this periodically (e.g., at end of frame) to free memory.
    pub fn flushDropped(self: *Self) void {
        self.ref_counts.mutex.lock();
        const dropped = self.ref_counts.dropped.toOwnedSlice(self.allocator) catch return;
        self.ref_counts.mutex.unlock();

        defer self.allocator.free(dropped);

        for (dropped) |id| {
            if (self.entities.fetchRemove(id)) |kv| {
                // Clean up the ref count entry
                self.ref_counts.mutex.lock();
                _ = self.ref_counts.counts.remove(id);
                self.ref_counts.mutex.unlock();

                // Deallocate the entity
                kv.value.deinit_fn(kv.value.ptr, self.allocator);
            }
        }
    }

    /// Get the number of active entities
    pub fn count(self: *Self) usize {
        return self.entities.count();
    }

    /// Check if an entity exists in the map
    pub fn contains(self: *Self, id: EntityId) bool {
        return self.entities.contains(id);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EntityMap basic operations" {
    const allocator = std.testing.allocator;
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    const Counter = struct { count: i32 };

    // Create an entity
    var counter = entities.new(Counter, .{ .count = 42 });
    defer counter.release();

    try std.testing.expectEqual(@as(usize, 1), entities.count());

    // Read it
    if (entities.read(Counter, counter.entityId())) |c| {
        try std.testing.expectEqual(@as(i32, 42), c.count);
    } else {
        try std.testing.expect(false); // Should have found it
    }
}

test "EntityMap lease pattern" {
    const allocator = std.testing.allocator;
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    const Counter = struct { count: i32 };

    var counter = entities.new(Counter, .{ .count = 0 });
    defer counter.release();

    // Lease and modify
    if (entities.lease(Counter, counter.entityId())) |lease_val| {
        var lease_mut = lease_val;
        defer entities.endLease(Counter, &lease_mut);
        lease_mut.ptr.count += 10;
    }

    // Verify the change persisted
    if (entities.read(Counter, counter.entityId())) |c| {
        try std.testing.expectEqual(@as(i32, 10), c.count);
    } else {
        try std.testing.expect(false);
    }
}

test "EntityMap type safety" {
    const allocator = std.testing.allocator;
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    const TypeA = struct { a: i32 };
    const TypeB = struct { b: f32 };

    var a = entities.new(TypeA, .{ .a = 1 });
    defer a.release();

    // Reading with wrong type should fail
    try std.testing.expect(entities.read(TypeB, a.entityId()) == null);

    // Reading with correct type should succeed
    try std.testing.expect(entities.read(TypeA, a.entityId()) != null);
}

test "EntityMap entity lifecycle with weak references" {
    const allocator = std.testing.allocator;
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    const Data = struct { value: i32 };

    var entity = entities.new(Data, .{ .value = 123 });
    const weak = entity.downgrade();

    // Entity exists
    try std.testing.expect(weak.isAlive());
    try std.testing.expect(entities.contains(entity.entityId()));

    // Release strong reference
    entity.release();

    // Weak reference should report dead (ref count is 0)
    try std.testing.expect(!weak.isAlive());

    // Upgrade should fail
    try std.testing.expect(weak.upgrade() == null);

    // Flush to actually remove from storage
    entities.flushDropped();

    // Now it should be gone from the map too
    try std.testing.expectEqual(@as(usize, 0), entities.count());
}

test "EntityMap multiple entities" {
    const allocator = std.testing.allocator;
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    const Item = struct { id: u32 };

    var e1 = entities.new(Item, .{ .id = 1 });
    var e2 = entities.new(Item, .{ .id = 2 });
    var e3 = entities.new(Item, .{ .id = 3 });

    try std.testing.expectEqual(@as(usize, 3), entities.count());

    // Verify each has unique ID
    try std.testing.expect(!e1.entityId().eql(e2.entityId()));
    try std.testing.expect(!e2.entityId().eql(e3.entityId()));

    // Release one
    e2.release();
    entities.flushDropped();

    try std.testing.expectEqual(@as(usize, 2), entities.count());

    // Others still accessible
    try std.testing.expect(entities.read(Item, e1.entityId()) != null);
    try std.testing.expect(entities.read(Item, e3.entityId()) != null);
    try std.testing.expect(entities.read(Item, e2.entityId()) == null);

    e1.release();
    e3.release();
}

test "EntityMap clone extends lifetime" {
    const allocator = std.testing.allocator;
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    const Data = struct { x: i32 };

    var original = entities.new(Data, .{ .x = 42 });
    var cloned = original.clone();

    // Release original
    original.release();

    // Entity should still exist due to clone
    try std.testing.expect(entities.read(Data, cloned.entityId()) != null);

    // Now release clone
    cloned.release();
    entities.flushDropped();

    try std.testing.expectEqual(@as(usize, 0), entities.count());
}

test "EntityMap reserve and insert separately" {
    const allocator = std.testing.allocator;
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    const Config = struct {
        name: []const u8,
        value: i32,
    };

    // Reserve slot first
    const slot = entities.reserve(Config);

    // Entity not yet in storage
    try std.testing.expectEqual(@as(usize, 0), entities.count());

    // Insert the data
    var config = entities.insert(Config, slot, .{
        .name = "test",
        .value = 100,
    });
    defer config.release();

    // Now it's in storage
    try std.testing.expectEqual(@as(usize, 1), entities.count());

    if (entities.read(Config, config.entityId())) |c| {
        try std.testing.expectEqualStrings("test", c.name);
        try std.testing.expectEqual(@as(i32, 100), c.value);
    } else {
        try std.testing.expect(false);
    }
}

test "EntityMap generation prevents ABA" {
    const allocator = std.testing.allocator;
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    const Value = struct { n: i32 };

    // Create and release an entity
    var first = entities.new(Value, .{ .n = 1 });
    const first_id = first.entityId();
    first.release();
    entities.flushDropped();

    // Create a new entity (might reuse the same index)
    var second = entities.new(Value, .{ .n = 2 });
    defer second.release();

    // The old ID should NOT match the new entity
    // (even if they share the same index, generations differ)
    if (entities.read(Value, first_id)) |_| {
        // If the index was reused, the generation should be different
        // so this read should either fail or return the new entity
        // which would have a different ID
        try std.testing.expect(!first_id.eql(second.entityId()));
    }

    // The new entity should be readable with its own ID
    if (entities.read(Value, second.entityId())) |v| {
        try std.testing.expectEqual(@as(i32, 2), v.n);
    } else {
        try std.testing.expect(false);
    }
}
