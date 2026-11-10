//! Wayland C bindings for Linux windowing
//!
//! These bindings wrap libwayland-client and related protocols to provide
//! native Wayland windowing support on Linux.
//!
//! Protocols used:
//! - wayland-client (core protocol)
//! - xdg-shell (window management)
//! - xdg-decoration (server-side decorations)
//! - fractional-scale-v1 (fractional output scales, with wp_viewporter)

const std = @import("std");

// =============================================================================
// Basic Types
// =============================================================================

/// Wayland fixed-point number (24.8 format)
pub const Fixed = i32;

pub fn fixedToDouble(f: Fixed) f64 {
    return @as(f64, @floatFromInt(f)) / 256.0;
}

// =============================================================================
// Opaque Handle Types
// =============================================================================

pub const Display = opaque {};
pub const Registry = opaque {};
pub const Callback = opaque {};
pub const Compositor = opaque {};
pub const Surface = opaque {};
pub const Buffer = opaque {};
pub const ShmPool = opaque {};
pub const Shm = opaque {};
pub const Seat = opaque {};
pub const Pointer = opaque {};
pub const Keyboard = opaque {};
pub const Touch = opaque {};
pub const Output = opaque {};

// XDG Shell types
pub const XdgWmBase = opaque {};
pub const XdgSurface = opaque {};
pub const XdgToplevel = opaque {};

// XDG Decoration types
pub const ZxdgDecorationManagerV1 = opaque {};
pub const ZxdgToplevelDecorationV1 = opaque {};

// Text Input types (IME support)
pub const ZwpTextInputV3 = opaque {};
pub const ZwpTextInputManagerV3 = opaque {};

// Viewporter types (HiDPI support)
pub const WpViewporter = opaque {};
pub const WpViewport = opaque {};

// Cursor shape protocol types
pub const WpCursorShapeManagerV1 = opaque {};
pub const WpCursorShapeDeviceV1 = opaque {};

// Fractional scale protocol types
pub const WpFractionalScaleManagerV1 = opaque {};
pub const WpFractionalScaleV1 = opaque {};

// Wayland array type (used in listeners)
pub const Array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

// =============================================================================
// Listener Structs
// =============================================================================

pub const RegistryListener = extern struct {
    global: ?*const fn (
        data: ?*anyopaque,
        registry: *Registry,
        name: u32,
        interface: [*:0]const u8,
        version: u32,
    ) callconv(.c) void = null,
    global_remove: ?*const fn (
        data: ?*anyopaque,
        registry: *Registry,
        name: u32,
    ) callconv(.c) void = null,
};

pub const SurfaceListener = extern struct {
    enter: ?*const fn (
        data: ?*anyopaque,
        surface: *Surface,
        output: *Output,
    ) callconv(.c) void = null,
    leave: ?*const fn (
        data: ?*anyopaque,
        surface: *Surface,
        output: *Output,
    ) callconv(.c) void = null,
    preferred_buffer_scale: ?*const fn (
        data: ?*anyopaque,
        surface: *Surface,
        factor: i32,
    ) callconv(.c) void = null,
    preferred_buffer_transform: ?*const fn (
        data: ?*anyopaque,
        surface: *Surface,
        transform: u32,
    ) callconv(.c) void = null,
};

pub const CallbackListener = extern struct {
    done: ?*const fn (
        data: ?*anyopaque,
        callback: *Callback,
        callback_data: u32,
    ) callconv(.c) void = null,
};

/// `wp_fractional_scale_v1.preferred_scale`: the scale the compositor wants
/// the surface's buffers drawn at, in 120ths (180 is 1.5), which the integer
/// `wl_surface.preferred_buffer_scale` cannot express.
pub const FractionalScaleListener = extern struct {
    preferred_scale: ?*const fn (
        data: ?*anyopaque,
        fractional_scale: *WpFractionalScaleV1,
        scale_120ths: u32,
    ) callconv(.c) void = null,
};

/// `wl_buffer.release`: the compositor no longer reads the buffer's memory.
pub const BufferListener = extern struct {
    release: ?*const fn (data: ?*anyopaque, buffer: *Buffer) callconv(.c) void = null,
};

pub const SeatListener = extern struct {
    capabilities: ?*const fn (
        data: ?*anyopaque,
        seat: *Seat,
        capabilities: SeatCapability,
    ) callconv(.c) void = null,
    name: ?*const fn (
        data: ?*anyopaque,
        seat: *Seat,
        name: [*:0]const u8,
    ) callconv(.c) void = null,
};

pub const SeatCapability = packed struct(u32) {
    pointer: bool = false,
    keyboard: bool = false,
    touch: bool = false,
    _padding: u29 = 0,
};

pub const PointerListener = extern struct {
    enter: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        serial: u32,
        surface: *Surface,
        surface_x: Fixed,
        surface_y: Fixed,
    ) callconv(.c) void = null,
    leave: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        serial: u32,
        surface: *Surface,
    ) callconv(.c) void = null,
    motion: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        time: u32,
        surface_x: Fixed,
        surface_y: Fixed,
    ) callconv(.c) void = null,
    button: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        serial: u32,
        time: u32,
        button: u32,
        state: PointerButtonState,
    ) callconv(.c) void = null,
    axis: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        time: u32,
        axis: PointerAxis,
        value: Fixed,
    ) callconv(.c) void = null,
    frame: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
    ) callconv(.c) void = null,
    axis_source: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        axis_source: PointerAxisSource,
    ) callconv(.c) void = null,
    axis_stop: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        time: u32,
        axis: PointerAxis,
    ) callconv(.c) void = null,
    axis_discrete: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        axis: PointerAxis,
        discrete: i32,
    ) callconv(.c) void = null,
    axis_value120: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        axis: PointerAxis,
        value120: i32,
    ) callconv(.c) void = null,
    axis_relative_direction: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        axis: PointerAxis,
        direction: PointerAxisRelativeDirection,
    ) callconv(.c) void = null,
};

pub const PointerButtonState = enum(u32) {
    released = 0,
    pressed = 1,
};

pub const PointerAxis = enum(u32) {
    vertical_scroll = 0,
    horizontal_scroll = 1,
};

pub const PointerAxisSource = enum(u32) {
    wheel = 0,
    finger = 1,
    continuous = 2,
    wheel_tilt = 3,
};

pub const PointerAxisRelativeDirection = enum(u32) {
    identical = 0,
    inverted = 1,
};

pub const KeyboardListener = extern struct {
    keymap: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        format: KeyboardKeymapFormat,
        fd: i32,
        size: u32,
    ) callconv(.c) void = null,
    enter: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        serial: u32,
        surface: *Surface,
        keys: *anyopaque, // wl_array*
    ) callconv(.c) void = null,
    leave: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        serial: u32,
        surface: *Surface,
    ) callconv(.c) void = null,
    key: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        serial: u32,
        time: u32,
        key: u32,
        state: KeyState,
    ) callconv(.c) void = null,
    modifiers: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        serial: u32,
        mods_depressed: u32,
        mods_latched: u32,
        mods_locked: u32,
        group: u32,
    ) callconv(.c) void = null,
    repeat_info: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        rate: i32,
        delay: i32,
    ) callconv(.c) void = null,
};

pub const KeyboardKeymapFormat = enum(u32) {
    no_keymap = 0,
    xkb_v1 = 1,
};

pub const KeyState = enum(u32) {
    released = 0,
    pressed = 1,
};

pub const TouchListener = extern struct {
    down: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        serial: u32,
        time: u32,
        surface: *Surface,
        id: i32,
        x: Fixed,
        y: Fixed,
    ) callconv(.c) void = null,
    up: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        serial: u32,
        time: u32,
        id: i32,
    ) callconv(.c) void = null,
    motion: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        time: u32,
        id: i32,
        x: Fixed,
        y: Fixed,
    ) callconv(.c) void = null,
    frame: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
    ) callconv(.c) void = null,
    cancel: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
    ) callconv(.c) void = null,
    shape: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        id: i32,
        major: Fixed,
        minor: Fixed,
    ) callconv(.c) void = null,
    orientation: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        id: i32,
        orientation: Fixed,
    ) callconv(.c) void = null,
};

pub const OutputListener = extern struct {
    geometry: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        make: [*:0]const u8,
        model: [*:0]const u8,
        transform: i32,
    ) callconv(.c) void = null,
    mode: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        flags: u32,
        width: i32,
        height: i32,
        refresh: i32,
    ) callconv(.c) void = null,
    done: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
    ) callconv(.c) void = null,
    scale: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        factor: i32,
    ) callconv(.c) void = null,
    name: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        name: [*:0]const u8,
    ) callconv(.c) void = null,
    description: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        description: [*:0]const u8,
    ) callconv(.c) void = null,
};

// =============================================================================
// XDG Shell Listeners
// =============================================================================

pub const XdgWmBaseListener = extern struct {
    ping: ?*const fn (
        data: ?*anyopaque,
        xdg_wm_base: *XdgWmBase,
        serial: u32,
    ) callconv(.c) void = null,
};

pub const XdgSurfaceListener = extern struct {
    configure: ?*const fn (
        data: ?*anyopaque,
        xdg_surface: *XdgSurface,
        serial: u32,
    ) callconv(.c) void = null,
};

pub const XdgToplevelListener = extern struct {
    configure: ?*const fn (
        data: ?*anyopaque,
        xdg_toplevel: *XdgToplevel,
        width: i32,
        height: i32,
        states: *anyopaque, // wl_array*
    ) callconv(.c) void = null,
    close: ?*const fn (
        data: ?*anyopaque,
        xdg_toplevel: *XdgToplevel,
    ) callconv(.c) void = null,
    configure_bounds: ?*const fn (
        data: ?*anyopaque,
        xdg_toplevel: *XdgToplevel,
        width: i32,
        height: i32,
    ) callconv(.c) void = null,
    wm_capabilities: ?*const fn (
        data: ?*anyopaque,
        xdg_toplevel: *XdgToplevel,
        capabilities: *anyopaque, // wl_array*
    ) callconv(.c) void = null,
};

// =============================================================================
// XDG Decoration Listeners
// =============================================================================

pub const ZxdgToplevelDecorationV1Listener = extern struct {
    configure: ?*const fn (
        data: ?*anyopaque,
        decoration: *ZxdgToplevelDecorationV1,
        mode: ZxdgToplevelDecorationV1Mode,
    ) callconv(.c) void = null,
};

pub const ZxdgToplevelDecorationV1Mode = enum(u32) {
    undefined = 0,
    client_side = 1,
    server_side = 2,
};

// =============================================================================
// Text Input V3 Protocol (IME Support)
// =============================================================================

/// Text input V3 listener for IME events
pub const ZwpTextInputV3Listener = extern struct {
    /// Notifies when the compositor sends enter event (text input activated)
    enter: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        surface: *Surface,
    ) callconv(.c) void = null,

    /// Notifies when the compositor sends leave event (text input deactivated)
    leave: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        surface: *Surface,
    ) callconv(.c) void = null,

    /// Pre-edit string for composing text (shown but not committed)
    preedit_string: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        text: ?[*:0]const u8,
        cursor_begin: i32,
        cursor_end: i32,
    ) callconv(.c) void = null,

    /// Committed text from input method
    commit_string: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        text: ?[*:0]const u8,
    ) callconv(.c) void = null,

    /// Text to delete before cursor
    delete_surrounding_text: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        before_length: u32,
        after_length: u32,
    ) callconv(.c) void = null,

    /// Signifies end of a batch of events, apply accumulated state
    done: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        serial: u32,
    ) callconv(.c) void = null,
};

// =============================================================================
// Interface Structs (for wl_proxy_marshal_* calls)
// =============================================================================

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?*const Message,
    event_count: c_int,
    events: ?*const Message,
};

pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?*const ?*const Interface,
};

// =============================================================================
// Core Wayland C Functions (libwayland-client.so)
// =============================================================================

// Display
pub extern "wayland-client" fn wl_display_connect(name: ?[*:0]const u8) ?*Display;
pub extern "wayland-client" fn wl_display_disconnect(display: *Display) void;
pub extern "wayland-client" fn wl_display_dispatch_pending(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_roundtrip(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_flush(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_get_fd(display: *Display) c_int;

// Multi-threaded reading (a second thread with its own event queue). Every
// thread that waits on the display fd must prepare, then read or cancel.
pub const EventQueue = opaque {};
pub extern "wayland-client" fn wl_display_create_queue(display: *Display) ?*EventQueue;
pub extern "wayland-client" fn wl_event_queue_destroy(queue: *EventQueue) void;
pub extern "wayland-client" fn wl_display_prepare_read(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_prepare_read_queue(
    display: *Display,
    queue: *EventQueue,
) c_int;
pub extern "wayland-client" fn wl_display_read_events(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_cancel_read(display: *Display) void;
pub extern "wayland-client" fn wl_display_dispatch_queue_pending(
    display: *Display,
    queue: *EventQueue,
) c_int;
pub extern "wayland-client" fn wl_proxy_create_wrapper(proxy: *anyopaque) ?*anyopaque;
pub extern "wayland-client" fn wl_proxy_wrapper_destroy(wrapper: *anyopaque) void;
pub extern "wayland-client" fn wl_proxy_set_queue(proxy: *anyopaque, queue: ?*EventQueue) void;

// wl_display_get_registry is an inline function in wayland-client, we implement it here
pub fn wl_display_get_registry(display: *Display) ?*Registry {
    // wl_display::get_registry is opcode 1
    const WL_DISPLAY_GET_REGISTRY: u32 = 1;
    return @ptrCast(wl_proxy_marshal_flags(
        @ptrCast(display),
        WL_DISPLAY_GET_REGISTRY,
        &wl_registry_interface,
        wl_proxy_get_version(@ptrCast(display)),
        0,
    ));
}

// Proxy (base for all Wayland objects)
pub extern "wayland-client" fn wl_proxy_add_listener(
    proxy: *anyopaque,
    implementation: *const anyopaque,
    data: ?*anyopaque,
) c_int;
pub extern "wayland-client" fn wl_proxy_destroy(proxy: *anyopaque) void;
pub extern "wayland-client" fn wl_proxy_marshal_flags(proxy: *anyopaque, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, ...) ?*anyopaque;
pub extern "wayland-client" fn wl_proxy_get_version(proxy: *anyopaque) u32;

// =============================================================================
// Protocol Interface Declarations (linked from protocol libraries)
// =============================================================================

pub extern "wayland-client" var wl_registry_interface: Interface;
pub extern "wayland-client" var wl_compositor_interface: Interface;
pub extern "wayland-client" var wl_surface_interface: Interface;
pub extern "wayland-client" var wl_callback_interface: Interface;
pub extern "wayland-client" var wl_seat_interface: Interface;
pub extern "wayland-client" var wl_pointer_interface: Interface;
pub extern "wayland-client" var wl_keyboard_interface: Interface;
pub extern "wayland-client" var wl_touch_interface: Interface;
pub extern "wayland-client" var wl_output_interface: Interface;
pub extern "wayland-client" var wl_shm_interface: Interface;
pub extern "wayland-client" var wl_shm_pool_interface: Interface;
pub extern "wayland-client" var wl_buffer_interface: Interface;

// XDG shell interfaces (defined manually since they come from wayland-protocols, not wayland-client)
// These need proper message signatures for wl_proxy_marshal_flags to work correctly.

// Forward declare for type arrays
const xdg_surface_interface_ptr: ?*const Interface = &xdg_surface_interface;
const xdg_toplevel_interface_ptr: ?*const Interface = &xdg_toplevel_interface;
const xdg_positioner_interface_ptr: ?*const Interface = &xdg_positioner_interface;
const zxdg_toplevel_decoration_v1_interface_ptr: ?*const Interface = &zxdg_toplevel_decoration_v1_interface;

// Type arrays for messages with object/new_id arguments
const xdg_wm_base_create_positioner_types = [_]?*const Interface{xdg_positioner_interface_ptr};
const xdg_wm_base_get_xdg_surface_types = [_]?*const Interface{ xdg_surface_interface_ptr, &wl_surface_interface };
const xdg_surface_get_toplevel_types = [_]?*const Interface{xdg_toplevel_interface_ptr};
const xdg_toplevel_set_parent_types = [_]?*const Interface{xdg_toplevel_interface_ptr};
const zxdg_decoration_manager_get_decoration_types = [_]?*const Interface{ zxdg_toplevel_decoration_v1_interface_ptr, xdg_toplevel_interface_ptr };
const zwp_text_input_manager_v3_get_text_input_types = [_]?*const Interface{ zwp_text_input_v3_interface_ptr, &wl_seat_interface };

// Viewporter forward declarations
const wp_viewport_interface_ptr: ?*const Interface = &wp_viewport_interface;
const wp_viewporter_get_viewport_types = [_]?*const Interface{ wp_viewport_interface_ptr, &wl_surface_interface };

// Cursor shape forward declarations
const wp_cursor_shape_device_v1_interface_ptr: ?*const Interface = &wp_cursor_shape_device_v1_interface;
const wp_cursor_shape_manager_v1_get_pointer_types = [_]?*const Interface{ wp_cursor_shape_device_v1_interface_ptr, &wl_pointer_interface };

// Fractional scale forward declarations
const wp_fractional_scale_v1_interface_ptr: ?*const Interface = &wp_fractional_scale_v1_interface;
const wp_fractional_scale_manager_v1_get_fractional_scale_types = [_]?*const Interface{
    wp_fractional_scale_v1_interface_ptr,
    &wl_surface_interface,
};

// Type arrays for text input v3 events with object arguments
const zwp_text_input_v3_enter_types = [_]?*const Interface{&wl_surface_interface};
const zwp_text_input_v3_leave_types = [_]?*const Interface{&wl_surface_interface};

// xdg_wm_base events: ping
const xdg_wm_base_events = [_]Message{
    .{ .name = "ping", .signature = "u", .types = null },
};

// xdg_wm_base methods: destroy, create_positioner, get_xdg_surface, pong
const xdg_wm_base_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "create_positioner", .signature = "n", .types = @ptrCast(&xdg_wm_base_create_positioner_types) },
    .{ .name = "get_xdg_surface", .signature = "no", .types = @ptrCast(&xdg_wm_base_get_xdg_surface_types) },
    .{ .name = "pong", .signature = "u", .types = null },
};

pub const xdg_wm_base_interface: Interface = .{
    .name = "xdg_wm_base",
    .version = 6,
    .method_count = 4,
    .methods = @ptrCast(&xdg_wm_base_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_wm_base_events),
};

// xdg_surface events: configure
const xdg_surface_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};

// xdg_surface methods: destroy, get_toplevel, get_popup, set_window_geometry, ack_configure
const xdg_surface_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel", .signature = "n", .types = @ptrCast(&xdg_surface_get_toplevel_types) },
    .{ .name = "get_popup", .signature = "noo", .types = null }, // simplified
    .{ .name = "set_window_geometry", .signature = "iiii", .types = null },
    .{ .name = "ack_configure", .signature = "u", .types = null },
};

pub const xdg_surface_interface: Interface = .{
    .name = "xdg_surface",
    .version = 6,
    .method_count = 5,
    .methods = @ptrCast(&xdg_surface_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_surface_events),
};

// xdg_toplevel events: configure, close, configure_bounds, wm_capabilities
const xdg_toplevel_events = [_]Message{
    .{ .name = "configure", .signature = "iia", .types = null },
    .{ .name = "close", .signature = "", .types = null },
    .{ .name = "configure_bounds", .signature = "ii", .types = null },
    .{ .name = "wm_capabilities", .signature = "a", .types = null },
};

// xdg_toplevel methods (14 total, we define the ones we use)
const xdg_toplevel_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_parent", .signature = "?o", .types = @ptrCast(&xdg_toplevel_set_parent_types) },
    .{ .name = "set_title", .signature = "s", .types = null },
    .{ .name = "set_app_id", .signature = "s", .types = null },
    .{ .name = "show_window_menu", .signature = "ouii", .types = null },
    .{ .name = "move", .signature = "ou", .types = null },
    .{ .name = "resize", .signature = "ouu", .types = null },
    .{ .name = "set_max_size", .signature = "ii", .types = null },
    .{ .name = "set_min_size", .signature = "ii", .types = null },
    .{ .name = "set_maximized", .signature = "", .types = null },
    .{ .name = "unset_maximized", .signature = "", .types = null },
    .{ .name = "set_fullscreen", .signature = "?o", .types = null },
    .{ .name = "unset_fullscreen", .signature = "", .types = null },
    .{ .name = "set_minimized", .signature = "", .types = null },
};

pub const xdg_toplevel_interface: Interface = .{
    .name = "xdg_toplevel",
    .version = 6,
    .method_count = 14,
    .methods = @ptrCast(&xdg_toplevel_methods),
    .event_count = 4,
    .events = @ptrCast(&xdg_toplevel_events),
};

pub const xdg_positioner_interface: Interface = .{
    .name = "xdg_positioner",
    .version = 6,
    .method_count = 10,
    .methods = null,
    .event_count = 0,
    .events = null,
};

// XDG decoration interfaces
const zxdg_decoration_manager_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel_decoration", .signature = "no", .types = @ptrCast(&zxdg_decoration_manager_get_decoration_types) },
};

pub const zxdg_decoration_manager_v1_interface: Interface = .{
    .name = "zxdg_decoration_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&zxdg_decoration_manager_v1_methods),
    .event_count = 0,
    .events = null,
};

// zxdg_toplevel_decoration_v1 events: configure
const zxdg_toplevel_decoration_v1_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};

const zxdg_toplevel_decoration_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_mode", .signature = "u", .types = null },
    .{ .name = "unset_mode", .signature = "", .types = null },
};

pub const zxdg_toplevel_decoration_v1_interface: Interface = .{
    .name = "zxdg_toplevel_decoration_v1",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&zxdg_toplevel_decoration_v1_methods),
    .event_count = 1,
    .events = @ptrCast(&zxdg_toplevel_decoration_v1_events),
};

// Text Input V3 interfaces (IME support)
const zwp_text_input_v3_interface_ptr = &zwp_text_input_v3_interface;

// zwp_text_input_manager_v3 methods: destroy, get_text_input
const zwp_text_input_manager_v3_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_text_input", .signature = "no", .types = @ptrCast(&zwp_text_input_manager_v3_get_text_input_types) },
};

pub const zwp_text_input_manager_v3_interface: Interface = .{
    .name = "zwp_text_input_manager_v3",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&zwp_text_input_manager_v3_methods),
    .event_count = 0,
    .events = null,
};

// zwp_text_input_v3 events: enter, leave, preedit_string, commit_string, delete_surrounding_text, done
const zwp_text_input_v3_events = [_]Message{
    .{ .name = "enter", .signature = "o", .types = @ptrCast(&zwp_text_input_v3_enter_types) },
    .{ .name = "leave", .signature = "o", .types = @ptrCast(&zwp_text_input_v3_leave_types) },
    .{ .name = "preedit_string", .signature = "?sii", .types = null },
    .{ .name = "commit_string", .signature = "?s", .types = null },
    .{ .name = "delete_surrounding_text", .signature = "uu", .types = null },
    .{ .name = "done", .signature = "u", .types = null },
};

// zwp_text_input_v3 methods: destroy, enable, disable, set_surrounding_text, set_text_change_cause, set_content_type, set_cursor_rectangle, commit
const zwp_text_input_v3_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "enable", .signature = "", .types = null },
    .{ .name = "disable", .signature = "", .types = null },
    .{ .name = "set_surrounding_text", .signature = "sii", .types = null },
    .{ .name = "set_text_change_cause", .signature = "u", .types = null },
    .{ .name = "set_content_type", .signature = "uu", .types = null },
    .{ .name = "set_cursor_rectangle", .signature = "iiii", .types = null },
    .{ .name = "commit", .signature = "", .types = null },
};

pub const zwp_text_input_v3_interface: Interface = .{
    .name = "zwp_text_input_v3",
    .version = 1,
    .method_count = 8,
    .methods = @ptrCast(&zwp_text_input_v3_methods),
    .event_count = 6,
    .events = @ptrCast(&zwp_text_input_v3_events),
};

// =============================================================================
// Higher-Level Wrapper Functions
// =============================================================================

pub const MARSHAL_FLAG_DESTROY: u32 = 1;

// Interface accessors (for registryBind)
pub fn getOutputInterface() *const Interface {
    return &wl_output_interface;
}

// Registry operations
pub fn registryAddListener(registry: *Registry, listener: *const RegistryListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(registry), @ptrCast(listener), data) == 0;
}

pub fn registryBind(registry: *Registry, name: u32, interface: *const Interface, version: u32) ?*anyopaque {
    return wl_proxy_marshal_flags(
        @ptrCast(registry),
        0, // WL_REGISTRY_BIND
        interface,
        version,
        0,
        name,
        interface.name,
        version,
        @as(?*anyopaque, null),
    );
}

pub fn registryDestroy(registry: *Registry) void {
    wl_proxy_destroy(@ptrCast(registry));
}

// Compositor operations
pub fn compositorCreateSurface(compositor: *Compositor) ?*Surface {
    const result = wl_proxy_marshal_flags(
        @ptrCast(compositor),
        0, // WL_COMPOSITOR_CREATE_SURFACE
        &wl_surface_interface,
        wl_proxy_get_version(@ptrCast(compositor)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn compositorDestroy(compositor: *Compositor) void {
    wl_proxy_destroy(@ptrCast(compositor));
}

// Surface operations

/// wl_surface request opcodes in protocol declaration order. A request's opcode is its
/// index in the protocol XML, so a bare literal silently names a different request when it
/// is off by one: `set_buffer_scale` written as 6 would marshal `commit`. Field names match the
/// protocol's request names so a test can check every opcode against libwayland's table.
const SurfaceRequest = enum(u32) {
    destroy = 0,
    attach = 1,
    damage = 2,
    frame = 3,
    set_opaque_region = 4,
    set_input_region = 5,
    commit = 6,
    set_buffer_transform = 7,
    set_buffer_scale = 8,
    damage_buffer = 9,
    offset = 10,
};

pub fn surfaceAddListener(surface: *Surface, listener: *const SurfaceListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(surface), @ptrCast(listener), data) == 0;
}

pub fn surfaceDestroy(surface: *Surface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        @backingInt(SurfaceRequest.destroy),
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn surfaceCommit(surface: *Surface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        @backingInt(SurfaceRequest.commit),
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
    );
}

pub fn surfaceFrame(surface: *Surface) ?*Callback {
    const result = wl_proxy_marshal_flags(
        @ptrCast(surface),
        @backingInt(SurfaceRequest.frame),
        &wl_callback_interface,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn surfaceSetBufferScale(surface: *Surface, scale: i32) void {
    // The compositor raises the fatal `invalid_scale` protocol error for a scale below one.
    std.debug.assert(scale >= 1);
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        @backingInt(SurfaceRequest.set_buffer_scale),
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        scale,
    );
}

test "wl_surface request opcodes match libwayland's protocol table" {
    // Goal: catch a helper marshaling the wrong wl_surface request. Methodology: the
    // libwayland-client `wl_surface_interface` table is generated from the protocol XML and
    // indexed by opcode, so each `SurfaceRequest` name must equal the name at its opcode.
    const names = @typeInfo(SurfaceRequest).@"enum".field_names;
    const values = @typeInfo(SurfaceRequest).@"enum".field_values;
    const method_count: usize = @intCast(wl_surface_interface.method_count);
    const methods: [*]const Message = @ptrCast(wl_surface_interface.methods.?);
    inline for (names, values) |name, opcode| {
        try std.testing.expect(opcode < method_count);
        try std.testing.expectEqualStrings(name, std.mem.span(methods[opcode].name));
    }
}

// =============================================================================
// wp_viewporter functions (HiDPI support)
// =============================================================================

/// Bind to wp_viewporter global
pub fn bindViewporter(registry: *Registry, name: u32, version: u32) ?*WpViewporter {
    return @ptrCast(@alignCast(registryBind(
        registry,
        name,
        &wp_viewporter_interface,
        @min(version, 1),
    )));
}

/// Create a viewport for a surface
pub fn viewporterGetViewport(viewporter: *WpViewporter, surface: *Surface) ?*WpViewport {
    const result = wl_proxy_marshal_flags(
        @ptrCast(viewporter),
        1, // WP_VIEWPORTER_GET_VIEWPORT
        &wp_viewport_interface,
        wl_proxy_get_version(@ptrCast(viewporter)),
        0,
        @as(?*anyopaque, null),
        @as(*anyopaque, @ptrCast(surface)),
    );
    return @ptrCast(@alignCast(result));
}

/// Set the destination size of the viewport (in logical pixels)
/// This is the size the surface will appear on screen
pub fn viewportSetDestination(viewport: *WpViewport, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(viewport),
        2, // WP_VIEWPORT_SET_DESTINATION
        null,
        wl_proxy_get_version(@ptrCast(viewport)),
        0,
        width,
        height,
    );
}

/// Destroy viewport
pub fn viewportDestroy(viewport: *WpViewport) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(viewport),
        0, // WP_VIEWPORT_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(viewport)),
        0,
    );
    wl_proxy_destroy(@ptrCast(viewport));
}

// =============================================================================
// wp_fractional_scale functions (fractional output scales)
// =============================================================================

/// wp_fractional_scale_manager_v1 request opcodes in protocol declaration order. See
/// `SurfaceRequest` for why opcodes are named instead of written as literals.
const FractionalScaleManagerRequest = enum(u32) {
    destroy = 0,
    get_fractional_scale = 1,
};

/// wp_fractional_scale_v1 request opcodes in protocol declaration order.
const FractionalScaleRequest = enum(u32) {
    destroy = 0,
};

pub fn bindFractionalScaleManager(
    registry: *Registry,
    name: u32,
    version: u32,
) ?*WpFractionalScaleManagerV1 {
    std.debug.assert(version >= 1);
    return @ptrCast(@alignCast(registryBind(
        registry,
        name,
        &wp_fractional_scale_manager_v1_interface,
        @min(version, 1),
    )));
}

/// Create the surface's wp_fractional_scale_v1. The scale it reports applies only
/// through wp_viewporter: the buffer is drawn at the logical size times the scale and
/// the viewport's destination maps it back to the logical size, so a caller binds it
/// only when the surface has a viewport.
pub fn fractionalScaleManagerGetFractionalScale(
    manager: *WpFractionalScaleManagerV1,
    surface: *Surface,
) ?*WpFractionalScaleV1 {
    const result = wl_proxy_marshal_flags(
        @ptrCast(manager),
        @backingInt(FractionalScaleManagerRequest.get_fractional_scale),
        &wp_fractional_scale_v1_interface,
        wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null),
        @as(*anyopaque, @ptrCast(surface)),
    );
    return @ptrCast(@alignCast(result));
}

pub fn fractionalScaleManagerDestroy(manager: *WpFractionalScaleManagerV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(manager),
        @backingInt(FractionalScaleManagerRequest.destroy),
        null,
        wl_proxy_get_version(@ptrCast(manager)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn fractionalScaleAddListener(
    fractional_scale: *WpFractionalScaleV1,
    listener: *const FractionalScaleListener,
    data: ?*anyopaque,
) bool {
    return wl_proxy_add_listener(@ptrCast(fractional_scale), @ptrCast(listener), data) == 0;
}

pub fn fractionalScaleDestroy(fractional_scale: *WpFractionalScaleV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(fractional_scale),
        @backingInt(FractionalScaleRequest.destroy),
        null,
        wl_proxy_get_version(@ptrCast(fractional_scale)),
        MARSHAL_FLAG_DESTROY,
    );
}

test "wp_fractional_scale opcodes and events match the protocol tables" {
    // Goal: catch the request enums and the hand-written wire tables drifting apart,
    // which would marshal the wrong request or demarshal `preferred_scale` wrongly.
    // Methodology: each opcode's name must equal the table entry at its index, and the
    // event must keep the protocol's single uint argument (the scale in 120ths).
    const manager_names = @typeInfo(FractionalScaleManagerRequest).@"enum".field_names;
    const manager_values = @typeInfo(FractionalScaleManagerRequest).@"enum".field_values;
    try std.testing.expectEqual(manager_names.len, wp_fractional_scale_manager_v1_methods.len);
    inline for (manager_names, manager_values) |name, opcode| {
        const method = wp_fractional_scale_manager_v1_methods[opcode];
        try std.testing.expectEqualStrings(name, std.mem.span(method.name));
    }
    const scale_names = @typeInfo(FractionalScaleRequest).@"enum".field_names;
    const scale_values = @typeInfo(FractionalScaleRequest).@"enum".field_values;
    try std.testing.expectEqual(scale_names.len, wp_fractional_scale_v1_methods.len);
    inline for (scale_names, scale_values) |name, opcode| {
        const method = wp_fractional_scale_v1_methods[opcode];
        try std.testing.expectEqualStrings(name, std.mem.span(method.name));
    }
    try std.testing.expectEqual(1, wp_fractional_scale_v1_events.len);
    const event = wp_fractional_scale_v1_events[0];
    try std.testing.expectEqualStrings("preferred_scale", std.mem.span(event.name));
    try std.testing.expectEqualStrings("u", std.mem.span(event.signature));
}

// Callback operations
pub fn callbackAddListener(callback: *Callback, listener: *const CallbackListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(callback), @ptrCast(listener), data) == 0;
}

pub fn callbackDestroy(callback: *Callback) void {
    wl_proxy_destroy(@ptrCast(callback));
}

// Shared-memory buffers (CPU rendering)

/// `WL_SHM_FORMAT_XRGB8888`: 32-bit little-endian B, G, R, X. Every compositor
/// must support it, so the CPU renderer needs no format negotiation.
pub const WL_SHM_FORMAT_XRGB8888: u32 = 1;

pub fn bindShm(registry: *Registry, name: u32, version: u32) ?*Shm {
    return @ptrCast(@alignCast(registryBind(registry, name, &wl_shm_interface, @min(version, 1))));
}

pub fn shmCreatePool(shm: *Shm, fd: i32, size: i32) ?*ShmPool {
    const result = wl_proxy_marshal_flags(
        @ptrCast(shm),
        0, // WL_SHM_CREATE_POOL
        &wl_shm_pool_interface,
        wl_proxy_get_version(@ptrCast(shm)),
        0,
        @as(?*anyopaque, null),
        fd,
        size,
    );
    return @ptrCast(@alignCast(result));
}

pub fn shmDestroy(shm: *Shm) void {
    wl_proxy_destroy(@ptrCast(shm));
}

pub fn shmPoolCreateBuffer(
    pool: *ShmPool,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,
) ?*Buffer {
    const result = wl_proxy_marshal_flags(
        @ptrCast(pool),
        0, // WL_SHM_POOL_CREATE_BUFFER
        &wl_buffer_interface,
        wl_proxy_get_version(@ptrCast(pool)),
        0,
        @as(?*anyopaque, null),
        offset,
        width,
        height,
        stride,
        format,
    );
    return @ptrCast(@alignCast(result));
}

pub fn shmPoolDestroy(pool: *ShmPool) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(pool),
        1, // WL_SHM_POOL_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(pool)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn bufferAddListener(buffer: *Buffer, listener: *const BufferListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(buffer), @ptrCast(listener), data) == 0;
}

pub fn bufferDestroy(buffer: *Buffer) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(buffer),
        0, // WL_BUFFER_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(buffer)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn surfaceAttach(surface: *Surface, buffer: ?*Buffer, x: i32, y: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        1, // WL_SURFACE_ATTACH
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        @as(?*anyopaque, @ptrCast(buffer)),
        x,
        y,
    );
}

/// Requires `wl_surface` version 4; the compositor is bound at up to 6.
pub fn surfaceDamageBuffer(surface: *Surface, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        9, // WL_SURFACE_DAMAGE_BUFFER
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        x,
        y,
        width,
        height,
    );
}

// Seat operations
pub fn seatAddListener(seat: *Seat, listener: *const SeatListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(seat), @ptrCast(listener), data) == 0;
}

pub fn seatGetPointer(seat: *Seat) ?*Pointer {
    const result = wl_proxy_marshal_flags(
        @ptrCast(seat),
        0, // WL_SEAT_GET_POINTER
        &wl_pointer_interface,
        wl_proxy_get_version(@ptrCast(seat)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn seatGetKeyboard(seat: *Seat) ?*Keyboard {
    const result = wl_proxy_marshal_flags(
        @ptrCast(seat),
        1, // WL_SEAT_GET_KEYBOARD
        &wl_keyboard_interface,
        wl_proxy_get_version(@ptrCast(seat)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn seatDestroy(seat: *Seat) void {
    wl_proxy_destroy(@ptrCast(seat));
}

// Pointer operations
pub fn pointerAddListener(pointer: *Pointer, listener: *const PointerListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(pointer), @ptrCast(listener), data) == 0;
}

pub fn pointerDestroy(pointer: *Pointer) void {
    // Use wl_proxy_destroy directly instead of release request
    // The release request requires wl_seat version 3+ and can cause issues
    wl_proxy_destroy(@ptrCast(pointer));
}

/// wl_pointer request opcodes in protocol declaration order.
const PointerRequest = enum(u32) {
    set_cursor = 0,
    release = 1,
};

/// Show `surface` as the pointer image, or hide the pointer when it is null. `serial` must be
/// the serial of the latest `wl_pointer.enter`; the compositor ignores any other.
pub fn pointer_set_cursor(
    pointer: *Pointer,
    serial: u32,
    surface: ?*Surface,
    hotspot: struct { x: i32, y: i32 },
) void {
    std.debug.assert(hotspot.x >= 0);
    std.debug.assert(hotspot.y >= 0);
    _ = wl_proxy_marshal_flags(
        @ptrCast(pointer),
        @backingInt(PointerRequest.set_cursor),
        null,
        wl_proxy_get_version(@ptrCast(pointer)),
        0,
        serial,
        @as(?*anyopaque, @ptrCast(surface)),
        hotspot.x,
        hotspot.y,
    );
}

test "wl_pointer request opcodes match libwayland's protocol table" {
    // Goal: catch `pointer_set_cursor` marshaling another request. Methodology: the same as
    // the wl_surface test; each `PointerRequest` name must equal the name at its opcode.
    const names = @typeInfo(PointerRequest).@"enum".field_names;
    const values = @typeInfo(PointerRequest).@"enum".field_values;
    const method_count: usize = @intCast(wl_pointer_interface.method_count);
    const methods: [*]const Message = @ptrCast(wl_pointer_interface.methods.?);
    try std.testing.expectEqual(names.len, method_count);
    inline for (names, values) |name, opcode| {
        try std.testing.expect(opcode < method_count);
        try std.testing.expectEqualStrings(name, std.mem.span(methods[opcode].name));
    }
}

// =============================================================================
// libwayland-cursor (XCursor theme loading)
// =============================================================================

pub const CursorTheme = opaque {};

/// `struct wl_cursor_image`: one frame of a cursor, in buffer pixels.
pub const CursorImage = extern struct {
    width: u32,
    height: u32,
    hotspot_x: u32,
    hotspot_y: u32,
    delay: u32,
};

/// `struct wl_cursor`: the frames of one named cursor.
pub const Cursor = extern struct {
    image_count: c_uint,
    images: [*]*CursorImage,
    name: [*:0]u8,
};

/// Loads every cursor of the theme into one shared-memory pool. A null `name` loads the
/// "default" theme; a theme with no cursors falls back to libwayland-cursor's built-in set.
pub extern "wayland-cursor" fn wl_cursor_theme_load(
    name: ?[*:0]const u8,
    size: c_int,
    shm: *Shm,
) ?*CursorTheme;
pub extern "wayland-cursor" fn wl_cursor_theme_destroy(theme: *CursorTheme) void;
/// A lookup in the already-loaded table: it never loads or allocates.
pub extern "wayland-cursor" fn wl_cursor_theme_get_cursor(
    theme: *CursorTheme,
    name: [*:0]const u8,
) ?*Cursor;
/// Creates the image's `wl_buffer` on the first call and returns the same buffer afterwards.
/// The theme owns the buffer and destroys it in `wl_cursor_theme_destroy`.
pub extern "wayland-cursor" fn wl_cursor_image_get_buffer(image: *CursorImage) ?*Buffer;

pub fn cursorShapeManagerGetPointer(manager: *WpCursorShapeManagerV1, pointer: *Pointer) ?*WpCursorShapeDeviceV1 {
    const result = wl_proxy_marshal_flags(
        @ptrCast(manager),
        1, // get_pointer
        &wp_cursor_shape_device_v1_interface,
        wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null),
        pointer,
    );
    return @ptrCast(@alignCast(result));
}

pub fn cursorShapeManagerDestroy(manager: *WpCursorShapeManagerV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(manager),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(manager)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn cursorShapeDeviceSetShape(device: *WpCursorShapeDeviceV1, serial: u32, shape: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(device),
        1, // set_shape
        null,
        wl_proxy_get_version(@ptrCast(device)),
        0,
        serial,
        shape,
    );
}

pub fn cursorShapeDeviceDestroy(device: *WpCursorShapeDeviceV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(device),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(device)),
        MARSHAL_FLAG_DESTROY,
    );
}

// Keyboard operations
pub fn keyboardAddListener(keyboard: *Keyboard, listener: *const KeyboardListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(keyboard), @ptrCast(listener), data) == 0;
}

pub fn keyboardDestroy(keyboard: *Keyboard) void {
    // Use wl_proxy_destroy directly instead of release request
    // The release request requires wl_seat version 3+ and can cause issues
    wl_proxy_destroy(@ptrCast(keyboard));
}

// Touch operations
pub fn seatGetTouch(seat: *Seat) ?*Touch {
    const result = wl_proxy_marshal_flags(
        @ptrCast(seat),
        2, // WL_SEAT_GET_TOUCH
        &wl_touch_interface,
        wl_proxy_get_version(@ptrCast(seat)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn touchAddListener(touch: *Touch, listener: *const TouchListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(touch), @ptrCast(listener), data) == 0;
}

pub fn touchDestroy(touch: *Touch) void {
    wl_proxy_destroy(@ptrCast(touch));
}

// Output operations
pub fn outputAddListener(output: *Output, listener: *const OutputListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(output), @ptrCast(listener), data) == 0;
}

pub fn outputDestroy(output: *Output) void {
    wl_proxy_destroy(@ptrCast(output));
}

// =============================================================================
// XDG Shell Wrapper Functions
// =============================================================================

// XDG WM Base
pub fn xdgWmBaseAddListener(wm_base: *XdgWmBase, listener: *const XdgWmBaseListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(wm_base), @ptrCast(listener), data) == 0;
}

pub fn xdgWmBasePong(wm_base: *XdgWmBase, serial: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(wm_base),
        3, // XDG_WM_BASE_PONG (destroy=0, create_positioner=1, get_xdg_surface=2, pong=3)
        null,
        wl_proxy_get_version(@ptrCast(wm_base)),
        0,
        serial,
    );
}

pub fn xdgWmBaseGetXdgSurface(wm_base: *XdgWmBase, surface: *Surface) ?*XdgSurface {
    const result = wl_proxy_marshal_flags(
        @ptrCast(wm_base),
        2, // XDG_WM_BASE_GET_XDG_SURFACE
        &xdg_surface_interface,
        wl_proxy_get_version(@ptrCast(wm_base)),
        0,
        @as(?*anyopaque, null),
        @as(*anyopaque, @ptrCast(surface)),
    );
    return @ptrCast(@alignCast(result));
}

pub fn xdgWmBaseDestroy(wm_base: *XdgWmBase) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(wm_base),
        0, // XDG_WM_BASE_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(wm_base)),
        MARSHAL_FLAG_DESTROY,
    );
}

// XDG Surface
pub fn xdgSurfaceAddListener(xdg_surface: *XdgSurface, listener: *const XdgSurfaceListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(xdg_surface), @ptrCast(listener), data) == 0;
}

pub fn xdgSurfaceGetToplevel(xdg_surface: *XdgSurface) ?*XdgToplevel {
    const result = wl_proxy_marshal_flags(
        @ptrCast(xdg_surface),
        1, // XDG_SURFACE_GET_TOPLEVEL
        &xdg_toplevel_interface,
        wl_proxy_get_version(@ptrCast(xdg_surface)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn xdgSurfaceAckConfigure(xdg_surface: *XdgSurface, serial: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(xdg_surface),
        4, // XDG_SURFACE_ACK_CONFIGURE
        null,
        wl_proxy_get_version(@ptrCast(xdg_surface)),
        0,
        serial,
    );
}

pub fn xdgSurfaceSetWindowGeometry(xdg_surface: *XdgSurface, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(xdg_surface),
        3, // XDG_SURFACE_SET_WINDOW_GEOMETRY
        null,
        wl_proxy_get_version(@ptrCast(xdg_surface)),
        0,
        x,
        y,
        width,
        height,
    );
}

pub fn xdgSurfaceDestroy(xdg_surface: *XdgSurface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(xdg_surface),
        0, // XDG_SURFACE_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(xdg_surface)),
        MARSHAL_FLAG_DESTROY,
    );
}

// XDG Toplevel

/// xdg_toplevel request opcodes in protocol declaration order. A request's opcode is its
/// index in the protocol XML, and xdg-shell declares `set_max_size` before `set_min_size`:
/// the size helpers once marshaled each other's opcode, so the compositor received the min
/// size as the max size. Field names match `xdg_toplevel_methods` so a test can check every
/// opcode against that table.
const XdgToplevelRequest = enum(u32) {
    destroy = 0,
    set_parent = 1,
    set_title = 2,
    set_app_id = 3,
    show_window_menu = 4,
    move = 5,
    resize = 6,
    set_max_size = 7,
    set_min_size = 8,
    set_maximized = 9,
    unset_maximized = 10,
    set_fullscreen = 11,
    unset_fullscreen = 12,
    set_minimized = 13,
};

pub fn xdgToplevelAddListener(toplevel: *XdgToplevel, listener: *const XdgToplevelListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(toplevel), @ptrCast(listener), data) == 0;
}

pub fn xdgToplevelSetTitle(toplevel: *XdgToplevel, title: [*:0]const u8) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        @backingInt(XdgToplevelRequest.set_title),
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        title,
    );
}

pub fn xdgToplevelSetAppId(toplevel: *XdgToplevel, app_id: [*:0]const u8) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        @backingInt(XdgToplevelRequest.set_app_id),
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        app_id,
    );
}

pub fn xdgToplevelSetMinSize(toplevel: *XdgToplevel, width: i32, height: i32) void {
    // Zero means unconstrained; the compositor raises the fatal `invalid_size` error below it.
    std.debug.assert(width >= 0);
    std.debug.assert(height >= 0);
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        @backingInt(XdgToplevelRequest.set_min_size),
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        width,
        height,
    );
}

pub fn xdgToplevelSetMaxSize(toplevel: *XdgToplevel, width: i32, height: i32) void {
    // Zero means unconstrained; the compositor raises the fatal `invalid_size` error below it.
    std.debug.assert(width >= 0);
    std.debug.assert(height >= 0);
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        @backingInt(XdgToplevelRequest.set_max_size),
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        width,
        height,
    );
}

/// Start an interactive move operation (user drags window)
/// Must be called in response to a pointer button press event
pub fn xdgToplevelMove(toplevel: *XdgToplevel, seat: *Seat, serial: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        @backingInt(XdgToplevelRequest.move),
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        seat,
        serial,
    );
}

/// Resize edge flags for xdgToplevelResize
pub const ResizeEdge = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
};

/// Start an interactive resize operation
/// Must be called in response to a pointer button press event
pub fn xdgToplevelResize(toplevel: *XdgToplevel, seat: *Seat, serial: u32, edges: ResizeEdge) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        @backingInt(XdgToplevelRequest.resize),
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        seat,
        serial,
        @backingInt(edges),
    );
}

pub fn xdgToplevelDestroy(toplevel: *XdgToplevel) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        @backingInt(XdgToplevelRequest.destroy),
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        MARSHAL_FLAG_DESTROY,
    );
}

test "xdg_toplevel request opcodes match the xdg_toplevel request table" {
    // Goal: catch a helper marshaling the wrong xdg_toplevel request, as when set_min_size and
    // set_max_size were swapped. Methodology: `xdg_toplevel_methods` is the wire table passed
    // to libwayland and is indexed by opcode, so each `XdgToplevelRequest` name must equal the
    // name at its opcode. The size requests are also pinned by name and value.
    const names = @typeInfo(XdgToplevelRequest).@"enum".field_names;
    const values = @typeInfo(XdgToplevelRequest).@"enum".field_values;
    const method_count: usize = @intCast(xdg_toplevel_interface.method_count);
    try std.testing.expectEqual(xdg_toplevel_methods.len, method_count);
    try std.testing.expectEqual(method_count, names.len);
    inline for (names, values) |name, opcode| {
        try std.testing.expect(opcode < method_count);
        try std.testing.expectEqualStrings(name, std.mem.span(xdg_toplevel_methods[opcode].name));
    }
    try std.testing.expectEqual(7, @backingInt(XdgToplevelRequest.set_max_size));
    try std.testing.expectEqual(8, @backingInt(XdgToplevelRequest.set_min_size));
}

// =============================================================================
// XDG Decoration Wrapper Functions
// =============================================================================

pub fn zxdgDecorationManagerV1GetToplevelDecoration(
    manager: *ZxdgDecorationManagerV1,
    toplevel: *XdgToplevel,
) ?*ZxdgToplevelDecorationV1 {
    const result = wl_proxy_marshal_flags(
        @ptrCast(manager),
        1, // ZXDG_DECORATION_MANAGER_V1_GET_TOPLEVEL_DECORATION
        &zxdg_toplevel_decoration_v1_interface,
        wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null),
        @as(*anyopaque, @ptrCast(toplevel)),
    );
    return @ptrCast(@alignCast(result));
}

pub fn zxdgDecorationManagerV1Destroy(manager: *ZxdgDecorationManagerV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(manager),
        0, // ZXDG_DECORATION_MANAGER_V1_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(manager)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn zxdgToplevelDecorationV1AddListener(
    decoration: *ZxdgToplevelDecorationV1,
    listener: *const ZxdgToplevelDecorationV1Listener,
    data: ?*anyopaque,
) bool {
    return wl_proxy_add_listener(@ptrCast(decoration), @ptrCast(listener), data) == 0;
}

pub fn zxdgToplevelDecorationV1SetMode(decoration: *ZxdgToplevelDecorationV1, mode: ZxdgToplevelDecorationV1Mode) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(decoration),
        1, // ZXDG_TOPLEVEL_DECORATION_V1_SET_MODE
        null,
        wl_proxy_get_version(@ptrCast(decoration)),
        0,
        @backingInt(mode),
    );
}

pub fn zxdgToplevelDecorationV1Destroy(decoration: *ZxdgToplevelDecorationV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(decoration),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(decoration)),
        MARSHAL_FLAG_DESTROY,
    );
}

// =============================================================================
// Text Input V3 Functions (IME Support)
// =============================================================================

/// Get a text input object from the text input manager
pub fn zwpTextInputManagerV3GetTextInput(manager: *ZwpTextInputManagerV3, seat: *Seat) ?*ZwpTextInputV3 {
    return @ptrCast(wl_proxy_marshal_flags(
        @ptrCast(manager),
        1, // get_text_input
        &zwp_text_input_v3_interface,
        wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null), // new_id placeholder
        seat,
    ));
}

/// Destroy the text input manager
pub fn zwpTextInputManagerV3Destroy(manager: *ZwpTextInputManagerV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(manager),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(manager)),
        MARSHAL_FLAG_DESTROY,
    );
}

/// Add listener to text input
pub fn zwpTextInputV3AddListener(text_input: *ZwpTextInputV3, listener: *const ZwpTextInputV3Listener, data: ?*anyopaque) void {
    _ = wl_proxy_add_listener(@ptrCast(text_input), @ptrCast(listener), data);
}

/// Destroy text input
pub fn zwpTextInputV3Destroy(text_input: *ZwpTextInputV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        MARSHAL_FLAG_DESTROY,
    );
}

/// Enable text input (start receiving input)
pub fn zwpTextInputV3Enable(text_input: *ZwpTextInputV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        1, // enable
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
    );
}

/// Disable text input (stop receiving input)
pub fn zwpTextInputV3Disable(text_input: *ZwpTextInputV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        2, // disable
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
    );
}

/// Set cursor rectangle for IME candidate window positioning
pub fn zwpTextInputV3SetCursorRectangle(text_input: *ZwpTextInputV3, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        6, // set_cursor_rectangle
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
        x,
        y,
        width,
        height,
    );
}

/// Commit pending state
pub fn zwpTextInputV3Commit(text_input: *ZwpTextInputV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        7, // commit
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
    );
}

// =============================================================================
// Helper Constants
// =============================================================================

/// Linux button codes (from linux/input-event-codes.h)
pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

/// Interface name constants for registry binding
pub const WL_COMPOSITOR_INTERFACE_NAME = "wl_compositor";
pub const WL_SHM_INTERFACE_NAME = "wl_shm";
pub const WL_SEAT_INTERFACE_NAME = "wl_seat";
pub const WL_OUTPUT_INTERFACE_NAME = "wl_output";
pub const XDG_WM_BASE_INTERFACE_NAME = "xdg_wm_base";
pub const ZXDG_DECORATION_MANAGER_V1_INTERFACE_NAME = "zxdg_decoration_manager_v1";
pub const ZWP_TEXT_INPUT_MANAGER_V3_INTERFACE_NAME = "zwp_text_input_manager_v3";
pub const WP_VIEWPORTER_INTERFACE_NAME = "wp_viewporter";
pub const WP_CURSOR_SHAPE_MANAGER_V1_INTERFACE_NAME = "wp_cursor_shape_manager_v1";
pub const WP_FRACTIONAL_SCALE_MANAGER_V1_INTERFACE_NAME = "wp_fractional_scale_manager_v1";

// =============================================================================
// wp_viewporter interface (for HiDPI support)
// =============================================================================

// wp_viewporter methods: destroy, get_viewport
const wp_viewporter_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_viewport", .signature = "no", .types = @ptrCast(&wp_viewporter_get_viewport_types) },
};

pub const wp_viewporter_interface: Interface = .{
    .name = "wp_viewporter",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&wp_viewporter_methods),
    .event_count = 0,
    .events = null,
};

// wp_fractional_scale_manager_v1 methods: destroy, get_fractional_scale
const wp_fractional_scale_manager_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{
        .name = "get_fractional_scale",
        .signature = "no",
        .types = @ptrCast(&wp_fractional_scale_manager_v1_get_fractional_scale_types),
    },
};

pub const wp_fractional_scale_manager_v1_interface: Interface = .{
    .name = "wp_fractional_scale_manager_v1",
    .version = 1,
    .method_count = wp_fractional_scale_manager_v1_methods.len,
    .methods = @ptrCast(&wp_fractional_scale_manager_v1_methods),
    .event_count = 0,
    .events = null,
};

// wp_fractional_scale_v1 methods: destroy. Events: preferred_scale, the
// compositor's preferred scale in 120ths (180 is 1.5).
const wp_fractional_scale_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
};

const wp_fractional_scale_v1_events = [_]Message{
    .{ .name = "preferred_scale", .signature = "u", .types = null },
};

pub const wp_fractional_scale_v1_interface: Interface = .{
    .name = "wp_fractional_scale_v1",
    .version = 1,
    .method_count = wp_fractional_scale_v1_methods.len,
    .methods = @ptrCast(&wp_fractional_scale_v1_methods),
    .event_count = wp_fractional_scale_v1_events.len,
    .events = @ptrCast(&wp_fractional_scale_v1_events),
};

// wp_cursor_shape_manager_v1 methods: destroy, get_pointer, get_tablet_tool_v2
const wp_cursor_shape_manager_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_pointer", .signature = "no", .types = @ptrCast(&wp_cursor_shape_manager_v1_get_pointer_types) },
    .{ .name = "get_tablet_tool_v2", .signature = "no", .types = null },
};

pub const wp_cursor_shape_manager_v1_interface: Interface = .{
    .name = "wp_cursor_shape_manager_v1",
    .version = 2,
    .method_count = 3,
    .methods = @ptrCast(&wp_cursor_shape_manager_v1_methods),
    .event_count = 0,
    .events = null,
};

// wp_cursor_shape_device_v1 methods: destroy, set_shape
const wp_cursor_shape_device_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_shape", .signature = "uu", .types = null },
};

pub const wp_cursor_shape_device_v1_interface: Interface = .{
    .name = "wp_cursor_shape_device_v1",
    .version = 2,
    .method_count = 2,
    .methods = @ptrCast(&wp_cursor_shape_device_v1_methods),
    .event_count = 0,
    .events = null,
};

// wp_viewport methods: destroy, set_source, set_destination
const wp_viewport_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_source", .signature = "ffff", .types = null }, // wl_fixed x, y, width, height
    .{ .name = "set_destination", .signature = "ii", .types = null }, // int32 width, height
};

pub const wp_viewport_interface: Interface = .{
    .name = "wp_viewport",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&wp_viewport_methods),
    .event_count = 0,
    .events = null,
};
