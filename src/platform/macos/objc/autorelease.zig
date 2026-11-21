pub const AutoreleasePool = opaque {
    pub inline fn init() *AutoreleasePool {
        return @ptrCast(objc_autoreleasePoolPush().?);
    }

    pub inline fn deinit(self: *AutoreleasePool) void {
        objc_autoreleasePoolPop(self);
    }
};

// These are not in any public header, but they are the documented ABI behind
// @autoreleasepool and are stable across macOS releases.
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(?*anyopaque) void;
