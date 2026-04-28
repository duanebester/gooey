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
// Focusable - Vtable trait for widgets that participate in focus
// =============================================================================

/// Trait/vtable that lets `FocusManager` drive focus on a widget without
/// importing the widget type. Each focusable widget exposes a
/// `pub fn focusable(self: *T) Focusable` that bundles its instance pointer
/// with a comptime-generated vtable; the widget then registers this trait
/// alongside its `FocusHandle` during render. This breaks the
/// `context → widgets` import edge that previously forced
/// `Gooey.focusWidgetById(comptime T, id)` to switch on `TextInput` /
/// `TextArea` / `CodeEditorState` directly. Adding a new focusable widget
/// type now touches only `widgets/`.
///
/// See PR 4 in `docs/cleanup-implementation-plan.md` and the cleanup
/// direction for backward dependencies in
/// `docs/architectural-cleanup-plan.md` §4.
///
/// The vtable carries pointer-equality identity: two `Focusable`s are the
/// same widget iff their `ptr` fields are equal. The framework relies on
/// this for "is the previously-focused widget still the same instance?"
/// checks across frames (widget storage is stable across frames; pointers
/// outlive the per-frame `focus_order` rebuild).
pub const Focusable = struct {
    /// Type-erased pointer to the widget instance. Stable for the lifetime
    /// of the widget in `WidgetStore` (heap allocation does not move).
    ptr: *anyopaque,

    /// Pointer to a static, comptime-built vtable. Each widget type has
    /// exactly one vtable shared across all instances of that type.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Set the widget's focused flag, reset cursor blink, etc.
        focus: *const fn (ptr: *anyopaque) void,
        /// Clear the widget's focused flag and any IME / selection state.
        blur: *const fn (ptr: *anyopaque) void,
        /// Read the widget's focused flag. Takes `*anyopaque` (not
        /// `*const`) because some widget types declare
        /// `pub fn isFocused(self: *Self) bool` rather than
        /// `*const Self` — `CodeEditorState` delegates to its
        /// embedded `TextArea` and so cannot promise const access.
        /// The vtable thunk does not mutate, but the type system
        /// can't see through the delegation.
        is_focused: *const fn (ptr: *anyopaque) bool,
    };

    /// Call the widget's `focus()` method through the vtable.
    pub fn focus(self: Focusable) void {
        self.vtable.focus(self.ptr);
    }

    /// Call the widget's `blur()` method through the vtable.
    pub fn blur(self: Focusable) void {
        self.vtable.blur(self.ptr);
    }

    /// Read the widget's focused flag through the vtable.
    pub fn isFocused(self: Focusable) bool {
        return self.vtable.is_focused(self.ptr);
    }

    /// Pointer-equality identity. Two `Focusable`s refer to the same
    /// widget instance iff their `ptr` fields match. The vtable is
    /// allowed to differ in principle (different widget *types*), but in
    /// practice a single instance only ever has one vtable, so equal
    /// `ptr` implies equal `vtable` as well.
    pub fn eql(self: Focusable, other: Focusable) bool {
        return self.ptr == other.ptr;
    }

    /// Build a Focusable for a widget type `T` that exposes the three
    /// instance methods `focus(*T) void`, `blur(*T) void`, and
    /// `isFocused(*const T) bool`. The vtable is constructed at comptime
    /// and lives in static storage — one vtable per widget type, shared
    /// across all instances. This is the canonical way for a widget's
    /// own `pub fn focusable(self: *T) Focusable` method to fill in the
    /// trait without hand-rolling thunks at every call site.
    ///
    /// Per CLAUDE.md §3, the trait shape is asserted on construction:
    /// every widget type must expose exactly the three methods above.
    /// A typo or missing method fails compile, not at runtime.
    pub fn fromInstance(comptime T: type, instance: *T) Focusable {
        // Trait shape — fail compile if a widget drops a required method.
        comptime {
            std.debug.assert(@hasDecl(T, "focus"));
            std.debug.assert(@hasDecl(T, "blur"));
            std.debug.assert(@hasDecl(T, "isFocused"));
        }

        const Thunks = struct {
            fn focusFn(ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.focus();
            }
            fn blurFn(ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.blur();
            }
            fn isFocusedFn(ptr: *anyopaque) bool {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.isFocused();
            }
        };

        // One vtable per `T`, in `comptime` static storage.
        const vtable = comptime &VTable{
            .focus = Thunks.focusFn,
            .blur = Thunks.blurFn,
            .is_focused = Thunks.isFocusedFn,
        };

        return .{ .ptr = instance, .vtable = vtable };
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

    /// Optional widget vtable. Set by widget primitives during render so
    /// `FocusManager.focusByName` / `cycleFocus` / `blurAll` can drive
    /// the underlying widget's `focus()` / `blur()` without the focus
    /// manager (which lives in `context/`) ever importing widget types.
    /// `null` when the focusable is registered without an associated
    /// widget instance — e.g. plain elements that participate in tab
    /// order but have no per-instance focused-flag of their own (PR 4
    /// in `docs/cleanup-implementation-plan.md`).
    widget: ?Focusable = null,

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

    /// Attach a `Focusable` widget vtable (fluent API). Called by the UI
    /// builder when rendering a stateful widget (TextInput, TextArea,
    /// CodeEditor) so the focus manager can drive the widget's
    /// `focus()` / `blur()` through the trait — no widget-type switch
    /// in `context/`.
    pub fn withWidget(self: Self, focusable: Focusable) Self {
        var result = self;
        result.widget = focusable;
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
    focus_order: std.ArrayListUnmanaged(FocusHandle) = .empty,

    /// Index into focus_order for current focus (-1 if nothing focused)
    focus_index: i32 = -1,

    /// Vtable for the currently focused widget instance (if any). Set
    /// when `focus()` resolves an `id` to a `FocusHandle.widget`, cleared
    /// when focus moves away. Stored on the manager so `blur()` can
    /// drive the widget's `blur()` even if the handle has fallen out of
    /// `focus_order` (which is rebuilt each frame). Widget pointers are
    /// stable across frames because `WidgetStore` heap-allocates each
    /// instance once and hands out pointers — see PR 4 in
    /// `docs/cleanup-implementation-plan.md`.
    focused_widget: ?Focusable = null,

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

        // Update focus_index to match current focused element. Also
        // refresh the cached `focused_widget` from the freshly-rebuilt
        // `focus_order` — widget pointers are stable across frames so
        // this is a no-op for the common case, but it's the right
        // moment to pick up a re-registered handle that now carries a
        // `Focusable` (e.g. widget mounted this frame).
        if (self.focused) |focused_id| {
            self.focus_index = -1;
            var found_widget: ?Focusable = null;
            for (self.focus_order.items, 0..) |handle, i| {
                if (handle.id.eql(focused_id)) {
                    self.focus_index = @intCast(i);
                    found_widget = handle.widget;
                    break;
                }
            }
            // If focused element is no longer registered, clear focus
            // and the widget cache together — they must not desync.
            if (self.focus_index == -1) {
                self.focused = null;
                self.focused_widget = null;
            } else if (found_widget) |w| {
                self.focused_widget = w;
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

    /// Focus a specific element by ID. Drives the widget's `focus()` /
    /// `blur()` through the `Focusable` trait when the registered handle
    /// carries one — so the focus manager never needs to know whether
    /// the underlying widget is a `TextInput`, `TextArea`, or
    /// `CodeEditorState` (PR 4 — break the `context → widgets` edge).
    pub fn focus(self: *Self, id: FocusId) void {
        if (!id.isValid()) return;

        const old_focus = self.focused;

        // Don't re-focus if already focused
        if (old_focus) |old| {
            if (old.eql(id)) return;
        }

        // Resolve the new handle (if registered this frame) and remember
        // the previously focused widget so we can blur it via the trait
        // before the new one's flag is set.
        var new_index: i32 = -1;
        var new_widget: ?Focusable = null;
        for (self.focus_order.items, 0..) |handle, i| {
            if (handle.id.eql(id)) {
                new_index = @intCast(i);
                new_widget = handle.widget;
                break;
            }
        }
        const old_widget = self.focused_widget;

        // Update manager state.
        self.focused = id;
        self.focus_index = new_index;
        self.focused_widget = new_widget;

        // Drive widget vtable: blur the old, then focus the new. Order
        // matches the previous `widgets.blurAll(); widget.focus()` flow
        // (cleared first, then set) so any widget that observes
        // `isFocused()` of its peers sees a single-focused-at-a-time
        // invariant during the transition.
        if (old_widget) |w| {
            // Avoid re-blurring the same instance if focus is moving
            // within a single widget (vtable identity is by `ptr`).
            const same = if (new_widget) |nw| w.eql(nw) else false;
            if (!same) w.blur();
        }
        if (new_widget) |w| w.focus();

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

    /// Focus a widget by its string ID. Convenience wrapper that exists
    /// to give callers a method named after their intent (`focusWidget`)
    /// rather than the lower-level `focusByName`. Per PR 4 in
    /// `docs/cleanup-implementation-plan.md`, this is the API replacing
    /// the old per-widget-type switch (`focusWidgetById(comptime T, id)`)
    /// in `Gooey`. The underlying mechanics are identical to
    /// `focusByName`: look up the handle in `focus_order`, drive the
    /// trait's `blur()` / `focus()`, update manager state.
    pub fn focusWidget(self: *Self, id: []const u8) void {
        self.focusByName(id);
    }

    /// Clear focus (blur everything). Drives the previously-focused
    /// widget's `blur()` through the trait, then clears manager state.
    /// Per PR 4, this replaces the prior `widgets.blurAll()` walk over
    /// every per-type widget map: the focus manager already knows which
    /// instance is focused — only that one needs blurring.
    pub fn blur(self: *Self) void {
        const old_widget = self.focused_widget;
        if (self.focused) |old| {
            self.focused = null;
            self.focus_index = -1;
            self.focused_widget = null;
            if (old_widget) |w| w.blur();
            self.notifyFocusChange(.{
                .event_type = .focus_out,
                .target = old,
                .related = null,
            });
        } else {
            // Defensive: even if `focused` was cleared without going
            // through this path (e.g. handle dropped from `focus_order`
            // mid-frame), still drop any stale widget reference.
            self.focused_widget = null;
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

    // Most UIs have far fewer than 128 tab stops. If a UI exceeds this,
    // the extra stops are silently ignored — focus still cycles among the
    // first MAX_TAB_STOPS entries, which is better than failing.
    const MAX_TAB_STOPS = 128;

    /// Single pass: collect tab-stop indices into a fixed buffer, find the
    /// current position, compute the target, and index directly.
    fn cycleFocus(self: *Self, delta: i32) void {
        std.debug.assert(delta == 1 or delta == -1);

        // Collect tab stops and locate current position in one pass.
        var tab_stops: [MAX_TAB_STOPS]FocusId = undefined;
        var count: u32 = 0;
        var current_pos: i32 = -1;

        for (self.focus_order.items, 0..) |handle, i| {
            if (!handle.tab_stop) continue;
            if (count >= MAX_TAB_STOPS) break; // Hard cap — fail safe.

            if (self.focus_index >= 0 and i == @as(usize, @intCast(self.focus_index))) {
                current_pos = @intCast(count);
            }
            tab_stops[count] = handle.id;
            count += 1;
        }
        if (count == 0) return;

        // Compute target position with wrap-around.
        const count_i32: i32 = @intCast(count);
        const target_pos: i32 = if (current_pos < 0)
            if (delta > 0) 0 else count_i32 - 1
        else
            @mod(current_pos + delta, count_i32);

        // Direct index — no second iteration.
        std.debug.assert(target_pos >= 0);
        std.debug.assert(target_pos < count_i32);
        self.focus(tab_stops[@intCast(target_pos)]);
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

// PR 4 — `Focusable` vtable.
//
// These tests pin the trait shape on a fake widget so the vtable
// machinery is exercised without dragging the real `TextInput` /
// `TextArea` / `CodeEditorState` types (and their atlases / IO / clip
// state) into a context-layer test.

test "Focusable vtable drives focus/blur on a widget" {
    // Minimal widget that implements the trait shape verified by
    // `core.interface_verify.verifyFocusableInterface`.
    const FakeWidget = struct {
        focused: bool = false,
        focus_calls: u32 = 0,
        blur_calls: u32 = 0,

        pub fn focus(self: *@This()) void {
            self.focused = true;
            self.focus_calls += 1;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
            self.blur_calls += 1;
        }
        pub fn isFocused(self: *@This()) bool {
            return self.focused;
        }
    };

    var w: FakeWidget = .{};
    const trait = Focusable.fromInstance(FakeWidget, &w);

    try std.testing.expect(!trait.isFocused());
    trait.focus();
    try std.testing.expect(trait.isFocused());
    try std.testing.expectEqual(@as(u32, 1), w.focus_calls);

    trait.blur();
    try std.testing.expect(!trait.isFocused());
    try std.testing.expectEqual(@as(u32, 1), w.blur_calls);

    // Pointer-equality identity: the same instance round-trips equal.
    const trait_again = Focusable.fromInstance(FakeWidget, &w);
    try std.testing.expect(trait.eql(trait_again));
}

test "FocusManager.focusWidget drives the registered Focusable" {
    const FakeWidget = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
        pub fn isFocused(self: *@This()) bool {
            return self.focused;
        }
    };

    const allocator = std.testing.allocator;
    var fm = FocusManager.init(allocator);
    defer fm.deinit();

    var w1: FakeWidget = .{};
    var w2: FakeWidget = .{};

    fm.beginFrame();
    fm.register(FocusHandle.init("a")
        .tabIndex(1)
        .withWidget(Focusable.fromInstance(FakeWidget, &w1)));
    fm.register(FocusHandle.init("b")
        .tabIndex(2)
        .withWidget(Focusable.fromInstance(FakeWidget, &w2)));
    fm.endFrame();

    // Focus the first widget — the trait should flip its flag.
    fm.focusWidget("a");
    try std.testing.expect(fm.isFocusedByName("a"));
    try std.testing.expect(w1.focused);
    try std.testing.expect(!w2.focused);

    // Move focus to the second — w1 must blur, w2 must focus.
    fm.focusWidget("b");
    try std.testing.expect(fm.isFocusedByName("b"));
    try std.testing.expect(!w1.focused);
    try std.testing.expect(w2.focused);

    // `blur()` clears the focused widget through the trait — no walk
    // over per-type widget maps required.
    fm.blur();
    try std.testing.expect(!fm.hasFocus());
    try std.testing.expect(!w1.focused);
    try std.testing.expect(!w2.focused);
}

test "FocusManager.focus is a no-op for the same id" {
    const FakeWidget = struct {
        focused: bool = false,
        focus_calls: u32 = 0,
        blur_calls: u32 = 0,
        pub fn focus(self: *@This()) void {
            self.focused = true;
            self.focus_calls += 1;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
            self.blur_calls += 1;
        }
        pub fn isFocused(self: *@This()) bool {
            return self.focused;
        }
    };

    const allocator = std.testing.allocator;
    var fm = FocusManager.init(allocator);
    defer fm.deinit();

    var w: FakeWidget = .{};
    fm.beginFrame();
    fm.register(FocusHandle.init("a")
        .withWidget(Focusable.fromInstance(FakeWidget, &w)));
    fm.endFrame();

    fm.focusWidget("a");
    try std.testing.expectEqual(@as(u32, 1), w.focus_calls);
    try std.testing.expectEqual(@as(u32, 0), w.blur_calls);

    // Re-focusing the same id must not re-fire the vtable.
    fm.focusWidget("a");
    try std.testing.expectEqual(@as(u32, 1), w.focus_calls);
    try std.testing.expectEqual(@as(u32, 0), w.blur_calls);
}
