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
//! // Later, from another window or callback (`app.getPlatform()`):
//! handle.update(app.getPlatform(), struct {
//!     fn apply(state: *MyState) void {
//!         state.counter += 1;
//!     }
//! }.apply);
//!
//! // Or read state:
//! if (handle.read(app.getPlatformConst())) |state| {
//!     std.debug.print("Counter: {}\n", .{state.counter});
//! }
//! ```
//!
//! ## Design
//!
//! WindowHandle wraps a WindowId with compile-time type information,
//! ensuring type-safe access to window state. Operations gracefully
//! handle closed windows by returning null or doing nothing.
//!
//! Ids are resolved against the *platform's* window registry. That registry is
//! the single source of window identity: `PlatformWindow.init` registers itself
//! and `getWindowId()` returns the id assigned there. Resolving through a
//! second, app-level registry would mean two independent id sequences, and a
//! handle would silently address the wrong window as soon as they drifted.

const std = @import("std");

// Platform imports
const platform = @import("../platform/mod.zig");
const Platform = platform.Platform;
// `PlatformWindow` is the OS-level handle; `Window` is the framework wrapper.
const PlatformWindow = platform.PlatformWindow;
const WindowId = platform.WindowId;

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
        pub fn update(self: Self, plat: *Platform, f: *const fn (*State) void) void {
            // Assertions: validate inputs
            std.debug.assert(self.id.isValid());
            std.debug.assert(@intFromPtr(f) != 0);

            const window = self.getWindow(plat) orelse return;
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
            plat: *Platform,
            comptime f: fn (*@import("../cx.zig").Cx, *State) void,
        ) void {
            // Assertions: validate inputs
            std.debug.assert(self.id.isValid());
            std.debug.assert(@intFromPtr(plat) != 0);

            const window = self.getWindow(plat) orelse return;
            const ctx = window.getUserData(WinCtx) orelse return;

            // Apply the update with Cx access
            f(&ctx.cx, ctx.state);

            // Request re-render
            window.requestRender();
        }

        /// Read this window's state (immutable).
        ///
        /// Returns null if the window has been closed.
        pub fn read(self: Self, plat: *const Platform) ?*const State {
            // Assertions: validate inputs
            std.debug.assert(self.id.isValid());
            std.debug.assert(@intFromPtr(plat) != 0);

            const window = self.getWindowConst(plat) orelse return null;
            const ctx = window.getUserData(WinCtx) orelse return null;
            return ctx.state;
        }

        /// Read this window's state (mutable).
        ///
        /// Use `update()` when you need to trigger a re-render after modification.
        /// This method is for cases where you need mutable access without re-render.
        ///
        /// Returns null if the window has been closed.
        pub fn readMut(self: Self, plat: *Platform) ?*State {
            // Assertions: validate inputs
            std.debug.assert(self.id.isValid());
            std.debug.assert(@intFromPtr(plat) != 0);

            const window = self.getWindow(plat) orelse return null;
            const ctx = window.getUserData(WinCtx) orelse return null;
            return ctx.state;
        }

        // =====================================================================
        // Window Operations
        // =====================================================================

        /// Request that this window close.
        ///
        /// Routes through the host close sequence, so an `on_close` callback
        /// can still veto it. Deliberately does *not* `deinit` the window: a
        /// handle close is normally invoked from inside that window's own event
        /// dispatch, and destroying it there would free the `WindowContext`
        /// holding the `Cx` the host is dispatching through.
        ///
        /// If the close is not vetoed the window becomes `isClosed()`, and
        /// `isValid()` reports false from that moment. The window itself is
        /// reclaimed by the owning `App` the next time it drains
        /// (`App.drainClosedWindows`, which `App.openWindow`,
        /// `App.closeWindowById`, and `App.deinit` all call). Until that drain
        /// the window stays registered with the platform, so `windowCount()`
        /// still includes it.
        pub fn close(self: Self, plat: *Platform) void {
            std.debug.assert(self.id.isValid());
            std.debug.assert(@intFromPtr(plat) != 0);

            const window = self.getWindow(plat) orelse return;
            std.debug.assert(window.getWindowId() == self.id);
            window.close();
        }

        /// Focus this window (bring to front and make key window).
        ///
        /// Does nothing if the window has been closed.
        pub fn focus(self: Self, plat: *Platform) void {
            std.debug.assert(self.id.isValid());

            const window = self.getWindow(plat) orelse return;
            window.focus();

            // Safe to publish: the lookup above proved the id is registered,
            // which is what `setActiveWindowId` asserts.
            plat.setActiveWindowId(self.id);
        }

        /// Set this window's title.
        ///
        /// An empty title is legal: AppKit, `xdg_toplevel.set_title`, and
        /// `document.title` all accept one and render an untitled window.
        ///
        /// No length bound is asserted here because there is no single bound to
        /// assert — each backend declares its own (Wayland 255 bytes, web 1024)
        /// and enforces it at its own `setTitle`. A fourth number invented at
        /// this layer could only be wrong on two targets out of three.
        ///
        /// Does nothing if the window has been closed.
        pub fn setTitle(self: Self, plat: *Platform, title: []const u8) void {
            std.debug.assert(self.id.isValid());
            std.debug.assert(@intFromPtr(plat) != 0);

            const window = self.getWindow(plat) orelse return;
            std.debug.assert(window.getWindowId() == self.id);
            window.setTitle(title);
        }

        /// Request a re-render of this window.
        ///
        /// Does nothing if the window has been closed.
        pub fn requestRender(self: Self, plat: *Platform) void {
            std.debug.assert(self.id.isValid());
            std.debug.assert(@intFromPtr(plat) != 0);

            const window = self.getWindow(plat) orelse return;
            window.requestRender();
        }

        // =====================================================================
        // Validation
        // =====================================================================

        /// Check if this window still exists and has not closed.
        ///
        /// Registration alone is not enough: a closed window stays registered
        /// until the owning `App` drains it, so `isClosed()` — not mere
        /// presence in the registry — is what answers "can the user still see
        /// this window?". `App.isWindowOpen` tests the same two things.
        pub fn isValid(self: Self, plat: *const Platform) bool {
            if (!self.id.isValid()) return false;

            const window = self.getWindowConst(plat) orelse return false;
            std.debug.assert(window.getWindowId() == self.id);
            return !window.isClosed();
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

        /// Resolve the window pointer through the platform registry (mutable).
        ///
        /// The platform boundary deals only in `*anyopaque` (it has no
        /// `getTyped` equivalent), so the cast lives here, at the one call site
        /// that knows the concrete window type.
        fn getWindow(self: Self, plat: *Platform) ?*PlatformWindow {
            std.debug.assert(self.id.isValid());

            const window_ptr = plat.getWindow(self.id) orelse return null;
            const window: *PlatformWindow = @ptrCast(@alignCast(window_ptr));

            // Pair-assert the cast: the registry is keyed by id, so a window
            // that reports a different id means the pointer we just
            // reinterpreted is not the one this handle names.
            std.debug.assert(window.getWindowId() == self.id);
            return window;
        }

        /// Resolve the window pointer through the platform registry (const).
        fn getWindowConst(self: Self, plat: *const Platform) ?*PlatformWindow {
            std.debug.assert(self.id.isValid());

            const window_ptr = plat.getWindow(self.id) orelse return null;
            const window: *PlatformWindow = @ptrCast(@alignCast(window_ptr));
            std.debug.assert(window.getWindowId() == self.id);
            return window;
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
