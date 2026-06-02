//! Object is an instance of a class. Trimmed to the surface Gooey uses:
//! `msgSend`, `fromId`, `release`, and id-typed instance-variable access.
//! (The custom `NSView` subclass stores its owning Zig `Window` pointer in an
//! ivar, which is what `get`/`setInstanceVariable` are for.)

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Object = struct {
    value: c.id,

    // Implement msgSend.
    const msg_send = MsgSend(Object);
    pub const msgSend = msg_send.msgSend;

    /// Convert a raw `id` into an Object. The input must be the size of the C
    /// `id` type (pointer-sized).
    pub fn fromId(id: anytype) Object {
        if (@sizeOf(@TypeOf(id)) != @sizeOf(c.id)) {
            @compileError("invalid id type");
        }

        // Some Objective-C pointers are "tagged pointers": small objects and
        // literals (NSNumber, NSString) encoded directly in the pointer bits
        // rather than heap-allocated. These may be UNALIGNED, so we disable
        // runtime safety for the cast.
        const ptr: c.id = blk: {
            @setRuntimeSafety(false);
            break :blk @ptrCast(@alignCast(id));
        };

        return .{ .value = ptr };
    }

    /// Read an id-typed instance variable by name.
    pub fn getInstanceVariable(self: Object, name: [:0]const u8) Object {
        assert(self.value != null);
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null);
        // A null ivar means the name does not exist on this object's class;
        // reading through it would silently return nil. Fail at the source.
        assert(ivar != null);
        return fromId(c.object_getIvar(self.value, ivar));
    }

    /// Write an id-typed instance variable by name.
    pub fn setInstanceVariable(self: Object, name: [:0]const u8, val: Object) void {
        assert(self.value != null);
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null);
        // A null ivar means the name does not exist on this object's class;
        // writing through it would be a silent no-op. Fail at the source.
        assert(ivar != null);
        c.object_setIvar(self.value, ivar, val.value);
    }

    /// Release a +1 reference. The matching retain is implied by alloc/copy or
    /// an explicit retain elsewhere; this balances it.
    pub fn release(self: Object) void {
        c.objc_release(self.value);
    }
};
