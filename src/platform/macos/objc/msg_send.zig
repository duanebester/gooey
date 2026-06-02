//! The `objc_msgSend` ABI-casting core. This is the essential piece of the
//! runtime wrapper: it builds a correctly-typed C function pointer for each
//! call site and unwraps wrapper arguments (Object / Class / Sel) to their
//! underlying `c.id` / `c.Class` / `c.SEL` before the call.
//!
//! Only the plain `msgSend` form is provided. Gooey never invokes the
//! superclass implementation directly, so the `objc_msgSendSuper` machinery
//! (and the `objc_super` struct) from upstream is intentionally omitted.
//!
//! Apple Silicon (aarch64) only: a single `objc_msgSend` entry point handles
//! every return type, so the x86_64 `_stret` / `_fpret` return-type dispatch
//! is not implemented.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const objc = @import("main.zig");

comptime {
    // Fail loudly rather than silently miscompiling struct/float returns on an
    // unsupported architecture: aarch64 routes every return type through the
    // one `objc_msgSend`, but x86_64 would need the `_stret` / `_fpret`
    // variants that this port deliberately omits.
    if (builtin.target.cpu.arch != .aarch64)
        @compileError("Gooey's Objective-C wrapper supports aarch64 (Apple Silicon) only");
}

/// Returns a struct that implements the `msgSend` function for type T. T must
/// be a struct with a `value` field that is the size of an `id` (Object,
/// Class, etc.).
pub fn MsgSend(comptime T: type) type {
    return struct {
        /// Invoke a selector on the target, i.e. an instance method on an
        /// object or a class method on a class. `args` must be a tuple.
        pub fn msgSend(
            target: T,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) Return {
            // Our one special-case: if the return type is our own Object type
            // then we wrap the raw id result.
            const is_object = Return == objc.Object;

            // The actual ABI return type is an `id` when we wrap, otherwise we
            // trust the caller's type.
            const RealReturn = if (is_object) c.id else Return;

            // Accept either a pre-registered Sel or a string to register.
            const sel: objc.Sel = switch (@TypeOf(sel_raw)) {
                objc.Sel => sel_raw,
                else => objc.sel(sel_raw),
            };

            // Build the concrete function type and call objc_msgSend through
            // it. On aarch64 the one entry point serves every return type.
            const Fn = MsgSendFn(RealReturn, @TypeOf(target.value), @TypeOf(args));
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(&c.objc_msgSend));

            // Unwrap any wrapper types in args to their underlying C values.
            const unwrapped_args = buildUnwrappedArgs(args);
            const result = @call(.auto, msg_send_ptr, .{ target.value, sel.value } ++ unwrapped_args);

            if (!is_object) return result;
            return .{ .value = result };
        }
    };
}

/// Returns the C function-pointer body type for `objc_msgSend` that matches
/// the given return type, target type, and argument tuple.
///
/// objc_msgSend is unusual: it must be called with the C ABI of the *real*
/// target method, not as a variadic C function. So we synthesise the exact
/// function type, cast objc_msgSend to it, and call through that.
///
///     // Wrong (garbage): objc_msgSend(obj, sel, (float)x)
///     // Right: ((void (*)(id, SEL, float))objc_msgSend)(obj, sel, x)
fn MsgSendFn(
    comptime Return: type,
    comptime Target: type,
    comptime Args: type,
) type {
    const argsInfo = @typeInfo(Args).@"struct";
    assert(argsInfo.is_tuple);

    // Target must always be an `id`-sized value (Class, Object, etc.).
    assert(@sizeOf(Target) == @sizeOf(c.id));

    // Build up the parameter types: target, selector, then unwrapped args.
    var param_types: [argsInfo.fields.len + 2]type = undefined;
    param_types[0] = Target;
    param_types[1] = c.SEL;
    for (argsInfo.fields, 0..) |field, i| param_types[i + 2] = unwrapType(field.type);

    return @Fn(&param_types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

fn UnwrappedArgs(comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| types[i] = unwrapType(field.type);
    return @Tuple(&types);
}

/// Maps objc wrapper types to their underlying C types for use in `@Fn`
/// signatures, and validates that all other types are C-ABI compatible.
fn unwrapType(comptime T: type) type {
    // Unwrap our objc.Object type.
    if (T == objc.Object) return c.id;

    // Unwrap any other objc wrapper (Class, Sel, etc.) — identified by having
    // a single `value` field of pointer size. Return the actual field type
    // rather than c.id, since Class and Sel have distinct pointer types.
    if (@typeInfo(T) == .@"struct") {
        const info = @typeInfo(T).@"struct";
        for (info.fields) |field| {
            if (std.mem.eql(u8, field.name, "value") and @sizeOf(field.type) == @sizeOf(c.id)) {
                return field.type;
            }
        }
    }

    // Validate that the remaining type is safe to pass over the C ABI. Passing
    // a non-C-compatible type (like []const u8) would otherwise compile but
    // segfault at runtime via objc_msgSend; these checks turn that into a
    // compile error.
    switch (@typeInfo(T)) {
        .int, .float, .bool, .void => {},
        .@"enum" => {},
        .pointer => {},
        .optional => |opt| {
            if (@typeInfo(opt.child) != .pointer)
                @compileError("msgSend: " ++ @typeName(T) ++ " — optional must wrap a pointer");
        },
        .@"struct" => |s| {
            if (s.layout != .@"extern" and s.layout != .@"packed")
                @compileError("msgSend: " ++ @typeName(T) ++ " — struct must be extern or packed");
        },
        .@"union" => |u| {
            if (u.layout != .@"extern")
                @compileError("msgSend: " ++ @typeName(T) ++ " — union must be extern");
        },
        else => @compileError("msgSend: " ++ @typeName(T) ++ " — not C-ABI compatible"),
    }

    return T;
}

inline fn buildUnwrappedArgs(args: anytype) UnwrappedArgs(@TypeOf(args)) {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var result: UnwrappedArgs(@TypeOf(args)) = undefined;
    inline for (fields, 0..) |_, i| {
        result[i] = if (unwrapType(@TypeOf(args[i])) != @TypeOf(args[i]))
            args[i].value
        else
            args[i];
    }
    return result;
}

test "MsgSendFn builds the expected C function type" {
    const testing = std.testing;
    try testing.expectEqual(fn (
        c.id,
        c.SEL,
    ) callconv(.c) u64, MsgSendFn(u64, c.id, @TypeOf(.{})));
    try testing.expectEqual(fn (c.id, c.SEL, u16, u32) callconv(.c) u64, MsgSendFn(u64, c.id, @TypeOf(.{
        @as(u16, 0),
        @as(u32, 0),
    })));
}
