const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("wayland.zig");
const core_clipboard = @import("../../core/clipboard.zig");
const assert = std.debug.assert;

pub const WlDataDeviceManager = opaque {};
pub const WlDataDevice = opaque {};
pub const WlDataSource = opaque {};
pub const WlDataOffer = opaque {};

pub const WlDataOfferListener = extern struct {
    offer: *const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        mime_type: [*:0]const u8,
    ) callconv(.c) void,
    source_actions: ?*const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        source_actions: u32,
    ) callconv(.c) void = null,
    action: ?*const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        dnd_action: u32,
    ) callconv(.c) void = null,
};

pub const WlDataSourceListener = extern struct {
    target: ?*const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
        mime_type: ?[*:0]const u8,
    ) callconv(.c) void = null,
    send: *const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
        mime_type: [*:0]const u8,
        fd: i32,
    ) callconv(.c) void,
    cancelled: *const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
    ) callconv(.c) void,
    dnd_drop_performed: ?*const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
    ) callconv(.c) void = null,
    dnd_finished: ?*const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
    ) callconv(.c) void = null,
    action: ?*const fn (
        data: ?*anyopaque,
        data_source: *WlDataSource,
        dnd_action: u32,
    ) callconv(.c) void = null,
};

pub const WlDataDeviceListener = extern struct {
    data_offer: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        id: *WlDataOffer,
    ) callconv(.c) void = null,
    enter: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        serial: u32,
        surface: ?*wayland.Surface,
        x: i32,
        y: i32,
        id: ?*WlDataOffer,
    ) callconv(.c) void = null,
    leave: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
    ) callconv(.c) void = null,
    motion: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        time: u32,
        x: i32,
        y: i32,
    ) callconv(.c) void = null,
    drop: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
    ) callconv(.c) void = null,
    selection: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        id: ?*WlDataOffer,
    ) callconv(.c) void = null,
};

pub extern "wayland-client" var wl_data_device_manager_interface: wayland.Interface;
pub extern "wayland-client" var wl_data_device_interface: wayland.Interface;
pub extern "wayland-client" var wl_data_source_interface: wayland.Interface;
pub extern "wayland-client" var wl_data_offer_interface: wayland.Interface;

pub const WL_DATA_DEVICE_MANAGER_INTERFACE_NAME = "wl_data_device_manager";
pub const MIME_TYPE_TEXT_PLAIN = "text/plain;charset=utf-8";
pub const MIME_TYPE_TEXT_UTF8 = "text/plain";
pub const MIME_TYPE_UTF8_STRING = "UTF8_STRING";

const WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE = 0;
const WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE = 1;

const WL_DATA_DEVICE_SET_SELECTION = 1;
const WL_DATA_DEVICE_RELEASE = 2;

const WL_DATA_SOURCE_OFFER = 0;
const WL_DATA_SOURCE_DESTROY = 1;

const WL_DATA_OFFER_RECEIVE = 1;
const WL_DATA_OFFER_DESTROY = 2;

pub fn dataDeviceManagerCreateDataSource(manager: *WlDataDeviceManager) ?*WlDataSource {
    return @ptrCast(wayland.wl_proxy_marshal_flags(
        @ptrCast(manager),
        WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE,
        &wl_data_source_interface,
        wayland.wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null),
    ));
}

pub fn dataDeviceManagerGetDataDevice(manager: *WlDataDeviceManager, seat: *wayland.Seat) ?*WlDataDevice {
    return @ptrCast(wayland.wl_proxy_marshal_flags(
        @ptrCast(manager),
        WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE,
        &wl_data_device_interface,
        wayland.wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null),
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
    const version = wayland.wl_proxy_get_version(@ptrCast(device));

    std.debug.assert(version >= 1);
    std.debug.assert(version <= 3);

    if (version >= 2) {
        _ = wayland.wl_proxy_marshal_flags(
            @ptrCast(device),
            WL_DATA_DEVICE_RELEASE,
            null,
            version,
            wayland.MARSHAL_FLAG_DESTROY,
        );
    } else {
        wayland.wl_proxy_destroy(@ptrCast(device));
    }
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

pub const ClipboardState = struct {
    data_device_manager: ?*WlDataDeviceManager = null,
    data_device: ?*WlDataDevice = null,

    current_offer: ?*WlDataOffer = null,
    offer_has_text: bool = false,

    pending_offer: ?*WlDataOffer = null,
    pending_has_text: bool = false,

    active_source: ?*WlDataSource = null,

    copy_buffer: []u8 = &.{},
    copy_len: usize = 0,

    last_serial: u32 = 0,

    display: ?*wayland.Display = null,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn reserveCopy(self: *Self, gpa: std.mem.Allocator, bytes: u32) !void {
        assert(self.copy_buffer.len == 0);
        assert(bytes > 0);
        self.copy_buffer = try gpa.alloc(u8, bytes);
        self.copy_len = 0;
        assert(self.copy_buffer.len == bytes);
    }

    pub fn releaseCopy(self: *Self, gpa: std.mem.Allocator) void {
        assert(self.copy_buffer.len > 0);
        if (self.active_source) |source| {
            dataSourceDestroy(source);
            self.active_source = null;
        }
        gpa.free(self.copy_buffer);
        self.copy_buffer = &.{};
        self.copy_len = 0;
    }

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

    pub fn bindManager(self: *Self, registry: *wayland.Registry, name: u32, version: u32) void {
        self.data_device_manager = @ptrCast(@alignCast(wayland.registryBind(
            registry,
            name,
            &wl_data_device_manager_interface,
            .{ .advertised = version, .supported_max = 3 },
        )));
    }

    pub fn setupDataDevice(self: *Self, seat: *wayland.Seat, display: *wayland.Display) void {
        if (self.data_device_manager == null) return;
        if (self.data_device != null) return;

        self.display = display;
        self.data_device = dataDeviceManagerGetDataDevice(self.data_device_manager.?, seat);

        if (self.data_device) |device| {
            _ = dataDeviceAddListener(device, &data_device_listener, self);
        }
    }

    fn handleDataOffer(self: *Self, offer: *WlDataOffer) void {
        self.pending_offer = offer;
        self.pending_has_text = false;
        _ = dataOfferAddListener(offer, &data_offer_listener, self);
    }

    fn handleSelection(self: *Self, offer: ?*WlDataOffer) void {
        if (self.current_offer) |old| {
            if (old != offer) {
                dataOfferDestroy(old);
            }
        }

        self.current_offer = offer;

        if (offer != null and offer == self.pending_offer) {
            self.offer_has_text = self.pending_has_text;
        } else {
            self.offer_has_text = false;
        }

        self.pending_offer = null;
        self.pending_has_text = false;
    }

    fn handleOfferMimeType(self: *Self, mime_type: [*:0]const u8) void {
        const mime = std.mem.span(mime_type);
        if (std.mem.eql(u8, mime, MIME_TYPE_TEXT_PLAIN) or
            std.mem.eql(u8, mime, MIME_TYPE_TEXT_UTF8) or
            std.mem.eql(u8, mime, MIME_TYPE_UTF8_STRING))
        {
            self.pending_has_text = true;
        }
    }

    pub fn readText(self: *Self, out: []u8) u32 {
        assert(out.len > 0);
        if (self.active_source != null and self.copy_len > 0) {
            const kept = core_clipboard.prefixFitting(self.copy_buffer[0..self.copy_len], out.len);
            @memcpy(out[0..kept], self.copy_buffer[0..kept]);
            return @intCast(kept);
        }
        const offer = self.current_offer orelse return 0;
        if (!self.offer_has_text) return 0;
        var pipe_fds: [2]i32 = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return 0;
        const read_fd = pipe_fds[0];
        dataOfferReceive(offer, MIME_TYPE_TEXT_PLAIN, pipe_fds[1]);
        if (self.display) |display| _ = wayland.wl_display_flush(display);
        _ = std.c.close(@intCast(pipe_fds[1]));
        defer _ = std.c.close(@intCast(read_fd));
        var total: usize = 0;
        var reads: u32 = 0;
        while (total < out.len) : (reads += 1) {
            assert(reads <= out.len);
            const n = std.posix.read(@intCast(read_fd), out[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        if (total == out.len) total = core_clipboard.wholeCodepoints(out);
        return @intCast(total);
    }

    pub fn setText(self: *Self, text: []const u8) bool {
        const manager = self.data_device_manager orelse return false;
        const device = self.data_device orelse return false;

        assert(text.len <= self.copy_buffer.len);
        const len = text.len;
        if (len == 0) return false;

        @memcpy(self.copy_buffer[0..len], text[0..len]);
        self.copy_len = len;

        if (self.active_source) |old| {
            dataSourceDestroy(old);
            self.active_source = null;
        }

        const source = dataDeviceManagerCreateDataSource(manager) orelse return false;
        self.active_source = source;

        _ = dataSourceAddListener(source, &data_source_listener, self);

        dataSourceOffer(source, MIME_TYPE_TEXT_PLAIN);
        dataSourceOffer(source, MIME_TYPE_TEXT_UTF8);
        dataSourceOffer(source, MIME_TYPE_UTF8_STRING);

        dataDeviceSetSelection(device, source, self.last_serial);

        if (self.display) |display| {
            _ = wayland.wl_display_flush(display);
        }

        return true;
    }

    fn handleSend(self: *Self, fd: i32) void {
        if (self.copy_len == 0) {
            _ = std.c.close(@intCast(fd));
            return;
        }

        var written: usize = 0;
        while (written < self.copy_len) {
            const remaining = self.copy_buffer[written..self.copy_len];
            const rc = std.c.write(@intCast(fd), remaining.ptr, remaining.len);
            if (rc < 0) {
                const err = std.posix.errno(rc);
                if (err == .INTR) continue;
                break;
            }
            if (rc == 0) break;
            written += @intCast(rc);
        }

        _ = std.c.close(@intCast(fd));
    }

    fn handleCancelled(self: *Self, source: *WlDataSource) void {
        if (self.active_source == source) {
            dataSourceDestroy(source);
            self.active_source = null;
            self.copy_len = 0;
        }
    }

    pub fn updateSerial(self: *Self, serial: u32) void {
        self.last_serial = serial;
    }
};

const data_device_listener = WlDataDeviceListener{
    .data_offer = dataDeviceDataOfferCallback,
    .enter = dataDeviceEnterCallback,
    .leave = dataDeviceLeaveCallback,
    .motion = dataDeviceMotionCallback,
    .drop = dataDeviceDropCallback,
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

const log = std.log.scoped(.clipboard_dnd);

fn dataDeviceEnterCallback(
    _: ?*anyopaque,
    _: *WlDataDevice,
    serial: u32,
    _: ?*wayland.Surface,
    _: i32,
    _: i32,
    _: ?*WlDataOffer,
) callconv(.c) void {
    log.debug("DnD enter event received (serial={}), ignoring - clipboard-only mode", .{serial});
}

fn dataDeviceLeaveCallback(
    _: ?*anyopaque,
    _: *WlDataDevice,
) callconv(.c) void {
    log.debug("DnD leave event received, ignoring - clipboard-only mode", .{});
}

fn dataDeviceMotionCallback(
    _: ?*anyopaque,
    _: *WlDataDevice,
    time: u32,
    _: i32,
    _: i32,
) callconv(.c) void {
    log.debug("DnD motion event received (time={}), ignoring - clipboard-only mode", .{time});
}

fn dataDeviceDropCallback(
    _: ?*anyopaque,
    _: *WlDataDevice,
) callconv(.c) void {
    log.debug("DnD drop event received, ignoring - clipboard-only mode", .{});
}

const data_offer_listener = WlDataOfferListener{
    .offer = dataOfferOfferCallback,
    .source_actions = dataOfferSourceActionsCallback,
    .action = dataOfferActionCallback,
};

fn dataOfferOfferCallback(
    data: ?*anyopaque,
    _: *WlDataOffer,
    mime_type: [*:0]const u8,
) callconv(.c) void {
    const state: *ClipboardState = @ptrCast(@alignCast(data));
    state.handleOfferMimeType(mime_type);
}

fn dataOfferSourceActionsCallback(
    _: ?*anyopaque,
    _: *WlDataOffer,
    source_actions: u32,
) callconv(.c) void {
    log.debug("Data offer source_actions event (actions=0x{x}), ignoring - clipboard-only mode", .{source_actions});
}

fn dataOfferActionCallback(
    _: ?*anyopaque,
    _: *WlDataOffer,
    dnd_action: u32,
) callconv(.c) void {
    log.debug("Data offer action event (action=0x{x}), ignoring - clipboard-only mode", .{dnd_action});
}

const data_source_listener = WlDataSourceListener{
    .target = dataSourceTargetCallback,
    .send = dataSourceSendCallback,
    .cancelled = dataSourceCancelledCallback,
    .dnd_drop_performed = dataSourceDndDropPerformedCallback,
    .dnd_finished = dataSourceDndFinishedCallback,
    .action = dataSourceActionCallback,
};

fn dataSourceTargetCallback(
    _: ?*anyopaque,
    _: *WlDataSource,
    mime_type: ?[*:0]const u8,
) callconv(.c) void {
    log.debug("Data source target event (mime_type={s}), informational", .{mime_type orelse "(null)"});
}

fn dataSourceDndDropPerformedCallback(
    _: ?*anyopaque,
    _: *WlDataSource,
) callconv(.c) void {
    log.debug("Data source DnD drop performed, ignoring - clipboard-only mode", .{});
}

fn dataSourceDndFinishedCallback(
    _: ?*anyopaque,
    _: *WlDataSource,
) callconv(.c) void {
    log.debug("Data source DnD finished, ignoring - clipboard-only mode", .{});
}

fn dataSourceActionCallback(
    _: ?*anyopaque,
    _: *WlDataSource,
    dnd_action: u32,
) callconv(.c) void {
    log.debug("Data source action event (action=0x{x}), ignoring - clipboard-only mode", .{dnd_action});
}

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

var global_state: ClipboardState = ClipboardState.init();

pub fn getState() *ClipboardState {
    return &global_state;
}

pub fn setText(text: []const u8) bool {
    return global_state.setText(text);
}

pub fn readText(out: []u8) u32 {
    return global_state.readText(out);
}
