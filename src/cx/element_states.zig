//! `cx.element_states` — keyed pool of per-element retained state.
//!
//! This module surfaces `Window.element_states` (PR 8.1's
//! generic `(id_hash, TypeId) -> *S` slot map) on `Cx` so widgets can
//! reach for retained state through the standard frame-context handle
//! instead of digging through `cx._window`. It mirrors GPUI's
//! [§19 `with_element_state` pattern](../../docs/architectural-cleanup-plan.md#19-with_element_stateglobal_id-fnstate---r-state)
//! adapted to Zig idioms — see "Shape delta from GPUI" below.
//!
//! ## Why a sub-namespace
//!
//! Same rationale as the other `cx/<group>.zig` files (CLAUDE.md §10
//! — don't take aliases). A zero-sized field marker on `Cx` recovers
//! `*Cx` via `@fieldParentPtr`, giving a `cx.element_states.with(...)`
//! call shape with no extra storage and no aliasing. PR 8.2 only had
//! the underlying pool reachable through `cx._window.element_states`,
//! which forced widgets that wanted a retained-state pointer to thread
//! the framework-private `_window` through every helper. PR 8.3 lifts
//! that to the public `cx.*` surface — same shape callers already use
//! for `cx.entities.*`, `cx.focus.*`, `cx.lists.*`.
//!
//! ## API surface
//!
//! Each method on `ElementStates` (the namespace marker) accepts a
//! string `id` (hashed via `LayoutId.fromString`) so callers don't
//! compute hashes by hand. Widgets that already have a `LayoutId`
//! (e.g. inside `Component.render`) can use the `*ById` variants to
//! pass the pre-computed `u32` hash directly and skip the second
//! hash. The shape mirrors the `cx.animations.tween` /
//! `cx.animations.tweenComptime` pair already used elsewhere in the
//! codebase.
//!
//! | API                              | Underlying pool call                  |
//! | -------------------------------- | ------------------------------------- |
//! | `cx.element_states.with(S, id, f)`        | `withElementState(S, hash(id), f)` |
//! | `cx.element_states.withById(S, id, f)`    | `withElementState(S, id, f)` (raw u64) |
//! | `cx.element_states.get(S, id)`            | `get(S, hash(id))`                 |
//! | `cx.element_states.getById(S, id)`        | `get(S, id)`                       |
//! | `cx.element_states.contains(S, id)`       | `contains(S, hash(id))`            |
//! | `cx.element_states.containsById(S, id)`   | `contains(S, id)`                  |
//! | `cx.element_states.insert(S, id, init)`   | `insert(S, hash(id), init)`        |
//! | `cx.element_states.insertById(S, id, v)`  | `insert(S, id, v)`                 |
//! | `cx.element_states.remove(S, id)`         | `remove(S, hash(id))`              |
//! | `cx.element_states.removeById(S, id)`     | `remove(S, id)`                    |
//!
//! ## Shape delta from GPUI's `with_element_state`
//!
//! GPUI's signature
//! `with_element_state<S, R>(global_id, |Option<S>, &mut Window| -> (R, S)) -> R`
//! threads the optional state through a closure that returns the
//! updated state (which the framework then writes back). Zig's
//! single-threaded frame loop makes the simpler `*S` borrow safe
//! without the closure-and-write-back ceremony, so `with` returns
//! `*S` directly and lets the caller mutate through the borrow. The
//! semantics are equivalent — the GPUI shape was largely about
//! borrow-checker appeasement.
//!
//! Documented in detail in `context/element_states.zig`'s "Shape
//! delta from GPUI" section; this file just surfaces the same
//! decision through the `Cx` API.

const std = @import("std");

const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;

const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;

/// Zero-sized namespace marker. Lives as the `element_states` field
/// on `Cx` and recovers the parent context via `@fieldParentPtr`
/// from each method. See `lists.zig` for the rationale (CLAUDE.md
/// §10 — don't take aliases).
pub const ElementStates = struct {
    /// Force this ZST to inherit `Cx`'s alignment via a zero-byte
    /// `[0]usize` filler — see the matching note in `cx/lists.zig`
    /// for the rationale. Without this, the namespace field would
    /// limit `Cx`'s overall alignment to 1 and `@fieldParentPtr`
    /// would fail to compile with "increases pointer alignment".
    _align: [0]usize = .{},

    /// Recover the owning `*Cx` from this namespace field.
    inline fn cx(self: *ElementStates) *Cx {
        return @fieldParentPtr("element_states", self);
    }

    /// Hash a string id to the `u64` shape the underlying pool
    /// expects. `LayoutId.fromString` returns a `u32` hash that
    /// disambiguates the framework's element ids; widening to `u64`
    /// matches the pool's `Key.element_id_hash` layout. The pool
    /// `Key` also carries the `TypeId(S)` so two different state
    /// types attached to the same `id` get separate slots — the
    /// `u64` width is purely about future-proofing the id space.
    inline fn hashId(id: []const u8) u64 {
        std.debug.assert(id.len > 0);
        return @as(u64, LayoutId.fromString(id).id);
    }

    // =========================================================================
    // Create-on-miss (`with` / `withById`)
    // =========================================================================

    /// Borrow the state of type `S` for `id`, creating it on miss.
    ///
    /// `default` is a comptime function pointer with shape
    /// `fn () S`; on miss the pool runs it once and caches the
    /// resulting value under `(hash(id), TypeId(S))`. Subsequent
    /// calls with the same `(S, id)` return the same pointer (the
    /// load-bearing invariant — see `element_states.zig`'s "stable
    /// pointer on hit" test).
    ///
    /// Errors:
    ///   * `error.OutOfMemory` — payload allocation failed.
    ///   * `error.ElementStatesAtCapacity` — the pool's
    ///     `MAX_ELEMENT_STATES` (4096) cap was hit.
    ///
    /// ```zig
    /// const ss = try cx.element_states.with(SelectState, "my-select", SelectState.defaultInit);
    /// ss.is_open = !ss.is_open;
    /// ```
    pub fn with(
        self: *ElementStates,
        comptime S: type,
        id: []const u8,
        comptime default: fn () S,
    ) !*S {
        return self.cx()._window.element_states.withElementState(S, hashId(id), default);
    }

    /// `with` with a pre-computed `u64` id hash. Use when the caller
    /// already has a `LayoutId` (or any other framework-provided
    /// hash) on hand and wants to skip the second `hashString`.
    /// Internally identical to `with` — both call the same pool
    /// method.
    pub fn withById(
        self: *ElementStates,
        comptime S: type,
        id_hash: u64,
        comptime default: fn () S,
    ) !*S {
        std.debug.assert(id_hash != 0);
        return self.cx()._window.element_states.withElementState(S, id_hash, default);
    }

    // =========================================================================
    // Lookup (`get` / `contains`)
    // =========================================================================

    /// Borrow the state of type `S` for `id`, or `null` if absent.
    /// Read-only path — does NOT create on miss. Use `with` when the
    /// caller's intent is "get-or-create"; `get` is for cases where
    /// the slot's existence is already implied by the call site
    /// (e.g. handler firing on a widget that just rendered).
    pub fn get(
        self: *ElementStates,
        comptime S: type,
        id: []const u8,
    ) ?*S {
        return self.cx()._window.element_states.get(S, hashId(id));
    }

    /// `get` with a pre-computed `u64` id hash. See `withById`.
    pub fn getById(
        self: *ElementStates,
        comptime S: type,
        id_hash: u64,
    ) ?*S {
        std.debug.assert(id_hash != 0);
        return self.cx()._window.element_states.get(S, id_hash);
    }

    /// `true` iff a state of type `S` is currently stored for `id`.
    /// Equivalent to `cx.element_states.get(S, id) != null` but
    /// avoids the `*S` materialisation when the caller only wants a
    /// presence check.
    pub fn contains(
        self: *ElementStates,
        comptime S: type,
        id: []const u8,
    ) bool {
        return self.cx()._window.element_states.contains(S, hashId(id));
    }

    /// `contains` with a pre-computed `u64` id hash. See `withById`.
    pub fn containsById(
        self: *ElementStates,
        comptime S: type,
        id_hash: u64,
    ) bool {
        std.debug.assert(id_hash != 0);
        return self.cx()._window.element_states.contains(S, id_hash);
    }

    // =========================================================================
    // Explicit insertion (`insert` / `insertById`)
    // =========================================================================

    /// Insert a state of type `S` for `id` from a caller-provided
    /// initial value. Use when the initial state depends on runtime
    /// context (allocator, geometry) that a comptime `default`
    /// can't capture.
    ///
    /// Asserts no entry exists for `(S, id)` — see the underlying
    /// `element_states.insert` doc for why this is an assert rather
    /// than an error return.
    pub fn insert(
        self: *ElementStates,
        comptime S: type,
        id: []const u8,
        initial: S,
    ) !*S {
        return self.cx()._window.element_states.insert(S, hashId(id), initial);
    }

    /// `insert` with a pre-computed `u64` id hash. See `withById`.
    pub fn insertById(
        self: *ElementStates,
        comptime S: type,
        id_hash: u64,
        initial: S,
    ) !*S {
        std.debug.assert(id_hash != 0);
        return self.cx()._window.element_states.insert(S, id_hash, initial);
    }

    // =========================================================================
    // Removal (`remove` / `removeById`)
    // =========================================================================

    /// Remove the state of type `S` for `id`. Calls the entry's
    /// `deinit_fn` and frees the payload. Returns `true` iff an
    /// entry was actually removed (i.e. the `(S, id)` pair existed).
    ///
    /// Today's widget lifecycle keeps state forever — no widget
    /// currently calls `remove`. The path is here for the
    /// frame-driven eviction work tracked in PR 8.4+ and for
    /// widgets that want explicit "drop my retained state on unmount"
    /// semantics ahead of that landing.
    pub fn remove(
        self: *ElementStates,
        comptime S: type,
        id: []const u8,
    ) bool {
        return self.cx()._window.element_states.remove(S, hashId(id));
    }

    /// `remove` with a pre-computed `u64` id hash. See `withById`.
    pub fn removeById(
        self: *ElementStates,
        comptime S: type,
        id_hash: u64,
    ) bool {
        std.debug.assert(id_hash != 0);
        return self.cx()._window.element_states.remove(S, id_hash);
    }
};
