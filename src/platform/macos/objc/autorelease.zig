//! Autorelease pool wrapper. Gooey creates a pool around work that vends
//! autoreleased Objective-C objects (e.g. per-frame Foundation temporaries) so
//! they are drained deterministically instead of accumulating.

pub const AutoreleasePool = opaque {
    /// Create a new autorelease pool. To clean it up, call deinit.
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
