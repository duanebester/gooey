//! Focus & Keyboard Navigation System
//!
//! Inspired by GPUI's FocusHandle and Ghostty's surface focus tracking.
//! Provides a unified focus management system for all focusable elements.
//!
//! ## Key Concepts
//!
//! - **FocusId**: Lightweight identifier for a focusable element (hash of string ID)
//! - **FocusHandle**: Reference with tab ordering configuration
//! - **FocusManager**: Central coordinator for focus state and navigation
//!
//! ## Tab Navigation
//!
//! Elements register themselves during render with a tab_index. Tab/Shift-Tab
//! cycles through registered elements in order. Elements can opt out with
//! tab_stop = false.
//!
//! ## Events
//!
//! Focus changes trigger focus/blur callbacks on the affected elements,
//! allowing widgets to update their visual state.

const std = @import("std");
const layout_id_mod = @import("../layout/layout_id.zig");
const LayoutId = layout_id_mod.LayoutId;

// =============================================================================
// FocusId - Lightweight focus identifier
// =============================================================================

/// Compact identifier for a focusable element.
/// Uses hash of string ID for fast comparison.
pub const FocusId = struct {
    /// Hash of the element's string ID
    hash: u64,

    const Self = @This();

    /// Create a FocusId from a string identifier
    pub fn init(id: []const u8) Self {
        return .{ .hash = std.hash.Wyhash.hash(0, id) };
    }

    /// Create an invalid/none FocusId
    pub fn none() Self {
        return .{ .hash = 0 };
    }

    /// Check if this is a valid (non-none) FocusId
    pub fn isValid(self: Self) bool {
        return self.hash != 0;
    }

    /// Compare two FocusIds for equality
    pub fn eql(self: Self, other: Self) bool {
        return self.hash == other.hash;
    }

    /// Create a FocusId from a LayoutId.
    /// Uses the string_id if available, otherwise derives from the 32-bit hash.
    /// This enables auto-injection of focus state in accessibility.
    pub fn fromLayoutId(layout_id: LayoutId) Self {
        // If we have the original string, use it for consistent hashing
        if (layout_id.string_id) |str| {
            return Self.init(str);
        }
        // Otherwise, extend the 32-bit layout hash to 64-bit
        // Mix the bits to create a reasonable 64-bit hash
        const id32 = layout_id.id;
        const high: u64 = @as(u64, id32) << 32;
        const low: u64 = @as(u64, id32) *% 0x9E3779B97F4A7C15; // Golden ratio prime
        return .{ .hash = high ^ low };
    }
};

// =============================================================================
// FocusHandle - Focus reference with configuration
// =============================================================================

/// Reference to a focusable element with tab ordering configuration.
/// Similar to GPUI's FocusHandle.
pub const FocusHandle = struct {
    /// The element's focus identifier
    id: FocusId,

    /// Tab order index (lower = earlier in tab order)
    /// Elements with same tab_index are ordered by registration
    tab_index: i32 = 0,

    /// Whether this element participates in tab navigation
    tab_stop: bool = true,

    /// Original string ID (for debugging/widget lookup)
    string_id: []const u8,

    const Self = @This();

    /// Create a new FocusHandle
    pub fn init(id: []const u8) Self {
        return .{
            .id = FocusId.init(id),
            .string_id = id,
        };
    }

    /// Set the tab index (fluent API)
    pub fn tabIndex(self: Self, index: i32) Self {
        var result = self;
        result.tab_index = index;
        return result;
    }

    /// Set whether this is a tab stop (fluent API)
    pub fn tabStop(self: Self, stop: bool) Self {
        var result = self;
        result.tab_stop = stop;
        return result;
    }

    /// Check if this handle is currently focused
    pub fn isFocused(self: Self, manager: *const FocusManager) bool {
        return manager.isFocused(self.id);
    }
};

// =============================================================================
// FocusEvent - Focus change notification
// =============================================================================

/// Type of focus change event
pub const FocusEventType = enum {
    /// Element gained focus
    focus_in,
    /// Element lost focus
    focus_out,
};

/// Focus change event data
pub const FocusEvent = struct {
    /// Type of focus change
    event_type: FocusEventType,
    /// The element that gained/lost focus
    target: FocusId,
    /// The element that had/will have focus (other side of the change)
    related: ?FocusId,
};

/// Callback type for focus change notifications
pub const FocusCallback = *const fn (event: FocusEvent, user_data: ?*anyopaque) void;

// =============================================================================
// FocusManager - Central focus coordinator
// =============================================================================

/// Manages focus state and tab navigation for all focusable elements.
/// Add to your Gooey struct and integrate with input handling.
pub const FocusManager = struct {
    allocator: std.mem.Allocator,

    /// Currently focused element (null = nothing focused)
    focused: ?FocusId = null,

    /// Tab order for keyboard navigation
    /// Rebuilt each frame during render
    focus_order: std.ArrayListUnmanaged(FocusHandle) = .{},

    /// Index into focus_order for current focus (-1 if nothing focused)
    focus_index: i32 = -1,

    /// Whether window/app has keyboard focus
    window_focused: bool = true,

    /// Focus change callback (optional)
    on_focus_change: ?FocusCallback = null,
    on_focus_change_data: ?*anyopaque = null,

    const Self = @This();

    /// Initialize the focus manager
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.focus_order.deinit(self.allocator);
    }

    // =========================================================================
    // Frame Lifecycle
    // =========================================================================

    /// Call at the start of each frame before building UI.
    /// Clears the focus order for rebuild.
    pub fn beginFrame(self: *Self) void {
        self.focus_order.clearRetainingCapacity();
        self.focus_index = -1;
    }

    /// Call at the end of each frame after building UI.
    /// Sorts the focus order and validates current focus.
    pub fn endFrame(self: *Self) void {
        // Sort by tab_index, then by registration order (stable sort)
        std.mem.sort(FocusHandle, self.focus_order.items, {}, struct {
            fn lessThan(_: void, a: FocusHandle, b: FocusHandle) bool {
                return a.tab_index < b.tab_index;
            }
        }.lessThan);

        // Update focus_index to match current focused element
        if (self.focused) |focused_id| {
            self.focus_index = -1;
            for (self.focus_order.items, 0..) |handle, i| {
                if (handle.id.eql(focused_id)) {
                    self.focus_index = @intCast(i);
                    break;
                }
            }
            // If focused element is no longer registered, clear focus
            if (self.focus_index == -1) {
                self.focused = null;
            }
        }
    }

    // =========================================================================
    // Registration (called during render)
    // =========================================================================

    /// Register a focusable element for this frame.
    /// Called during render pass to build tab order.
    pub fn register(self: *Self, handle: FocusHandle) void {
        self.focus_order.append(self.allocator, handle) catch return;
    }

    // =========================================================================
    // Focus Control
    // =========================================================================

    /// Focus a specific element by ID
    pub fn focus(self: *Self, id: FocusId) void {
        if (!id.isValid()) return;

        const old_focus = self.focused;

        // Don't re-focus if already focused
        if (old_focus) |old| {
            if (old.eql(id)) return;
        }

        // Update focus
        self.focused = id;

        // Find index in focus order
        self.focus_index = -1;
        for (self.focus_order.items, 0..) |handle, i| {
            if (handle.id.eql(id)) {
                self.focus_index = @intCast(i);
                break;
            }
        }

        // Notify blur on old element
        if (old_focus) |old| {
            self.notifyFocusChange(.{
                .event_type = .focus_out,
                .target = old,
                .related = id,
            });
        }

        // Notify focus on new element
        self.notifyFocusChange(.{
            .event_type = .focus_in,
            .target = id,
            .related = old_focus,
        });
    }

    /// Focus an element by string ID
    pub fn focusByName(self: *Self, id: []const u8) void {
        self.focus(FocusId.init(id));
    }

    /// Clear focus (blur everything)
    pub fn blur(self: *Self) void {
        if (self.focused) |old| {
            self.focused = null;
            self.focus_index = -1;
            self.notifyFocusChange(.{
                .event_type = .focus_out,
                .target = old,
                .related = null,
            });
        }
    }

    /// Move focus to the next element in tab order
    pub fn focusNext(self: *Self) void {
        self.cycleFocus(1);
    }

    /// Move focus to the previous element in tab order
    pub fn focusPrev(self: *Self) void {
        self.cycleFocus(-1);
    }

    /// Cycle focus by delta (+1 for next, -1 for prev)
    fn cycleFocus(self: *Self, delta: i32) void {
        // Count tab stops inline
        var count: usize = 0;
        for (self.focus_order.items) |handle| {
            if (handle.tab_stop) count += 1;
        }
        if (count == 0) return;

        // Find current position and next target in one pass
        var current_pos: i32 = -1;
        var pos: i32 = 0;
        for (self.focus_order.items, 0..) |handle, i| {
            if (!handle.tab_stop) continue;
            if (self.focus_index >= 0 and i == @as(usize, @intCast(self.focus_index))) {
                current_pos = pos;
            }
            pos += 1;
        }

        // Calculate target and iterate again to find it
        const target_pos: i32 = if (current_pos < 0)
            if (delta > 0) 0 else @as(i32, @intCast(count)) - 1
        else
            @mod(current_pos + delta, @as(i32, @intCast(count)));

        pos = 0;
        for (self.focus_order.items) |handle| {
            if (!handle.tab_stop) continue;
            if (pos == target_pos) {
                self.focus(handle.id);
                return;
            }
            pos += 1;
        }
    }

    // =========================================================================
    // Focus Queries
    // =========================================================================

    /// Check if a specific element is focused
    pub fn isFocused(self: *const Self, id: FocusId) bool {
        if (self.focused) |focused_id| {
            return focused_id.eql(id) and self.window_focused;
        }
        return false;
    }

    /// Check if a specific element (by name) is focused
    pub fn isFocusedByName(self: *const Self, id: []const u8) bool {
        return self.isFocused(FocusId.init(id));
    }

    /// Get the currently focused element's ID
    pub fn getFocused(self: *const Self) ?FocusId {
        return self.focused;
    }

    /// Get the currently focused element's handle (if registered this frame)
    pub fn getFocusedHandle(self: *const Self) ?FocusHandle {
        if (self.focused == null) return null;
        if (self.focus_index < 0) return null;
        if (self.focus_index >= @as(i32, @intCast(self.focus_order.items.len))) return null;
        return self.focus_order.items[@intCast(self.focus_index)];
    }

    /// Look up a FocusHandle by its FocusId
    /// Returns the handle if found in the current frame's focus order
    pub fn getHandleById(self: *const Self, id: FocusId) ?FocusHandle {
        for (self.focus_order.items) |handle| {
            if (handle.id.eql(id)) {
                return handle;
            }
        }
        return null;
    }

    /// Check if anything is focused
    pub fn hasFocus(self: *const Self) bool {
        return self.focused != null and self.window_focused;
    }

    // =========================================================================
    // Window Focus
    // =========================================================================

    /// Called when the window gains keyboard focus
    pub fn windowFocused(self: *Self) void {
        self.window_focused = true;
        if (self.focused) |id| {
            self.notifyFocusChange(.{
                .event_type = .focus_in,
                .target = id,
                .related = null,
            });
        }
    }

    /// Called when the window loses keyboard focus
    pub fn windowBlurred(self: *Self) void {
        self.window_focused = false;
        if (self.focused) |id| {
            self.notifyFocusChange(.{
                .event_type = .focus_out,
                .target = id,
                .related = null,
            });
        }
    }

    // =========================================================================
    // Callbacks
    // =========================================================================

    /// Set the focus change callback
    pub fn setOnFocusChange(
        self: *Self,
        callback: ?FocusCallback,
        user_data: ?*anyopaque,
    ) void {
        self.on_focus_change = callback;
        self.on_focus_change_data = user_data;
    }

    /// Internal: notify listeners of focus change
    fn notifyFocusChange(self: *Self, event: FocusEvent) void {
        if (self.on_focus_change) |callback| {
            callback(event, self.on_focus_change_data);
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "FocusId basic operations" {
    const id1 = FocusId.init("input1");
    const id2 = FocusId.init("input1");
    const id3 = FocusId.init("input2");
    const none_id = FocusId.none();

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
    try std.testing.expect(id1.isValid());
    try std.testing.expect(!none_id.isValid());
}

test "FocusId fromLayoutId with string_id" {
    // When LayoutId has a string_id, FocusId should match FocusId.init with same string
    const layout_id = LayoutId.fromString("my_button");
    const focus_id_from_layout = FocusId.fromLayoutId(layout_id);
    const focus_id_direct = FocusId.init("my_button");

    try std.testing.expect(focus_id_from_layout.eql(focus_id_direct));
    try std.testing.expect(focus_id_from_layout.isValid());
}

test "FocusId fromLayoutId without string_id" {
    // When LayoutId has no string_id, should still produce valid unique hash
    const layout_id = LayoutId.fromInt(12345);
    const focus_id = FocusId.fromLayoutId(layout_id);

    try std.testing.expect(focus_id.isValid());

    // Different layout IDs should produce different focus IDs
    const layout_id2 = LayoutId.fromInt(67890);
    const focus_id2 = FocusId.fromLayoutId(layout_id2);

    try std.testing.expect(!focus_id.eql(focus_id2));
}

test "FocusId fromLayoutId none" {
    // LayoutId.none should produce a deterministic (though potentially valid) FocusId
    const layout_id = LayoutId.none;
    const focus_id = FocusId.fromLayoutId(layout_id);

    // The hash of 0 extended will be 0, which is the none hash
    try std.testing.expect(!focus_id.isValid());
}

test "FocusHandle fluent API" {
    const handle = FocusHandle.init("my_input")
        .tabIndex(5)
        .tabStop(true);

    try std.testing.expectEqual(@as(i32, 5), handle.tab_index);
    try std.testing.expect(handle.tab_stop);
    try std.testing.expect(handle.id.isValid());
}

test "FocusManager focus operations" {
    const allocator = std.testing.allocator;
    var fm = FocusManager.init(allocator);
    defer fm.deinit();

    fm.beginFrame();
    fm.register(FocusHandle.init("input1").tabIndex(1));
    fm.register(FocusHandle.init("input2").tabIndex(2));
    fm.register(FocusHandle.init("input3").tabIndex(3).tabStop(false));
    fm.endFrame();

    try std.testing.expect(!fm.hasFocus());

    fm.focusByName("input1");
    try std.testing.expect(fm.hasFocus());
    try std.testing.expect(fm.isFocusedByName("input1"));

    fm.focusNext();
    try std.testing.expect(fm.isFocusedByName("input2"));

    fm.focusNext();
    try std.testing.expect(fm.isFocusedByName("input1")); // Wrapped, skipped input3

    fm.focusPrev();
    try std.testing.expect(fm.isFocusedByName("input2"));

    fm.blur();
    try std.testing.expect(!fm.hasFocus());
}

test "FocusManager tab order sorting" {
    const allocator = std.testing.allocator;
    var fm = FocusManager.init(allocator);
    defer fm.deinit();

    fm.beginFrame();
    fm.register(FocusHandle.init("third").tabIndex(3));
    fm.register(FocusHandle.init("first").tabIndex(1));
    fm.register(FocusHandle.init("second").tabIndex(2));
    fm.endFrame();

    fm.focusByName("first");
    try std.testing.expect(fm.isFocusedByName("first"));

    fm.focusNext();
    try std.testing.expect(fm.isFocusedByName("second"));

    fm.focusNext();
    try std.testing.expect(fm.isFocusedByName("third"));
}

test "FocusManager window focus" {
    const allocator = std.testing.allocator;
    var fm = FocusManager.init(allocator);
    defer fm.deinit();

    fm.beginFrame();
    fm.register(FocusHandle.init("input1"));
    fm.endFrame();

    fm.focusByName("input1");
    try std.testing.expect(fm.isFocusedByName("input1"));

    fm.windowBlurred();
    try std.testing.expect(!fm.isFocusedByName("input1"));
    try std.testing.expect(fm.focused != null);

    fm.windowFocused();
    try std.testing.expect(fm.isFocusedByName("input1"));
}
