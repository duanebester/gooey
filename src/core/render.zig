//! Render trait and View system for reactive UI
//!
//! This module provides the infrastructure for renderable entities:
//! - `Renderable(T)` - comptime check if a type can render
//! - `AnyView` - type-erased view handle for window roots
//! - `ViewContext(T)` - extended context for render methods
//!
//! When a type T implements a `render` method with the signature:
//!   `fn render(*T, *Window, *ViewContext(T)) AnyElement`
//! Then `Entity(T)` can be used as a window's root view.
//!
//! Example:
//! ```zig
//! const Counter = struct {
//!     count: i32,
//!
//!     // This makes Counter "Renderable"
//!     pub fn render(self: *Counter, window: *Window, cx: *ViewContext(Counter)) AnyElement {
//!         return text(std.fmt.allocPrint(cx.allocator(), "Count: {}", .{self.count}));
//!     }
//!
//!     pub fn increment(self: *Counter, cx: *ViewContext(Counter)) void {
//!         self.count += 1;
//!         cx.notify(); // Triggers re-render
//!     }
//! };
//!
//! // Use as window root
//! const counter = app.new(Counter, ...);
//! window.setRootView(Counter, counter);
//! ```

const std = @import("std");
const entity_mod = @import("entity.zig");
const entity_map_mod = @import("entity_map.zig");
const context_mod = @import("context.zig");

pub const EntityId = entity_mod.EntityId;
pub const Entity = entity_mod.Entity;
pub const WeakEntity = entity_mod.WeakEntity;
pub const AnyEntity = entity_mod.AnyEntity;
pub const RefCounts = entity_mod.RefCounts;
pub const typeId = entity_mod.typeId;
pub const TypeId = entity_mod.TypeId;
pub const EntityMap = entity_map_mod.EntityMap;
pub const Context = context_mod.Context;
pub const ContextVTable = context_mod.ContextVTable;

// ============================================================================
// Render Trait (comptime check)
// ============================================================================

/// Check if a type T is "Renderable" - i.e., has a render method.
///
/// A type is Renderable if it has a declaration named "render".
/// The expected signature is:
///   `fn render(*T, *Window, *ViewContext(T)) AnyElement`
///
/// But we only check for existence here; signature is enforced at call site.
pub fn Renderable(comptime T: type) bool {
    return @hasDecl(T, "render");
}

// ============================================================================
// ViewContext - Extended Context for Render Methods
// ============================================================================

/// ViewContext extends Context with window-specific operations.
///
/// This is passed to render() methods and provides:
/// - All Context(T) functionality (notify, entity access, etc.)
/// - Window access for layout and painting
/// - Listener creation for event callbacks
pub fn ViewContext(comptime T: type) type {
    return struct {
        /// The underlying entity context
        ctx: Context(T),
        /// The window being rendered to (type-erased to avoid circular deps)
        window_ptr: *anyopaque,
        /// VTable for window operations
        window_vtable: *const WindowVTable,

        const Self = @This();

        pub fn init(
            ctx: Context(T),
            window_ptr: *anyopaque,
            window_vtable: *const WindowVTable,
        ) Self {
            return .{
                .ctx = ctx,
                .window_ptr = window_ptr,
                .window_vtable = window_vtable,
            };
        }

        // === Forwarded from Context ===

        pub fn entityId(self: *const Self) EntityId {
            return self.ctx.entityId();
        }

        pub fn entity(self: *const Self) Entity(T) {
            return self.ctx.entity();
        }

        pub fn weakEntity(self: *const Self) WeakEntity(T) {
            return self.ctx.weakEntity();
        }

        pub fn notify(self: *Self) void {
            self.ctx.notify();
        }

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.ctx.allocator();
        }

        pub fn readEntity(self: *const Self, comptime U: type, handle: Entity(U)) ?*const U {
            return self.ctx.readEntity(U, handle);
        }

        // === Window Operations ===

        /// Get the window size
        pub fn windowSize(self: *const Self) struct { width: f32, height: f32 } {
            return self.window_vtable.getSize(self.window_ptr);
        }

        /// Request a re-render of the window
        pub fn requestRender(self: *Self) void {
            self.window_vtable.requestRender(self.window_ptr);
        }

        // === Listener Creation ===

        /// Create a callback that captures this entity for event handling.
        /// The callback will update the entity when invoked.
        ///
        /// Example:
        /// ```zig
        /// button("Click me", cx.listener(struct {
        ///     fn onClick(self: *Counter, cx: *ViewContext(Counter)) void {
        ///         self.count += 1;
        ///         cx.notify();
        ///     }
        /// }.onClick))
        /// ```
        pub fn listener(
            self: *const Self,
            comptime callback: fn (*T, *Self) void,
        ) Listener(T) {
            return Listener(T){
                .entity_id = self.ctx.entityId(),
                .callback = callback,
                .vtable = self.ctx.vtable,
                .app_ptr = self.ctx.app_ptr,
                .window_ptr = self.window_ptr,
                .window_vtable = self.window_vtable,
            };
        }
    };
}

/// A captured callback for an entity. Created via ViewContext.listener().
pub fn Listener(comptime T: type) type {
    return struct {
        entity_id: EntityId,
        callback: *const fn (*T, *ViewContext(T)) void,
        vtable: *const ContextVTable,
        app_ptr: *anyopaque,
        window_ptr: *anyopaque,
        window_vtable: *const WindowVTable,

        const Self = @This();

        /// Invoke the listener. This leases the entity, calls the callback,
        /// then returns the entity to storage.
        pub fn invoke(self: *const Self, entities: *EntityMap) void {
            if (entities.lease(T, self.entity_id)) |*lease| {
                defer entities.endLease(T, lease);

                const weak = WeakEntity(T){
                    .id = self.entity_id,
                    .ref_counts = entities.ref_counts,
                };

                const ctx = Context(T).init(self.app_ptr, weak, self.vtable);
                var view_ctx = ViewContext(T).init(ctx, self.window_ptr, self.window_vtable);

                self.callback(lease.ptr, &view_ctx);
            }
        }
    };
}

/// VTable for Window operations (avoids circular imports)
pub const WindowVTable = struct {
    pub const Size = struct { width: f32, height: f32 };
    getSize: *const fn (*anyopaque) Size,
    requestRender: *const fn (*anyopaque) void,
};

// ============================================================================
// AnyView - Type-erased renderable view
// ============================================================================

/// A type-erased handle to a renderable entity.
///
/// AnyView allows windows to store their root view without knowing
/// the concrete type. When rendering is needed, it calls the stored
/// render function which downcasts and invokes the actual render method.
pub const AnyView = struct {
    /// The entity ID for dirty checking
    entity_id: EntityId,
    /// Type ID for runtime type checking
    entity_type: TypeId,
    /// Reference counts for the entity
    ref_counts: *RefCounts,
    /// Type-erased render function
    render_fn: *const fn (
        entity_id: EntityId,
        entities: *EntityMap,
        app_ptr: *anyopaque,
        ctx_vtable: *const ContextVTable,
        window_ptr: *anyopaque,
        window_vtable: *const WindowVTable,
    ) RenderOutput,

    const Self = @This();

    /// Create an AnyView from a typed Entity handle.
    /// T must be Renderable (have a render method).
    pub fn from(comptime T: type, handle: Entity(T)) Self {
        comptime {
            if (!Renderable(T)) {
                @compileError("Type " ++ @typeName(T) ++ " is not Renderable (missing render method)");
            }
        }

        return .{
            .entity_id = handle.entityId(),
            .entity_type = typeId(T),
            .ref_counts = handle.ref_counts,
            .render_fn = makeRenderFn(T),
        };
    }

    /// Render this view, returning the output.
    pub fn render(
        self: Self,
        entities: *EntityMap,
        app_ptr: *anyopaque,
        ctx_vtable: *const ContextVTable,
        window_ptr: *anyopaque,
        window_vtable: *const WindowVTable,
    ) RenderOutput {
        return self.render_fn(
            self.entity_id,
            entities,
            app_ptr,
            ctx_vtable,
            window_ptr,
            window_vtable,
        );
    }

    /// Check if the view's entity is still alive
    pub fn isAlive(self: Self) bool {
        return self.ref_counts.isAlive(self.entity_id);
    }

    /// Downgrade to a weak view handle
    pub fn downgrade(self: Self) AnyWeakView {
        return .{
            .entity_id = self.entity_id,
            .entity_type = self.entity_type,
            .ref_counts = self.ref_counts,
            .render_fn = self.render_fn,
        };
    }

    /// Generate the type-erased render function for type T
    fn makeRenderFn(comptime T: type) *const fn (
        EntityId,
        *EntityMap,
        *anyopaque,
        *const ContextVTable,
        *anyopaque,
        *const WindowVTable,
    ) RenderOutput {
        return struct {
            fn render(
                entity_id: EntityId,
                entities: *EntityMap,
                app_ptr: *anyopaque,
                ctx_vtable: *const ContextVTable,
                window_ptr: *anyopaque,
                window_vtable: *const WindowVTable,
            ) RenderOutput {
                // Lease the entity for rendering
                if (entities.lease(T, entity_id)) |lease| {
                    var lease_mut = lease;
                    defer entities.endLease(T, &lease_mut);

                    // Build the ViewContext
                    const weak = WeakEntity(T){
                        .id = entity_id,
                        .ref_counts = entities.ref_counts,
                    };
                    const ctx = Context(T).init(app_ptr, weak, ctx_vtable);
                    var view_ctx = ViewContext(T).init(ctx, window_ptr, window_vtable);

                    // Call the render method
                    return lease.ptr.render(&view_ctx);
                }

                return RenderOutput.empty();
            }
        }.render;
    }
};

/// Weak reference to an AnyView (doesn't keep entity alive)
pub const AnyWeakView = struct {
    entity_id: EntityId,
    entity_type: TypeId,
    ref_counts: *RefCounts,
    render_fn: *const fn (
        EntityId,
        *EntityMap,
        *anyopaque,
        *const ContextVTable,
        *anyopaque,
        *const WindowVTable,
    ) RenderOutput,

    pub fn upgrade(self: AnyWeakView) ?AnyView {
        if (self.ref_counts.tryIncrement(self.entity_id)) {
            return AnyView{
                .entity_id = self.entity_id,
                .entity_type = self.entity_type,
                .ref_counts = self.ref_counts,
                .render_fn = self.render_fn,
            };
        }
        return null;
    }

    pub fn isAlive(self: AnyWeakView) bool {
        return self.ref_counts.isAlive(self.entity_id);
    }
};

// ============================================================================
// RenderOutput - What render() returns
// ============================================================================

/// The output of a render() call.
///
/// For now, this is a simple wrapper that can hold layout commands
/// or be extended to hold a full element tree later.
pub const RenderOutput = struct {
    /// Whether rendering produced any output
    has_content: bool,
    /// User data pointer (for custom render output)
    user_data: ?*anyopaque,
    /// Cleanup function for user_data
    cleanup_fn: ?*const fn (*anyopaque) void,

    pub fn empty() RenderOutput {
        return .{
            .has_content = false,
            .user_data = null,
            .cleanup_fn = null,
        };
    }

    pub fn withContent() RenderOutput {
        return .{
            .has_content = true,
            .user_data = null,
            .cleanup_fn = null,
        };
    }

    pub fn deinit(self: *RenderOutput) void {
        if (self.cleanup_fn) |cleanup| {
            if (self.user_data) |data| {
                cleanup(data);
            }
        }
        self.* = empty();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Renderable comptime check" {
    const NotRenderable = struct {
        value: i32,
    };

    const IsRenderable = struct {
        value: i32,

        pub fn render(self: *@This(), cx: *ViewContext(@This())) RenderOutput {
            _ = self;
            _ = cx;
            return RenderOutput.withContent();
        }
    };

    try std.testing.expect(!Renderable(NotRenderable));
    try std.testing.expect(Renderable(IsRenderable));
}

test "ViewContext type instantiation" {
    const TestView = struct {
        count: i32,

        pub fn render(self: *@This(), cx: *ViewContext(@This())) RenderOutput {
            _ = self;
            _ = cx;
            return RenderOutput.withContent();
        }
    };

    // Just verify types compile
    _ = ViewContext(TestView);
    _ = Listener(TestView);
}
