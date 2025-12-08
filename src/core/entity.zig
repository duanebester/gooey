//! Entity system for Gooey - reactive state management
//!
//! This module provides the foundation for GPUI-style reactive entities.
//! Entities are reference-counted objects that can be observed and updated reactively.
//!
//! Key types:
//! - `EntityId`: Unique identifier with generation for ABA safety (slotmap-style)
//! - `Entity(T)`: Strong, typed handle that keeps the entity alive
//! - `WeakEntity(T)`: Weak reference that doesn't prevent release
//! - `AnyEntity`: Type-erased strong handle
//! - `AnyWeakEntity`: Type-erased weak handle
//!
//! The entity system is separate from:
//! - `ElementId`: Runtime identity for interactive UI elements (hit testing, focus)
//! - `LayoutId`: Hash-based names for layout element lookup
//!
//! Example:
//! ```zig
//! const Counter = struct { count: i32 };
//!
//! // Create via EntityMap (owned by App)
//! const slot = entities.reserve(Counter);
//! const counter = entities.insert(Counter, slot, .{ .count = 0 });
//!
//! // Read
//! if (entities.read(Counter, counter.entityId())) |c| {
//!     std.debug.print("Count: {}\n", .{c.count});
//! }
//!
//! // Update via lease pattern
//! if (entities.lease(Counter, counter.entityId())) |*lease| {
//!     lease.ptr.count += 1;
//!     entities.endLease(Counter, lease);
//! }
//! ```

const std = @import("std");

/// Unique identifier for entities across the application.
///
/// Uses a slotmap-style design with index + generation counter.
/// The generation prevents ABA problems: if an entity is released and
/// a new one allocated at the same index, the old handles won't match.
pub const EntityId = struct {
    index: u32,
    generation: u32,

    const Self = @This();

    pub fn eql(self: Self, other: Self) bool {
        return self.index == other.index and self.generation == other.generation;
    }

    /// Hash for use in hash maps
    pub fn hash(self: Self) u64 {
        return @as(u64, self.index) | (@as(u64, self.generation) << 32);
    }

    /// Format for debug printing
    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("EntityId({},{})", .{ self.index, self.generation });
    }

    /// Invalid/null entity ID
    pub const invalid = Self{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn isValid(self: Self) bool {
        return self.index != std.math.maxInt(u32);
    }
};

/// Context for EntityId in hash maps
pub const EntityIdContext = struct {
    pub fn hash(_: EntityIdContext, id: EntityId) u64 {
        return id.hash();
    }

    pub fn eql(_: EntityIdContext, a: EntityId, b: EntityId) bool {
        return a.eql(b);
    }
};

/// A strong, typed reference to an entity.
///
/// As long as any `Entity(T)` handle exists, the entity stays alive.
/// When the last strong reference is released, the entity is marked for cleanup.
///
/// Entity handles are NOT automatically released - you must call `release()`
/// or use `defer entity.release()` when done.
pub fn Entity(comptime T: type) type {
    return struct {
        id: EntityId,
        ref_counts: *RefCounts,

        const Self = @This();

        /// Downgrade to a weak reference that doesn't prevent release
        pub fn downgrade(self: Self) WeakEntity(T) {
            return .{ .id = self.id, .ref_counts = self.ref_counts };
        }

        /// Get the entity ID
        pub fn entityId(self: Self) EntityId {
            return self.id;
        }

        /// Clone this handle (increments reference count)
        pub fn clone(self: Self) Self {
            self.ref_counts.increment(self.id);
            return .{ .id = self.id, .ref_counts = self.ref_counts };
        }

        /// Release this handle (decrements reference count)
        /// The entity is cleaned up when the last strong reference is released.
        pub fn release(self: *Self) void {
            _ = self.ref_counts.decrement(self.id);
            self.* = undefined;
        }

        /// Convert to a type-erased handle
        pub fn intoAny(self: Self) AnyEntity {
            return .{
                .id = self.id,
                .ref_counts = self.ref_counts,
                .type_id = typeId(T),
                .type_name = @typeName(T),
            };
        }
    };
}

/// A weak reference that doesn't prevent the entity from being released.
///
/// Useful for:
/// - Breaking reference cycles
/// - Caching references that shouldn't keep entities alive
/// - Observer callbacks
pub fn WeakEntity(comptime T: type) type {
    return struct {
        id: EntityId,
        ref_counts: *RefCounts,

        const Self = @This();

        /// Try to upgrade to a strong reference.
        /// Returns null if the entity has been released.
        pub fn upgrade(self: Self) ?Entity(T) {
            if (self.ref_counts.tryIncrement(self.id)) {
                return Entity(T){ .id = self.id, .ref_counts = self.ref_counts };
            }
            return null;
        }

        pub fn entityId(self: Self) EntityId {
            return self.id;
        }

        /// Check if the entity is still alive (without upgrading)
        pub fn isAlive(self: Self) bool {
            return self.ref_counts.isAlive(self.id);
        }

        /// Convert to type-erased weak handle
        pub fn intoAny(self: Self) AnyWeakEntity {
            return .{
                .id = self.id,
                .ref_counts = self.ref_counts,
                .type_id = typeId(T),
            };
        }
    };
}

/// Type-erased strong entity handle.
///
/// Useful when you need to store handles to entities of different types
/// in the same collection.
pub const AnyEntity = struct {
    id: EntityId,
    ref_counts: *RefCounts,
    type_id: TypeId,
    type_name: []const u8,

    const Self = @This();

    pub fn entityId(self: Self) EntityId {
        return self.id;
    }

    pub fn downgrade(self: Self) AnyWeakEntity {
        return .{
            .id = self.id,
            .ref_counts = self.ref_counts,
            .type_id = self.type_id,
        };
    }

    pub fn clone(self: Self) Self {
        self.ref_counts.increment(self.id);
        return self;
    }

    pub fn release(self: *Self) void {
        _ = self.ref_counts.decrement(self.id);
        self.* = undefined;
    }

    /// Try to downcast to a typed handle
    pub fn downcast(self: Self, comptime T: type) ?Entity(T) {
        if (self.type_id == typeId(T)) {
            return Entity(T){ .id = self.id, .ref_counts = self.ref_counts };
        }
        return null;
    }
};

/// Type-erased weak entity handle.
pub const AnyWeakEntity = struct {
    id: EntityId,
    ref_counts: *RefCounts,
    type_id: TypeId,

    const Self = @This();

    pub fn entityId(self: Self) EntityId {
        return self.id;
    }

    pub fn upgrade(self: Self) ?AnyEntity {
        if (self.ref_counts.tryIncrement(self.id)) {
            return AnyEntity{
                .id = self.id,
                .ref_counts = self.ref_counts,
                .type_id = self.type_id,
                .type_name = "", // Lost in type erasure
            };
        }
        return null;
    }

    pub fn isAlive(self: Self) bool {
        return self.ref_counts.isAlive(self.id);
    }

    pub fn downcast(self: Self, comptime T: type) ?WeakEntity(T) {
        if (self.type_id == typeId(T)) {
            return WeakEntity(T){ .id = self.id, .ref_counts = self.ref_counts };
        }
        return null;
    }
};

/// Type identifier for runtime type checking
pub const TypeId = usize;

/// Get the TypeId for a type (compile-time stable address)
pub fn typeId(comptime T: type) TypeId {
    return @intFromPtr(&struct {
        var x: T = undefined;
    }.x);
}

/// Thread-safe reference counting for entities.
///
/// Tracks the number of strong references to each entity.
/// When the count drops to zero, the entity ID is added to `dropped`
/// for later cleanup by the EntityMap owner.
pub const RefCounts = struct {
    allocator: std.mem.Allocator,
    /// Reference counts by EntityId
    counts: std.HashMap(EntityId, u32, EntityIdContext, std.hash_map.default_max_load_percentage),
    /// Generation counter for each slot index (for reuse)
    generations: std.AutoArrayHashMap(u32, u32),
    /// Entity IDs that have been dropped (ref count hit zero)
    dropped: std.ArrayListUnmanaged(EntityId),
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .counts = std.HashMap(EntityId, u32, EntityIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .generations = std.AutoArrayHashMap(u32, u32).init(allocator),
            .dropped = .{},
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.counts.deinit();
        self.generations.deinit();
        self.dropped.deinit(self.allocator);
    }

    /// Allocate a new entity ID with ref count 1
    pub fn allocate(self: *Self, index: u32) EntityId {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get or create generation for this index
        const gen_result = self.generations.getOrPut(index) catch unreachable;
        if (!gen_result.found_existing) {
            gen_result.value_ptr.* = 0;
        }
        const generation = gen_result.value_ptr.*;

        const id = EntityId{ .index = index, .generation = generation };

        // Initialize ref count to 1
        self.counts.put(id, 1) catch unreachable;

        return id;
    }

    /// Increment reference count (called when cloning a handle)
    pub fn increment(self: *Self, id: EntityId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.counts.getPtr(id)) |count| {
            count.* += 1;
        }
    }

    /// Try to increment reference count for weak->strong upgrade.
    /// Returns true if successful (entity alive), false if entity is dead.
    pub fn tryIncrement(self: *Self, id: EntityId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.counts.getPtr(id)) |count| {
            if (count.* > 0) {
                count.* += 1;
                return true;
            }
        }
        return false;
    }

    /// Decrement reference count. Returns true if this was the last reference.
    pub fn decrement(self: *Self, id: EntityId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.counts.getPtr(id)) |count| {
            if (count.* > 0) {
                count.* -= 1;
                if (count.* == 0) {
                    // Mark as dropped for cleanup
                    self.dropped.append(self.allocator, id) catch {};
                    // Increment generation for this slot so future allocations don't match
                    if (self.generations.getPtr(id.index)) |gen| {
                        gen.* +%= 1;
                    }
                    return true;
                }
            }
        }
        return false;
    }

    /// Check if an entity is still alive
    pub fn isAlive(self: *Self, id: EntityId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.counts.get(id)) |count| {
            return count > 0;
        }
        return false;
    }

    /// Get current reference count (for debugging)
    pub fn getCount(self: *Self, id: EntityId) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.counts.get(id);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EntityId equality and hashing" {
    const id1 = EntityId{ .index = 1, .generation = 0 };
    const id2 = EntityId{ .index = 1, .generation = 0 };
    const id3 = EntityId{ .index = 1, .generation = 1 };
    const id4 = EntityId{ .index = 2, .generation = 0 };

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3)); // Different generation
    try std.testing.expect(!id1.eql(id4)); // Different index

    try std.testing.expectEqual(id1.hash(), id2.hash());
    try std.testing.expect(id1.hash() != id3.hash());
}

test "EntityId validity" {
    const valid = EntityId{ .index = 0, .generation = 0 };
    const invalid = EntityId.invalid;

    try std.testing.expect(valid.isValid());
    try std.testing.expect(!invalid.isValid());
}

test "RefCounts basic operations" {
    const allocator = std.testing.allocator;
    var ref_counts = RefCounts.init(allocator);
    defer ref_counts.deinit();

    // Allocate an entity
    const id = ref_counts.allocate(0);
    try std.testing.expectEqual(@as(u32, 1), ref_counts.getCount(id).?);
    try std.testing.expect(ref_counts.isAlive(id));

    // Increment
    ref_counts.increment(id);
    try std.testing.expectEqual(@as(u32, 2), ref_counts.getCount(id).?);

    // Decrement (not last)
    try std.testing.expect(!ref_counts.decrement(id));
    try std.testing.expectEqual(@as(u32, 1), ref_counts.getCount(id).?);

    // Decrement (last reference)
    try std.testing.expect(ref_counts.decrement(id));
    try std.testing.expect(!ref_counts.isAlive(id));

    // Should be in dropped list
    try std.testing.expectEqual(@as(usize, 1), ref_counts.dropped.items.len);
}

test "RefCounts generation increment on release" {
    const allocator = std.testing.allocator;
    var ref_counts = RefCounts.init(allocator);
    defer ref_counts.deinit();

    // Allocate and release
    const id1 = ref_counts.allocate(0);
    try std.testing.expectEqual(@as(u32, 0), id1.generation);
    _ = ref_counts.decrement(id1);

    // Clear dropped list (simulating cleanup)
    ref_counts.dropped.clearRetainingCapacity();

    // Allocate again at same index - should have incremented generation
    const id2 = ref_counts.allocate(0);
    try std.testing.expectEqual(@as(u32, 1), id2.generation);
    try std.testing.expect(!id1.eql(id2)); // Different generations
}

test "RefCounts tryIncrement for weak upgrade" {
    const allocator = std.testing.allocator;
    var ref_counts = RefCounts.init(allocator);
    defer ref_counts.deinit();

    const id = ref_counts.allocate(0);

    // tryIncrement succeeds while alive
    try std.testing.expect(ref_counts.tryIncrement(id));
    try std.testing.expectEqual(@as(u32, 2), ref_counts.getCount(id).?);

    // Release both references
    _ = ref_counts.decrement(id);
    _ = ref_counts.decrement(id);

    // tryIncrement fails after death
    try std.testing.expect(!ref_counts.tryIncrement(id));
}

test "Entity and WeakEntity" {
    const allocator = std.testing.allocator;
    var ref_counts = RefCounts.init(allocator);
    defer ref_counts.deinit();

    const TestEntity = struct { value: i32 };

    // Create an entity handle manually (normally done by EntityMap)
    const id = ref_counts.allocate(0);
    var entity = Entity(TestEntity){ .id = id, .ref_counts = &ref_counts };

    // Downgrade to weak
    const weak = entity.downgrade();
    try std.testing.expect(weak.isAlive());

    // Clone the entity
    var cloned = entity.clone();
    try std.testing.expectEqual(@as(u32, 2), ref_counts.getCount(id).?);

    // Release original
    entity.release();
    try std.testing.expect(weak.isAlive()); // Still alive due to clone

    // Upgrade weak
    if (weak.upgrade()) |upgraded| {
        var up = upgraded;
        try std.testing.expect(up.id.eql(id));
        up.release();
    } else {
        try std.testing.expect(false); // Should have upgraded
    }

    // Release clone
    cloned.release();
    try std.testing.expect(!weak.isAlive()); // Now dead

    // Upgrade should fail
    try std.testing.expect(weak.upgrade() == null);
}

test "typeId uniqueness" {
    const A = struct { x: i32 };
    const B = struct { y: i32 };

    const id_a = typeId(A);
    const id_b = typeId(B);
    const id_a2 = typeId(A);

    try std.testing.expect(id_a != id_b);
    try std.testing.expectEqual(id_a, id_a2);
}
