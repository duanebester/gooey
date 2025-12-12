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
//! ## Usage
//!
//! ```zig
//! const AppState = struct {
//!     count: i32 = 0,
//!     theme: Theme = .light,
//! };
//!
//! pub fn main() !void {
//!     var app_state = AppState{};
//!     try gooey.runWithState(AppState, .{
//!         .state = &app_state,
//!         .render = render,
//!     });
//! }
//!
//! fn render(cx: *gooey.Context(AppState)) void {
//!     cx.vstack(.{ .gap = 16 }, .{
//!         gooey.ui.textFmt("Count: {}", .{cx.state().count}, .{}),
//!         gooey.ui.button("+", increment),
//!     });
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
        /// Note: In simple cases where state is modified in event handlers
        /// that already trigger re-renders, this may not be necessary.
        pub fn notify(self: *Self) void {
            self.gooey.requestRender();
        }

        // =====================================================================
        // Handler Creation
        // =====================================================================

        /// Create a handler from a method on State.
        ///
        /// This allows you to pass methods as event callbacks while maintaining
        /// access to both the state and context. No more global variables!
        ///
        /// ## Example
        ///
        /// ```zig
        /// const AppState = struct {
        ///     count: i32 = 0,
        ///
        ///     pub fn increment(self: *AppState, cx: *Context(AppState)) void {
        ///         self.count += 1;
        ///         cx.notify();
        ///     }
        /// };
        ///
        /// fn render(cx: *Context(AppState)) void {
        ///     cx.box(.{}, .{
        ///         ui.buttonHandler("+", cx.handler(AppState.increment)),
        ///     });
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
