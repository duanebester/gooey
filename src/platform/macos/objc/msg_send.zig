const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const objc = @import("main.zig");

comptime {
    if (builtin.target.cpu.arch != .aarch64)
        @compileError("Gooey's Objective-C wrapper supports aarch64 (Apple Silicon) only");
}

pub fn MsgSend(comptime T: type) type {
    return struct {
        pub fn msgSend(
            target: T,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) Return {
            const is_object = Return == objc.Object;
            const RealReturn = if (is_object) c.id else Return;

            const sel: objc.Sel = switch (@TypeOf(sel_raw)) {
                objc.Sel => sel_raw,
                else => objc.sel(sel_raw),
            };

            const Fn = MsgSendFn(RealReturn, @TypeOf(target.value), @TypeOf(args));
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(&c.objc_msgSend));

            const unwrapped_args = buildUnwrappedArgs(args);
            const result = @call(.auto, msg_send_ptr, .{ target.value, sel.value } ++ unwrapped_args);

            if (!is_object) return result;
            return .{ .value = result };
        }
    };
}

fn MsgSendFn(
    comptime Return: type,
    comptime Target: type,
    comptime Args: type,
) type {
    const argsInfo = @typeInfo(Args).@"struct";
    assert(argsInfo.is_tuple);

    assert(@sizeOf(Target) == @sizeOf(c.id));

    var param_types: [argsInfo.field_types.len + 2]type = undefined;
    param_types[0] = Target;
    param_types[1] = c.SEL;
    for (argsInfo.field_types, 0..) |field_type, i| param_types[i + 2] = unwrapType(field_type);

    return @Fn(&param_types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

fn UnwrappedArgs(comptime Args: type) type {
    const field_types = @typeInfo(Args).@"struct".field_types;
    var types: [field_types.len]type = undefined;
    for (field_types, 0..) |field_type, i| types[i] = unwrapType(field_type);
    return @Tuple(&types);
}

fn unwrapType(comptime T: type) type {
    if (T == objc.Object) return c.id;

    if (@typeInfo(T) == .@"struct") {
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |field_name, field_type| {
            if (std.mem.eql(u8, field_name, "value") and @sizeOf(field_type) == @sizeOf(c.id)) {
                return field_type;
            }
        }
    }

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
    const field_types = @typeInfo(@TypeOf(args)).@"struct".field_types;
    var result: UnwrappedArgs(@TypeOf(args)) = undefined;
    inline for (field_types, 0..) |_, i| {
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
