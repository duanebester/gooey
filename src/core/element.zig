//! Element trait and ElementId for the gooey UI framework
//!
//! Elements are the building blocks of the UI. Every interactive component
//! (buttons, text inputs, lists, etc.) implements the Element interface.

const std = @import("std");
const geometry = @import("geometry.zig");
const event = @import("event.zig");

/// Unique identifier for an element in the view tree
pub const ElementId = struct {
    value: u64,

    const Self = @This();

    var next_id: u64 = 1;

    pub fn generate() Self {
        const id = next_id;
        next_id += 1;
        return .{ .value = id };
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.value == other.value;
    }

    pub const none = Self{ .value = 0 };
};

/// Bounding rectangle for hit testing
pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn init(x: f32, y: f32, width: f32, height: f32) Bounds {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn contains(self: Bounds, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }

    pub const zero = Bounds{ .x = 0, .y = 0, .width = 0, .height = 0 };
};

/// Result of handling an event
pub const EventResult = enum {
    /// Event was not handled, continue propagation
    ignored,
    /// Event was handled, but allow propagation to continue
    handled,
    /// Event was handled, stop all propagation
    stop,
};

/// Type-erased Element interface
pub const Element = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    pub const VTable = struct {
        handleEvent: *const fn (ptr: *anyopaque, ev: *event.Event) EventResult,
        getBounds: *const fn (ptr: *anyopaque) Bounds,
        getId: *const fn (ptr: *anyopaque) ElementId,
        canFocus: *const fn (ptr: *anyopaque) bool,
        onFocus: *const fn (ptr: *anyopaque) void,
        onBlur: *const fn (ptr: *anyopaque) void,
    };

    pub fn handleEvent(self: Self, ev: *event.Event) EventResult {
        return self.vtable.handleEvent(self.ptr, ev);
    }

    pub fn getBounds(self: Self) Bounds {
        return self.vtable.getBounds(self.ptr);
    }

    pub fn getId(self: Self) ElementId {
        return self.vtable.getId(self.ptr);
    }

    pub fn canFocus(self: Self) bool {
        return self.vtable.canFocus(self.ptr);
    }

    pub fn onFocus(self: Self) void {
        self.vtable.onFocus(self.ptr);
    }

    pub fn onBlur(self: Self) void {
        self.vtable.onBlur(self.ptr);
    }
};

/// Helper to create an Element from a concrete type
pub fn asElement(comptime T: type, ptr: *T) Element {
    const gen = struct {
        fn handleEvent(p: *anyopaque, ev: *event.Event) EventResult {
            const self: *T = @ptrCast(@alignCast(p));
            return self.handleEvent(ev);
        }
        fn getBounds(p: *anyopaque) Bounds {
            const self: *T = @ptrCast(@alignCast(p));
            return self.getBounds();
        }
        fn getId(p: *anyopaque) ElementId {
            const self: *T = @ptrCast(@alignCast(p));
            return self.getId();
        }
        fn canFocus(p: *anyopaque) bool {
            const self: *T = @ptrCast(@alignCast(p));
            return self.canFocus();
        }
        fn onFocus(p: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(p));
            self.onFocus();
        }
        fn onBlur(p: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(p));
            self.onBlur();
        }
        const vtable = Element.VTable{
            .handleEvent = handleEvent,
            .getBounds = getBounds,
            .getId = getId,
            .canFocus = canFocus,
            .onFocus = onFocus,
            .onBlur = onBlur,
        };
    };
    return .{ .ptr = ptr, .vtable = &gen.vtable };
}
