const std = @import("std");
const tree_mod = @import("tree.zig");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");

pub const Tree = tree_mod.Tree;
pub const Element = tree_mod.Element;
pub const Fingerprint = fingerprint_mod.Fingerprint;

pub const Bridge = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called every synced frame, even with an empty list, so pull-based
        /// bridges (Windows) can refresh bounds that moved.
        syncDirty: *const fn (
            ptr: *anyopaque,
            tree: *const Tree,
            dirty_indices: []const u16,
        ) void,

        /// Remove elements that no longer exist.
        removeElements: *const fn (
            ptr: *anyopaque,
            fingerprints: []const Fingerprint,
        ) void,

        announce: *const fn (
            ptr: *anyopaque,
            message: []const u8,
            live: types.Live,
        ) void,

        focusChanged: *const fn (
            ptr: *anyopaque,
            tree: *const Tree,
            element_index: ?u16,
        ) void,

        /// Called periodically, not every frame, to gate a11y work.
        isActive: *const fn (ptr: *anyopaque) bool,

        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn syncDirty(self: Bridge, tree: *const Tree, dirty: []const u16) void {
        std.debug.assert(tree.count() <= tree.elements.len);
        std.debug.assert(dirty.len <= tree.count());

        self.vtable.syncDirty(self.ptr, tree, dirty);
    }

    pub fn removeElements(self: Bridge, fps: []const Fingerprint) void {
        std.debug.assert(fps.len <= @import("../core/limits.zig").a11y_element_count_ceiling);

        self.vtable.removeElements(self.ptr, fps);
    }

    pub fn announce(self: Bridge, msg: []const u8, live: types.Live) void {
        std.debug.assert(@backingInt(live) <= @backingInt(types.Live.assertive));

        self.vtable.announce(self.ptr, msg, live);
    }

    pub fn focusChanged(self: Bridge, tree: *const Tree, idx: ?u16) void {
        std.debug.assert(idx == null or idx.? < tree.count());

        self.vtable.focusChanged(self.ptr, tree, idx);
    }

    pub fn isActive(self: Bridge) bool {
        return self.vtable.isActive(self.ptr);
    }

    pub fn deinit(self: Bridge) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn syncFrame(self: Bridge, tree: *const Tree) void {
        std.debug.assert(tree.count() <= tree.elements.len);
        std.debug.assert(tree.stack_depth == 0);

        if (!self.isActive()) return;

        // Called even when none are dirty; see `VTable.syncDirty`.
        self.syncDirty(tree, tree.getDirtyElements());

        const removed = tree.getRemovedFingerprints();
        if (removed.len > 0) {
            self.removeElements(removed);
        }

        const announcements = tree.getAnnouncements();
        for (announcements) |ann| {
            self.announce(ann.message, ann.live);
        }

        if (tree.focusChanged()) {
            self.focusChanged(tree, tree.getFocusedIndex());
        }
    }
};

/// Safe no-ops, for when a11y is disabled or unsupported.
pub const NullBridge = struct {
    pub fn bridge() Bridge {
        return .{
            .ptr = undefined,
            .vtable = &vtable,
        };
    }

    const vtable = VTable{
        .syncDirty = syncDirty,
        .removeElements = removeElements,
        .announce = announce_,
        .focusChanged = focusChanged,
        .isActive = isActive,
        .deinit = deinit_,
    };

    const VTable = Bridge.VTable;

    fn syncDirty(_: *anyopaque, _: *const Tree, _: []const u16) void {}
    fn removeElements(_: *anyopaque, _: []const Fingerprint) void {}
    fn announce_(_: *anyopaque, _: []const u8, _: types.Live) void {}
    fn focusChanged(_: *anyopaque, _: *const Tree, _: ?u16) void {}
    fn isActive(_: *anyopaque) bool {
        return false;
    }
    fn deinit_(_: *anyopaque) void {}
};

pub const TestBridge = struct {
    sync_count: u32 = 0,
    remove_count: u32 = 0,
    announce_count: u32 = 0,
    focus_count: u32 = 0,
    active: bool = true,

    last_dirty_count: usize = 0,
    last_removed_count: usize = 0,
    last_announcement: ?[]const u8 = null,
    last_focus_index: ?u16 = null,

    const Self = @This();

    pub fn bridge(self: *Self) Bridge {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Bridge.VTable{
        .syncDirty = syncDirty,
        .removeElements = removeElements,
        .announce = announce_,
        .focusChanged = focusChanged,
        .isActive = isActive,
        .deinit = deinit_,
    };

    fn syncDirty(ptr: *anyopaque, _: *const Tree, dirty: []const u16) void {
        const self = castSelf(ptr);
        self.sync_count += 1;
        self.last_dirty_count = dirty.len;
    }

    fn removeElements(ptr: *anyopaque, fps: []const Fingerprint) void {
        const self = castSelf(ptr);
        self.remove_count += 1;
        self.last_removed_count = fps.len;
    }

    fn announce_(ptr: *anyopaque, msg: []const u8, _: types.Live) void {
        const self = castSelf(ptr);
        self.announce_count += 1;
        self.last_announcement = msg;
    }

    fn focusChanged(ptr: *anyopaque, _: *const Tree, idx: ?u16) void {
        const self = castSelf(ptr);
        self.focus_count += 1;
        self.last_focus_index = idx;
    }

    fn isActive(ptr: *anyopaque) bool {
        const self = castSelf(ptr);
        return self.active;
    }

    fn deinit_(_: *anyopaque) void {}

    fn castSelf(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn reset(self: *Self) void {
        self.sync_count = 0;
        self.remove_count = 0;
        self.announce_count = 0;
        self.focus_count = 0;
        self.last_dirty_count = 0;
        self.last_removed_count = 0;
        self.last_announcement = null;
        self.last_focus_index = null;
    }
};

comptime {
    std.debug.assert(@sizeOf(Bridge) == 2 * @sizeOf(usize));

    std.debug.assert(@sizeOf(Bridge.VTable) == 6 * @sizeOf(usize));
}

/// A tree at the tests' capacity, on the heap like a window's.
fn createTestTree() !*Tree {
    const tree = try std.testing.allocator.create(Tree);
    errdefer std.testing.allocator.destroy(tree);
    try tree.initInPlace(&tree_mod.Capacity.standard);
    return tree;
}

fn destroyTestTree(tree: *Tree) void {
    tree.deinit();
    std.testing.allocator.destroy(tree);
}

test "null bridge is safe" {
    const b = NullBridge.bridge();

    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    b.syncDirty(tree, tree.getDirtyElements());
    b.removeElements(tree.getRemovedFingerprints());
    b.announce("Test", .polite);
    b.focusChanged(tree, null);
    try std.testing.expect(!b.isActive());
    b.deinit();
}

test "test bridge records calls" {
    var test_bridge = TestBridge{};
    const b = test_bridge.bridge();

    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .button,
        .name = "Submit",
        .state = .{ .focused = true },
    });
    tree.popElement();
    tree.announce("Button focused", .polite);
    tree.endFrame();

    b.syncFrame(tree);

    try std.testing.expectEqual(@as(u32, 1), test_bridge.sync_count);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.announce_count);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.focus_count);
    try std.testing.expectEqualStrings("Button focused", test_bridge.last_announcement.?);
    try std.testing.expectEqual(@as(?u16, 0), test_bridge.last_focus_index);
}

test "test bridge respects active flag" {
    var test_bridge = TestBridge{ .active = false };
    const b = test_bridge.bridge();

    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    // syncFrame early-outs when not active.
    b.syncFrame(tree);

    try std.testing.expectEqual(@as(u32, 0), test_bridge.sync_count);
}

test "bridge syncFrame handles all operations" {
    var test_bridge = TestBridge{};
    const b = test_bridge.bridge();

    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 2" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(tree);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.sync_count);
    try std.testing.expectEqual(@as(usize, 2), test_bridge.last_dirty_count);

    test_bridge.reset();

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(tree);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.remove_count);
    try std.testing.expectEqual(@as(usize, 1), test_bridge.last_removed_count);
}
