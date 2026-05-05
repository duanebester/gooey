//! `ElementStates` — fixed-capacity, generically-typed element state pool.
//!
//! Rationale (cleanup item #11 in `docs/architectural-cleanup-plan.md`,
//! PR 8 in `docs/cleanup-implementation-plan.md`): every stateful widget
//! today gets its own per-type map on `WidgetStore` —
//! `text_inputs`, `text_areas`, `code_editors`, `scroll_containers`,
//! `select_states`, plus follow-on candidates for `uniform_list` /
//! `data_table` / `tree_list`. Adding a new stateful widget requires
//! framework edits: a new field, a new `init`/`deinit` line, a new
//! getter, a new lifecycle hook in `beginFrame`. That coupling violates
//! the "user-extensible widget" promise of the framework — only
//! framework authors can add stateful widgets, not consumers.
//!
//! The GPUI answer
//! ([§19](../../docs/architectural-cleanup-plan.md#19-with_element_stateglobal_id-fnstate---r-state))
//! is one map keyed by `(GlobalElementId, TypeId)`. Any element can attach
//! any state type without framework changes. We adopt that shape, but with
//! Gooey's static-allocation discipline:
//!
//!   - One fixed-capacity slot table (`MAX_ELEMENT_STATES = 4096`),
//!     declared at the top of the file as a hard cap. Insert past
//!     capacity returns an error so the caller surfaces the limit
//!     violation explicitly (CLAUDE.md §4 — every limit must be visible).
//!
//!   - Each entry stores a heap-allocated `*S` payload. The `(id_hash,
//!     type_id)` composite key plus a type-erased `deinit_fn` thunk lets
//!     us tear down arbitrary `S`s through one `ElementStates.deinit`
//!     call — no per-type cleanup paths leaking into the framework body.
//!
//!   - `withElementState(S, id_hash, default)` is the only mutating
//!     entry point we expose. On miss it heap-allocates a fresh `S` from
//!     `default()` and caches it; on hit it returns the cached pointer.
//!     Either way the caller gets `*S` and can read/write through it
//!     directly. `default` is a comptime function pointer so the
//!     fast-path miss costs one allocation plus one `S.init`.
//!
//! ## What this PR ships
//!
//! PR 8.1 introduces the container in isolation — no widget-side
//! migration yet. The shape is exercised through the test suite at the
//! bottom of this file. Subsequent PR 8.x slices peel widgets off
//! `WidgetStore` one at a time onto this generic, with `select_states`
//! (smallest, u32-keyed) as the natural first consumer to validate the
//! call-site shape, then `text_input` / `text_area` / `code_editor` /
//! `scroll_container` in turn. PR 8 closes when the per-type maps on
//! `WidgetStore` are all gone.
//!
//! ## Storage layout
//!
//! Backing is `[cap]?Entry` with a dense-prefix invariant — the same
//! shape as `SubscriberSet` and `Globals`, for the same reasons:
//! linear scan over `[0..count)` is cache-friendly at this size, and
//! swap-remove keeps iteration cost tied to populated slots. Total
//! footprint at `cap = 4096`:
//!
//!   - `Entry` is 32 bytes on a 64-bit target (composite key 16 B + ptr
//!     8 B + deinit_fn 8 B; compiler tightens optional tag into the
//!     pointer's null bit).
//!   - `4096 * 32 B = 128 KiB`.
//!
//! 128 KiB is too large to embed inline on the WASM stack budget
//! (CLAUDE.md §14). Callers heap-allocate `ElementStates` and use
//! `initInPlace`. The static-allocation policy is preserved: the heap
//! allocation is once, at framework init.
//!
//! ## Out of scope for PR 8.1
//!
//! - **Frame-driven eviction.** GPUI's `with_element_state` falls back
//!   to the previous frame's map if the current frame hasn't touched
//!   the element yet — `mem::swap` between `rendered_frame.element_states`
//!   and `next_frame.element_states` discards entries that weren't
//!   accessed for two consecutive frames. We don't need that yet:
//!   today's `WidgetStore` keeps state forever (no GC), so adopting
//!   the same "explicit `remove` on widget unmount" semantics is a
//!   pure refactor. Frame-driven eviction lands in a later PR alongside
//!   the rest of the GPUI `Frame` double-buffer adoption (PR 7c.3+).
//!
//! - **`with_element_state` taking a state-mutating closure.** GPUI's
//!   API consumes the state, runs `f(Option<S>, &mut Cx) -> (R, S)`,
//!   and writes back. That's natural in Rust but awkward in Zig
//!   without `comptime` capture; our shape returns a `*S` directly and
//!   leaves mutation to the caller. The semantics are equivalent — we
//!   trade a closure boundary for a borrow boundary, and Gooey's
//!   single-threaded frame loop makes the borrow safe.

const std = @import("std");

// =============================================================================
// Capacity caps
// =============================================================================

/// Hard cap on simultaneously-stored element states.
///
/// Sketch the math (per CLAUDE.md §7 — back-of-envelope before
/// implementing): `Entry` is 32 bytes; `4096 * 32 = 128 KiB`. That's
/// too large for the WASM stack so callers heap-allocate the
/// containing `ElementStates`. 4096 distinct stateful elements per
/// window is well above any realistic UI density (a long virtual list
/// of 4096 rows where every row is a stateful widget would be the
/// ceiling). Past the cap, `withElementState` returns
/// `error.ElementStatesAtCapacity` so the limit violation is visible
/// at the call site — not silently truncated.
pub const MAX_ELEMENT_STATES: u32 = 4096;

// =============================================================================
// Type ID
// =============================================================================

/// Comptime-stable type identifier. Same shape and value space as
/// `entity.typeId` and `global.typeId` so future consolidation onto a
/// single `core/type_id.zig` is a mechanical rename.
///
/// The pointer to `@typeName(T)` is interned by the compiler and
/// stable for the lifetime of the program. Casting it to `u64` gives
/// us a cheap key with zero runtime cost and no allocation.
pub const TypeId = u64;

/// Get a unique, comptime-stable type ID for `T`. Stable across
/// compilation units within one binary; not stable across binaries
/// (which is fine — `ElementStates` is a per-process structure).
pub fn typeId(comptime T: type) TypeId {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

// =============================================================================
// Composite key
// =============================================================================

/// `(element_id_hash, type_id)` — uniquely identifies a piece of
/// element state. Two elements with the same `id` but different state
/// types live in separate slots; two elements with the same state
/// type but different `id`s also live in separate slots. The product
/// of those two axes is what makes the per-type-maps on `WidgetStore`
/// redundant: one keyed pool encodes both axes.
///
/// `element_id_hash` is the `u64` returned by `ElementId.hash()` —
/// callers hash at the boundary, the pool itself never sees raw
/// `[]const u8` IDs and never owns key memory.
pub const Key = struct {
    element_id_hash: u64,
    type_id: TypeId,

    pub fn eql(a: Key, b: Key) bool {
        return a.element_id_hash == b.element_id_hash and a.type_id == b.type_id;
    }
};

// =============================================================================
// Entry
// =============================================================================

/// One slot in the table.
///
/// `ptr` is the heap-allocated `*S` cast to `*anyopaque`. We re-apply
/// the right type at the lookup site using the same `S` the caller
/// passed to `withElementState`. `deinit_fn` is the comptime-built
/// thunk that calls `S.deinit` (if declared) and frees the
/// allocation; it captures the original `S` type at insertion time so
/// teardown does not need to re-reflect on stored types at runtime.
const Entry = struct {
    key: Key,
    ptr: *anyopaque,
    deinit_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
};

// =============================================================================
// ElementStates
// =============================================================================

/// Generic element-state pool. One per `Window`.
///
/// The capacity-cap and slot-map invariants intentionally mirror
/// `SubscriberSet` and `Globals` — the discipline is uniform across
/// every keyed pool in the framework (CLAUDE.md §1, §4).
pub const ElementStates = struct {
    /// Allocator used to heap-allocate stored payloads. Borrowed for
    /// the lifetime of `ElementStates`. The pool itself does not
    /// allocate from `allocator` for its own backing — the entries
    /// array is embedded by value.
    allocator: std.mem.Allocator,

    /// Backing storage. `entries[0..count]` is the dense used prefix;
    /// everything from `count..MAX_ELEMENT_STATES` is `null` and must
    /// not be read.
    ///
    /// At 4096 entries × 32 bytes/entry this is 128 KiB. `Window`
    /// already pulls `ElementStates` in via heap allocation
    /// (`allocator.create(ElementStates)` + `initInPlace`) so the
    /// stack budget is not at risk.
    entries: [MAX_ELEMENT_STATES]?Entry,

    /// Number of populated slots. Invariant:
    /// `entries[i] != null` for all `i < count`.
    count: u32,

    const Self = @This();

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /// Empty pool. Use the by-value path for tests and other small
    /// containers; framework-level callers use `initInPlace` to keep
    /// the 128 KiB array off the stack.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .entries = @splat(null),
            .count = 0,
        };
    }

    /// In-place initialization for pools embedded in a large parent
    /// struct. Field-by-field — no struct literal, no stack temp.
    /// `noinline` so ReleaseSmall does not combine the parent's
    /// frame with ours and blow the WASM stack budget (CLAUDE.md §14).
    pub noinline fn initInPlace(self: *Self, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        // Bulk null-stomp the optional tag bytes. The compiler lowers
        // this to a memset on the optional discriminant byte for each
        // slot — equivalent to one `@memset` over the discriminant
        // bytes, but expressed in terms the type system understands.
        var i: u32 = 0;
        while (i < MAX_ELEMENT_STATES) : (i += 1) {
            self.entries[i] = null;
        }
        self.count = 0;

        // Pair-assert (CLAUDE.md §3): the just-initialised pool must
        // read back as empty. Catches a future refactor that forgets
        // to zero `count` or skips the `null` stomp.
        std.debug.assert(self.count == 0);
        std.debug.assert(self.entries[0] == null);
    }

    /// Drop every populated slot, calling each entry's `deinit_fn`.
    /// Safe to call multiple times; the second call walks an
    /// all-`null` table.
    pub fn deinit(self: *Self) void {
        std.debug.assert(self.count <= MAX_ELEMENT_STATES);

        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (self.entries[i]) |entry| {
                entry.deinit_fn(entry.ptr, self.allocator);
                self.entries[i] = null;
            } else {
                // Defensive: a `null` in the dense prefix indicates a
                // bug in `removeAt` or `withElementState`. Surface it
                // loudly rather than silently leaking the rest of the
                // table.
                unreachable;
            }
        }
        self.count = 0;
    }

    // -------------------------------------------------------------------------
    // Inspection
    // -------------------------------------------------------------------------

    /// Number of populated slots.
    pub fn len(self: *const Self) u32 {
        std.debug.assert(self.count <= MAX_ELEMENT_STATES);
        return self.count;
    }

    /// `true` iff inserting one more entry would not exceed capacity.
    pub fn hasRoom(self: *const Self) bool {
        return self.count < MAX_ELEMENT_STATES;
    }

    /// `true` iff a state of type `S` is registered for `id_hash`.
    pub fn contains(self: *const Self, comptime S: type, id_hash: u64) bool {
        return self.findIndex(.{
            .element_id_hash = id_hash,
            .type_id = typeId(S),
        }) != null;
    }

    /// Borrow a mutable pointer to the stored `S` for `id_hash`, or
    /// `null` if absent. Pointer is invalidated by any subsequent
    /// `remove` of the same key (swap-remove changes the slot's
    /// position) or by `deinit` (frees the payload).
    ///
    /// **Does not insert.** Use `withElementState` to create-on-miss.
    pub fn get(self: *Self, comptime S: type, id_hash: u64) ?*S {
        const key: Key = .{ .element_id_hash = id_hash, .type_id = typeId(S) };
        const idx = self.findIndex(key) orelse return null;
        // `entries[idx]` is non-null by `findIndex`'s post-condition.
        const entry = self.entries[idx].?;
        return @ptrCast(@alignCast(entry.ptr));
    }

    // -------------------------------------------------------------------------
    // Mutation
    // -------------------------------------------------------------------------

    /// Look up the state of type `S` for `id_hash`, creating it on miss.
    ///
    /// On miss: heap-allocates a `*S` and runs `default()` to
    /// initialise it. Caches the resulting pointer under
    /// `(id_hash, typeId(S))` and returns it. Subsequent calls with
    /// the same `(S, id_hash)` return the same pointer.
    ///
    /// On capacity exhaustion: returns `error.ElementStatesAtCapacity`.
    /// On allocator failure: returns `error.OutOfMemory`.
    ///
    /// `default` is a comptime function pointer so the miss path is
    /// one `allocator.create(S)` plus one `default()` call — no
    /// indirect call through a runtime function pointer.
    pub fn withElementState(
        self: *Self,
        comptime S: type,
        id_hash: u64,
        comptime default: fn () S,
    ) !*S {
        const key: Key = .{ .element_id_hash = id_hash, .type_id = typeId(S) };

        // Pair-assertion (CLAUDE.md §3) on the read boundary: the
        // table invariants must hold before we touch it.
        std.debug.assert(self.count <= MAX_ELEMENT_STATES);

        if (self.findIndex(key)) |idx| {
            const entry = self.entries[idx].?;
            return @ptrCast(@alignCast(entry.ptr));
        }

        // Miss path — capacity check first so a near-full table
        // surfaces the cap before we make a doomed allocation.
        if (self.count >= MAX_ELEMENT_STATES) {
            return error.ElementStatesAtCapacity;
        }

        const slot = try self.allocator.create(S);
        errdefer self.allocator.destroy(slot);

        slot.* = default();

        const idx = self.count;
        self.entries[idx] = .{
            .key = key,
            .ptr = @ptrCast(slot),
            .deinit_fn = makeDeinit(S),
        };
        self.count = idx + 1;

        // Pair-assert on the write boundary: the slot we just wrote
        // must read back. Catches a future refactor that bumps
        // `count` before the write, or writes to the wrong index.
        std.debug.assert(self.entries[idx] != null);
        std.debug.assert(self.entries[idx].?.key.eql(key));

        return slot;
    }

    /// Insert a state of type `S` for `id_hash` from a caller-provided
    /// initial value. Useful when the initial state depends on
    /// runtime context (allocator, geometry) that a comptime `default`
    /// can't capture.
    ///
    /// Asserts no entry exists for `(S, id_hash)`. Use `get` first if
    /// you need an upsert. Returning a duplicate-rejection error
    /// instead would force callers into an awkward "try insert, fall
    /// back to get" dance; the upsert is rare enough to not warrant
    /// the API surface.
    pub fn insert(
        self: *Self,
        comptime S: type,
        id_hash: u64,
        initial: S,
    ) !*S {
        const key: Key = .{ .element_id_hash = id_hash, .type_id = typeId(S) };
        std.debug.assert(self.count <= MAX_ELEMENT_STATES);
        std.debug.assert(self.findIndex(key) == null);

        if (self.count >= MAX_ELEMENT_STATES) {
            return error.ElementStatesAtCapacity;
        }

        const slot = try self.allocator.create(S);
        errdefer self.allocator.destroy(slot);
        slot.* = initial;

        const idx = self.count;
        self.entries[idx] = .{
            .key = key,
            .ptr = @ptrCast(slot),
            .deinit_fn = makeDeinit(S),
        };
        self.count = idx + 1;

        std.debug.assert(self.entries[idx] != null);
        return slot;
    }

    /// Remove the state of type `S` for `id_hash`. Calls the entry's
    /// `deinit_fn` and frees the payload. Returns `true` iff an entry
    /// was actually removed.
    pub fn remove(self: *Self, comptime S: type, id_hash: u64) bool {
        const key: Key = .{ .element_id_hash = id_hash, .type_id = typeId(S) };
        const idx = self.findIndex(key) orelse return false;
        self.removeAt(idx);
        return true;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// Linear scan over the dense prefix. O(count). The naive scan
    /// matches `Globals` and `SubscriberSet`; at this size the
    /// branch-predictor friendliness of the linear walk beats a hash
    /// map's pointer-chasing for the small-N case (most elements
    /// touch < 64 distinct states). If a profile shows otherwise we
    /// can swap in an `AutoHashMap` keyed by `Key.hash()` without
    /// changing the public surface.
    fn findIndex(self: *const Self, key: Key) ?u32 {
        std.debug.assert(self.count <= MAX_ELEMENT_STATES);
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (self.entries[i]) |entry| {
                if (entry.key.eql(key)) return i;
            } else {
                // Slots in `[0..count)` must be populated.
                unreachable;
            }
        }
        return null;
    }

    /// Swap-remove the entry at `idx`. The entry's payload is
    /// deinitialised and freed. The tail entry, if any, is moved into
    /// slot `idx` to preserve the dense-prefix invariant.
    fn removeAt(self: *Self, idx: u32) void {
        std.debug.assert(idx < self.count);
        std.debug.assert(self.count <= MAX_ELEMENT_STATES);

        const removed = self.entries[idx].?;
        removed.deinit_fn(removed.ptr, self.allocator);

        self.count -= 1;
        if (idx < self.count) {
            // Move the tail entry into `idx`. The tail slot was
            // guaranteed populated by the same dense-prefix invariant.
            self.entries[idx] = self.entries[self.count];
        }
        self.entries[self.count] = null;
    }
};

// =============================================================================
// Deinit thunk builder
// =============================================================================

/// Build a type-erased deinit thunk for `S`.
///
/// Three supported `S.deinit` shapes (mirroring `Globals.makeOwnedDeinit`
/// for consistency — same compile-time selection, same diagnostics):
///
///   1. `fn(*S) void`             — typical for self-contained state
///   2. `fn(*S, Allocator) void`  — for state that owns sub-allocations
///   3. no `deinit` method        — POD state; we just free the slot
///
/// The selected shape is captured at `withElementState` time, so the
/// teardown path is one indirect call through a function pointer in
/// rodata — no runtime reflection.
fn makeDeinit(
    comptime S: type,
) *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const Thunk = struct {
        fn run(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const typed: *S = @ptrCast(@alignCast(ptr));

            // `@hasDecl` is only legal on container types. POD
            // primitives (`u32`, `bool`) and tuples have no decl
            // namespace — guard against them so a future
            // `withElementState(u32, …)` for some scalar state is a
            // legal call shape (just with no `deinit` hook).
            if (comptime hasDeinit(S)) {
                const Deinit = @TypeOf(S.deinit);
                const info = @typeInfo(Deinit);
                if (info == .@"fn") {
                    const params = info.@"fn".params;
                    if (params.len == 1) {
                        typed.deinit();
                    } else if (params.len == 2) {
                        typed.deinit(allocator);
                    } else {
                        @compileError(
                            "ElementStates.withElementState: " ++ @typeName(S) ++
                                ".deinit must have shape fn(*Self) void or fn(*Self, Allocator) void",
                        );
                    }
                }
            }
            allocator.destroy(typed);
        }
    };
    return &Thunk.run;
}

/// `@hasDecl(S, "deinit")` guarded by a container-type check.
/// Mirrors the helper in `global.zig`.
fn hasDeinit(comptime S: type) bool {
    const info = @typeInfo(S);
    return switch (info) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(S, "deinit"),
        else => false,
    };
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: exercise every public surface of `ElementStates` —
// `init` / `initInPlace` / `withElementState` / `insert` / `get` /
// `contains` / `remove` / `deinit` — plus the corner cases that the
// invariants exist to defend against (capacity exhaustion, type-keyed
// disambiguation, payload teardown). Each test allocates the pool by
// value (small enough at test time) and uses `std.testing.allocator`
// so a leak in any teardown path fails the test.

const testing = std.testing;

test "ElementStates: init produces an empty pool" {
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    try testing.expectEqual(@as(u32, 0), states.len());
    try testing.expect(states.hasRoom());
}

test "ElementStates: initInPlace matches init shape" {
    // `initInPlace` is the path used by `Window` to keep the 128 KiB
    // entries array off the WASM stack. The pool must come out
    // identical to the by-value `init` call.
    const states = try testing.allocator.create(ElementStates);
    defer testing.allocator.destroy(states);
    states.initInPlace(testing.allocator);
    defer states.deinit();

    try testing.expectEqual(@as(u32, 0), states.len());
    try testing.expectEqual(@as(?Entry, null), states.entries[0]);
    try testing.expectEqual(@as(?Entry, null), states.entries[MAX_ELEMENT_STATES - 1]);
}

test "ElementStates: typeId distinguishes types" {
    // Two distinct types must produce distinct ids. Same-type calls
    // must produce the same id. Anything else breaks the keyed-pool
    // invariant downstream.
    const A = struct { x: u32 };
    const B = struct { y: u32 };
    try testing.expect(typeId(A) != typeId(B));
    try testing.expectEqual(typeId(A), typeId(A));
}

test "ElementStates: Key.eql compares both axes" {
    // The composite key must split on both axes: same id with
    // different type, and same type with different id, must compare
    // unequal. Without this `text_input("foo")` and
    // `text_area("foo")` would collide.
    const a: Key = .{ .element_id_hash = 1, .type_id = 100 };
    const same: Key = .{ .element_id_hash = 1, .type_id = 100 };
    const diff_id: Key = .{ .element_id_hash = 2, .type_id = 100 };
    const diff_type: Key = .{ .element_id_hash = 1, .type_id = 200 };

    try testing.expect(a.eql(same));
    try testing.expect(!a.eql(diff_id));
    try testing.expect(!a.eql(diff_type));
}

test "ElementStates: withElementState creates on miss" {
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    const Counter = struct {
        value: u32,
        pub fn defaultInit() @This() {
            return .{ .value = 42 };
        }
    };

    const ptr = try states.withElementState(Counter, 0xCAFE, Counter.defaultInit);
    try testing.expectEqual(@as(u32, 42), ptr.value);
    try testing.expectEqual(@as(u32, 1), states.len());
    try testing.expect(states.contains(Counter, 0xCAFE));
}

test "ElementStates: withElementState returns same pointer on hit" {
    // Stable pointer identity is the load-bearing invariant: callers
    // mutate state through the returned pointer and expect those
    // writes to survive across calls (and across frames). Verify the
    // second call returns the same address as the first, and that
    // mutations through that pointer are visible on subsequent reads.
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    const Counter = struct {
        value: u32,
        pub fn defaultInit() @This() {
            return .{ .value = 0 };
        }
    };

    const first = try states.withElementState(Counter, 0xBEEF, Counter.defaultInit);
    first.value = 7;

    const second = try states.withElementState(Counter, 0xBEEF, Counter.defaultInit);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(u32, 7), second.value);
    try testing.expectEqual(@as(u32, 1), states.len());
}

test "ElementStates: same id with different type allocates separate slots" {
    // The composite-key promise: `text_input("foo")` and
    // `text_area("foo")` must not collide. Use two trivially
    // distinct types under the same `id_hash`.
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    const A = struct {
        x: u32,
        pub fn defaultInit() @This() {
            return .{ .x = 11 };
        }
    };
    const B = struct {
        y: u32,
        pub fn defaultInit() @This() {
            return .{ .y = 22 };
        }
    };

    const a = try states.withElementState(A, 0xABCD, A.defaultInit);
    const b = try states.withElementState(B, 0xABCD, B.defaultInit);

    try testing.expect(@intFromPtr(a) != @intFromPtr(b));
    try testing.expectEqual(@as(u32, 11), a.x);
    try testing.expectEqual(@as(u32, 22), b.y);
    try testing.expectEqual(@as(u32, 2), states.len());
    try testing.expect(states.contains(A, 0xABCD));
    try testing.expect(states.contains(B, 0xABCD));
}

test "ElementStates: get returns null for missing entries" {
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    const T = struct {
        v: u32,
        pub fn defaultInit() @This() {
            return .{ .v = 0 };
        }
    };

    try testing.expect(states.get(T, 0x1) == null);
    try testing.expect(!states.contains(T, 0x1));

    _ = try states.withElementState(T, 0x1, T.defaultInit);
    try testing.expect(states.get(T, 0x1) != null);

    // Same type, different id — still missing.
    try testing.expect(states.get(T, 0x2) == null);
}

test "ElementStates: insert places an explicit initial value" {
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    const Settings = struct { width: u32, height: u32 };

    const ptr = try states.insert(Settings, 0xDEAD, .{ .width = 800, .height = 600 });
    try testing.expectEqual(@as(u32, 800), ptr.width);
    try testing.expectEqual(@as(u32, 600), ptr.height);
    try testing.expect(states.contains(Settings, 0xDEAD));
}

test "ElementStates: remove tears down and frees the payload" {
    // Use an allocator-aware `deinit` shape so the test fails (via a
    // testing-allocator leak report) if the thunk forgets to call
    // through.
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    const Owned = struct {
        buf: []u8,
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
        }
    };

    const buf = try testing.allocator.alloc(u8, 16);
    _ = try states.insert(Owned, 0xFEED, .{ .buf = buf });
    try testing.expectEqual(@as(u32, 1), states.len());

    try testing.expect(states.remove(Owned, 0xFEED));
    try testing.expectEqual(@as(u32, 0), states.len());
    try testing.expect(!states.contains(Owned, 0xFEED));

    // Removing again is a no-op — `remove` returns false rather
    // than panicking. That's the contract callers will rely on for
    // unmount-cleanup paths that might race with manual removal.
    try testing.expect(!states.remove(Owned, 0xFEED));
}

test "ElementStates: remove preserves dense prefix via swap-remove" {
    // Three entries of the same type with distinct ids. After
    // removing the middle one, the tail must move into the freed
    // slot so that `entries[0..count)` stays fully populated.
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    const T = struct { tag: u32 };

    _ = try states.insert(T, 0x1, .{ .tag = 1 });
    _ = try states.insert(T, 0x2, .{ .tag = 2 });
    _ = try states.insert(T, 0x3, .{ .tag = 3 });
    try testing.expectEqual(@as(u32, 3), states.len());

    try testing.expect(states.remove(T, 0x2));
    try testing.expectEqual(@as(u32, 2), states.len());

    // `1` and `3` survive; the tail (`3`) was swapped into slot 1.
    try testing.expect(states.contains(T, 0x1));
    try testing.expect(!states.contains(T, 0x2));
    try testing.expect(states.contains(T, 0x3));

    // Dense-prefix invariant holds: both populated slots are < count,
    // and slot[count] is null.
    try testing.expect(states.entries[0] != null);
    try testing.expect(states.entries[1] != null);
    try testing.expectEqual(@as(?Entry, null), states.entries[2]);
}

test "ElementStates: deinit calls each entry's teardown thunk" {
    // Insert a payload with an allocator-aware deinit, then drop the
    // pool without manual `remove`. The testing allocator's leak
    // report will catch any thunk that forgets to free the inner
    // buffer.
    var states = ElementStates.init(testing.allocator);

    const Owned = struct {
        buf: []u8,
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
        }
    };

    const buf_a = try testing.allocator.alloc(u8, 8);
    const buf_b = try testing.allocator.alloc(u8, 16);
    _ = try states.insert(Owned, 0xA, .{ .buf = buf_a });
    _ = try states.insert(Owned, 0xB, .{ .buf = buf_b });

    states.deinit();
    try testing.expectEqual(@as(u32, 0), states.len());
}

test "ElementStates: deinit handles types with no deinit (POD payloads)" {
    // POD payloads have no `deinit` method. The thunk must skip the
    // method-call branch and just free the slot. A leak here would
    // surface as the testing allocator complaining at test exit.
    var states = ElementStates.init(testing.allocator);

    const Pod = struct { a: u32, b: u32 };

    _ = try states.insert(Pod, 0x10, .{ .a = 1, .b = 2 });
    _ = try states.insert(Pod, 0x20, .{ .a = 3, .b = 4 });
    try testing.expectEqual(@as(u32, 2), states.len());

    states.deinit();
}

test "ElementStates: deinit handles allocator-less deinit shape" {
    // The `fn(*Self) void` shape — the most common one for widget
    // state that owns no sub-allocations. Drives a side-effect
    // counter through a static pointer so we can assert it was
    // actually called.
    const Tracker = struct {
        var deinit_calls: u32 = 0;
        x: u32,
        pub fn deinit(self: *@This()) void {
            _ = self;
            deinit_calls += 1;
        }
    };
    Tracker.deinit_calls = 0;

    var states = ElementStates.init(testing.allocator);
    _ = try states.insert(Tracker, 0xAA, .{ .x = 1 });
    _ = try states.insert(Tracker, 0xBB, .{ .x = 2 });

    states.deinit();
    try testing.expectEqual(@as(u32, 2), Tracker.deinit_calls);
}

test "ElementStates: withElementState past capacity returns ElementStatesAtCapacity" {
    // The capacity check must fire before any allocation. We can't
    // fake `count` and leave `entries` null — `findIndex` walks the
    // dense prefix and would hit `unreachable` on the first null
    // slot. Fill the table for real with cheap `u32`-payload entries
    // so the prefix invariant holds. 4096 small allocations is fine
    // for a once-per-test fixture.
    const states = try testing.allocator.create(ElementStates);
    defer testing.allocator.destroy(states);
    states.initInPlace(testing.allocator);
    defer states.deinit();

    const Tiny = struct {
        v: u32,
        pub fn defaultInit() @This() {
            return .{ .v = 0 };
        }
    };

    // Fill exactly to capacity with distinct ids.
    var i: u32 = 0;
    while (i < MAX_ELEMENT_STATES) : (i += 1) {
        _ = try states.insert(Tiny, @as(u64, i) + 1, .{ .v = i });
    }
    try testing.expectEqual(MAX_ELEMENT_STATES, states.len());
    try testing.expect(!states.hasRoom());

    // One past the cap with a fresh id: the capacity check must
    // surface as `error.ElementStatesAtCapacity`.
    const fresh_id: u64 = @as(u64, MAX_ELEMENT_STATES) + 100;
    try testing.expectError(
        error.ElementStatesAtCapacity,
        states.withElementState(Tiny, fresh_id, Tiny.defaultInit),
    );

    // Hitting an *existing* id at capacity must still succeed —
    // `withElementState` finds the cached entry and returns its
    // pointer without touching the cap.
    const existing = try states.withElementState(Tiny, 1, Tiny.defaultInit);
    try testing.expectEqual(@as(u32, 0), existing.v);
}

test "ElementStates: insert past capacity returns ElementStatesAtCapacity" {
    // Mirror of the `withElementState` capacity test for the
    // explicit-init `insert` path. Fill the table for real so the
    // dense-prefix invariant holds when `insert` calls `findIndex`.
    const states = try testing.allocator.create(ElementStates);
    defer testing.allocator.destroy(states);
    states.initInPlace(testing.allocator);
    defer states.deinit();

    const Tiny = struct { v: u32 };

    var i: u32 = 0;
    while (i < MAX_ELEMENT_STATES) : (i += 1) {
        _ = try states.insert(Tiny, @as(u64, i) + 1, .{ .v = i });
    }
    try testing.expectEqual(MAX_ELEMENT_STATES, states.len());

    const fresh_id: u64 = @as(u64, MAX_ELEMENT_STATES) + 100;
    try testing.expectError(
        error.ElementStatesAtCapacity,
        states.insert(Tiny, fresh_id, .{ .v = 0 }),
    );
}

test "ElementStates: hasRoom transitions at capacity boundary" {
    // `hasRoom` is the public read used by callers that want to
    // surface a graceful degradation path (e.g. "show a warning
    // banner if too many widgets are mounted"). It must flip exactly
    // at `MAX_ELEMENT_STATES`. Drive it through real inserts so the
    // boundary is exercised against the actual mutation path.
    const states = try testing.allocator.create(ElementStates);
    defer testing.allocator.destroy(states);
    states.initInPlace(testing.allocator);
    defer states.deinit();

    const Tiny = struct { v: u32 };

    var i: u32 = 0;
    while (i < MAX_ELEMENT_STATES - 1) : (i += 1) {
        _ = try states.insert(Tiny, @as(u64, i) + 1, .{ .v = i });
    }
    try testing.expect(states.hasRoom());

    _ = try states.insert(Tiny, @as(u64, MAX_ELEMENT_STATES), .{ .v = 0 });
    try testing.expect(!states.hasRoom());
}

test "ElementStates: contains is type-keyed, not just id-keyed" {
    // Insert under type `A` and ensure `contains(B, same_id)` returns
    // false. This is the inverse of the "same id, different type"
    // separation test, exercising the read side instead of the write
    // side.
    var states = ElementStates.init(testing.allocator);
    defer states.deinit();

    const A = struct { x: u32 };
    const B = struct { y: u32 };

    _ = try states.insert(A, 0x42, .{ .x = 1 });
    try testing.expect(states.contains(A, 0x42));
    try testing.expect(!states.contains(B, 0x42));
}
