//! Class wrapper. Trimmed to what Gooey uses: sending messages to a class
//! (e.g. `+alloc`, `+stringWithUTF8String:`), looking classes up by name, and
//! building a custom class pair at runtime (the `NSTextInputClient` view) via
//! `allocateClassPair` + `addIvar` + `addMethod` + `registerClassPair`.

const std = @import("std");
const assert = std.debug.assert;
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolResult = cpkg.boolResult;
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Class = struct {
    value: c.Class,

    // Implement msgSend.
    const msg_send = MsgSend(Class);
    pub const msgSend = msg_send.msgSend;

    /// Add a new method to the class. `imp` must be a function with the C
    /// calling convention whose first two arguments are a `c.id` (self) and a
    /// `c.SEL` (the selector). Returns true on success. Only valid between
    /// `allocateClassPair` and `registerClassPair`.
    pub fn addMethod(self: Class, name: [:0]const u8, imp: anytype) bool {
        const Fn = @TypeOf(imp);
        const fn_info = @typeInfo(Fn).@"fn";
        assert(std.meta.eql(fn_info.calling_convention, std.builtin.CallingConvention.c));
        assert(fn_info.is_var_args == false);
        assert(fn_info.params.len >= 2);
        assert(fn_info.params[0].type == c.id);
        assert(fn_info.params[1].type == c.SEL);
        const encoding = comptime objc.comptimeEncode(Fn);
        return boolResult(c.class_addMethod(
            self.value,
            objc.sel(name).value,
            @ptrCast(&imp),
            &encoding,
        ));
    }

    /// Add an instance variable of type `id` to the class. Only valid between
    /// `allocateClassPair` and `registerClassPair`. Returns true on success.
    pub fn addIvar(self: Class, name: [:0]const u8) bool {
        const result = c.class_addIvar(self.value, name.ptr, @sizeOf(c.id), @alignOf(c.id), "@");
        return boolResult(result);
    }
};

/// Look up a registered class by name, returning null if unknown.
pub fn getClass(name: [:0]const u8) ?Class {
    assert(name.len > 0);
    return .{ .value = c.objc_getClass(name.ptr) orelse return null };
}

/// Begin defining a new class. Call `registerClassPair` on the result once all
/// ivars and methods have been added.
pub fn allocateClassPair(superclass: ?Class, name: [:0]const u8) ?Class {
    assert(name.len > 0);
    if (superclass) |cls| assert(cls.value != null);
    return .{ .value = c.objc_allocateClassPair(
        if (superclass) |cls| cls.value else null,
        name.ptr,
        0,
    ) orelse return null };
}

/// Finish defining a class so the runtime can instantiate it.
pub fn registerClassPair(class: Class) void {
    assert(class.value != null);
    c.objc_registerClassPair(class.value);
}
