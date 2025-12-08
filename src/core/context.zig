//! Context(T) - Entity-scoped context for reactive operations
//!
//! Provides a scoped context when interacting with an Entity(T), with methods
//! related to that specific entity such as notifying observers and accessing
//! other entities. This is modeled after GPUI's Context type.
//!
//! Key features:
//! - `notify()` to mark the entity as needing re-render
//! - `entity()` to get a strong handle to the current entity
//! - Access to App for creating/reading other entities
//!
//! Example:
//! ```zig
//! const Counter = struct {
//!     count: i32,
//!
//!     pub fn increment(self: *Counter, cx: *Context(Counter)) void {
//!         self.count += 1;
//!         cx.notify(); // Triggers re-render
//!     }
//! };
//!
//! // Create entity with build function
//! const counter = app.new(Counter, struct {
//!     fn build(cx: *Context(Counter)) Counter {
//!         return .{ .count = 0 };
//!     }
//! }.build);
//!
//! // Update entity
//! app.update(Counter, counter, struct {
//!     fn update(c: *Counter, cx: *Context(Counter)) void {
//!         c.increment(cx);
//!     }
//! }.update);
//! ```

const std = @import("std");
const entity_mod = @import("entity.zig");
const entity_map_mod = @import("entity_map.zig");

pub const EntityId = entity_mod.EntityId;
pub const Entity = entity_mod.Entity;
pub const WeakEntity = entity_mod.WeakEntity;
pub const AnyEntity = entity_mod.AnyEntity;
pub const EntityMap = entity_map_mod.EntityMap;
pub const Lease = entity_map_mod.Lease;

/// Entity-scoped context for reactive operations.
///
/// This context is provided when updating an entity and gives access to:
/// - The current entity (via `entity()` or `weakEntity()`)
/// - Notification to trigger re-renders (`notify()`)
/// - App-level operations for interacting with other entities
pub fn Context(comptime T: type) type {
    return struct {
        /// Reference to the application context (type-erased to avoid circular dep)
        app_ptr: *anyopaque,
        /// Weak reference to the entity this context is scoped to
        entity_state: WeakEntity(T),
        /// Function pointers for App operations (set by App)
        vtable: *const ContextVTable,

        const Self = @This();

        /// Initialize a new context for the given entity
        pub fn init(app_ptr: *anyopaque, weak: WeakEntity(T), vtable: *const ContextVTable) Self {
            return .{
                .app_ptr = app_ptr,
                .entity_state = weak,
                .vtable = vtable,
            };
        }

        // =====================================================================
        // Entity Access
        // =====================================================================

        /// Returns the EntityId of the entity this context is scoped to.
        pub fn entityId(self: *const Self) EntityId {
            return self.entity_state.entityId();
        }

        /// Returns a strong handle to the entity belonging to this context.
        /// The entity must be alive since we have a context for it.
        pub fn entity(self: *const Self) Entity(T) {
            return self.entity_state.upgrade() orelse
                @panic("Entity must be alive if we have a context for it");
        }

        /// Returns a weak handle to the entity belonging to this context.
        pub fn weakEntity(self: *const Self) WeakEntity(T) {
            return self.entity_state;
        }

        // =====================================================================
        // Notification / Reactivity
        // =====================================================================

        /// Mark this entity as needing re-render.
        ///
        /// Call this whenever the entity's state changes in a way that affects
        /// its visual representation. This will cause any windows displaying
        /// this entity (or observing it) to re-render on the next frame.
        pub fn notify(self: *Self) void {
            self.vtable.markDirty(self.app_ptr, self.entity_state.entityId());
        }

        // =====================================================================
        // Entity Operations via VTable
        // =====================================================================

        /// Get the allocator
        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.vtable.getAllocator(self.app_ptr);
        }

        /// Read another entity immutably via the entity map.
        /// Returns null if the entity doesn't exist or has the wrong type.
        pub fn readEntity(self: *const Self, comptime U: type, handle: Entity(U)) ?*const U {
            const entities = self.vtable.getEntities(self.app_ptr);
            return entities.read(U, handle.entityId());
        }
    };
}

/// VTable for App operations - allows Context to call App without circular imports
pub const ContextVTable = struct {
    markDirty: *const fn (*anyopaque, EntityId) void,
    getAllocator: *const fn (*anyopaque) std.mem.Allocator,
    getEntities: *const fn (*anyopaque) *EntityMap,
};

// ============================================================================
// Tests
// ============================================================================

test "Context type instantiation" {
    const TestEntity = struct {
        value: i32,
    };

    // Verify the Context type can be instantiated at comptime
    const ContextType = Context(TestEntity);
    _ = ContextType;
}
