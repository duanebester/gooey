pub const c = struct {
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

    pub const BOOL = i8;

    pub extern fn objc_getClass(name: [*c]const u8) Class;
    pub extern fn sel_registerName(str: [*c]const u8) SEL;

    pub extern fn objc_allocateClassPair(superclass: Class, name: [*c]const u8, extra_bytes: usize) Class;
    pub extern fn objc_registerClassPair(cls: Class) void;
    pub extern fn class_addMethod(cls: Class, name: SEL, imp: ?*const anyopaque, types: [*c]const u8) BOOL;
    pub extern fn class_addIvar(cls: Class, name: [*c]const u8, size: usize, alignment: u8, types: [*c]const u8) BOOL;
    pub extern fn class_addProtocol(cls: Class, protocol: *objc_protocol) BOOL;

    pub extern fn objc_getProtocol(name: [*c]const u8) ?*objc_protocol;

    pub extern fn object_getInstanceVariable(obj: id, name: [*c]const u8, out_value: ?*?*anyopaque) Ivar;
    pub extern fn object_getIvar(obj: id, ivar: Ivar) id;
    pub extern fn object_setIvar(obj: id, ivar: Ivar, value: id) void;

    pub extern fn objc_release(obj: id) void;

    pub extern fn objc_msgSend() callconv(.c) void;
};

pub fn boolResult(result: c.BOOL) bool {
    return result != 0;
}
