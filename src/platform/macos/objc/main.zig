//! Local, zero-dependency Objective-C runtime wrapper: a trimmed in-tree port
//! of the subset of `mitchellh/zig-objc` Gooey uses, with the same public
//! surface so files that `@import("objc")` read as against upstream.

const autorelease = @import("autorelease.zig");
const class = @import("class.zig");
const encoding = @import("encoding.zig");
const object = @import("object.zig");
const protocol = @import("protocol.zig");
const selpkg = @import("sel.zig");

pub const c = @import("c.zig").c;

pub const AutoreleasePool = autorelease.AutoreleasePool;

pub const Object = object.Object;

pub const Class = class.Class;
pub const getClass = class.getClass;
pub const allocateClassPair = class.allocateClassPair;
pub const registerClassPair = class.registerClassPair;

pub const Protocol = protocol.Protocol;
pub const getProtocol = protocol.getProtocol;

pub const Encoding = encoding.Encoding;
pub const comptimeEncode = encoding.comptimeEncode;

pub const sel = selpkg.sel;
pub const Sel = selpkg.Sel;

test {
    @import("std").testing.refAllDecls(@This());
}
