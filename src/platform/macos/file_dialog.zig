const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");
const interface_mod = @import("../interface.zig");

const assert = std.debug.assert;

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

/// Null on cancel; an error is a failure, not a cancel. Paths live in
/// `scratch`.
pub fn promptForPaths(
    scratch: std.mem.Allocator,
    options: PathPromptOptions,
) DialogError!?PathPromptResult {
    assert(options.files or options.directories);
    const NSOpenPanel = objc.getClass("NSOpenPanel") orelse return error.DialogUnavailable;
    const panel = NSOpenPanel.msgSend(objc.Object, "openPanel", .{});

    panel.msgSend(void, "setCanChooseDirectories:", .{options.directories});
    panel.msgSend(void, "setCanChooseFiles:", .{options.files});
    panel.msgSend(void, "setAllowsMultipleSelection:", .{options.multiple});
    panel.msgSend(void, "setCanCreateDirectories:", .{true});
    panel.msgSend(void, "setResolvesAliases:", .{true});

    // Flush pending UI updates before the modal block, so clicks register.
    if (objc.getClass("NSApplication")) |NSApp| {
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
        app.msgSend(void, "updateWindows", .{});
    }

    const response: isize = panel.msgSend(isize, "runModal", .{});

    if (response != @backingInt(appkit.NSModalResponse.OK)) {
        return null;
    }
    const result = try openPaths(scratch, panel.msgSend(objc.Object, "URLs", .{}));
    if (!options.multiple) assert(result.paths.len == 1);
    return result;
}

/// A path that cannot be copied fails the selection instead of being left
/// out of it.
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

/// Null on cancel; an error is a failure, not a cancel. The path lives in
/// `scratch`.
pub fn promptForNewPath(
    scratch: std.mem.Allocator,
    options: SavePromptOptions,
) DialogError!?[]const u8 {
    if (options.suggested_name) |name| assert(name.len > 0);
    const NSSavePanel = objc.getClass("NSSavePanel") orelse return error.DialogUnavailable;
    const panel = NSSavePanel.msgSend(objc.Object, "savePanel", .{});

    panel.msgSend(void, "setCanCreateDirectories:", .{true});

    if (options.directory) |directory| {
        if (createFileURL(directory, true)) |dir_url| {
            panel.msgSend(void, "setDirectoryURL:", .{dir_url.value});
        }
    }

    if (options.suggested_name) |name| {
        if (createNSString(name)) |ns_name| {
            panel.msgSend(void, "setNameFieldStringValue:", .{ns_name.value});
        }
    }

    // Flush pending UI updates before the modal block, so clicks register.
    if (objc.getClass("NSApplication")) |NSApp| {
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
        app.msgSend(void, "updateWindows", .{});
    }

    const response: isize = panel.msgSend(isize, "runModal", .{});

    if (response != @backingInt(appkit.NSModalResponse.OK)) {
        return null;
    }

    const url = panel.msgSend(objc.Object, "URL", .{});
    return try nsUrlToPath(scratch, url);
}

fn nsUrlToPath(scratch: std.mem.Allocator, url: objc.Object) DialogError![]const u8 {
    // `fileSystemRepresentation` is a UTF-8, null-terminated C string.
    const cstr: ?[*:0]const u8 = url.msgSend(?[*:0]const u8, "fileSystemRepresentation", .{});
    const ptr = cstr orelse {
        std.log.warn("macos: file dialog selected a URL with no file system path", .{});
        return error.PathUnrepresentable;
    };
    const path = scratch.dupe(u8, std.mem.span(ptr)) catch return scratchFull();
    assert(path.len > 0);
    return path;
}

pub fn scratchFull() DialogError {
    std.log.err("macos: file dialog selection does not fit the dialog scratch. " ++
        "Raise ResourceLimits.events.dialog_path_bytes_max.", .{});
    return error.DialogPathTooLong;
}

fn createNSString(str: []const u8) ?objc.Object {
    const NSString = objc.getClass("NSString") orelse return null;

    // `str` may not be NUL-terminated, so `initWithBytes:length:encoding:`.
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

fn createFileURL(path: []const u8, is_directory: bool) ?objc.Object {
    const ns_path = createNSString(path) orelse return null;
    const NSURL = objc.getClass("NSURL") orelse return null;
    return NSURL.msgSend(objc.Object, "fileURLWithPath:isDirectory:", .{ ns_path.value, is_directory });
}
