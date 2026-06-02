//! Hand-written `extern "c"` declarations for the slice of the Objective-C
//! runtime that Gooey actually calls. This replaces the upstream `zig-objc`
//! dependency's `translate-c` of `<objc/runtime.h>` + `<objc/message.h>`,
//! removing the xcrun / Apple-SDK-path build plumbing entirely. The system
//! `objc` library and the `Foundation` framework are still linked by
//! `build.zig`, which is where these symbols resolve.
//!
//! Only the functions and types reachable from Gooey's call sites are
//! declared here. If a new runtime call is needed, add its declaration rather
//! than reaching for a code generator.

/// The Objective-C runtime namespace, exposed publicly as `objc.c`. Internal
/// modules import it as `@import("c.zig").c`; the 25 Gooey files that touch the
/// runtime directly only reference `objc.c.id`, `objc.c.SEL`, and
/// `objc.c.class_addProtocol`.
pub const c = struct {
    // Opaque runtime types. They are intentionally *distinct* Zig types (not
    // all aliases of `?*anyopaque`) so the encoding machinery and msgSend
    // argument unwrapping can tell `id` / `Class` / `SEL` / `Protocol` apart —
    // each encodes differently ('@' / '#' / ':') and a switch over them would
    // otherwise see duplicate prongs.
    pub const objc_object = opaque {};
    pub const objc_class = opaque {};
    pub const objc_selector = opaque {};
    pub const objc_protocol = opaque {};
    pub const objc_ivar = opaque {};

    pub const id = ?*objc_object;
    pub const Class = ?*objc_class;
    pub const SEL = ?*objc_selector;
    pub const Protocol = objc_protocol;
    pub const Ivar = ?*objc_ivar;

    // Apple's <objc/objc.h> defines BOOL as `signed char` on x86_64 and as
    // C99 `_Bool` on arm64. We model it as `i8` on every target: an `i8`
    // return is ABI-compatible with both (a single 0/1 byte in the return
    // register), and it lets call sites compare the result against 0 the way
    // the runtime's C API expects (e.g. `class_addProtocol(...) == 0`).
    // `boolResult` maps that back to a Zig `bool`.
    pub const BOOL = i8;

    // --- Classes & selectors ---------------------------------------------
    pub extern fn objc_getClass(name: [*c]const u8) Class;
    pub extern fn sel_registerName(str: [*c]const u8) SEL;

    // --- Dynamic class construction --------------------------------------
    pub extern fn objc_allocateClassPair(superclass: Class, name: [*c]const u8, extra_bytes: usize) Class;
    pub extern fn objc_registerClassPair(cls: Class) void;
    pub extern fn class_addMethod(cls: Class, name: SEL, imp: ?*const anyopaque, types: [*c]const u8) BOOL;
    pub extern fn class_addIvar(cls: Class, name: [*c]const u8, size: usize, alignment: u8, types: [*c]const u8) BOOL;
    pub extern fn class_addProtocol(cls: Class, protocol: *objc_protocol) BOOL;

    // --- Protocols -------------------------------------------------------
    pub extern fn objc_getProtocol(name: [*c]const u8) ?*objc_protocol;

    // --- Instance variables ----------------------------------------------
    pub extern fn object_getInstanceVariable(obj: id, name: [*c]const u8, out_value: ?*?*anyopaque) Ivar;
    pub extern fn object_getIvar(obj: id, ivar: Ivar) id;
    pub extern fn object_setIvar(obj: id, ivar: Ivar, value: id) void;

    // --- Reference counting ----------------------------------------------
    pub extern fn objc_release(obj: id) void;

    // --- Message send ----------------------------------------------------
    // Declared as a zero-argument C function and re-cast to the correct
    // concrete signature at each call site (see msg_send.zig); objc_msgSend
    // must be invoked with the ABI of the real target method, never as a
    // variadic function. Gooey targets Apple Silicon only, where this single
    // entry point handles every return type — the x86_64 `_stret` / `_fpret`
    // variants are intentionally absent.
    pub extern fn objc_msgSend() callconv(.c) void;
};

/// Convert a runtime `BOOL` return value into a Zig `bool`. Any non-zero value
/// is treated as true, matching the C semantics of `BOOL`.
pub fn boolResult(result: c.BOOL) bool {
    return result != 0;
}
