//! `BlurHandlerRegistry` — fixed-capacity store of "fire this handler
//! when the named focusable is about to be blurred."
//!
//! Backed by `SubscriberSet([]const u8, HandlerRef, ...)`. The slice
//! key uses a content-equality comparator (`std.mem.eql`) so
//! re-registering the same `id` on consecutive frames replaces in
//! place rather than leaking a slot per frame. Past the cap the
//! registry returns `.dropped` and the caller logs a warning.
//!
//! `invoked_this_transition` is a re-entrancy latch: a single focus
//! change passes through several call sites that must agree on whether
//! the handler set has already fired this transition.
//!
//! The registry does not reach outward. `Window` keeps the walk over
//! its widget stores and asks `getHandler(id)` per focused widget, so
//! widget types never leak back into `context/`.

const std = @import("std");

const handler_mod = @import("handler.zig");
const HandlerRef = handler_mod.HandlerRef;

const subscriber_set_mod = @import("subscriber_set.zig");
const SubscriberSet = subscriber_set_mod.SubscriberSet;
const Insertion = subscriber_set_mod.Insertion;

// =============================================================================
// Capacity caps
// =============================================================================

/// Hard cap on simultaneously-registered blur handlers. A frame would
/// have to mount more than 64 distinct text fields with `.on_blur`
/// handlers to hit this — well above any realistic UI density. Past
/// the cap we drop with a warning rather than crash.
pub const MAX_BLUR_HANDLERS: u32 = 64;

/// Upper bound on field IDs — a loud-fast check against
/// accidentally-truncated heap garbage being passed in as an ID.
pub const MAX_BLUR_HANDLER_ID_LENGTH: usize = 256;

// =============================================================================
// Backing set
// =============================================================================
//
// Slice-keyed sets need a content-equality comparator — the default
// `std.meta.eql` would compare `(ptr, len)` tuples and miss the case
// where two identical IDs come in via different backing storage
// (e.g. one from the layout arena, one from a heap-duped string).

const Set = SubscriberSet([]const u8, HandlerRef, .{
    .capacity = MAX_BLUR_HANDLERS,
    .keysEqual = struct {
        fn eq(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.eq,
});

// =============================================================================
// BlurHandlerRegistry
// =============================================================================

pub const BlurHandlerRegistry = struct {
    /// Slot map of `id -> handler`. Wrapped in a generic so the
    /// invariants (dense prefix, swap-remove, capacity cap) live in
    /// one tested place rather than re-invented per registry.
    handlers: Set,

    /// Re-entrancy guard for a focus transition. Without it, the same
    /// `on_blur` callback would fire 2–3 times per transition as a
    /// focus change passes through several call sites. Set on first
    /// invocation, cleared by the runtime once the transition is done.
    invoked_this_transition: bool = false,

    const Self = @This();

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /// Empty registry. Use this in by-value init paths.
    pub fn init() Self {
        return .{
            .handlers = Set.init(),
            .invoked_this_transition = false,
        };
    }

    /// In-place initialization for sets embedded in a large parent
    /// struct. Field-by-field to avoid a stack temp, delegating to the
    /// generic's own `initInPlace`.
    pub fn initInPlace(self: *Self) void {
        self.handlers.initInPlace();
        self.invoked_this_transition = false;
    }

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    /// Register or replace the blur handler for `id`.
    ///
    /// At capacity the call drops with a warning rather than a hard
    /// failure — UI rendering should not crash on a degenerate widget
    /// tree, and the limit is high enough that hitting it indicates a
    /// real bug elsewhere worth surfacing in logs.
    pub fn register(self: *Self, id: []const u8, handler: HandlerRef) void {
        // Write-boundary pair-assertions: ID is non-empty (empty IDs
        // collide and signal a caller that forgot to set one) and
        // bounded (a 4 GB slice as an ID is heap garbage).
        std.debug.assert(id.len > 0);
        std.debug.assert(id.len <= MAX_BLUR_HANDLER_ID_LENGTH);

        const outcome = self.handlers.insert(id, handler);
        switch (outcome) {
            .inserted, .replaced => {},
            .dropped => {
                std.log.warn(
                    "Blur handler limit ({d}) exceeded - dropping handler for '{s}'",
                    .{ MAX_BLUR_HANDLERS, id },
                );
            },
        }
    }

    /// Drop every registered handler. Called at the start of each
    /// frame before re-walking the pending-input list: registration is
    /// per-frame because the layout arena resets every frame and the
    /// IDs would otherwise dangle.
    pub fn clearAll(self: *Self) void {
        self.handlers.clear();
        self.invoked_this_transition = false;
    }

    // -------------------------------------------------------------------------
    // Lookup
    // -------------------------------------------------------------------------

    /// Look up the handler for `id`, or `null` if none is registered.
    /// Returns the handler by value — `HandlerRef` is two words and
    /// always cheaper to copy than to indirect through a pointer that
    /// can be invalidated by `clearAll`.
    pub fn getHandler(self: *const Self, id: []const u8) ?HandlerRef {
        std.debug.assert(id.len > 0);
        std.debug.assert(id.len <= MAX_BLUR_HANDLER_ID_LENGTH);

        const cb = self.handlers.getCallback(id) orelse return null;
        return cb.*;
    }

    /// `true` iff there is a handler registered for `id`.
    pub fn contains(self: *const Self, id: []const u8) bool {
        return self.handlers.contains(id);
    }

    /// Number of currently-registered handlers.
    pub fn count(self: *const Self) u32 {
        return self.handlers.len();
    }

    // -------------------------------------------------------------------------
    // Re-entrancy guard
    // -------------------------------------------------------------------------

    /// Mark the start of a single focus transition. Returns `true`
    /// iff this is the first call since the last `endTransition` /
    /// `clearAll` — the caller uses the return to decide whether to
    /// invoke handlers or short-circuit. Folding the latch and the
    /// check into one method keeps callers from getting the order
    /// wrong.
    ///
    /// Pattern:
    /// ```
    /// if (!registry.beginTransition()) return; // already fired
    /// // … walk focused widgets, fire handlers …
    /// ```
    pub fn beginTransition(self: *Self) bool {
        if (self.invoked_this_transition) return false;
        self.invoked_this_transition = true;
        return true;
    }

    /// Mark the end of a focus transition — the next
    /// `beginTransition` will fire handlers again.
    pub fn endTransition(self: *Self) void {
        self.invoked_this_transition = false;
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: exercise the registry through the public surface that
// `Window` exposes (`register` / `clearAll` / `getHandler` / the
// transition guard). The underlying `SubscriberSet` has its own
// invariant tests; here we focus on the blur-specific semantics that
// matter to callers — content-equality of slice keys, the cap-and-warn
// behaviour, and the re-entrancy latch.

const testing = std.testing;

// A trivial no-op handler — we only care about identity, not effects.
fn noopCallback(_: *@import("window.zig").Window, _: handler_mod.EntityId) void {}

fn makeHandler() HandlerRef {
    return .{
        .callback = noopCallback,
        .entity_id = handler_mod.EntityId.invalid,
    };
}

test "BlurHandlerRegistry: init produces an empty registry" {
    const r = BlurHandlerRegistry.init();
    try testing.expectEqual(@as(u32, 0), r.count());
    try testing.expectEqual(false, r.invoked_this_transition);
}

test "BlurHandlerRegistry: initInPlace matches init" {
    var r: BlurHandlerRegistry = undefined;
    r.initInPlace();
    try testing.expectEqual(@as(u32, 0), r.count());
    try testing.expectEqual(false, r.invoked_this_transition);
}

test "BlurHandlerRegistry: register adds a new entry" {
    var r = BlurHandlerRegistry.init();
    r.register("name_field", makeHandler());

    try testing.expectEqual(@as(u32, 1), r.count());
    try testing.expect(r.contains("name_field"));
    try testing.expect(r.getHandler("name_field") != null);
    try testing.expect(r.getHandler("missing") == null);
}

test "BlurHandlerRegistry: register replaces existing entry by content" {
    var r = BlurHandlerRegistry.init();

    // Two distinct backing buffers, identical content. Without
    // content equality this would leak a slot per frame.
    const id_a: []const u8 = "field_one";
    const id_b_buf = [_]u8{ 'f', 'i', 'e', 'l', 'd', '_', 'o', 'n', 'e' };
    const id_b: []const u8 = id_b_buf[0..];

    r.register(id_a, makeHandler());
    r.register(id_b, makeHandler());

    try testing.expectEqual(@as(u32, 1), r.count());
}

test "BlurHandlerRegistry: register past cap drops without crashing" {
    var r = BlurHandlerRegistry.init();

    // Fill to capacity using stable backing strings. `comptime`
    // formatting would explode the test binary; we hand-roll unique
    // 2-char IDs from a small alphabet.
    var i: u32 = 0;
    var buf: [MAX_BLUR_HANDLERS][2]u8 = undefined;
    while (i < MAX_BLUR_HANDLERS) : (i += 1) {
        buf[i][0] = @as(u8, @intCast('a' + (i / 26)));
        buf[i][1] = @as(u8, @intCast('a' + (i % 26)));
        r.register(buf[i][0..], makeHandler());
    }
    try testing.expectEqual(MAX_BLUR_HANDLERS, r.count());

    // One past the cap: silently dropped, count unchanged.
    r.register("over_cap", makeHandler());
    try testing.expectEqual(MAX_BLUR_HANDLERS, r.count());
    try testing.expect(!r.contains("over_cap"));
}

test "BlurHandlerRegistry: clearAll empties and resets the transition guard" {
    var r = BlurHandlerRegistry.init();
    r.register("a", makeHandler());
    r.register("b", makeHandler());
    _ = r.beginTransition();

    r.clearAll();
    try testing.expectEqual(@as(u32, 0), r.count());
    try testing.expectEqual(false, r.invoked_this_transition);
}

test "BlurHandlerRegistry: beginTransition latches and endTransition resets" {
    var r = BlurHandlerRegistry.init();

    // First call wins.
    try testing.expectEqual(true, r.beginTransition());
    // Subsequent calls during the same transition are no-ops.
    try testing.expectEqual(false, r.beginTransition());
    try testing.expectEqual(false, r.beginTransition());

    r.endTransition();
    // Next transition starts fresh.
    try testing.expectEqual(true, r.beginTransition());
}
