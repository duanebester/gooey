//! Mock clipboard for testing
//!
//! Stores clipboard content in memory without platform dependencies.
//! Use this to test copy/paste functionality in isolation.
//!
//! Example:
//! ```zig
//! var clipboard = MockClipboard.init(std.testing.allocator);
//! defer clipboard.deinit();
//!
//! try std.testing.expect(clipboard.setText("Hello"));
//! const text = clipboard.getText(std.testing.allocator);
//! defer if (text) |t| std.testing.allocator.free(t);
//!
//! try std.testing.expectEqualStrings("Hello", text.?);
//! try std.testing.expectEqual(@as(u32, 1), clipboard.set_count);
//! ```

const std = @import("std");
const interface_verify = @import("../core/interface_verify.zig");

pub const MockClipboard = struct {
    // =========================================================================
    // Internal State
    // =========================================================================

    content: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    // =========================================================================
    // Call Tracking
    // =========================================================================

    get_count: u32 = 0,
    set_count: u32 = 0,
    has_text_count: u32 = 0,

    // =========================================================================
    // Controllable Behavior
    // =========================================================================

    should_fail_get: bool = false,
    should_fail_set: bool = false,

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.content) |c| {
            self.allocator.free(c);
        }
        self.* = undefined;
    }

    // =========================================================================
    // Clipboard Interface
    // =========================================================================

    /// Get text from clipboard.
    /// Caller owns the returned slice and must free it.
    pub fn getText(self: *Self, allocator: std.mem.Allocator) ?[]const u8 {
        self.get_count += 1;

        if (self.should_fail_get) {
            return null;
        }

        if (self.content) |c| {
            return allocator.dupe(u8, c) catch null;
        }

        return null;
    }

    /// Set text to clipboard.
    /// Returns true on success, false on failure.
    pub fn setText(self: *Self, text: []const u8) bool {
        self.set_count += 1;

        if (self.should_fail_set) {
            return false;
        }

        // Free old content
        if (self.content) |old| {
            self.allocator.free(old);
        }

        // Store new content
        self.content = self.allocator.dupe(u8, text) catch {
            self.content = null;
            return false;
        };

        return true;
    }

    /// Check if clipboard has text content.
    pub fn hasText(self: *Self) bool {
        self.has_text_count += 1;
        return self.content != null;
    }

    // =========================================================================
    // Test Utilities
    // =========================================================================

    /// Reset all counters and state (for test isolation)
    pub fn reset(self: *Self) void {
        if (self.content) |c| {
            self.allocator.free(c);
        }
        self.content = null;
        self.get_count = 0;
        self.set_count = 0;
        self.has_text_count = 0;
        self.should_fail_get = false;
        self.should_fail_set = false;
    }

    /// Set content directly without going through setText (for test setup)
    pub fn setContentDirect(self: *Self, text: []const u8) !void {
        if (self.content) |old| {
            self.allocator.free(old);
        }
        self.content = try self.allocator.dupe(u8, text);
    }

    /// Get content directly without tracking (for test verification)
    pub fn getContentDirect(self: *const Self) ?[]const u8 {
        return self.content;
    }

    // =========================================================================
    // Interface Verification
    // =========================================================================

    comptime {
        interface_verify.verifyClipboardInterface(@This());
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MockClipboard set and get" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    try std.testing.expect(clipboard.setText("Hello, World!"));
    try std.testing.expectEqual(@as(u32, 1), clipboard.set_count);

    const text = clipboard.getText(std.testing.allocator);
    defer if (text) |t| std.testing.allocator.free(t);

    try std.testing.expectEqual(@as(u32, 1), clipboard.get_count);
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("Hello, World!", text.?);
}

test "MockClipboard returns null when empty" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    const text = clipboard.getText(std.testing.allocator);
    try std.testing.expect(text == null);
    try std.testing.expectEqual(@as(u32, 1), clipboard.get_count);
}

test "MockClipboard hasText" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    try std.testing.expect(!clipboard.hasText());

    _ = clipboard.setText("test");
    try std.testing.expect(clipboard.hasText());

    try std.testing.expectEqual(@as(u32, 2), clipboard.has_text_count);
}

test "MockClipboard can simulate get failure" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    _ = clipboard.setText("content");
    clipboard.should_fail_get = true;

    const text = clipboard.getText(std.testing.allocator);
    try std.testing.expect(text == null);
}

test "MockClipboard can simulate set failure" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    clipboard.should_fail_set = true;
    try std.testing.expect(!clipboard.setText("will fail"));
    try std.testing.expect(!clipboard.hasText());
}

test "MockClipboard overwrites previous content" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    _ = clipboard.setText("first");
    _ = clipboard.setText("second");

    const text = clipboard.getText(std.testing.allocator);
    defer if (text) |t| std.testing.allocator.free(t);

    try std.testing.expectEqualStrings("second", text.?);
    try std.testing.expectEqual(@as(u32, 2), clipboard.set_count);
}

test "MockClipboard reset clears state" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    _ = clipboard.setText("content");
    const text = clipboard.getText(std.testing.allocator);
    if (text) |t| std.testing.allocator.free(t);
    clipboard.should_fail_get = true;

    clipboard.reset();

    try std.testing.expectEqual(@as(u32, 0), clipboard.get_count);
    try std.testing.expectEqual(@as(u32, 0), clipboard.set_count);
    try std.testing.expect(!clipboard.hasText());
    try std.testing.expect(!clipboard.should_fail_get);
}

test "MockClipboard direct access for test setup" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    // Set directly (doesn't increment set_count)
    try clipboard.setContentDirect("preset content");
    try std.testing.expectEqual(@as(u32, 0), clipboard.set_count);

    // Verify directly (doesn't increment get_count)
    try std.testing.expectEqualStrings("preset content", clipboard.getContentDirect().?);
    try std.testing.expectEqual(@as(u32, 0), clipboard.get_count);
}

test "MockClipboard handles empty string" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    _ = clipboard.setText("");

    const text = clipboard.getText(std.testing.allocator);
    defer if (text) |t| std.testing.allocator.free(t);

    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("", text.?);
}

test "MockClipboard handles unicode" {
    var clipboard = MockClipboard.init(std.testing.allocator);
    defer clipboard.deinit();

    const unicode_text = "Hello 🎉 World 日本語";
    _ = clipboard.setText(unicode_text);

    const text = clipboard.getText(std.testing.allocator);
    defer if (text) |t| std.testing.allocator.free(t);

    try std.testing.expectEqualStrings(unicode_text, text.?);
}
