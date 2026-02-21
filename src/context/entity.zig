//! Entity System - GPUI-style reference-counted shared state
//!
//! Entities are the core abstraction for shared mutable state in Gooey.
//! An Entity(T) is a lightweight handle (just an ID) that references data
//! stored in the EntityMap. This enables:
//!
//! - Multiple views observing the same data
//! - Automatic re-rendering when data changes
//! - Clean separation between "what data exists" and "who's looking at it"
//!
//! ## Key Insight from GPUI
//!
//! A "View" is just an Entity(T) where T implements a `render()` method.
//! There's no separate View type - it's all entities.
//!
//! ## Usage
//!
//! ```zig
//! // A "View" is just an Entity(T) where T implements a render() method.
//! // cx.update() returns a HandlerRef that, when invoked, calls the
//! // method and marks the entity dirty automatically.
//! const Counter = struct {
//!     count: i32 = 0,
//!
//!     pub fn increment(self: *Counter) void {
//!         self.count += 1;
//!     }
//!
//!     pub fn render(self: *Counter, cx: *EntityContext(Counter), b: *Builder) void {
//!         b.vstack(.{}, .{
//!             ui.textFmt("Count: {}", .{self.count}, .{}),
//!             ui.buttonHandler("+", cx.update(Counter.increment)),
//!         });
//!     }
//! };
//! ```

const std = @import("std");

// Forward declaration for Gooey (used in Entity.context)
const Gooey = @import("gooey.zig").Gooey;

// =============================================================================
// Entity ID
// =============================================================================

/// Unique identifier for an entity
pub const EntityId = struct {
    id: u64,

    pub const invalid = EntityId{ .id = 0 };

    pub fn isValid(self: EntityId) bool {
        return self.id != 0;
    }

    pub fn eql(self: EntityId, other: EntityId) bool {
        return self.id == other.id;
    }

    pub fn hash(self: EntityId) u64 {
        return self.id;
    }
};

// =============================================================================
// Entity Handle
// =============================================================================

/// A lightweight handle to an entity of type T.
///
/// Entity(T) is just an ID - it doesn't contain the actual data.
/// Use EntityContext.read() to access the data, or use the convenience
/// method `entity.context(gooey)` to get an EntityContext.
pub fn Entity(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The type this entity holds
        pub const Inner = T;

        /// The entity's unique ID
        id: EntityId,

        /// Check if this is a valid entity reference
        pub fn isValid(self: Self) bool {
            return self.id.isValid();
        }

        /// Create an invalid/null entity reference
        pub fn nil() Self {
            return .{ .id = EntityId.invalid };
        }

        /// Compare two entity handles
        pub fn eql(self: Self, other: Self) bool {
            return self.id.eql(other.id);
        }

        /// Create an EntityContext for this entity.
        ///
        /// This is a convenience method that eliminates boilerplate when
        /// working with entities in component render methods.
        ///
        /// ## Example
        ///
        /// ```zig
        /// const CounterButtons = struct {
        ///     counter: gooey.Entity(Counter),
        ///
        ///     pub fn render(self: @This(), b: *ui.Builder) void {
        ///         var cx = self.counter.context(g_gooey);
        ///         b.hstack(.{ .gap = 8 }, .{
        ///             ui.buttonHandler("-", cx.handler(Counter.decrement)),
        ///             ui.buttonHandler("+", cx.handler(Counter.increment)),
        ///         });
        ///     }
        /// };
        /// ```
        pub fn context(self: Self, gooey: *Gooey) EntityContext(T) {
            return .{
                .gooey = gooey,
                .entities = gooey.getEntities(),
                .entity_id = self.id,
            };
        }
    };
}

// =============================================================================
// Comptime Helpers
// =============================================================================

/// Check if a type is a "View" (has a render method)
pub fn isView(comptime T: type) bool {
    return @hasDecl(T, "render");
}

/// Get a unique type ID for a type
pub fn typeId(comptime T: type) usize {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

// =============================================================================
// Type-erased Entity Storage
// =============================================================================

/// Type-erased entity slot
const EntitySlot = struct {
    /// Pointer to the actual data
    ptr: *anyopaque,

    /// Type ID for runtime type checking
    type_id: usize,

    /// Destructor function
    deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,

    /// Reference count
    ref_count: u32 = 1,

    /// Entities that are observing this one (notified on change)
    observers: std.ArrayListUnmanaged(EntityId) = .{},

    /// Entities that this one is observing (for cleanup on removal)
    observing: std.ArrayListUnmanaged(EntityId) = .{},

    /// Whether this entity needs re-render (for views)
    dirty: bool = true,

    /// Whether this entity is already in the pending_notifications list.
    /// Separate from `dirty` because `processNotifications` clears the
    /// pending list without clearing dirty flags — using `dirty` alone
    /// would silently skip re-notification after processing.
    in_pending_list: bool = false,
};

// =============================================================================
// Entity Map
// =============================================================================

/// Central storage for all entities.
///
/// The EntityMap owns all entity data and provides type-safe access
/// through Entity(T) handles.
pub const EntityMap = struct {
    allocator: std.mem.Allocator,

    /// All entity slots, keyed by ID
    slots: std.AutoHashMapUnmanaged(u64, EntitySlot) = .{},

    /// Next ID to assign
    next_id: u64 = 1,

    /// Entities that have been marked dirty this frame
    pending_notifications: std.ArrayListUnmanaged(EntityId) = .{},

    /// Observations made during current frame (for auto-cleanup)
    /// Stores (observer_id, target_id) pairs
    frame_observations: std.ArrayListUnmanaged(struct { observer: EntityId, target: EntityId }) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        // Clean up all entities
        var iter = self.slots.iterator();
        while (iter.next()) |entry| {
            var slot = entry.value_ptr;
            slot.deinit_fn(slot.ptr, self.allocator);
            slot.observers.deinit(self.allocator);
            slot.observing.deinit(self.allocator); // NEW
        }
        self.slots.deinit(self.allocator);
        self.pending_notifications.deinit(self.allocator);
        self.frame_observations.deinit(self.allocator); // NEW
    }

    /// Create a new entity with the given initial value
    pub fn new(self: *Self, comptime T: type, value: T) !Entity(T) {
        const id = EntityId{ .id = self.next_id };
        self.next_id += 1;

        // Allocate and store the value
        const ptr = try self.allocator.create(T);
        ptr.* = value;

        // Create type-erased destructor
        const Destructor = struct {
            fn destroy(p: *anyopaque, alloc: std.mem.Allocator) void {
                const typed: *T = @ptrCast(@alignCast(p));
                alloc.destroy(typed);
            }
        };

        // Store in map
        try self.slots.put(self.allocator, id.id, .{
            .ptr = ptr,
            .type_id = typeId(T),
            .deinit_fn = Destructor.destroy,
        });

        return .{ .id = id };
    }

    /// Read an entity's data (immutable)
    pub fn read(self: *const Self, comptime T: type, entity: Entity(T)) ?*const T {
        if (self.slots.get(entity.id.id)) |slot| {
            if (slot.type_id == typeId(T)) {
                return @ptrCast(@alignCast(slot.ptr));
            }
        }
        return null;
    }

    /// Get mutable access to an entity's data
    pub fn write(self: *Self, comptime T: type, entity: Entity(T)) ?*T {
        if (self.slots.getPtr(entity.id.id)) |slot| {
            if (slot.type_id == typeId(T)) {
                return @ptrCast(@alignCast(slot.ptr));
            }
        }
        return null;
    }

    /// Mark an entity as needing notification. O(1) dedup via
    /// `in_pending_list` flag — no linear scan of the pending list.
    pub fn markDirty(self: *Self, id: EntityId) void {
        if (self.slots.getPtr(id.id)) |slot| {
            slot.dirty = true;
            if (slot.in_pending_list) return; // Already queued — O(1) dedup.
            slot.in_pending_list = true;
            self.pending_notifications.append(self.allocator, id) catch
                @panic("entity: pending_notifications append failed (OOM)");
        }
    }

    /// Process all pending notifications, marking observers as dirty
    /// Returns true if any entities need re-render
    pub fn processNotifications(self: *Self) bool {
        var any_dirty = false;

        for (self.pending_notifications.items) |id| {
            if (self.slots.getPtr(id.id)) |slot| {
                // Clear pending flag so the entity can be re-queued next time.
                slot.in_pending_list = false;

                // Mark all observers as dirty.
                for (slot.observers.items) |observer_id| {
                    if (self.slots.getPtr(observer_id.id)) |observer_slot| {
                        observer_slot.dirty = true;
                        any_dirty = true;
                    }
                }
            }
        }

        self.pending_notifications.clearRetainingCapacity();
        return any_dirty;
    }

    /// Add an observer relationship (bidirectional tracking)
    pub fn observe(self: *Self, target_id: EntityId, observer_id: EntityId) void {
        // Add observer to target's observer list
        if (self.slots.getPtr(target_id.id)) |target_slot| {
            // Avoid duplicate observers
            for (target_slot.observers.items) |obs| {
                if (obs.eql(observer_id)) return; // Already observing
            }
            target_slot.observers.append(self.allocator, observer_id) catch {};
        }

        // Add target to observer's observing list (reverse tracking)
        if (self.slots.getPtr(observer_id.id)) |observer_slot| {
            for (observer_slot.observing.items) |obs| {
                if (obs.eql(target_id)) return; // Already tracked
            }
            observer_slot.observing.append(self.allocator, target_id) catch {};
        }

        // Track for frame-based cleanup
        self.frame_observations.append(self.allocator, .{ .observer = observer_id, .target = target_id }) catch {};
    }

    /// Remove an observer relationship (bidirectional)
    pub fn unobserve(self: *Self, target_id: EntityId, observer_id: EntityId) void {
        // Remove observer from target's list
        if (self.slots.getPtr(target_id.id)) |target_slot| {
            for (target_slot.observers.items, 0..) |obs, i| {
                if (obs.eql(observer_id)) {
                    _ = target_slot.observers.swapRemove(i);
                    break;
                }
            }
        }

        // Remove target from observer's observing list
        if (self.slots.getPtr(observer_id.id)) |observer_slot| {
            for (observer_slot.observing.items, 0..) |obs, i| {
                if (obs.eql(target_id)) {
                    _ = observer_slot.observing.swapRemove(i);
                    break;
                }
            }
        }
    }

    /// Check if an entity is dirty (needs re-render)
    pub fn isDirty(self: *const Self, id: EntityId) bool {
        if (self.slots.get(id.id)) |slot| {
            return slot.dirty;
        }
        return false;
    }

    /// Clear dirty flag for an entity
    pub fn clearDirty(self: *Self, id: EntityId) void {
        if (self.slots.getPtr(id.id)) |slot| {
            slot.dirty = false;
        }
    }

    /// Check if an entity exists
    pub fn exists(self: *const Self, id: EntityId) bool {
        return self.slots.contains(id.id);
    }

    /// Remove an entity and clean up all relationships
    pub fn remove(self: *Self, id: EntityId) void {
        const kv = self.slots.fetchRemove(id.id) orelse return;
        var slot = kv.value;

        // Remove this entity from the observer lists of entities it was observing
        // (Using the reverse tracking - O(n) where n = entities this one observed)
        for (slot.observing.items) |target_id| {
            if (self.slots.getPtr(target_id.id)) |target_slot| {
                for (target_slot.observers.items, 0..) |obs, i| {
                    if (obs.eql(id)) {
                        _ = target_slot.observers.swapRemove(i);
                        break;
                    }
                }
            }
        }

        // Remove this entity from entities that were observing it
        for (slot.observers.items) |observer_id| {
            if (self.slots.getPtr(observer_id.id)) |observer_slot| {
                for (observer_slot.observing.items, 0..) |obs, i| {
                    if (obs.eql(id)) {
                        _ = observer_slot.observing.swapRemove(i);
                        break;
                    }
                }
            }
        }

        // Clean up slot memory
        slot.deinit_fn(slot.ptr, self.allocator);
        slot.observers.deinit(self.allocator);
        slot.observing.deinit(self.allocator);
    }

    /// Get entity count
    pub fn count(self: *const Self) usize {
        return self.slots.count();
    }

    /// Begin a new frame - call before rendering
    /// Clears frame observations from previous frame
    pub fn beginFrame(self: *Self) void {
        // Clear observations from last frame
        // This ensures stale observations are removed
        for (self.frame_observations.items) |obs| {
            self.unobserve(obs.target, obs.observer);
        }
        self.frame_observations.clearRetainingCapacity();
    }

    /// End frame - observations made this frame are now active
    /// Call after rendering is complete
    pub fn endFrame(_: *Self) void {
        // Frame observations are already registered via observe()
        // This is a hook for future optimizations (e.g., batching)
    }

    /// Get list of entities this entity is observing
    pub fn getObserving(self: *const Self, id: EntityId) ?[]const EntityId {
        if (self.slots.get(id.id)) |slot| {
            return slot.observing.items;
        }
        return null;
    }

    /// Get list of entities observing this entity
    pub fn getObservers(self: *const Self, id: EntityId) ?[]const EntityId {
        if (self.slots.get(id.id)) |slot| {
            return slot.observers.items;
        }
        return null;
    }

    /// Get count of active frame observations
    pub fn frameObservationCount(self: *const Self) usize {
        return self.frame_observations.items.len;
    }
};

// =============================================================================
// Entity Context
// =============================================================================

/// Context for entity operations.
///
/// EntityContext(T) provides typed access to an entity and operations
/// for reading/updating other entities, creating new entities, etc.
pub fn EntityContext(comptime T: type) type {
    const handler_mod = @import("handler.zig");
    const HandlerRef = handler_mod.HandlerRef;

    return struct {
        const Self = @This();

        /// The type of entity this context is for
        pub const EntityType = T;

        /// Reference to Gooey (for rendering, window ops, etc.)
        gooey: *Gooey,

        /// The entity map
        entities: *EntityMap,

        /// The entity this context is for
        entity_id: EntityId,

        // =====================================================================
        // Self Access
        // =====================================================================

        /// Get mutable access to this entity's data
        pub fn state(self: *Self) *T {
            return self.entities.write(T, .{ .id = self.entity_id }) orelse
                @panic("EntityContext: entity not found");
        }

        /// Get immutable access to this entity's data
        pub fn stateConst(self: *const Self) *const T {
            return self.entities.read(T, .{ .id = self.entity_id }) orelse
                @panic("EntityContext: entity not found");
        }

        // =====================================================================
        // Other Entity Access
        // =====================================================================

        /// Read another entity's data (auto-subscribes to changes)
        pub fn read(self: *Self, comptime U: type, entity: Entity(U)) *const U {
            // Auto-subscribe: reading creates an observer relationship
            self.entities.observe(entity.id, self.entity_id);

            return self.entities.read(U, entity) orelse
                @panic("EntityContext.read: entity not found");
        }

        // =====================================================================
        // Pure State Handlers (Option B - Recommended)
        // =====================================================================

        /// Create a handler from a pure entity method.
        ///
        /// The method should be `fn(*T) void` - no context parameter.
        /// After the method is called, the entity is marked dirty and UI re-renders.
        ///
        /// ## Example
        ///
        /// ```zig
        /// const Counter = struct {
        ///     count: i32 = 0,
        ///
        ///     pub fn increment(self: *Counter) void {
        ///         self.count += 1;
        ///     }
        /// };
        ///
        /// // In render:
        /// ui.buttonHandler("+", cx.update(Counter.increment));
        /// ```
        pub fn update(
            self: *Self,
            comptime method: fn (*T) void,
        ) HandlerRef {
            const entity_id = self.entity_id;

            const Wrapper = struct {
                fn invoke(gooey: *Gooey, eid: EntityId) void {
                    const ents = gooey.getEntities();
                    const data = ents.write(T, .{ .id = eid }) orelse {
                        return;
                    };

                    // Call the pure method
                    method(data);

                    // Mark dirty and request render
                    ents.markDirty(eid);
                    gooey.requestRender();
                }
            };

            return .{
                .callback = Wrapper.invoke,
                .entity_id = entity_id,
            };
        }

        /// Create a handler from a pure entity method that takes an argument.
        ///
        /// **Note:** For EntityContext, we need to pack both the entity_id AND the arg.
        /// Since entity_id uses the HandlerRef's entity_id field, we store the arg
        /// using a thread-local approach (limited to one arg value per method type).
        ///
        /// For most cases, prefer using the existing `handler()` method or restructure
        /// to avoid needing both entity_id and an argument.
        /// Create a handler from a pure entity method that takes an argument.
        ///
        /// Packs entity_id (lower 32 bits) and arg (upper 32 bits) into
        /// `HandlerRef.entity_id`, so each handler carries its own argument
        /// without shared mutable state. Args are limited to ≤4 bytes
        /// (`bool`, `i32`, `u32`, `enum`, small structs).
        pub fn updateWith(
            self: *Self,
            arg: anytype,
            comptime method: fn (*T, @TypeOf(arg)) void,
        ) HandlerRef {
            const Arg = @TypeOf(arg);
            comptime {
                std.debug.assert(@sizeOf(Arg) <= 4); // Arg must fit in upper 32 bits.
            }
            // Data integrity: truncation to u32 must be lossless. Runtime check
            // because std.debug.assert is stripped in ReleaseFast and silent
            // corruption of the packed ID would target the wrong entity.
            if (self.entity_id.id > std.math.maxInt(u32))
                @panic("entity_id exceeds u32 range for updateWith packing");

            // Pack: lower 32 = entity_id, upper 32 = arg.
            var arg_bits: u32 = 0;
            @memcpy(std.mem.asBytes(&arg_bits)[0..@sizeOf(Arg)], std.mem.asBytes(&arg));
            const combined: u64 = @as(u64, arg_bits) << 32 | @as(u64, @as(u32, @truncate(self.entity_id.id)));

            const Wrapper = struct {
                fn invoke(gooey: *Gooey, packed_id: EntityId) void {
                    // Unpack entity_id from lower 32 bits.
                    const eid_raw: u32 = @truncate(packed_id.id);
                    const eid = EntityId{ .id = @as(u64, eid_raw) };

                    // Unpack arg from upper 32 bits.
                    var raw: u32 = @truncate(packed_id.id >> 32);
                    var unpacked_arg: Arg = undefined;
                    @memcpy(std.mem.asBytes(&unpacked_arg), std.mem.asBytes(&raw)[0..@sizeOf(Arg)]);

                    const ents = gooey.getEntities();
                    const data = ents.write(T, .{ .id = eid }) orelse {
                        return;
                    };

                    // Call the pure method with the unpacked argument.
                    method(data, unpacked_arg);

                    // Mark dirty and request render.
                    ents.markDirty(eid);
                    gooey.requestRender();
                }
            };

            return .{
                .callback = Wrapper.invoke,
                .entity_id = .{ .id = combined },
            };
        }

        // =====================================================================
        // Entity Creation
        // =====================================================================

        /// Create a new entity
        pub fn create(self: *Self, comptime U: type, value: U) !Entity(U) {
            return self.entities.new(U, value);
        }

        /// Remove an entity
        pub fn remove(self: *Self, id: EntityId) void {
            self.entities.remove(id);
        }

        // =====================================================================
        // Handler Creation
        // =====================================================================

        /// Create a handler from a method on this entity type.
        ///
        /// The entity ID is embedded in the HandlerRef, so each handler
        /// correctly references its own entity.
        ///
        /// Usage:
        /// ```zig
        /// ui.buttonHandler("+", cx.handler(MyView.increment))
        /// ```
        pub fn handler(
            self: *Self,
            comptime method: fn (*T, *Self) void,
        ) HandlerRef {
            // Create a wrapper that uses the entity_id from HandlerRef
            const Wrapper = struct {
                fn invoke(gooey: *Gooey, eid: EntityId) void {
                    // Get entities from gooey
                    const ents = gooey.getEntities();
                    const data = ents.write(T, .{ .id = eid }) orelse {
                        return;
                    };

                    var cx = Self{
                        .gooey = gooey,
                        .entities = ents,
                        .entity_id = eid,
                    };

                    method(data, &cx);
                }
            };

            // Return handler with entity_id embedded
            return .{
                .callback = Wrapper.invoke,
                .entity_id = self.entity_id,
            };
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "Entity creation and access" {
    const allocator = std.testing.allocator;

    var map = EntityMap.init(allocator);
    defer map.deinit();

    const TestData = struct {
        value: i32,
        name: []const u8,
    };

    // Create entity
    const entity = try map.new(TestData, .{ .value = 42, .name = "test" });
    try std.testing.expect(entity.isValid());

    // Read entity
    const data = map.read(TestData, entity);
    try std.testing.expect(data != null);
    try std.testing.expectEqual(@as(i32, 42), data.?.value);

    // Write entity
    if (map.write(TestData, entity)) |ptr| {
        ptr.value = 100;
    }

    const updated = map.read(TestData, entity);
    try std.testing.expectEqual(@as(i32, 100), updated.?.value);
}

test "Entity observation" {
    const allocator = std.testing.allocator;

    var map = EntityMap.init(allocator);
    defer map.deinit();

    const Model = struct { count: i32 };
    const View = struct { label: []const u8 };

    const model = try map.new(Model, .{ .count = 0 });
    const view = try map.new(View, .{ .label = "counter" });

    // View observes model
    map.observe(model.id, view.id);

    // Mark model dirty
    map.markDirty(model.id);

    // Process notifications - view should become dirty
    const any_dirty = map.processNotifications();
    try std.testing.expect(any_dirty);
    try std.testing.expect(map.isDirty(view.id));
}

test "Entity type safety" {
    const allocator = std.testing.allocator;

    var map = EntityMap.init(allocator);
    defer map.deinit();

    const TypeA = struct { a: i32 };
    const TypeB = struct { b: i32 };

    const entity_a = try map.new(TypeA, .{ .a = 1 });

    // Reading with wrong type should return null
    const wrong_type = map.read(TypeB, .{ .id = entity_a.id });
    try std.testing.expect(wrong_type == null);

    // Reading with correct type should work
    const right_type = map.read(TypeA, entity_a);
    try std.testing.expect(right_type != null);
}

test "Entity.context convenience method" {
    // This test verifies the API compiles correctly.
    // Full integration test would require a Gooey instance.
    const TestModel = struct {
        value: i32,
    };

    const entity = Entity(TestModel){ .id = .{ .id = 42 } };
    try std.testing.expect(entity.isValid());

    // Verify the context method exists and returns the right type
    const ContextType = EntityContext(TestModel);
    _ = ContextType;
}

test "Observer auto-cleanup on entity removal" {
    const allocator = std.testing.allocator;

    const Model = struct { value: i32 };

    var map = EntityMap.init(allocator);
    defer map.deinit();

    // Create entities
    const target = try map.new(Model, .{ .value = 1 });
    const observer1 = try map.new(Model, .{ .value = 2 });
    const observer2 = try map.new(Model, .{ .value = 3 });

    // Set up observations
    map.observe(target.id, observer1.id);
    map.observe(target.id, observer2.id);

    // Verify observations
    try std.testing.expectEqual(@as(usize, 2), map.getObservers(target.id).?.len);
    try std.testing.expectEqual(@as(usize, 1), map.getObserving(observer1.id).?.len);

    // Remove observer1 - should auto-cleanup from target's observer list
    map.remove(observer1.id);

    // Target should only have observer2 now
    try std.testing.expectEqual(@as(usize, 1), map.getObservers(target.id).?.len);
    try std.testing.expect(map.getObservers(target.id).?[0].eql(observer2.id));
}

test "Frame-based observation cleanup" {
    const allocator = std.testing.allocator;

    const Model = struct { value: i32 };

    var map = EntityMap.init(allocator);
    defer map.deinit();

    const target = try map.new(Model, .{ .value = 1 });
    const observer = try map.new(Model, .{ .value = 2 });

    // Frame 1: observe
    map.beginFrame();
    map.observe(target.id, observer.id);
    map.endFrame();

    try std.testing.expectEqual(@as(usize, 1), map.getObservers(target.id).?.len);

    // Frame 2: begin clears previous observations
    map.beginFrame();
    // Observation was cleared
    try std.testing.expectEqual(@as(usize, 0), map.getObservers(target.id).?.len);

    // Re-observe in this frame
    map.observe(target.id, observer.id);
    map.endFrame();

    try std.testing.expectEqual(@as(usize, 1), map.getObservers(target.id).?.len);
}
