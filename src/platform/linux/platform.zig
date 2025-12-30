//! LinuxPlatform - Platform implementation for Linux/Wayland
//!
//! Provides the main event loop and platform lifecycle for Linux systems
//! using Wayland as the display server protocol.

const std = @import("std");
const wayland = @import("wayland.zig");
const interface_mod = @import("../interface.zig");
const LinuxWindow = @import("window.zig").Window;
const linux_input = @import("input.zig");
const input = @import("../../core/input.zig");
const clipboard = @import("clipboard.zig");

// Static listeners - must persist for lifetime of Wayland objects
const registry_listener = wayland.RegistryListener{
    .global = LinuxPlatform.registryGlobal,
    .global_remove = LinuxPlatform.registryGlobalRemove,
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
    running: bool = true,
    display: ?*wayland.Display = null,

    // Global Wayland objects
    registry: ?*wayland.Registry = null,
    compositor: ?*wayland.Compositor = null,
    xdg_wm_base: ?*wayland.XdgWmBase = null,
    decoration_manager: ?*wayland.ZxdgDecorationManagerV1 = null,
    seat: ?*wayland.Seat = null,
    pointer: ?*wayland.Pointer = null,
    keyboard: ?*wayland.Keyboard = null,
    text_input_manager: ?*wayland.ZwpTextInputManagerV3 = null,
    text_input: ?*wayland.ZwpTextInputV3 = null,
    viewporter: ?*wayland.WpViewporter = null,

    // Clipboard state
    clipboard_state: *clipboard.ClipboardState = clipboard.getState(),

    // Input state
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_buttons: u32 = 0,
    last_key_serial: u32 = 0,
    last_pointer_serial: u32 = 0,
    modifier_alt: bool = false,
    modifier_ctrl: bool = false,
    modifier_shift: bool = false,
    modifier_super: bool = false,

    // Active window for interactive operations (move/resize)
    active_window: ?*LinuxWindow = null,

    // Scale factor from output
    scale_factor: i32 = 1,

    // IME state (accumulated during event batch, applied on done)
    ime_preedit_text: ?[]const u8 = null,
    ime_commit_text: ?[]const u8 = null,
    ime_delete_before: u32 = 0,
    ime_delete_after: u32 = 0,
    ime_serial: u32 = 0,

    const Self = @This();

    /// Platform capabilities for Linux/Wayland
    pub const capabilities = interface_mod.PlatformCapabilities{
        .high_dpi = true,
        .multi_window = true,
        .gpu_accelerated = true,
        .display_link = false, // Uses frame callbacks
        .can_close_window = true,
        .glass_effects = false, // Compositor-dependent
        .clipboard = true,
        .file_dialogs = true, // Via XDG Desktop Portal
        .ime = true,
        .custom_cursors = true,
        .window_drag_by_content = false,
        .name = "Linux/Wayland",
        .graphics_backend = "Vulkan",
    };

    /// Initialize platform - connects to Wayland and gets globals.
    /// IMPORTANT: After calling init(), you MUST call setupListeners() on the
    /// final memory location of the platform struct before using it.
    pub fn init() !Self {
        var self = Self{};

        // Connect to Wayland display
        self.display = wayland.wl_display_connect(null) orelse {
            return error.FailedToConnectToDisplay;
        };

        // Get registry - we'll set up the listener in setupListeners()
        self.registry = wayland.wl_display_get_registry(self.display.?) orelse {
            return error.FailedToGetRegistry;
        };

        return self;
    }

    /// Set up Wayland listeners. Must be called after the platform struct is
    /// at its final memory location (not on a temporary stack variable).
    pub fn setupListeners(self: *Self) !void {
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
        // Don't try to destroy Wayland objects if display is gone
        if (self.display == null) {
            self.running = false;
            return;
        }

        // Destroy in reverse order of creation, flushing between major objects
        // Clipboard first (depends on seat and manager)
        self.clipboard_state.deinit();

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
        if (self.keyboard) |kb| {
            wayland.keyboardDestroy(kb);
            self.keyboard = null;
        }
        if (self.pointer) |ptr| {
            wayland.pointerDestroy(ptr);
            self.pointer = null;
        }

        // Flush to ensure destroy requests are sent before destroying seat
        _ = wayland.wl_display_flush(self.display.?);

        if (self.seat) |seat| {
            wayland.seatDestroy(seat);
            self.seat = null;
        }
        if (self.decoration_manager) |dm| {
            wayland.zxdgDecorationManagerV1Destroy(dm);
            self.decoration_manager = null;
        }
        if (self.xdg_wm_base) |wm| {
            wayland.xdgWmBaseDestroy(wm);
            self.xdg_wm_base = null;
        }
        if (self.compositor) |comp| {
            wayland.compositorDestroy(comp);
            self.compositor = null;
        }
        if (self.registry) |reg| {
            wayland.registryDestroy(reg);
            self.registry = null;
        }

        // Final flush before disconnect
        _ = wayland.wl_display_flush(self.display.?);

        // Disconnect last
        wayland.wl_display_disconnect(self.display.?);
        self.display = null;

        self.running = false;
    }

    /// Run the platform event loop (blocking)
    pub fn run(self: *Self) void {
        while (self.running) {
            // Render frame if we have an active window
            if (self.active_window) |window| {
                if (window.isClosed()) {
                    self.running = false;
                    break;
                }
                window.renderFrame();
            }

            // Flush outgoing requests
            _ = wayland.wl_display_flush(self.display.?);

            // Dispatch Wayland events (blocking)
            if (wayland.wl_display_dispatch(self.display.?) < 0) {
                // Connection error
                self.running = false;
                break;
            }
        }
    }

    /// Run a single iteration of the event loop (non-blocking)
    pub fn poll(self: *Self) bool {
        if (!self.running) return false;

        // Flush outgoing requests
        _ = wayland.wl_display_flush(self.display.?);

        // Dispatch pending events
        if (wayland.wl_display_dispatch_pending(self.display.?) < 0) {
            self.running = false;
            return false;
        }

        return self.running;
    }

    /// Block and wait for events, then dispatch them
    /// Returns false if the connection is broken or quit was requested
    pub fn dispatch(self: *Self) bool {
        if (!self.running) return false;

        // This blocks until events are available
        if (wayland.wl_display_dispatch(self.display.?) < 0) {
            self.running = false;
            return false;
        }

        return self.running;
    }

    /// Flush pending requests to the server
    pub fn flush(self: *Self) void {
        if (self.display) |display| {
            _ = wayland.wl_display_flush(display);
        }
    }

    /// Signal the platform to quit
    pub fn quit(self: *Self) void {
        self.running = false;
    }

    /// Set the active window for pointer events (move/resize operations)
    pub fn setActiveWindow(self: *Self, window: *LinuxWindow) void {
        self.active_window = window;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
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

    /// Get the viewporter (for HiDPI support, may be null)
    pub fn getViewporter(self: *Self) ?*wayland.WpViewporter {
        return self.viewporter;
    }

    /// Get current scale factor
    pub fn getScaleFactor(self: *const Self) f64 {
        return @floatFromInt(self.scale_factor);
    }

    /// Get interface for runtime polymorphism
    pub fn interface(self: *Self) interface_mod.PlatformVTable {
        return interface_mod.makePlatformVTable(Self, self);
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
                @min(version, 6),
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.XDG_WM_BASE_INTERFACE_NAME)) {
            self.xdg_wm_base = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.xdg_wm_base_interface,
                @min(version, 6),
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.ZXDG_DECORATION_MANAGER_V1_INTERFACE_NAME)) {
            self.decoration_manager = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.zxdg_decoration_manager_v1_interface,
                @min(version, 1),
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.WL_SEAT_INTERFACE_NAME)) {
            self.seat = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.wl_seat_interface,
                @min(version, 8),
            )));

            if (self.seat) |seat| {
                // Uses module-level static listener
                _ = wayland.seatAddListener(seat, &seat_listener, self);
            }
        } else if (std.mem.eql(u8, interface_name, wayland.ZWP_TEXT_INPUT_MANAGER_V3_INTERFACE_NAME)) {
            self.text_input_manager = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.zwp_text_input_manager_v3_interface,
                @min(version, 1),
            )));

            // Create text input object if we have both manager and seat
            if (self.text_input_manager != null and self.seat != null and self.text_input == null) {
                self.text_input = wayland.zwpTextInputManagerV3GetTextInput(self.text_input_manager.?, self.seat.?);
                if (self.text_input) |ti| {
                    wayland.zwpTextInputV3AddListener(ti, &text_input_listener, self);
                }
            }
        } else if (std.mem.eql(u8, interface_name, wayland.WP_VIEWPORTER_INTERFACE_NAME)) {
            self.viewporter = wayland.bindViewporter(registry, name, version);
        } else if (std.mem.eql(u8, interface_name, clipboard.WL_DATA_DEVICE_MANAGER_INTERFACE_NAME)) {
            self.clipboard_state.bindManager(registry, name, version);
            // Data device setup is deferred to setupListeners() after roundtrips complete
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
        } else if (!caps.pointer and self.pointer != null) {
            wayland.pointerDestroy(self.pointer.?);
            self.pointer = null;
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
        self.pointer_x = wayland.fixedToDouble(surface_x);
        self.pointer_y = wayland.fixedToDouble(surface_y);

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

        const button_bit: u32 = switch (button) {
            wayland.BTN_LEFT => 1,
            wayland.BTN_RIGHT => 2,
            wayland.BTN_MIDDLE => 4,
            else => 0,
        };

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
                const handled = window.handleInput(event);

                // Handle client-side window management when no server decorations
                // Only if the event wasn't handled by the app
                if (!handled and !window.has_server_decorations and button == wayland.BTN_LEFT) {
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

        // Enable text input for IME when keyboard focus enters
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Enable(ti);
            wayland.zwpTextInputV3Commit(ti);
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

        // Disable text input when keyboard focus leaves
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Disable(ti);
            wayland.zwpTextInputV3Commit(ti);
        }
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
        // Close the fd - we're not using xkbcommon yet
        // In a full implementation, we'd mmap this and parse the keymap
        std.posix.close(fd);
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
                    // Alt+F4 to close
                    if (key == linux_input.evdev.KEY_F4 and self.modifier_alt) {
                        std.debug.print("Alt+F4 pressed - closing window\n", .{});
                        self.running = false;
                        return;
                    }

                    // Ctrl+Q to close
                    if (key == linux_input.evdev.KEY_Q and self.modifier_ctrl) {
                        std.debug.print("Ctrl+Q pressed - closing window\n", .{});
                        self.running = false;
                        return;
                    }
                }

                // Generate text_input event for printable characters
                // Skip if Ctrl or Alt/Super are held (those are shortcuts, not text)
                if (!self.modifier_ctrl and !self.modifier_alt and !self.modifier_super) {
                    if (linux_input.evdevKeyToChar(key, self.modifier_shift)) |char| {
                        // Create a single-character string on the stack
                        var char_buf: [1]u8 = .{char};
                        const text_event = linux_input.textInputEvent(&char_buf);
                        _ = window.handleInput(text_event);
                    }
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

        // Store preedit text - will be applied on done event
        if (text) |t| {
            self.ime_preedit_text = std.mem.span(t);
        } else {
            self.ime_preedit_text = null;
        }
    }

    fn textInputCommitString(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        text: ?[*:0]const u8,
    ) callconv(.c) void {
        _ = text_input;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // Store commit text - will be applied on done event
        if (text) |t| {
            self.ime_commit_text = std.mem.span(t);
        } else {
            self.ime_commit_text = null;
        }
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
        if (self.ime_commit_text) |commit_text| {
            window.setInsertedText(commit_text);
            window.clearMarkedText();
            const event = linux_input.textInputEvent(window.inserted_text);
            _ = window.handleInput(event);
            self.ime_commit_text = null;
        }

        // Handle preedit string (composing text)
        if (self.ime_preedit_text) |preedit_text| {
            window.setMarkedText(preedit_text);
            const event = linux_input.compositionEvent(window.marked_text);
            _ = window.handleInput(event);
            self.ime_preedit_text = null;
        } else if (self.ime_commit_text == null) {
            // Empty preedit with no commit means composition cancelled
            if (window.hasMarkedText()) {
                window.clearMarkedText();
                const event = linux_input.compositionEvent("");
                _ = window.handleInput(event);
            }
        }
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

    /// Set content type hints for IME
    pub fn setContentType(self: *Self, hint: wayland.ZwpTextInputV3ContentHint, purpose: wayland.ZwpTextInputV3ContentPurpose) void {
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3SetContentType(ti, hint, purpose);
            wayland.zwpTextInputV3Commit(ti);
        }
    }
};
