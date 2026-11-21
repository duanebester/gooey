const std = @import("std");
const dbus = @import("dbus.zig");
const interface_mod = @import("../interface.zig");

pub const PathPromptOptions = interface_mod.PathPromptOptions;
pub const PathPromptResult = interface_mod.PathPromptResult;
pub const SavePromptOptions = interface_mod.SavePromptOptions;

const response_uri_count_max: u32 = 1 << 20;
const separator: u8 = 0;

/// Host dialog-buffer bytes for `dialog_path_bytes_max`: a selection's
/// paths, or a save request's folder and name with a terminator each.
pub fn requestBytes(path_bytes_max: u32) u32 {
    std.debug.assert(path_bytes_max > 0);
    std.debug.assert(path_bytes_max < std.math.maxInt(u32) - 2);
    return path_bytes_max + 2;
}

/// One FileChooser request on a private session-bus connection. The core
/// host polls the connection's fd beside the Wayland fd and calls `poll`
/// per loop turn, so its window keeps running; strings live in the
/// request's own buffers, so it holds no pointer into itself.
pub const PortalRequest = struct {
    connection: dbus.Connection,
    token_buffer: [64]u8,
    token_len: u32,
    handle_buffer: [256]u8,
    handle_len: u32,
    match_buffer: [512]u8,
    match_len: u32,

    pub const messages_per_poll_max: u32 = 64;

    /// Bounded per call; a private connection carries few messages.
    pub const Options = union(enum) {
        open: *const PathPromptOptions,
        save: *const SavePromptOptions,
    };

    pub const Status = union(enum) {
        open,
        /// fd will not re-announce queued messages; call again soon.
        open_more,
        cancelled,
        selected: Selection,
    };

    /// On success `end` or `close` must follow; `strings` is sized with
    /// `requestBytes`.
    pub fn begin(self: *PortalRequest, options: Options, strings: []u8) !void {
        std.debug.assert(strings.len >= 2);
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
        // Portal requires a fixed title (the app's was dropped).
        var message = try dbus.Message.newMethodCall(
            dbus.PORTAL_BUS_NAME,
            dbus.PORTAL_OBJECT_PATH,
            dbus.PORTAL_FILE_CHOOSER_INTERFACE,
            method,
        );
        defer message.deinit();

        var iter = message.iterInitAppend();
        if (!iter.appendString("")) return error.AppendFailed;
        if (!iter.appendString(title)) return error.AppendFailed;
        var dict_iter = iter.openContainer(dbus.TYPE_ARRAY, "{sv}") orelse
            return error.ContainerFailed;
        switch (options) {
            .open => |open| try appendOpenOptions(&dict_iter, self.token(), open),
            .save => |save| try appendSaveOptions(&dict_iter, self.token(), save, strings),
        }
        if (!iter.closeContainer(&dict_iter)) return error.ContainerFailed;

        var reply = try self.connection.callMethod(&message, dbus.TIMEOUT_USE_DEFAULT);
        reply.deinit();
        std.debug.assert(self.handle_len > 0);
    }

    /// Non-blocking read of what has arrived, decoding selected paths.
    pub fn poll(self: *PortalRequest, paths: []u8) !Status {
        std.debug.assert(paths.len > 0);
        std.debug.assert(self.handle_len > 0);
        // Zero timeout reads only what is available.
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

    /// Unsubscribe and close; the request is undefined afterwards.
    pub fn end(self: *PortalRequest) void {
        std.debug.assert(self.match_len > 0);
        self.connection.removeMatch(self.matchRule());
        self.connection.deinit();
        self.* = undefined;
    }

    /// Ask the portal to close the open dialog, then `end`.
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

    /// Socket to poll beside other fds; null for a non-socket bus.
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

    /// Subscribe to the Response before the call is sent, so the signal
    /// cannot arrive unheard.
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

/// Response selection: `count` paths NUL-joined (the core's `events.Paths`
/// layout); only the prefix that fit the caller's buffer was written.
pub const Selection = struct {
    count: u32,
    bytes_len: u64,
};

fn appendOpenOptions(
    dict_iter: *dbus.MessageIter,
    request_token: [:0]const u8,
    options: *const PathPromptOptions,
) !void {
    std.debug.assert(request_token.len > 0);
    std.debug.assert(options.files or options.directories);

    try appendDictEntryString(dict_iter, "handle_token", request_token);

    try appendDictEntryBool(dict_iter, "multiple", options.multiple);

    try appendDictEntryBool(dict_iter, "directory", options.directories);

    try appendDictEntryBool(dict_iter, "modal", true);
}

fn appendSaveOptions(
    dict_iter: *dbus.MessageIter,
    request_token: [:0]const u8,
    options: *const SavePromptOptions,
    strings: []u8,
) !void {
    std.debug.assert(request_token.len > 0);
    if (options.suggested_name) |name| std.debug.assert(name.len > 0);

    try appendDictEntryString(dict_iter, "handle_token", request_token);

    try appendDictEntryBool(dict_iter, "modal", true);

    var used: usize = 0;
    if (options.directory) |dir| {
        const folder = terminated(strings, dir);
        used = folder.len + 1;
        try appendDictEntryBytes(dict_iter, "current_folder", folder[0 .. folder.len + 1]);
    }

    if (options.suggested_name) |name| {
        try appendDictEntryString(dict_iter, "current_name", terminated(strings[used..], name));
    }
}

fn isResponse(message: *dbus.Message, handle_path: [:0]const u8) bool {
    std.debug.assert(handle_path.len > 0);
    if (message.getType() != dbus.MESSAGE_TYPE_SIGNAL) return false;
    const path = message.getPath() orelse return false;
    if (!std.mem.eql(u8, path, handle_path)) return false;
    return message.isSignal(dbus.PORTAL_REQUEST_INTERFACE, "Response");
}

/// Null for a cancel; otherwise an iterator over the "uris" string array,
/// valid while the message lives.
fn responseUris(signal_msg: *dbus.Message) !?dbus.MessageIter {
    std.debug.assert(signal_msg.getType() == dbus.MESSAGE_TYPE_SIGNAL);
    std.debug.assert(signal_msg.isSignal(dbus.PORTAL_REQUEST_INTERFACE, "Response"));
    var iter = signal_msg.iterInit() orelse return error.InvalidResponse;

    if (iter.getArgType() != dbus.TYPE_UINT32) return error.InvalidResponse;
    const response_code = iter.getUint32();

    // Portal codes: 0 success, 1 user-cancelled, 2 other (GNOME sends 2
    // for Escape); both 1 and 2 are a cancel, not an error.
    if (response_code == 1 or response_code == 2) return null;
    if (response_code != 0) return error.PortalError;

    if (!iter.next()) return error.InvalidResponse;
    if (iter.getArgType() != dbus.TYPE_ARRAY) return error.InvalidResponse;

    var dict_iter = iter.recurse();
    while (dict_iter.getArgType() == dbus.TYPE_DICT_ENTRY) {
        var entry_iter = dict_iter.recurse();

        if (entry_iter.getArgType() != dbus.TYPE_STRING) {
            _ = dict_iter.next();
            continue;
        }
        const key = entry_iter.getString() orelse {
            _ = dict_iter.next();
            continue;
        };

        if (std.mem.eql(u8, key, "uris")) {
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

fn generateToken(buf: *[64]u8) [:0]const u8 {
    // std.posix.clock_gettime was removed in Zig 0.16; call libc directly.
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 12345 };
    _ = std.c.clock_gettime(.REALTIME, &ts);

    const hash: u64 = @bitCast(ts.sec *% 1000000000 +% ts.nsec);
    // "gooey_" plus at most 16 hex digits fit the 63 bytes.
    const len = std.fmt.bufPrint(buf[0..63], "gooey_{x}", .{hash}) catch unreachable;
    buf[len.len] = 0;
    return buf[0..len.len :0];
}

fn buildHandlePath(buf: *[256]u8, unique_name: []const u8, token: [:0]const u8) ![:0]const u8 {
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

fn buildMatchRule(buf: *[512]u8, handle_path: [:0]const u8) ![:0]const u8 {
    const format = "type='signal',interface='{s}',member='Response',path='{s}'";
    const len = std.fmt.bufPrint(buf[0..511], format, .{
        dbus.PORTAL_REQUEST_INTERFACE,
        handle_path,
    }) catch return error.RuleTooLong;
    buf[len.len] = 0;
    return buf[0..len.len :0];
}

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

fn appendDictEntryBool(dict_iter: *dbus.MessageIter, key: [:0]const u8, value: bool) !void {
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse
        return error.ContainerFailed;

    if (!entry.appendString(key)) return error.AppendFailed;

    var variant = entry.openContainer(dbus.TYPE_VARIANT, "b") orelse return error.ContainerFailed;
    if (!variant.appendBool(value)) return error.AppendFailed;
    if (!entry.closeContainer(&variant)) return error.ContainerFailed;

    if (!dict_iter.closeContainer(&entry)) return error.ContainerFailed;
}

/// Append a dict entry with byte array value: {key: variant<ay>}. The portal
/// expects the bytes NUL-terminated, so `value` ends with its terminator.
fn appendDictEntryBytes(dict_iter: *dbus.MessageIter, key: [:0]const u8, value: []const u8) !void {
    std.debug.assert(value.len > 0);
    std.debug.assert(value[value.len - 1] == 0);
    var entry = dict_iter.openContainer(dbus.TYPE_DICT_ENTRY, null) orelse
        return error.ContainerFailed;

    if (!entry.appendString(key)) return error.AppendFailed;

    var variant = entry.openContainer(dbus.TYPE_VARIANT, "ay") orelse return error.ContainerFailed;

    if (!variant.appendBytes(value)) return error.AppendFailed;
    if (!entry.closeContainer(&variant)) return error.ContainerFailed;

    if (!dict_iter.closeContainer(&entry)) return error.ContainerFailed;
}

/// Copy `text` into the front of `target` with a terminator; the core's
/// request copy bounds every string, so it always fits.
fn terminated(target: []u8, text: []const u8) [:0]const u8 {
    std.debug.assert(text.len < target.len);
    std.debug.assert(std.mem.indexOfScalar(u8, text, 0) == null);
    @memcpy(target[0..text.len], text);
    target[text.len] = 0;
    return target[0..text.len :0];
}

fn logError(context: []const u8, err: anyerror) void {
    if (@import("builtin").mode == .debug) {
        std.log.err("file_dialog: {s}: {}", .{ context, err });
    }
}

test "URI to path conversion" {
    var out: [32]u8 = undefined;

    var len = decodeUri("file:///home/user/test.txt", &out);
    try std.testing.expectEqualStrings("/home/user/test.txt", out[0..len]);

    len = decodeUri("file:///home/user/my%20file.txt", &out);
    try std.testing.expectEqualStrings("/home/user/my file.txt", out[0..len]);

    len = decodeUri("/direct/path/test.txt", &out);
    try std.testing.expectEqualStrings("/direct/path/test.txt", out[0..len]);

    // A path longer than `out` reports its whole length and writes a prefix.
    var short: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 19), decodeUri("file:///home/user/test.txt", &short));
    try std.testing.expectEqualStrings("/hom", &short);
}

test "terminated fills its target exactly" {
    var strings: [requestBytes(7)]u8 = undefined;
    const folder = terminated(&strings, "/tmp");
    try std.testing.expectEqualStrings("/tmp", folder);
    const name = terminated(strings[folder.len + 1 ..], "a.c");
    try std.testing.expectEqualStrings("a.c", name);
    try std.testing.expectEqual(@as(u8, 0), strings[strings.len - 1]);
}

test "token generation produces valid identifier" {
    var buf: [64]u8 = undefined;
    const token = generateToken(&buf);

    try std.testing.expect(token.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, token, "gooey_"));
}
