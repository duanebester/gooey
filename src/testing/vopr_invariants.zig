//! Invariants the VOPR checks for every app, with no app model: they state
//! what the core's emit and focus rules promise about any rendered frame.
//!
//! - A11y and hits agree (`checkFrame`, after every flip). Emit writes both
//!   from the same node (`emit.zig`: `emitA11y` from the laid-out bounds,
//!   `emitHit` from the same bounds clipped to the enclosing clips), so:
//!   1. every accessibility node with an interactive role
//!      (`interactive_roles`) has a hit record with its id, and that
//!      record's bounds lie within the node's (equal unless a clip or a
//!      scroll box cut them);
//!   2. every hit record with a click or key handler (`on_click`, `on_key`)
//!      has an accessibility node with its id and an interactive role.
//!   A separator with a range (a splitter) is interactive; one without is
//!   not. A handled record with no node of its own passes rule 2 when the
//!   nearest ancestor record with a node is interactive: it is part of that
//!   control, as a Select's trigger box is of its combobox, whose node
//!   speaks for it.
//!   Exceptions: nodes in the drag layer have hits but no accessibility
//!   nodes (`emitAccessibility` skips the `.drag` layer), so a record whose
//!   chain of parents includes a drag-layer root is left out of rule 2;
//!   there is no drag-layer flag in a record, so a record is left out when
//!   the window's drag is active and its fragment is the last one.
//! - Focus is live (`checkFocusLive`, whenever the rendered frame is
//!   current): with nothing in flight or awaiting a flip and no render
//!   requested, the focused id is `.root` or a record of the rendered frame
//!   that takes focus (focusable, or the keyboard drag's drop target) at or
//!   after the modal's first record. That is `router.validateFocus`'s
//!   postcondition on the frame it built, which is now the rendered one; a
//!   handler that moves focus after that build also requests a render.

const std = @import("std");
const gooey = @import("gooey");
const vopr_frame = @import("vopr_frame.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const Window = internals.window.Window;
const Role = @TypeOf(@as(records.A11yNode, undefined).role);
const index_none = records.index_none;
const findHit = vopr_frame.findHit;
const findA11y = vopr_frame.findA11y;

/// Roles a person operates: activated, toggled, edited, or chosen. A
/// `listbox`, `menu`, or `tablist` groups operable children and a
/// `scrollbar` or `slider` names a range; only `slider` is in, since a
/// slider takes keys itself.
const interactive_roles = [_]Role{
    .button,   .checkbox,  .radio,      .switch_,  .link,   .textbox,
    .textarea, .searchbox, .spinbutton, .combobox, .option, .menuitem,
    .tab,      .treeitem,  .slider,
};

/// Bounds may differ by this much from float rounding in a clip.
const bounds_slop_px: f32 = 0.01;

/// A separator with a range is a window splitter, which WAI-ARIA counts as
/// a widget: a person focuses it and moves it with keys (splitter example).
/// A separator without one is a static divider.
fn interactive(node: *const records.A11yNode) bool {
    if (node.role == .separator) return node.range != null;
    return std.mem.indexOfScalar(Role, &interactive_roles, node.role) != null;
}

/// Both directions of the a11y–hit agreement on `frame`.
pub fn checkFrame(window: *const Window, frame: *const records.Frame) void {
    assert(frame.hit_count <= frame.hits.len);
    assert(frame.a11y_count <= frame.a11y.len);
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (!interactive(node)) continue;
        const index = findHit(frame, node.id) orelse std.debug.panic(
            "vopr: frame {d}: the {t} node {x} has no hit record",
            .{ frame.frame_number, node.role, @backingInt(node.id) },
        );
        const hit = frame.hits[index].bounds;
        if (!within(hit, node.bounds)) {
            std.debug.panic("vopr: frame {d}: the {t} node {x} has bounds {any}, but its " ++
                "hit record {any} lies outside them", .{
                frame.frame_number, node.role, @backingInt(node.id), node.bounds, hit,
            });
        }
    }
    const drag_fragment = dragFragment(window, frame);
    for (frame.hits[0..frame.hit_count]) |*record| {
        const handled = record.on_click != index_none or record.on_key != index_none;
        if (!handled) continue;
        if (drag_fragment) |fragment| {
            if (record.fragment == fragment) continue;
        }
        const node = findA11y(frame, record.id) orelse ownerNode(frame, record) orelse
            std.debug.panic(
                "vopr: frame {d}: hit record {x} has a {s} handler but no accessibility node",
                .{ frame.frame_number, @backingInt(record.id), handlerName(record) },
            );
        if (!interactive(node)) {
            std.debug.panic("vopr: frame {d}: hit record {x} has a {s} handler, but its " ++
                "accessibility node's role {t} is not interactive", .{
                frame.frame_number, @backingInt(record.id), handlerName(record), node.role,
            });
        }
    }
}

/// For a handled record with no node of its own: the node of its nearest
/// ancestor record that has one, when that node is interactive, as a
/// Select's trigger box is part of its combobox. Null otherwise.
fn ownerNode(
    frame: *const records.Frame,
    record: *const records.HitRecord,
) ?*const records.A11yNode {
    var index = record.parent;
    var depth: u32 = 0;
    while (index != index_none) : (depth += 1) {
        assert(depth < frame.hit_count);
        const ancestor = &frame.hits[index];
        if (findA11y(frame, ancestor.id)) |node| return if (interactive(node)) node else null;
        index = ancestor.parent;
    }
    return null;
}

/// The fragment the drag preview is in, when a drag shows one: the last.
fn dragFragment(window: *const Window, frame: *const records.Frame) ?u8 {
    if (window.drag.phase != .active) return null;
    var fragment_last: u8 = 0;
    for (frame.hits[0..frame.hit_count]) |*record| {
        fragment_last = @max(fragment_last, record.fragment);
    }
    return fragment_last;
}

fn handlerName(record: *const records.HitRecord) []const u8 {
    return if (record.on_click != index_none) "click" else "key";
}

/// The focused id is `.root` or a record of the rendered frame that takes
/// focus, whenever that frame is current.
pub fn checkFocusLive(window: *Window) void {
    assert(window.phase == .idle);
    if (window.frame_in_flight.load(.acquire)) return;
    if (window.awaiting_flip or window.render_requested) return;
    if (window.focus == .root) return;
    const frame = window.rendered();
    const index = findHit(frame, window.focus) orelse std.debug.panic(
        "vopr: frame {d}: focus {x} is not in the rendered frame",
        .{ frame.frame_number, @backingInt(window.focus) },
    );
    const record = &frame.hits[index];
    const takes_focus = record.focusable or window.isKeyboardDropTarget(record.id);
    if (!takes_focus or index < frame.modal_hit_start) {
        std.debug.panic("vopr: frame {d}: focus {x} is on record {d}, which takes focus " ++
            "{}, under a modal starting at {d}", .{
            frame.frame_number,    @backingInt(window.focus), index, takes_focus,
            frame.modal_hit_start,
        });
    }
}

/// Print the first line where two frame dumps differ, with its neighbours.
pub fn reportDumpDifference(expected: []const u8, actual: []const u8) void {
    var line_start: usize = 0;
    var line_number: u32 = 1;
    const shorter = @min(expected.len, actual.len);
    var index: usize = 0;
    while (index < shorter and expected[index] == actual[index]) : (index += 1) {
        if (expected[index] == '\n') {
            line_start = index + 1;
            line_number += 1;
        }
    }
    std.debug.print("vopr: dumps differ at line {d}:\n  rendered: {s}\n  rebuilt:  {s}\n", .{
        line_number,
        lineAt(expected, line_start),
        lineAt(actual, line_start),
    });
}

fn lineAt(bytes: []const u8, start: usize) []const u8 {
    if (start >= bytes.len) return "(end)";
    const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
    return bytes[start..end];
}

fn within(inner: records.Rect, outer: records.Rect) bool {
    assert(inner.width >= 0);
    assert(outer.width >= 0);
    // A record clipped to nothing (scrolled out of view) has no extent.
    if (inner.width == 0 or inner.height == 0) return true;
    if (inner.x < outer.x - bounds_slop_px) return false;
    if (inner.y < outer.y - bounds_slop_px) return false;
    if (inner.x + inner.width > outer.x + outer.width + bounds_slop_px) return false;
    return inner.y + inner.height <= outer.y + outer.height + bounds_slop_px;
}
