//! Native macOS File Dialogs
//!
//! Provides file open (NSOpenPanel) and save (NSSavePanel) dialogs.
//! Uses synchronous/modal presentation for simplicity.
//!
//! The prompts return null for a cancel and an error for a failure, which
//! the core host reports as `.failed`, never as `.cancelled`. Paths are
//! copied into `scratch`, the core's text scratch, which holds a selection
//! of `ResourceLimits.events.dialog_path_bytes_max` bytes
//! (`limits.textScratchBytes`); a selection it cannot hold fails with
//! `error.DialogPathTooLong`, logged with the field to raise. One within the
//! scratch but past the budget fails fast in the core (`tick.checkSelection`).

const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");
const interface_mod = @import("../interface.zig");

const assert = std.debug.assert;

// ============================================================================
// Types (re-exported from interface)
// ============================================================================

pub const PathPromptOptions = interface_mod.PathPromptOptions;
pub const PathPromptResult = interface_mod.PathPromptResult;
pub const SavePromptOptions = interface_mod.SavePromptOptions;

pub const DialogError = error{
    /// AppKit is missing a panel class, which only a broken process sees.
    DialogUnavailable,
    /// The scratch cannot hold the selection.
    DialogPathTooLong,
    /// A selected URL has no file system representation.
    PathUnrepresentable,
};

// ============================================================================
// Open Dialog
// ============================================================================

/// Show a file/directory open dialog (blocking/modal). Returns null if the
/// user cancels. The paths live in `scratch`.
pub fn promptForPaths(
    scratch: std.mem.Allocator,
    options: PathPromptOptions,
) DialogError!?PathPromptResult {
    assert(options.files or options.directories);
    const NSOpenPanel = objc.getClass("NSOpenPanel") orelse return error.DialogUnavailable;
    const panel = NSOpenPanel.msgSend(objc.Object, "openPanel", .{});

    // Configure panel options
    panel.msgSend(void, "setCanChooseDirectories:", .{options.directories});
    panel.msgSend(void, "setCanChooseFiles:", .{options.files});
    panel.msgSend(void, "setAllowsMultipleSelection:", .{options.multiple});
    panel.msgSend(void, "setCanCreateDirectories:", .{true});
    panel.msgSend(void, "setResolvesAliases:", .{true});

    // Flush pending UI updates before blocking (makes button click feel responsive)
    if (objc.getClass("NSApplication")) |NSApp| {
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
        app.msgSend(void, "updateWindows", .{});
    }

    // Run modal dialog (blocks until user responds)
    const response: isize = panel.msgSend(isize, "runModal", .{});

    if (response != @backingInt(appkit.NSModalResponse.OK)) {
        return null; // User cancelled
    }
    const result = try openPaths(scratch, panel.msgSend(objc.Object, "URLs", .{}));
    if (!options.multiple) assert(result.paths.len == 1);
    return result;
}

/// Copy every selected URL's path into `scratch`. A path that cannot be
/// copied fails the selection instead of being left out of it.
fn openPaths(scratch: std.mem.Allocator, urls: objc.Object) DialogError!PathPromptResult {
    const count: usize = urls.msgSend(usize, "count", .{});
    if (count == 0) return error.PathUnrepresentable; // AppKit reported OK with nothing.

    const paths = scratch.alloc([]const u8, count) catch return scratchFull();
    for (paths, 0..) |*path, index| {
        assert(index < count);
        const url = urls.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, index)});
        path.* = try nsUrlToPath(scratch, url);
    }
    assert(paths.len == count);
    return .{ .paths = paths, .allocator = scratch };
}

// ============================================================================
// Save Dialog
// ============================================================================

/// Show a file save dialog (blocking/modal). Returns null if the user
/// cancels. The path lives in `scratch`.
pub fn promptForNewPath(
    scratch: std.mem.Allocator,
    options: SavePromptOptions,
) DialogError!?[]const u8 {
    if (options.suggested_name) |name| assert(name.len > 0);
    const NSSavePanel = objc.getClass("NSSavePanel") orelse return error.DialogUnavailable;
    const panel = NSSavePanel.msgSend(objc.Object, "savePanel", .{});

    panel.msgSend(void, "setCanCreateDirectories:", .{true});

    // Set initial directory
    if (options.directory) |directory| {
        if (createFileURL(directory, true)) |dir_url| {
            panel.msgSend(void, "setDirectoryURL:", .{dir_url.value});
        }
    }

    // Set suggested filename
    if (options.suggested_name) |name| {
        if (createNSString(name)) |ns_name| {
            panel.msgSend(void, "setNameFieldStringValue:", .{ns_name.value});
        }
    }

    // Flush pending UI updates before blocking (makes button click feel responsive)
    if (objc.getClass("NSApplication")) |NSApp| {
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
        app.msgSend(void, "updateWindows", .{});
    }

    // Run modal dialog (blocks until user responds)
    const response: isize = panel.msgSend(isize, "runModal", .{});

    if (response != @backingInt(appkit.NSModalResponse.OK)) {
        return null;
    }

    // Get result URL
    const url = panel.msgSend(objc.Object, "URL", .{});
    return try nsUrlToPath(scratch, url);
}

// ============================================================================
// Helpers
// ============================================================================

/// Copy the URL's file system path into `scratch`.
fn nsUrlToPath(scratch: std.mem.Allocator, url: objc.Object) DialogError![]const u8 {
    // fileSystemRepresentation returns a C string (UTF-8, null-terminated)
    const cstr: ?[*:0]const u8 = url.msgSend(?[*:0]const u8, "fileSystemRepresentation", .{});
    const ptr = cstr orelse {
        std.log.warn("macos: file dialog selected a URL with no file system path", .{});
        return error.PathUnrepresentable;
    };
    const path = scratch.dupe(u8, std.mem.span(ptr)) catch return scratchFull();
    assert(path.len > 0);
    return path;
}

/// The core's text scratch cannot hold the selection: its paths are past the
/// app's `dialog_path_bytes_max` (`limits.textScratchBytes`).
pub fn scratchFull() DialogError {
    std.log.err("macos: file dialog selection does not fit the dialog scratch. " ++
        "Raise ResourceLimits.events.dialog_path_bytes_max.", .{});
    return error.DialogPathTooLong;
}

/// Create NSString from Zig slice
fn createNSString(str: []const u8) ?objc.Object {
    const NSString = objc.getClass("NSString") orelse return null;

    // Use initWithBytes:length:encoding: for non-null-terminated strings
    const ns_string_id: objc.c.id = NSString.msgSend(objc.c.id, "alloc", .{});
    if (ns_string_id == null) return null;

    const ns_string = objc.Object.fromId(ns_string_id);
    const initialized_id: objc.c.id = ns_string.msgSend(
        objc.c.id,
        "initWithBytes:length:encoding:",
        .{
            str.ptr,
            @as(c_ulong, str.len),
            @as(c_ulong, 4), // NSUTF8StringEncoding = 4
        },
    );
    if (initialized_id == null) return null;

    return objc.Object.fromId(initialized_id);
}

/// Create NSURL from file path
fn createFileURL(path: []const u8, is_directory: bool) ?objc.Object {
    const ns_path = createNSString(path) orelse return null;
    const NSURL = objc.getClass("NSURL") orelse return null;
    return NSURL.msgSend(objc.Object, "fileURLWithPath:isDirectory:", .{ ns_path.value, is_directory });
}
