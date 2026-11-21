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

/// The bridges' element slots at the tests' tree capacity.
const element_count_max = a11y.TreeCapacity.standard.element_count_max;

/// A tree at the `standard` profile's capacity, on the heap like a window's.
fn createTree() !*Tree {
    const tree = try std.testing.allocator.create(Tree);
    errdefer std.testing.allocator.destroy(tree);
    try tree.initInPlace(&a11y.TreeCapacity.standard);
    return tree;
}

fn destroyTree(tree: *Tree) void {
    tree.deinit();
    std.testing.allocator.destroy(tree);
}

test "tree frame lifecycle" {
    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 1), tree.count());
    try std.testing.expectEqual(@as(usize, 1), tree.getDirtyElements().len);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(usize, 0), tree.getDirtyElements().len);
}

test "tree with multiple elements" {
    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();

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
    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();

    _ = tree.pushElement(.{ .role = .dialog, .name = "Confirm" });
    {
        _ = tree.pushElement(.{ .role = .heading, .name = "Are you sure?", .heading_level = .h2 });
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

    const focused_idx = tree.getFocusedIndex();
    try std.testing.expect(focused_idx != null);

    if (focused_idx) |idx| {
        const focused = tree.getElement(idx).?;
        try std.testing.expectEqualStrings("OK", focused.name.?);
    }
}

test "bridge syncFrame handles all operations" {
    var test_bridge = TestBridge{};
    const b = test_bridge.bridge();

    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test", .state = .{ .focused = true } });
    tree.popElement();
    tree.announce("Button focused", .polite);
    tree.endFrame();

    b.syncFrame(tree);

    try std.testing.expectEqual(@as(u32, 1), test_bridge.sync_count);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.announce_count);
    try std.testing.expectEqual(@as(u32, 1), test_bridge.focus_count);
}

test "bridge respects active flag" {
    var test_bridge = TestBridge{ .active = false };
    const b = test_bridge.bridge();

    const tree = try createTree();
    defer destroyTree(tree);
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(tree);

    try std.testing.expectEqual(@as(u32, 0), test_bridge.sync_count);
}

test "null bridge is safe no-op" {
    const b = NullBridge.bridge();

    const tree = try createTree();
    defer destroyTree(tree);
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.announce("Hello", .polite);
    tree.endFrame();

    b.syncFrame(tree);
    try std.testing.expect(!b.isActive());
}

test "element removal tracked across frames" {
    var test_bridge = TestBridge{};
    const b = test_bridge.bridge();

    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 2" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(tree);
    test_bridge.reset();

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    tree.endFrame();

    b.syncFrame(tree);

    try std.testing.expectEqual(@as(u32, 1), test_bridge.remove_count);
    try std.testing.expectEqual(@as(usize, 1), test_bridge.last_removed_count);
}

test "announcements with different priorities" {
    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();

    tree.announce("Item saved", .polite);

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
    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();
    tree.announce("Should be ignored", .off);
    tree.endFrame();

    try std.testing.expectEqual(@as(usize, 0), tree.getAnnouncements().len);
}

test "state changes mark element dirty" {
    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .checkbox,
        .name = "Agree",
        .state = .{ .checked = false },
    });
    tree.popElement();
    tree.endFrame();

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .checkbox,
        .name = "Agree",
        .state = .{ .checked = true },
    });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(usize, 1), tree.getDirtyElements().len);
}

test "value changes mark element dirty" {
    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .textbox,
        .name = "Input",
        .value = "hello",
    });
    tree.popElement();
    tree.endFrame();

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .textbox,
        .name = "Input",
        .value = "world",
    });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(usize, 1), tree.getDirtyElements().len);
}

test "focus change detected" {
    const tree = try createTree();
    defer destroyTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "A" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "B" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expect(!tree.focusChanged());

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "A" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "B", .state = .{ .focused = true } });
    tree.popElement();
    tree.endFrame();

    try std.testing.expect(tree.focusChanged());
}

test "slider with value range" {
    const tree = try createTree();
    defer destroyTree(tree);

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
    const tree = try createTree();
    defer destroyTree(tree);

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

    const first_item = tree.getElement(1).?;
    try std.testing.expectEqual(@as(?u16, 1), first_item.pos_in_set);
    try std.testing.expectEqual(@as(?u16, 3), first_item.set_size);
}

test "tree holds exactly its element capacity" {
    // Fill the tree to its capacity with siblings; the last push still lands.
    // One more push is a programmer error that asserts, so it is not run here;
    // the fail-fast check `core-a11y-elements` covers that boundary.
    const tree = try createTree();
    defer destroyTree(tree);

    const capacity = tree.elements.len;
    try std.testing.expectEqual(@as(usize, element_count_max), capacity);

    tree.beginFrame();
    var pushed: usize = 0;
    while (pushed < capacity) : (pushed += 1) {
        const index = tree.pushElement(.{ .role = .button, .name = "Test" });
        try std.testing.expectEqual(@as(u16, @intCast(pushed)), index);
        tree.popElement();
    }
    tree.endFrame();

    try std.testing.expectEqual(capacity, tree.count());
}

test "tree holds exactly its depth capacity" {
    const tree = try createTree();
    defer destroyTree(tree);

    const depth_max = tree.parent_stack.len;
    tree.beginFrame();
    var depth: usize = 0;
    while (depth < depth_max) : (depth += 1) {
        _ = tree.pushElement(.{ .role = .group, .name = "Nested" });
    }
    try std.testing.expectEqual(depth_max, @as(usize, tree.stack_depth));
    while (depth > 0) : (depth -= 1) {
        tree.popElement();
    }
    tree.endFrame();

    try std.testing.expectEqual(depth_max, tree.count());
}

test "zero overhead pattern" {
    // The pattern used in Builder.accessible().
    const a11y_enabled = false;

    var work_done = false;

    if (a11y_enabled) {
        work_done = true;
    }

    try std.testing.expect(!work_done);
}

test "platform bridge creation" {
    var platform_bridge: PlatformBridge = undefined;
    const b = a11y.createPlatformBridge(&platform_bridge, element_count_max, null, null);

    const tree = try createTree();
    defer destroyTree(tree);
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    // Safe no-ops when VoiceOver isn't running.
    b.syncDirty(tree, tree.getDirtyElements());
    b.removeElements(tree.getRemovedFingerprints());
    b.announce("Test announcement", .polite);
    b.focusChanged(tree, null);
    b.deinit();
}

test "platform bridge with full frame sync" {
    var platform_bridge: PlatformBridge = undefined;
    const b = a11y.createPlatformBridge(&platform_bridge, element_count_max, null, null);

    const tree = try createTree();
    defer destroyTree(tree);

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

    b.syncFrame(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .dialog, .name = "Settings" });
    {
        _ = tree.pushElement(.{ .role = .button, .name = "Save", .state = .{ .focused = true } });
        tree.popElement();
    }
    tree.popElement();
    tree.endFrame();

    b.syncFrame(tree);
    b.deinit();
}

test "macos bridge slot allocation" {
    if (builtin.os.tag != .macos) return;

    const fingerprint = @import("fingerprint.zig");

    var mac_bridge = MacBridge.init(element_count_max, null, null);
    defer mac_bridge.bridge().deinit();

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

    const slot1_again = mac_bridge.findOrAllocSlot(fp1);
    try std.testing.expectEqual(slot1, slot1_again);
}

test "macos bridge slot reuse after invalidation" {
    if (builtin.os.tag != .macos) return;

    const fingerprint = @import("fingerprint.zig");

    var mac_bridge = MacBridge.init(element_count_max, null, null);
    const b = mac_bridge.bridge();
    defer b.deinit();

    const fp1 = fingerprint.compute(.button, "Button1", null, 0);
    const slot1 = mac_bridge.findOrAllocSlot(fp1);
    try std.testing.expect(slot1 != null);

    const fps_to_remove = [_]fingerprint.Fingerprint{fp1};
    b.removeElements(&fps_to_remove);

    const fp2 = fingerprint.compute(.button, "Button2", null, 0);
    const slot2 = mac_bridge.findOrAllocSlot(fp2);
    try std.testing.expect(slot2 != null);
    try std.testing.expectEqual(slot1.?, slot2.?);
}

test "macos bridge voiceover detection" {
    if (builtin.os.tag != .macos) return;

    var mac_bridge = MacBridge.init(element_count_max, null, null);
    const b = mac_bridge.bridge();

    // The value depends on the system; just verify no crash.
    const is_active = b.isActive();
    _ = is_active;

    b.deinit();
}

test "macos bridge full lifecycle" {
    if (builtin.os.tag != .macos) return;

    var mac_bridge = MacBridge.init(element_count_max, null, null);
    const b = mac_bridge.bridge();

    const tree = try createTree();
    defer destroyTree(tree);

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

        b.syncFrame(tree);
    }

    b.deinit();
}
