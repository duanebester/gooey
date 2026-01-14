//! WindowHandle - Typed handle for cross-window communication
//!
//! Provides type-safe operations on windows with a specific State type.
//! This is the GPUI-inspired API for managing windows from other contexts.
//!
//! ## Usage
//!
//! ```zig
//! // Create a window and get a typed handle
//! const handle = try app.openWindow(MyState, &my_state, render, .{});
//!
//! // Later, from another window or callback:
//! handle.update(app, struct {
//!     fn apply(state: *MyState) void {
//!         state.counter += 1;
//!     }
//! }.apply);
//!
//! // Or read state:
//! if (handle.read(app)) |state| {
//!     std.debug.print("Counter: {}\n", .{state.counter});
//! }
//! ```
//!
//! ## Design
//!
//! WindowHandle wraps a WindowId with compile-time type information,
//! ensuring type-safe access to window state. Operations gracefully
//! handle closed windows by returning null or doing nothing.

const std = @import("std");

// Platform imports
const platform = @import("../platform/mod.zig");
const Window = platform.Window;
const WindowId = platform.WindowId;
const WindowRegistry = platform.WindowRegistry;

// Runtime imports
const WindowContext = @import("window_context.zig").WindowContext;

// =============================================================================
// WindowHandle
// =============================================================================

/// A typed handle to a window with a specific State type.
///
/// Provides type-safe operations on the window's state. All operations
/// gracefully handle the case where the window has been closed.
pub fn WindowHandle(comptime State: type) type {
    return struct {
        /// The underlying window ID
        id: WindowId,

        const Self = @This();

        // =====================================================================
        // Constants (per CLAUDE.md: "put a limit on everything")
        // =====================================================================

        /// Type alias for the WindowContext with this State type
        const WinCtx = WindowContext(State);

        // =====================================================================
        // State Access
        // =====================================================================

        /// Update this window's state and trigger a re-render.
        ///
        /// The update function receives a mutable pointer to the state.
        /// After the update, the window is marked for re-rendering.
        ///
        /// Does nothing if the window has been closed.
        pub fn update(self: Self, registry: *WindowRegistry, f: *const fn (*State) void) void {
            // Assertions: validate inputs
            std.debug.assert(self.id.isValid());

            const window = self.getWindow(registry) orelse return;
            const ctx = window.getUserData(WinCtx) orelse return;

            // Apply the update
            f(ctx.state);

            // Request re-render
            window.requestRender();
        }

        /// Update this window's state with context access.
        ///
        /// The update function receives both the Cx context and state,
        /// allowing side effects like spawning new windows or animations.
        ///
        /// Does nothing if the window has been closed.
        pub fn updateWithCx(
            self: Self,
            registry: *WindowRegistry,
            comptime f: fn (*@import("../cx.zig").Cx, *State) void,
        ) void {
            // Assertions: validate inputs
            std.debug.assert(self.id.isValid());

            const window = self.getWindow(registry) orelse return;
            const ctx = window.getUserData(WinCtx) orelse return;

            // Apply the update with Cx access
            f(&ctx.cx, ctx.state);

            // Request re-render
            window.requestRender();
        }

        /// Read this window's state (immutable).
        ///
        /// Returns null if the window has been closed.
        pub fn read(self: Self, registry: *const WindowRegistry) ?*const State {
            // Assertions: validate inputs
            std.debug.assert(self.id.isValid());

            const window = self.getWindowConst(registry) orelse return null;
            const ctx = window.getUserData(WinCtx) orelse return null;
            return ctx.state;
        }

        /// Read this window's state (mutable).
        ///
        /// Use `update()` when you need to trigger a re-render after modification.
        /// This method is for cases where you need mutable access without re-render.
        ///
        /// Returns null if the window has been closed.
        pub fn readMut(self: Self, registry: *WindowRegistry) ?*State {
            // Assertions: validate inputs
            std.debug.assert(self.id.isValid());

            const window = self.getWindow(registry) orelse return null;
            const ctx = window.getUserData(WinCtx) orelse return null;
            return ctx.state;
        }

        // =====================================================================
        // Window Operations
        // =====================================================================

        /// Close this window.
        ///
        /// The window will be destroyed and removed from the registry.
        /// After this call, `isValid()` will return false.
        pub fn close(self: Self, registry: *WindowRegistry) void {
            std.debug.assert(self.id.isValid());

            if (registry.unregister(self.id)) |window_ptr| {
                // Cast to Window and close it
                const window: *Window = @ptrCast(@alignCast(window_ptr));
                window.close();
            }
        }

        /// Focus this window (bring to front and make key window).
        ///
        /// Does nothing if the window has been closed.
        pub fn focus(self: Self, registry: *WindowRegistry) void {
            std.debug.assert(self.id.isValid());

            const window = self.getWindow(registry) orelse return;
            window.focus();
            registry.setActiveWindow(self.id);
        }

        /// Set this window's title.
        ///
        /// Does nothing if the window has been closed.
        pub fn setTitle(self: Self, registry: *WindowRegistry, title: []const u8) void {
            std.debug.assert(self.id.isValid());

            const window = self.getWindow(registry) orelse return;
            window.setTitle(title);
        }

        /// Request a re-render of this window.
        ///
        /// Does nothing if the window has been closed.
        pub fn requestRender(self: Self, registry: *WindowRegistry) void {
            std.debug.assert(self.id.isValid());

            const window = self.getWindow(registry) orelse return;
            window.requestRender();
        }

        // =====================================================================
        // Validation
        // =====================================================================

        /// Check if this window still exists.
        ///
        /// Returns false if the window has been closed.
        pub fn isValid(self: Self, registry: *const WindowRegistry) bool {
            if (!self.id.isValid()) return false;
            return registry.contains(self.id);
        }

        /// Get the raw WindowId.
        ///
        /// Useful for comparisons or storing in collections.
        pub fn getId(self: Self) WindowId {
            return self.id;
        }

        // =====================================================================
        // Internal Helpers
        // =====================================================================

        /// Get the window pointer from the registry (mutable).
        fn getWindow(self: Self, registry: *WindowRegistry) ?*Window {
            return registry.getTyped(Window, self.id);
        }

        /// Get the window pointer from the registry (const).
        fn getWindowConst(self: Self, registry: *const WindowRegistry) ?*Window {
            return registry.getTyped(Window, self.id);
        }

        // =====================================================================
        // Construction
        // =====================================================================

        /// Create a WindowHandle from a WindowId.
        ///
        /// This is typically called by the app layer when opening a new window.
        pub fn fromId(id: WindowId) Self {
            std.debug.assert(id.isValid());
            return .{ .id = id };
        }

        /// Create an invalid handle.
        ///
        /// Useful as a sentinel value. `isValid()` will always return false.
        pub fn invalid() Self {
            return .{ .id = .invalid };
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "WindowHandle type instantiation" {
    const TestState = struct {
        count: i32 = 0,
        name: []const u8 = "test",
    };

    // Verify the type compiles correctly
    const Handle = WindowHandle(TestState);
    _ = Handle;
}

test "WindowHandle invalid sentinel" {
    const TestState = struct {
        value: i32 = 42,
    };

    const Handle = WindowHandle(TestState);
    const h = Handle.invalid();

    // Invalid handle has invalid ID
    std.debug.assert(h.id == .invalid);
}

test "WindowHandle fromId construction" {
    const TestState = struct {
        value: i32 = 42,
    };

    const Handle = WindowHandle(TestState);
    const id = WindowId.fromRaw(123);
    const h = Handle.fromId(id);

    // Handle should have the correct ID
    std.debug.assert(h.getId() == id);
    std.debug.assert(h.getId().raw() == 123);
}

test "WindowHandle struct size is minimal" {
    const TestState = struct {
        data: [1024]u8 = undefined,
        count: i32 = 0,
    };

    const Handle = WindowHandle(TestState);

    // WindowHandle should only contain the WindowId, not the State
    const size = @sizeOf(Handle);
    std.debug.assert(size == @sizeOf(WindowId));
    std.debug.assert(size <= 4); // Just a u32
}
