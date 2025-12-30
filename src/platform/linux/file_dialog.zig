//! Linux File Dialogs via XDG Desktop Portal
//!
//! Provides native file open and save dialogs using the freedesktop.org
//! portal system. Works across all major Linux desktop environments
//! (GNOME, KDE, etc.) via D-Bus communication.
//!
//! ## Architecture
//!
//! - Uses `org.freedesktop.portal.FileChooser` interface
//! - Communicates via session D-Bus
//! - Blocking/synchronous API (waits for portal response signal)
//! - Converts `file://` URIs to filesystem paths
//!
//! ## Requirements
//!
//! - libdbus-1 (runtime)
//! - xdg-desktop-portal service running
//! - A portal backend (xdg-desktop-portal-gtk, -kde, -wlr, etc.)

const std = @import("std");
const dbus = @import("dbus.zig");
const interface_mod = @import("../interface.zig");

// =============================================================================
// Types (re-exported from interface)
// =============================================================================

pub const PathPromptOptions = interface_mod.PathPromptOptions;
pub const PathPromptResult = interface_mod.PathPromptResult;
pub const SavePromptOptions = interface_mod.SavePromptOptions;

// =============================================================================
// Constants
// =============================================================================

const PORTAL_TIMEOUT_MS: c_int = 120_000; // 2 minutes for user interaction
const SIGNAL_WAIT_TIMEOUT_MS: c_int = 500; // Poll interval for signal
const MAX_SIGNAL_WAIT_ITERATIONS: u32 = 300; // Total wait ~2.5 minutes
const MAX_URIS: usize = 1024;
const MAX_PATH_LEN: usize = 4096;

// =============================================================================
// Open Dialog
// =============================================================================

/// Show a file/directory open dialog (blocking/modal).
/// Returns null if user cancels or on error.
/// Caller owns returned PathPromptResult and must call deinit().
pub fn promptForPaths(
    allocator: std.mem.Allocator,
    options: PathPromptOptions,
) ?PathPromptResult {
    return promptForPathsInternal(allocator, options) catch |err| {
        logError("promptForPaths failed", err);
        return null;
    };
}

fn promptForPathsInternal(
    allocator: std.mem.Allocator,
    options: PathPromptOptions,
) !?PathPromptResult {
    // Connect to session bus
    var conn = try dbus.Connection.connectSessionPrivate();
    defer conn.deinit();

    // Get unique name for request handle
    const unique_name = conn.getUniqueName() orelse return error.NoUniqueName;

    // Generate request token and handle path
    var token_buf: [64]u8 = undefined;
    var handle_buf: [256]u8 = undefined;
    const token = generateToken(&token_buf);
    const handle_path = try buildHandlePath(&handle_buf, unique_name, token);

    // Subscribe to Response signal before sending request
    var match_buf: [512]u8 = undefined;
    const match_rule = try buildMatchRule(&match_buf, handle_path);
    try conn.addMatch(match_rule);
    defer conn.removeMatch(match_rule);

    // Build and send OpenFile request
    var msg = try dbus.Message.newMethodCall(
        dbus.PORTAL_BUS_NAME,
        dbus.PORTAL_OBJECT_PATH,
        dbus.PORTAL_FILE_CHOOSER_INTERFACE,
        "OpenFile",
    );
    defer msg.deinit();

    // Append arguments: parent_window (empty string), title, options dict
    var iter = msg.iterInitAppend();

    // Parent window identifier (empty for Wayland)
    if (!iter.appendString("")) return error.AppendFailed;

    // Title/message
    const title = options.message orelse "Open";
    var title_buf: [256:0]u8 = undefined;
    const title_z = toSentinelSlice(title, &title_buf) orelse return error.TitleTooLong;
    if (!iter.appendString(title_z)) return error.AppendFailed;

    // Options dictionary a{sv}
    var dict_iter = iter.openContainer(dbus.TYPE_ARRAY, "{sv}") orelse return error.ContainerFailed;

    // handle_token
    try appendDictEntryString(&dict_iter, "handle_token", token);

    // accept_label (button text)
    if (options.prompt) |prompt| {
        var prompt_buf: [128:0]u8 = undefined;
        const prompt_z = toSentinelSlice(prompt, &prompt_buf) orelse return error.PromptTooLong;
        try appendDictEntryString(&dict_iter, "accept_label", prompt_z);
    }

    // multiple selection
    try appendDictEntryBool(&dict_iter, "multiple", options.multiple);

    // directory mode
    try appendDictEntryBool(&dict_iter, "directory", options.directories);

    // modal
    try appendDictEntryBool(&dict_iter, "modal", true);

    // current_folder (starting directory as byte array)
    if (options.starting_directory) |dir| {
        try appendDictEntryBytes(&dict_iter, "current_folder", dir);
    }

    // File filters
    if (options.allowed_extensions) |extensions| {
        try appendFileFilters(&dict_iter, extensions);
    }

    if (!iter.closeContainer(&dict_iter)) return error.ContainerFailed;

    // Send request and get response (contains request handle)
    var reply = try conn.callMethod(&msg, dbus.TIMEOUT_USE_DEFAULT);
    defer reply.deinit();

    // Wait for Response signal
    const uris = try waitForResponse(&conn, handle_path) orelse return null;
    defer allocator.free(uris);

    // Convert URIs to paths
    return urisToPathResult(allocator, uris);
}

// =============================================================================
// Save Dialog
// =============================================================================

/// Show a file save dialog (blocking/modal).
/// Returns null if user cancels or on error.
/// Caller owns returned path and must free with allocator.
pub fn promptForNewPath(
    allocator: std.mem.Allocator,
    options: SavePromptOptions,
) ?[]const u8 {
    return promptForNewPathInternal(allocator, options) catch |err| {
        logError("promptForNewPath failed", err);
        return null;
    };
}

fn promptForNewPathInternal(
    allocator: std.mem.Allocator,
    options: SavePromptOptions,
) !?[]const u8 {
    // Connect to session bus
    var conn = try dbus.Connection.connectSessionPrivate();
    defer conn.deinit();

    // Get unique name for request handle
    const unique_name = conn.getUniqueName() orelse return error.NoUniqueName;

    // Generate request token and handle path
    var token_buf: [64]u8 = undefined;
    var handle_buf: [256]u8 = undefined;
    const token = generateToken(&token_buf);
    const handle_path = try buildHandlePath(&handle_buf, unique_name, token);

    // Subscribe to Response signal
    var match_buf: [512]u8 = undefined;
    const match_rule = try buildMatchRule(&match_buf, handle_path);
    try conn.addMatch(match_rule);
    defer conn.removeMatch(match_rule);

    // Build and send SaveFile request
    var msg = try dbus.Message.newMethodCall(
        dbus.PORTAL_BUS_NAME,
        dbus.PORTAL_OBJECT_PATH,
        dbus.PORTAL_FILE_CHOOSER_INTERFACE,
        "SaveFile",
    );
    defer msg.deinit();

    var iter = msg.iterInitAppend();

    // Parent window identifier (empty for Wayland)
    if (!iter.appendString("")) return error.AppendFailed;

    // Title/message
    const title = options.message orelse "Save";
    var title_buf: [256:0]u8 = undefined;
    const title_z = toSentinelSlice(title, &title_buf) orelse return error.TitleTooLong;
    if (!iter.appendString(title_z)) return error.AppendFailed;

    // Options dictionary a{sv}
    var dict_iter = iter.openContainer(dbus.TYPE_ARRAY, "{sv}") orelse return error.ContainerFailed;

    // handle_token
    try appendDictEntryString(&dict_iter, "handle_token", token);

    // accept_label (button text)
    if (options.prompt) |prompt| {
        var prompt_buf: [128:0]u8 = undefined;
        const prompt_z = toSentinelSlice(prompt, &prompt_buf) orelse return error.PromptTooLong;
        try appendDictEntryString(&dict_iter, "accept_label", prompt_z);
    }

    // modal
    try appendDictEntryBool(&dict_iter, "modal", true);

    // current_folder (starting directory)
    if (options.directory) |dir| {
        try appendDictEntryBytes(&dict_iter, "current_folder", dir);
    }

    // current_name (suggested filename)
    if (options.suggested_name) |name| {
        var name_buf: [256:0]u8 = undefined;
        const name_z = toSentinelSlice(name, &name_buf) orelse return error.NameTooLong;
        try appendDictEntryString(&dict_iter, "current_name", name_z);
    }

    // File filters
    if (options.allowed_extensions) |extensions| {
        try appendFileFilters(&dict_iter, extensions);
    }

    if (!iter.closeContainer(&dict_iter)) return error.ContainerFailed;

    // Send request
    var reply = try conn.callMethod(&msg, dbus.TIMEOUT_USE_DEFAULT);
    defer reply.deinit();

    // Wait for Response signal
    const uris = try waitForResponse(&conn, handle_path) orelse return null;
    defer allocator.free(uris);

    // Convert first URI to path
    if (uris.len == 0) return null;

    return uriToPath(allocator, uris[0]);
}

// =============================================================================
// Response Handling
// =============================================================================

/// Wait for the portal Response signal and extract URIs
fn waitForResponse(
    conn: *dbus.Connection,
    handle_path: [:0]const u8,
) !?[][]const u8 {
    var iterations: u32 = 0;

    while (iterations < MAX_SIGNAL_WAIT_ITERATIONS) : (iterations += 1) {
        // Read any available data
        _ = conn.readWrite(SIGNAL_WAIT_TIMEOUT_MS);

        // Process all pending messages
        while (conn.popMessage()) |*msg_ptr| {
            var signal_msg = msg_ptr.*;
            defer signal_msg.deinit();

            // Check if this is our Response signal
            if (signal_msg.getType() != dbus.MESSAGE_TYPE_SIGNAL) continue;

            const path = signal_msg.getPath() orelse continue;
            if (!std.mem.eql(u8, path, handle_path)) continue;

            if (!signal_msg.isSignal(dbus.PORTAL_REQUEST_INTERFACE, "Response")) continue;

            // Parse response
            var iter = signal_msg.iterInit() orelse return error.InvalidResponse;

            // First argument: response code (u32)
            if (iter.getArgType() != dbus.TYPE_UINT32) return error.InvalidResponse;
            const response_code = iter.getUint32();

            if (response_code == 1) {
                // User cancelled
                return null;
            } else if (response_code != 0) {
                // Error
                return error.PortalError;
            }

            // Second argument: results dict a{sv}
            if (!iter.next()) return error.InvalidResponse;
            if (iter.getArgType() != dbus.TYPE_ARRAY) return error.InvalidResponse;

            // Look for "uris" key in results
            var dict_iter = iter.recurse();
            while (dict_iter.getArgType() == dbus.TYPE_DICT_ENTRY) {
                var entry_iter = dict_iter.recurse();

                // Key (string)
                if (entry_iter.getArgType() != dbus.TYPE_STRING) {
                    _ = dict_iter.next();
                    continue;
                }
                const key = entry_iter.getString() orelse {
                    _ = dict_iter.next();
                    continue;
                };

                if (std.mem.eql(u8, key, "uris")) {
                    // Found uris - parse variant containing string array
                    if (!entry_iter.next()) return error.InvalidResponse;
                    if (entry_iter.getArgType() != dbus.TYPE_VARIANT) return error.InvalidResponse;

                    var variant_iter = entry_iter.recurse();
                    if (variant_iter.getArgType() != dbus.TYPE_ARRAY) return error.InvalidResponse;

                    // Count URIs first
                    var count_iter = variant_iter.recurse();
                    var count: usize = 0;
                    while (count_iter.getArgType() == dbus.TYPE_STRING) {
                        count += 1;
                        if (!count_iter.next()) break;
                    }

                    if (count == 0) return null;
                    if (count > MAX_URIS) count = MAX_URIS;

                    // Allocate and fill URI array
                    var uris = std.heap.page_allocator.alloc([]const u8, count) catch return error.OutOfMemory;
                    errdefer std.heap.page_allocator.free(uris);

                    var array_iter = variant_iter.recurse();
                    var i: usize = 0;
                    while (array_iter.getArgType() == dbus.TYPE_STRING and i < count) {
                        if (array_iter.getString()) |uri| {
                            uris[i] = std.heap.page_allocator.dupe(u8, uri) catch return error.OutOfMemory;
                            i += 1;
                        }
                        if (!array_iter.next()) break;
                    }

                    return uris[0..i];
                }

                _ = dict_iter.next();
            }

            return error.NoUrisInResponse;
        }
    }

    return error.Timeout;
}

// =============================================================================
// URI/Path Conversion
// =============================================================================

/// Convert file:// URI to filesystem path
fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        // Not a file URI, try to use as-is
        return allocator.dupe(u8, uri) catch return null;
    }

    // Decode percent-encoded characters
    const encoded_path = uri[prefix.len..];
    var decoded = allocator.alloc(u8, encoded_path.len) catch return null;
    var write_idx: usize = 0;
    var read_idx: usize = 0;

    while (read_idx < encoded_path.len) {
        if (encoded_path[read_idx] == '%' and read_idx + 2 < encoded_path.len) {
            const hex = encoded_path[read_idx + 1 .. read_idx + 3];
            if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                decoded[write_idx] = byte;
                write_idx += 1;
                read_idx += 3;
                continue;
            } else |_| {}
        }
        decoded[write_idx] = encoded_path[read_idx];
        write_idx += 1;
        read_idx += 1;
    }

    // Shrink to actual size by duplicating to right size
    const result = allocator.dupe(u8, decoded[0..write_idx]) catch {
        allocator.free(decoded);
        return null;
    };
    allocator.free(decoded);
    return result;
}

/// Convert array of URIs to PathPromptResult
fn urisToPathResult(allocator: std.mem.Allocator, uris: [][]const u8) ?PathPromptResult {
    if (uris.len == 0) return null;

    var paths = allocator.alloc([]const u8, uris.len) catch return null;
    var valid_count: usize = 0;

    for (uris) |uri| {
        if (uriToPath(allocator, uri)) |path| {
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

// =============================================================================
// D-Bus Message Building Helpers
// =============================================================================

/// Generate a unique token for request handles
fn generateToken(buf: *[64]u8) [:0]const u8 {
    // Use timestamp for uniqueness
    const ts = std.posix.clock_gettime(.REALTIME) catch std.posix.timespec{
        .sec = 0,
        .nsec = 12345,
    };

    const hash: u64 = @bitCast(ts.sec *% 1000000000 +% ts.nsec);
    const len = std.fmt.bufPrint(buf[0..63], "gooey_{x}", .{hash}) catch return "gooey_token";
    buf[len.len] = 0;
    return buf[0..len.len :0];
}

/// Build the request handle object path
fn buildHandlePath(buf: *[256]u8, unique_name: []const u8, token: [:0]const u8) ![:0]const u8 {
    // Format: /org/freedesktop/portal/desktop/request/{sender}/{token}
    // Sender has : replaced with _ and leading : removed
    var sender_buf: [128]u8 = undefined;
    var sender_len: usize = 0;

    for (unique_name) |c| {
        if (c == ':') continue; // Skip leading colon
        if (c == '.') {
            sender_buf[sender_len] = '_';
        } else {
            sender_buf[sender_len] = c;
        }
        sender_len += 1;
        if (sender_len >= sender_buf.len) break;
    }

    const len = std.fmt.bufPrint(buf[0..255], "/org/freedesktop/portal/desktop/request/{s}/{s}", .{
        sender_buf[0..sender_len],
        token,
    }) catch return error.PathTooLong;
    buf[len.len] = 0;
    return buf[0..len.len :0];
}

/// Build D-Bus match rule for Response signal
fn buildMatchRule(buf: *[512]u8, handle_path: [:0]const u8) ![:0]const u8 {
    const len = std.fmt.bufPrint(buf[0..511], "type='signal',interface='{s}',member='Response',path='{s}'", .{
        dbus.PORTAL_REQUEST_INTERFACE,
        handle_path,
    }) catch return error.RuleTooLong;
    buf[len.len] = 0;
    return buf[0..len.len :0];
}

/// Append a dict entry with string value: {key: variant<string>}
fn appendDictEntryString(dict_iter: *dbus.MessageIter, key: [:0]const u8, value: [:0]const u8) !void {
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse return error.ContainerFailed;

    if (!entry.appendString(key)) return error.AppendFailed;

    var variant = entry.openContainer(dbus.TYPE_VARIANT, "s") orelse return error.ContainerFailed;
    if (!variant.appendString(value)) return error.AppendFailed;
    if (!entry.closeContainer(&variant)) return error.ContainerFailed;

    if (!dict_iter.closeContainer(&entry)) return error.ContainerFailed;
}

/// Append a dict entry with boolean value: {key: variant<bool>}
fn appendDictEntryBool(dict_iter: *dbus.MessageIter, key: [:0]const u8, value: bool) !void {
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse return error.ContainerFailed;

    if (!entry.appendString(key)) return error.AppendFailed;

    var variant = entry.openContainer(dbus.TYPE_VARIANT, "b") orelse return error.ContainerFailed;
    if (!variant.appendBool(value)) return error.AppendFailed;
    if (!entry.closeContainer(&variant)) return error.ContainerFailed;

    if (!dict_iter.closeContainer(&entry)) return error.ContainerFailed;
}

/// Append a dict entry with byte array value: {key: variant<ay>}
fn appendDictEntryBytes(dict_iter: *dbus.MessageIter, key: [:0]const u8, value: []const u8) !void {
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse return error.ContainerFailed;

    if (!entry.appendString(key)) return error.AppendFailed;

    var variant = entry.openContainer(dbus.TYPE_VARIANT, "ay") orelse return error.ContainerFailed;

    // Append path bytes with null terminator (portal expects null-terminated byte array)
    var path_with_null: [MAX_PATH_LEN + 1]u8 = undefined;
    if (value.len >= MAX_PATH_LEN) return error.PathTooLong;
    @memcpy(path_with_null[0..value.len], value);
    path_with_null[value.len] = 0;

    if (!variant.appendBytes(path_with_null[0 .. value.len + 1])) return error.AppendFailed;
    if (!entry.closeContainer(&variant)) return error.ContainerFailed;

    if (!dict_iter.closeContainer(&entry)) return error.ContainerFailed;
}

/// Append file filters as a(sa(us))
fn appendFileFilters(dict_iter: *dbus.MessageIter, extensions: []const []const u8) !void {
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse return error.ContainerFailed;

    if (!entry.appendString("filters")) return error.AppendFailed;

    // variant containing array of filters
    var variant = entry.openContainer(dbus.TYPE_VARIANT, "a(sa(us))") orelse return error.ContainerFailed;

    // Array of filter tuples
    var filters_array = variant.openContainer(dbus.TYPE_ARRAY, "(sa(us))") orelse return error.ContainerFailed;

    // Single filter tuple: ("Files", [(0, "*.ext"), ...])
    var filter_tuple = filters_array.openContainer(dbus.TYPE_STRUCT, null) orelse return error.ContainerFailed;

    // Filter name
    if (!filter_tuple.appendString("Allowed files")) return error.AppendFailed;

    // Array of (type, pattern) tuples
    var patterns_array = filter_tuple.openContainer(dbus.TYPE_ARRAY, "(us)") orelse return error.ContainerFailed;

    for (extensions) |ext| {
        var pattern_tuple = patterns_array.openContainer(dbus.TYPE_STRUCT, null) orelse return error.ContainerFailed;

        // Type 0 = glob pattern
        if (!pattern_tuple.appendUint32(0)) return error.AppendFailed;

        // Pattern string: "*.ext"
        var pattern_buf: [128:0]u8 = undefined;
        if (ext.len + 2 >= 128) continue; // Skip if too long
        pattern_buf[0] = '*';
        pattern_buf[1] = '.';
        @memcpy(pattern_buf[2 .. 2 + ext.len], ext);
        pattern_buf[2 + ext.len] = 0;
        if (!pattern_tuple.appendString(pattern_buf[0 .. 2 + ext.len :0])) return error.AppendFailed;

        if (!patterns_array.closeContainer(&pattern_tuple)) return error.ContainerFailed;
    }

    if (!filter_tuple.closeContainer(&patterns_array)) return error.ContainerFailed;
    if (!filters_array.closeContainer(&filter_tuple)) return error.ContainerFailed;
    if (!variant.closeContainer(&filters_array)) return error.ContainerFailed;
    if (!entry.closeContainer(&variant)) return error.ContainerFailed;
    if (!dict_iter.closeContainer(&entry)) return error.ContainerFailed;
}

// =============================================================================
// Utilities
// =============================================================================

/// Convert slice to sentinel-terminated slice (copies to buffer)
fn toSentinelSlice(slice: []const u8, buf: []u8) ?[:0]const u8 {
    if (slice.len >= buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return buf[0..slice.len :0];
}

/// Log error for debugging (only in debug builds)
fn logError(context: []const u8, err: anyerror) void {
    if (@import("builtin").mode == .Debug) {
        std.log.err("file_dialog: {s}: {}", .{ context, err });
    }
}

// =============================================================================
// Tests
// =============================================================================

test "URI to path conversion" {
    const allocator = std.testing.allocator;

    // Simple path
    {
        const path = uriToPath(allocator, "file:///home/user/test.txt");
        try std.testing.expect(path != null);
        defer allocator.free(path.?);
        try std.testing.expectEqualStrings("/home/user/test.txt", path.?);
    }

    // Percent-encoded path
    {
        const path = uriToPath(allocator, "file:///home/user/my%20file.txt");
        try std.testing.expect(path != null);
        defer allocator.free(path.?);
        try std.testing.expectEqualStrings("/home/user/my file.txt", path.?);
    }

    // Non-file URI (returned as-is)
    {
        const path = uriToPath(allocator, "/direct/path/test.txt");
        try std.testing.expect(path != null);
        defer allocator.free(path.?);
        try std.testing.expectEqualStrings("/direct/path/test.txt", path.?);
    }
}

test "token generation produces valid identifier" {
    var buf: [64]u8 = undefined;
    const token = generateToken(&buf);

    try std.testing.expect(token.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, token, "gooey_"));
}

test "PathPromptOptions defaults" {
    const opts = PathPromptOptions{};
    try std.testing.expect(opts.files == true);
    try std.testing.expect(opts.directories == false);
    try std.testing.expect(opts.multiple == false);
}

test "SavePromptOptions defaults" {
    const opts = SavePromptOptions{};
    try std.testing.expect(opts.can_create_directories == true);
    try std.testing.expect(opts.directory == null);
    try std.testing.expect(opts.suggested_name == null);
}
