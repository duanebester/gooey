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

const interactive_roles = [_]Role{
    .button,   .checkbox,  .radio,      .switch_,  .link,   .textbox,
    .textarea, .searchbox, .spinbutton, .combobox, .option, .menuitem,
    .tab,      .treeitem,  .slider,
};

const bounds_slop_px: f32 = 0.01;

fn interactive(node: *const records.A11yNode) bool {
    if (node.role == .separator) return node.range != null;
    return std.mem.indexOfScalar(Role, &interactive_roles, node.role) != null;
}

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
    if (inner.width == 0 or inner.height == 0) return true;
    if (inner.x < outer.x - bounds_slop_px) return false;
    if (inner.y < outer.y - bounds_slop_px) return false;
    if (inner.x + inner.width > outer.x + outer.width + bounds_slop_px) return false;
    return inner.y + inner.height <= outer.y + outer.height + bounds_slop_px;
}
