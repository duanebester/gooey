//! Platform accessibility bridge interface.
//!
//! Each platform implements this interface to translate
//! the accessibility tree to native APIs (VoiceOver, AT-SPI2, ARIA).
//!
//! Design:
//! - VTable pattern for runtime polymorphism
//! - NullBridge for disabled/unsupported platforms
//! - All methods are safe to call (null-safe)

const std = @import("std");
const tree_mod = @import("tree.zig");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");
const constants = @import("constants.zig");

pub const Tree = tree_mod.Tree;
pub const Element = tree_mod.Element;
pub const Fingerprint = fingerprint_mod.Fingerprint;

/// Platform bridge interface
pub const Bridge = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Sync dirty elements to platform. Called at end of frame.
        /// Receives only indices of elements that changed.
        syncDirty: *const fn (
            ptr: *anyopaque,
            tree: *const Tree,
            dirty_indices: []const u16,
        ) void,

        /// Remove elements that no longer exist.
        /// Receives fingerprints for stable identity lookup.
        removeElements: *const fn (
            ptr: *anyopaque,
            fingerprints: []const Fingerprint,
        ) void,

        /// Process announcements.
        announce: *const fn (
            ptr: *anyopaque,
            message: []const u8,
            live: types.Live,
        ) void,

        /// Notify focus change.
        focusChanged: *const fn (
            ptr: *anyopaque,
            tree: *const Tree,
            element_index: ?u16,
        ) void,

        /// Check if screen reader is active.
        /// Called periodically (not every frame) to gate a11y work.
        isActive: *const fn (ptr: *anyopaque) bool,

        /// Clean up platform resources.
        deinit: *const fn (ptr: *anyopaque) void,
    };

    // =========================================================================
    // Convenience Wrappers
    // =========================================================================

    /// Sync dirty elements to platform
    pub fn syncDirty(self: Bridge, tree: *const Tree, dirty: []const u16) void {
        // Assertion: tree must be valid
        std.debug.assert(tree.count() <= constants.MAX_ELEMENTS);
        // Assertion: dirty indices must be within tree bounds
        std.debug.assert(dirty.len <= constants.MAX_ELEMENTS);

        self.vtable.syncDirty(self.ptr, tree, dirty);
    }

    /// Remove elements by fingerprint
    pub fn removeElements(self: Bridge, fps: []const Fingerprint) void {
        // Assertion: removal list bounded
        std.debug.assert(fps.len <= constants.MAX_ELEMENTS);

        self.vtable.removeElements(self.ptr, fps);
    }

    /// Announce message to screen reader
    pub fn announce(self: Bridge, msg: []const u8, live: types.Live) void {
        // Assertion: live level valid
        std.debug.assert(@intFromEnum(live) <= @intFromEnum(types.Live.assertive));

        self.vtable.announce(self.ptr, msg, live);
    }

    /// Notify that focus changed
    pub fn focusChanged(self: Bridge, tree: *const Tree, idx: ?u16) void {
        // Assertion: index within bounds if present
        std.debug.assert(idx == null or idx.? < tree.count());

        self.vtable.focusChanged(self.ptr, tree, idx);
    }

    /// Check if screen reader is currently active
    pub fn isActive(self: Bridge) bool {
        return self.vtable.isActive(self.ptr);
    }

    /// Clean up resources
    pub fn deinit(self: Bridge) void {
        self.vtable.deinit(self.ptr);
    }

    /// Perform full frame sync: sync dirty, remove old, announce, handle focus
    pub fn syncFrame(self: Bridge, tree: *const Tree) void {
        // Assertion: tree state is valid
        std.debug.assert(tree.count() <= constants.MAX_ELEMENTS);
        std.debug.assert(tree.stack_depth == 0); // Frame must be ended

        // Only sync if screen reader is active
        if (!self.isActive()) return;

        // Sync dirty elements (new or changed)
        const dirty = tree.getDirtyElements();
        if (dirty.len > 0) {
            self.syncDirty(tree, dirty);
        }

        // Remove elements that no longer exist
        const removed = tree.getRemovedFingerprints();
        if (removed.len > 0) {
            self.removeElements(removed);
        }

        // Process announcements
        const announcements = tree.getAnnouncements();
        for (announcements) |ann| {
            self.announce(ann.message, ann.live);
        }

        // Notify focus changes
        if (tree.focusChanged()) {
            self.focusChanged(tree, tree.getFocusedIndex());
        }
    }
};

/// Null bridge for when a11y is disabled or unsupported.
/// All operations are safe no-ops.
pub const NullBridge = struct {
    /// Get Bridge interface pointing to null implementation
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

/// Test bridge that records calls for verification
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

    /// Get Bridge interface
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

    /// Reset all counters and state
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

// Compile-time assertions per CLAUDE.md
comptime {
    // Bridge should be small (just two pointers)
    std.debug.assert(@sizeOf(Bridge) == 2 * @sizeOf(usize));

    // VTable should have all required functions
    std.debug.assert(@sizeOf(Bridge.VTable) == 6 * @sizeOf(usize));
}

test "null bridge is safe" {
    const b = NullBridge.bridge();

    // All operations should be no-ops
    var tree = Tree.init();
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    b.syncDirty(&tree, tree.getDirtyElements());
    b.removeElements(tree.getRemovedFingerprints());
    b.announce("Test", .polite);
    b.focusChanged(&tree, null);
    try std.testing.expect(!b.isActive());
    b.deinit();
}

test "test bridge records calls" {
    var test_bridge = TestBridge{};
    const b = test_bridge.bridge();

    var tree = Tree.init();
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .button,
        .name = "Submit",
        .state = .{ .focused = true },
    });
    tree.popElement();
    tree.announce("Button focused", .polite);
    tree.endFrame();

    // Sync frame (active = true)
    b.syncFrame(&tree);

    try std.testing.expectEqual(@as(u32, 1), test_bridge.sync_count);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.announce_count);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.focus_count);
    try std.testing.expectEqualStrings("Button focused", test_bridge.last_announcement.?);
    try std.testing.expectEqual(@as(?u16, 0), test_bridge.last_focus_index);
}

test "test bridge respects active flag" {
    var test_bridge = TestBridge{ .active = false };
    const b = test_bridge.bridge();

    var tree = Tree.init();
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    // syncFrame should early-out when not active
    b.syncFrame(&tree);

    try std.testing.expectEqual(@as(u32, 0), test_bridge.sync_count);
}

test "bridge syncFrame handles all operations" {
    var test_bridge = TestBridge{};
    const b = test_bridge.bridge();

    // Frame 1: Create two elements
    var tree = Tree.init();
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 2" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(&tree);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.sync_count);
    try std.testing.expectEqual(@as(usize, 2), test_bridge.last_dirty_count);

    test_bridge.reset();

    // Frame 2: Remove one element
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(&tree);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.remove_count);
    try std.testing.expectEqual(@as(usize, 1), test_bridge.last_removed_count);
}
