//! Screen-reader publishing: the rendered frame's accessibility nodes and
//! announcements, handed to the platform bridge (VoiceOver, AT-SPI2, ARIA)
//! through the 0.3.1 accessibility tree, which diffs frames and keeps the
//! bridges' identities stable.
//!
//! Runs on the main thread each time a frame becomes `rendered`, so the
//! nodes' strings, which live in that frame, outlive the sync. Whether a
//! screen reader runs is asked at most once per `poll_interval_ns` of the
//! window's clock, and on the first frame: the core renders only on change,
//! so a poll counted in frames could wait arbitrarily long. When none runs,
//! that poll is the whole cost.
//!
//! Performance sketch: one pass over at most `a11y.element_count_max` nodes
//! (512 at `small`, 2,048 at `standard`) into a tree reserved at the same
//! count, then the bridge's diff, only while a screen reader is running.

const std = @import("std");
const records = @import("records.zig");
const A11ySystem = @import("a11y_system.zig").A11ySystem;
const a11y = @import("../accessibility/accessibility.zig");

const assert = std.debug.assert;

/// How often a rendered frame re-asks the bridge whether a screen reader
/// runs: 0.3.1's 60 frames at 60 Hz.
pub const poll_interval_ns: u64 = std.time.ns_per_s;

/// When the bridge was last polled, on the window's clock; null before the
/// first frame.
pub const Poll = struct { last_ns: ?u64 = null };

/// Publish `frame` to `system`'s bridge. The frame's node pool and the tree
/// are both sized by `ResourceLimits.a11y.element_count_max`, and node depth
/// by `build.box_depth_max`, so every node fits; emit fails fast before.
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
    // The focused text field's selection is the frame's IME answer, so the
    // bridge can report caret moves without a second accessibility field.
    if (frame.ime) |ime| {
        if (ime.owner == node.id) {
            assert(ime.selected_start <= ime.selected_end);
            assert(ime.selected_end <= node.value.len);
            element.selection = .{ .start = ime.selected_start, .end = ime.selected_end };
        }
    }
    assert(element.role == node.role);
}

test "the bridge is polled on the first frame and then once per interval" {
    // Goal: an app that renders rarely still notices a screen reader on its
    // next frame. Methodology: publish at clock times around the interval
    // and read when the poll last ran; frames in between do not poll.
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
        .announcements = .{ .count_max = 1, .bytes_max = 1 },
        .text_bytes_max = 1,
        .mesh_point_count_max = 0,
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
    // Goal: the frame's pools and the tree share `ResourceLimits.a11y`, so a
    // frame filled exactly fits the tree exactly. Methodology: fill a frame
    // sized from `nano` with 128 sibling nodes and 4 announcements, publish
    // it to a tree sized from `nano`, and count both sides. One more node or
    // announcement fails fast in the frame (`core-a11y-*` fail-fast checks).
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
            .count_max = nano.a11y.announcement_count_frame_max,
            .bytes_max = nano.a11y.announcement_bytes_frame_max,
        },
        .text_bytes_max = 2,
        .mesh_point_count_max = 0,
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
        });
    }
    for (0..nano.a11y.announcement_count_frame_max) |_| {
        frame.announcements.push("Saved", .polite, 1);
    }
    try std.testing.expectEqual(frame.a11y.len, frame.a11y_count);

    system.forceEnable();
    var poll: Poll = .{ .last_ns = 0 };
    publish(system, &poll, frame, 0);
    try std.testing.expectEqual(@as(usize, nano.a11y.element_count_max), system.tree.count());
    try std.testing.expectEqual(
        @as(u16, @intCast(nano.a11y.announcement_count_frame_max)),
        system.tree.announcement_count,
    );
}
