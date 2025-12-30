//! Linux/Wayland Clipboard Support
//!
//! Provides clipboard access using the Wayland wl_data_device protocol.
//! This implements copy/paste via wl_data_source and wl_data_offer.
//!
//! The Wayland clipboard model:
//! - Copy (setText): Create wl_data_source, offer MIME types, set as selection
//! - Paste (getText): Receive wl_data_offer, request data, read from fd
//!
//! MIME type used: "text/plain;charset=utf-8"

const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("wayland.zig");

// =============================================================================
// Wayland Data Device Protocol Types
// =============================================================================

pub const WlDataDeviceManager = opaque {};
pub const WlDataDevice = opaque {};
pub const WlDataSource = opaque {};
pub const WlDataOffer = opaque {};

/// Data offer listener - receives events about available paste data
pub const WlDataOfferListener = extern struct {
    /// Advertise offered mime type
    offer: *const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        mime_type: [*:0]const u8,
    ) callconv(.c) void,
    /// Source actions available
    source_actions: ?*const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        source_actions: u32,
    ) callconv(.c) void = null,
    /// Action selected by compositor
    action: ?*const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        dnd_action: u32,
    ) callconv(.c) void = null,
};

/// Data source listener - receives events when our data is requested
pub const WlDataSourceListener = extern struct {
    /// Target accepts mime type (may be null)
    target: ?*const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
        mime_type: ?[*:0]const u8,
    ) callconv(.c) void = null,
    /// Request to send data to fd
    send: *const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
        mime_type: [*:0]const u8,
        fd: i32,
    ) callconv(.c) void,
    /// Selection was replaced
    cancelled: *const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
    ) callconv(.c) void,
    /// DnD drop performed (unused for clipboard)
    dnd_drop_performed: ?*const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
    ) callconv(.c) void = null,
    /// DnD finished (unused for clipboard)
    dnd_finished: ?*const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
    ) callconv(.c) void = null,
    /// Action selected (unused for clipboard)
    action: ?*const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
        dnd_action: u32,
    ) callconv(.c) void = null,
};

/// Data device listener - receives selection/DnD events
pub const WlDataDeviceListener = extern struct {
    /// New data offer created
    data_offer: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        id: *WlDataOffer,
    ) callconv(.c) void = null,
    /// DnD enter (unused for clipboard)
    enter: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        serial: u32,
        surface: ?*wayland.Surface,
        x: i32,
        y: i32,
        id: ?*WlDataOffer,
    ) callconv(.c) void = null,
    /// DnD leave (unused for clipboard)
    leave: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
    ) callconv(.c) void = null,
    /// DnD motion (unused for clipboard)
    motion: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        time: u32,
        x: i32,
        y: i32,
    ) callconv(.c) void = null,
    /// DnD drop (unused for clipboard)
    drop: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
    ) callconv(.c) void = null,
    /// Selection changed - new clipboard content available
    selection: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        id: ?*WlDataOffer,
    ) callconv(.c) void = null,
};

// =============================================================================
// Protocol Interface Declarations (from libwayland-client)
// =============================================================================

// These are part of the core Wayland protocol and exported from libwayland-client
pub extern "wayland-client" var wl_data_device_manager_interface: wayland.Interface;
pub extern "wayland-client" var wl_data_device_interface: wayland.Interface;
pub extern "wayland-client" var wl_data_source_interface: wayland.Interface;
pub extern "wayland-client" var wl_data_offer_interface: wayland.Interface;

// =============================================================================
// Protocol Constants
// =============================================================================

pub const WL_DATA_DEVICE_MANAGER_INTERFACE_NAME = "wl_data_device_manager";
pub const MIME_TYPE_TEXT_PLAIN = "text/plain;charset=utf-8";
pub const MIME_TYPE_TEXT_UTF8 = "text/plain";
pub const MIME_TYPE_UTF8_STRING = "UTF8_STRING";

// Data device manager method opcodes
const WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE = 0;
const WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE = 1;

// Data device method opcodes
const WL_DATA_DEVICE_SET_SELECTION = 1;
const WL_DATA_DEVICE_RELEASE = 2;

// Data source method opcodes
const WL_DATA_SOURCE_OFFER = 0;
const WL_DATA_SOURCE_DESTROY = 1;

// Data offer method opcodes
const WL_DATA_OFFER_RECEIVE = 1;
const WL_DATA_OFFER_DESTROY = 2;

// =============================================================================
// Wrapper Functions
// =============================================================================

pub fn dataDeviceManagerCreateDataSource(manager: *WlDataDeviceManager) ?*WlDataSource {
    return @ptrCast(wayland.wl_proxy_marshal_flags(
        @ptrCast(manager),
        WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE,
        &wl_data_source_interface,
        wayland.wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null), // new_id placeholder
    ));
}

pub fn dataDeviceManagerGetDataDevice(manager: *WlDataDeviceManager, seat: *wayland.Seat) ?*WlDataDevice {
    return @ptrCast(wayland.wl_proxy_marshal_flags(
        @ptrCast(manager),
        WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE,
        &wl_data_device_interface,
        wayland.wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null), // new_id placeholder
        seat,
    ));
}

pub fn dataDeviceSetSelection(device: *WlDataDevice, source: ?*WlDataSource, serial: u32) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(device),
        WL_DATA_DEVICE_SET_SELECTION,
        null,
        wayland.wl_proxy_get_version(@ptrCast(device)),
        0,
        source,
        serial,
    );
}

pub fn dataDeviceRelease(device: *WlDataDevice) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(device),
        WL_DATA_DEVICE_RELEASE,
        null,
        wayland.wl_proxy_get_version(@ptrCast(device)),
        wayland.MARSHAL_FLAG_DESTROY,
    );
}

pub fn dataDeviceAddListener(device: *WlDataDevice, listener: *const WlDataDeviceListener, data: ?*anyopaque) c_int {
    return wayland.wl_proxy_add_listener(@ptrCast(device), @ptrCast(listener), data);
}

pub fn dataSourceOffer(source: *WlDataSource, mime_type: [*:0]const u8) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(source),
        WL_DATA_SOURCE_OFFER,
        null,
        wayland.wl_proxy_get_version(@ptrCast(source)),
        0,
        mime_type,
    );
}

pub fn dataSourceDestroy(source: *WlDataSource) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(source),
        WL_DATA_SOURCE_DESTROY,
        null,
        wayland.wl_proxy_get_version(@ptrCast(source)),
        wayland.MARSHAL_FLAG_DESTROY,
    );
}

pub fn dataSourceAddListener(source: *WlDataSource, listener: *const WlDataSourceListener, data: ?*anyopaque) c_int {
    return wayland.wl_proxy_add_listener(@ptrCast(source), @ptrCast(listener), data);
}

pub fn dataOfferReceive(offer: *WlDataOffer, mime_type: [*:0]const u8, fd: i32) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(offer),
        WL_DATA_OFFER_RECEIVE,
        null,
        wayland.wl_proxy_get_version(@ptrCast(offer)),
        0,
        mime_type,
        fd,
    );
}

pub fn dataOfferDestroy(offer: *WlDataOffer) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(offer),
        WL_DATA_OFFER_DESTROY,
        null,
        wayland.wl_proxy_get_version(@ptrCast(offer)),
        wayland.MARSHAL_FLAG_DESTROY,
    );
}

pub fn dataOfferAddListener(offer: *WlDataOffer, listener: *const WlDataOfferListener, data: ?*anyopaque) c_int {
    return wayland.wl_proxy_add_listener(@ptrCast(offer), @ptrCast(listener), data);
}

// =============================================================================
// Clipboard State
// =============================================================================

/// Maximum clipboard buffer size (64 KB should be plenty for text)
const MAX_CLIPBOARD_SIZE = 64 * 1024;

/// Maximum number of MIME types to track per offer
const MAX_MIME_TYPES = 16;

/// Clipboard state - managed by the platform
pub const ClipboardState = struct {
    // Wayland objects
    data_device_manager: ?*WlDataDeviceManager = null,
    data_device: ?*WlDataDevice = null,

    // Current clipboard selection offer (for paste)
    current_offer: ?*WlDataOffer = null,
    offer_has_text: bool = false,

    // Pending offer being advertised (before selection event)
    pending_offer: ?*WlDataOffer = null,
    pending_has_text: bool = false,

    // Currently active data source (for copy)
    active_source: ?*WlDataSource = null,

    // Buffer for clipboard text we're offering (copy)
    copy_buffer: [MAX_CLIPBOARD_SIZE]u8 = undefined,
    copy_len: usize = 0,

    // Serial for set_selection
    last_serial: u32 = 0,

    // Display for flushing
    display: ?*wayland.Display = null,

    const Self = @This();

    /// Initialize clipboard state
    pub fn init() Self {
        return .{};
    }

    /// Clean up clipboard resources
    pub fn deinit(self: *Self) void {
        if (self.current_offer) |offer| {
            dataOfferDestroy(offer);
            self.current_offer = null;
        }
        if (self.active_source) |source| {
            dataSourceDestroy(source);
            self.active_source = null;
        }
        if (self.data_device) |device| {
            dataDeviceRelease(device);
            self.data_device = null;
        }
        self.data_device_manager = null;
        self.display = null;
    }

    /// Bind the data device manager from registry
    pub fn bindManager(self: *Self, registry: *wayland.Registry, name: u32, version: u32) void {
        self.data_device_manager = @ptrCast(@alignCast(wayland.registryBind(
            registry,
            name,
            &wl_data_device_manager_interface,
            @min(version, 3),
        )));
    }

    /// Create data device once we have both manager and seat
    pub fn setupDataDevice(self: *Self, seat: *wayland.Seat, display: *wayland.Display) void {
        if (self.data_device_manager == null) return;
        if (self.data_device != null) return;

        self.display = display;
        self.data_device = dataDeviceManagerGetDataDevice(self.data_device_manager.?, seat);

        if (self.data_device) |device| {
            _ = dataDeviceAddListener(device, &data_device_listener, self);
        }
    }

    /// Handle new data offer (clipboard content changed)
    fn handleDataOffer(self: *Self, offer: *WlDataOffer) void {
        // New offer being advertised - track it as pending until selection event
        self.pending_offer = offer;
        self.pending_has_text = false;
        // Add listener to receive mime type events for this offer
        _ = dataOfferAddListener(offer, &data_offer_listener, self);
    }

    /// Handle selection event (clipboard content available)
    fn handleSelection(self: *Self, offer: ?*WlDataOffer) void {
        // Destroy old offer if any
        if (self.current_offer) |old| {
            if (old != offer) {
                dataOfferDestroy(old);
            }
        }

        self.current_offer = offer;

        // If this is the pending offer we've been tracking, use its accumulated has_text flag
        if (offer != null and offer == self.pending_offer) {
            self.offer_has_text = self.pending_has_text;
        } else {
            self.offer_has_text = false;
        }

        // Clear pending state
        self.pending_offer = null;
        self.pending_has_text = false;
    }

    /// Handle mime type advertisement from offer
    fn handleOfferMimeType(self: *Self, mime_type: [*:0]const u8) void {
        const mime = std.mem.span(mime_type);
        // Check if this is a text type we can use
        if (std.mem.eql(u8, mime, MIME_TYPE_TEXT_PLAIN) or
            std.mem.eql(u8, mime, MIME_TYPE_TEXT_UTF8) or
            std.mem.eql(u8, mime, MIME_TYPE_UTF8_STRING))
        {
            self.pending_has_text = true;
        }
    }

    /// Read text from clipboard
    pub fn getText(self: *Self, allocator: std.mem.Allocator) ?[]const u8 {
        // If we have our own active source, return our own data
        // (Wayland doesn't give us a data_offer for our own selection)
        if (self.active_source != null and self.copy_len > 0) {
            return allocator.dupe(u8, self.copy_buffer[0..self.copy_len]) catch null;
        }

        const offer = self.current_offer orelse return null;
        if (!self.offer_has_text) return null;

        // Create pipe for receiving data
        var pipe_fds: [2]i32 = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return null;

        const read_fd = pipe_fds[0];
        const write_fd = pipe_fds[1];

        // Request data - compositor will write to write_fd
        dataOfferReceive(offer, MIME_TYPE_TEXT_PLAIN, write_fd);

        // Flush to ensure request is sent
        if (self.display) |display| {
            _ = wayland.wl_display_flush(display);
        }

        // Close write end - we only read
        std.posix.close(@intCast(write_fd));

        // Read data from pipe
        var buffer = allocator.alloc(u8, MAX_CLIPBOARD_SIZE) catch {
            std.posix.close(@intCast(read_fd));
            return null;
        };

        var total_read: usize = 0;
        while (total_read < MAX_CLIPBOARD_SIZE) {
            const n = std.posix.read(@intCast(read_fd), buffer[total_read..]) catch break;
            if (n == 0) break;
            total_read += n;
        }

        std.posix.close(@intCast(read_fd));

        if (total_read == 0) {
            allocator.free(buffer);
            return null;
        }

        // Shrink buffer to actual size
        const result = allocator.realloc(buffer, total_read) catch {
            // realloc failed, return the original buffer truncated
            return buffer[0..total_read];
        };
        return result;
    }

    /// Write text to clipboard
    pub fn setText(self: *Self, text: []const u8) bool {
        const manager = self.data_device_manager orelse return false;
        const device = self.data_device orelse return false;

        // Limit to buffer size
        const len = @min(text.len, MAX_CLIPBOARD_SIZE);
        if (len == 0) return false;

        // Store text in our buffer
        @memcpy(self.copy_buffer[0..len], text[0..len]);
        self.copy_len = len;

        // Destroy old source if any
        if (self.active_source) |old| {
            dataSourceDestroy(old);
            self.active_source = null;
        }

        // Create new data source
        const source = dataDeviceManagerCreateDataSource(manager) orelse return false;
        self.active_source = source;

        // Add listener for send requests
        _ = dataSourceAddListener(source, &data_source_listener, self);

        // Offer text mime types
        dataSourceOffer(source, MIME_TYPE_TEXT_PLAIN);
        dataSourceOffer(source, MIME_TYPE_TEXT_UTF8);
        dataSourceOffer(source, MIME_TYPE_UTF8_STRING);

        // Set as current selection
        dataDeviceSetSelection(device, source, self.last_serial);

        // Flush to ensure it's sent
        if (self.display) |display| {
            _ = wayland.wl_display_flush(display);
        }

        return true;
    }

    /// Handle send request - write our data to the fd
    fn handleSend(self: *Self, fd: i32) void {
        if (self.copy_len == 0) {
            std.posix.close(@intCast(fd));
            return;
        }

        // Write data to fd
        var written: usize = 0;
        while (written < self.copy_len) {
            const n = std.posix.write(@intCast(fd), self.copy_buffer[written..self.copy_len]) catch break;
            if (n == 0) break;
            written += n;
        }

        std.posix.close(@intCast(fd));
    }

    /// Handle cancelled event - our selection was replaced
    fn handleCancelled(self: *Self, source: *WlDataSource) void {
        if (self.active_source == source) {
            dataSourceDestroy(source);
            self.active_source = null;
            self.copy_len = 0;
        }
    }

    /// Update serial (should be called on input events)
    pub fn updateSerial(self: *Self, serial: u32) void {
        self.last_serial = serial;
    }
};

// =============================================================================
// Static Listeners
// =============================================================================

const data_device_listener = WlDataDeviceListener{
    .data_offer = dataDeviceDataOfferCallback,
    .selection = dataDeviceSelectionCallback,
};

fn dataDeviceDataOfferCallback(
    data: ?*anyopaque,
    _: *WlDataDevice,
    offer: *WlDataOffer,
) callconv(.c) void {
    const state: *ClipboardState = @ptrCast(@alignCast(data));
    state.handleDataOffer(offer);
}

fn dataDeviceSelectionCallback(
    data: ?*anyopaque,
    _: *WlDataDevice,
    offer: ?*WlDataOffer,
) callconv(.c) void {
    const state: *ClipboardState = @ptrCast(@alignCast(data));
    state.handleSelection(offer);
}

const data_offer_listener = WlDataOfferListener{
    .offer = dataOfferOfferCallback,
};

fn dataOfferOfferCallback(
    data: ?*anyopaque,
    _: *WlDataOffer,
    mime_type: [*:0]const u8,
) callconv(.c) void {
    const state: *ClipboardState = @ptrCast(@alignCast(data));
    state.handleOfferMimeType(mime_type);
}

const data_source_listener = WlDataSourceListener{
    .send = dataSourceSendCallback,
    .cancelled = dataSourceCancelledCallback,
};

fn dataSourceSendCallback(
    data: ?*anyopaque,
    _: *WlDataSource,
    _: [*:0]const u8,
    fd: i32,
) callconv(.c) void {
    const state: *ClipboardState = @ptrCast(@alignCast(data));
    state.handleSend(fd);
}

fn dataSourceCancelledCallback(
    data: ?*anyopaque,
    source: *WlDataSource,
) callconv(.c) void {
    const state: *ClipboardState = @ptrCast(@alignCast(data));
    state.handleCancelled(source);
}

// =============================================================================
// Global Clipboard State (singleton for simple API)
// =============================================================================

var global_state: ClipboardState = ClipboardState.init();

/// Get the global clipboard state (for platform integration)
pub fn getState() *ClipboardState {
    return &global_state;
}

// =============================================================================
// Public API (matching mac/clipboard.zig interface)
// =============================================================================

/// Read text from the system clipboard.
/// Returns owned slice that caller must free, or null if no text available.
pub fn getText(allocator: std.mem.Allocator) ?[]const u8 {
    return global_state.getText(allocator);
}

/// Write text to the system clipboard.
/// Returns true on success.
pub fn setText(text: []const u8) bool {
    return global_state.setText(text);
}
