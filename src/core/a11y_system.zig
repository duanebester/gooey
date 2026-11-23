const std = @import("std");
const builtin = @import("builtin");

const a11y = @import("../accessibility/accessibility.zig");

pub const A11ySystem = struct {
    tree: a11y.Tree,

    platform_bridge: a11y.PlatformBridge,

    bridge: a11y.Bridge,

    enabled: bool = false,

    check_counter: u32 = 0,

    const Self = @This();

    pub noinline fn initInPlace(self: *Self, capacity: *const a11y.TreeCapacity) !void {
        try self.tree.initInPlace(capacity);
        self.enabled = false;
        self.check_counter = 0;
        self.platform_bridge = .{ .null_bridge = {} };
        self.bridge = a11y.NullBridge.bridge();
        std.debug.assert(self.bridgeAddressValid());
        std.debug.assert(!self.bridge.isActive());
    }

    pub fn bindPlatform(self: *Self, window: anytype, view: anytype) void {
        std.debug.assert(self.bridgeAddressValid());
        self.bridge.deinit();
        self.enabled = false;
        self.check_counter = 0;
        self.platform_bridge = .{ .null_bridge = {} };
        self.bridge = a11y.createPlatformBridge(
            &self.platform_bridge,
            @intCast(self.tree.elements.len),
            window,
            view,
        );
        std.debug.assert(self.bridgeAddressValid());
    }

    pub fn bindHeadless(self: *Self) void {
        std.debug.assert(self.bridgeAddressValid());
        self.bridge.deinit();
        self.enabled = false;
        self.check_counter = 0;
        self.platform_bridge = .{ .null_bridge = {} };
        self.bridge = a11y.NullBridge.bridge();
        std.debug.assert(!self.bridge.isActive());
    }

    pub fn bridgeAddressValid(self: *const Self) bool {
        if (self.platform_bridge == .null_bridge) return true;
        const storage_start = @intFromPtr(&self.platform_bridge);
        const storage_end = storage_start + @sizeOf(a11y.PlatformBridge);
        const bridge_address = @intFromPtr(self.bridge.ptr);
        if (bridge_address < storage_start) return false;
        return bridge_address < storage_end;
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.bridgeAddressValid());
        self.bridge.deinit();
        self.tree.deinit();
    }

    pub fn beginFrame(self: *Self) void {
        std.debug.assert(self.check_counter < a11y.constants.SCREEN_READER_CHECK_INTERVAL);
        std.debug.assert(self.bridgeAddressValid());

        self.check_counter += 1;
        if (self.check_counter >= a11y.constants.SCREEN_READER_CHECK_INTERVAL) {
            self.check_counter = 0;
            self.enabled = self.bridge.isActive();
        }

        if (self.enabled) {
            self.tree.beginFrame();
        }
    }

    pub fn isEnabled(self: *const Self) bool {
        return self.enabled;
    }

    pub fn forceEnable(self: *Self) void {
        self.enabled = true;
    }

    pub fn forceDisable(self: *Self) void {
        self.enabled = false;
    }

    pub fn getTree(self: *Self) *a11y.Tree {
        return &self.tree;
    }

    pub fn announce(self: *Self, message: []const u8, priority: a11y.Live) void {
        if (!self.enabled) return;
        self.tree.announce(message, priority);
    }
};

const testing = std.testing;

test "A11ySystem: initInPlace produces a disabled, freshly-counted system" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();
    sys.bindPlatform(null, null);

    try testing.expectEqual(false, sys.isEnabled());
    try testing.expectEqual(@as(u32, 0), sys.check_counter);
    try testing.expect(@intFromPtr(sys.bridge.ptr) != 0);
    try testing.expect(sys.bridgeAddressValid());
}

test "A11ySystem: a by-value copy is detected as a dangling bridge" {
    const original = try testing.allocator.create(A11ySystem);
    defer testing.allocator.destroy(original);
    try original.initInPlace(&a11y.TreeCapacity.standard);
    original.bindPlatform(null, null);
    defer original.deinit();

    const copy = try testing.allocator.create(A11ySystem);
    defer testing.allocator.destroy(copy);
    copy.* = original.*;

    try testing.expect(original.bridgeAddressValid());
    if (original.platform_bridge == .null_bridge) {
        try testing.expect(copy.bridgeAddressValid());
    } else {
        try testing.expect(!copy.bridgeAddressValid());
    }
}

test "A11ySystem: forceEnable / forceDisable flip the cached flag" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();

    sys.forceEnable();
    try testing.expectEqual(true, sys.isEnabled());

    sys.forceDisable();
    try testing.expectEqual(false, sys.isEnabled());
}

test "A11ySystem: announce is a no-op when disabled" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();

    try testing.expectEqual(false, sys.isEnabled());
    sys.announce("ignored", .polite);
    try testing.expectEqual(@as(u16, 0), sys.tree.announcement_count);
}

test "A11ySystem: announce reaches the tree when enabled" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();

    sys.forceEnable();
    sys.tree.beginFrame();
    sys.announce("hello", .polite);
    sys.tree.endFrame();

    try testing.expectEqual(@as(u16, 1), sys.tree.announcement_count);
}

test "A11ySystem: beginFrame increments the counter and resets at the interval" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();

    const interval = a11y.constants.SCREEN_READER_CHECK_INTERVAL;
    var i: u32 = 0;
    while (i < interval - 1) : (i += 1) {
        sys.beginFrame();
    }
    try testing.expectEqual(interval - 1, sys.check_counter);

    sys.beginFrame();
    try testing.expectEqual(@as(u32, 0), sys.check_counter);
}
