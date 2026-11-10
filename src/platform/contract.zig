//! Exact compile-time verification of backend signatures.
//!
//! The core binds to its renderer (`core/backend.zig`) and the Vulkan
//! renderer to its presentation surface (`linux/vk_surface.zig`) through
//! declarations that each target provides. Zig only analyzes the selected
//! target, so presence checks with `@hasDecl` would let drift accumulate on
//! the others: a parameter that is `f32` on one target and `f64` on another,
//! or a fallible call on one and an infallible one on another.
//!
//! This module checks complete function types — parameter types and order,
//! receiver mutability, numeric widths, error-union presence, and payload
//! types — so a signature change fails to compile with a message naming the
//! offending declaration.
//!
//! ## Why a descriptor instead of comparing whole `fn` types
//!
//! Implementations use inferred error sets (`!*Self`), so an expected type
//! written as `fn (...) anyerror!*Self` would never compare equal. `Sig`
//! therefore states the parameter list and the *payload* type, plus whether an
//! error union is required, and the verifier destructures `@typeInfo` to
//! compare piecewise.

const std = @import("std");

// =============================================================================
// Signature descriptors
// =============================================================================

/// Whether a verified declaration must return an error union.
pub const ErrorPolicy = enum {
    /// The return type must be `E!Payload` for some error set `E`.
    required,
    /// The return type must be exactly the payload type.
    forbidden,
};

/// One expected function signature.
pub const Sig = struct {
    /// Parameter types in declaration order, receiver included.
    params: []const type,
    /// Return payload type, with any error union already unwrapped.
    returns: type,
    /// Whether the declaration must be fallible.
    errors: ErrorPolicy = .forbidden,
};

// =============================================================================
// Primitive checks
// =============================================================================

/// Verify that `Owner.name` is a function exactly matching `sig`.
pub fn verifyFn(
    comptime Owner: type,
    comptime name: []const u8,
    comptime sig: Sig,
) void {
    comptime {
        if (!@hasDecl(Owner, name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} is missing required declaration '{s}': expected {s}",
                .{ @typeName(Owner), name, describe(sig) },
            ));
        }

        const Actual = @TypeOf(@field(Owner, name));
        const info = switch (@typeInfo(Actual)) {
            .@"fn" => |f| f,
            else => @compileError(std.fmt.comptimePrint(
                "{s}.{s} must be a function, found {s}",
                .{ @typeName(Owner), name, @typeName(Actual) },
            )),
        };

        if (info.attrs.varargs) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} must not be variadic",
                .{ @typeName(Owner), name },
            ));
        }
        if (info.is_generic) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} must not be generic; a backend boundary needs a concrete" ++
                    " signature so every target can be checked uniformly",
                .{ @typeName(Owner), name },
            ));
        }

        verifyFnParams(Owner, name, sig, info.param_types);
        verifyFnReturn(Owner, name, sig, info.return_type);
    }
}

/// Compare a declaration's parameter list against `sig`, receiver included.
fn verifyFnParams(
    comptime Owner: type,
    comptime name: []const u8,
    comptime sig: Sig,
    comptime params: []const ?type,
) void {
    comptime {
        if (params.len != sig.params.len) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} takes {d} parameter(s), expected {d}: {s}",
                .{ @typeName(Owner), name, params.len, sig.params.len, describe(sig) },
            ));
        }

        for (params, sig.params, 0..) |actual_param, Expected, index| {
            const Param = actual_param orelse @compileError(std.fmt.comptimePrint(
                "{s}.{s} parameter {d} has no concrete type (comptime or anytype)",
                .{ @typeName(Owner), name, index },
            ));
            if (Param != Expected) {
                @compileError(std.fmt.comptimePrint(
                    "{s}.{s} parameter {d} is {s}, expected {s}",
                    .{ @typeName(Owner), name, index, @typeName(Param), @typeName(Expected) },
                ));
            }
        }
    }
}

/// Compare a declaration's return type against `sig`, honouring `ErrorPolicy`.
fn verifyFnReturn(
    comptime Owner: type,
    comptime name: []const u8,
    comptime sig: Sig,
    comptime declared: ?type,
) void {
    comptime {
        const Return = declared orelse @compileError(std.fmt.comptimePrint(
            "{s}.{s} has no concrete return type",
            .{ @typeName(Owner), name },
        ));

        switch (sig.errors) {
            .required => {
                const payload = switch (@typeInfo(Return)) {
                    .error_union => |u| u.payload,
                    else => @compileError(std.fmt.comptimePrint(
                        "{s}.{s} must be fallible and return an error union, found {s}",
                        .{ @typeName(Owner), name, @typeName(Return) },
                    )),
                };
                if (payload != sig.returns) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} returns error union payload {s}, expected {s}",
                        .{ @typeName(Owner), name, @typeName(payload), @typeName(sig.returns) },
                    ));
                }
            },
            .forbidden => {
                if (@typeInfo(Return) == .error_union) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} must be infallible, found error union {s}",
                        .{ @typeName(Owner), name, @typeName(Return) },
                    ));
                }
                if (Return != sig.returns) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} returns {s}, expected {s}",
                        .{ @typeName(Owner), name, @typeName(Return), @typeName(sig.returns) },
                    ));
                }
            },
        }
    }
}

/// Verify that `Owner.name` is a non-function declaration of type `Expected`.
pub fn verifyConst(
    comptime Owner: type,
    comptime name: []const u8,
    comptime Expected: type,
) void {
    comptime {
        if (!@hasDecl(Owner, name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} is missing required constant '{s}: {s}'",
                .{ @typeName(Owner), name, @typeName(Expected) },
            ));
        }
        const Actual = @TypeOf(@field(Owner, name));
        if (Actual != Expected) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} is {s}, expected {s}",
                .{ @typeName(Owner), name, @typeName(Actual), @typeName(Expected) },
            ));
        }
    }
}

/// Render a signature descriptor for compile-error messages.
fn describe(comptime sig: Sig) []const u8 {
    comptime {
        var text: []const u8 = "fn (";
        for (sig.params, 0..) |Param, index| {
            if (index > 0) text = text ++ ", ";
            text = text ++ @typeName(Param);
        }
        text = text ++ ") ";
        if (sig.errors == .required) text = text ++ "!";
        return text ++ @typeName(sig.returns);
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "verifyFn matches an exact signature" {
    const Fixture = struct {
        pub fn takesSlice(_: *@This(), _: []const u8) u32 {
            return 0;
        }
    };
    comptime verifyFn(Fixture, "takesSlice", .{
        .params = &.{ *Fixture, []const u8 },
        .returns = u32,
    });
}

test "verifyFn accepts an inferred error set as a required error union" {
    // Backends universally use inferred error sets, so the payload — not the
    // error set — is what the verifier may compare.
    const Fixture = struct {
        pub fn fallible(_: *@This()) !u16 {
            return 7;
        }
    };
    comptime verifyFn(Fixture, "fallible", .{
        .params = &.{*Fixture},
        .returns = u16,
        .errors = .required,
    });
}

test "verifyConst matches a comptime declaration type" {
    const Fixture = struct {
        pub const extension_name: [*:0]const u8 = "VK_KHR_surface";
    };
    comptime verifyConst(Fixture, "extension_name", [*:0]const u8);
}

test "describe renders a readable signature" {
    const Fixture = struct {};
    const rendered = comptime describe(.{
        .params = &.{ *Fixture, std.mem.Allocator },
        .returns = void,
        .errors = .required,
    });
    // The parameter type names are fully qualified, so assert on the shape
    // rather than the exact prefix.
    try testing.expect(std.mem.startsWith(u8, rendered, "fn ("));
    try testing.expect(std.mem.endsWith(u8, rendered, ") !void"));
    try testing.expect(std.mem.indexOf(u8, rendered, "Allocator") != null);
}
