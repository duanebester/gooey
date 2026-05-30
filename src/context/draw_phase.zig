//! `DrawPhase` — explicit per-frame phase tagging.
//!
//! `Window` carries a `current_phase` field that advances through the
//! frame lifecycle. Phase-restricted methods assert against it at entry
//! so "called a paint API outside paint" / "registered a hitbox after
//! layout finalized" bugs fail at the assertion site instead of
//! corrupting a later frame.
//!
//! Per frame the phase walks strictly monotonically, no skipping back:
//!
//!   `none` → `prepaint` → `paint` → `focus` → `none`
//!
//!   - `none`     — outside a frame (default at construction; re-entered
//!                  once the frame is flushed). Most state-mutating frame
//!                  APIs assert this is **not** active.
//!   - `prepaint` — user `render_fn` running: element tree built, layout
//!                  declared, hitboxes / blur handlers / cancel groups
//!                  registered.
//!   - `paint`    — layout finalized; render commands emitted into the
//!                  scene; widget rendering passes run.
//!   - `focus`    — post-paint focus / a11y / dispatch finalisation; the
//!                  scene is frozen.
//!
//! Transitions are assertions, not enforcement: they panic in debug and
//! compile out in release.

const std = @import("std");

/// Phases a frame walks through. Numeric ordering is load-bearing for
/// `assertAdvance` — do not reorder without auditing its call sites.
/// Tagged `u8` so the `current_phase` field stays one byte.
pub const DrawPhase = enum(u8) {
    /// Outside a frame. No paint / prepaint API is callable.
    none = 0,
    /// User `render_fn` is running; element tree is being built.
    prepaint = 1,
    /// Layout has finalized; render commands are being emitted.
    paint = 2,
    /// Post-paint focus / a11y finalisation; scene is frozen.
    focus = 3,

    /// Human-readable phase name for diagnostics.
    pub fn name(self: DrawPhase) []const u8 {
        return switch (self) {
            .none => "none",
            .prepaint => "prepaint",
            .paint => "paint",
            .focus => "focus",
        };
    }
};

// =============================================================================
// Assertion helpers
// =============================================================================

/// Assert that `actual` is exactly `expected`. Used by phase-restricted
/// methods at entry (e.g. `openElement` asserts `.prepaint`). One-line
/// so it inlines cleanly and the optimizer can elide it once the
/// caller's phase is known.
pub fn assertPhase(actual: DrawPhase, expected: DrawPhase) void {
    if (actual == expected) return;
    std.debug.panic(
        "DrawPhase mismatch: expected .{s}, got .{s}",
        .{ expected.name(), actual.name() },
    );
}

/// Assert a legal phase advance from `current` to `next`. The frame
/// machine calls this at every transition.
///
/// Legal advances: `.none`→`.prepaint`, `.prepaint`→`.paint`,
/// `.paint`→`.focus`, `.focus`→`.none`. Any other transition is a bug
/// in the frame driver — phases advance monotonically and only the
/// frame-end reset returns to `.none`.
pub fn assertAdvance(current: DrawPhase, next: DrawPhase) void {
    const cur: u8 = @intFromEnum(current);
    const nxt: u8 = @intFromEnum(next);

    // Forward step by exactly one phase covers the first three legal
    // transitions; the wrap is split out so the failure mode is clear.
    if (nxt == cur + 1) return;

    // The only legal wrap is `.focus` → `.none` at frame end.
    if (current == .focus and next == .none) return;

    std.debug.panic(
        "DrawPhase illegal advance: .{s} -> .{s}",
        .{ current.name(), next.name() },
    );
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "DrawPhase tag values are stable" {
    // The ordering is load-bearing for `assertAdvance`. Pin the
    // numeric values so a future reorder fails loudly here.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(DrawPhase.none));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(DrawPhase.prepaint));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(DrawPhase.paint));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(DrawPhase.focus));
}

test "DrawPhase fits in a single byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(DrawPhase));
}

test "DrawPhase.name returns expected strings" {
    try testing.expectEqualStrings("none", DrawPhase.none.name());
    try testing.expectEqualStrings("prepaint", DrawPhase.prepaint.name());
    try testing.expectEqualStrings("paint", DrawPhase.paint.name());
    try testing.expectEqualStrings("focus", DrawPhase.focus.name());
}

test "assertPhase passes when phases match" {
    assertPhase(.paint, .paint);
    assertPhase(.prepaint, .prepaint);
    assertPhase(.none, .none);
    assertPhase(.focus, .focus);
}

test "assertAdvance accepts the four legal transitions" {
    assertAdvance(.none, .prepaint);
    assertAdvance(.prepaint, .paint);
    assertAdvance(.paint, .focus);
    assertAdvance(.focus, .none);
}
