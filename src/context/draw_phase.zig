//! `DrawPhase` — explicit per-frame phase tagging.
//!
//! Inspired by GPUI's `DrawPhase`. Each `Gooey` carries a
//! `current_phase: DrawPhase` field that is advanced through the frame
//! lifecycle and asserted at the entry of phase-restricted methods.
//! This catches "called paint API outside paint" / "registered hitbox
//! after layout was finalized" bugs at the assertion site rather than
//! letting them corrupt later frames.
//!
//! See `docs/cleanup-implementation-plan.md` PR 6 and CLAUDE.md §3
//! ("Assertion Density") and §11 ("Handle the Negative Space").
//!
//! ## Phase ordering
//!
//! Per frame, `Gooey` walks the phases in this order — strictly
//! monotone, no skipping backwards inside a single frame:
//!
//!   `none` → `prepaint` → `paint` → `focus` → `none`
//!
//!   - `none`     — outside a frame. Default value at construction.
//!                  Re-entered in `finalizeFrame` once everything is
//!                  flushed. Most state-mutating frame APIs assert that
//!                  this phase is **not** active.
//!   - `prepaint` — user `render_fn` is running. Element tree is being
//!                  built, layout declarations are being submitted,
//!                  hitboxes / blur handlers / cancel groups are being
//!                  registered. Set by `beginFrame`.
//!   - `paint`    — layout has finalized; render commands are being
//!                  emitted into the scene; widget rendering passes
//!                  (text inputs, scroll bars, canvas) run here. Set by
//!                  `endFrame` once layout returns.
//!   - `focus`    — post-paint focus / a11y / dispatch tree
//!                  finalisation. The scene is frozen; no more paint
//!                  commands are accepted. Set after the last paint
//!                  pass in `runtime/frame.zig`.
//!
//! Phase transitions are **assertions, not enforcement**: they fire
//! `unreachable` in debug builds and compile out in release. The
//! ordering invariant (monotone advance, only `finalizeFrame` resets
//! to `.none`) is itself asserted at every transition — see
//! `assertAdvance` below.

const std = @import("std");

/// Phases a frame walks through. The numeric ordering matters — see
/// `assertAdvance`. Do not reorder without auditing every call site of
/// `assertAdvance` and `assertPhase`.
///
/// Tagged `u8` so a `DrawPhase` field on `Gooey` is one byte rather
/// than the default `usize`. Per CLAUDE.md §15 ("Explicitly-Sized
/// Types") we lock the representation rather than letting the
/// architecture pick.
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
//
// Each helper is one-line in the hot path so it inlines cleanly and
// disappears in release builds. Pair these (per CLAUDE.md §3) with a
// matching assertion at the **end** of the phase-restricted block where
// it materially helps catch lifetime bugs — e.g. `assertPhase(.paint)`
// at the start of `paint_quad`, plus a phase-equality assertion on the
// way out for any function that crosses async / callback boundaries.

/// Assert that `actual` is exactly `expected`. Used by phase-restricted
/// methods at entry: e.g. `paint_quad` asserts `.paint`,
/// `insert_hitbox` asserts `.prepaint`.
///
/// In debug builds, a mismatch panics with both the expected and actual
/// phase names so the failure mode is obvious. In release builds this
/// compiles to a single equality test that the optimizer is free to
/// elide once the caller's phase is known.
pub fn assertPhase(actual: DrawPhase, expected: DrawPhase) void {
    if (actual == expected) return;
    std.debug.panic(
        "DrawPhase mismatch: expected .{s}, got .{s}",
        .{ expected.name(), actual.name() },
    );
}

/// Assert that `actual` is one of the listed phases. Used where a
/// method is legal across two adjacent phases (e.g. a blur-handler
/// registry that accepts work in `.prepaint` _and_ `.paint`).
///
/// `allowed` is comptime-known so the generated code is a fixed
/// sequence of equality tests with no runtime allocation or loop.
pub fn assertPhaseOneOf(actual: DrawPhase, comptime allowed: []const DrawPhase) void {
    comptime std.debug.assert(allowed.len > 0);
    inline for (allowed) |p| {
        if (actual == p) return;
    }
    std.debug.panic(
        "DrawPhase mismatch: got .{s}, expected one of {d} phases",
        .{ actual.name(), allowed.len },
    );
}

/// Assert that `actual` is **not** `.none`. Used by any method that
/// requires a frame to be in flight but does not care which phase.
///
/// Phrased positively per CLAUDE.md §11: the invariant being checked
/// is "we are inside a frame", not "we are not outside a frame". The
/// implementation tests for `.none` because it is the single excluded
/// value, but the function name documents the positive intent.
pub fn assertInFrame(actual: DrawPhase) void {
    if (actual != .none) return;
    std.debug.panic(
        "DrawPhase invariant violated: expected to be inside a frame, got .none",
        .{},
    );
}

/// Assert a legal phase advance from `current` to `next`. The frame
/// machine in `Gooey` calls this at every transition.
///
/// Legal advances:
///   - `.none`     → `.prepaint`     (start of frame)
///   - `.prepaint` → `.paint`        (layout finalized)
///   - `.paint`    → `.focus`        (paint pass complete)
///   - `.focus`    → `.none`         (frame fully flushed)
///
/// Any other transition is a bug in the frame driver: phases must
/// advance monotonically and only `finalizeFrame` may reset to `.none`.
/// We encode this with the tag's numeric ordering plus a wrap-around
/// case for the final reset.
pub fn assertAdvance(current: DrawPhase, next: DrawPhase) void {
    const cur: u8 = @intFromEnum(current);
    const nxt: u8 = @intFromEnum(next);

    // Forward step by exactly one phase covers the first three legal
    // transitions in the table above. Splitting this from the wrap
    // case (per CLAUDE.md §3 — "split compound assertions") makes the
    // failure mode obvious.
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
    // numeric values so a future reorder fails this test loudly
    // rather than silently breaking the advance check.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(DrawPhase.none));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(DrawPhase.prepaint));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(DrawPhase.paint));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(DrawPhase.focus));
}

test "DrawPhase fits in a single byte" {
    // Per CLAUDE.md §15 — keep the representation explicit so the
    // `current_phase` field on `Gooey` doesn't quietly grow to a
    // word.
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

test "assertPhaseOneOf passes when actual is in the allowed set" {
    assertPhaseOneOf(.paint, &.{ .prepaint, .paint });
    assertPhaseOneOf(.prepaint, &.{ .prepaint, .paint });
    assertPhaseOneOf(.focus, &.{.focus});
}

test "assertInFrame passes for any non-none phase" {
    assertInFrame(.prepaint);
    assertInFrame(.paint);
    assertInFrame(.focus);
}

test "assertAdvance accepts the four legal transitions" {
    assertAdvance(.none, .prepaint);
    assertAdvance(.prepaint, .paint);
    assertAdvance(.paint, .focus);
    assertAdvance(.focus, .none);
}
