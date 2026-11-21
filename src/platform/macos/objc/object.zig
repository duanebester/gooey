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

        // Tagged pointers (small objects and literals such as NSNumber or
        // NSString encoded in the pointer bits) may be UNALIGNED, so runtime
        // safety is off for the cast.
        const ptr: c.id = blk: {
            @setRuntimeSafety(false);
            break :blk @ptrCast(@alignCast(id));
        };

        return .{ .value = ptr };
    }

    pub fn getInstanceVariable(self: Object, name: [:0]const u8) Object {
        assert(self.value != null);
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null);
        // A null ivar means the class has no such name; reading through it
        // would silently return nil. Fail at the source.
        assert(ivar != null);
        return fromId(c.object_getIvar(self.value, ivar));
    }

    pub fn setInstanceVariable(self: Object, name: [:0]const u8, val: Object) void {
        assert(self.value != null);
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null);
        // A null ivar means the class has no such name; writing through it
        // would be a silent no-op. Fail at the source.
        assert(ivar != null);
        c.object_setIvar(self.value, ivar, val.value);
    }

    /// Balances the +1 from alloc/copy or an explicit retain elsewhere.
    pub fn release(self: Object) void {
        c.objc_release(self.value);
    }
};
