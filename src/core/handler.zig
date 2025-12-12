//! Handler - Type-erased event handler with context
//!
//! HandlerRef allows event callbacks to access application state and context
//! without requiring global variables. This is the key abstraction that enables
//! component-local state handling.
//!
//! ## Usage
//!
//! ```zig
//! const AppState = struct {
//!     count: i32 = 0,
//!
//!     pub fn increment(self: *AppState, cx: *Context(AppState)) void {
//!         self.count += 1;
//!         cx.notify();
//!     }
//! };
//!
//! fn render(cx: *Context(AppState)) void {
//!     cx.box(.{}, .{
//!         ui.buttonHandler("+ Increment", cx.handler(AppState.increment)),
//!     });
//! }
//! ```
//! Handler - Type-erased event handler with context
//!
//! HandlerRef allows event callbacks to access application state and context
//! without requiring global variables.

const std = @import("std");
const Gooey = @import("gooey.zig").Gooey;
const entity_mod = @import("entity.zig");
pub const EntityId = entity_mod.EntityId;

/// Type-erased handler reference that can be stored and invoked later.
///
/// The callback receives a `*Gooey` pointer and optional entity ID.
pub const HandlerRef = struct {
    /// The actual callback function (receives Gooey and entity ID)
    callback: *const fn (*Gooey, EntityId) void,

    /// Entity ID this handler operates on (invalid = use root state)
    entity_id: EntityId = EntityId.invalid,

    /// Invoke this handler
    pub fn invoke(self: HandlerRef, gooey: *Gooey) void {
        self.callback(gooey, self.entity_id);
    }
};

/// Storage for the root view's state pointer (for non-entity handlers).
pub threadlocal var root_state_ptr: ?*anyopaque = null;
pub threadlocal var root_state_type_id: usize = 0;

/// Get the type ID for a given type
pub fn typeId(comptime T: type) usize {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

/// Store the root state pointer for handler callbacks
pub fn setRootState(comptime State: type, state_ptr: *State) void {
    root_state_ptr = @ptrCast(state_ptr);
    root_state_type_id = typeId(State);
}

/// Clear the root state pointer
pub fn clearRootState() void {
    root_state_ptr = null;
    root_state_type_id = 0;
}

/// Get the root state pointer with type checking
pub fn getRootState(comptime State: type) ?*State {
    if (root_state_ptr) |ptr| {
        if (root_state_type_id == typeId(State)) {
            return @ptrCast(@alignCast(ptr));
        }
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "HandlerRef basic usage" {
    const TestState = struct {
        value: i32 = 0,
    };

    var state = TestState{ .value = 42 };
    setRootState(TestState, &state);
    defer clearRootState();

    const retrieved = getRootState(TestState);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i32, 42), retrieved.?.value);
}

test "getRootState type mismatch returns null" {
    const StateA = struct { a: i32 = 1 };
    const StateB = struct { b: i32 = 2 };

    var state_a = StateA{};
    setRootState(StateA, &state_a);
    defer clearRootState();

    const wrong_type = getRootState(StateB);
    try std.testing.expect(wrong_type == null);

    const right_type = getRootState(StateA);
    try std.testing.expect(right_type != null);
}
