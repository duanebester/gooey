//! D-Bus Bindings for Linux
//!
//! Low-level bindings to libdbus-1 for portal integration.
//! Used primarily for XDG Desktop Portal communication (file dialogs, etc.)
//!
//! ## Design Notes
//!
//! - Links dynamically to libdbus-1 (available on virtually all Linux systems)
//! - Provides type-safe Zig wrappers around C API
//! - Focuses on session bus operations (portals use session bus)
//! - Supports both synchronous calls and signal handling

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Constants
// =============================================================================

/// D-Bus type signatures
pub const TYPE_INVALID: c_int = 0;
pub const TYPE_BYTE: c_int = 'y';
pub const TYPE_BOOLEAN: c_int = 'b';
pub const TYPE_INT16: c_int = 'n';
pub const TYPE_UINT16: c_int = 'q';
pub const TYPE_INT32: c_int = 'i';
pub const TYPE_UINT32: c_int = 'u';
pub const TYPE_INT64: c_int = 'x';
pub const TYPE_UINT64: c_int = 't';
pub const TYPE_DOUBLE: c_int = 'd';
pub const TYPE_STRING: c_int = 's';
pub const TYPE_OBJECT_PATH: c_int = 'o';
pub const TYPE_SIGNATURE: c_int = 'g';
pub const TYPE_ARRAY: c_int = 'a';
pub const TYPE_VARIANT: c_int = 'v';
pub const TYPE_STRUCT: c_int = 'r';
pub const TYPE_DICT_ENTRY: c_int = 'e';
pub const TYPE_UNIX_FD: c_int = 'h';

/// Struct begin/end markers (for signature building)
pub const STRUCT_BEGIN_CHAR: c_int = '(';
pub const STRUCT_END_CHAR: c_int = ')';
pub const DICT_ENTRY_BEGIN_CHAR: c_int = '{';
pub const DICT_ENTRY_END_CHAR: c_int = '}';

/// Bus types
pub const BUS_SESSION: c_int = 0;
pub const BUS_SYSTEM: c_int = 1;
pub const BUS_STARTER: c_int = 2;

/// Message types
pub const MESSAGE_TYPE_INVALID: c_int = 0;
pub const MESSAGE_TYPE_METHOD_CALL: c_int = 1;
pub const MESSAGE_TYPE_METHOD_RETURN: c_int = 2;
pub const MESSAGE_TYPE_ERROR: c_int = 3;
pub const MESSAGE_TYPE_SIGNAL: c_int = 4;

/// Handler results
pub const HANDLER_RESULT_HANDLED: c_int = 0;
pub const HANDLER_RESULT_NOT_YET_HANDLED: c_int = 1;
pub const HANDLER_RESULT_NEED_MEMORY: c_int = 2;

/// Dispatch status
pub const DISPATCH_DATA_REMAINS: c_int = 0;
pub const DISPATCH_COMPLETE: c_int = 1;
pub const DISPATCH_NEED_MEMORY: c_int = 2;

/// Timeout constants
pub const TIMEOUT_USE_DEFAULT: c_int = -1;
pub const TIMEOUT_INFINITE: c_int = 0x7fffffff;

/// Portal constants
pub const PORTAL_BUS_NAME = "org.freedesktop.portal.Desktop";
pub const PORTAL_OBJECT_PATH = "/org/freedesktop/portal/desktop";
pub const PORTAL_FILE_CHOOSER_INTERFACE = "org.freedesktop.portal.FileChooser";
pub const PORTAL_REQUEST_INTERFACE = "org.freedesktop.portal.Request";

// =============================================================================
// Opaque Types
// =============================================================================

pub const DBusConnection = opaque {};
pub const DBusMessage = opaque {};
pub const DBusPendingCall = opaque {};
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

/// D-Bus message iterator for reading/writing complex types
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

// =============================================================================
// External Functions (libdbus-1)
// =============================================================================

// Error handling
pub extern fn dbus_error_init(err: *DBusError) void;
pub extern fn dbus_error_free(err: *DBusError) void;
pub extern fn dbus_error_is_set(err: *const DBusError) c_uint;
pub extern fn dbus_error_has_name(err: *const DBusError, name: [*:0]const u8) c_uint;

// Connection management
pub extern fn dbus_bus_get(bus_type: c_int, err: *DBusError) ?*DBusConnection;
pub extern fn dbus_bus_get_private(bus_type: c_int, err: *DBusError) ?*DBusConnection;
pub extern fn dbus_connection_close(connection: *DBusConnection) void;
pub extern fn dbus_connection_unref(connection: *DBusConnection) void;
pub extern fn dbus_connection_ref(connection: *DBusConnection) *DBusConnection;
pub extern fn dbus_connection_flush(connection: *DBusConnection) void;
pub extern fn dbus_connection_read_write(connection: *DBusConnection, timeout_milliseconds: c_int) c_uint;
pub extern fn dbus_connection_read_write_dispatch(connection: *DBusConnection, timeout_milliseconds: c_int) c_uint;
pub extern fn dbus_connection_dispatch(connection: *DBusConnection) c_int;
pub extern fn dbus_connection_get_dispatch_status(connection: *DBusConnection) c_int;
pub extern fn dbus_connection_send(connection: *DBusConnection, message: *DBusMessage, serial: ?*u32) c_uint;
pub extern fn dbus_connection_send_with_reply(connection: *DBusConnection, message: *DBusMessage, pending_return: *?*DBusPendingCall, timeout_milliseconds: c_int) c_uint;
pub extern fn dbus_connection_send_with_reply_and_block(connection: *DBusConnection, message: *DBusMessage, timeout_milliseconds: c_int, err: *DBusError) ?*DBusMessage;
pub extern fn dbus_connection_pop_message(connection: *DBusConnection) ?*DBusMessage;
pub extern fn dbus_bus_add_match(connection: *DBusConnection, rule: [*:0]const u8, err: *DBusError) void;
pub extern fn dbus_bus_remove_match(connection: *DBusConnection, rule: [*:0]const u8, err: *DBusError) void;
pub extern fn dbus_bus_get_unique_name(connection: *DBusConnection) ?[*:0]const u8;

// Message creation
pub extern fn dbus_message_new(message_type: c_int) ?*DBusMessage;
pub extern fn dbus_message_new_method_call(bus_name: ?[*:0]const u8, path: [*:0]const u8, iface: ?[*:0]const u8, method: [*:0]const u8) ?*DBusMessage;
pub extern fn dbus_message_new_signal(path: [*:0]const u8, iface: [*:0]const u8, name: [*:0]const u8) ?*DBusMessage;
pub extern fn dbus_message_ref(message: *DBusMessage) *DBusMessage;
pub extern fn dbus_message_unref(message: *DBusMessage) void;

// Message inspection
pub extern fn dbus_message_get_type(message: *DBusMessage) c_int;
pub extern fn dbus_message_get_path(message: *DBusMessage) ?[*:0]const u8;
pub extern fn dbus_message_get_interface(message: *DBusMessage) ?[*:0]const u8;
pub extern fn dbus_message_get_member(message: *DBusMessage) ?[*:0]const u8;
pub extern fn dbus_message_get_sender(message: *DBusMessage) ?[*:0]const u8;
pub extern fn dbus_message_get_destination(message: *DBusMessage) ?[*:0]const u8;
pub extern fn dbus_message_get_signature(message: *DBusMessage) ?[*:0]const u8;
pub extern fn dbus_message_is_signal(message: *DBusMessage, iface: [*:0]const u8, signal_name: [*:0]const u8) c_uint;
pub extern fn dbus_message_is_method_call(message: *DBusMessage, iface: [*:0]const u8, method: [*:0]const u8) c_uint;

// Message iteration (reading/writing)
pub extern fn dbus_message_iter_init(message: *DBusMessage, iter: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_init_append(message: *DBusMessage, iter: *DBusMessageIter) void;
pub extern fn dbus_message_iter_has_next(iter: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_next(iter: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_get_arg_type(iter: *DBusMessageIter) c_int;
pub extern fn dbus_message_iter_get_element_type(iter: *DBusMessageIter) c_int;
pub extern fn dbus_message_iter_recurse(iter: *DBusMessageIter, sub: *DBusMessageIter) void;
pub extern fn dbus_message_iter_get_signature(iter: *DBusMessageIter) ?[*:0]u8;
pub extern fn dbus_message_iter_get_basic(iter: *DBusMessageIter, value: *DBusBasicValue) void;
pub extern fn dbus_message_iter_get_fixed_array(iter: *DBusMessageIter, value: *?*anyopaque, n_elements: *c_int) void;
pub extern fn dbus_message_iter_append_basic(iter: *DBusMessageIter, arg_type: c_int, value: *const anyopaque) c_uint;
pub extern fn dbus_message_iter_append_fixed_array(iter: *DBusMessageIter, element_type: c_int, value: *const anyopaque, n_elements: c_int) c_uint;
pub extern fn dbus_message_iter_open_container(iter: *DBusMessageIter, container_type: c_int, contained_signature: ?[*:0]const u8, sub: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_close_container(iter: *DBusMessageIter, sub: *DBusMessageIter) c_uint;
pub extern fn dbus_message_iter_abandon_container(iter: *DBusMessageIter, sub: *DBusMessageIter) void;

// Pending call
pub extern fn dbus_pending_call_block(pending: *DBusPendingCall) void;
pub extern fn dbus_pending_call_steal_reply(pending: *DBusPendingCall) ?*DBusMessage;
pub extern fn dbus_pending_call_unref(pending: *DBusPendingCall) void;
pub extern fn dbus_pending_call_get_completed(pending: *DBusPendingCall) c_uint;

// Memory
pub extern fn dbus_free(memory: ?*anyopaque) void;
pub extern fn dbus_free_string_array(str_array: ?[*]?[*:0]u8) void;

// =============================================================================
// High-Level Zig Wrappers
// =============================================================================

pub const Error = error{
    ConnectionFailed,
    MessageCreationFailed,
    MessageSendFailed,
    InvalidReply,
    Timeout,
    DBusError,
    OutOfMemory,
};

/// Wrapper around DBusError for RAII-style cleanup
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

    pub fn getMessage(self: *const Self) ?[]const u8 {
        if (self.inner.message) |msg| {
            return std.mem.span(msg);
        }
        return null;
    }
};

/// High-level connection wrapper
pub const Connection = struct {
    conn: *DBusConnection,
    is_private: bool,

    const Self = @This();

    /// Connect to the session bus (shared connection)
    pub fn connectSession() Error!Self {
        var err = ErrorState.init();
        defer err.deinit();

        const conn = dbus_bus_get(BUS_SESSION, &err.inner) orelse {
            return Error.ConnectionFailed;
        };

        return Self{
            .conn = conn,
            .is_private = false,
        };
    }

    /// Connect to the session bus (private connection - must be explicitly closed)
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

    /// Get the unique bus name for this connection
    pub fn getUniqueName(self: *Self) ?[]const u8 {
        if (dbus_bus_get_unique_name(self.conn)) |name| {
            return std.mem.span(name);
        }
        return null;
    }

    /// Add a match rule for receiving signals
    pub fn addMatch(self: *Self, rule: [:0]const u8) Error!void {
        var err = ErrorState.init();
        defer err.deinit();

        dbus_bus_add_match(self.conn, rule.ptr, &err.inner);

        if (err.isSet()) {
            return Error.DBusError;
        }
    }

    /// Remove a match rule
    pub fn removeMatch(self: *Self, rule: [:0]const u8) void {
        var err = ErrorState.init();
        defer err.deinit();

        dbus_bus_remove_match(self.conn, rule.ptr, &err.inner);
    }

    /// Send a message and block waiting for reply
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

    /// Send a message without waiting for reply
    pub fn send(self: *Self, message: *Message) Error!void {
        if (dbus_connection_send(self.conn, message.msg, null) == 0) {
            return Error.MessageSendFailed;
        }
    }

    /// Read and dispatch messages (blocking)
    pub fn readWriteDispatch(self: *Self, timeout_ms: c_int) bool {
        return dbus_connection_read_write_dispatch(self.conn, timeout_ms) != 0;
    }

    /// Read available data (non-blocking with timeout)
    pub fn readWrite(self: *Self, timeout_ms: c_int) bool {
        return dbus_connection_read_write(self.conn, timeout_ms) != 0;
    }

    /// Pop a message from the incoming queue
    pub fn popMessage(self: *Self) ?Message {
        if (dbus_connection_pop_message(self.conn)) |msg| {
            return Message{ .msg = msg };
        }
        return null;
    }

    /// Get dispatch status
    pub fn getDispatchStatus(self: *Self) c_int {
        return dbus_connection_get_dispatch_status(self.conn);
    }

    /// Dispatch any pending messages
    pub fn dispatch(self: *Self) c_int {
        return dbus_connection_dispatch(self.conn);
    }
};

/// High-level message wrapper
pub const Message = struct {
    msg: *DBusMessage,

    const Self = @This();

    /// Create a method call message
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

    /// Create a signal message
    pub fn newSignal(
        path: [:0]const u8,
        iface: [:0]const u8,
        signal_name: [:0]const u8,
    ) Error!Self {
        const msg = dbus_message_new_signal(
            path.ptr,
            iface.ptr,
            signal_name.ptr,
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

    pub fn getInterface(self: *const Self) ?[]const u8 {
        if (dbus_message_get_interface(self.msg)) |iface| {
            return std.mem.span(iface);
        }
        return null;
    }

    pub fn getMember(self: *const Self) ?[]const u8 {
        if (dbus_message_get_member(self.msg)) |member| {
            return std.mem.span(member);
        }
        return null;
    }

    pub fn isSignal(self: *const Self, iface: [:0]const u8, signal_name: [:0]const u8) bool {
        return dbus_message_is_signal(self.msg, iface.ptr, signal_name.ptr) != 0;
    }

    /// Initialize an iterator for reading message arguments
    pub fn iterInit(self: *Self) ?MessageIter {
        var iter = MessageIter{};
        if (dbus_message_iter_init(self.msg, &iter.inner) == 0) {
            return null; // No arguments
        }
        return iter;
    }

    /// Initialize an iterator for appending message arguments
    pub fn iterInitAppend(self: *Self) MessageIter {
        var iter = MessageIter{};
        dbus_message_iter_init_append(self.msg, &iter.inner);
        return iter;
    }
};

/// Message iterator for reading/writing arguments
pub const MessageIter = struct {
    inner: DBusMessageIter = .{},

    const Self = @This();

    pub fn hasNext(self: *Self) bool {
        return dbus_message_iter_has_next(&self.inner) != 0;
    }

    pub fn next(self: *Self) bool {
        return dbus_message_iter_next(&self.inner) != 0;
    }

    pub fn getArgType(self: *Self) c_int {
        return dbus_message_iter_get_arg_type(&self.inner);
    }

    pub fn getElementType(self: *Self) c_int {
        return dbus_message_iter_get_element_type(&self.inner);
    }

    pub fn recurse(self: *Self) Self {
        var sub = Self{};
        dbus_message_iter_recurse(&self.inner, &sub.inner);
        return sub;
    }

    /// Get a string argument
    pub fn getString(self: *Self) ?[]const u8 {
        var value: DBusBasicValue = undefined;
        dbus_message_iter_get_basic(&self.inner, &value);
        if (value.str) |str| {
            return std.mem.span(str);
        }
        return null;
    }

    /// Get a u32 argument
    pub fn getUint32(self: *Self) u32 {
        var value: DBusBasicValue = undefined;
        dbus_message_iter_get_basic(&self.inner, &value);
        return value.u32;
    }

    /// Get an i32 argument
    pub fn getInt32(self: *Self) i32 {
        var value: DBusBasicValue = undefined;
        dbus_message_iter_get_basic(&self.inner, &value);
        return value.i32;
    }

    /// Get a boolean argument
    pub fn getBool(self: *Self) bool {
        var value: DBusBasicValue = undefined;
        dbus_message_iter_get_basic(&self.inner, &value);
        return value.bool_val != 0;
    }

    /// Append a string argument
    pub fn appendString(self: *Self, str: [:0]const u8) bool {
        const ptr: *const [*:0]const u8 = &str.ptr;
        return dbus_message_iter_append_basic(&self.inner, TYPE_STRING, @ptrCast(ptr)) != 0;
    }

    /// Append an object path argument
    pub fn appendObjectPath(self: *Self, path: [:0]const u8) bool {
        const ptr: *const [*:0]const u8 = &path.ptr;
        return dbus_message_iter_append_basic(&self.inner, TYPE_OBJECT_PATH, @ptrCast(ptr)) != 0;
    }

    /// Append a u32 argument
    pub fn appendUint32(self: *Self, value: u32) bool {
        return dbus_message_iter_append_basic(&self.inner, TYPE_UINT32, &value) != 0;
    }

    /// Append an i32 argument
    pub fn appendInt32(self: *Self, value: i32) bool {
        return dbus_message_iter_append_basic(&self.inner, TYPE_INT32, &value) != 0;
    }

    /// Append a boolean argument
    pub fn appendBool(self: *Self, value: bool) bool {
        const dbus_bool: u32 = if (value) 1 else 0;
        return dbus_message_iter_append_basic(&self.inner, TYPE_BOOLEAN, &dbus_bool) != 0;
    }

    /// Append a variant containing a string
    pub fn appendVariantString(self: *Self, str: [:0]const u8) bool {
        var sub = self.openContainer(TYPE_VARIANT, "s") orelse return false;
        if (!sub.appendString(str)) {
            self.abandonContainer(&sub);
            return false;
        }
        return self.closeContainer(&sub);
    }

    /// Append a variant containing a double
    pub fn appendVariantDouble(self: *Self, value: f64) bool {
        var sub = self.openContainer(TYPE_VARIANT, "d") orelse return false;
        if (dbus_message_iter_append_basic(&sub.inner, TYPE_DOUBLE, &value) == 0) {
            self.abandonContainer(&sub);
            return false;
        }
        return self.closeContainer(&sub);
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

    /// Open a container (array, struct, variant, dict entry)
    pub fn openContainer(self: *Self, container_type: c_int, signature: ?[:0]const u8) ?Self {
        var sub = Self{};
        const sig_ptr: ?[*:0]const u8 = if (signature) |s| s.ptr else null;
        if (dbus_message_iter_open_container(&self.inner, container_type, sig_ptr, &sub.inner) == 0) {
            return null;
        }
        return sub;
    }

    /// Close a container
    pub fn closeContainer(self: *Self, sub: *Self) bool {
        return dbus_message_iter_close_container(&self.inner, &sub.inner) != 0;
    }

    /// Abandon a container (on error)
    pub fn abandonContainer(self: *Self, sub: *Self) void {
        dbus_message_iter_abandon_container(&self.inner, &sub.inner);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ErrorState init/deinit" {
    var err = ErrorState.init();
    defer err.deinit();

    try std.testing.expect(!err.isSet());
}

test "DBusError size check" {
    // Ensure our struct matches expected size
    comptime {
        std.debug.assert(@sizeOf(DBusError) >= 32);
    }
}

test "DBusMessageIter size check" {
    // The iterator struct should be large enough for libdbus internals
    comptime {
        std.debug.assert(@sizeOf(DBusMessageIter) >= 64);
    }
}
