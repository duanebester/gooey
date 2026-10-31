//! Screen-reader publishing: the rendered frame's accessibility nodes and
//! announcements, handed to the platform bridge (VoiceOver, AT-SPI2, ARIA)
//! through the 0.3.1 accessibility tree, which diffs frames and keeps the
//! bridges' identities stable.
//!
//! Runs on the main thread each time a frame becomes `rendered`, so the
//! nodes' strings, which live in that frame, outlive the sync. When no
//! screen reader is active the cost is the bridge's periodic poll.
//!
//! Performance sketch: one pass over at most `a11y_node_count_max` nodes
//! (2,048 at `.small`) into the tree's fixed 2,048 elements, then the
//! bridge's diff, only while a screen reader is running.

const std = @import("std");
const records = @import("records.zig");
const A11ySystem = @import("../context/a11y_system.zig").A11ySystem;
const a11y = @import("../accessibility/accessibility.zig");

const assert = std.debug.assert;

/// Publish `frame` to `system`'s bridge. A frame deeper or larger than the
/// tree is a capacity error and fails fast.
pub fn publish(system: *A11ySystem, frame: *const records.Frame) void {
    assert(frame.a11y_count <= frame.a11y.len);
    system.beginFrame();
    if (!system.isEnabled()) return;
    const tree = system.getTree();
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
        .state = node.state,
        .live = node.live,
        .heading_level = node.heading_level,
    }) orelse std.debug.panic("accessibility tree full: capacity {d} elements, depth {d}; " ++
        "frame {d} has {d} nodes", .{
        a11y.constants.MAX_ELEMENTS,
        a11y.constants.MAX_DEPTH,
        frame.frame_number,
        frame.a11y_count,
    });
    const element = tree.getElementMut(index).?;
    element.bounds = .{
        .x = node.bounds.x,
        .y = node.bounds.y,
        .width = node.bounds.width,
        .height = node.bounds.height,
    };
    assert(element.role == node.role);
}
