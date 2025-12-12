//! Context - Typed application context for stateful UI
//!
//! Context wraps the UI system and user-defined application state,
//! providing a clean API for accessing state and triggering re-renders.
//!
//! ## Design Philosophy
//!
//! Context enables "Level 2" apps that need typed state without the
//! complexity of a full entity system. It provides:
//! - Type-safe access to user-defined state
//! - Automatic re-render triggering via `notify()`
//! - Access to allocator and window operations
//!
//! ## Pure State Pattern (Recommended)
//!
//! Keep state pure (no UI knowledge) and use `update()` for mutations:
//!
//! ```zig
//! // State is pure - no cx, no notify, just data + logic
//! const AppState = struct {
//!     count: i32 = 0,
//!
//!     pub fn increment(self: *AppState) void {
//!         self.count += 1;
//!     }
//!
//!     pub fn decrement(self: *AppState) void {
//!         self.count -= 1;
//!     }
//! };
//!
//! fn render(cx: *gooey.Context(AppState)) void {
//!     cx.vstack(.{}, .{
//!         gooey.ui.textFmt("{d}", .{cx.state().count}, .{}),
//!         // cx.update() calls the method, then auto-notifies
//!         gooey.ui.buttonHandler("+", cx.update(AppState.increment)),
//!         gooey.ui.buttonHandler("-", cx.update(AppState.decrement)),
//!     });
//! }
//!
//! // Testing state is easy - no mocking cx!
//! test "increment works" {
//!     var state = AppState{};
//!     state.increment();
//!     try std.testing.expectEqual(1, state.count);
//! }
//! ```
//!
//! ## With Arguments
//!
//! For methods that need arguments (e.g., item index), use `updateWith()`:
//!
//! ```zig
//! const AppState = struct {
//!     counters: [10]i32 = [_]i32{0} ** 10,
//!
//!     pub fn incrementAt(self: *AppState, index: usize) void {
//!         self.counters[index] += 1;
//!     }
//! };
//!
//! fn render(cx: *gooey.Context(AppState)) void {
//!     for (0..10) |i| {
//!         gooey.ui.buttonHandler("+", cx.updateWith(i, AppState.incrementAt)),
//!     }
//! }
//! ```
//!
//! ## Legacy Pattern (Still Supported)
//!
//! Methods that need context access (e.g., for focus control) use `handler()`:
//!
//! ```zig
//! const AppState = struct {
//!     pub fn submit(self: *AppState, cx: *Context(AppState)) void {
//!         // Do something with state
//!         self.submitted = true;
//!         // Need context for UI operations
//!         cx.blurAll();
//!         cx.notify();
//!     }
//! };
//!
//! fn render(cx: *gooey.Context(AppState)) void {
//!     gooey.ui.buttonHandler("Submit", cx.handler(AppState.submit)),
//! }
//! ```

const std = @import("std");

// Forward declarations for dependencies
const Gooey = @import("gooey.zig").Gooey;
const ui_mod = @import("../ui/ui.zig");
const Builder = ui_mod.Builder;
// Handler support
const handler_mod = @import("handler.zig");
pub const HandlerRef = handler_mod.HandlerRef;
pub const EntityId = handler_mod.EntityId;

/// Context wraps UI + user state, providing typed access to application state
/// and convenience methods for UI operations.
///
/// The `State` type parameter is the user's application state struct.
pub fn Context(comptime State: type) type {
    return struct {
        const Self = @This();

        // =====================================================================
        // Core References
        // =====================================================================

        /// The underlying Gooey context (layout, scene, widgets, etc.)
        gooey: *Gooey,

        /// The UI builder for constructing the element tree
        builder: *Builder,

        /// User's application state
        user_state: *State,

        // =====================================================================
        // State Access
        // =====================================================================

        /// Get a mutable pointer to the user's application state
        pub fn state(self: *Self) *State {
            return self.user_state;
        }

        /// Get an immutable reference to the user's application state
        pub fn stateConst(self: *const Self) *const State {
            return self.user_state;
        }

        // =====================================================================
        // Reactivity
        // =====================================================================

        /// Trigger a UI re-render
        ///
        /// Call this after modifying state to ensure the UI updates.
        /// Note: When using `update()` or `updateWith()`, notification is automatic.
        pub fn notify(self: *Self) void {
            self.gooey.requestRender();
        }

        // =====================================================================
        // Pure State Handlers (Option B - Recommended)
        // =====================================================================

        /// Create a handler from a pure state method.
        ///
        /// The method should be `fn(*State) void` - no context parameter.
        /// After the method is called, the UI automatically re-renders.
        ///
        /// This is the recommended pattern because:
        /// - State stays pure and testable
        /// - No UI coupling in state methods
        /// - Framework handles the notification glue
        ///
        /// ## Example
        ///
        /// ```zig
        /// const AppState = struct {
        ///     count: i32 = 0,
        ///
        ///     pub fn increment(self: *AppState) void {
        ///         self.count += 1;
        ///     }
        /// };
        ///
        /// fn render(cx: *Context(AppState)) void {
        ///     ui.buttonHandler("+", cx.update(AppState.increment));
        /// }
        /// ```
        pub fn update(
            self: *Self,
            comptime method: fn (*State) void,
        ) HandlerRef {
            _ = self;

            const Wrapper = struct {
                fn invoke(gooey: *Gooey, _: EntityId) void {
                    const state_ptr = handler_mod.getRootState(State) orelse {
                        std.debug.print("Handler error: state not found\n", .{});
                        return;
                    };

                    // Call the pure method
                    method(state_ptr);

                    // Auto-notify (re-render)
                    gooey.requestRender();
                }
            };

            return .{
                .callback = Wrapper.invoke,
                .entity_id = EntityId.invalid,
            };
        }

        /// Create a handler from a pure state method that takes an argument.
        ///
        /// The method should be `fn(*State, ArgType) void`.
        /// The argument is captured and passed when the handler is invoked.
        /// After the method is called, the UI automatically re-renders.
        ///
        /// **Note:** The argument must fit in 8 bytes (u64). This covers:
        /// - All integer types up to u64/i64
        /// - usize (indices)
        /// - Pointers
        /// - Small structs/enums
        ///
        /// ## Example
        ///
        /// ```zig
        /// const AppState = struct {
        ///     counters: [10]i32 = [_]i32{0} ** 10,
        ///
        ///     pub fn incrementAt(self: *AppState, index: usize) void {
        ///         self.counters[index] += 1;
        ///     }
        /// };
        ///
        /// fn render(cx: *Context(AppState)) void {
        ///     for (0..10) |i| {
        ///         ui.buttonHandler("+", cx.updateWith(i, AppState.incrementAt));
        ///     }
        /// }
        /// ```
        pub fn updateWith(
            self: *Self,
            arg: anytype,
            comptime method: fn (*State, @TypeOf(arg)) void,
        ) HandlerRef {
            _ = self;
            const Arg = @TypeOf(arg);

            // Ensure arg fits in EntityId (8 bytes)
            comptime {
                if (@sizeOf(Arg) > @sizeOf(u64)) {
                    @compileError("updateWith: argument type '" ++ @typeName(Arg) ++ "' exceeds 8 bytes. Use a pointer or index instead.");
                }
            }

            // Pack the argument into EntityId
            const packed_entity_id = packArg(Arg, arg);

            const Wrapper = struct {
                fn invoke(gooey: *Gooey, packed_arg: EntityId) void {
                    const state_ptr = handler_mod.getRootState(State) orelse {
                        std.debug.print("Handler error: state not found\n", .{});
                        return;
                    };

                    // Unpack the argument
                    const unpacked = unpackArg(Arg, packed_arg);

                    // Call the pure method with the argument
                    method(state_ptr, unpacked);

                    // Auto-notify (re-render)
                    gooey.requestRender();
                }
            };

            return .{
                .callback = Wrapper.invoke,
                .entity_id = packed_entity_id,
            };
        }

        // =====================================================================
        // Context-Aware Handlers (Legacy Pattern)
        // =====================================================================

        /// Create a handler from a method that receives the context.
        ///
        /// Use this when the handler needs to perform UI operations like
        /// focus management, scrolling, or conditional notification.
        ///
        /// **Note:** Prefer `update()` when possible for cleaner, testable code.
        ///
        /// ## Example
        ///
        /// ```zig
        /// const AppState = struct {
        ///     pub fn submit(self: *AppState, cx: *Context(AppState)) void {
        ///         self.submitted = true;
        ///         cx.blurAll();  // Need context for UI operations
        ///         cx.notify();
        ///     }
        /// };
        ///
        /// fn render(cx: *Context(AppState)) void {
        ///     ui.buttonHandler("Submit", cx.handler(AppState.submit));
        /// }
        /// ```
        pub fn handler(
            self: *Self,
            comptime method: fn (*State, *Self) void,
        ) HandlerRef {
            // Store state pointer for the callback to retrieve
            handler_mod.setRootState(State, self.user_state);

            // Create a wrapper that reconstructs context and calls method
            const Wrapper = struct {
                fn invoke(gooey: *Gooey, _: EntityId) void {
                    // Retrieve the stored state pointer
                    const state_ptr = handler_mod.getRootState(State) orelse {
                        std.debug.print("Handler error: state not found\n", .{});
                        return;
                    };

                    // Reconstruct a minimal context for the handler
                    var cx = Self{
                        .gooey = gooey,
                        .builder = undefined,
                        .user_state = state_ptr,
                    };

                    // Call the actual method
                    method(state_ptr, &cx);
                }
            };

            return .{
                .callback = Wrapper.invoke,
                .entity_id = EntityId.invalid,
            };
        }

        // =====================================================================
        // Resource Access
        // =====================================================================

        /// Get the allocator used by Gooey
        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.gooey.allocator;
        }

        // =====================================================================
        // Window Operations
        // =====================================================================

        /// Get window dimensions
        pub fn windowSize(self: *Self) struct { width: f32, height: f32 } {
            return .{
                .width = self.gooey.width,
                .height = self.gooey.height,
            };
        }

        // =====================================================================
        // Layout Shortcuts (delegate to builder)
        // =====================================================================

        /// Create a vertical stack layout
        pub fn vstack(self: *Self, style: ui_mod.StackStyle, children: anytype) void {
            self.builder.vstack(style, children);
        }

        /// Create a horizontal stack layout
        pub fn hstack(self: *Self, style: ui_mod.StackStyle, children: anytype) void {
            self.builder.hstack(style, children);
        }

        /// Create a box container
        pub fn box(self: *Self, style: ui_mod.BoxStyle, children: anytype) void {
            self.builder.box(style, children);
        }

        /// Create a box container with an explicit ID
        pub fn boxWithId(self: *Self, id: []const u8, style: ui_mod.BoxStyle, children: anytype) void {
            self.builder.boxWithId(id, style, children);
        }

        /// Create a centered container
        pub fn center(self: *Self, style: ui_mod.CenterStyle, children: anytype) void {
            self.builder.center(style, children);
        }

        /// Conditionally render children
        pub fn when(self: *Self, condition: bool, children: anytype) void {
            self.builder.when(condition, children);
        }

        /// Render if optional value is non-null
        pub fn maybe(self: *Self, optional: anytype, comptime render_fn: anytype) void {
            self.builder.maybe(optional, render_fn);
        }

        /// Iterate over items and render each
        pub fn each(self: *Self, items: anytype, comptime render_fn: anytype) void {
            self.builder.each(items, render_fn);
        }

        /// Create a scrollable container
        pub fn scroll(self: *Self, id: []const u8, style: ui_mod.ScrollStyle, children: anytype) void {
            self.builder.scroll(id, style, children);
        }

        // =====================================================================
        // Widget Access
        // =====================================================================

        /// Get or create a TextInput widget by ID
        pub fn textInput(self: *Self, id: []const u8) ?*@import("../elements/text_input.zig").TextInput {
            return self.gooey.textInput(id);
        }

        /// Focus a TextInput by ID
        pub fn focusTextInput(self: *Self, id: []const u8) void {
            self.gooey.focusTextInput(id);
        }

        /// Focus next element in tab order
        pub fn focusNext(self: *Self) void {
            self.gooey.focusNext();
        }

        /// Focus previous element in tab order
        pub fn focusPrev(self: *Self) void {
            self.gooey.focusPrev();
        }

        /// Clear all focus
        pub fn blurAll(self: *Self) void {
            self.gooey.blurAll();
        }

        /// Check if an element is focused
        pub fn isElementFocused(self: *Self, id: []const u8) bool {
            return self.gooey.isElementFocused(id);
        }

        /// Get a scroll container by ID
        pub fn scrollContainer(self: *Self, id: []const u8) ?*@import("../elements/scroll_container.zig").ScrollContainer {
            return self.gooey.widgets.scrollContainer(id);
        }
    };
}

// =============================================================================
// Helper Functions for Argument Packing
// =============================================================================

/// Pack an argument into an EntityId (up to 8 bytes)
fn packArg(comptime T: type, arg: T) EntityId {
    var result: u64 = 0;
    const arg_bytes = std.mem.asBytes(&arg);
    const result_bytes = std.mem.asBytes(&result);
    @memcpy(result_bytes[0..@sizeOf(T)], arg_bytes);
    return .{ .id = result };
}

/// Unpack an argument from an EntityId
fn unpackArg(comptime T: type, packed_entity_id: EntityId) T {
    var result: T = undefined;
    const result_bytes = std.mem.asBytes(&result);
    const packed_bytes = std.mem.asBytes(&packed_entity_id.id);
    @memcpy(result_bytes, packed_bytes[0..@sizeOf(T)]);
    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "Context creation and state access" {
    const TestState = struct {
        count: i32 = 0,
        name: []const u8 = "test",
    };

    const test_state = TestState{ .count = 42 };

    // We can't fully test without a real Gooey instance, but we can verify the type compiles
    const ContextType = Context(TestState);
    _ = ContextType;

    // Verify state is accessible
    try std.testing.expectEqual(@as(i32, 42), test_state.count);
}

test "packArg/unpackArg roundtrip" {
    // Test with usize
    {
        const original: usize = 42;
        const packed_entity_id = packArg(usize, original);
        const unpacked = unpackArg(usize, packed_entity_id);
        try std.testing.expectEqual(original, unpacked);
    }

    // Test with i32
    {
        const original: i32 = -123;
        const packed_entity_id = packArg(i32, original);
        const unpacked = unpackArg(i32, packed_entity_id);
        try std.testing.expectEqual(original, unpacked);
    }

    // Test with small struct
    {
        const Point = struct { x: i16, y: i16 };
        const original = Point{ .x = 100, .y = -50 };
        const packed_entity_id = packArg(Point, original);
        const unpacked = unpackArg(Point, packed_entity_id);
        try std.testing.expectEqual(original.x, unpacked.x);
        try std.testing.expectEqual(original.y, unpacked.y);
    }

    // Test with enum
    {
        const Color = enum(u8) { red, green, blue };
        const original = Color.green;
        const packed_entity_id = packArg(Color, original);
        const unpacked = unpackArg(Color, packed_entity_id);
        try std.testing.expectEqual(original, unpacked);
    }
}

test "pure state methods are testable" {
    // This demonstrates why Option B is valuable - state is testable!
    const TestState = struct {
        count: i32 = 0,
        items: [4]i32 = [_]i32{0} ** 4,

        pub fn increment(self: *@This()) void {
            self.count += 1;
        }

        pub fn decrement(self: *@This()) void {
            self.count -= 1;
        }

        pub fn incrementAt(self: *@This(), index: usize) void {
            self.items[index] += 1;
        }
    };

    var s = TestState{};

    // Test increment
    s.increment();
    try std.testing.expectEqual(@as(i32, 1), s.count);

    // Test decrement
    s.decrement();
    try std.testing.expectEqual(@as(i32, 0), s.count);

    // Test incrementAt
    s.incrementAt(2);
    try std.testing.expectEqual(@as(i32, 1), s.items[2]);
    try std.testing.expectEqual(@as(i32, 0), s.items[0]);
}
