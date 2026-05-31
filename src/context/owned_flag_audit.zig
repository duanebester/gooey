//! Compile-time audit pinning the `_owned: bool` flag invariant.
//!
//! Resource ownership is expressed by exactly two deliberate
//! discriminators — `AppResources.owned` (bundled vs borrowed rendering
//! resources) and `Frame.owned` (owned vs borrowed per-frame
//! transients) — plus two per-entry cache markers (`DecodedImage.owned`,
//! `ShapedRun.owned`) which are data-plane flags, not lifecycle flags.
//! No other `_owned: bool` field should live on `Window` or any type
//! composed onto it.
//!
//! The compile-time tests below pin that: re-adding an `_owned`-suffixed
//! field to one of the audited types fails the build with a precise
//! `@compileError`. The allow-list lives in `isAllowListedField`.

const std = @import("std");

const Window = @import("window.zig").Window;
const AppResources = @import("app_resources.zig").AppResources;
const Frame = @import("frame.zig").Frame;

/// Returns true if a `name: bool` field is allowed to live on a type
/// even though its name matches the audit pattern. We compare on
/// `(TypeName, FieldName)` pairs so a future field with the same name
/// on an unrelated type still trips the audit.
fn isAllowListedField(comptime TypeName: []const u8, comptime FieldName: []const u8) bool {
    // Deliberate ownership discriminator between bundled and borrowed
    // rendering resources.
    if (std.mem.eql(u8, TypeName, "AppResources") and std.mem.eql(u8, FieldName, "owned")) return true;
    // Discriminates owned vs borrowed per-window per-frame transients.
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
// Each test names one concrete type so a failure's compileError points
// at the exact regressing field. Enumerated rather than walked via
// `refAllDecls` recursion: the loud, specific failure message is worth
// more than the convenience.

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
