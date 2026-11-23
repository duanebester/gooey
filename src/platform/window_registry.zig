const std = @import("std");
const limits = @import("../core/limits.zig");

pub const WindowId = enum(u32) {
    invalid = 0,
    _,

    pub fn isValid(self: WindowId) bool {
        return self != .invalid;
    }

    pub fn raw(self: WindowId) u32 {
        return @backingInt(self);
    }

    pub fn fromRaw(value: u32) WindowId {
        std.debug.assert(value != 0);
        return @fromBackingInt(@intCast(value));
    }
};

pub const WindowRegistry = struct {
    ids: [window_count_max]WindowId,
    pointers: [window_count_max]*anyopaque,
    window_count: u32,

    next_id: u32,

    active_window: ?WindowId,

    pub const window_count_max: u32 = limits.window_count_max;

    const Self = @This();

    pub fn init() Self {
        return .{
            .ids = @splat(.invalid),
            .pointers = undefined,
            .window_count = 0,
            .next_id = 1,
            .active_window = null,
        };
    }

    pub fn register(self: *Self, window_ptr: *anyopaque) error{TooManyWindows}!WindowId {
        std.debug.assert(@intFromPtr(window_ptr) != 0);
        std.debug.assert(self.window_count <= window_count_max);
        if (self.window_count == window_count_max) return error.TooManyWindows;
        const slot = self.slotOf(.invalid).?;
        const id: WindowId = @fromBackingInt(self.next_id);
        std.debug.assert(id.isValid());
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        self.ids[slot] = id;
        self.pointers[slot] = window_ptr;
        self.window_count += 1;

        return id;
    }

    pub fn unregister(self: *Self, id: WindowId) ?*anyopaque {
        std.debug.assert(id.isValid());
        std.debug.assert(self.window_count <= window_count_max);

        if (self.active_window) |active| {
            if (active == id) self.active_window = null;
        }
        const slot = self.slotOf(id) orelse return null;
        self.ids[slot] = .invalid;
        self.window_count -= 1;
        return self.pointers[slot];
    }

    fn slotOf(self: *const Self, id: WindowId) ?u32 {
        for (self.ids, 0..) |slot_id, slot| {
            if (slot_id == id) return @intCast(slot);
        }
        return null;
    }

    pub fn get(self: *const Self, id: WindowId) ?*anyopaque {
        if (!id.isValid()) return null;
        const slot = self.slotOf(id) orelse return null;
        return self.pointers[slot];
    }

    pub fn getTyped(self: *const Self, comptime T: type, id: WindowId) ?*T {
        comptime std.debug.assert(@sizeOf(T) > 0);

        if (self.get(id)) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    pub fn contains(self: *const Self, id: WindowId) bool {
        if (!id.isValid()) return false;
        return self.slotOf(id) != null;
    }

    pub fn setActiveWindow(self: *Self, id: ?WindowId) void {
        if (id) |window_id| {
            std.debug.assert(window_id.isValid());
            std.debug.assert(self.contains(window_id));
        }
        self.active_window = id;
    }

    pub fn getActiveWindow(self: *const Self) ?WindowId {
        return self.active_window;
    }

    pub fn getActiveWindowTyped(self: *const Self, comptime T: type) ?*T {
        if (self.active_window) |id| {
            return self.getTyped(T, id);
        }
        return null;
    }

    pub fn count(self: *const Self) u32 {
        std.debug.assert(self.window_count <= window_count_max);
        return self.window_count;
    }

    pub fn iterator(self: *const Self) Iterator {
        return .{ .registry = self, .slot = 0 };
    }

    pub const Iterator = struct {
        registry: *const Self,
        slot: u32,

        pub fn next(self: *Iterator) ?*const WindowId {
            while (self.slot < window_count_max) {
                const id = &self.registry.ids[self.slot];
                self.slot += 1;
                if (id.isValid()) return id;
            }
            return null;
        }
    };
};

test "WindowId - basic operations" {
    const invalid = WindowId.invalid;
    std.debug.assert(!invalid.isValid());
    std.debug.assert(invalid.raw() == 0);

    const valid = WindowId.fromRaw(42);
    std.debug.assert(valid.isValid());
    std.debug.assert(valid.raw() == 42);
}

test "WindowRegistry - register and lookup" {
    var registry: WindowRegistry = .init();
    var dummy: u32 = 1;
    const id = try registry.register(&dummy);
    try std.testing.expect(id.isValid());
    try std.testing.expectEqual(@as(u32, 1), registry.getTyped(u32, id).?.*);
    try std.testing.expectEqual(@as(?*anyopaque, null), registry.get(WindowId.fromRaw(99)));
    var ids = registry.iterator();
    try std.testing.expectEqual(id, ids.next().?.*);
    try std.testing.expect(ids.next() == null);
}

test "WindowRegistry - holds window_count_max windows, then refuses one more" {
    var registry: WindowRegistry = .init();
    var dummies: [WindowRegistry.window_count_max + 1]u32 = @splat(0);
    var ids: [WindowRegistry.window_count_max]WindowId = undefined;
    for (&ids, dummies[0..ids.len]) |*id, *dummy| id.* = try registry.register(dummy);
    try std.testing.expectEqual(WindowRegistry.window_count_max, registry.count());
    const extra = &dummies[dummies.len - 1];
    try std.testing.expectError(error.TooManyWindows, registry.register(extra));
    try std.testing.expectEqual(WindowRegistry.window_count_max, registry.count());

    _ = registry.unregister(ids[0]);
    try std.testing.expect(!registry.contains(ids[0]));
    const again = try registry.register(extra);
    try std.testing.expect(again != ids[0]);
    try std.testing.expectEqual(@as(*anyopaque, extra), registry.get(again).?);
}

test "WindowRegistry - registration does not elect an active window" {
    var registry: WindowRegistry = .init();
    var dummy: u32 = 1;
    const id = try registry.register(&dummy);
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());

    registry.setActiveWindow(id);
    try std.testing.expectEqual(id, registry.getActiveWindow().?);
}

test "WindowRegistry - unregistering the active window clears the slot" {
    var registry: WindowRegistry = .init();
    var dummy: u32 = 7;
    const id = try registry.register(&dummy);
    registry.setActiveWindow(id);
    try std.testing.expectEqual(id, registry.getActiveWindow().?);

    try std.testing.expectEqual(@as(?*anyopaque, &dummy), registry.unregister(id));
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());
    try std.testing.expectEqual(@as(u32, 0), registry.count());
    try std.testing.expectEqual(@as(?*anyopaque, null), registry.unregister(id));

    registry.setActiveWindow(null);
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());
}
