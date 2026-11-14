//! LinuxPlatform - Platform implementation for Linux/Wayland
//!
//! Owns the Wayland connection, its globals, and the seat's input devices,
//! and routes their events to the active window. The core host
//! (`core_host.zig`) runs the event loop on this connection.

const std = @import("std");
const wayland = @import("wayland.zig");
const interface_mod = @import("../interface.zig");
const linux_window = @import("window.zig");
const LinuxWindow = linux_window.Window;
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;
const linux_input = @import("input.zig");
const input = @import("../../input/events.zig");
const clipboard = @import("clipboard.zig");
const CursorSurface = @import("cursor_surface.zig").CursorSurface;
const linux_backend = @import("../linux_backend.zig");

// Static listeners - must persist for lifetime of Wayland objects
const fractional_scale_manager_name = wayland.WP_FRACTIONAL_SCALE_MANAGER_V1_INTERFACE_NAME;

/// The highest `wl_compositor` version to bind. `wl_surface` events are demarshaled with
/// the linked libwayland's `wl_surface` table, not the compositor's, so that table caps the
/// compositor too: libwayland 1.21 knows `wl_surface` 5, without `preferred_buffer_scale`.
fn compositorVersionMax() u32 {
    const surface_version = wayland.tableVersion(&wayland.wl_surface_interface);
    const version = @min(wayland.compositor_version_max, surface_version);
    std.debug.assert(version >= 1);
    std.debug.assert(version <= surface_version);
    return version;
}

/// The highest `wl_seat` version to bind, capped by the linked libwayland's tables for the
/// pointer, keyboard, and touch objects the seat creates, for the same reason.
fn seatVersionMax() u32 {
    const version = @min(
        wayland.seat_version_max,
        wayland.tableVersion(&wayland.wl_pointer_interface),
        wayland.tableVersion(&wayland.wl_keyboard_interface),
        wayland.tableVersion(&wayland.wl_touch_interface),
    );
    std.debug.assert(version >= 1);
    std.debug.assert(version <= wayland.seat_version_max);
    return version;
}

const registry_listener = wayland.RegistryListener{
    .global = LinuxPlatform.registryGlobal,
    .global_remove = LinuxPlatform.registryGlobalRemove,
};

const output_listener = wayland.OutputListener{
    .geometry = LinuxPlatform.outputGeometry,
    .mode = LinuxPlatform.outputMode,
    .done = LinuxPlatform.outputDone,
    .scale = LinuxPlatform.outputScale,
    .name = LinuxPlatform.outputName,
    .description = LinuxPlatform.outputDescription,
};

const wm_base_listener = wayland.XdgWmBaseListener{
    .ping = LinuxPlatform.xdgWmBasePing,
};

const seat_listener = wayland.SeatListener{
    .capabilities = LinuxPlatform.seatCapabilities,
    .name = LinuxPlatform.seatName,
};

const pointer_listener = wayland.PointerListener{
    .enter = LinuxPlatform.pointerEnter,
    .leave = LinuxPlatform.pointerLeave,
    .motion = LinuxPlatform.pointerMotion,
    .button = LinuxPlatform.pointerButton,
    .axis = LinuxPlatform.pointerAxis,
    .frame = LinuxPlatform.pointerFrame,
    .axis_source = LinuxPlatform.pointerAxisSource,
    .axis_stop = LinuxPlatform.pointerAxisStop,
    .axis_discrete = LinuxPlatform.pointerAxisDiscrete,
    .axis_value120 = LinuxPlatform.pointerAxisValue120,
    .axis_relative_direction = LinuxPlatform.pointerAxisRelativeDirection,
};

const keyboard_listener = wayland.KeyboardListener{
    .keymap = LinuxPlatform.keyboardKeymap,
    .enter = LinuxPlatform.keyboardEnter,
    .leave = LinuxPlatform.keyboardLeave,
    .key = LinuxPlatform.keyboardKey,
    .modifiers = LinuxPlatform.keyboardModifiers,
    .repeat_info = LinuxPlatform.keyboardRepeatInfo,
};

const touch_listener = wayland.TouchListener{
    .down = LinuxPlatform.touchDown,
    .up = LinuxPlatform.touchUp,
    .motion = LinuxPlatform.touchMotion,
    .frame = LinuxPlatform.touchFrame,
    .cancel = LinuxPlatform.touchCancel,
    .shape = LinuxPlatform.touchShape,
    .orientation = LinuxPlatform.touchOrientation,
};

// Text input V3 listener for IME support
const text_input_listener = wayland.ZwpTextInputV3Listener{
    .enter = LinuxPlatform.textInputEnter,
    .leave = LinuxPlatform.textInputLeave,
    .preedit_string = LinuxPlatform.textInputPreeditString,
    .commit_string = LinuxPlatform.textInputCommitString,
    .delete_surrounding_text = LinuxPlatform.textInputDeleteSurroundingText,
    .done = LinuxPlatform.textInputDone,
};

pub const LinuxPlatform = struct {
    /// Cleared only by `quit`, a 0.3.1 call kept while `context/window.zig`
    /// compiles. The core host's loop ends when the window closes.
    running: bool = false,

    display: ?*wayland.Display = null,

    /// Registry for tracking all windows by ID
    window_registry: WindowRegistry,

    // Global Wayland objects
    registry: ?*wayland.Registry = null,
    compositor: ?*wayland.Compositor = null,
    xdg_wm_base: ?*wayland.XdgWmBase = null,
    decoration_manager: ?*wayland.ZxdgDecorationManagerV1 = null,
    seat: ?*wayland.Seat = null,
    pointer: ?*wayland.Pointer = null,
    keyboard: ?*wayland.Keyboard = null,
    touch: ?*wayland.Touch = null,
    text_input_manager: ?*wayland.ZwpTextInputManagerV3 = null,
    /// Enabled by the core host only while a text field is focused, so keys
    /// typed with no field focused never start a composition nothing receives.
    text_input: ?*wayland.ZwpTextInputV3 = null,
    viewporter: ?*wayland.WpViewporter = null,
    /// Fractional output scales (1.5 rather than the rounded-up 2). Windows use
    /// it only together with `viewporter`; without it they keep integer scales.
    fractional_scale_manager: ?*wayland.WpFractionalScaleManagerV1 = null,
    /// Shared-memory allocator for CPU-rendered frames. Bound on every build
    /// because it is a core global, but only `wayland_cpu` windows use it.
    shm: ?*wayland.Shm = null,
    cursor_shape_manager: ?*wayland.WpCursorShapeManagerV1 = null,
    cursor_shape_device: ?*wayland.WpCursorShapeDeviceV1 = null,
    /// XCursor theme images, loaded at initialization only when the compositor offers no
    /// `wp_cursor_shape_manager_v1`, which stays the preferred path.
    cursor_surface: CursorSurface = .{},
    output: ?*wayland.Output = null,

    // Display refresh rate in millihertz (e.g., 60000 = 60Hz, 144000 = 144Hz)
    // Default to 60Hz (60000 mHz) until we get actual value from wl_output
    refresh_rate_mhz: i32 = 60000,

    // Clipboard state
    clipboard_state: *clipboard.ClipboardState = clipboard.getState(),

    // Input state
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_buttons: u32 = 0,
    last_key_serial: u32 = 0,
    last_pointer_serial: u32 = 0,
    pointer_enter_serial: ?u32 = null,
    cursor_shape: ?interface_mod.CursorShape = null,
    modifier_alt: bool = false,
    modifier_ctrl: bool = false,
    modifier_shift: bool = false,
    modifier_super: bool = false,

    // Active window for input dispatch, frame pacing and interactive
    // move/resize. Derived from `window_registry.active_window` — write it
    // only through `setActiveWindowId` so the two cannot disagree.
    active_window: ?*LinuxWindow = null,

    // Window receiving the current touch gesture sequence
    touch_window: ?*LinuxWindow = null,

    // Scale factor from output
    scale_factor: i32 = 1,

    // IME state (accumulated during event batch, applied on done). The strings
    // are copies: libwayland frees an event's string arguments when its
    // callback returns, and `textInputDone` arrives in a later callback.
    ime_preedit_text: ImeText = .{},
    ime_commit_text: ImeText = .{},
    ime_delete_before: u32 = 0,
    ime_delete_after: u32 = 0,
    ime_serial: u32 = 0,

    const Self = @This();

    // =========================================================================
    // Window Registry
    // =========================================================================

    /// Register a window with the platform and return its ID.
    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        std.debug.assert(@intFromPtr(window) != 0);
        std.debug.assert(self.window_registry.count() < WindowRegistry.MAX_WINDOWS);

        const id = try self.window_registry.register(window);
        std.debug.assert(id.isValid());
        return id;
    }

    /// Unregister a window by ID.
    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        std.debug.assert(id.isValid());
        _ = self.window_registry.unregister(id);
        std.debug.assert(!self.window_registry.contains(id));
    }

    /// Set the active window by ID.
    ///
    /// The `WindowId` is the single authority. Wayland pointer, keyboard, and
    /// IME dispatch all need the concrete `*LinuxWindow`, so the pointer is
    /// *derived* here rather than published separately: two setters would let
    /// the registry's active id name one window while every event went to
    /// another.
    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        self.window_registry.setActiveWindow(id);
        self.active_window = if (id) |window_id|
            self.window_registry.getTyped(LinuxWindow, window_id)
        else
            null;

        // `setActiveWindow` already asserted the id is registered, so the
        // lookup above cannot miss; a null here would mean registry corruption.
        if (id != null) std.debug.assert(self.active_window != null);
        if (id == null) std.debug.assert(self.active_window == null);
    }

    /// Hand the active role to a surviving open window after the current one
    /// closes or dies.
    ///
    /// `active_window` is the routing target for every pointer, keyboard, and
    /// IME event, so leaving it null while other windows remain would strand
    /// input. Closed windows are skipped: they stay registered until their
    /// owner reclaims them, so electing one would route events into a window
    /// that has already declared itself gone. Any open window is a sound
    /// choice: the compositor corrects us with the next `enter` event.
    pub fn reelectActiveWindow(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);

        // The registry is capped at MAX_WINDOWS, so one pass is bounded work.
        var scanned: u32 = 0;
        var chosen: ?WindowId = null;
        var ids = self.window_registry.iterator();
        while (ids.next()) |id| {
            std.debug.assert(scanned < WindowRegistry.MAX_WINDOWS);
            scanned += 1;
            std.debug.assert(id.isValid());

            const window = self.window_registry.getTyped(LinuxWindow, id.*) orelse continue;
            if (window.isClosed()) continue;

            chosen = id.*;
            break;
        }

        self.setActiveWindowId(chosen);
        std.debug.assert(scanned <= self.window_registry.count());
    }

    /// Initialize the platform against its final address.
    ///
    /// This cannot be a by-value `init`: `wl_registry_add_listener` and
    /// `xdg_wm_base_add_listener` retain the `data` pointer for the lifetime
    /// of the proxy, so handing them the address of a temporary would leave
    /// the compositor writing into a dead frame once the value was moved to
    /// its home. Listener setup therefore runs here as the final step instead
    /// of in a second call every caller had to remember to make.
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        std.debug.assert(@intFromPtr(self) != 0);

        self.* = Self{
            .window_registry = WindowRegistry.init(allocator),
        };

        errdefer self.window_registry.deinit();

        self.display = wayland.wl_display_connect(null) orelse {
            return error.FailedToConnectToDisplay;
        };
        errdefer {
            // Disconnecting also reclaims any globals bound during the
            // roundtrips below, so a failed bind needs no separate unwind.
            wayland.wl_display_disconnect(self.display.?);
            self.display = null;
        }

        self.registry = wayland.wl_display_get_registry(self.display.?) orelse {
            return error.FailedToGetRegistry;
        };
        errdefer {
            wayland.registryDestroy(self.registry.?);
            self.registry = null;
        }

        try self.setupListeners();
        self.loadCursorSurface();

        std.debug.assert(self.compositor != null);
        std.debug.assert(self.xdg_wm_base != null);
        std.debug.assert(!self.running);
    }

    /// Load the cursor theme fallback while still initializing: a hover change after the
    /// event loop starts must not allocate. Runs after `setupListeners`, whose second
    /// roundtrip delivered `wl_output.scale`.
    fn loadCursorSurface(self: *Self) void {
        std.debug.assert(self.compositor != null);
        std.debug.assert(self.cursor_surface.surface == null);
        if (self.cursor_shape_manager != null) return;

        const shm = self.shm orelse {
            std.log.warn("cursor: no wl_shm; keeping the compositor's cursor", .{});
            return;
        };
        self.cursor_surface.load(.{
            .compositor = self.compositor.?,
            .shm = shm,
            .output_scale = self.scale_factor,
        });
    }

    /// Bind the Wayland listeners that capture `self`.
    ///
    /// Private because it is only ever correct to run it from `initInPlace`,
    /// where the address is already final.
    fn setupListeners(self: *Self) !void {
        std.debug.assert(self.display != null);
        std.debug.assert(self.registry != null);

        // Set up registry listener with the FINAL pointer location
        _ = wayland.registryAddListener(self.registry.?, &registry_listener, self);

        // Roundtrip to get all globals
        _ = wayland.wl_display_roundtrip(self.display.?);

        // Second roundtrip to process seat capabilities and bind keyboard/pointer
        _ = wayland.wl_display_roundtrip(self.display.?);

        // Verify we have required globals
        if (self.compositor == null) {
            return error.MissingCompositor;
        }
        if (self.xdg_wm_base == null) {
            return error.MissingXdgWmBase;
        }

        // Set up XDG WM base listener for ping/pong with the FINAL pointer
        _ = wayland.xdgWmBaseAddListener(self.xdg_wm_base.?, &wm_base_listener, self);

        // Set up clipboard data device if we have manager and seat
        if (self.clipboard_state.data_device_manager != null and self.seat != null) {
            self.clipboard_state.setupDataDevice(self.seat.?, self.display.?);
        }
    }

    pub fn deinit(self: *Self) void {
        // Clean up window registry
        self.window_registry.deinit();

        // Don't try to destroy Wayland objects if display is gone
        if (self.display == null) return;

        // Destroy in reverse order of creation, flushing between major objects
        // Clipboard first (depends on seat and manager)
        self.clipboard_state.deinit();
        self.destroySeatObjects();

        // Flush to ensure destroy requests are sent before destroying seat
        _ = wayland.wl_display_flush(self.display.?);
        self.destroyGlobals();

        // Final flush before disconnect
        _ = wayland.wl_display_flush(self.display.?);

        // Disconnect last
        wayland.wl_display_disconnect(self.display.?);
        self.display = null;
    }

    /// Destroy the objects created from the seat and its managers, which must
    /// go before the seat itself.
    fn destroySeatObjects(self: *Self) void {
        std.debug.assert(self.display != null);
        // Text input (depends on seat and manager)
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Destroy(ti);
            self.text_input = null;
        }
        if (self.text_input_manager) |tim| {
            wayland.zwpTextInputManagerV3Destroy(tim);
            self.text_input_manager = null;
        }

        // Input devices (they depend on seat)
        if (self.cursor_shape_device) |device| {
            wayland.cursorShapeDeviceDestroy(device);
            self.cursor_shape_device = null;
        }
        if (self.keyboard) |kb| {
            wayland.keyboardDestroy(kb);
            self.keyboard = null;
        }
        if (self.pointer) |ptr| {
            wayland.pointerDestroy(ptr);
            self.pointer = null;
        }
        std.debug.assert(self.pointer == null);
        std.debug.assert(self.keyboard == null);
    }

    /// Destroy the bound globals, the seat first and the registry last.
    fn destroyGlobals(self: *Self) void {
        std.debug.assert(self.display != null);
        std.debug.assert(self.pointer == null);
        if (self.seat) |seat| {
            wayland.seatDestroy(seat);
            self.seat = null;
        }
        if (self.decoration_manager) |dm| {
            wayland.zxdgDecorationManagerV1Destroy(dm);
            self.decoration_manager = null;
        }
        if (self.cursor_shape_manager) |manager| {
            wayland.cursorShapeManagerDestroy(manager);
            self.cursor_shape_manager = null;
        }
        if (self.fractional_scale_manager) |manager| {
            wayland.fractionalScaleManagerDestroy(manager);
            self.fractional_scale_manager = null;
        }
        // Before `shm` and `compositor`, which created its pool and surface.
        self.cursor_surface.deinit();
        if (self.xdg_wm_base) |wm| {
            wayland.xdgWmBaseDestroy(wm);
            self.xdg_wm_base = null;
        }
        if (self.output) |output| {
            wayland.outputDestroy(output);
            self.output = null;
        }
        if (self.shm) |shm| {
            wayland.shmDestroy(shm);
            self.shm = null;
        }
        if (self.compositor) |comp| {
            wayland.compositorDestroy(comp);
            self.compositor = null;
        }
        if (self.registry) |reg| {
            wayland.registryDestroy(reg);
            self.registry = null;
        }
        std.debug.assert(self.compositor == null);
        std.debug.assert(self.registry == null);
    }

    /// Get the Wayland display pointer (for wgpu surface creation)
    pub fn getDisplay(self: *Self) ?*anyopaque {
        return @ptrCast(self.display);
    }

    /// Get the compositor for creating surfaces
    pub fn getCompositor(self: *Self) ?*wayland.Compositor {
        return self.compositor;
    }

    /// Get the XDG WM base for window management
    pub fn getXdgWmBase(self: *Self) ?*wayland.XdgWmBase {
        return self.xdg_wm_base;
    }

    /// Get the decoration manager (may be null if not supported)
    pub fn getDecorationManager(self: *Self) ?*wayland.ZxdgDecorationManagerV1 {
        return self.decoration_manager;
    }

    /// Get the shared-memory allocator used by CPU-rendered windows.
    pub fn getShm(self: *Self) ?*wayland.Shm {
        return self.shm;
    }

    /// Get the viewporter (for HiDPI support, may be null)
    pub fn getViewporter(self: *Self) ?*wayland.WpViewporter {
        return self.viewporter;
    }

    /// Get the fractional scale manager (may be null if not supported)
    pub fn getFractionalScaleManager(self: *Self) ?*wayland.WpFractionalScaleManagerV1 {
        return self.fractional_scale_manager;
    }

    /// Get current scale factor
    pub fn getScaleFactor(self: *const Self) f64 {
        return @floatFromInt(self.scale_factor);
    }

    fn ensureCursorShapeDevice(self: *Self) void {
        if (self.cursor_shape_device != null) std.debug.assert(self.pointer != null);
        if (self.cursor_shape_device != null) std.debug.assert(self.cursor_shape_manager != null);
        if (self.cursor_shape_device != null) return;

        const manager = self.cursor_shape_manager orelse return;
        const pointer = self.pointer orelse return;
        self.cursor_shape_device = wayland.cursorShapeManagerGetPointer(manager, pointer);
        std.debug.assert(self.cursor_shape_manager != null);
        std.debug.assert(self.pointer != null);
    }

    /// Prefer `wp_cursor_shape_v1`; without it, show the theme image on the cursor surface.
    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        if (self.cursor_shape_device != null) std.debug.assert(self.pointer != null);
        if (self.cursor_shape_device != null) std.debug.assert(self.cursor_shape_manager != null);
        if (self.cursor_shape == shape) return;
        const serial = self.pointer_enter_serial orelse return;

        if (self.cursor_shape_device) |device| {
            const protocol_shape: u32 = switch (shape) {
                .default => 1,
                .text => 9,
                .pointer => 4,
                .resize_left_right => 30, // col_resize
                .resize_up_down => 31, // row_resize
            };
            wayland.cursorShapeDeviceSetShape(device, serial, protocol_shape);
        } else {
            const pointer = self.pointer orelse return;
            if (!self.cursor_surface.show(pointer, serial, shape)) return;
        }
        self.cursor_shape = shape;
    }

    // =========================================================================
    // Wayland Callbacks
    // =========================================================================

    fn registryGlobal(
        data: ?*anyopaque,
        registry: *wayland.Registry,
        name: u32,
        iface: [*:0]const u8,
        version: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        const interface_name = std.mem.span(iface);

        // Debug: log all available protocols (uncomment for debugging)
        // std.debug.print("Wayland global: {s} (name={d}, version={d})\n", .{ interface_name, name, version });

        if (std.mem.eql(u8, interface_name, wayland.WL_COMPOSITOR_INTERFACE_NAME)) {
            self.compositor = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.wl_compositor_interface,
                .{ .advertised = version, .supported_max = compositorVersionMax() },
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.XDG_WM_BASE_INTERFACE_NAME)) {
            self.xdg_wm_base = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.xdg_wm_base_interface,
                .{ .advertised = version, .supported_max = 6 },
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.ZXDG_DECORATION_MANAGER_V1_INTERFACE_NAME)) {
            self.decoration_manager = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.zxdg_decoration_manager_v1_interface,
                .{ .advertised = version, .supported_max = 1 },
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.WL_SEAT_INTERFACE_NAME)) {
            self.bindSeat(registry, name, version);
        } else if (std.mem.eql(u8, interface_name, wayland.ZWP_TEXT_INPUT_MANAGER_V3_INTERFACE_NAME)) {
            self.bindTextInputManager(registry, name, version);
        } else if (std.mem.eql(u8, interface_name, wayland.WP_VIEWPORTER_INTERFACE_NAME)) {
            self.viewporter = wayland.bindViewporter(registry, name, version);
        } else if (std.mem.eql(u8, interface_name, fractional_scale_manager_name)) {
            self.fractional_scale_manager = wayland.bindFractionalScaleManager(
                registry,
                name,
                version,
            );
        } else if (std.mem.eql(u8, interface_name, wayland.WL_SHM_INTERFACE_NAME)) {
            self.shm = wayland.bindShm(registry, name, version);
        } else if (std.mem.eql(u8, interface_name, wayland.WP_CURSOR_SHAPE_MANAGER_V1_INTERFACE_NAME)) {
            self.bindCursorShapeManager(registry, name, version);
        } else if (std.mem.eql(u8, interface_name, wayland.WL_OUTPUT_INTERFACE_NAME)) {
            // Bind to first output only (for refresh rate)
            if (self.output == null) self.bindOutput(registry, name, version);
        } else if (std.mem.eql(u8, interface_name, clipboard.WL_DATA_DEVICE_MANAGER_INTERFACE_NAME)) {
            self.clipboard_state.bindManager(registry, name, version);
            // Data device setup is deferred to setupListeners() after roundtrips complete
        }
    }

    /// Bind the seat and listen for its capabilities, which create the pointer,
    /// keyboard, and touch objects.
    fn bindSeat(self: *Self, registry: *wayland.Registry, name: u32, version: u32) void {
        self.seat = @ptrCast(@alignCast(wayland.registryBind(
            registry,
            name,
            &wayland.wl_seat_interface,
            .{ .advertised = version, .supported_max = seatVersionMax() },
        )));

        if (self.seat) |seat| {
            // Uses module-level static listener
            _ = wayland.seatAddListener(seat, &seat_listener, self);
        }
    }

    /// Bind the text input manager and create the seat's text input, which the
    /// core host enables only while a text field is focused.
    fn bindTextInputManager(
        self: *Self,
        registry: *wayland.Registry,
        name: u32,
        version: u32,
    ) void {
        self.text_input_manager = @ptrCast(@alignCast(wayland.registryBind(
            registry,
            name,
            &wayland.zwp_text_input_manager_v3_interface,
            .{ .advertised = version, .supported_max = 1 },
        )));

        // Create text input object if we have both manager and seat
        const manager = self.text_input_manager orelse return;
        const seat = self.seat orelse return;
        if (self.text_input != null) return;
        self.text_input = wayland.zwpTextInputManagerV3GetTextInput(manager, seat);
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3AddListener(ti, &text_input_listener, self);
        }
    }

    /// Bind the cursor shape manager and create the pointer's shape device, if
    /// the pointer already exists.
    fn bindCursorShapeManager(
        self: *Self,
        registry: *wayland.Registry,
        name: u32,
        version: u32,
    ) void {
        self.cursor_shape_manager = @ptrCast(@alignCast(wayland.registryBind(
            registry,
            name,
            &wayland.wp_cursor_shape_manager_v1_interface,
            .{ .advertised = version, .supported_max = 2 },
        )));
        self.ensureCursorShapeDevice();
    }

    /// Bind the first output and listen for its mode and scale.
    fn bindOutput(self: *Self, registry: *wayland.Registry, name: u32, version: u32) void {
        std.debug.assert(self.output == null);
        self.output = @ptrCast(@alignCast(wayland.registryBind(
            registry,
            name,
            wayland.getOutputInterface(),
            .{ .advertised = version, .supported_max = 4 },
        )));
        if (self.output) |output| {
            _ = wayland.outputAddListener(output, &output_listener, self);
        }
    }

    fn registryGlobalRemove(
        data: ?*anyopaque,
        registry: *wayland.Registry,
        name: u32,
    ) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
        // Handle global removal if needed
    }

    // =========================================================================
    // Output Listener Callbacks
    // =========================================================================

    fn outputGeometry(
        data: ?*anyopaque,
        output: *wayland.Output,
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        make: [*:0]const u8,
        model: [*:0]const u8,
        transform: i32,
    ) callconv(.c) void {
        _ = data;
        _ = output;
        _ = x;
        _ = y;
        _ = physical_width;
        _ = physical_height;
        _ = subpixel;
        _ = make;
        _ = model;
        _ = transform;
        // Geometry info is informational, we only care about mode and scale
    }

    fn outputMode(
        data: ?*anyopaque,
        output: *wayland.Output,
        flags: u32,
        width: i32,
        height: i32,
        refresh: i32,
    ) callconv(.c) void {
        _ = output;
        _ = width;
        _ = height;
        const self: *Self = @ptrCast(@alignCast(data));

        // WL_OUTPUT_MODE_CURRENT = 0x1
        const WL_OUTPUT_MODE_CURRENT: u32 = 0x1;
        if ((flags & WL_OUTPUT_MODE_CURRENT) != 0 and refresh > 0) {
            self.refresh_rate_mhz = refresh;
            std.debug.print("Display refresh rate: {}mHz ({d:.1}Hz)\n", .{
                refresh,
                @as(f64, @floatFromInt(refresh)) / 1000.0,
            });
        }
    }

    fn outputScale(
        data: ?*anyopaque,
        output: *wayland.Output,
        factor: i32,
    ) callconv(.c) void {
        _ = output;
        const self: *Self = @ptrCast(@alignCast(data));

        if (factor > 0) {
            self.scale_factor = factor;
        }
    }

    fn outputDone(
        data: ?*anyopaque,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = data;
        _ = output;
        // All output properties have been sent
    }

    fn outputName(
        data: ?*anyopaque,
        output: *wayland.Output,
        name: [*:0]const u8,
    ) callconv(.c) void {
        _ = data;
        _ = output;
        _ = name;
        // Output name is informational
    }

    fn outputDescription(
        data: ?*anyopaque,
        output: *wayland.Output,
        description: [*:0]const u8,
    ) callconv(.c) void {
        _ = data;
        _ = output;
        _ = description;
        // Output description is informational
    }

    fn xdgWmBasePing(
        data: ?*anyopaque,
        xdg_wm_base: *wayland.XdgWmBase,
        serial: u32,
    ) callconv(.c) void {
        _ = data;
        wayland.xdgWmBasePong(xdg_wm_base, serial);
    }

    fn seatName(
        data: ?*anyopaque,
        seat: *wayland.Seat,
        name: [*:0]const u8,
    ) callconv(.c) void {
        _ = data;
        _ = seat;
        _ = name;
        // Seat name is informational, we don't need to do anything with it
    }

    fn seatCapabilities(
        data: ?*anyopaque,
        seat: *wayland.Seat,
        caps: wayland.SeatCapability,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));

        // Handle pointer
        if (caps.pointer and self.pointer == null) {
            self.pointer = wayland.seatGetPointer(seat);
            if (self.pointer) |ptr| {
                // Uses module-level static listener
                _ = wayland.pointerAddListener(ptr, &pointer_listener, self);
            }
            self.ensureCursorShapeDevice();
        } else if (!caps.pointer and self.pointer != null) {
            if (self.cursor_shape_device) |device| {
                wayland.cursorShapeDeviceDestroy(device);
                self.cursor_shape_device = null;
            }
            wayland.pointerDestroy(self.pointer.?);
            self.pointer = null;
            self.pointer_enter_serial = null;
            self.cursor_shape = null;
        }

        // Handle keyboard
        if (caps.keyboard and self.keyboard == null) {
            self.keyboard = wayland.seatGetKeyboard(seat);
            if (self.keyboard) |kb| {
                // Uses module-level static listener
                _ = wayland.keyboardAddListener(kb, &keyboard_listener, self);
            }
        } else if (!caps.keyboard and self.keyboard != null) {
            wayland.keyboardDestroy(self.keyboard.?);
            self.keyboard = null;
        }

        // Handle touch
        if (caps.touch and self.touch == null) {
            std.debug.print("touch: seat advertises touch capability, acquiring device\n", .{});
            self.touch = wayland.seatGetTouch(seat);
            if (self.touch) |t| {
                _ = wayland.touchAddListener(t, &touch_listener, self);
            }
        } else if (!caps.touch and self.touch != null) {
            wayland.touchDestroy(self.touch.?);
            self.touch = null;
        }

        // Create text input if we now have seat and manager
        if (self.text_input_manager != null and self.text_input == null) {
            self.text_input = wayland.zwpTextInputManagerV3GetTextInput(self.text_input_manager.?, seat);
            if (self.text_input) |ti| {
                wayland.zwpTextInputV3AddListener(ti, &text_input_listener, self);
            }
        }
    }

    fn pointerEnter(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        serial: u32,
        surface: *wayland.Surface,
        surface_x: wayland.Fixed,
        surface_y: wayland.Fixed,
    ) callconv(.c) void {
        _ = pointer;
        _ = surface;
        const self: *Self = @ptrCast(@alignCast(data));
        self.last_pointer_serial = serial;
        self.pointer_enter_serial = serial;
        self.pointer_x = wayland.fixedToDouble(surface_x);
        self.pointer_y = wayland.fixedToDouble(surface_y);
        self.cursor_shape = null;
        self.setCursorShape(.default);

        // Dispatch mouse_entered event to active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );
            const event = linux_input.mouseEnteredEvent(self.pointer_x, self.pointer_y, modifiers);
            _ = window.handleInput(event);
        }
    }

    fn pointerLeave(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        serial: u32,
        surface: *wayland.Surface,
    ) callconv(.c) void {
        _ = pointer;
        _ = serial;
        _ = surface;
        const self: *Self = @ptrCast(@alignCast(data));
        self.pointer_enter_serial = null;
        self.cursor_shape = null;
        // A leave with a button held means the compositor broke the implicit
        // grab (a release outside arrives before its leave), so the gesture
        // is gone: cancel it rather than leave a drag waiting for a release.
        self.cancelPointerGesture();

        // Dispatch mouse_exited event to active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );
            const event = linux_input.mouseExitedEvent(self.pointer_x, self.pointer_y, modifiers);
            _ = window.handleInput(event);
        }
    }

    fn pointerMotion(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        time: u32,
        surface_x: wayland.Fixed,
        surface_y: wayland.Fixed,
    ) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));
        self.pointer_x = wayland.fixedToDouble(surface_x);
        self.pointer_y = wayland.fixedToDouble(surface_y);

        // Dispatch mouse_moved or mouse_dragged event to active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );

            const event = if (window.pressed_button) |button|
                linux_input.mouseDraggedEvent(self.pointer_x, self.pointer_y, button, modifiers)
            else
                linux_input.mouseMovedEvent(self.pointer_x, self.pointer_y, modifiers);

            _ = window.handleInput(event);
        }
    }

    fn pointerButton(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        serial: u32,
        time: u32,
        button: u32,
        state: wayland.PointerButtonState,
    ) callconv(.c) void {
        _ = pointer;
        const self: *Self = @ptrCast(@alignCast(data));

        // Save serial for interactive move/resize operations
        self.last_pointer_serial = serial;

        // Update clipboard serial for copy operations
        self.clipboard_state.updateSerial(serial);

        const button_bit = pointerButtonBit(button);

        const modifiers = linux_input.modifiersFromFlags(
            self.modifier_shift,
            self.modifier_ctrl,
            self.modifier_alt,
            self.modifier_super,
        );

        if (state == .pressed) {
            self.pointer_buttons |= button_bit;

            // Dispatch mouse_down event to active window
            if (self.active_window) |window| {
                const handled = self.pointerButtonPressed(window, time, button, modifiers);

                // Handle client-side window management when no server decorations
                // Only if the event wasn't handled by the app
                if (!handled and !window.has_server_decorations and button == wayland.BTN_LEFT) {
                    self.startPointerMoveOrResize(window);
                }
            }
        } else {
            self.pointer_buttons &= ~button_bit;

            // Dispatch mouse_up event to active window
            if (self.active_window) |window| {
                const event = linux_input.mouseUpEvent(
                    self.pointer_x,
                    self.pointer_y,
                    button,
                    modifiers,
                );
                _ = window.handleInput(event);
            }
        }
    }

    /// The `pointer_buttons` bit for an evdev button code; zero for buttons it
    /// does not track.
    fn pointerButtonBit(button: u32) u32 {
        return switch (button) {
            wayland.BTN_LEFT => 1,
            wayland.BTN_RIGHT => 2,
            wayland.BTN_MIDDLE => 4,
            else => 0,
        };
    }

    /// Send a mouse_down, with its click count, to `window`. Returns whether the
    /// app handled it.
    fn pointerButtonPressed(
        self: *Self,
        window: *LinuxWindow,
        time: u32,
        button: u32,
        modifiers: input.Modifiers,
    ) bool {
        std.debug.assert(self.active_window == window);
        // Track click count for double/triple click detection
        const click_count = window.click_tracker.recordClick(
            time,
            self.pointer_x,
            self.pointer_y,
            button,
        );

        const event = linux_input.mouseDownEvent(
            self.pointer_x,
            self.pointer_y,
            button,
            click_count,
            modifiers,
        );
        return window.handleInput(event);
    }

    /// Without server-side decorations, a left press the app did not handle
    /// resizes the window from its edges or moves it from its title bar area.
    fn startPointerMoveOrResize(self: *Self, window: *LinuxWindow) void {
        std.debug.assert(!window.has_server_decorations);
        const border_width: f64 = 8.0;
        const title_bar_height: f64 = 32.0;

        // Check for resize edges first
        if (window.getResizeEdge(self.pointer_x, self.pointer_y, border_width)) |edge| {
            window.startResize(edge);
        } else if (window.isInTitleBar(self.pointer_y, title_bar_height)) {
            // If in title bar area, start move
            window.startMove();
        }
    }

    fn pointerAxis(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        time: u32,
        axis: wayland.PointerAxis,
        value: wayland.Fixed,
    ) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));

        // Convert axis value to delta
        const delta = wayland.fixedToDouble(value);

        // Dispatch scroll event to active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );

            // Wayland sends separate events for horizontal/vertical scroll
            const delta_x: f64 = if (axis == .horizontal_scroll) delta else 0;
            const delta_y: f64 = if (axis == .vertical_scroll) delta else 0;

            const event = linux_input.scrollEvent(
                self.pointer_x,
                self.pointer_y,
                delta_x,
                delta_y,
                modifiers,
            );
            _ = window.handleInput(event);
        }
    }

    fn pointerFrame(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        // Frame event signals end of a group of pointer events
    }

    fn pointerAxisSource(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        axis_source: wayland.PointerAxisSource,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis_source;
    }

    fn pointerAxisStop(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        time: u32,
        axis: wayland.PointerAxis,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
    }

    fn pointerAxisDiscrete(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        axis: wayland.PointerAxis,
        discrete: i32,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = discrete;
    }

    fn pointerAxisValue120(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        axis: wayland.PointerAxis,
        value120: i32,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = value120;
    }

    fn pointerAxisRelativeDirection(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        axis: wayland.PointerAxis,
        direction: wayland.PointerAxisRelativeDirection,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = direction;
    }

    // =========================================================================
    // Touch Callbacks
    // =========================================================================

    fn touchDown(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        serial: u32,
        time: u32,
        surface: *wayland.Surface,
        id: i32,
        x: wayland.Fixed,
        y: wayland.Fixed,
    ) callconv(.c) void {
        _ = touch;
        _ = serial;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));
        const px = wayland.fixedToDouble(x);
        const py = wayland.fixedToDouble(y);
        std.debug.print("touch: down id={d} pos=({d:.1},{d:.1})\n", .{ id, px, py });

        // Find the window owning this surface; fall back to active window.
        var iter = self.window_registry.iterator();
        while (iter.next()) |window_id| {
            const window = self.window_registry.getTyped(LinuxWindow, window_id.*) orelse continue;
            if (window.wl_surface == surface) {
                self.touch_window = window;
                break;
            }
        }
        if (self.touch_window == null) {
            std.debug.print("touch: surface lookup failed, using active_window\n", .{});
            self.touch_window = self.active_window;
        }

        if (self.touch_window) |window| {
            const event = linux_input.touchDownEvent(id, px, py);
            _ = window.handleInput(event);
        } else {
            std.debug.print("touch: no window to dispatch to\n", .{});
        }
    }

    fn touchUp(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        serial: u32,
        time: u32,
        id: i32,
    ) callconv(.c) void {
        _ = touch;
        _ = serial;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));

        if (self.touch_window) |window| {
            // Reuse the last known position for the up event — the protocol
            // does not repeat coordinates on up, only on down and motion.
            const event = linux_input.touchUpEvent(id, 0, 0);
            _ = window.handleInput(event);
        }
    }

    fn touchMotion(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        time: u32,
        id: i32,
        x: wayland.Fixed,
        y: wayland.Fixed,
    ) callconv(.c) void {
        _ = touch;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));

        if (self.touch_window) |window| {
            const event = linux_input.touchMovedEvent(id, wayland.fixedToDouble(x), wayland.fixedToDouble(y));
            _ = window.handleInput(event);
        }
    }

    fn touchFrame(
        data: ?*anyopaque,
        touch: *wayland.Touch,
    ) callconv(.c) void {
        _ = data;
        _ = touch;
        // Frame signals the end of a batch of touch events for the same
        // logical instant. No action needed — events are dispatched immediately.
    }

    fn touchCancel(
        data: ?*anyopaque,
        touch: *wayland.Touch,
    ) callconv(.c) void {
        _ = touch;
        const self: *Self = @ptrCast(@alignCast(data));

        if (self.touch_window) |window| {
            _ = window.handleInput(linux_input.touchCancelledEvent());
        }
        self.touch_window = null;
    }

    fn touchShape(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        id: i32,
        major: wayland.Fixed,
        minor: wayland.Fixed,
    ) callconv(.c) void {
        _ = data;
        _ = touch;
        _ = id;
        _ = major;
        _ = minor;
        // Shape (contact ellipse) is not yet surfaced in the event model.
    }

    fn touchOrientation(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        id: i32,
        orientation: wayland.Fixed,
    ) callconv(.c) void {
        _ = data;
        _ = touch;
        _ = id;
        _ = orientation;
        // Orientation (contact angle) is not yet surfaced in the event model.
    }

    fn keyboardEnter(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        _: u32,
        surface: *wayland.Surface,
        keys: *anyopaque,
    ) callconv(.c) void {
        _ = keyboard;
        _ = surface;
        _ = keys;
        const self: *Self = @ptrCast(@alignCast(data));

        // Reset key repeat tracker on focus gain
        if (self.active_window) |window| {
            window.key_repeat_tracker.reset();
        }
    }

    fn keyboardLeave(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        _: u32,
        surface: *wayland.Surface,
    ) callconv(.c) void {
        _ = keyboard;
        _ = surface;
        const self: *Self = @ptrCast(@alignCast(data));

        // Reset key repeat tracker and click tracker on focus loss
        if (self.active_window) |window| {
            window.key_repeat_tracker.reset();
            window.click_tracker.reset();
        }
        // Another window took the keyboard mid-drag, as Alt+Tab does; its
        // release may never reach this surface.
        self.cancelPointerGesture();
    }

    /// Forget held buttons and send `pointer_cancelled` when any was held,
    /// so a drag cancels instead of dropping where the pointer last was.
    fn cancelPointerGesture(self: *Self) void {
        if (self.pointer_buttons == 0) return;
        self.pointer_buttons = 0;
        std.debug.assert(self.pointer_buttons == 0);
        const window = self.active_window orelse return;
        _ = window.handleInput(.pointer_cancelled);
        std.debug.assert(window.pressed_button == null);
    }

    fn keyboardKeymap(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        _: wayland.KeyboardKeymapFormat,
        fd: i32,
        _: u32,
    ) callconv(.c) void {
        _ = data;
        _ = keyboard;
        // Close the fd - we're not using xkbcommon yet.
        // In a full implementation, we'd mmap this and parse the keymap.
        // std.posix.close was removed in Zig 0.16 ("posix and os.windows
        // removals" in the release notes); libc is linked on Linux so we
        // call the libc symbol directly.
        _ = std.c.close(fd);
        // Keymap received - in a full implementation we'd parse this with xkbcommon
    }

    fn keyboardRepeatInfo(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        _: i32,
        _: i32,
    ) callconv(.c) void {
        _ = data;
        _ = keyboard;
        // Repeat info received - could be used for key repeat handling
    }

    fn keyboardKey(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        serial: u32,
        time: u32,
        key: u32,
        state: wayland.KeyState,
    ) callconv(.c) void {
        _ = keyboard;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));
        self.last_key_serial = serial;

        // Update clipboard serial for copy operations
        self.clipboard_state.updateSerial(serial);

        const modifiers = linux_input.modifiersFromFlags(
            self.modifier_shift,
            self.modifier_ctrl,
            self.modifier_alt,
            self.modifier_super,
        );

        if (state == .pressed) {
            // Check if this is a repeat
            var is_repeat = false;
            if (self.active_window) |window| {
                is_repeat = window.key_repeat_tracker.checkAndPress(key);
            }

            // Dispatch key_down event to active window
            if (self.active_window) |window| {
                const event = linux_input.keyDownEvent(key, modifiers, is_repeat);
                const handled = window.handleInput(event);

                // Handle built-in shortcuts only if not handled by app
                if (!handled) {
                    if (self.closeOnShortcut(window, key)) return;
                }

                // Generate text_input event for printable characters
                // Skip if Ctrl or Alt/Super are held (those are shortcuts, not text)
                if (!self.modifier_ctrl and !self.modifier_alt and !self.modifier_super) {
                    self.sendKeyText(window, key);
                }
            }
        } else {
            // Key released
            if (self.active_window) |window| {
                window.key_repeat_tracker.release(key);

                const event = linux_input.keyUpEvent(key, modifiers);
                _ = window.handleInput(event);
            }
        }
    }

    /// Close `window` for Alt+F4 or Ctrl+Q, and return whether it did. Both
    /// shortcuts close the focused window rather than clearing `running`,
    /// matching their messages and what `Window.close` does for
    /// `xdg_toplevel.close`. Stopping the loop here would reintroduce a
    /// single-window assumption that `run` and `Window.close` avoid, and would
    /// skip the application's close veto.
    fn closeOnShortcut(self: *Self, window: *LinuxWindow, key: u32) bool {
        std.debug.assert(self.active_window == window);
        // Alt+F4 to close
        if (key == linux_input.evdev.KEY_F4 and self.modifier_alt) {
            std.debug.print("Alt+F4 pressed - closing window\n", .{});
            window.close();
            return true;
        }

        // Ctrl+Q to close
        if (key == linux_input.evdev.KEY_Q and self.modifier_ctrl) {
            std.debug.print("Ctrl+Q pressed - closing window\n", .{});
            window.close();
            return true;
        }
        return false;
    }

    /// Send the character `key` types with the current Shift state as a
    /// text_input event, if it types one.
    fn sendKeyText(self: *Self, window: *LinuxWindow, key: u32) void {
        std.debug.assert(!self.modifier_ctrl);
        std.debug.assert(!self.modifier_alt);
        if (linux_input.evdevKeyToChar(key, self.modifier_shift)) |char| {
            // Create a single-character string on the stack
            var char_buf: [1]u8 = .{char};
            const text_event = linux_input.textInputEvent(&char_buf);
            _ = window.handleInput(text_event);
        }
    }

    fn keyboardModifiers(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        serial: u32,
        mods_depressed: u32,
        mods_latched: u32,
        mods_locked: u32,
        group: u32,
    ) callconv(.c) void {
        _ = keyboard;
        _ = serial;
        _ = mods_latched;
        _ = mods_locked;
        _ = group;
        const self: *Self = @ptrCast(@alignCast(data));

        // Update modifier state using XKB masks
        self.modifier_shift = (mods_depressed & linux_input.xkb_mod.SHIFT) != 0;
        self.modifier_ctrl = (mods_depressed & linux_input.xkb_mod.CTRL) != 0;
        self.modifier_alt = (mods_depressed & linux_input.xkb_mod.ALT) != 0;
        self.modifier_super = (mods_depressed & linux_input.xkb_mod.SUPER) != 0;

        // Dispatch modifiers_changed event to active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );
            const event = linux_input.modifiersChangedEvent(modifiers);
            _ = window.handleInput(event);
        }
    }

    // =========================================================================
    // Text Input V3 Callbacks (IME Support)
    // =========================================================================

    fn textInputEnter(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        surface: *wayland.Surface,
    ) callconv(.c) void {
        _ = text_input;
        _ = surface;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // Text input is now active for this surface
        if (self.active_window) |window| {
            window.ime_active = true;
        }
    }

    fn textInputLeave(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        surface: *wayland.Surface,
    ) callconv(.c) void {
        _ = text_input;
        _ = surface;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // Text input is no longer active
        if (self.active_window) |window| {
            window.ime_active = false;
            window.clearMarkedText();
        }
    }

    fn textInputPreeditString(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        text: ?[*:0]const u8,
        cursor_begin: i32,
        cursor_end: i32,
    ) callconv(.c) void {
        _ = text_input;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        _ = cursor_begin;
        _ = cursor_end;

        // Copied now, applied on the done event.
        self.ime_preedit_text.set(text);
    }

    fn textInputCommitString(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        text: ?[*:0]const u8,
    ) callconv(.c) void {
        _ = text_input;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // Copied now, applied on the done event.
        self.ime_commit_text.set(text);
    }

    fn textInputDeleteSurroundingText(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        before_length: u32,
        after_length: u32,
    ) callconv(.c) void {
        _ = text_input;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // Store delete info - will be applied on done event
        self.ime_delete_before = before_length;
        self.ime_delete_after = after_length;
    }

    fn textInputDone(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        serial: u32,
    ) callconv(.c) void {
        _ = text_input;
        _ = serial;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        const window = self.active_window orelse return;

        // Apply accumulated IME state
        // First handle any delete_surrounding_text
        if (self.ime_delete_before > 0 or self.ime_delete_after > 0) {
            // TODO: Implement delete surrounding text support
            // For now, we just track that it was requested
            self.ime_delete_before = 0;
            self.ime_delete_after = 0;
        }

        // Handle commit string (final text)
        if (self.ime_commit_text.get()) |commit_text| {
            // Whole, up to the protocol's bound: the core queue copies it,
            // cutting it at a codepoint boundary past its text budget.
            window.clearMarkedText();
            const event = linux_input.textInputEvent(commit_text);
            _ = window.handleInput(event);
            self.ime_commit_text.clear();
        }

        // Handle preedit string (composing text)
        if (self.ime_preedit_text.get()) |preedit_text| {
            window.setMarkedText(preedit_text);
            const event = linux_input.compositionEvent(window.marked_text);
            _ = window.handleInput(event);
            self.ime_preedit_text.clear();
        } else if (self.ime_commit_text.get() == null) {
            // Empty preedit with no commit means composition cancelled
            if (window.hasMarkedText()) {
                window.clearMarkedText();
                const event = linux_input.compositionEvent("");
                _ = window.handleInput(event);
            }
        }
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while that file
    // compiles, and go when phase 6 deletes it.

    pub fn quit(self: *Self) void {
        self.running = false;
        std.debug.assert(!self.running);
    }

    /// The core's renderer is its host's, so there is nothing to lock here.
    pub fn lockRenderThreads(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
    }

    // =========================================================================
    // Public IME Control Functions
    // =========================================================================

    /// Enable text input for the active window
    pub fn enableTextInput(self: *Self) void {
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Enable(ti);
            wayland.zwpTextInputV3Commit(ti);
        }
    }

    /// Disable text input
    pub fn disableTextInput(self: *Self) void {
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Disable(ti);
            wayland.zwpTextInputV3Commit(ti);
        }
    }

    /// Set IME cursor rectangle for candidate window positioning
    pub fn setImeCursorRect(self: *Self, x: i32, y: i32, width: i32, height: i32) void {
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3SetCursorRectangle(ti, x, y, width, height);
            wayland.zwpTextInputV3Commit(ti);
        }
    }
};

/// One text-input-v3 string, copied out of libwayland's argument buffer.
/// Bounded by the Wayland message size, which text-input-v3 states as 4000
/// bytes of text, so a commit arrives whole; a longer string is still
/// external input, not a programmer error, so it is cut at the last
/// codepoint boundary that fits (a warning is logged) rather than failing.
const ImeText = struct {
    bytes: [bytes_max]u8 = undefined,
    len: u16 = 0,
    present: bool = false,

    const bytes_max = 4000;

    comptime {
        std.debug.assert(bytes_max <= std.math.maxInt(u16));
        std.debug.assert(bytes_max >= LinuxWindow.marked_text_bytes_max);
    }

    fn set(self: *ImeText, text: ?[*:0]const u8) void {
        const source = std.mem.span(text orelse {
            self.clear();
            return;
        });
        const len = codepointPrefixLen(source, bytes_max);
        if (len < source.len) {
            std.log.warn("IME string of {d} bytes cut to {d} (buffer {d})", .{
                source.len,
                len,
                bytes_max,
            });
        }
        @memcpy(self.bytes[0..len], source[0..len]);
        self.len = @intCast(len);
        self.present = true;
        std.debug.assert(self.len <= bytes_max);
    }

    fn get(self: *const ImeText) ?[]const u8 {
        if (!self.present) return null;
        std.debug.assert(self.len <= bytes_max);
        return self.bytes[0..self.len];
    }

    fn clear(self: *ImeText) void {
        self.len = 0;
        self.present = false;
    }
};

/// The longest prefix of `text` within `len_max` bytes that ends on a UTF-8
/// codepoint boundary: a cut never splits a multi-byte sequence.
fn codepointPrefixLen(text: []const u8, len_max: usize) usize {
    if (text.len <= len_max) return text.len;
    var len = len_max;
    // A continuation byte (0b10xxxxxx) at `len` means the cut splits a
    // sequence; a sequence is at most 4 bytes, so at most 3 steps back. The
    // bound also holds for invalid input, which the IME, not Gooey, produced.
    var steps: u8 = 0;
    while (steps < 3 and len > 0 and (text[len] & 0xC0) == 0x80) : (steps += 1) {
        len -= 1;
    }
    std.debug.assert(len <= len_max);
    return len;
}

test "IME strings survive libwayland freeing the event's argument buffer" {
    // Goal: Bug B. libwayland frees a text-input-v3 event's strings when its
    // callback returns, and `textInputDone` reads them in a later callback.
    // Methodology: store a string, overwrite the source the way a freed and
    // reused buffer would be, and check the stored copy is unchanged.
    var source = "nihongo".*;
    var text: ImeText = .{};
    text.set(@ptrCast(&source));
    @memset(source[0 .. source.len - 1], 0xA5);
    try std.testing.expectEqualStrings("nihongo", text.get().?);
    text.set(null);
    try std.testing.expectEqual(@as(?[]const u8, null), text.get());
}

test "an IME string past the buffer is cut on a codepoint boundary" {
    // Goal: the bound never splits a UTF-8 sequence. Methodology: fill to one
    // byte before the limit with ASCII, then a 3-byte "か" that crosses it:
    // the cut must drop the whole sequence. At exactly the limit nothing is
    // cut, and a 2-byte limit inside a 3-byte sequence cuts to zero.
    const limit = ImeText.bytes_max;
    var long: [limit + 3:0]u8 = undefined;
    @memset(long[0 .. limit - 1], 'a');
    @memcpy(long[limit - 1 ..][0..3], "か");
    long[limit + 2] = 0;
    var text: ImeText = .{};
    text.set(&long);
    try std.testing.expectEqual(@as(usize, limit - 1), text.get().?.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text.get().?));
    try std.testing.expectEqual(@as(usize, limit), codepointPrefixLen(long[0..limit], limit));
    try std.testing.expectEqual(@as(usize, 0), codepointPrefixLen("か", 2));
}
