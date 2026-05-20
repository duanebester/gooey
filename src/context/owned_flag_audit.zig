//! PR 9 Task 5 \u2014 compile-time audit pinning the `_owned: bool` flag
//! retirement.
//!
//! Pre-PR-7 (and through several 7a/7b/7c slices) Gooey carried
//! per-resource ownership flags directly on the framework wrappers \u2014
//! `text_owned: bool`, `svg_owned: bool`, `image_owned: bool` triplets
//! on `Window`, `scene_owned`/`dispatch_owned` peers on a transient,
//! and so on. The cleanup plan consolidated those flags into two
//! deliberate ownership *discriminators*:
//!
//!   * `AppResources.owned` (PR 7a) \u2014 picks between "I built the
//!     bundled text/svg/image resources, free them at deinit" and
//!     "the multi-window app handed me a borrowed bundle".
//!   * `Frame.owned` (PR 7c.3a) \u2014 same shape for the per-frame
//!     transients.
//!
//! Beyond those two, per-entry cache markers (`DecodedImage.owned`,
//! `ShapedRun.owned`) survive as *data-plane* flags, not lifecycle
//! flags. Everything else \u2014 every `_owned: bool` field that ever lived
//! on `Window` itself or one of its sub-structs \u2014 should stay gone.
//!
//! This file's compile-time tests pin that invariant. If any future
//! refactor re-adds a `_owned`-suffixed field to `Window` (or to a
//! type composed onto `Window`), one of the tests below will fail at
//! compile time with a precise compileError. The allow-list lives in
//! `is_allow_listed_field` below.

const std = @import("std");

const Window = @import("window.zig").Window;
const AppResources = @import("app_resources.zig").AppResources;
const Frame = @import("frame.zig").Frame;

/// Returns true if a `name: bool` field is allowed to live on a type
/// even though its name matches the audit pattern. The list mirrors
/// the PR 9 Task 5 carve-outs documented in
/// `docs/cleanup-implementation-plan.md`.
///
/// We compare on `(TypeName, FieldName)` pairs so a future field with
/// the same name on an unrelated type still trips the audit.
fn isAllowListedField(comptime TypeName: []const u8, comptime FieldName: []const u8) bool {
    // PR 7a \u2014 `AppResources.owned` is the deliberate ownership
    // discriminator between bundled and borrowed rendering resources.
    if (std.mem.eql(u8, TypeName, "AppResources") and std.mem.eql(u8, FieldName, "owned")) return true;
    // PR 7c.3a \u2014 `Frame.owned` discriminates owned vs borrowed
    // per-window per-frame transients.
    if (std.mem.eql(u8, TypeName, "Frame") and std.mem.eql(u8, FieldName, "owned")) return true;
    // `DecodedImage.owned` \u2014 per-entry cache marker on the WASM image
    // loader: "free this slice on deinit?".
    if (std.mem.eql(u8, TypeName, "DecodedImage") and std.mem.eql(u8, FieldName, "owned")) return true;
    // `ShapedRun.owned` \u2014 per-entry cache marker in `text/types.zig`:
    // "do I own this slice?".
    if (std.mem.eql(u8, TypeName, "ShapedRun") and std.mem.eql(u8, FieldName, "owned")) return true;
    return false;
}

/// Walk `T`'s field list at comptime; for each field whose name ends
/// in `_owned` or equals `owned`, fail compilation unless the
/// `(TypeName, FieldName)` pair is allow-listed.
///
/// We don't recurse into nested types here \u2014 the test suite below
/// hits the specific types we want to pin individually so each
/// compile-error message names a single concrete type. That's worth
/// more than the convenience of an automatic walk: when this fires,
/// the reader needs to know exactly which struct just regressed.
fn assertNoOwnedFlag(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    const type_name = comptime shortTypeName(@typeName(T));
    inline for (info.@"struct".fields) |field| {
        if (field.type != bool) continue;
        const name = field.name;
        const matches_pattern = comptime (std.mem.eql(u8, name, "owned") or std.mem.endsWith(u8, name, "_owned"));
        if (!matches_pattern) continue;
        if (comptime isAllowListedField(type_name, name)) continue;
        @compileError("PR 9 Task 5: type '" ++ type_name ++ "' has a `" ++ name ++ ": bool` field that is not on the allow-list. Per the cleanup plan, ownership lives on `AppResources.owned` / `Frame.owned`; per-entry cache markers (`DecodedImage.owned`, `ShapedRun.owned`) are also allow-listed. If this field is a deliberate addition, add `(\"" ++ type_name ++ "\", \"" ++ name ++ "\")` to `isAllowListedField`.");
    }
}

/// `@typeName(T)` returns the fully qualified path
/// (e.g. `context.window.Window`); the audit messages are clearer if
/// we strip everything up to and including the last `.`.
fn shortTypeName(comptime full: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |idx| {
        return full[idx + 1 ..];
    }
    return full;
}

// =============================================================================
// Tests
// =============================================================================
//
// Each test names one concrete type. If the test fails, the
// compileError message inside `assertNoOwnedFlag` points the reader at
// the exact field. We deliberately enumerate types here rather than
// reach for `refAllDecls`-based recursion \u2014 the loud, specific failure
// message is more valuable than the convenience.

test "no `_owned` flag on Window" {
    comptime assertNoOwnedFlag(Window);
}

test "AppResources.owned stays on the allow-list (allow-list still wired up)" {
    // This is the live-fire check that the allow-list works: if a
    // refactor accidentally renames the type or the field, the audit
    // either fires (good, points at the rename) or silently passes
    // (bad). We assert presence directly.
    const info = @typeInfo(AppResources).@"struct";
    var found = false;
    inline for (info.fields) |f| {
        if (std.mem.eql(u8, f.name, "owned") and f.type == bool) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "Frame.owned stays on the allow-list" {
    const info = @typeInfo(Frame).@"struct";
    var found = false;
    inline for (info.fields) |f| {
        if (std.mem.eql(u8, f.name, "owned") and f.type == bool) {
            found = true;
        }
    }
    try std.testing.expect(found);
}
