//! Drag & Drop Types
//!
//! Core data structures for drag operations. Single active drag at a time,
//! zero allocation after init (state stored inline in Gooey struct).

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const Point = geometry.Point;

/// Type identifier for drag payloads (comptime-stable address)
pub const DragTypeId = usize;

/// Get unique type ID for drag payload type
/// Uses type name pointer — stable across frames, zero allocation
pub fn dragTypeId(comptime T: type) DragTypeId {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

/// Active drag state (single drag at a time)
pub const DragState = struct {
    /// Type-erased pointer to dragged value (caller ensures lifetime)
    value_ptr: *anyopaque,
    /// Type ID for runtime type checking
    type_id: DragTypeId,
    /// Cursor offset from drag start (for preview positioning)
    cursor_offset: Point(f32),
    /// Current cursor position
    cursor_position: Point(f32),
    /// Starting position (for calculating offset)
    start_position: Point(f32),
    /// Source element's layout ID (for styling source during drag)
    source_layout_id: ?u32,

    const Self = @This();

    /// Type-safe value access — returns null if type mismatch
    pub fn getValue(self: *const Self, comptime T: type) ?*T {
        if (self.type_id != dragTypeId(T)) return null;
        return @ptrCast(@alignCast(self.value_ptr));
    }
};

/// Pending drag (before threshold exceeded)
/// Becomes DragState once cursor moves > DRAG_THRESHOLD pixels
pub const PendingDrag = struct {
    value_ptr: *anyopaque,
    type_id: DragTypeId,
    start_position: Point(f32),
    source_layout_id: ?u32,
};

/// Drag threshold in pixels (matches GPUI)
pub const DRAG_THRESHOLD: f32 = 2.0;

test "dragTypeId uniqueness" {
    const IdA = dragTypeId(u32);
    const IdB = dragTypeId([]const u8);
    const IdA2 = dragTypeId(u32);

    try std.testing.expect(IdA != IdB);
    try std.testing.expectEqual(IdA, IdA2);
}

test "DragState.getValue type safety" {
    const TestItem = struct { id: u32 };
    var item = TestItem{ .id = 42 };

    const drag = DragState{
        .value_ptr = &item,
        .type_id = dragTypeId(TestItem),
        .cursor_offset = .{ .x = 0, .y = 0 },
        .cursor_position = .{ .x = 100, .y = 100 },
        .start_position = .{ .x = 100, .y = 100 },
        .source_layout_id = null,
    };

    // Correct type works
    const retrieved = drag.getValue(TestItem);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 42), retrieved.?.id);

    // Wrong type returns null
    const wrong = drag.getValue(u64);
    try std.testing.expect(wrong == null);
}

test "DRAG_THRESHOLD is reasonable" {
    try std.testing.expect(DRAG_THRESHOLD >= 1.0);
    try std.testing.expect(DRAG_THRESHOLD <= 10.0);
}
