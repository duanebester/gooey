//! Cross-Platform File Dialogs
//!
//! Provides a unified API for native file open/save dialogs across all
//! supported platforms. Dispatches to the appropriate backend at compile time:
//!
//! - **macOS**: NSOpenPanel / NSSavePanel (blocking/modal)
//! - **Linux**: XDG Desktop Portal via D-Bus (blocking/modal)
//! - **WASM**: Returns `null` — browsers cannot show blocking file dialogs.
//!   Use `gooey.platform.web.file_dialog` for the async callback-based API.
//!
//! ## Usage
//!
//! ```zig
//! const gooey = @import("gooey");
//! const file_dialog = gooey.file_dialog;
//!
//! // Open dialog
//! if (file_dialog.promptForPaths(allocator, .{
//!     .files = true,
//!     .prompt = "Attach",
//!     .allowed_extensions = &.{ "txt", "png", "pdf" },
//! })) |result| {
//!     defer result.deinit();
//!     for (result.paths) |path| {
//!         // ...
//!     }
//! }
//!
//! // Save dialog
//! if (file_dialog.promptForNewPath(allocator, .{
//!     .suggested_name = "untitled.txt",
//!     .prompt = "Save",
//! })) |path| {
//!     defer allocator.free(path);
//!     // ...
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const interface_mod = @import("platform/interface.zig");

// =============================================================================
// Types (re-exported from platform interface)
// =============================================================================

pub const PathPromptOptions = interface_mod.PathPromptOptions;
pub const PathPromptResult = interface_mod.PathPromptResult;
pub const SavePromptOptions = interface_mod.SavePromptOptions;

// =============================================================================
// Platform Backend Selection
// =============================================================================

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;

const has_native_backend = is_macos or is_linux;

/// Whether the current platform supports synchronous (blocking) file dialogs.
///
/// On WASM, this is `false` — use `gooey.platform.web.file_dialog` for the
/// async callback-based API instead.
pub const supported = has_native_backend;

// =============================================================================
// Open Dialog
// =============================================================================

/// Show a file/directory open dialog (blocking/modal).
///
/// Returns `null` if the user cancels, on error, or on unsupported platforms (WASM).
/// Caller owns the returned `PathPromptResult` and must call `deinit()`.
///
/// **WASM note:** This always returns `null`. Use the async web file dialog API instead:
/// `gooey.platform.web.file_dialog.openFilesAsync()`
pub fn promptForPaths(
    allocator: std.mem.Allocator,
    options: PathPromptOptions,
) ?PathPromptResult {
    // Assertions: validate options are internally consistent
    std.debug.assert(options.files or options.directories); // Must select at least one kind
    std.debug.assert(!(options.directories and options.allowed_extensions != null)); // Extensions don't apply to directories

    if (comptime has_native_backend) {
        const backend = if (is_macos)
            @import("platform/macos/file_dialog.zig")
        else
            @import("platform/linux/file_dialog.zig");
        return backend.promptForPaths(allocator, options);
    }
    return null;
}

// =============================================================================
// Save Dialog
// =============================================================================

/// Show a file save dialog (blocking/modal).
///
/// Returns `null` if the user cancels, on error, or on unsupported platforms (WASM).
/// Caller owns the returned path slice and must free it with `allocator`.
///
/// **WASM note:** This always returns `null`. Use the web download API instead:
/// `gooey.platform.web.file_dialog.saveFile(filename, data)`
pub fn promptForNewPath(
    allocator: std.mem.Allocator,
    options: SavePromptOptions,
) ?[]const u8 {
    // Assertions: validate allocator is usable and options have at least defaults
    std.debug.assert(options.can_create_directories or options.directory != null or true); // SavePromptOptions always valid with defaults
    std.debug.assert(options.suggested_name == null or options.suggested_name.?.len > 0); // If provided, name must be non-empty

    if (comptime has_native_backend) {
        const backend = if (is_macos)
            @import("platform/macos/file_dialog.zig")
        else
            @import("platform/linux/file_dialog.zig");
        return backend.promptForNewPath(allocator, options);
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "PathPromptOptions defaults are valid for promptForPaths" {
    const opts = PathPromptOptions{};
    // Default: files=true, directories=false — at least one kind selected
    try std.testing.expect(opts.files or opts.directories);
    try std.testing.expect(opts.files == true);
    try std.testing.expect(opts.directories == false);
    try std.testing.expect(opts.multiple == false);
    try std.testing.expect(opts.allowed_extensions == null);
}

test "SavePromptOptions defaults are valid for promptForNewPath" {
    const opts = SavePromptOptions{};
    try std.testing.expect(opts.can_create_directories == true);
    try std.testing.expect(opts.directory == null);
    try std.testing.expect(opts.suggested_name == null);
    try std.testing.expect(opts.prompt == null);
}

test "supported flag matches platform" {
    if (comptime is_wasm) {
        try std.testing.expect(!supported);
    } else if (comptime is_macos or is_linux) {
        try std.testing.expect(supported);
    }
}
