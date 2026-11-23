const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Object = struct {
    value: c.id,

    const msg_send = MsgSend(Object);
    pub const msgSend = msg_send.msgSend;

    pub fn fromId(id: anytype) Object {
        if (@sizeOf(@TypeOf(id)) != @sizeOf(c.id)) {
            @compileError("invalid id type");
        }

        const ptr: c.id = blk: {
            @setRuntimeSafety(false);
            break :blk @ptrCast(@alignCast(id));
        };

        return .{ .value = ptr };
    }

    pub fn getInstanceVariable(self: Object, name: [:0]const u8) Object {
        assert(self.value != null);
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null);
        assert(ivar != null);
        return fromId(c.object_getIvar(self.value, ivar));
    }

    pub fn setInstanceVariable(self: Object, name: [:0]const u8, val: Object) void {
        assert(self.value != null);
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null);
        assert(ivar != null);
        c.object_setIvar(self.value, ivar, val.value);
    }

    pub fn release(self: Object) void {
        c.objc_release(self.value);
    }
};
