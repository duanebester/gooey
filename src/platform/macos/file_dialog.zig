//! Native macOS File Dialogs
//!
//! Provides file open (NSOpenPanel) and save (NSSavePanel) dialogs.
//! Uses synchronous/modal presentation for simplicity.

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

// ============================================================================
// Open Dialog
// ============================================================================

/// Show a file/directory open dialog (blocking/modal).
/// Returns null if user cancels or on error.
/// Caller owns returned PathPromptResult and must call deinit().
pub fn promptForPaths(
    allocator: std.mem.Allocator,
    options: PathPromptOptions,
) ?PathPromptResult {
    assert(options.files or options.directories);
    const NSOpenPanel = objc.getClass("NSOpenPanel") orelse return null;
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

    // Extract selected URLs
    const urls = panel.msgSend(objc.Object, "URLs", .{});
    const count: usize = urls.msgSend(usize, "count", .{});

    if (count == 0) {
        return null;
    }

    // Allocate paths array
    var paths = allocator.alloc([]const u8, count) catch return null;
    var valid_count: usize = 0;

    for (0..count) |i| {
        const url = urls.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, i)});
        if (nsUrlToPath(allocator, url)) |path| {
            paths[valid_count] = path;
            valid_count += 1;
        }
    }

    if (valid_count == 0) {
        allocator.free(paths);
        return null;
    }

    return .{
        .paths = paths[0..valid_count],
        .allocator = allocator,
    };
}

// ============================================================================
// Save Dialog
// ============================================================================

/// Show a file save dialog (blocking/modal).
/// Returns null if user cancels or on error.
/// Caller owns returned path and must free with allocator.
pub fn promptForNewPath(
    allocator: std.mem.Allocator,
    options: SavePromptOptions,
) ?[]const u8 {
    if (options.suggested_name) |name| assert(name.len > 0);
    const NSSavePanel = objc.getClass("NSSavePanel") orelse return null;
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
    return nsUrlToPath(allocator, url);
}

// ============================================================================
// Helpers
// ============================================================================

/// Convert NSURL to Zig string (owned by caller)
fn nsUrlToPath(allocator: std.mem.Allocator, url: objc.Object) ?[]const u8 {
    // fileSystemRepresentation returns a C string (UTF-8, null-terminated)
    const cstr: ?[*:0]const u8 = url.msgSend(?[*:0]const u8, "fileSystemRepresentation", .{});
    if (cstr) |ptr| {
        return allocator.dupe(u8, std.mem.span(ptr)) catch null;
    }
    return null;
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
