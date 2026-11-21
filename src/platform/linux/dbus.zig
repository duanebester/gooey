const std = @import("std");
const builtin = @import("builtin");

pub const TYPE_BYTE: c_int = 'y';
pub const TYPE_BOOLEAN: c_int = 'b';
pub const TYPE_UINT32: c_int = 'u';
pub const TYPE_STRING: c_int = 's';
pub const TYPE_ARRAY: c_int = 'a';
pub const TYPE_VARIANT: c_int = 'v';
pub const TYPE_DICT_ENTRY: c_int = 'e';

pub const BUS_SESSION: c_int = 0;

pub const MESSAGE_TYPE_SIGNAL: c_int = 4;

pub const TIMEOUT_USE_DEFAULT: c_int = -1;

pub const PORTAL_BUS_NAME = "org.freedesktop.portal.Desktop";
pub const PORTAL_OBJECT_PATH = "/org/freedesktop/portal/desktop";
pub const PORTAL_FILE_CHOOSER_INTERFACE = "org.freedesktop.portal.FileChooser";
pub const PORTAL_REQUEST_INTERFACE = "org.freedesktop.portal.Request";

pub const DBusConnection = opaque {};
pub const DBusMessage = opaque {};
pub const DBusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    dummy1: c_uint = 0,
    dummy2: c_uint = 0,
    dummy3: c_uint = 0,
    dummy4: c_uint = 0,
    dummy5: c_uint = 0,
    padding1: ?*anyopaque = null,
};

pub const DBusMessageIter = extern struct {
    dummy1: ?*anyopaque = null,
    dummy2: ?*anyopaque = null,
    dummy3: c_uint = 0,
    dummy4: c_int = 0,
    dummy5: c_int = 0,
    dummy6: c_int = 0,
    dummy7: c_int = 0,
    dummy8: c_int = 0,
    dummy9: c_int = 0,
    dummy10: c_int = 0,
    dummy11: c_int = 0,
    pad1: c_int = 0,
    pad2: ?*anyopaque = null,
    pad3: ?*anyopaque = null,
};

pub const DBusBasicValue = extern union {
    bytes: [8]u8,
    i16: i16,
    u16: u16,
    i32: i32,
    u32: u32,
    bool_val: u32, // D-Bus booleans are 32-bit
    i64: i64,
    u64: u64,
    dbl: f64,
    str: ?[*:0]const u8,
    fd: c_int,
};

pub extern fn dbus_error_init(err: *DBusError) void;
pub extern fn dbus_error_free(err: *DBusError) void;
pub extern fn dbus_error_is_set(err: *const DBusError) c_uint;

pub extern fn dbus_bus_get_private(bus_type: c_int, err: *DBusError) ?*DBusConnection;
pub extern fn dbus_connection_close(connection: *DBusConnection) void;
pub extern fn dbus_connection_unref(connection: *DBusConnection) void;
pub extern fn dbus_connection_flush(connection: *DBusConnection) void;
pub extern fn dbus_connection_read_write(connection: *DBusConnection, timeout_milliseconds: c_int) c_uint;
pub extern fn dbus_connection_dispatch(connection: *DBusConnection) c_int;
pub extern fn dbus_connection_send_with_reply_and_block(connection: *DBusConnection, message: *DBusMessage, timeout_milliseconds: c_int, err: *DBusError) ?*DBusMessage;
pub extern fn dbus_connection_pop_message(connection: *DBusConnection) ?*DBusMessage;
pub extern fn dbus_connection_send(
    connection: *DBusConnection,
    message: *DBusMessage,
    serial: ?*u32,
) c_uint;
pub extern fn dbus_connection_get_unix_fd(connection: *DBusConnection, fd: *c_int) c_uint;
pub extern fn dbus_bus_add_match(connection: *DBusConnection, rule: [*:0]const u8, err: *DBusError) void;
pub extern fn dbus_bus_remove_match(connection: *DBusConnection, rule: [*:0]const u8, err: *DBusError) void;
pub extern fn dbus_bus_get_unique_name(connection: *DBusConnection) ?[*:0]const u8;

pub extern fn dbus_message_new_method_call(bus_name: ?[*:0]const u8, path: [*:0]const u8, iface: ?[*:0]const u8, method: [*:0]const u8) ?*DBusMessage;
pub extern fn dbus_message_unref(message: *DBusMessage) void;

pub extern fn dbus_message_get_type(message: *DBusMessage) c_int;
pub extern fn dbus_message_get_path(message: *DBusMessage) ?[*:0]const u8;
pub extern fn dbus_message_is_signal(message: *DBusMessage, iface: [*:0]const u8, signal_name: [*:0]const u8) c_uint;

pub extern fn dbus_message_iter_init(message: *DBusMessage, iter: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_init_append(message: *DBusMessage, iter: *DBusMessageIter) void;
pub extern fn dbus_message_iter_next(iter: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_get_arg_type(iter: *DBusMessageIter) c_int;
pub extern fn dbus_message_iter_recurse(iter: *DBusMessageIter, sub: *DBusMessageIter) void;
pub extern fn dbus_message_iter_get_basic(iter: *DBusMessageIter, value: *DBusBasicValue) void;
pub extern fn dbus_message_iter_append_basic(iter: *DBusMessageIter, arg_type: c_int, value: *const anyopaque) c_uint;
pub extern fn dbus_message_iter_append_fixed_array(iter: *DBusMessageIter, element_type: c_int, value: *const anyopaque, n_elements: c_int) c_uint;
pub extern fn dbus_message_iter_open_container(iter: *DBusMessageIter, container_type: c_int, contained_signature: ?[*:0]const u8, sub: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_close_container(iter: *DBusMessageIter, sub: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_abandon_container(iter: *DBusMessageIter, sub: *DBusMessageIter) void;

pub const Error = error{
    ConnectionFailed,
    MessageCreationFailed,
    MessageSendFailed,
    InvalidReply,
    Timeout,
    DBusError,
    OutOfMemory,
};

pub const ErrorState = struct {
    inner: DBusError = .{},

    const Self = @This();

    pub fn init() Self {
        var self = Self{};
        dbus_error_init(&self.inner);
        return self;
    }

    pub fn deinit(self: *Self) void {
        dbus_error_free(&self.inner);
    }

    pub fn isSet(self: *const Self) bool {
        return dbus_error_is_set(&self.inner) != 0;
    }

    pub fn getName(self: *const Self) ?[]const u8 {
        if (self.inner.name) |name| {
            return std.mem.span(name);
        }
        return null;
    }
};

pub const Connection = struct {
    conn: *DBusConnection,
    is_private: bool,

    const Self = @This();

    /// Private connection: must be explicitly closed.
    pub fn connectSessionPrivate() Error!Self {
        var err = ErrorState.init();
        defer err.deinit();

        const conn = dbus_bus_get_private(BUS_SESSION, &err.inner) orelse {
            return Error.ConnectionFailed;
        };

        return Self{
            .conn = conn,
            .is_private = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.is_private) {
            dbus_connection_close(self.conn);
        }
        dbus_connection_unref(self.conn);
    }

    pub fn flush(self: *Self) void {
        dbus_connection_flush(self.conn);
    }

    pub fn getUniqueName(self: *Self) ?[]const u8 {
        if (dbus_bus_get_unique_name(self.conn)) |name| {
            return std.mem.span(name);
        }
        return null;
    }

    pub fn addMatch(self: *Self, rule: [:0]const u8) Error!void {
        var err = ErrorState.init();
        defer err.deinit();

        dbus_bus_add_match(self.conn, rule.ptr, &err.inner);

        if (err.isSet()) {
            return Error.DBusError;
        }
    }

    pub fn removeMatch(self: *Self, rule: [:0]const u8) void {
        var err = ErrorState.init();
        defer err.deinit();

        dbus_bus_remove_match(self.conn, rule.ptr, &err.inner);
    }

    pub fn callMethod(self: *Self, message: *Message, timeout_ms: c_int) Error!Message {
        var err = ErrorState.init();
        defer err.deinit();

        const reply = dbus_connection_send_with_reply_and_block(
            self.conn,
            message.msg,
            timeout_ms,
            &err.inner,
        ) orelse {
            if (err.isSet()) {
                return Error.DBusError;
            }
            return Error.InvalidReply;
        };

        return Message{ .msg = reply };
    }

    /// Queue a message without waiting for a reply; `flush` sends it.
    pub fn send(self: *Self, message: *Message) Error!void {
        if (dbus_connection_send(self.conn, message.msg, null) == 0) return Error.OutOfMemory;
    }

    /// The connection's socket, for a caller that polls it with other fds.
    pub fn unixFd(self: *Self) ?std.posix.fd_t {
        var fd: c_int = -1;
        if (dbus_connection_get_unix_fd(self.conn, &fd) == 0) return null;
        std.debug.assert(fd >= 0);
        return fd;
    }

    pub fn readWrite(self: *Self, timeout_ms: c_int) bool {
        return dbus_connection_read_write(self.conn, timeout_ms) != 0;
    }

    pub fn popMessage(self: *Self) ?Message {
        if (dbus_connection_pop_message(self.conn)) |msg| {
            return Message{ .msg = msg };
        }
        return null;
    }

    pub fn dispatch(self: *Self) c_int {
        return dbus_connection_dispatch(self.conn);
    }
};

pub const Message = struct {
    msg: *DBusMessage,

    const Self = @This();

    pub fn newMethodCall(
        bus_name: ?[:0]const u8,
        path: [:0]const u8,
        iface: ?[:0]const u8,
        method: [:0]const u8,
    ) Error!Self {
        const msg = dbus_message_new_method_call(
            if (bus_name) |b| b.ptr else null,
            path.ptr,
            if (iface) |i| i.ptr else null,
            method.ptr,
        ) orelse return Error.MessageCreationFailed;

        return Self{ .msg = msg };
    }

    pub fn deinit(self: *Self) void {
        dbus_message_unref(self.msg);
    }

    pub fn getType(self: *const Self) c_int {
        return dbus_message_get_type(self.msg);
    }

    pub fn getPath(self: *const Self) ?[]const u8 {
        if (dbus_message_get_path(self.msg)) |path| {
            return std.mem.span(path);
        }
        return null;
    }

    pub fn isSignal(self: *const Self, iface: [:0]const u8, signal_name: [:0]const u8) bool {
        return dbus_message_is_signal(self.msg, iface.ptr, signal_name.ptr) != 0;
    }

    pub fn iterInit(self: *Self) ?MessageIter {
        var iter = MessageIter{};
        if (dbus_message_iter_init(self.msg, &iter.inner) == 0) {
            return null; // No arguments
        }
        return iter;
    }

    pub fn iterInitAppend(self: *Self) MessageIter {
        var iter = MessageIter{};
        dbus_message_iter_init_append(self.msg, &iter.inner);
        return iter;
    }
};

pub const MessageIter = struct {
    inner: DBusMessageIter = .{},

    const Self = @This();

    pub fn next(self: *Self) bool {
        return dbus_message_iter_next(&self.inner) != 0;
    }

    pub fn getArgType(self: *Self) c_int {
        return dbus_message_iter_get_arg_type(&self.inner);
    }

    pub fn recurse(self: *Self) Self {
        var sub = Self{};
        dbus_message_iter_recurse(&self.inner, &sub.inner);
        return sub;
    }

    pub fn getString(self: *Self) ?[]const u8 {
        var value: DBusBasicValue = undefined;
        dbus_message_iter_get_basic(&self.inner, &value);
        if (value.str) |str| {
            return std.mem.span(str);
        }
        return null;
    }

    pub fn getUint32(self: *Self) u32 {
        var value: DBusBasicValue = undefined;
        dbus_message_iter_get_basic(&self.inner, &value);
        return value.u32;
    }

    pub fn appendString(self: *Self, str: [:0]const u8) bool {
        const ptr: *const [*:0]const u8 = &str.ptr;
        return dbus_message_iter_append_basic(&self.inner, TYPE_STRING, @ptrCast(ptr)) != 0;
    }

    pub fn appendBool(self: *Self, value: bool) bool {
        const dbus_bool: u32 = if (value) 1 else 0;
        return dbus_message_iter_append_basic(&self.inner, TYPE_BOOLEAN, &dbus_bool) != 0;
    }

    /// Append raw bytes (for "ay" type - byte array)
    pub fn appendBytes(self: *Self, bytes: []const u8) bool {
        var sub = Self{};
        if (dbus_message_iter_open_container(&self.inner, TYPE_ARRAY, "y", &sub.inner) == 0) {
            return false;
        }
        if (bytes.len > 0) {
            const ptr: *const [*]const u8 = &bytes.ptr;
            if (dbus_message_iter_append_fixed_array(&sub.inner, TYPE_BYTE, @ptrCast(ptr), @intCast(bytes.len)) == 0) {
                dbus_message_iter_abandon_container(&self.inner, &sub.inner);
                return false;
            }
        }
        return dbus_message_iter_close_container(&self.inner, &sub.inner) != 0;
    }

    pub fn openContainer(self: *Self, container_type: c_int, signature: ?[:0]const u8) ?Self {
        var sub = Self{};
        const sig_ptr: ?[*:0]const u8 = if (signature) |s| s.ptr else null;
        if (dbus_message_iter_open_container(&self.inner, container_type, sig_ptr, &sub.inner) == 0) {
            return null;
        }
        return sub;
    }

    pub fn closeContainer(self: *Self, sub: *Self) bool {
        return dbus_message_iter_close_container(&self.inner, &sub.inner) != 0;
    }
};

test "ErrorState init/deinit" {
    var err = ErrorState.init();
    defer err.deinit();

    try std.testing.expect(!err.isSet());
}

test "DBusError size check" {
    comptime {
        std.debug.assert(@sizeOf(DBusError) >= 32);
    }
}

test "DBusMessageIter size check" {
    // Large enough for libdbus internals.
    comptime {
        std.debug.assert(@sizeOf(DBusMessageIter) >= 64);
    }
}
