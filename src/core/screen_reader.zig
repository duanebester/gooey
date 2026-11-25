const std = @import("std");
const records = @import("records.zig");
const A11ySystem = @import("a11y_system.zig").A11ySystem;
const a11y = @import("../accessibility/accessibility.zig");

const assert = std.debug.assert;

pub const poll_interval_ns: u64 = std.time.ns_per_s;

pub const Poll = struct { last_ns: ?u64 = null };

pub fn publish(system: *A11ySystem, poll: *Poll, frame: *const records.Frame, now_ns: u64) void {
    assert(frame.a11y_count <= frame.a11y.len);
    assert(frame.a11y.len <= system.tree.elements.len);
    const due = if (poll.last_ns) |last| now_ns -| last >= poll_interval_ns else true;
    if (due) {
        poll.last_ns = now_ns;
        system.enabled = system.bridge.isActive();
    }
    if (!system.isEnabled()) return;
    const tree = system.getTree();
    tree.beginFrame();
    var open: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        assert(node.depth <= open);
        while (open > node.depth) : (open -= 1) tree.popElement();
        push(tree, frame, node);
        open += 1;
    }
    while (open > 0) : (open -= 1) tree.popElement();
    for (frame.announcements.slice()) |item| {
        tree.announce(frame.announcements.text(item), item.live);
    }
    tree.endFrame();
    system.bridge.syncFrame(tree);
    assert(tree.stack_depth == 0);
}

fn push(tree: *a11y.Tree, frame: *const records.Frame, node: *const records.A11yNode) void {
    const index = tree.pushElement(.{
        .role = node.role,
        .name = frame.text(node.name),
        .value = frame.text(node.value),
        .description = if (node.description.len > 0) frame.text(node.description) else null,
        .state = node.state,
        .live = node.live,
        .heading_level = node.heading_level,
        .pos_in_set = node.pos_in_set,
        .set_size = node.set_size,
        .value_min = if (node.range) |range| range.min else null,
        .value_max = if (node.range) |range| range.max else null,
        .value_now = if (node.range) |range| range.now else null,
        .orientation = if (node.range) |range| range.orientation else null,
    });
    const element = tree.getElementMut(index).?;
    element.bounds = .{
        .x = node.bounds.x,
        .y = node.bounds.y,
        .width = node.bounds.width,
        .height = node.bounds.height,
    };
    if (node.selection) |selection| {
        assert(selection.start <= selection.end);
        assert(selection.end <= node.value.len);
        if (node.state.focused) element.selection = selection;
    }
    assert(element.role == node.role);
}

test "the bridge is polled on the first frame and then once per interval" {
    const system = try std.testing.allocator.create(A11ySystem);
    defer std.testing.allocator.destroy(system);
    try system.initInPlace(&a11y.TreeCapacity.standard);
    defer system.deinit();
    var frame: records.Frame = undefined;
    try frame.initInPlace(std.testing.allocator, &.{
        .paint_record_count_max = 1,
        .hit_record_count_max = 1,
        .handler_count_max = 1,
        .a11y_node_count_max = 1,
        .announcements = .{ .polite_pending_max = 1, .message_bytes_max = 1 },
        .text_bytes_max = 1,
        .mesh_point_count_max = 0,
        .params_slot_count_max = 0,
        .params_stride = 0,
    });
    defer frame.deinit(std.testing.allocator);
    var poll: Poll = .{};
    publish(system, &poll, &frame, 5);
    try std.testing.expectEqual(@as(?u64, 5), poll.last_ns);
    publish(system, &poll, &frame, 5 + poll_interval_ns - 1);
    try std.testing.expectEqual(@as(?u64, 5), poll.last_ns);
    publish(system, &poll, &frame, 5 + poll_interval_ns);
    try std.testing.expectEqual(@as(?u64, 5 + poll_interval_ns), poll.last_ns);
    try std.testing.expect(!system.isEnabled());
}

test "a full nano frame publishes every node and announcement into a nano tree" {
    const limits_mod = @import("limits.zig");
    const nano = limits_mod.ResourceLimits.nano;
    const gpa = std.testing.allocator;
    const system = try gpa.create(A11ySystem);
    defer gpa.destroy(system);

    try system.initInPlace(&a11y.TreeCapacity.fromLimits(&nano));
    defer system.deinit();

    const frame = try gpa.create(records.Frame);
    defer gpa.destroy(frame);

    try frame.initInPlace(gpa, &.{
        .paint_record_count_max = 1,
        .hit_record_count_max = 1,
        .handler_count_max = 1,
        .a11y_node_count_max = nano.a11y.element_count_max,
        .announcements = .{
            .polite_pending_max = nano.a11y.announcement_polite_pending_max,
            .message_bytes_max = nano.a11y.announcement_message_bytes_max,
        },
        .text_bytes_max = 2,
        .mesh_point_count_max = 0,
        .params_slot_count_max = 0,
        .params_stride = 0,
    });
    defer frame.deinit(gpa);

    const name = frame.copyText("Go");
    for (0..nano.a11y.element_count_max) |index| {
        frame.appendA11y(.{
            .id = @fromBackingInt(@intCast(index + 1)),
            .role = .button,
            .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .depth = 0,
            .name = name,
            .value = .empty,
            .href = .empty,
            .description = .empty,
            .state = .{},
            .heading_level = .none,
            .live = .off,
            .pos_in_set = null,
            .set_size = null,
            .range = null,
            .selection = null,
        });
    }
    for (0..nano.a11y.announcement_polite_pending_max) |_| {
        frame.announcements.push("Saved", .polite, 1);
    }
    frame.announcements.push("Failed", .assertive, 1);
    try std.testing.expectEqual(frame.a11y.len, frame.a11y_count);

    system.forceEnable();
    var poll: Poll = .{ .last_ns = 0 };
    publish(system, &poll, frame, 0);
    try std.testing.expectEqual(@as(usize, nano.a11y.element_count_max), system.tree.count());
    try std.testing.expectEqual(
        @as(u16, @intCast(nano.a11y.announcement_polite_pending_max + 1)),
        system.tree.announcement_count,
    );
}
