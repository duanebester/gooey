//! Objective-C type-encoding generation. The runtime's `class_addMethod`
//! wants a string describing a method's return and argument types (e.g.
//! "v@:c" for `void method(id, SEL, char)`). This module derives that string
//! from a Zig function type at comptime, so `Class.addMethod` can register Zig
//! callbacks with the runtime.
//!
//! Reference:
//! https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html

const std = @import("std");
const objc = @import("main.zig");
const c = @import("c.zig").c;
const assert = std.debug.assert;
const testing = std.testing;

/// How much space do we need to encode this type?
fn comptimeN(comptime T: type) usize {
    comptime {
        const encoding = objc.Encoding.init(T);

        // Figure out how much space we need
        return std.fmt.count("{f}", .{encoding});
    }
}

/// Encode a type into a comptime, null-terminated string.
pub fn comptimeEncode(comptime T: type) [comptimeN(T):0]u8 {
    comptime {
        const encoding = objc.Encoding.init(T);

        // Build our final signature
        var buf: [comptimeN(T) + 1]u8 = undefined;
        const result = std.fmt.bufPrint(buf[0 .. buf.len - 1], "{f}", .{encoding}) catch unreachable;
        buf[result.len] = 0;

        return buf[0..result.len :0].*;
    }
}

/// Encoding union which parses type information and turns it into Obj-C
/// runtime Type Encodings.
pub const Encoding = union(enum) {
    char,
    int,
    short,
    long,
    longlong,
    uchar,
    uint,
    ushort,
    ulong,
    ulonglong,
    float,
    double,
    bool,
    void,
    char_string,
    object,
    class,
    selector,
    array: struct { arr_type: type, len: usize },
    structure: struct { struct_type: type, show_type_spec: bool },
    @"union": struct { union_type: type, show_type_spec: bool },
    bitfield: u32,
    pointer: struct { ptr_type: type, size: std.builtin.Type.Pointer.Size },
    function: std.builtin.Type.Fn,
    unknown,

    pub fn init(comptime T: type) Encoding {
        return switch (T) {
            i8, c_char => .char,
            c_short => .short,
            i32, c_int => .int,
            c_long => .long,
            i64, c_longlong => .longlong,
            u8 => .uchar,
            c_ushort => .ushort,
            u32, c_uint => .uint,
            c_ulong => .ulong,
            u64, c_ulonglong => .ulonglong,
            f32 => .float,
            f64 => .double,
            bool => .bool,
            void, anyopaque => .void,
            [*c]u8, [*c]const u8 => .char_string,
            c.SEL, objc.Sel => .selector,
            c.Class, objc.Class => .class,
            c.id, objc.Object => .object,
            else => switch (@typeInfo(T)) {
                .@"opaque" => .void,
                .@"enum" => |m| .init(m.tag_type),
                .array => |arr| .{ .array = .{ .len = arr.len, .arr_type = arr.child } },
                .@"struct" => |m| switch (m.layout) {
                    .@"packed" => .init(m.backing_integer.?),
                    else => .{ .structure = .{ .struct_type = T, .show_type_spec = true } },
                },
                .@"union" => .{ .@"union" = .{
                    .union_type = T,
                    .show_type_spec = true,
                } },
                .optional => |m| switch (@typeInfo(m.child)) {
                    .pointer => |ptr| .{ .pointer = .{ .ptr_type = m.child, .size = ptr.size } },
                    else => @compileError("unsupported non-pointer optional type: " ++ @typeName(T)),
                },
                .pointer => |ptr| .{ .pointer = .{ .ptr_type = T, .size = ptr.size } },
                .@"fn" => |fn_info| .{ .function = fn_info },
                else => @compileError("unsupported type: " ++ @typeName(T)),
            },
        };
    }

    pub fn format(
        comptime self: Encoding,
        writer: anytype,
    ) !void {
        switch (self) {
            .char => try writer.writeAll("c"),
            .int => try writer.writeAll("i"),
            .short => try writer.writeAll("s"),
            .long => try writer.writeAll("l"),
            .longlong => try writer.writeAll("q"),
            .uchar => try writer.writeAll("C"),
            .uint => try writer.writeAll("I"),
            .ushort => try writer.writeAll("S"),
            .ulong => try writer.writeAll("L"),
            .ulonglong => try writer.writeAll("Q"),
            .float => try writer.writeAll("f"),
            .double => try writer.writeAll("d"),
            .bool => try writer.writeAll("B"),
            .void => try writer.writeAll("v"),
            .char_string => try writer.writeAll("*"),
            .object => try writer.writeAll("@"),
            .class => try writer.writeAll("#"),
            .selector => try writer.writeAll(":"),
            .array => |a| {
                try writer.print("[{}", .{a.len});
                const encode_type = init(a.arr_type);
                try encode_type.format(writer);
                try writer.writeAll("]");
            },
            .structure => |s| {
                const struct_info = @typeInfo(s.struct_type);
                assert(struct_info.@"struct".layout == .@"extern");

                // Strips the fully qualified type name to leave just the
                // type name. Used in naming the Struct in an encoding.
                var type_name_iter = std.mem.splitBackwardsScalar(u8, @typeName(s.struct_type), '.');
                const type_name = type_name_iter.first();
                try writer.print("{{{s}", .{type_name});

                // if the encoding should show the internal type specification
                // of the struct (determined by levels of pointer indirection)
                if (s.show_type_spec) {
                    try writer.writeAll("=");
                    inline for (struct_info.@"struct".fields) |field| {
                        const field_encode = init(field.type);
                        try field_encode.format(writer);
                    }
                }

                try writer.writeAll("}");
            },
            .@"union" => |u| {
                const union_info = @typeInfo(u.union_type);
                assert(union_info.@"union".layout == .@"extern");

                // Strips the fully qualified type name to leave just the
                // type name. Used in naming the Union in an encoding
                var type_name_iter = std.mem.splitBackwardsScalar(u8, @typeName(u.union_type), '.');
                const type_name = type_name_iter.first();
                try writer.print("({s}", .{type_name});

                // if the encoding should show the internal type specification
                // of the Union (determined by levels of pointer indirection)
                if (u.show_type_spec) {
                    try writer.writeAll("=");
                    inline for (union_info.@"union".fields) |field| {
                        const field_encode = init(field.type);
                        try field_encode.format(writer);
                    }
                }

                try writer.writeAll(")");
            },
            .bitfield => |b| try writer.print("b{}", .{b}), // not sure if needed from Zig -> Obj-C
            .pointer => |p| {
                switch (p.size) {
                    .one => {
                        // get the pointer info (count of levels of direction
                        // and the underlying type)
                        const pointer_info = indirectionCountAndType(p.ptr_type);
                        for (0..pointer_info.indirection_levels) |_| {
                            try writer.writeAll("^");
                        }

                        // create a new Encoding union from the pointers child
                        // type, giving an encoding of the underlying pointer type
                        comptime var encoding = init(pointer_info.child);

                        // if the indirection levels are greater than 1, for
                        // certain types that means getting rid of it's
                        // internal type specification
                        if (pointer_info.indirection_levels > 1) {
                            switch (encoding) {
                                .structure => |*s| s.show_type_spec = false,
                                .@"union" => |*u| u.show_type_spec = false,
                                else => {},
                            }
                        }

                        // call this format function again, this time with the child type encoding
                        try encoding.format(writer);
                    },
                    else => @compileError("Pointer size not supported for encoding"),
                }
            },
            .function => |fn_info| {
                assert(std.meta.eql(fn_info.calling_convention, std.builtin.CallingConvention.c));

                // Return type is first in a method encoding
                const ret_type_enc = init(fn_info.return_type.?);
                try ret_type_enc.format(writer);
                inline for (fn_info.params) |param| {
                    const param_enc = init(param.type.?);
                    try param_enc.format(writer);
                }
            },
            .unknown => {},
        }
    }
};

/// This comptime function gets the levels of indirection from a type. If the
/// type is a pointer type it returns the underlying type from the pointer (the
/// child) by walking the pointer to that child. Returns the type and 0 for
/// count if the type isn't a pointer.
fn indirectionCountAndType(comptime T: type) struct {
    child: type,
    indirection_levels: comptime_int,
} {
    var WalkType = T;
    var count: usize = 0;
    while (@typeInfo(WalkType) == .pointer) : (count += 1) {
        WalkType = @typeInfo(WalkType).pointer.child;
    }

    return .{ .child = WalkType, .indirection_levels = count };
}

// --- Tests -----------------------------------------------------------------
// These exercise the encoding machinery in isolation; they are pure (no live
// runtime needed) and document the expected encoding for representative types.

fn encodingMatchesType(comptime T: type, expected_encoding: []const u8) !void {
    var buf: [200]u8 = undefined;
    const enc = Encoding.init(T);
    const enc_string = try std.fmt.bufPrint(&buf, "{f}", .{enc});
    try testing.expectEqualStrings(expected_encoding, enc_string);
}

test "scalar encodings" {
    try encodingMatchesType(i8, "c");
    try encodingMatchesType(c_char, "c");
    try encodingMatchesType(c_short, "s");
    try encodingMatchesType(c_int, "i");
    try encodingMatchesType(c_long, "l");
    try encodingMatchesType(c_longlong, "q");
    try encodingMatchesType(u8, "C");
    try encodingMatchesType(c_ushort, "S");
    try encodingMatchesType(c_uint, "I");
    try encodingMatchesType(c_ulong, "L");
    try encodingMatchesType(c_ulonglong, "Q");
    try encodingMatchesType(f32, "f");
    try encodingMatchesType(f64, "d");
}

test "pointer and array encodings" {
    try encodingMatchesType([4]i8, "[4c]");
    try encodingMatchesType(*u8, "^C");
    try encodingMatchesType(**u8, "^^C");
    try encodingMatchesType(?*u8, "^C");
}

test "enum and packed struct encodings" {
    const TestEnum = enum(c_uint) {};
    try encodingMatchesType(TestEnum, "I");

    const TestPackedStruct = packed struct(u32) { _: u32 };
    try encodingMatchesType(TestPackedStruct, "I");
}

test "struct encodings" {
    const TestStruct = extern struct {
        float: f32,
        char: u8,
    };
    try encodingMatchesType(*TestStruct, "^{TestStruct=fC}");
    try encodingMatchesType(**TestStruct, "^^{TestStruct}");

    const NestedStruct = extern struct { char: i8 };
    const Outer = extern struct {
        float: f32,
        char: u8,
        nested: **NestedStruct,
    };
    try encodingMatchesType(*Outer, "^{Outer=fC^^{NestedStruct}}");
}

test "opaque encodings" {
    const TestOpaque = opaque {};
    try encodingMatchesType(*TestOpaque, "^v");
    try encodingMatchesType(?*TestOpaque, "^v");
}

test "union encodings" {
    const TestUnion = extern union {
        int: c_int,
        short: c_short,
        long: c_long,
    };
    try encodingMatchesType(TestUnion, "(TestUnion=isl)");
    try encodingMatchesType(*TestUnion, "^(TestUnion=isl)");
    try encodingMatchesType(**TestUnion, "^^(TestUnion)");
}

test "function encoding" {
    const test_fn = struct {
        fn add(_: c.id, _: c.SEL, _: i8) callconv(.c) void {}
    };
    try encodingMatchesType(@TypeOf(test_fn.add), "v@:c");
}
