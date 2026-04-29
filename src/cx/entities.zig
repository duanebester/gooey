//! `cx.entities` — entity creation and access.
//!
//! This module hosts the bodies of the entity-related helpers that
//! used to live directly on `Cx`. They are accessed through the
//! `cx.entities.<name>(...)` sub-namespace, which is implemented as a
//! zero-sized field on `Cx` whose methods recover `*Cx` via
//! `@fieldParentPtr`. See `lists.zig` for the rationale.
//!
//! ## Naming inside the namespace
//!
//! The redundant `Entity` suffix is dropped now that the namespace
//! carries the grouping:
//!
//! | Old                                  | New                             |
//! | ------------------------------------ | ------------------------------- |
//! | `cx.createEntity(T, value)`          | `cx.entities.create(T, value)`  |
//! | `cx.readEntity(T, entity)`           | `cx.entities.read(T, entity)`   |
//! | `cx.writeEntity(T, entity)`          | `cx.entities.write(T, entity)`  |
//! | `cx.entityCx(T, entity)`             | `cx.entities.context(T, entity)`|
//! | `cx.attachEntityCancelGroup(id, g)`  | `cx.entities.attachCancel(id, g)` |
//! | `cx.detachEntityCancelGroup(id)`     | `cx.entities.detachCancel(id)`  |
//!
//! The original top-level methods remain as deprecated one-line
//! forwarders into this module — they will be removed in PR 9.
//!
//! Process-wide cancel-group registration (not tied to an entity)
//! stays on `Cx` itself as `cx.registerCancelGroup` /
//! `cx.unregisterCancelGroup`. Those have nothing to do with entity
//! lifetime — they are app-level groups cancelled at window close.

const std = @import("std");

const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;

const entity_mod = @import("../context/entity.zig");
const EntityId = entity_mod.EntityId;
const Entity = entity_mod.Entity;
const EntityContext = entity_mod.EntityContext;

/// Zero-sized namespace marker. Lives as the `entities` field on `Cx`
/// and recovers the parent context via `@fieldParentPtr` from each
/// method. See `lists.zig` for the rationale (CLAUDE.md §10 — don't
/// take aliases).
pub const Entities = struct {
    /// Force this ZST to inherit `Cx`'s alignment via a zero-byte
    /// `[0]usize` filler — see the matching note in `cx/lists.zig`
    /// for the rationale. Without this, the namespace field would
    /// limit `Cx`'s overall alignment to 1 and `@fieldParentPtr`
    /// would fail to compile with "increases pointer alignment".
    _align: [0]usize = .{},

    /// Recover the owning `*Cx` from this namespace field.
    inline fn cx(self: *Entities) *Cx {
        return @fieldParentPtr("entities", self);
    }

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Create a new entity with the given initial value. Returns a
    /// typed `Entity(T)` handle that can be passed to `read`, `write`,
    /// or `context`. The entity stays alive until explicitly removed
    /// (or until `Window.deinit` runs).
    pub fn create(
        self: *Entities,
        comptime T: type,
        value: T,
    ) !Entity(T) {
        // PR 7b.3 — entities lifted off `Window` onto `App`. Reach
        // through `_window.app.entities` — the borrowed `*App`
        // points at app-scope storage shared across windows.
        return self.cx()._window.app.entities.new(T, value);
    }

    // =========================================================================
    // Access
    // =========================================================================

    /// Read an entity's data (immutable). Returns `null` if the
    /// entity has been removed since its handle was issued — callers
    /// must handle this case rather than dereferencing blindly, since
    /// entity lifetimes are not statically tracked.
    pub fn read(
        self: *Entities,
        comptime T: type,
        entity: Entity(T),
    ) ?*const T {
        return self.cx()._window.readEntity(T, entity);
    }

    /// Write to an entity's data (mutable). Returns `null` if the
    /// entity has been removed.
    pub fn write(
        self: *Entities,
        comptime T: type,
        entity: Entity(T),
    ) ?*T {
        return self.cx()._window.writeEntity(T, entity);
    }

    /// Get an entity-scoped context for handlers. Returns `null` if
    /// the entity doesn't exist. The returned `EntityContext(T)` is
    /// the entity-flavored cousin of `*Cx` — use it inside handlers
    /// that are bound to a specific entity rather than the root state.
    pub fn context(
        self: *Entities,
        comptime T: type,
        entity: Entity(T),
    ) ?EntityContext(T) {
        const c = self.cx();
        // PR 7b.3 — entities live on `App`. Both the existence
        // check and the borrowed `*EntityMap` handed to the
        // `EntityContext` reach through `_window.app.entities`.
        if (!c._window.app.entities.exists(entity.id)) return null;
        return EntityContext(T){
            .window = c._window,
            .entities = &c._window.app.entities,
            .entity_id = entity.id,
        };
    }

    // =========================================================================
    // Structured cancellation
    // =========================================================================

    /// Attach a cancellation group to an entity.
    ///
    /// When the entity is removed (via `EntityContext.remove`,
    /// `EntityMap.remove`, or during `Window.deinit`), the group is
    /// cancelled automatically. This prevents use-after-free from
    /// background tasks that reference entity data.
    ///
    /// Only one group per entity. Detach before attaching a different
    /// group — the underlying `EntityMap` asserts this invariant.
    pub fn attachCancel(
        self: *Entities,
        id: EntityId,
        group: *std.Io.Group,
    ) void {
        // PR 7b.3 — cancel groups attach to entities on the
        // shared `App.entities` map.
        self.cx()._window.app.entities.attachCancelGroup(id, group);
    }

    /// Detach a cancellation group from an entity without cancelling
    /// it. Use when the async work has completed normally and the
    /// group should no longer be auto-cancelled on entity removal.
    pub fn detachCancel(self: *Entities, id: EntityId) void {
        // PR 7b.3 — see `attachCancel`.
        self.cx()._window.app.entities.detachCancelGroup(id);
    }
};
