//! `Globals` — type-keyed singleton store, capped at `MAX_GLOBALS`.
//!
//! GPUI-style "set/get/update a value of type `G`" registry, indexed
//! by a comptime-stable type ID. Lets cross-cutting state (theme,
//! keymap, debugger, future: settings, telemetry, focus debugger) live
//! off `Gooey`'s direct field list while still being reachable in O(1)
//! from anywhere with a `*Cx` / `*Gooey`.
//!
//! Rationale (per `docs/cleanup-implementation-plan.md` PR 6):
//!
//! `Gooey` had grown a long tail of single-purpose fields — `keymap`,
//! `debugger`, and (historically) the theme pointer on `Builder`. Each
//! addition forced a synchronized edit across the four init paths
//! (`initOwned`, `initOwnedPtr`, `initWithSharedResources`,
//! `initWithSharedResourcesPtr`) plus `deinit`. A type-keyed registry
//! collapses that to a single `globals: Globals` field plus per-call
//! `set`/`get` at the call site that owns the policy.
//!
//! ## Design choices
//!
//! - **Fixed capacity at comptime** (`MAX_GLOBALS = 32`). Per
//!   CLAUDE.md §4 ("Put a Limit on Everything") every registry has a
//!   hard cap. Past the cap, `set` panics — the framework owns this
//!   list and 32 is far more than the audited PR 6 set (3) plus
//!   reasonable future growth.
//!
//! - **Two ownership shapes.** `setOwned(G, value)` heap-allocates a
//!   `*G` we own (deinit'd on `Globals.deinit`); `setBorrowed(G, ptr)`
//!   stores a caller-owned `*G` we never free. The first covers
//!   `Keymap` / `Debugger` (allocator-aware lifetimes); the second
//!   covers `*const Theme` (callers pass `&Theme.dark` from static
//!   storage). Mixing the shapes is illegal — `set*` checks that a
//!   slot's existing entry, if any, matches the new ownership.
//!
//! - **Type ID = `@typeName(T).ptr` interpret-as-`usize`.** Same trick
//!   used by `entity.typeId` / `drag.dragTypeId`: the Zig compiler
//!   guarantees one interned `[*:0]const u8` per type, so the pointer
//!   value is comptime-stable across the whole program. No allocation,
//!   no string compare, no `@typeInfo` recursion. Matches the existing
//!   convention in `src/context/entity.zig` so consumers don't have to
//!   learn a new ID scheme.
//!
//! - **Linear scan.** With a hard cap of 32, a tagged-array linear
//!   scan beats a hash map: no allocation, no collision logic, the
//!   whole table fits in two cache lines, and the worst-case lookup
//!   is ~32 integer compares. `get` / `set` / `update` are all O(N)
//!   with a tiny N — and called once per accessor, not per frame
//!   element.
//!
//! - **No RAII handles.** The registry is `set`-once-per-key by
//!   convention; teardown is `Globals.deinit`. We do not yet expose
//!   `remove`. If a future need arises, add it then — premature
//!   removal API is a footgun for the static-lifetime cases (theme).
//!
//! ## Phase interaction
//!
//! `Globals` carries no `DrawPhase` assertions itself — globals are
//! read from every phase (theme during prepaint and paint, keymap
//! during input dispatch, debugger across the entire frame). Phase
//! restrictions live on the **callers** that read or mutate the
//! payload, not on the registry that locates it.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Limits
// =============================================================================
//
// 32 is generous: PR 6 lands with three globals (theme, keymap,
// debugger). Future PRs (focus debugger, settings, telemetry) push
// the count toward ~10. Doubling that gives headroom without bloating
// the table — the entry struct is small enough that the whole array
// fits in two 64-byte cache lines on a 64-bit target.

pub const MAX_GLOBALS: u32 = 32;

// =============================================================================
// Type ID
// =============================================================================

/// Comptime-stable type identifier. Same shape and value space as
/// `entity.typeId` so future consolidation is mechanical.
///
/// The pointer to `@typeName(T)` is interned by the compiler and
/// stable for the lifetime of the program. Casting it to `usize`
/// gives us a cheap key with zero runtime cost and no allocation.
pub const TypeId = usize;

/// Get a unique, comptime-stable type ID for `T`.
pub fn typeId(comptime T: type) TypeId {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

// =============================================================================
// Storage
// =============================================================================

/// Ownership tag for a slot. Keeping this explicit (rather than e.g.
/// "a non-null `deinit_fn` means owned") makes the invariant readable
/// at the assertion sites and survives a future where some borrowed
/// pointers grow optional teardown hooks.
const Ownership = enum(u8) {
    /// Slot is unused. `ptr` is undefined.
    empty = 0,
    /// `ptr` was heap-allocated by `setOwned`. We free + deinit on
    /// `Globals.deinit`.
    owned = 1,
    /// `ptr` is a caller-managed mutable `*G`. We never free it.
    /// `deinit_fn` is always null for this variant.
    borrowed = 2,
    /// `ptr` is a caller-managed `*const G` (the underlying value is
    /// immutable from our side — typically `&Theme.dark`). Stored as
    /// an opaque pointer with const-ness re-applied at lookup. `get`
    /// refuses to hand out a mutable view of a const slot;
    /// `getConst` is the only legal accessor. `deinit_fn` is always
    /// null for this variant.
    borrowed_const = 3,
};

/// One row in the globals table. `extern`-free so the layout stays
/// tight: the four fields pack into 32 bytes on a 64-bit target,
/// which puts a full table at exactly 1 KiB (`32 * 32`) — small
/// enough to embed inline in `Gooey` without forcing a heap split.
const Entry = struct {
    /// `typeId(G)` for whichever `G` this slot stores, or 0 when
    /// `ownership == .empty`.
    type_id: TypeId,

    /// Type-erased pointer to the stored value. Always the address of
    /// the actual `G` — no double-indirection. For `setOwned` this is
    /// the heap allocation we made; for `setBorrowed` this is the
    /// caller's pointer.
    ptr: ?*anyopaque,

    /// Destructor for owned entries. Captures the `G` type at
    /// `setOwned` time so `Globals.deinit` can call `G.deinit` (if
    /// declared) and free the allocation without re-reflecting on
    /// `G`. Always null for borrowed and empty entries.
    deinit_fn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    ownership: Ownership,

    const empty = Entry{
        .type_id = 0,
        .ptr = null,
        .deinit_fn = null,
        .ownership = .empty,
    };
};

// =============================================================================
// Globals
// =============================================================================

/// Type-keyed singleton store. Embedded by-value on `Gooey`.
///
/// Default-constructed via `.{}`: every slot starts as `Entry.empty`,
/// no allocations, no setup. Real values arrive via `setOwned` /
/// `setBorrowed` after the rest of the frame context is wired up.
pub const Globals = struct {
    /// Backing table. Linear-scanned on every access; see the module
    /// doc for why a hash map would be slower at this size.
    entries: [MAX_GLOBALS]Entry = @splat(Entry.empty),

    /// High-water mark. Lookups scan `[0, count)` rather than the
    /// full capacity, so a sparsely-populated table stays fast. Never
    /// decrements (we don't expose `remove`); when we do, this becomes
    /// a denser invariant to maintain.
    count: u32 = 0,

    const Self = @This();

    // -------------------------------------------------------------------------
    // Lookups
    // -------------------------------------------------------------------------

    /// Return a mutable pointer to the stored `G`, or `null` if no
    /// slot is set. Lifetime: tied to `Globals` for owned entries and
    /// to the caller for borrowed entries — do not store across a
    /// `Globals.deinit`.
    ///
    /// Panics if the slot exists but was registered via
    /// `setBorrowedConst` — handing out a mutable view of an
    /// immutable global is a soundness bug, not a runtime fallback.
    /// Use `getConst` for read-only access.
    pub fn get(self: *Self, comptime G: type) ?*G {
        const id = typeId(G);
        const used = self.count;
        std.debug.assert(used <= MAX_GLOBALS);

        var i: u32 = 0;
        while (i < used) : (i += 1) {
            const entry = self.entries[i];
            if (entry.ownership == .empty) continue;
            if (entry.type_id != id) continue;

            // Defensive: an empty slot shouldn't have a non-null ptr,
            // but assert it anyway so a future `remove` that forgets
            // to clear `ptr` fails here rather than miscompiling.
            std.debug.assert(entry.ptr != null);

            // Refuse to alias a const-borrowed slot as `*G`. Phrased
            // positively (CLAUDE.md §11): the caller's invariant is
            // "this slot was registered mutably". If that does not
            // hold, fail loudly rather than silently returning a
            // pointer that violates the borrow's promise.
            if (entry.ownership == .borrowed_const) {
                std.debug.panic(
                    "Globals.get({s}): slot was registered via setBorrowedConst; " ++
                        "use getConst instead",
                    .{@typeName(G)},
                );
            }
            return @ptrCast(@alignCast(entry.ptr.?));
        }
        return null;
    }

    /// Return a `*const G` view of the stored value. Works for every
    /// ownership shape — owned, borrowed, and borrowed-const all
    /// degrade cleanly to a const view.
    ///
    /// Convenience for readers that want the type system to enforce
    /// immutability at the call site (e.g. `theme()` accessors).
    pub fn getConst(self: *Self, comptime G: type) ?*const G {
        const id = typeId(G);
        const used = self.count;
        std.debug.assert(used <= MAX_GLOBALS);

        var i: u32 = 0;
        while (i < used) : (i += 1) {
            const entry = self.entries[i];
            if (entry.ownership == .empty) continue;
            if (entry.type_id != id) continue;

            std.debug.assert(entry.ptr != null);
            return @ptrCast(@alignCast(entry.ptr.?));
        }
        return null;
    }

    /// `true` when a slot for `G` is currently set, regardless of
    /// ownership shape. Implemented against `getConst` so const-only
    /// slots are visible.
    pub fn has(self: *Self, comptime G: type) bool {
        return self.getConst(G) != null;
    }

    // -------------------------------------------------------------------------
    // Mutators
    // -------------------------------------------------------------------------

    /// Heap-allocate a copy of `value` and register it under `G`.
    ///
    /// We own the allocation. On `Globals.deinit`, if `G` exposes a
    /// `pub fn deinit(*G) void` or `pub fn deinit(*G, Allocator) void`
    /// we call it before freeing. This matches the `Keymap` /
    /// `Debugger` lifetime — both have allocator-aware teardown — so
    /// the registry can swallow them without forcing the caller to
    /// remember the right `deinit` shape.
    ///
    /// Re-setting an existing owned slot is illegal: the framework
    /// owns the global list and overwriting in place would silently
    /// leak the previous payload. Catch it loudly. (If a future need
    /// arises for "replace", add a dedicated `replaceOwned` that
    /// deinits the old value explicitly.)
    pub fn setOwned(
        self: *Self,
        allocator: std.mem.Allocator,
        comptime G: type,
        value: G,
    ) !void {
        const id = typeId(G);
        // Slot must not already exist for `G` — see doc comment
        // above on the no-overwrite policy.
        std.debug.assert(!self.has(G));
        std.debug.assert(self.count < MAX_GLOBALS);

        const slot = try allocator.create(G);
        errdefer allocator.destroy(slot);
        slot.* = value;

        const idx = self.count;
        self.entries[idx] = .{
            .type_id = id,
            .ptr = @ptrCast(slot),
            .deinit_fn = makeOwnedDeinit(G),
            .ownership = .owned,
        };
        self.count = idx + 1;

        // Pair-assert (CLAUDE.md §3): slot we just wrote must read
        // back. Catches a future refactor that forgets to bump
        // `count` or writes to the wrong index.
        std.debug.assert(self.has(G));
    }

    /// Register a caller-owned mutable `*G`. We never free this
    /// pointer; the caller's lifetime must outlive the `Globals` (or
    /// the caller must clear the slot before destroying the pointee
    /// — not supported in this PR, see module doc).
    pub fn setBorrowed(
        self: *Self,
        comptime G: type,
        ptr: *G,
    ) void {
        const id = typeId(G);
        std.debug.assert(!self.has(G));
        std.debug.assert(self.count < MAX_GLOBALS);
        std.debug.assert(@intFromPtr(ptr) != 0);

        const idx = self.count;
        self.entries[idx] = .{
            .type_id = id,
            .ptr = @ptrCast(ptr),
            .deinit_fn = null,
            .ownership = .borrowed,
        };
        self.count = idx + 1;

        std.debug.assert(self.has(G));
    }

    /// Register a caller-owned `*const G`. We never free the pointer
    /// and we never hand out a mutable view of it — `get(G)` panics
    /// for const-borrowed slots; only `getConst(G)` succeeds.
    ///
    /// Useful for `*const Theme` where the value lives in static
    /// storage (`Theme.light` / `Theme.dark`) and the registry only
    /// needs to hold a pointer.
    pub fn setBorrowedConst(
        self: *Self,
        comptime G: type,
        ptr: *const G,
    ) void {
        const id = typeId(G);
        std.debug.assert(!self.has(G));
        std.debug.assert(self.count < MAX_GLOBALS);
        std.debug.assert(@intFromPtr(ptr) != 0);

        const idx = self.count;
        self.entries[idx] = .{
            .type_id = id,
            // Stash the const pointer as opaque. Re-applied as
            // `*const G` only on the `getConst` lookup path.
            .ptr = @ptrCast(@constCast(ptr)),
            .deinit_fn = null,
            .ownership = .borrowed_const,
        };
        self.count = idx + 1;

        std.debug.assert(self.has(G));
    }

    /// Replace the borrowed pointer for `G`. Asserts that the slot,
    /// if it exists, was originally registered as `borrowed` —
    /// re-pointing an owned slot would skip its deinit and leak;
    /// re-pointing a const slot would erase the `*const` promise.
    pub fn replaceBorrowed(
        self: *Self,
        comptime G: type,
        ptr: *G,
    ) void {
        const id = typeId(G);
        std.debug.assert(@intFromPtr(ptr) != 0);

        const used = self.count;
        var i: u32 = 0;
        while (i < used) : (i += 1) {
            const entry = &self.entries[i];
            if (entry.type_id != id) continue;
            if (entry.ownership == .empty) continue;

            // Asserting ownership == .borrowed (not "!= .owned") is
            // the positive form per CLAUDE.md §11.
            std.debug.assert(entry.ownership == .borrowed);
            entry.ptr = @ptrCast(ptr);
            return;
        }
        // No existing slot: register fresh.
        self.setBorrowed(G, ptr);
    }

    /// Replace the const-borrowed pointer for `G`. This is the
    /// `cx.setTheme(&Theme.dark)` call shape — users swap themes at
    /// runtime, the storage is always `*const Theme`. Asserts the
    /// existing slot, if any, was registered via `setBorrowedConst`.
    pub fn replaceBorrowedConst(
        self: *Self,
        comptime G: type,
        ptr: *const G,
    ) void {
        const id = typeId(G);
        std.debug.assert(@intFromPtr(ptr) != 0);

        const used = self.count;
        var i: u32 = 0;
        while (i < used) : (i += 1) {
            const entry = &self.entries[i];
            if (entry.type_id != id) continue;
            if (entry.ownership == .empty) continue;

            std.debug.assert(entry.ownership == .borrowed_const);
            entry.ptr = @ptrCast(@constCast(ptr));
            return;
        }
        // No existing slot: register fresh.
        self.setBorrowedConst(G, ptr);
    }

    /// Apply `mutator(*G)` to the stored value. Returns `false` if
    /// the slot is empty (caller can decide whether that's an error).
    /// Convenience for the GPUI `update`-style call site.
    pub fn update(
        self: *Self,
        comptime G: type,
        mutator: fn (*G) void,
    ) bool {
        const ptr = self.get(G) orelse return false;
        mutator(ptr);
        return true;
    }

    // -------------------------------------------------------------------------
    // Teardown
    // -------------------------------------------------------------------------

    /// Drop every owned entry. Borrowed (mutable and const) entries
    /// are left untouched — their lifetimes belong to the caller.
    /// Safe to call multiple times; the second call walks an
    /// all-`.empty` table.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        const used = self.count;
        std.debug.assert(used <= MAX_GLOBALS);

        var i: u32 = 0;
        while (i < used) : (i += 1) {
            const entry = &self.entries[i];
            switch (entry.ownership) {
                .empty => continue,
                .borrowed, .borrowed_const => {
                    // Caller owns the pointer; just clear our slot.
                    entry.* = Entry.empty;
                },
                .owned => {
                    // `ptr` and `deinit_fn` are non-null for owned
                    // entries — the `setOwned` path enforces this.
                    std.debug.assert(entry.ptr != null);
                    std.debug.assert(entry.deinit_fn != null);
                    entry.deinit_fn.?(entry.ptr.?, allocator);
                    entry.* = Entry.empty;
                },
            }
        }
        self.count = 0;
    }
};

// =============================================================================
// Internal helpers
// =============================================================================

/// Build a type-erased deinit thunk for an owned `G`. Calls
/// `G.deinit` if it exists (in either the `(*G) void` or
/// `(*G, Allocator) void` shape) and then frees the allocation.
///
/// Done as a comptime closure so the right shape is selected once at
/// `setOwned` time and the resulting function pointer lives in
/// rodata. No runtime reflection on the hot path.
fn makeOwnedDeinit(
    comptime G: type,
) *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const Thunk = struct {
        fn run(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const typed: *G = @ptrCast(@alignCast(ptr));
            // `@hasDecl` is only legal on container types (struct /
            // enum / union / opaque). Primitives like `u8` have no
            // decl namespace — guard against them before reflecting
            // so `setOwned(allocator, u8, 3)` is a legal call shape
            // (just with no `deinit` hook).
            if (comptime hasDeinit(G)) {
                const Deinit = @TypeOf(G.deinit);
                const info = @typeInfo(Deinit);
                if (info == .@"fn") {
                    const params = info.@"fn".params;
                    // Two supported shapes — keep the branches
                    // explicit so the compile error for an
                    // unsupported shape is informative.
                    if (params.len == 1) {
                        typed.deinit();
                    } else if (params.len == 2) {
                        typed.deinit(allocator);
                    } else {
                        @compileError(
                            "Globals.setOwned: " ++ @typeName(G) ++
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

/// `@hasDecl(G, "deinit")` guarded by a container-type check.
///
/// `@hasDecl` is a compile error on primitives (`u8`, `f32`, ...) and
/// pointers — it is only defined for container types. Threading the
/// guard through a comptime helper keeps the call site at
/// `makeOwnedDeinit` readable and makes the rule reusable if another
/// reflection helper grows here.
fn hasDeinit(comptime G: type) bool {
    const info = @typeInfo(G);
    return switch (info) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(G, "deinit"),
        else => false,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "typeId is stable across calls and distinct across types" {
    const A = struct { x: u32 };
    const B = struct { x: u32 };

    try testing.expectEqual(typeId(A), typeId(A));
    try testing.expect(typeId(A) != typeId(B));
}

test "Globals: setBorrowed + get round-trip" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    var theme_value: u32 = 42;
    g.setBorrowed(u32, &theme_value);

    const got = g.get(u32) orelse return error.MissingGlobal;
    try testing.expectEqual(@as(u32, 42), got.*);
    try testing.expect(got == &theme_value);
}

test "Globals: setOwned heap-allocates a copy and deinit frees it" {
    var g = Globals{};

    const Payload = struct {
        x: u32,
        deinit_called: *bool,

        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };

    var deinit_called = false;
    try g.setOwned(testing.allocator, Payload, .{
        .x = 7,
        .deinit_called = &deinit_called,
    });

    const got = g.get(Payload) orelse return error.MissingGlobal;
    try testing.expectEqual(@as(u32, 7), got.x);

    g.deinit(testing.allocator);
    try testing.expect(deinit_called);
}

test "Globals: setOwned supports allocator-aware deinit" {
    var g = Globals{};

    const Payload = struct {
        buf: []u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
        }
    };

    const buf = try testing.allocator.alloc(u8, 16);
    try g.setOwned(testing.allocator, Payload, .{ .buf = buf });

    g.deinit(testing.allocator);
}

test "Globals: distinct types live side-by-side" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    var a: u32 = 1;
    var b: i64 = 2;
    g.setBorrowed(u32, &a);
    g.setBorrowed(i64, &b);

    try testing.expectEqual(@as(u32, 1), g.get(u32).?.*);
    try testing.expectEqual(@as(i64, 2), g.get(i64).?.*);
}

test "Globals: get returns null for unregistered types" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    try testing.expect(g.get(u32) == null);
    try testing.expect(!g.has(u32));
}

test "Globals: replaceBorrowed swaps the pointer for an existing slot" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    var a: u32 = 1;
    var b: u32 = 2;
    g.setBorrowed(u32, &a);
    try testing.expectEqual(@as(u32, 1), g.get(u32).?.*);

    g.replaceBorrowed(u32, &b);
    try testing.expectEqual(@as(u32, 2), g.get(u32).?.*);

    // Count should not have grown — replacement, not insertion.
    try testing.expectEqual(@as(u32, 1), g.count);
}

test "Globals: replaceBorrowed registers when slot is missing" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    var a: u32 = 5;
    g.replaceBorrowed(u32, &a);
    try testing.expectEqual(@as(u32, 5), g.get(u32).?.*);
}

test "Globals: setBorrowedConst + getConst round-trip" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    const value: u32 = 99;
    g.setBorrowedConst(u32, &value);

    const got = g.getConst(u32) orelse return error.MissingGlobal;
    try testing.expectEqual(@as(u32, 99), got.*);
    try testing.expect(got == &value);
    try testing.expect(g.has(u32));
}

test "Globals: replaceBorrowedConst swaps the const pointer" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    const a: u32 = 1;
    const b: u32 = 2;
    g.setBorrowedConst(u32, &a);
    try testing.expectEqual(@as(u32, 1), g.getConst(u32).?.*);

    g.replaceBorrowedConst(u32, &b);
    try testing.expectEqual(@as(u32, 2), g.getConst(u32).?.*);

    // Replacement, not insertion — count stays at 1.
    try testing.expectEqual(@as(u32, 1), g.count);
}

test "Globals: replaceBorrowedConst registers when slot is missing" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    const v: u32 = 7;
    g.replaceBorrowedConst(u32, &v);
    try testing.expectEqual(@as(u32, 7), g.getConst(u32).?.*);
}

test "Globals: getConst reads through every ownership shape" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    var mutable: u32 = 1;
    const immutable: i64 = 2;

    g.setBorrowed(u32, &mutable);
    g.setBorrowedConst(i64, &immutable);
    try g.setOwned(testing.allocator, u8, 3);

    try testing.expectEqual(@as(u32, 1), g.getConst(u32).?.*);
    try testing.expectEqual(@as(i64, 2), g.getConst(i64).?.*);
    try testing.expectEqual(@as(u8, 3), g.getConst(u8).?.*);
}

test "Globals: update applies a mutator to the stored value" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    var v: u32 = 1;
    g.setBorrowed(u32, &v);

    const Mut = struct {
        fn bump(p: *u32) void {
            p.* += 41;
        }
    };
    try testing.expect(g.update(u32, Mut.bump));
    try testing.expectEqual(@as(u32, 42), v);
}

test "Globals: update returns false for unregistered types" {
    var g = Globals{};
    defer g.deinit(testing.allocator);

    const Mut = struct {
        fn bump(p: *u32) void {
            p.* += 1;
        }
    };
    try testing.expect(!g.update(u32, Mut.bump));
}

test "Globals: deinit clears all slots and is idempotent" {
    var g = Globals{};

    var v: u32 = 1;
    g.setBorrowed(u32, &v);
    try testing.expectEqual(@as(u32, 1), g.count);

    g.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), g.count);
    try testing.expect(g.get(u32) == null);

    // Second call must be a no-op.
    g.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), g.count);
}

test "MAX_GLOBALS is the documented capacity" {
    // Pin the constant so a future bump (or accidental shrink)
    // surfaces in the test diff.
    try testing.expectEqual(@as(u32, 32), MAX_GLOBALS);
}

test "Entry packs into a small struct" {
    // Soft assertion on layout: the table embeds in `Gooey`, so
    // bloating `Entry` would leak into the parent's stack budget.
    // The exact size depends on pointer width; on a 64-bit target
    // we expect something in the 24..40 byte range.
    if (@sizeOf(usize) == 8) {
        try testing.expect(@sizeOf(Entry) <= 40);
    }
}
