//! The platform events one VOPR action delivers, in order, for the models
//! that route events themselves (splitter, actions). It mirrors
//! `Vopr.deliverPointer`, `deliverGesture`, and `cancelEvent`: a click that
//! releases a held button first sends that button's held move and release;
//! a press reports the pointer before its button; a release reports its
//! held move first.

const std = @import("std");
const gooey = @import("gooey");
const vopr = @import("vopr.zig");

const assert = std.debug.assert;

const input = gooey.input;
const Action = vopr.Action;

/// Most events one action delivers: a click that releases a held button
/// (a held move, the release) and then clicks (a move, a press, a release).
pub const event_count_action_max: u32 = 5;

pub const Point = struct { x: f32, y: f32 };

pub const Press = struct { point: Point, button: input.MouseButton };

pub const Event = union(enum) {
    /// `mouse_moved` or `mouse_dragged`: the models treat them alike.
    moved: Point,
    down: Press,
    up: Press,
    key_down: Action.Chord,
    key_up,
    /// `pointer_cancelled`, or a `focus_lost` that cancelled the gesture.
    pointer_cancelled,
    /// Text, a composition, a wheel step, a resize, or a focus loss with no
    /// gesture: nothing the models route.
    other,
};

pub const Events = struct {
    buffer: [event_count_action_max]Event,
    count: u32,

    fn push(self: *Events, event: Event) void {
        assert(self.count < event_count_action_max);
        self.buffer[self.count] = event;
        self.count += 1;
    }

    pub fn slice(self: *const Events) []const Event {
        assert(self.count <= event_count_action_max);
        return self.buffer[0..self.count];
    }
};

/// The events `action` delivers, in delivery order.
pub fn lower(action: *const Action) Events {
    var events: Events = .{ .buffer = undefined, .count = 0 };
    switch (action.*) {
        .pointer => |pointer| {
            const point: Point = .{ .x = pointer.x, .y = pointer.y };
            const held: Press = .{ .point = point, .button = pointer.button };
            if (pointer.releases_held) {
                assert(pointer.kind == .click);
                events.push(.{ .moved = point });
                events.push(.{ .up = held });
            }
            switch (pointer.kind) {
                .move => events.push(.{ .moved = point }),
                .press => {
                    events.push(.{ .moved = point });
                    events.push(.{ .down = held });
                },
                .release => {
                    events.push(.{ .moved = point });
                    events.push(.{ .up = held });
                },
                .click => {
                    events.push(.{ .moved = point });
                    events.push(.{ .down = held });
                    events.push(.{ .up = held });
                },
            }
        },
        .drag => |gesture| lowerGesture(&events, gesture),
        .key => |chord| {
            events.push(.{ .key_down = chord });
            events.push(.key_up);
        },
        .cancel => |cancel| events.push(switch (cancel.kind) {
            .pointer_cancelled, .focus_lost_with_pointer => .pointer_cancelled,
            // A held key released by the focus loss is a `key_up`, which
            // no model here routes.
            .focus_lost => .other,
        }),
        .text, .compose, .scroll, .resize => events.push(.other),
        .wait_ns, .tick_main, .present => unreachable,
    }
    assert(events.count > 0);
    return events;
}

fn lowerGesture(events: *Events, gesture: Action.Gesture) void {
    const point: Point = .{ .x = gesture.x, .y = gesture.y };
    const held: Press = .{ .point = point, .button = gesture.button };
    switch (gesture.kind) {
        .press => {
            if (gesture.releases_held) {
                events.push(.{ .moved = point });
                events.push(.{ .up = held });
            }
            events.push(.{ .moved = point });
            events.push(.{ .down = held });
        },
        .move => events.push(.{ .moved = point }),
        .release => {
            assert(!gesture.releases_held);
            events.push(.{ .moved = point });
            events.push(.{ .up = held });
        },
    }
}
