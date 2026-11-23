const std = @import("std");
const gooey = @import("gooey");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const Window = internals.window.Window;
const ElementId = records.ElementId;

pub fn hitIndex(frame: *const records.Frame, x: f32, y: f32) ?u32 {
    assert(frame.hit_count <= frame.hits.len);
    assert(frame.modal_hit_start <= frame.hit_count);
    var index = frame.hit_count;
    while (index > frame.modal_hit_start) {
        index -= 1;
        const record = &frame.hits[index];
        if (record.pointer and record.bounds.contains(x, y)) return index;
    }
    return null;
}

pub fn onScrollbar(window: *Window, x: f32, y: f32) bool {
    const frame = drainFrame(window);
    assert(frame.hit_count <= frame.hits.len);
    var index = hitIndex(frame, x, y) orelse return false;
    var depth: u32 = 0;
    while (index != records.index_none) : (depth += 1) {
        assert(depth <= frame.hit_count);
        const record = &frame.hits[index];
        if (record.scroll) {
            const scroll = internals.window.ScrollState;
            if (window.retained.findConst(scroll, record.id)) |state| {
                if (state.scrollbarAt(x, y) != null) return true;
            }
        }
        index = record.parent;
    }
    return false;
}

fn drainFrame(window: *Window) *const records.Frame {
    assert(window.phase == .idle);
    const flips = window.awaiting_flip and !window.frame_in_flight.load(.acquire);
    const frame: *const records.Frame = if (flips) window.built() else window.rendered();
    assert(frame.hit_count <= frame.hits.len);
    return frame;
}

pub fn nextTabStop(frame: *const records.Frame, focus: ElementId, backward: bool) ElementId {
    assert(frame.modal_hit_start <= frame.hit_count);
    const start = frame.modal_hit_start;
    const count = frame.hit_count - start;
    if (count == 0) return focus;
    const current = findHit(frame, focus);
    var index: u32 = if (current) |found| found - start else if (backward) count else count - 1;
    var step: u32 = 0;
    while (step < count) : (step += 1) {
        index = if (backward) (index + count - 1) % count else (index + 1) % count;
        if (frame.hits[start + index].tab_stop) return frame.hits[start + index].id;
    }
    return focus;
}

pub fn findHit(frame: *const records.Frame, id: ElementId) ?u32 {
    assert(frame.hit_count <= frame.hits.len);
    if (id == .root) return null;
    for (frame.hits[0..frame.hit_count], 0..) |*record, index| {
        if (record.id == id) return @intCast(index);
    }
    return null;
}

pub fn findA11y(frame: *const records.Frame, id: ElementId) ?*const records.A11yNode {
    assert(frame.a11y_count <= frame.a11y.len);
    if (id == .root) return null;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.id == id) return node;
    }
    return null;
}
