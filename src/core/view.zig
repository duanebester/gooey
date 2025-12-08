//! View system for element management and event dispatch
//!
//! Uses a flat list of elements with hitboxes, similar to GPUI.
//! Elements are hit-tested in reverse order (last added = topmost).

const std = @import("std");
const element = @import("element.zig");
const event = @import("event.zig");
const input = @import("input.zig");

const Element = element.Element;
const ElementId = element.ElementId;
const Bounds = element.Bounds;
const EventResult = element.EventResult;
const Event = event.Event;
const EventPhase = event.EventPhase;

/// Manages elements and event dispatch
pub const ViewTree = struct {
    allocator: std.mem.Allocator,
    /// Flat list of elements (paint order: first = back, last = front)
    elements: std.ArrayList(Element),
    focused_id: ElementId = ElementId.none,
    hovered_id: ElementId = ElementId.none,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .elements = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.elements.deinit(self.allocator);
    }

    /// Add an element to the view (will be rendered on top)
    pub fn addElement(self: *Self, elem: Element) !void {
        try self.elements.append(self.allocator, elem);
    }

    /// Clear all elements
    pub fn clear(self: *Self) void {
        self.elements.clearRetainingCapacity();
    }

    /// Hit test - find element at point (reverse order = topmost first)
    pub fn hitTest(self: *Self, x: f32, y: f32) ?Element {
        var i = self.elements.items.len;
        while (i > 0) {
            i -= 1;
            const elem = self.elements.items[i];
            if (elem.getBounds().contains(x, y)) {
                return elem;
            }
        }
        return null;
    }

    /// Focus an element by ID
    pub fn focus(self: *Self, id: ElementId) void {
        if (self.focused_id.eql(id)) return;

        // Blur old focus
        if (!self.focused_id.eql(ElementId.none)) {
            for (self.elements.items) |elem| {
                if (elem.getId().eql(self.focused_id)) {
                    elem.onBlur();
                    break;
                }
            }
        }

        self.focused_id = id;

        // Focus new element
        if (!id.eql(ElementId.none)) {
            for (self.elements.items) |elem| {
                if (elem.getId().eql(id)) {
                    elem.onFocus();
                    break;
                }
            }
        }
    }

    /// Clear focus
    pub fn blur(self: *Self) void {
        self.focus(ElementId.none);
    }

    /// Find element by ID
    pub fn findElement(self: *Self, id: ElementId) ?Element {
        for (self.elements.items) |elem| {
            if (elem.getId().eql(id)) {
                return elem;
            }
        }
        return null;
    }

    /// Dispatch an input event
    pub fn dispatchEvent(self: *Self, input_event: input.InputEvent) bool {
        var target: ?Element = null;
        var target_id = self.focused_id;

        // For mouse events, hit test to find target
        switch (input_event) {
            .mouse_down => |m| {
                const x: f32 = @floatCast(m.position.x);
                const y: f32 = @floatCast(m.position.y);
                if (self.hitTest(x, y)) |elem| {
                    target = elem;
                    target_id = elem.getId();
                    // Auto-focus on click
                    if (elem.canFocus()) {
                        self.focus(target_id);
                    }
                } else {
                    // Clicked outside - blur
                    self.blur();
                    return false;
                }
            },
            .mouse_up, .mouse_moved, .mouse_dragged => |m| {
                const x: f32 = @floatCast(m.position.x);
                const y: f32 = @floatCast(m.position.y);
                target = self.hitTest(x, y);
                if (target) |t| {
                    target_id = t.getId();
                }
            },
            else => {
                // Keyboard events go to focused element
                if (!self.focused_id.eql(ElementId.none)) {
                    target = self.findElement(self.focused_id);
                }
            },
        }

        // Dispatch to target
        if (target) |t| {
            var ev = Event.init(input_event, target_id);
            ev.phase = .target;
            ev.current_target = target_id;
            const result = t.handleEvent(&ev);
            return result == .handled or result == .stop or ev.default_prevented;
        }

        return false;
    }
};
