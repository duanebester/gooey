//! Application context - the main entry point for a gooey application
//!
//! The App owns all entities and provides the reactive update loop.
//! It integrates with the entity system to provide:
//! - Entity creation via `new()`
//! - Entity updates via `update()`
//! - Dirty tracking for reactive re-renders
//!
//! Example:
//! ```zig
//! var app = try App.init(allocator);
//! defer app.deinit();
//!
//! // Create a reactive entity
//! var counter = app.new(Counter, struct {
//!     fn build(_: *Context(Counter)) Counter {
//!         return .{ .count = 0 };
//!     }
//! }.build);
//! defer counter.release();
//!
//! // Update with reactivity
//! app.update(Counter, counter, struct {
//!     fn update(c: *Counter, cx: *Context(Counter)) void {
//!         c.count += 1;
//!         cx.notify(); // Mark as dirty
//!     }
//! }.update);
//! ```

const std = @import("std");
const platform = @import("../platform/mac/platform.zig");
const Window = @import("../platform/mac/window.zig").Window;
const entity_map_mod = @import("entity_map.zig");
const entity_mod = @import("entity.zig");
const context_mod = @import("context.zig");

pub const EntityMap = entity_map_mod.EntityMap;
pub const EntityId = entity_mod.EntityId;
pub const EntityIdContext = entity_mod.EntityIdContext;
pub const Entity = entity_mod.Entity;
pub const WeakEntity = entity_mod.WeakEntity;
pub const Context = context_mod.Context;
pub const ContextVTable = context_mod.ContextVTable;

pub const App = struct {
    platform: platform.MacPlatform,
    allocator: std.mem.Allocator,

    /// Entity storage - owns all entity data
    entities: EntityMap,

    /// Set of entity IDs that need re-render
    dirty_entities: std.HashMap(EntityId, void, EntityIdContext, std.hash_map.default_max_load_percentage),

    /// VTable for Context operations
    context_vtable: ContextVTable,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const self = Self{
            .platform = try platform.MacPlatform.init(),
            .allocator = allocator,
            .entities = try EntityMap.init(allocator),
            .dirty_entities = std.HashMap(EntityId, void, EntityIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .context_vtable = .{
                .markDirty = markDirtyVTable,
                .getAllocator = getAllocatorVTable,
                .getEntities = getEntitiesVTable,
            },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.dirty_entities.deinit();
        self.entities.deinit();
        self.platform.deinit();
    }

    // =========================================================================
    // Entity Creation
    // =========================================================================

    /// Create a new entity with a build function.
    ///
    /// The build function receives a Context for the new entity, allowing
    /// it to set up initial state, subscriptions, or create child entities.
    ///
    /// Returns a strong Entity handle. The caller is responsible for
    /// calling `release()` when done with the entity.
    pub fn new(self: *Self, comptime T: type, build: *const fn (*Context(T)) T) Entity(T) {
        // Reserve a slot in the entity map
        const slot = self.entities.reserve(T);

        // Create context for the build function
        var ctx = Context(T).init(
            @ptrCast(self),
            slot.entity.downgrade(),
            &self.context_vtable,
        );

        // Build the entity
        const value = build(&ctx);

        // Insert into the map and return the handle
        return self.entities.insert(T, slot, value);
    }

    /// Create a new entity with a simple value (no build context needed).
    pub fn newSimple(self: *Self, comptime T: type, value: T) Entity(T) {
        return self.entities.new(T, value);
    }

    // =========================================================================
    // Entity Updates
    // =========================================================================

    /// Update an entity with a callback that receives mutable access and a context.
    ///
    /// The entity is leased (temporarily removed from storage) during the update
    /// to prevent aliasing. The callback can mutate the entity and call `cx.notify()`
    /// to mark it as dirty for re-render.
    pub fn update(
        self: *Self,
        comptime T: type,
        handle: Entity(T),
        callback: *const fn (*T, *Context(T)) void,
    ) void {
        if (self.entities.lease(T, handle.entityId())) |lease| {
            var lease_mut = lease;
            defer self.entities.endLease(T, &lease_mut);

            var ctx = Context(T).init(
                @ptrCast(self),
                handle.downgrade(),
                &self.context_vtable,
            );

            callback(lease.ptr, &ctx);
        }
    }

    /// Read an entity immutably.
    pub fn read(self: *Self, comptime T: type, handle: Entity(T)) ?*const T {
        return self.entities.read(T, handle.entityId());
    }

    // =========================================================================
    // Dirty Tracking
    // =========================================================================

    /// Mark an entity as dirty (needs re-render).
    pub fn markDirty(self: *Self, id: EntityId) void {
        self.dirty_entities.put(id, {}) catch {};
    }

    /// Check if an entity is dirty.
    pub fn isDirty(self: *Self, id: EntityId) bool {
        return self.dirty_entities.contains(id);
    }

    /// Clear all dirty flags. Call this after rendering.
    pub fn clearDirty(self: *Self) void {
        self.dirty_entities.clearRetainingCapacity();
    }

    /// Get and clear dirty entities, returning the IDs that were dirty.
    /// Caller owns the returned slice and must free it.
    pub fn takeDirty(self: *Self) ![]EntityId {
        var result = std.ArrayList(EntityId).init(self.allocator);
        var iter = self.dirty_entities.keyIterator();
        while (iter.next()) |id| {
            try result.append(id.*);
        }
        self.dirty_entities.clearRetainingCapacity();
        return result.toOwnedSlice();
    }

    /// Check if any entities are dirty.
    pub fn hasDirty(self: *Self) bool {
        return self.dirty_entities.count() > 0;
    }

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Flush dropped entities (cleanup cycle).
    /// Call this periodically, e.g., at the end of each frame.
    pub fn flushDropped(self: *Self) void {
        self.entities.flushDropped();
    }

    // =========================================================================
    // Window & Platform
    // =========================================================================

    pub fn createWindow(self: *Self, options: Window.Options) !*Window {
        return try Window.init(self.allocator, &self.platform, options);
    }

    pub fn run(self: *Self, callback: ?*const fn (*Self) void) void {
        self.platform.run(self, callback);
    }

    pub fn quit(self: *Self) void {
        self.platform.quit();
    }

    // =========================================================================
    // Window Connection Helpers
    // =========================================================================

    /// Connect a window to this App for reactive rendering.
    /// After calling this, you can use window.setRootView().
    pub fn connectWindow(self: *Self, window: *Window) void {
        window.connectApp(
            @ptrCast(self),
            &self.context_vtable,
            isDirtyVTable,
            clearDirtyVTable,
            getEntitiesVTable,
        );
    }

    fn isDirtyVTable(app_ptr: *anyopaque, id: EntityId) bool {
        const self: *Self = @ptrCast(@alignCast(app_ptr));
        return self.isDirty(id);
    }

    fn clearDirtyVTable(app_ptr: *anyopaque, id: EntityId) void {
        const self: *Self = @ptrCast(@alignCast(app_ptr));
        _ = self.dirty_entities.remove(id);
    }

    // =========================================================================
    // VTable Implementations (for Context callbacks)
    // =========================================================================

    fn markDirtyVTable(app_ptr: *anyopaque, id: EntityId) void {
        const self: *Self = @ptrCast(@alignCast(app_ptr));
        self.markDirty(id);
    }

    fn getAllocatorVTable(app_ptr: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(app_ptr));
        return self.allocator;
    }

    fn getEntitiesVTable(app_ptr: *anyopaque) *EntityMap {
        const self: *Self = @ptrCast(@alignCast(app_ptr));
        return &self.entities;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "App entity creation and update" {
    const allocator = std.testing.allocator;

    // We can't fully test without platform init, but we can test the entity parts
    // by creating a minimal test that doesn't call platform functions

    const Counter = struct {
        count: i32,
    };

    // Test EntityMap directly (App requires platform)
    var entities = try EntityMap.init(allocator);
    defer entities.deinit();

    var counter = entities.new(Counter, .{ .count = 0 });
    defer counter.release();

    // Verify we can read
    if (entities.read(Counter, counter.entityId())) |c| {
        try std.testing.expectEqual(@as(i32, 0), c.count);
    } else {
        try std.testing.expect(false);
    }

    // Verify lease/update works
    if (entities.lease(Counter, counter.entityId())) |lease| {
        var lease_mut = lease;
        defer entities.endLease(Counter, &lease_mut);
        lease_mut.ptr.count = 42;
    }

    // Verify change persisted
    if (entities.read(Counter, counter.entityId())) |c| {
        try std.testing.expectEqual(@as(i32, 42), c.count);
    } else {
        try std.testing.expect(false);
    }
}

test "Dirty tracking" {
    const allocator = std.testing.allocator;

    var dirty = std.HashMap(EntityId, void, EntityIdContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer dirty.deinit();

    const id1 = EntityId{ .index = 1, .generation = 0 };
    const id2 = EntityId{ .index = 2, .generation = 0 };

    // Mark dirty
    try dirty.put(id1, {});
    try std.testing.expect(dirty.contains(id1));
    try std.testing.expect(!dirty.contains(id2));

    // Add another
    try dirty.put(id2, {});
    try std.testing.expect(dirty.contains(id2));

    // Clear
    dirty.clearRetainingCapacity();
    try std.testing.expect(!dirty.contains(id1));
    try std.testing.expect(!dirty.contains(id2));
}
