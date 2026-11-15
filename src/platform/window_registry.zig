//! WindowId & WindowRegistry - Cross-window reference tracking
//!
//! This module provides:
//! - `WindowId`: A unique identifier for windows (enum-based for type safety)
//! - `WindowRegistry`: A centralized registry for tracking windows by ID
//!
//! ## Design Rationale
//!
//! Using `WindowId` instead of raw pointers:
//! - Type-safe: can't accidentally pass wrong pointer type
//! - Stable: IDs don't change if window moves in memory
//! - Validatable: can check if ID is valid before dereferencing
//! - Cross-platform: same ID type works on all backends
//!
//! ## Capacity
//!
//! An app opens one window (contract decision 14), so the registry holds
//! `limits.window_count_max` slots in place and never allocates.
//!
//! ## Usage
//!
//! ```zig
//! var registry: WindowRegistry = .init();
//! const id = try registry.register(window);
//! const maybe_window = registry.get(id);
//! ```

const std = @import("std");
const limits = @import("../core/limits.zig");

// =============================================================================
// WindowId
// =============================================================================

/// Unique identifier for windows.
///
/// Uses enum(u32) for type safety - can't accidentally mix up with other IDs.
/// The `.invalid` sentinel is always 0, making null checks explicit.
pub const WindowId = enum(u32) {
    /// Sentinel value indicating no window / invalid ID
    invalid = 0,
    /// Allow any other u32 value as a valid ID
    _,

    /// Check if this ID represents a valid window.
    pub fn isValid(self: WindowId) bool {
        return self != .invalid;
    }

    /// Get the raw numeric value (for debugging/logging).
    pub fn raw(self: WindowId) u32 {
        return @backingInt(self);
    }

    /// Create a WindowId from a raw value.
    /// Asserts the value is not the invalid sentinel.
    pub fn fromRaw(value: u32) WindowId {
        std.debug.assert(value != 0); // Cannot create invalid ID via fromRaw
        return @fromBackingInt(@intCast(value));
    }
};

// =============================================================================
// WindowRegistry
// =============================================================================

/// Central registry for tracking windows by ID.
///
/// Holds `window_count_max` slots in place, so registration never allocates
/// and lookup scans at most that many. Thread-safe considerations: This
/// registry is NOT thread-safe. All access should be from the main thread
/// (where window operations occur).
pub const WindowRegistry = struct {
    /// Registered windows; `.invalid` marks a free slot.
    ids: [window_count_max]WindowId,
    /// Window pointers, stored as opaque for platform independence.
    pointers: [window_count_max]*anyopaque,
    window_count: u32,

    /// Next ID to assign (monotonically increasing)
    next_id: u32,

    /// Currently focused/active window (null if none)
    active_window: ?WindowId,

    pub const window_count_max: u32 = limits.window_count_max;

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init() Self {
        return .{
            .ids = @splat(.invalid),
            .pointers = undefined,
            .window_count = 0,
            .next_id = 1,
            .active_window = null,
        };
    }

    // =========================================================================
    // Registration
    // =========================================================================

    /// Register a window and return its assigned ID. A window past
    /// `window_count_max` is refused: the app opens one (decision 14).
    ///
    /// The window pointer is stored as opaque to avoid coupling the registry
    /// to a specific Window type (enables cross-platform use).
    pub fn register(self: *Self, window_ptr: *anyopaque) error{TooManyWindows}!WindowId {
        std.debug.assert(@intFromPtr(window_ptr) != 0);
        std.debug.assert(self.window_count <= window_count_max);
        if (self.window_count == window_count_max) return error.TooManyWindows;
        const slot = self.slotOf(.invalid).?;
        const id: WindowId = @fromBackingInt(self.next_id);
        std.debug.assert(id.isValid());
        // Skip the invalid sentinel on wraparound (billions of creations).
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        self.ids[slot] = id;
        self.pointers[slot] = window_ptr;
        self.window_count += 1;

        // Registration deliberately does NOT elect an active window.
        //
        // Auto-activating the first registered window would make focus policy
        // an invisible side effect of registration, and backends that also
        // publish focus explicitly would disagree about which window
        // `getActiveWindowId` names for the same program. Each backend calls
        // `setActiveWindowId` itself, so the policy is one readable line per
        // backend and the registry stays a pure map.
        return id;
    }

    /// Unregister a window by ID.
    /// Returns the window pointer if found, null otherwise.
    pub fn unregister(self: *Self, id: WindowId) ?*anyopaque {
        std.debug.assert(id.isValid());
        std.debug.assert(self.window_count <= window_count_max);

        // Clear active window if it was this one
        if (self.active_window) |active| {
            if (active == id) self.active_window = null;
        }
        const slot = self.slotOf(id) orelse return null;
        self.ids[slot] = .invalid;
        self.window_count -= 1;
        return self.pointers[slot];
    }

    /// The slot holding `id`, or the first free slot for `.invalid`.
    fn slotOf(self: *const Self, id: WindowId) ?u32 {
        for (self.ids, 0..) |slot_id, slot| {
            if (slot_id == id) return @intCast(slot);
        }
        return null;
    }

    // =========================================================================
    // Lookup
    // =========================================================================

    /// Get a window pointer by ID.
    /// Returns null if the ID is invalid or not registered.
    pub fn get(self: *const Self, id: WindowId) ?*anyopaque {
        if (!id.isValid()) return null;
        const slot = self.slotOf(id) orelse return null;
        return self.pointers[slot];
    }

    /// Get a typed window pointer by ID.
    /// Convenience method that casts the opaque pointer to the expected type.
    pub fn getTyped(self: *const Self, comptime T: type, id: WindowId) ?*T {
        // Assertions: T must be a pointer-compatible type
        comptime std.debug.assert(@sizeOf(T) > 0);

        if (self.get(id)) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    /// Check if a window ID is registered.
    pub fn contains(self: *const Self, id: WindowId) bool {
        if (!id.isValid()) return false;
        return self.slotOf(id) != null;
    }

    // =========================================================================
    // Active Window
    // =========================================================================

    /// Set the active/focused window.
    pub fn setActiveWindow(self: *Self, id: ?WindowId) void {
        // Assertions: if id is provided, it should be valid and registered
        if (id) |window_id| {
            std.debug.assert(window_id.isValid());
            std.debug.assert(self.contains(window_id));
        }
        self.active_window = id;
    }

    /// Get the currently active window ID.
    pub fn getActiveWindow(self: *const Self) ?WindowId {
        return self.active_window;
    }

    /// Get the active window pointer (typed).
    pub fn getActiveWindowTyped(self: *const Self, comptime T: type) ?*T {
        if (self.active_window) |id| {
            return self.getTyped(T, id);
        }
        return null;
    }

    // =========================================================================
    // Iteration
    // =========================================================================

    /// Get the number of registered windows.
    pub fn count(self: *const Self) u32 {
        std.debug.assert(self.window_count <= window_count_max);
        return self.window_count;
    }

    /// Iterate over all registered window IDs.
    pub fn iterator(self: *const Self) Iterator {
        return .{ .registry = self, .slot = 0 };
    }

    pub const Iterator = struct {
        registry: *const Self,
        slot: u32,

        pub fn next(self: *Iterator) ?*const WindowId {
            while (self.slot < window_count_max) {
                const id = &self.registry.ids[self.slot];
                self.slot += 1;
                if (id.isValid()) return id;
            }
            return null;
        }
    };
};

// =============================================================================
// Tests
// =============================================================================

test "WindowId - basic operations" {
    const invalid = WindowId.invalid;
    std.debug.assert(!invalid.isValid());
    std.debug.assert(invalid.raw() == 0);

    const valid = WindowId.fromRaw(42);
    std.debug.assert(valid.isValid());
    std.debug.assert(valid.raw() == 42);
}

test "WindowRegistry - register and lookup" {
    var registry: WindowRegistry = .init();
    var dummy: u32 = 1;
    const id = try registry.register(&dummy);
    try std.testing.expect(id.isValid());
    try std.testing.expectEqual(@as(u32, 1), registry.getTyped(u32, id).?.*);
    try std.testing.expectEqual(@as(?*anyopaque, null), registry.get(WindowId.fromRaw(99)));
    var ids = registry.iterator();
    try std.testing.expectEqual(id, ids.next().?.*);
    try std.testing.expect(ids.next() == null);
}

test "WindowRegistry - holds window_count_max windows, then refuses one more" {
    // Goal: the registry is full at exactly `window_count_max` windows, the
    // next registration is refused without changing it, and a freed slot is
    // reused under a fresh id.
    var registry: WindowRegistry = .init();
    var dummies: [WindowRegistry.window_count_max + 1]u32 = @splat(0);
    var ids: [WindowRegistry.window_count_max]WindowId = undefined;
    for (&ids, dummies[0..ids.len]) |*id, *dummy| id.* = try registry.register(dummy);
    try std.testing.expectEqual(WindowRegistry.window_count_max, registry.count());
    const extra = &dummies[dummies.len - 1];
    try std.testing.expectError(error.TooManyWindows, registry.register(extra));
    try std.testing.expectEqual(WindowRegistry.window_count_max, registry.count());

    _ = registry.unregister(ids[0]);
    try std.testing.expect(!registry.contains(ids[0]));
    const again = try registry.register(extra);
    try std.testing.expect(again != ids[0]);
    try std.testing.expectEqual(@as(*anyopaque, extra), registry.get(again).?);
}

test "WindowRegistry - registration does not elect an active window" {
    // Focus policy belongs to the backend, not to registration. Electing here
    // would make registration silently change focus, and the backends would
    // disagree about which window is active. Registration must leave the
    // active slot untouched.
    var registry: WindowRegistry = .init();
    var dummy: u32 = 1;
    const id = try registry.register(&dummy);
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());

    // Only an explicit call elects.
    registry.setActiveWindow(id);
    try std.testing.expectEqual(id, registry.getActiveWindow().?);
}

test "WindowRegistry - unregistering the active window clears the slot" {
    // Negative space: a stale active id must never outlive its window, or a
    // later lookup would resolve focus to a freed pointer.
    var registry: WindowRegistry = .init();
    var dummy: u32 = 7;
    const id = try registry.register(&dummy);
    registry.setActiveWindow(id);
    try std.testing.expectEqual(id, registry.getActiveWindow().?);

    try std.testing.expectEqual(@as(?*anyopaque, &dummy), registry.unregister(id));
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());
    try std.testing.expectEqual(@as(u32, 0), registry.count());
    try std.testing.expectEqual(@as(?*anyopaque, null), registry.unregister(id));

    // Clearing explicitly is also valid from the empty state.
    registry.setActiveWindow(null);
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());
}
