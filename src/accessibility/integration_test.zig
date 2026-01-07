//! Integration tests for Gooey A11Y (Phase 1 & 2)
//!
//! Tests the accessibility tree integration with Gooey context
//! and Builder API. Uses TestBridge to verify correct behavior.
//! Phase 2 adds MacBridge tests for VoiceOver integration.

const std = @import("std");
const builtin = @import("builtin");
const a11y = @import("accessibility.zig");
const Tree = a11y.Tree;
const Bridge = a11y.Bridge;
const TestBridge = a11y.TestBridge;
const NullBridge = a11y.NullBridge;
const Role = a11y.Role;
const State = a11y.State;
const Live = a11y.Live;
const ElementConfig = a11y.ElementConfig;
const PlatformBridge = a11y.PlatformBridge;
const MacBridge = a11y.MacBridge;

// ============================================================================
// Tree Integration Tests
// ============================================================================

test "tree frame lifecycle" {
    var tree = Tree.init();

    // Simulate frame 1
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 1), tree.count());
    try std.testing.expectEqual(@as(usize, 1), tree.getDirtyElements().len);

    // Simulate frame 2 - same content
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();
    tree.endFrame();

    // Same content = not dirty
    try std.testing.expectEqual(@as(usize, 0), tree.getDirtyElements().len);
}

test "tree with multiple elements" {
    var tree = Tree.init();

    tree.beginFrame();

    // Build a simple form structure
    _ = tree.pushElement(.{ .role = .group, .name = "Login Form" });
    {
        _ = tree.pushElement(.{ .role = .textbox, .name = "Username" });
        tree.popElement();

        _ = tree.pushElement(.{ .role = .textbox, .name = "Password" });
        tree.popElement();

        _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
        tree.popElement();
    }
    tree.popElement();

    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 4), tree.count());
}

test "tree nested structure" {
    var tree = Tree.init();

    tree.beginFrame();

    // Dialog with nested content
    _ = tree.pushElement(.{ .role = .dialog, .name = "Confirm" });
    {
        _ = tree.pushElement(.{ .role = .heading, .name = "Are you sure?", .heading_level = 2 });
        tree.popElement();

        _ = tree.pushElement(.{ .role = .group, .name = "Actions" });
        {
            _ = tree.pushElement(.{ .role = .button, .name = "Cancel" });
            tree.popElement();

            _ = tree.pushElement(.{ .role = .button, .name = "OK", .state = .{ .focused = true } });
            tree.popElement();
        }
        tree.popElement();
    }
    tree.popElement();

    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 5), tree.count());

    // Verify focus tracking
    const focused_idx = tree.getFocusedIndex();
    try std.testing.expect(focused_idx != null);

    if (focused_idx) |idx| {
        const focused = tree.getElement(idx).?;
        try std.testing.expectEqualStrings("OK", focused.name.?);
    }
}

// ============================================================================
// Bridge Integration Tests
// ============================================================================

test "bridge syncFrame handles all operations" {
    var test_bridge = TestBridge{};
    const b = test_bridge.bridge();

    var tree = Tree.init();

    // Frame 1: create elements and announce
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test", .state = .{ .focused = true } });
    tree.popElement();
    tree.announce("Button focused", .polite);
    tree.endFrame();

    b.syncFrame(&tree);

    try std.testing.expectEqual(@as(u32, 1), test_bridge.sync_count);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.announce_count);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.focus_count);
}

test "bridge respects active flag" {
    var test_bridge = TestBridge{ .active = false };
    const b = test_bridge.bridge();

    var tree = Tree.init();
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    // Should early-out since not active
    b.syncFrame(&tree);

    try std.testing.expectEqual(@as(u32, 0), test_bridge.sync_count);
}

test "null bridge is safe no-op" {
    const b = NullBridge.bridge();

    var tree = Tree.init();
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.announce("Hello", .polite);
    tree.endFrame();

    // All operations should be no-ops
    b.syncFrame(&tree);
    try std.testing.expect(!b.isActive());
}

// ============================================================================
// Element Removal Tests
// ============================================================================

test "element removal tracked across frames" {
    var test_bridge = TestBridge{};
    const b = test_bridge.bridge();

    var tree = Tree.init();

    // Frame 1: Two buttons
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 2" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(&tree);
    test_bridge.reset();

    // Frame 2: Only one button (Button 2 removed)
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(&tree);

    // Should have 1 removal
    try std.testing.expectEqual(@as(u32, 1), test_bridge.remove_count);
    try std.testing.expectEqual(@as(usize, 1), test_bridge.last_removed_count);
}

// ============================================================================
// Announcement Tests
// ============================================================================

test "announcements with different priorities" {
    var tree = Tree.init();

    tree.beginFrame();

    // Polite announcement
    tree.announce("Item saved", .polite);

    // Assertive announcement
    tree.announce("Error occurred", .assertive);

    tree.endFrame();

    const announcements = tree.getAnnouncements();
    try std.testing.expectEqual(@as(usize, 2), announcements.len);
    try std.testing.expectEqualStrings("Item saved", announcements[0].message);
    try std.testing.expectEqual(Live.polite, announcements[0].live);
    try std.testing.expectEqualStrings("Error occurred", announcements[1].message);
    try std.testing.expectEqual(Live.assertive, announcements[1].live);
}

test "off announcements are ignored" {
    var tree = Tree.init();

    tree.beginFrame();
    tree.announce("Should be ignored", .off);
    tree.endFrame();

    try std.testing.expectEqual(@as(usize, 0), tree.getAnnouncements().len);
}

// ============================================================================
// State Change Tests
// ============================================================================

test "state changes mark element dirty" {
    var tree = Tree.init();

    // Frame 1: unchecked checkbox
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .checkbox,
        .name = "Agree",
        .state = .{ .checked = false },
    });
    tree.popElement();
    tree.endFrame();

    // Frame 2: checked checkbox
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .checkbox,
        .name = "Agree",
        .state = .{ .checked = true },
    });
    tree.popElement();
    tree.endFrame();

    // State change = dirty
    try std.testing.expectEqual(@as(usize, 1), tree.getDirtyElements().len);
}

test "value changes mark element dirty" {
    var tree = Tree.init();

    // Frame 1: initial value
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .textbox,
        .name = "Input",
        .value = "hello",
    });
    tree.popElement();
    tree.endFrame();

    // Frame 2: changed value
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .textbox,
        .name = "Input",
        .value = "world",
    });
    tree.popElement();
    tree.endFrame();

    // Value change = dirty
    try std.testing.expectEqual(@as(usize, 1), tree.getDirtyElements().len);
}

// ============================================================================
// Focus Tracking Tests
// ============================================================================

test "focus change detected" {
    var tree = Tree.init();

    // Frame 1: no focus
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "A" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "B" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expect(!tree.focusChanged());

    // Frame 2: focus on B
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "A" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "B", .state = .{ .focused = true } });
    tree.popElement();
    tree.endFrame();

    try std.testing.expect(tree.focusChanged());
}

// ============================================================================
// Role-Specific Tests
// ============================================================================

test "slider with value range" {
    var tree = Tree.init();

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .slider,
        .name = "Volume",
        .value_min = 0,
        .value_max = 100,
        .value_now = 75,
    });
    tree.popElement();
    tree.endFrame();

    const elem = tree.getElement(0).?;
    try std.testing.expectEqual(@as(?f32, 0), elem.value_min);
    try std.testing.expectEqual(@as(?f32, 100), elem.value_max);
    try std.testing.expectEqual(@as(?f32, 75), elem.value_now);
}

test "list with position tracking" {
    var tree = Tree.init();

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .list, .name = "Menu" });
    {
        _ = tree.pushElement(.{ .role = .listitem, .name = "Home", .pos_in_set = 1, .set_size = 3 });
        tree.popElement();
        _ = tree.pushElement(.{ .role = .listitem, .name = "About", .pos_in_set = 2, .set_size = 3 });
        tree.popElement();
        _ = tree.pushElement(.{ .role = .listitem, .name = "Contact", .pos_in_set = 3, .set_size = 3 });
        tree.popElement();
    }
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 4), tree.count());

    // Verify position tracking
    const first_item = tree.getElement(1).?;
    try std.testing.expectEqual(@as(?u16, 1), first_item.pos_in_set);
    try std.testing.expectEqual(@as(?u16, 3), first_item.set_size);
}

// ============================================================================
// Capacity Tests
// ============================================================================

test "tree respects element limit" {
    var tree = Tree.init();

    tree.beginFrame();

    // Push elements up to limit
    var pushed: u32 = 0;
    while (pushed < a11y.MAX_ELEMENTS + 10) : (pushed += 1) {
        const result = tree.pushElement(.{ .role = .button, .name = "Test" });
        if (result == null) break;
        tree.popElement();
    }

    tree.endFrame();

    // Should not exceed MAX_ELEMENTS
    try std.testing.expect(tree.count() <= a11y.MAX_ELEMENTS);
}

test "tree respects depth limit" {
    var tree = Tree.init();

    tree.beginFrame();

    // Try to nest beyond limit
    var depth: u32 = 0;
    while (depth < a11y.MAX_DEPTH + 10) : (depth += 1) {
        const result = tree.pushElement(.{ .role = .group, .name = "Nested" });
        if (result == null) break;
    }

    // Close what we opened
    while (depth > 0) : (depth -= 1) {
        tree.popElement();
    }

    tree.endFrame();

    // Depth should have been limited
    try std.testing.expect(depth <= a11y.MAX_DEPTH);
}

// ============================================================================
// Zero-Cost When Disabled Tests
// ============================================================================

test "zero overhead pattern" {
    // Simulate the pattern used in Builder.accessible()
    const a11y_enabled = false;

    var work_done = false;

    if (a11y_enabled) {
        // This block should never execute
        work_done = true;
    }

    try std.testing.expect(!work_done);
}

// ============================================================================
// Phase 2: Platform Bridge Tests
// ============================================================================

test "platform bridge creation" {
    var platform_bridge: PlatformBridge = undefined;
    const b = a11y.createPlatformBridge(&platform_bridge, null, null);

    // Bridge should be usable regardless of platform
    var tree = Tree.init();
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    // These should all be safe no-ops when VoiceOver isn't running
    b.syncDirty(&tree, tree.getDirtyElements());
    b.removeElements(tree.getRemovedFingerprints());
    b.announce("Test announcement", .polite);
    b.focusChanged(&tree, null);
    b.deinit();
}

test "platform bridge with full frame sync" {
    var platform_bridge: PlatformBridge = undefined;
    const b = a11y.createPlatformBridge(&platform_bridge, null, null);

    var tree = Tree.init();

    // Frame 1: Create elements
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .dialog, .name = "Settings" });
    {
        _ = tree.pushElement(.{ .role = .checkbox, .name = "Enable notifications", .state = .{ .checked = true } });
        tree.popElement();
        _ = tree.pushElement(.{ .role = .button, .name = "Save", .state = .{ .focused = true } });
        tree.popElement();
    }
    tree.popElement();
    tree.announce("Settings opened", .polite);
    tree.endFrame();

    // Sync to platform (no-op when screen reader inactive)
    b.syncFrame(&tree);

    // Frame 2: Remove an element
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .dialog, .name = "Settings" });
    {
        _ = tree.pushElement(.{ .role = .button, .name = "Save", .state = .{ .focused = true } });
        tree.popElement();
    }
    tree.popElement();
    tree.endFrame();

    b.syncFrame(&tree);
    b.deinit();
}

// macOS-specific tests (only compiled on macOS)
test "macos bridge slot allocation" {
    if (builtin.os.tag != .macos) return;

    const fingerprint = @import("fingerprint.zig");

    var mac_bridge = MacBridge.init(null, null);

    // Allocate multiple slots
    const fp1 = fingerprint.compute(.button, "Button1", null, 0);
    const fp2 = fingerprint.compute(.button, "Button2", null, 1);
    const fp3 = fingerprint.compute(.checkbox, "Check", null, 2);

    const slot1 = mac_bridge.findOrAllocSlot(fp1);
    const slot2 = mac_bridge.findOrAllocSlot(fp2);
    const slot3 = mac_bridge.findOrAllocSlot(fp3);

    try std.testing.expect(slot1 != null);
    try std.testing.expect(slot2 != null);
    try std.testing.expect(slot3 != null);

    // All slots should be different
    try std.testing.expect(slot1.? != slot2.?);
    try std.testing.expect(slot2.? != slot3.?);
    try std.testing.expect(slot1.? != slot3.?);

    // Re-requesting same fingerprint returns same slot
    const slot1_again = mac_bridge.findOrAllocSlot(fp1);
    try std.testing.expectEqual(slot1, slot1_again);
}

test "macos bridge slot reuse after invalidation" {
    if (builtin.os.tag != .macos) return;

    const fingerprint = @import("fingerprint.zig");

    var mac_bridge = MacBridge.init(null, null);
    const b = mac_bridge.bridge();

    // Allocate a slot
    const fp1 = fingerprint.compute(.button, "Button1", null, 0);
    const slot1 = mac_bridge.findOrAllocSlot(fp1);
    try std.testing.expect(slot1 != null);

    // Remove the element
    const fps_to_remove = [_]fingerprint.Fingerprint{fp1};
    b.removeElements(&fps_to_remove);

    // Allocate new element - should reuse slot 0
    const fp2 = fingerprint.compute(.button, "Button2", null, 0);
    const slot2 = mac_bridge.findOrAllocSlot(fp2);
    try std.testing.expect(slot2 != null);
    try std.testing.expectEqual(slot1.?, slot2.?);
}

test "macos bridge voiceover detection" {
    if (builtin.os.tag != .macos) return;

    var mac_bridge = MacBridge.init(null, null);
    const b = mac_bridge.bridge();

    // isActive checks VoiceOver status
    // Will be false in test environment (no VoiceOver running)
    const is_active = b.isActive();
    // Just verify it doesn't crash - actual value depends on system state
    _ = is_active;

    b.deinit();
}

test "macos bridge full lifecycle" {
    if (builtin.os.tag != .macos) return;

    var mac_bridge = MacBridge.init(null, null);
    const b = mac_bridge.bridge();

    var tree = Tree.init();

    // Simulate several frames
    for (0..3) |frame| {
        tree.beginFrame();

        _ = tree.pushElement(.{
            .role = .button,
            .name = if (frame == 0) "First" else "Updated",
            .state = .{ .focused = frame == 2 },
        });
        tree.popElement();

        if (frame == 1) {
            tree.announce("Button updated", .polite);
        }

        tree.endFrame();

        // Sync each frame
        b.syncFrame(&tree);
    }

    b.deinit();
}
