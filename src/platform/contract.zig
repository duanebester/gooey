//! Compile-time verification of backend signatures against `Sig` descriptors.
//! Implementations use inferred error sets (`!*Self`), so whole `fn` types
//! never compare equal; `Sig` states the parameter list and payload type and
//! the verifier destructures `@typeInfo` to compare piecewise instead.

const std = @import("std");

/// Whether a verified declaration must return an error union.
pub const ErrorPolicy = enum {
    required,
    forbidden,
};

/// One expected function signature.
pub const Sig = struct {
    /// Parameter types in declaration order, receiver included.
    params: []const type,
    /// Return payload type, with any error union already unwrapped.
    returns: type,
    errors: ErrorPolicy = .forbidden,
};

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
