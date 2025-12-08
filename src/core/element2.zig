//! Element trait and AnyElement - the core of the UI system
//!
//! Elements are the building blocks of the UI. They have three phases:
//! 1. request_layout() - Request layout from the layout engine
//! 2. prepaint() - Compute hitboxes, register event handlers
//! 3. paint() - Draw to the scene
//!
//! This is modeled after GPUI's Element trait.

const std = @import("std");
const types = @import("element_types.zig");
const style_mod = @import("style.zig");

pub const Bounds = types.Bounds;
pub const Size = types.Size;
pub const Point = types.Point;
pub const Pixels = types.Pixels;
pub const ElementId = types.ElementId;
pub const GlobalElementId = types.GlobalElementId;
pub const LayoutNodeId = types.LayoutNodeId;
pub const Style = style_mod.Style;
pub const Hsla = style_mod.Hsla;

// Forward declarations for contexts
pub const WindowContext = @import("window_context.zig").WindowContext;

// =============================================================================
// Element Interface
// =============================================================================

/// Check if type T implements the Element interface.
///
/// Required:
///   - RequestLayoutState: type (can be void)
///   - PrepaintState: type (can be void)
///   - fn id(*T) ?ElementId
///   - fn request_layout(*T, *WindowContext) struct { LayoutNodeId, RequestLayoutState }
///   - fn prepaint(*T, Bounds, *RequestLayoutState, *WindowContext) PrepaintState
///   - fn paint(*T, Bounds, *RequestLayoutState, *PrepaintState, *WindowContext) void
pub fn isElement(comptime T: type) bool {
    const has_request_layout = @hasDecl(T, "request_layout");
    const has_prepaint = @hasDecl(T, "prepaint");
    const has_paint = @hasDecl(T, "paint");
    return has_request_layout and has_prepaint and has_paint;
}

// =============================================================================
// AnyElement - Type-erased element
// =============================================================================

/// Type-erased element for heterogeneous element trees.
///
/// AnyElement wraps any concrete element type and provides a uniform
/// interface for the rendering pipeline.
pub const AnyElement = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    pub const VTable = struct {
        getId: *const fn (*anyopaque) ?ElementId,
        requestLayout: *const fn (*anyopaque, *WindowContext) LayoutResult,
        doPrepaint: *const fn (*anyopaque, Bounds, *WindowContext) void,
        doPaint: *const fn (*anyopaque, Bounds, *WindowContext) void,
        doDeinit: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub const LayoutResult = struct {
        layout_id: LayoutNodeId,
        /// Opaque pointer to state - stored by the caller
        state_ptr: ?*anyopaque = null,
    };

    /// Create AnyElement from a concrete element type
    pub fn init(comptime T: type, ptr: *T) Self {
        comptime {
            if (!isElement(T)) {
                @compileError("Type " ++ @typeName(T) ++ " does not implement Element interface");
            }
        }

        const gen = struct {
            fn getId(p: *anyopaque) ?ElementId {
                const self: *T = @ptrCast(@alignCast(p));
                if (@hasDecl(T, "id")) {
                    return self.id();
                }
                return null;
            }

            fn requestLayout(p: *anyopaque, cx: *WindowContext) LayoutResult {
                const self: *T = @ptrCast(@alignCast(p));
                const result = self.request_layout(cx);
                return .{ .layout_id = result[0] };
            }

            fn doPrepaint(p: *anyopaque, bounds: Bounds, cx: *WindowContext) void {
                const self: *T = @ptrCast(@alignCast(p));
                var state: T.RequestLayoutState = undefined;
                _ = self.prepaint(bounds, &state, cx);
            }

            fn doPaint(p: *anyopaque, bounds: Bounds, cx: *WindowContext) void {
                const self: *T = @ptrCast(@alignCast(p));
                var layout_state: T.RequestLayoutState = undefined;
                var prepaint_state: T.PrepaintState = undefined;
                self.paint(bounds, &layout_state, &prepaint_state, cx);
            }

            fn doDeinit(p: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *T = @ptrCast(@alignCast(p));
                if (@hasDecl(T, "deinit")) {
                    self.deinit();
                }
                allocator.destroy(self);
            }

            const vtable = VTable{
                .getId = getId,
                .requestLayout = requestLayout,
                .doPrepaint = doPrepaint,
                .doPaint = doPaint,
                .doDeinit = doDeinit,
            };
        };

        return .{
            .ptr = ptr,
            .vtable = &gen.vtable,
        };
    }

    /// Allocate and wrap an element
    pub fn create(comptime T: type, allocator: std.mem.Allocator, value: T) !Self {
        const ptr = try allocator.create(T);
        ptr.* = value;
        return Self.init(T, ptr);
    }

    pub fn id(self: Self) ?ElementId {
        return self.vtable.getId(self.ptr);
    }

    pub fn request_layout(self: Self, cx: *WindowContext) LayoutResult {
        return self.vtable.requestLayout(self.ptr, cx);
    }

    pub fn prepaint(self: Self, bounds: Bounds, cx: *WindowContext) void {
        self.vtable.doPrepaint(self.ptr, bounds, cx);
    }

    pub fn paint(self: Self, bounds: Bounds, cx: *WindowContext) void {
        self.vtable.doPaint(self.ptr, bounds, cx);
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        self.vtable.doDeinit(self.ptr, allocator);
    }
};

// =============================================================================
// IntoElement - Convert types to elements
// =============================================================================

/// Trait for types that can be converted into an element
pub fn IntoElement(comptime T: type) bool {
    if (T == AnyElement) return true;
    if (isElement(T)) return true;
    // Strings become Text elements
    if (T == []const u8 or T == [:0]const u8) return true;
    return false;
}

// =============================================================================
// Component - Higher-level abstraction over Element
// =============================================================================

/// Component wraps a render function that produces elements.
/// This is similar to functional components in React.
pub fn Component(comptime State: type) type {
    return struct {
        state: State,
        render_fn: *const fn (*State, *WindowContext) AnyElement,

        const Self = @This();

        // Element interface implementation
        pub const RequestLayoutState = LayoutNodeId;
        pub const PrepaintState = void;

        pub fn id(_: *Self) ?ElementId {
            return null;
        }

        pub fn request_layout(self: *Self, cx: *WindowContext) struct { LayoutNodeId, RequestLayoutState } {
            const child = self.render_fn(&self.state, cx);
            const result = child.request_layout(cx);
            return .{ result.layout_id, result.layout_id };
        }

        pub fn prepaint(self: *Self, bounds: Bounds, _: *RequestLayoutState, cx: *WindowContext) PrepaintState {
            const child = self.render_fn(&self.state, cx);
            child.prepaint(bounds, cx);
        }

        pub fn paint(self: *Self, bounds: Bounds, _: *RequestLayoutState, _: *PrepaintState, cx: *WindowContext) void {
            const child = self.render_fn(&self.state, cx);
            child.paint(bounds, cx);
        }
    };
}

// =============================================================================
// Empty Element
// =============================================================================

pub const Empty = struct {
    pub const RequestLayoutState = void;
    pub const PrepaintState = void;

    pub fn id(_: *Empty) ?ElementId {
        return null;
    }

    pub fn request_layout(_: *Empty, cx: *WindowContext) struct { LayoutNodeId, void } {
        const layout_id = cx.request_layout(Style{}, &.{});
        return .{ layout_id, {} };
    }

    pub fn prepaint(_: *Empty, _: Bounds, _: *void, _: *WindowContext) void {}

    pub fn paint(_: *Empty, _: Bounds, _: *void, _: *void, _: *WindowContext) void {}
};

pub fn empty() Empty {
    return .{};
}

// =============================================================================
// Tests
// =============================================================================

test "isElement check" {
    const Valid = struct {
        pub const RequestLayoutState = void;
        pub const PrepaintState = void;

        pub fn id(_: *@This()) ?ElementId {
            return null;
        }

        pub fn request_layout(_: *@This(), _: *WindowContext) struct { LayoutNodeId, void } {
            return .{ LayoutNodeId.invalid, {} };
        }

        pub fn prepaint(_: *@This(), _: Bounds, _: *void, _: *WindowContext) void {}

        pub fn paint(_: *@This(), _: Bounds, _: *void, _: *void, _: *WindowContext) void {}
    };

    const Invalid = struct {
        value: i32,
    };

    try std.testing.expect(isElement(Valid));
    try std.testing.expect(!isElement(Invalid));
}

test "Empty element" {
    const e = empty();
    try std.testing.expect(e.id() == null);
}
