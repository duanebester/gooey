//! Mock file dialog for testing
//!
//! Simulates file open/save dialogs without platform dependencies.
//! Use this to test file selection workflows in isolation.
//!
//! Example:
//! ```zig
//! var dialog = MockFileDialog.init(std.testing.allocator);
//! defer dialog.deinit();
//!
//! // Configure expected response
//! try dialog.setOpenResponse(&.{"/path/to/file.txt"});
//!
//! // Use in test
//! const result = dialog.promptForPaths(std.testing.allocator, .{});
//! defer if (result) |r| r.deinit();
//!
//! try std.testing.expect(result != null);
//! try std.testing.expectEqual(@as(u32, 1), dialog.open_count);
//! ```

const std = @import("std");
const interface_mod = @import("../platform/interface.zig");
const interface_verify = @import("../core/interface_verify.zig");

// =============================================================================
// Types (re-exported from interface)
// =============================================================================

pub const PathPromptOptions = interface_mod.PathPromptOptions;
pub const PathPromptResult = interface_mod.PathPromptResult;
pub const SavePromptOptions = interface_mod.SavePromptOptions;

// =============================================================================
// Mock Implementation
// =============================================================================

pub const MockFileDialog = struct {
    // =========================================================================
    // Call Tracking
    // =========================================================================

    open_count: u32 = 0,
    save_count: u32 = 0,

    // =========================================================================
    // Last Values (for verification)
    // =========================================================================

    last_open_options: ?PathPromptOptions = null,
    last_save_options: ?SavePromptOptions = null,

    // =========================================================================
    // Configurable Responses
    // =========================================================================

    /// Paths to return from promptForPaths (null = user cancelled)
    open_response_paths: ?[]const []const u8 = null,

    /// Path to return from promptForNewPath (null = user cancelled)
    save_response_path: ?[]const u8 = null,

    /// Simulate user cancellation
    should_cancel_open: bool = false,
    should_cancel_save: bool = false,

    /// Sequence of responses for multiple calls (advanced testing)
    open_response_sequence: ?[]const ?[]const []const u8 = null,
    save_response_sequence: ?[]const ?[]const u8 = null,
    sequence_index: usize = 0,

    // =========================================================================
    // Internal State
    // =========================================================================

    allocator: std.mem.Allocator,

    /// Stored paths that need cleanup
    stored_open_paths: std.ArrayListUnmanaged([]const u8) = .{},
    stored_save_path: ?[]const u8 = null,

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .stored_open_paths = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        // Free stored paths
        for (self.stored_open_paths.items) |path| {
            self.allocator.free(path);
        }
        self.stored_open_paths.deinit(self.allocator);

        if (self.stored_save_path) |path| {
            self.allocator.free(path);
        }

        self.* = undefined;
    }

    // =========================================================================
    // Configuration Methods
    // =========================================================================

    /// Set paths to return from next promptForPaths call
    pub fn setOpenResponse(self: *Self, paths: []const []const u8) !void {
        // Clear previous stored paths
        for (self.stored_open_paths.items) |path| {
            self.allocator.free(path);
        }
        self.stored_open_paths.clearRetainingCapacity();

        // Store copies
        for (paths) |path| {
            const copy = try self.allocator.dupe(u8, path);
            try self.stored_open_paths.append(self.allocator, copy);
        }

        self.open_response_paths = self.stored_open_paths.items;
        self.should_cancel_open = false;
    }

    /// Set path to return from next promptForNewPath call
    pub fn setSaveResponse(self: *Self, path: []const u8) !void {
        if (self.stored_save_path) |old| {
            self.allocator.free(old);
        }

        self.stored_save_path = try self.allocator.dupe(u8, path);
        self.save_response_path = self.stored_save_path;
        self.should_cancel_save = false;
    }

    /// Configure to simulate user cancelling open dialog
    pub fn setCancelOpen(self: *Self) void {
        self.should_cancel_open = true;
        self.open_response_paths = null;
    }

    /// Configure to simulate user cancelling save dialog
    pub fn setCancelSave(self: *Self) void {
        self.should_cancel_save = true;
        self.save_response_path = null;
    }

    // =========================================================================
    // File Dialog Interface
    // =========================================================================

    /// Show a file/directory open dialog (mock implementation)
    /// Returns null if configured to cancel or on error.
    /// Caller owns returned PathPromptResult and must call deinit().
    pub fn promptForPaths(
        self: *Self,
        allocator: std.mem.Allocator,
        options: PathPromptOptions,
    ) ?PathPromptResult {
        self.open_count += 1;
        self.last_open_options = options;

        // Check for sequence-based response
        if (self.open_response_sequence) |seq| {
            if (self.sequence_index < seq.len) {
                const response = seq[self.sequence_index];
                self.sequence_index += 1;

                if (response) |paths| {
                    return self.createPathResult(allocator, paths);
                }
                return null;
            }
        }

        // Check for cancellation
        if (self.should_cancel_open) {
            return null;
        }

        // Return configured response
        if (self.open_response_paths) |paths| {
            return self.createPathResult(allocator, paths);
        }

        return null;
    }

    /// Show a file save dialog (mock implementation)
    /// Returns null if configured to cancel or on error.
    /// Caller owns returned path and must free with allocator.
    pub fn promptForNewPath(
        self: *Self,
        allocator: std.mem.Allocator,
        options: SavePromptOptions,
    ) ?[]const u8 {
        self.save_count += 1;
        self.last_save_options = options;

        // Check for sequence-based response
        if (self.save_response_sequence) |seq| {
            if (self.sequence_index < seq.len) {
                const response = seq[self.sequence_index];
                self.sequence_index += 1;

                if (response) |path| {
                    return allocator.dupe(u8, path) catch null;
                }
                return null;
            }
        }

        // Check for cancellation
        if (self.should_cancel_save) {
            return null;
        }

        // Return configured response
        if (self.save_response_path) |path| {
            return allocator.dupe(u8, path) catch null;
        }

        return null;
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    fn createPathResult(
        self: *Self,
        allocator: std.mem.Allocator,
        paths: []const []const u8,
    ) ?PathPromptResult {
        _ = self;

        if (paths.len == 0) {
            return null;
        }

        // Allocate result paths
        const result_paths = allocator.alloc([]const u8, paths.len) catch return null;
        var valid_count: usize = 0;

        for (paths) |path| {
            result_paths[valid_count] = allocator.dupe(u8, path) catch {
                // Cleanup on failure
                for (result_paths[0..valid_count]) |p| {
                    allocator.free(p);
                }
                allocator.free(result_paths);
                return null;
            };
            valid_count += 1;
        }

        return PathPromptResult{
            .paths = result_paths,
            .allocator = allocator,
        };
    }

    // =========================================================================
    // Test Utilities
    // =========================================================================

    /// Reset all counters and state (for test isolation)
    pub fn reset(self: *Self) void {
        self.open_count = 0;
        self.save_count = 0;
        self.last_open_options = null;
        self.last_save_options = null;
        self.should_cancel_open = false;
        self.should_cancel_save = false;
        self.sequence_index = 0;

        // Clear stored paths
        for (self.stored_open_paths.items) |path| {
            self.allocator.free(path);
        }
        self.stored_open_paths.clearRetainingCapacity();

        if (self.stored_save_path) |path| {
            self.allocator.free(path);
            self.stored_save_path = null;
        }

        self.open_response_paths = null;
        self.save_response_path = null;
        self.open_response_sequence = null;
        self.save_response_sequence = null;
    }

    /// Get total dialog invocations
    pub fn totalCalls(self: *const Self) u32 {
        return self.open_count + self.save_count;
    }

    /// Check if last open dialog allowed directories
    pub fn lastOpenAllowedDirectories(self: *const Self) bool {
        if (self.last_open_options) |opts| {
            return opts.directories;
        }
        return false;
    }

    /// Check if last open dialog allowed multiple selection
    pub fn lastOpenAllowedMultiple(self: *const Self) bool {
        if (self.last_open_options) |opts| {
            return opts.multiple;
        }
        return false;
    }

    /// Get last save suggested filename
    pub fn lastSaveSuggestedName(self: *const Self) ?[]const u8 {
        if (self.last_save_options) |opts| {
            return opts.suggested_name;
        }
        return null;
    }

    // =========================================================================
    // Interface Verification
    // =========================================================================

    comptime {
        interface_verify.verifyFileDialogInterface(@This());
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MockFileDialog open returns configured paths" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    try dialog.setOpenResponse(&.{ "/path/to/file1.txt", "/path/to/file2.txt" });

    const result = dialog.promptForPaths(std.testing.allocator, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.?.paths.len);
    try std.testing.expectEqualStrings("/path/to/file1.txt", result.?.paths[0]);
    try std.testing.expectEqualStrings("/path/to/file2.txt", result.?.paths[1]);
    try std.testing.expectEqual(@as(u32, 1), dialog.open_count);
}

test "MockFileDialog open returns null when cancelled" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    dialog.setCancelOpen();

    const result = dialog.promptForPaths(std.testing.allocator, .{});
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), dialog.open_count);
}

test "MockFileDialog save returns configured path" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    try dialog.setSaveResponse("/path/to/saved.txt");

    const result = dialog.promptForNewPath(std.testing.allocator, .{});
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);

    try std.testing.expectEqualStrings("/path/to/saved.txt", result.?);
    try std.testing.expectEqual(@as(u32, 1), dialog.save_count);
}

test "MockFileDialog save returns null when cancelled" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    dialog.setCancelSave();

    const result = dialog.promptForNewPath(std.testing.allocator, .{});
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), dialog.save_count);
}

test "MockFileDialog tracks options" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    _ = dialog.promptForPaths(std.testing.allocator, .{
        .directories = true,
        .multiple = true,
        .prompt = "Select Folder",
    });

    try std.testing.expect(dialog.lastOpenAllowedDirectories());
    try std.testing.expect(dialog.lastOpenAllowedMultiple());
    try std.testing.expectEqualStrings("Select Folder", dialog.last_open_options.?.prompt.?);
}

test "MockFileDialog tracks save options" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    _ = dialog.promptForNewPath(std.testing.allocator, .{
        .suggested_name = "document.txt",
        .directory = "/home/user",
    });

    try std.testing.expectEqualStrings("document.txt", dialog.lastSaveSuggestedName().?);
    try std.testing.expectEqualStrings("/home/user", dialog.last_save_options.?.directory.?);
}

test "MockFileDialog reset clears state" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    try dialog.setOpenResponse(&.{"/test"});
    const open_result = dialog.promptForPaths(std.testing.allocator, .{});
    if (open_result) |r| r.deinit();
    const save_result = dialog.promptForNewPath(std.testing.allocator, .{});
    if (save_result) |r| std.testing.allocator.free(r);

    dialog.reset();

    try std.testing.expectEqual(@as(u32, 0), dialog.open_count);
    try std.testing.expectEqual(@as(u32, 0), dialog.save_count);
    try std.testing.expect(dialog.last_open_options == null);
    try std.testing.expect(dialog.open_response_paths == null);
}

test "MockFileDialog multiple calls" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    try dialog.setOpenResponse(&.{"/file.txt"});

    // Multiple calls return same configured response
    const r1 = dialog.promptForPaths(std.testing.allocator, .{});
    defer if (r1) |r| r.deinit();

    const r2 = dialog.promptForPaths(std.testing.allocator, .{});
    defer if (r2) |r| r.deinit();

    try std.testing.expectEqual(@as(u32, 2), dialog.open_count);
    try std.testing.expect(r1 != null);
    try std.testing.expect(r2 != null);
}

test "MockFileDialog totalCalls" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    _ = dialog.promptForPaths(std.testing.allocator, .{});
    _ = dialog.promptForPaths(std.testing.allocator, .{});
    _ = dialog.promptForNewPath(std.testing.allocator, .{});

    try std.testing.expectEqual(@as(u32, 3), dialog.totalCalls());
}

test "MockFileDialog empty response" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    // No response configured - should return null
    const result = dialog.promptForPaths(std.testing.allocator, .{});
    try std.testing.expect(result == null);
}

test "MockFileDialog single file" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    try dialog.setOpenResponse(&.{"/single/file.txt"});

    const result = dialog.promptForPaths(std.testing.allocator, .{ .multiple = false });
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.?.paths.len);
}

test "MockFileDialog allowed extensions in options" {
    var dialog = MockFileDialog.init(std.testing.allocator);
    defer dialog.deinit();

    const extensions = &[_][]const u8{ "txt", "md", "rst" };
    _ = dialog.promptForPaths(std.testing.allocator, .{
        .allowed_extensions = extensions,
    });

    try std.testing.expect(dialog.last_open_options.?.allowed_extensions != null);
    try std.testing.expectEqual(@as(usize, 3), dialog.last_open_options.?.allowed_extensions.?.len);
}
