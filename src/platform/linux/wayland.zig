//! Wayland C bindings for Linux windowing
//!
//! These bindings wrap libwayland-client and related protocols to provide
//! native Wayland windowing support on Linux.
//!
//! Protocols used:
//! - wayland-client (core protocol)
//! - xdg-shell (window management)
//! - xdg-decoration (server-side decorations)

const std = @import("std");

// =============================================================================
// Basic Types
// =============================================================================

/// Wayland fixed-point number (24.8 format)
pub const Fixed = i32;

pub fn fixedToDouble(f: Fixed) f64 {
    return @as(f64, @floatFromInt(f)) / 256.0;
}

pub fn doubleToFixed(d: f64) Fixed {
    return @intFromFloat(d * 256.0);
}

// =============================================================================
// Opaque Handle Types
// =============================================================================

pub const Display = opaque {};
pub const Registry = opaque {};
pub const Callback = opaque {};
pub const Compositor = opaque {};
pub const Surface = opaque {};
pub const Region = opaque {};
pub const Buffer = opaque {};
pub const ShmPool = opaque {};
pub const Shm = opaque {};
pub const Seat = opaque {};
pub const Pointer = opaque {};
pub const Keyboard = opaque {};
pub const Touch = opaque {};
pub const Output = opaque {};
pub const Subcompositor = opaque {};
pub const Subsurface = opaque {};

// XDG Shell types
pub const XdgWmBase = opaque {};
pub const XdgSurface = opaque {};
pub const XdgToplevel = opaque {};
pub const XdgPopup = opaque {};
pub const XdgPositioner = opaque {};

// XDG Decoration types
pub const ZxdgDecorationManagerV1 = opaque {};
pub const ZxdgToplevelDecorationV1 = opaque {};

// Text Input types (IME support)
pub const ZwpTextInputV3 = opaque {};
pub const ZwpTextInputManagerV3 = opaque {};

// Viewporter types (HiDPI support)
pub const WpViewporter = opaque {};
pub const WpViewport = opaque {};

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

pub const XdgToplevelState = enum(u32) {
    maximized = 1,
    fullscreen = 2,
    resizing = 3,
    activated = 4,
    tiled_left = 5,
    tiled_right = 6,
    tiled_top = 7,
    tiled_bottom = 8,
    suspended = 9,
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

/// Content hint flags for text input
pub const ZwpTextInputV3ContentHint = packed struct(u32) {
    completion: bool = false, // 0x1
    spellcheck: bool = false, // 0x2
    auto_capitalization: bool = false, // 0x4
    lowercase: bool = false, // 0x8
    uppercase: bool = false, // 0x10
    titlecase: bool = false, // 0x20
    hidden_text: bool = false, // 0x40
    sensitive_data: bool = false, // 0x80
    latin: bool = false, // 0x100
    multiline: bool = false, // 0x200
    _padding: u22 = 0,

    pub const none: ZwpTextInputV3ContentHint = .{};
    pub const default: ZwpTextInputV3ContentHint = .{ .completion = true, .spellcheck = true, .auto_capitalization = true };
};

/// Content purpose for text input
pub const ZwpTextInputV3ContentPurpose = enum(u32) {
    normal = 0,
    alpha = 1,
    digits = 2,
    number = 3,
    phone = 4,
    url = 5,
    email = 6,
    name = 7,
    password = 8,
    pin = 9,
    date = 10,
    time = 11,
    datetime = 12,
    terminal = 13,
};

/// Change cause for text input done event
pub const ZwpTextInputV3ChangeCause = enum(u32) {
    input_method = 0,
    other = 1,
};

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
pub extern "wayland-client" fn wl_display_dispatch(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_dispatch_pending(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_roundtrip(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_flush(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_get_fd(display: *Display) c_int;

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
pub extern "wayland-client" var wl_region_interface: Interface;
pub extern "wayland-client" var wl_callback_interface: Interface;
pub extern "wayland-client" var wl_seat_interface: Interface;
pub extern "wayland-client" var wl_pointer_interface: Interface;
pub extern "wayland-client" var wl_keyboard_interface: Interface;
pub extern "wayland-client" var wl_output_interface: Interface;
pub extern "wayland-client" var wl_shm_interface: Interface;

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

// Display operations
pub fn displayConnect(name: ?[*:0]const u8) ?*Display {
    return wl_display_connect(name);
}

pub fn displayDisconnect(display: *Display) void {
    wl_display_disconnect(display);
}

pub fn displayDispatch(display: *Display) c_int {
    return wl_display_dispatch(display);
}

pub fn displayDispatchPending(display: *Display) c_int {
    return wl_display_dispatch_pending(display);
}

pub fn displayRoundtrip(display: *Display) c_int {
    return wl_display_roundtrip(display);
}

pub fn displayFlush(display: *Display) c_int {
    return wl_display_flush(display);
}

pub fn displayGetRegistry(display: *Display) ?*Registry {
    return wl_display_get_registry(display);
}

pub fn displayGetFd(display: *Display) c_int {
    return wl_display_get_fd(display);
}

// Interface accessors (for registryBind)
pub fn getCompositorInterface() *const Interface {
    return &wl_compositor_interface;
}

pub fn getXdgWmBaseInterface() *const Interface {
    return &xdg_wm_base_interface;
}

pub fn getSeatInterface() *const Interface {
    return &wl_seat_interface;
}

pub fn getOutputInterface() *const Interface {
    return &wl_output_interface;
}

pub fn getDecorationManagerInterface() *const Interface {
    return &zxdg_decoration_manager_v1_interface;
}

pub fn getTextInputManagerV3Interface() *const Interface {
    return &zwp_text_input_manager_v3_interface;
}

pub fn getTextInputV3Interface() *const Interface {
    return &zwp_text_input_v3_interface;
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

pub fn compositorCreateRegion(compositor: *Compositor) ?*Region {
    const result = wl_proxy_marshal_flags(
        @ptrCast(compositor),
        1, // WL_COMPOSITOR_CREATE_REGION
        &wl_region_interface,
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
pub fn surfaceAddListener(surface: *Surface, listener: *const SurfaceListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(surface), @ptrCast(listener), data) == 0;
}

pub fn surfaceDestroy(surface: *Surface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        0, // WL_SURFACE_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn surfaceCommit(surface: *Surface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        6, // WL_SURFACE_COMMIT
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
    );
}

pub fn surfaceFrame(surface: *Surface) ?*Callback {
    const result = wl_proxy_marshal_flags(
        @ptrCast(surface),
        3, // WL_SURFACE_FRAME
        &wl_callback_interface,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn surfaceSetOpaqueRegion(surface: *Surface, region: ?*Region) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        5, // WL_SURFACE_SET_OPAQUE_REGION
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        @as(?*anyopaque, @ptrCast(region)),
    );
}

pub fn surfaceSetBufferScale(surface: *Surface, scale: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        6, // WL_SURFACE_SET_BUFFER_SCALE
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        scale,
    );
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

/// Destroy viewporter
pub fn viewporterDestroy(viewporter: *WpViewporter) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(viewporter),
        0, // WP_VIEWPORTER_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(viewporter)),
        0,
    );
    wl_proxy_destroy(@ptrCast(viewporter));
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

/// Set the source rectangle of the viewport (in buffer coordinates, as wl_fixed)
/// Use -1 for all values to use the entire buffer
pub fn viewportSetSource(viewport: *WpViewport, x: Fixed, y: Fixed, width: Fixed, height: Fixed) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(viewport),
        1, // WP_VIEWPORT_SET_SOURCE
        null,
        wl_proxy_get_version(@ptrCast(viewport)),
        0,
        x,
        y,
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

// Callback operations
pub fn callbackAddListener(callback: *Callback, listener: *const CallbackListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(callback), @ptrCast(listener), data) == 0;
}

pub fn callbackDestroy(callback: *Callback) void {
    wl_proxy_destroy(@ptrCast(callback));
}

// Region operations
pub fn regionAdd(region: *Region, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(region),
        1, // WL_REGION_ADD
        null,
        wl_proxy_get_version(@ptrCast(region)),
        0,
        x,
        y,
        width,
        height,
    );
}

pub fn regionDestroy(region: *Region) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(region),
        0, // WL_REGION_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(region)),
        MARSHAL_FLAG_DESTROY,
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

// Keyboard operations
pub fn keyboardAddListener(keyboard: *Keyboard, listener: *const KeyboardListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(keyboard), @ptrCast(listener), data) == 0;
}

pub fn keyboardDestroy(keyboard: *Keyboard) void {
    // Use wl_proxy_destroy directly instead of release request
    // The release request requires wl_seat version 3+ and can cause issues
    wl_proxy_destroy(@ptrCast(keyboard));
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
pub fn xdgToplevelAddListener(toplevel: *XdgToplevel, listener: *const XdgToplevelListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(toplevel), @ptrCast(listener), data) == 0;
}

pub fn xdgToplevelSetTitle(toplevel: *XdgToplevel, title: [*:0]const u8) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        2, // XDG_TOPLEVEL_SET_TITLE
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        title,
    );
}

pub fn xdgToplevelSetAppId(toplevel: *XdgToplevel, app_id: [*:0]const u8) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        3, // XDG_TOPLEVEL_SET_APP_ID
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        app_id,
    );
}

pub fn xdgToplevelSetMinSize(toplevel: *XdgToplevel, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        7, // XDG_TOPLEVEL_SET_MIN_SIZE
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        width,
        height,
    );
}

pub fn xdgToplevelSetMaxSize(toplevel: *XdgToplevel, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        8, // XDG_TOPLEVEL_SET_MAX_SIZE
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
        5, // XDG_TOPLEVEL_MOVE
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
        6, // XDG_TOPLEVEL_RESIZE
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        seat,
        serial,
        @intFromEnum(edges),
    );
}

pub fn xdgToplevelDestroy(toplevel: *XdgToplevel) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        0, // XDG_TOPLEVEL_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        MARSHAL_FLAG_DESTROY,
    );
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
        @intFromEnum(mode),
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

/// Set surrounding text for context
pub fn zwpTextInputV3SetSurroundingText(text_input: *ZwpTextInputV3, text: [*:0]const u8, cursor: i32, anchor: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        3, // set_surrounding_text
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
        text,
        cursor,
        anchor,
    );
}

/// Set text change cause
pub fn zwpTextInputV3SetTextChangeCause(text_input: *ZwpTextInputV3, cause: ZwpTextInputV3ChangeCause) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        4, // set_text_change_cause
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
        @intFromEnum(cause),
    );
}

/// Set content type (hints and purpose)
pub fn zwpTextInputV3SetContentType(text_input: *ZwpTextInputV3, hint: ZwpTextInputV3ContentHint, purpose: ZwpTextInputV3ContentPurpose) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        5, // set_content_type
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
        @as(u32, @bitCast(hint)),
        @intFromEnum(purpose),
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
