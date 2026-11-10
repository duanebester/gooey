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
//! - Blocking API (`promptForPaths`, `promptForNewPath`) that waits for the
//!   portal's Response signal, and `PortalRequest`, which the core host polls
//!   from its event loop so the window keeps running while the dialog is open
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
/// Most URIs one Response may carry before it is treated as malformed; the
/// app's own limit (`dialog_path_count_max`) is far lower and fails fast.
const response_uri_count_max: u32 = 1 << 20;
/// Joins the paths of a `Selection`, as in the core's `events.Paths`.
const separator: u8 = 0;

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
    std.debug.assert(options.files or options.directories);
    return promptForPathsInternal(allocator, &options) catch |err| {
        logError("promptForPaths failed", err);
        return null;
    };
}

fn promptForPathsInternal(
    allocator: std.mem.Allocator,
    options: *const PathPromptOptions,
) !?PathPromptResult {
    var request: PortalRequest = undefined;
    try request.begin(.{ .open = options });
    defer request.end();

    // Wait for the Response signal; its paths come from `allocator`.
    return waitForResponse(allocator, &request.connection, request.handlePath());
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
    if (options.suggested_name) |name| std.debug.assert(name.len > 0);
    return promptForNewPathInternal(allocator, &options) catch |err| {
        logError("promptForNewPath failed", err);
        return null;
    };
}

fn promptForNewPathInternal(
    allocator: std.mem.Allocator,
    options: *const SavePromptOptions,
) !?[]const u8 {
    var request: PortalRequest = undefined;
    try request.begin(.{ .save = options });
    defer request.end();

    // Wait for the Response signal and keep the first path. A save dialog
    // returns one URI; any others and the array are freed.
    const handle_path = request.handlePath();
    const result = try waitForResponse(allocator, &request.connection, handle_path) orelse
        return null;
    std.debug.assert(result.paths.len > 0);
    defer allocator.free(result.paths);
    for (result.paths[1..]) |path| allocator.free(path);
    return result.paths[0];
}

// =============================================================================
// Portal Requests
// =============================================================================

/// One FileChooser request: a private session-bus connection subscribed to
/// the request's Response signal, then the OpenFile or SaveFile call. The
/// portal answers the call at once with the request handle and keeps the
/// dialog open until the user closes it, when the Response arrives.
///
/// `promptForPaths` and `promptForNewPath` block on the Response. The core
/// host instead polls the connection's fd beside the Wayland fd and calls
/// `poll` once per loop turn, so its window keeps running meanwhile. The
/// strings live in the request's own buffers and are kept by length, so a
/// request holds no pointer into itself.
pub const PortalRequest = struct {
    connection: dbus.Connection,
    token_buffer: [64]u8,
    token_len: u32,
    handle_buffer: [256]u8,
    handle_len: u32,
    match_buffer: [512]u8,
    match_len: u32,

    /// Most messages one `poll` handles; the rest wait for the next call.
    /// A request's private connection receives only a few: the bus's
    /// NameAcquired, the call's reply, and the Response.
    pub const messages_per_poll_max: u32 = 64;

    pub const Options = union(enum) {
        open: *const PathPromptOptions,
        save: *const SavePromptOptions,
    };

    pub const Status = union(enum) {
        /// No Response yet: the dialog is open.
        open,
        /// No Response among the messages this call may handle, and more are
        /// queued that the fd will not announce again: call again soon.
        open_more,
        cancelled,
        selected: Selection,
    };

    /// Connect, subscribe to the Response, and send the call. On success the
    /// dialog is open and `end` or `close` must follow.
    pub fn begin(self: *PortalRequest, options: Options) !void {
        switch (options) {
            .open => |open| std.debug.assert(open.files or open.directories),
            .save => |save| if (save.suggested_name) |name| std.debug.assert(name.len > 0),
        }
        try self.subscribe();
        errdefer self.end();
        const method: [:0]const u8, const title: [:0]const u8 = switch (options) {
            .open => .{ "OpenFile", "Open" },
            .save => .{ "SaveFile", "Save" },
        };
        var message = try dbus.Message.newMethodCall(
            dbus.PORTAL_BUS_NAME,
            dbus.PORTAL_OBJECT_PATH,
            dbus.PORTAL_FILE_CHOOSER_INTERFACE,
            method,
        );
        defer message.deinit();

        var iter = message.iterInitAppend();
        // Parent window identifier (empty for Wayland)
        if (!iter.appendString("")) return error.AppendFailed;
        // The portal requires a title; decision 11 drops the app's, so it is fixed.
        if (!iter.appendString(title)) return error.AppendFailed;
        var dict_iter = iter.openContainer(dbus.TYPE_ARRAY, "{sv}") orelse
            return error.ContainerFailed;
        switch (options) {
            .open => |open| try appendOpenOptions(&dict_iter, self.token(), open),
            .save => |save| try appendSaveOptions(&dict_iter, self.token(), save),
        }
        if (!iter.closeContainer(&dict_iter)) return error.ContainerFailed;

        // The reply carries the request handle; the dialog stays open after it.
        var reply = try self.connection.callMethod(&message, dbus.TIMEOUT_USE_DEFAULT);
        reply.deinit();
        std.debug.assert(self.handle_len > 0);
    }

    /// Read what has arrived without blocking and look for the Response.
    /// Selected paths are decoded into `paths` (see `Selection`).
    pub fn poll(self: *PortalRequest, paths: []u8) !Status {
        std.debug.assert(paths.len > 0);
        std.debug.assert(self.handle_len > 0);
        // A zero timeout reads only what is available; false once disconnected.
        if (!self.connection.readWrite(0)) return error.Disconnected;
        var handled: u32 = 0;
        while (handled < messages_per_poll_max) : (handled += 1) {
            var message = self.connection.popMessage() orelse return .open;
            defer message.deinit();
            if (!isResponse(&message, self.handlePath())) continue;
            var uris = try responseUris(&message) orelse return .cancelled;
            return .{ .selected = try joinUris(&uris, paths) };
        }
        return .open_more;
    }

    /// Unsubscribe and close the connection, after the Response or a failed
    /// `begin`. The request is undefined afterwards.
    pub fn end(self: *PortalRequest) void {
        std.debug.assert(self.match_len > 0);
        self.connection.removeMatch(self.matchRule());
        self.connection.deinit();
        self.* = undefined;
    }

    /// Ask the portal to close the open dialog (`Request.Close`, which sends
    /// no Response), then `end`. For an owner leaving while the dialog is open.
    pub fn close(self: *PortalRequest) void {
        std.debug.assert(self.handle_len > 0);
        defer self.end();
        var message = dbus.Message.newMethodCall(
            dbus.PORTAL_BUS_NAME,
            self.handlePath(),
            dbus.PORTAL_REQUEST_INTERFACE,
            "Close",
        ) catch |err| return logError("Request.Close failed", err);
        defer message.deinit();
        self.connection.send(&message) catch |err| return logError("Request.Close failed", err);
        self.connection.flush();
    }

    /// The connection's socket, to poll beside other fds while the dialog is
    /// open; null for a bus that is not on a socket.
    pub fn fd(self: *PortalRequest) ?std.posix.fd_t {
        std.debug.assert(self.handle_len > 0);
        return self.connection.unixFd();
    }

    pub fn handlePath(self: *const PortalRequest) [:0]const u8 {
        std.debug.assert(self.handle_len < self.handle_buffer.len);
        return self.handle_buffer[0..self.handle_len :0];
    }

    fn token(self: *const PortalRequest) [:0]const u8 {
        std.debug.assert(self.token_len < self.token_buffer.len);
        return self.token_buffer[0..self.token_len :0];
    }

    fn matchRule(self: *const PortalRequest) [:0]const u8 {
        std.debug.assert(self.match_len < self.match_buffer.len);
        return self.match_buffer[0..self.match_len :0];
    }

    /// Connect, name the request, and subscribe to its Response before the
    /// call is sent, so the signal cannot arrive unheard.
    fn subscribe(self: *PortalRequest) !void {
        self.connection = try dbus.Connection.connectSessionPrivate();
        errdefer self.connection.deinit();
        const unique_name = self.connection.getUniqueName() orelse return error.NoUniqueName;
        self.token_len = @intCast(generateToken(&self.token_buffer).len);
        const handle_path = try buildHandlePath(&self.handle_buffer, unique_name, self.token());
        self.handle_len = @intCast(handle_path.len);
        self.match_len = @intCast((try buildMatchRule(&self.match_buffer, handle_path)).len);
        try self.connection.addMatch(self.matchRule());
        std.debug.assert(self.handle_len > 0);
    }
};

/// A Response's selection: `count` paths joined by NUL bytes, `bytes_len`
/// in all (the layout of the core's `events.Paths`). Only the prefix that
/// fit the caller's buffer was written, so the caller checks both totals
/// against its limits before it reads the buffer.
pub const Selection = struct {
    count: u32,
    bytes_len: u64,
};

/// Append the OpenFile options: the request token, multiple selection,
/// folder mode, and modality.
fn appendOpenOptions(
    dict_iter: *dbus.MessageIter,
    request_token: [:0]const u8,
    options: *const PathPromptOptions,
) !void {
    std.debug.assert(request_token.len > 0);
    std.debug.assert(options.files or options.directories);

    // handle_token
    try appendDictEntryString(dict_iter, "handle_token", request_token);

    // multiple selection
    try appendDictEntryBool(dict_iter, "multiple", options.multiple);

    // directory mode
    try appendDictEntryBool(dict_iter, "directory", options.directories);

    // modal
    try appendDictEntryBool(dict_iter, "modal", true);
}

/// Append the SaveFile options: the request token, modality, and the
/// starting folder and suggested file name when the app gave them.
fn appendSaveOptions(
    dict_iter: *dbus.MessageIter,
    request_token: [:0]const u8,
    options: *const SavePromptOptions,
) !void {
    std.debug.assert(request_token.len > 0);
    if (options.suggested_name) |name| std.debug.assert(name.len > 0);

    // handle_token
    try appendDictEntryString(dict_iter, "handle_token", request_token);

    // modal
    try appendDictEntryBool(dict_iter, "modal", true);

    // current_folder (starting directory)
    if (options.directory) |dir| {
        try appendDictEntryBytes(dict_iter, "current_folder", dir);
    }

    // current_name (suggested filename)
    if (options.suggested_name) |name| {
        var name_buf: [256:0]u8 = undefined;
        const name_z = toSentinelSlice(name, &name_buf) orelse return error.NameTooLong;
        try appendDictEntryString(dict_iter, "current_name", name_z);
    }
}

// =============================================================================
// Response Handling
// =============================================================================

/// Wait for the portal Response signal and convert its URIs to paths. The
/// strings belong to the signal message, so they are converted into
/// `allocator` before the message is freed; nothing else is allocated.
fn waitForResponse(
    allocator: std.mem.Allocator,
    conn: *dbus.Connection,
    handle_path: [:0]const u8,
) !?PathPromptResult {
    // buildHandlePath produces every handle under the portal's request path.
    const request_path_prefix = "/org/freedesktop/portal/desktop/request/";
    std.debug.assert(handle_path.len > request_path_prefix.len);
    std.debug.assert(std.mem.startsWith(u8, handle_path, request_path_prefix));
    var iterations: u32 = 0;

    while (iterations < MAX_SIGNAL_WAIT_ITERATIONS) : (iterations += 1) {
        // Read any available data
        _ = conn.readWrite(SIGNAL_WAIT_TIMEOUT_MS);

        // Process all pending messages
        while (conn.popMessage()) |*msg_ptr| {
            var signal_msg = msg_ptr.*;
            defer signal_msg.deinit();

            if (!isResponse(&signal_msg, handle_path)) continue;
            var uris = try responseUris(&signal_msg) orelse return null;
            return urisToPathResult(allocator, &uris);
        }
    }

    return error.Timeout;
}

/// Whether `message` is the Response signal of the request at `handle_path`.
fn isResponse(message: *dbus.Message, handle_path: [:0]const u8) bool {
    std.debug.assert(handle_path.len > 0);
    if (message.getType() != dbus.MESSAGE_TYPE_SIGNAL) return false;
    const path = message.getPath() orelse return false;
    if (!std.mem.eql(u8, path, handle_path)) return false;
    return message.isSignal(dbus.PORTAL_REQUEST_INTERFACE, "Response");
}

/// Read a portal Response signal: null for a cancel, otherwise an iterator
/// over the `as` array of the "uris" entry in its results, valid while the
/// message lives.
fn responseUris(signal_msg: *dbus.Message) !?dbus.MessageIter {
    std.debug.assert(signal_msg.getType() == dbus.MESSAGE_TYPE_SIGNAL);
    std.debug.assert(signal_msg.isSignal(dbus.PORTAL_REQUEST_INTERFACE, "Response"));
    var iter = signal_msg.iterInit() orelse return error.InvalidResponse;

    // First argument: response code (u32)
    if (iter.getArgType() != dbus.TYPE_UINT32) return error.InvalidResponse;
    const response_code = iter.getUint32();

    // The portal's codes: 0 success, 1 cancelled by the user, 2 the
    // interaction ended some other way, which GNOME's portal sends
    // for Escape. Both 1 and 2 are a cancel, not an error.
    if (response_code == 1 or response_code == 2) return null;
    if (response_code != 0) return error.PortalError;

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
            return variant_iter;
        }

        _ = dict_iter.next();
    }

    return error.NoUrisInResponse;
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

    // Decode percent-encoded characters; decoding never lengthens the path.
    var decoded = allocator.alloc(u8, uri.len - prefix.len) catch return null;
    const decoded_len = decodeUri(uri, decoded);
    std.debug.assert(decoded_len <= decoded.len);

    // Shrink to actual size by duplicating to right size
    const result = allocator.dupe(u8, decoded[0..decoded_len]) catch {
        allocator.free(decoded);
        return null;
    };
    allocator.free(decoded);
    return result;
}

/// Decode one URI to a path: strip `file://` and decode percent escapes, or
/// keep a URI without that prefix as it is. Writes the prefix of the path
/// that fits `out` and returns the path's whole length.
fn decodeUri(uri: []const u8, out: []u8) usize {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        const kept = @min(uri.len, out.len);
        @memcpy(out[0..kept], uri[0..kept]);
        return uri.len;
    }
    const encoded_path = uri[prefix.len..];
    var write_idx: usize = 0;
    var read_idx: usize = 0;
    // Each step consumes one byte or one three-byte escape.
    while (read_idx < encoded_path.len) {
        var byte = encoded_path[read_idx];
        var consumed: usize = 1;
        if (byte == '%' and read_idx + 2 < encoded_path.len) {
            const hex = encoded_path[read_idx + 1 .. read_idx + 3];
            if (std.fmt.parseInt(u8, hex, 16)) |value| {
                byte = value;
                consumed = 3;
            } else |_| {}
        }
        if (write_idx < out.len) out[write_idx] = byte;
        write_idx += 1;
        read_idx += consumed;
    }
    std.debug.assert(write_idx <= encoded_path.len);
    return write_idx;
}

/// Decode a Response's `as` URI array into `out` as NUL-joined paths,
/// writing only what fits, and return the whole selection's totals.
fn joinUris(array: *dbus.MessageIter, out: []u8) !Selection {
    std.debug.assert(array.getArgType() == dbus.TYPE_ARRAY);
    var uri_iter = array.recurse();
    var count: u32 = 0;
    var bytes_len: u64 = 0;
    while (uri_iter.getArgType() == dbus.TYPE_STRING) : (count += 1) {
        if (count == response_uri_count_max) return error.InvalidResponse;
        const uri = uri_iter.getString() orelse return error.InvalidResponse;
        if (count > 0) {
            if (bytes_len < out.len) out[@intCast(bytes_len)] = separator;
            bytes_len += 1;
        }
        const start: usize = @intCast(@min(bytes_len, out.len));
        const path_len = decodeUri(uri, out[start..]);
        // An empty path, or one holding the separator, cannot be joined.
        if (path_len == 0) return error.InvalidResponse;
        const written = out[start..][0..@min(path_len, out.len - start)];
        if (std.mem.indexOfScalar(u8, written, separator) != null) return error.InvalidResponse;
        bytes_len += path_len;
        _ = uri_iter.next();
    }
    if (count == 0) return error.NoUrisInResponse;
    std.debug.assert(bytes_len >= count);
    return .{ .count = count, .bytes_len = bytes_len };
}

/// Convert the response's `as` URI array to paths in `allocator`, keeping
/// at most `MAX_URIS`. Returns null when there are none or one fails to
/// convert (out of scratch).
fn urisToPathResult(allocator: std.mem.Allocator, array: *dbus.MessageIter) ?PathPromptResult {
    std.debug.assert(array.getArgType() == dbus.TYPE_ARRAY);
    var count_iter = array.recurse();
    var count: usize = 0;
    while (count_iter.getArgType() == dbus.TYPE_STRING and count < MAX_URIS) {
        count += 1;
        if (!count_iter.next()) break;
    }
    if (count == 0) return null;

    // Every URI must convert: the result owns exactly `count` paths, so
    // `PathPromptResult.deinit` frees the array at the size it was allocated.
    const paths = allocator.alloc([]const u8, count) catch return null;
    var converted: usize = 0;
    var uri_iter = array.recurse();
    while (converted < count) : (converted += 1) {
        const path = if (uri_iter.getString()) |uri| uriToPath(allocator, uri) else null;
        paths[converted] = path orelse {
            for (paths[0..converted]) |done| allocator.free(done);
            allocator.free(paths);
            return null;
        };
        _ = uri_iter.next();
    }
    std.debug.assert(converted == count);
    return .{ .paths = paths, .allocator = allocator };
}

// =============================================================================
// D-Bus Message Building Helpers
// =============================================================================

/// Generate a unique token for request handles
fn generateToken(buf: *[64]u8) [:0]const u8 {
    // Use timestamp for uniqueness. std.posix.clock_gettime was removed in
    // Zig 0.16 (see "posix and os.windows removals" in the 0.16.0 release
    // notes). We link libc on Linux, so call the libc symbol directly and
    // fall back to a fixed value on failure — the token only needs to be
    // unique-ish per request.
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 12345 };
    _ = std.c.clock_gettime(.REALTIME, &ts);

    const hash: u64 = @bitCast(ts.sec *% 1000000000 +% ts.nsec);
    // "gooey_" and at most 16 hex digits fit the 63 bytes, so it cannot fail.
    const len = std.fmt.bufPrint(buf[0..63], "gooey_{x}", .{hash}) catch unreachable;
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
    const format = "type='signal',interface='{s}',member='Response',path='{s}'";
    const len = std.fmt.bufPrint(buf[0..511], format, .{
        dbus.PORTAL_REQUEST_INTERFACE,
        handle_path,
    }) catch return error.RuleTooLong;
    buf[len.len] = 0;
    return buf[0..len.len :0];
}

/// Append a dict entry with string value: {key: variant<string>}
fn appendDictEntryString(
    dict_iter: *dbus.MessageIter,
    key: [:0]const u8,
    value: [:0]const u8,
) !void {
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse
        return error.ContainerFailed;

    if (!entry.appendString(key)) return error.AppendFailed;

    var variant = entry.openContainer(dbus.TYPE_VARIANT, "s") orelse return error.ContainerFailed;
    if (!variant.appendString(value)) return error.AppendFailed;
    if (!entry.closeContainer(&variant)) return error.ContainerFailed;

    if (!dict_iter.closeContainer(&entry)) return error.ContainerFailed;
}

/// Append a dict entry with boolean value: {key: variant<bool>}
fn appendDictEntryBool(dict_iter: *dbus.MessageIter, key: [:0]const u8, value: bool) !void {
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse
        return error.ContainerFailed;

    if (!entry.appendString(key)) return error.AppendFailed;

    var variant = entry.openContainer(dbus.TYPE_VARIANT, "b") orelse return error.ContainerFailed;
    if (!variant.appendBool(value)) return error.AppendFailed;
    if (!entry.closeContainer(&variant)) return error.ContainerFailed;

    if (!dict_iter.closeContainer(&entry)) return error.ContainerFailed;
}

/// Append a dict entry with byte array value: {key: variant<ay>}
fn appendDictEntryBytes(dict_iter: *dbus.MessageIter, key: [:0]const u8, value: []const u8) !void {
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse
        return error.ContainerFailed;

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
    if (@import("builtin").mode == .debug) {
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
