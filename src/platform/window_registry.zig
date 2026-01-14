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
//! ## Usage
//!
//! ```zig
//! var registry = WindowRegistry.init(allocator);
//! defer registry.deinit();
//!
//! const id = registry.register(window);
//! const maybe_window = registry.get(id);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

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
        return @intFromEnum(self);
    }

    /// Create a WindowId from a raw value.
    /// Asserts the value is not the invalid sentinel.
    pub fn fromRaw(value: u32) WindowId {
        std.debug.assert(value != 0); // Cannot create invalid ID via fromRaw
        return @enumFromInt(value);
    }
};

// =============================================================================
// WindowRegistry
// =============================================================================

/// Central registry for tracking windows by ID.
///
/// Provides O(1) lookup of windows by ID, and tracks the currently active window.
/// Thread-safe considerations: This registry is NOT thread-safe. All access should
/// be from the main thread (where window operations occur).
pub const WindowRegistry = struct {
    /// Allocator for internal data structures
    allocator: Allocator,

    /// Map from WindowId to window pointer (stored as opaque for platform independence)
    windows: std.AutoHashMap(WindowId, *anyopaque),

    /// Next ID to assign (monotonically increasing)
    next_id: u32 = 1,

    /// Currently focused/active window (null if none)
    active_window: ?WindowId = null,

    /// Maximum number of windows allowed (per CLAUDE.md: "put a limit on everything")
    pub const MAX_WINDOWS: u32 = 32;

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Initialize a new WindowRegistry.
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .windows = std.AutoHashMap(WindowId, *anyopaque).init(allocator),
        };
    }

    /// Clean up registry resources.
    /// Note: Does NOT destroy the windows themselves - caller is responsible.
    pub fn deinit(self: *Self) void {
        // Assertions: validate state
        std.debug.assert(self.next_id >= 1); // next_id should never wrap to 0

        self.windows.deinit();
        self.* = undefined;
    }

    // =========================================================================
    // Registration
    // =========================================================================

    /// Register a window and return its assigned ID.
    ///
    /// The window pointer is stored as opaque to avoid coupling the registry
    /// to a specific Window type (enables cross-platform use).
    pub fn register(self: *Self, window_ptr: *anyopaque) !WindowId {
        // Assertions: validate inputs and limits
        std.debug.assert(@intFromPtr(window_ptr) != 0);
        std.debug.assert(self.windows.count() < MAX_WINDOWS); // Hard limit

        // Generate next ID
        const id: WindowId = @enumFromInt(self.next_id);
        std.debug.assert(id.isValid()); // Sanity check

        self.next_id += 1;

        // Prevent wraparound (would take billions of window creations)
        if (self.next_id == 0) {
            self.next_id = 1; // Skip invalid sentinel
        }

        // Store in registry
        try self.windows.put(id, window_ptr);

        // Set as active if this is the first window
        if (self.active_window == null) {
            self.active_window = id;
        }

        return id;
    }

    /// Unregister a window by ID.
    /// Returns the window pointer if found, null otherwise.
    pub fn unregister(self: *Self, id: WindowId) ?*anyopaque {
        // Assertions: validate input
        std.debug.assert(id.isValid());

        const result = self.windows.fetchRemove(id);

        // Clear active window if it was this one
        if (self.active_window) |active| {
            if (active == id) {
                self.active_window = null;
            }
        }

        if (result) |kv| {
            return kv.value;
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
        return self.windows.get(id);
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
        return self.windows.contains(id);
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
        return @intCast(self.windows.count());
    }

    /// Iterate over all registered window IDs.
    pub fn iterator(self: *const Self) std.AutoHashMap(WindowId, *anyopaque).KeyIterator {
        return self.windows.keyIterator();
    }
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
    var registry = WindowRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var dummy1: u32 = 1;
    var dummy2: u32 = 2;

    const id1 = try registry.register(&dummy1);
    const id2 = try registry.register(&dummy2);

    // Assertions: IDs should be unique and valid
    std.debug.assert(id1.isValid());
    std.debug.assert(id2.isValid());
    std.debug.assert(id1 != id2);

    // Lookup should return correct pointers
    const ptr1 = registry.getTyped(u32, id1);
    const ptr2 = registry.getTyped(u32, id2);

    std.debug.assert(ptr1 != null);
    std.debug.assert(ptr2 != null);
    std.debug.assert(ptr1.?.* == 1);
    std.debug.assert(ptr2.?.* == 2);
}

test "WindowRegistry - unregister" {
    var registry = WindowRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var dummy: u32 = 42;
    const id = try registry.register(&dummy);

    std.debug.assert(registry.contains(id));
    std.debug.assert(registry.count() == 1);

    _ = registry.unregister(id);

    std.debug.assert(!registry.contains(id));
    std.debug.assert(registry.count() == 0);
    std.debug.assert(registry.get(id) == null);
}

test "WindowRegistry - active window tracking" {
    var registry = WindowRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var dummy1: u32 = 1;
    var dummy2: u32 = 2;

    // First window becomes active automatically
    const id1 = try registry.register(&dummy1);
    std.debug.assert(registry.getActiveWindow().? == id1);

    // Second window doesn't change active
    const id2 = try registry.register(&dummy2);
    std.debug.assert(registry.getActiveWindow().? == id1);

    // Can change active manually
    registry.setActiveWindow(id2);
    std.debug.assert(registry.getActiveWindow().? == id2);

    // Unregistering active window clears it
    _ = registry.unregister(id2);
    std.debug.assert(registry.getActiveWindow() == null);
}

test "WindowRegistry - count limit constant" {
    // Verify MAX_WINDOWS is a reasonable limit
    std.debug.assert(WindowRegistry.MAX_WINDOWS >= 1);
    std.debug.assert(WindowRegistry.MAX_WINDOWS <= 256);
}
