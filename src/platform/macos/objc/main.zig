//! Local, zero-dependency Objective-C runtime wrapper.
//!
//! This is a trimmed in-tree port of the subset of `mitchellh/zig-objc` that
//! Gooey actually used, written so the project has no external package
//! dependencies and no `translate-c` / xcrun / Apple-SDK-path build steps. The
//! public surface below matches the upstream `objc` module's shape, so the
//! files that `@import("objc")` compile unchanged.
//!
//! Intentionally omitted (unused by Gooey): blocks, fast-enumeration
//! iterators, properties, the superclass message-send path, metaclasses,
//! retain, and class-pair disposal.

const autorelease = @import("autorelease.zig");
const class = @import("class.zig");
const encoding = @import("encoding.zig");
const object = @import("object.zig");
const protocol = @import("protocol.zig");
const selpkg = @import("sel.zig");

/// The raw Objective-C runtime namespace (types + `extern` functions). Exposed
/// so call sites can name `objc.c.id`, `objc.c.SEL`, etc., and so framework
/// globals can be declared as `extern "c" var x: objc.c.id`.
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
