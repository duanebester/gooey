//! LinuxPlatform - Platform implementation for Linux/Wayland
//!
//! Provides the main event loop and platform lifecycle for Linux systems
//! using Wayland as the display server protocol.

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland.zig");
const interface_mod = @import("../interface.zig");
const LinuxWindow = @import("window.zig").Window;
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;
const linux_input = @import("input.zig");
const input = @import("../../input/events.zig");
const clipboard = @import("clipboard.zig");

const HIDDEN_FRAME_POLL_MS: i32 = 50;

/// Retries allowed for one `wl_display_flush` before the loop gives up for
/// this iteration. A full write buffer is transient, so the next iteration
/// retries; the bound exists because an unbounded retry is an unbounded
/// stall inside a single frame (CLAUDE.md §4).
const flush_attempts_max: u32 = 8;

fn eventLoopPollTimeout(has_pending_work: bool, waiting_for_frame: bool, refresh_rate_mhz: i32) i32 {
    std.debug.assert(refresh_rate_mhz > 0);
    std.debug.assert(refresh_rate_mhz <= 1_000_000);
    if (waiting_for_frame) return HIDDEN_FRAME_POLL_MS;
    if (has_pending_work) return 0;

    const frame_time_ms = @divFloor(@as(i32, 1_000_000), refresh_rate_mhz);
    return @max(frame_time_ms, 1);
}

/// One window's contribution to the event loop's exit and pacing decision.
///
/// Sampled out of the window rather than read through it, so the fold below
/// stays pure and is exercisable without a compositor connection.
const WindowLoopState = struct {
    /// The window has not recorded a close.
    open: bool,
    /// A redraw, continuous-render mode, or a pending resize is outstanding.
    has_queued_work: bool,
    /// A `wl_callback` is in flight, so the compositor is pacing this window.
    waiting_for_frame: bool,
};

/// Aggregate of `WindowLoopState` over every registered window.
const LoopState = struct {
    open_count: u32,
    has_pending_work: bool,
    all_waiting_for_frame: bool,
};

/// Fold per-window state into the event loop's exit and pacing decision.
///
/// `open_count` counts windows that have not recorded a close, *not* registry
/// entries. A closed window stays registered until its owner reclaims it
/// (`App.drainClosedWindows`), so counting entries would keep the loop alive
/// waiting on a window that will never draw again.
///
/// `all_waiting_for_frame` is an AND, not an OR: one window idling on a
/// `wl_callback` must not stop a sibling with queued work from being serviced
/// this iteration. Only when every open window is paced by the compositor may
/// the loop fall back to the timed wait. With a single window this reduces
/// exactly to the previous `frame_callback != null` test.
fn foldLoopState(windows: []const WindowLoopState) LoopState {
    std.debug.assert(windows.len <= WindowRegistry.MAX_WINDOWS);

    var open_count: u32 = 0;
    var has_pending_work = false;
    var all_waiting_for_frame = true;

    for (windows) |window| {
        if (!window.open) continue;
        open_count += 1;
        if (window.has_queued_work) has_pending_work = true;
        if (!window.waiting_for_frame) all_waiting_for_frame = false;
    }

    std.debug.assert(open_count <= windows.len);
    if (open_count == 0) std.debug.assert(!has_pending_work);

    return .{
        .open_count = open_count,
        .has_pending_work = has_pending_work,
        .all_waiting_for_frame = all_waiting_for_frame,
    };
}

// Static listeners - must persist for lifetime of Wayland objects
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
    /// The blocking `run()` loop is on the stack. Nothing else.
    ///
    /// Backs `isRunning`, whose meaning `platform/contract.zig` pins: false
    /// after `initInPlace`, true from entry to `run`, false once `quit`
    /// returns. Owned exclusively by `run` and `quit`; no other function
    /// writes it.
    running: bool = false,

    /// The compositor connection can still carry traffic.
    ///
    /// Distinct from `running` because a caller may hand-roll its own loop out
    /// of `poll`/`dispatch`/`dispatchWithTimeout` and never call `run` — those
    /// helpers need "is the socket usable", and answering that with `running`
    /// would refuse every dispatch to a caller who legitimately never started
    /// the blocking loop.
    ///
    /// Not expressible as `display != null`: a fatal protocol error kills the
    /// connection while the `wl_display` object is still allocated, and
    /// `deinit` must have that pointer to destroy the proxies and call
    /// `wl_display_disconnect`. Nulling `display` at the error site would leak
    /// the connection, so liveness needs its own bit.
    connection_alive: bool = false,

    display: ?*wayland.Display = null,

    /// Registry for tracking all windows by ID
    window_registry: WindowRegistry,

    /// Allocator for platform resources
    allocator: std.mem.Allocator,

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
    text_input: ?*wayland.ZwpTextInputV3 = null,
    viewporter: ?*wayland.WpViewporter = null,
    cursor_shape_manager: ?*wayland.WpCursorShapeManagerV1 = null,
    cursor_shape_device: ?*wayland.WpCursorShapeDeviceV1 = null,
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

    /// Owner hook fired once per `run` iteration; see `setLoopTurnCallback`.
    loop_turn_callback: ?LoopTurnCallback = null,

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

    /// Get a window by ID.
    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        return self.window_registry.get(id);
    }

    /// Get the active window ID.
    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        return self.window_registry.getActiveWindow();
    }

    /// Set the active window by ID.
    ///
    /// The `WindowId` is the single authority. Wayland pointer, keyboard, and
    /// IME dispatch all need the concrete `*LinuxWindow`, so the pointer is
    /// *derived* here rather than published separately: two setters would let
    /// `getActiveWindowId()` name one window while every event went to another.
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

    /// Get the number of registered windows.
    pub fn windowCount(self: *const Self) u32 {
        return self.window_registry.count();
    }

    /// Callback invoked once per iteration of the `run` loop.
    pub const LoopTurnCallback = *const fn (*Self) void;

    /// Install the per-turn owner hook. `null` clears it.
    ///
    /// Contract-pinned; see the `LoopTurnCallback` note in
    /// `platform/contract.zig` for why the owner needs this point at all.
    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
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
            .allocator = allocator,
        };

        errdefer self.window_registry.deinit();

        self.display = wayland.wl_display_connect(null) orelse {
            return error.FailedToConnectToDisplay;
        };
        self.connection_alive = true;
        errdefer {
            // Disconnecting also reclaims any globals bound during the
            // roundtrips below, so a failed bind needs no separate unwind.
            wayland.wl_display_disconnect(self.display.?);
            self.display = null;
            self.connection_alive = false;
        }

        self.registry = wayland.wl_display_get_registry(self.display.?) orelse {
            return error.FailedToGetRegistry;
        };
        errdefer {
            wayland.registryDestroy(self.registry.?);
            self.registry = null;
        }

        try self.setupListeners();

        std.debug.assert(self.compositor != null);
        std.debug.assert(self.xdg_wm_base != null);
        // The contract requires a freshly initialized platform to report that
        // no host loop has started yet, so `run` is the only thing that can
        // make `isRunning` true.
        std.debug.assert(!self.running);
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
        // Teardown may not run underneath `run`: it frees the registry and the
        // connection the loop is still reading. `run` clears `running` on
        // every exit, so a live flag here means the caller reentered.
        std.debug.assert(!self.running);

        // Clean up window registry
        self.window_registry.deinit();

        // Don't try to destroy Wayland objects if display is gone
        if (self.display == null) {
            self.connection_alive = false;
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
        if (self.cursor_shape_manager) |manager| {
            wayland.cursorShapeManagerDestroy(manager);
            self.cursor_shape_manager = null;
        }
        if (self.xdg_wm_base) |wm| {
            wayland.xdgWmBaseDestroy(wm);
            self.xdg_wm_base = null;
        }
        if (self.output) |output| {
            wayland.outputDestroy(output);
            self.output = null;
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

        self.connection_alive = false;
    }

    /// Run the platform event loop (blocking).
    ///
    /// Uses `poll()` rather than `wl_display_dispatch` so frame callbacks can
    /// drive rendering at vsync rate without blocking on input.
    ///
    /// The loop lives while *any* registered window is open, and services
    /// *every* open window. It used to render, pace, and exit from
    /// `active_window` alone, which meant a non-active window never drew and
    /// closing the active one ended the process.
    ///
    /// `running` is raised *after* the display guard, not before it: with no
    /// connection there is no loop, and a host that samples `isRunning` would
    /// otherwise be told a loop was live for the rest of the process. The
    /// `defer` pairs with the raise so every exit — quit, last window closed,
    /// connection death — leaves `running` false.
    pub fn run(self: *Self) void {
        const display = self.display orelse return;
        const fd = wayland.displayGetFd(display);
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
        std.debug.assert(!self.running);

        self.running = true;
        defer self.running = false;

        var pollfds_buf: [8]posix.pollfd = undefined;

        while (self.running) {
            pollfds_buf[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
            const pollfds = pollfds_buf[0..1];

            // Give the owner its turn first, while no window callback is on
            // the stack: `wl_display_dispatch` below is what runs them, and it
            // has fully unwound by the time control returns here. A window the
            // compositor or titlebar closed during the previous iteration is
            // reclaimed now, which is also what lets the `open_count` test
            // below see the registry shrink instead of counting a corpse.
            //
            // Before the exit test, not after: reclaiming the last window is
            // exactly the case that ends the loop, and the owner may call
            // `quit` from here.
            if (self.loop_turn_callback) |on_turn| on_turn(self);
            if (!self.running) break;

            // With no open window there is no surface to present and no
            // surface for the compositor to send events to, so no further
            // iteration could observe a state change. Stopping here is not a
            // quit policy: `App.checkQuitCondition` still owns that decision,
            // and `quit()` remains the owner's way to stop the loop early.
            if (self.collectLoopState().open_count == 0) break;

            self.renderOpenWindows();

            if (!self.flushDisplay(display, pollfds)) break;

            // Dispatch events already in the queue before deciding how long to
            // wait, so this iteration's pacing sees them.
            if (wayland.wl_display_dispatch_pending(display) < 0) {
                self.connection_alive = false;
                break;
            }

            // Never spin while a frame callback is outstanding. Compositors
            // can withhold callbacks for hidden windows, so use the same 20Hz
            // fallback cadence as other Wayland clients while still waking
            // immediately when a visible surface receives its callback.
            const pacing = self.collectLoopState();
            const timeout_ms = eventLoopPollTimeout(
                pacing.has_pending_work,
                pacing.all_waiting_for_frame,
                self.refresh_rate_mhz,
            );
            // A failed `poll` on the display fd leaves no way to learn when
            // the socket is readable again, so treat it as connection death
            // rather than retrying blind, exactly as a failed dispatch is.
            const poll_result = posix.poll(pollfds, timeout_ms) catch {
                self.connection_alive = false;
                break;
            };

            if (poll_result > 0 and (pollfds[0].revents & posix.POLL.IN) != 0) {
                if (wayland.wl_display_dispatch(display) < 0) {
                    self.connection_alive = false;
                    break;
                }
            }
        }
    }

    /// Sample every registered window and fold the event loop's decision.
    ///
    /// Read-only, so iterating the registry map directly is safe here: nothing
    /// in this pass can run application code and rehash it.
    fn collectLoopState(self: *const Self) LoopState {
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);

        var samples: [WindowRegistry.MAX_WINDOWS]WindowLoopState = undefined;
        var found: u32 = 0;

        var ids = self.window_registry.iterator();
        while (ids.next()) |id| {
            std.debug.assert(found < WindowRegistry.MAX_WINDOWS);
            std.debug.assert(id.isValid());

            const window = self.window_registry.getTyped(LinuxWindow, id.*) orelse continue;
            samples[found] = .{
                .open = !window.isClosed(),
                .has_queued_work = window.needs_redraw or window.continuous_render or
                    window.pending_resize,
                .waiting_for_frame = window.frame_callback != null,
            };
            found += 1;
        }

        std.debug.assert(found <= self.window_registry.count());
        return foldLoopState(samples[0..found]);
    }

    /// Present every open window the compositor is not already pacing.
    ///
    /// Render eagerly only when no compositor callback is pending: a redraw
    /// requested during `frameCallback()` must stay queued until that
    /// newly-scheduled callback fires, otherwise animation frames are
    /// submitted twice per compositor tick.
    ///
    /// The window ids are copied out before any rendering starts. `renderFrame`
    /// runs the application's render callback, which may open or close windows
    /// and so rehash the registry's map; holding a live map iterator across
    /// that would walk freed buckets. Each id is re-resolved immediately before
    /// use, and `Window.deinit` unregisters before it frees, so a window
    /// destroyed earlier in this very pass resolves to null instead of a
    /// dangling pointer.
    fn renderOpenWindows(self: *Self) void {
        var ids: [WindowRegistry.MAX_WINDOWS]WindowId = undefined;
        const found = self.snapshotWindowIds(&ids);
        std.debug.assert(found <= WindowRegistry.MAX_WINDOWS);

        for (ids[0..found]) |id| {
            std.debug.assert(id.isValid());

            const window = self.window_registry.getTyped(LinuxWindow, id) orelse continue;
            if (window.isClosed()) continue;

            // A bufferless surface may not receive its first callback, so
            // bootstrap with one eager presentation. Every later frame is
            // paced by the compositor callback already in flight.
            if (window.frame_callback == null or !window.has_presented_frame) {
                window.renderFrame();
            }
        }
    }

    /// Copy the ids of every registered window into caller storage.
    ///
    /// Returns the number written. Bounded by `MAX_WINDOWS`, which is also the
    /// registry's own hard cap, so the destination can never overflow.
    fn snapshotWindowIds(
        self: *const Self,
        out: *[WindowRegistry.MAX_WINDOWS]WindowId,
    ) u32 {
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);

        var found: u32 = 0;
        var ids = self.window_registry.iterator();
        while (ids.next()) |id| {
            std.debug.assert(found < WindowRegistry.MAX_WINDOWS);
            std.debug.assert(id.isValid());
            out[found] = id.*;
            found += 1;
        }

        std.debug.assert(found == self.window_registry.count());
        return found;
    }

    /// Drain the outgoing request buffer before polling.
    ///
    /// Returns false only when the connection is gone, in which case
    /// `connection_alive` is already cleared and the caller must leave the
    /// loop. A full write
    /// buffer (`EAGAIN`) is waited out up to `flush_attempts_max` times; giving
    /// up after that returns true so the caller completes this iteration and
    /// retries, rather than stalling inside one frame indefinitely.
    fn flushDisplay(self: *Self, display: *wayland.Display, pollfds: []posix.pollfd) bool {
        std.debug.assert(pollfds.len == 1);
        std.debug.assert(pollfds[0].events == posix.POLL.IN);

        var attempts: u32 = 0;
        while (attempts < flush_attempts_max) : (attempts += 1) {
            if (wayland.wl_display_flush(display) >= 0) return true;

            // EAGAIN means the write buffer is full, so wait for writability
            // (EAGAIN == EWOULDBLOCK on Linux). Anything else is fatal.
            const errno_val = std.c._errno().*;
            if (errno_val != @intFromEnum(posix.E.AGAIN)) {
                self.connection_alive = false;
                return false;
            }

            pollfds[0].events = posix.POLL.OUT;
            _ = posix.poll(pollfds, -1) catch {
                pollfds[0].events = posix.POLL.IN;
                return true;
            };
            pollfds[0].events = posix.POLL.IN;
        }

        std.debug.assert(attempts == flush_attempts_max);
        return true;
    }

    /// Run a single iteration of the event loop (non-blocking)
    /// Dispatches any pending events already read from the socket.
    ///
    /// Gated on connection liveness, not on `running`: this is one of the
    /// primitives a caller drives its own loop with instead of calling `run`,
    /// so it must work while `isRunning` is false.
    pub fn poll(self: *Self) bool {
        if (!self.connection_alive) return false;
        const display = self.display orelse return false;

        // Flush outgoing requests
        _ = wayland.wl_display_flush(display);

        // Dispatch pending events (already in the queue)
        if (wayland.wl_display_dispatch_pending(display) < 0) {
            self.connection_alive = false;
            return false;
        }

        return true;
    }

    /// Block and wait for events, then dispatch them.
    ///
    /// Returns false once the connection is gone. Like `poll`, independent of
    /// `running` so a hand-rolled loop can use it without entering `run`.
    pub fn dispatch(self: *Self) bool {
        if (!self.connection_alive) return false;
        const display = self.display orelse return false;

        // This blocks until events are available
        if (wayland.wl_display_dispatch(display) < 0) {
            self.connection_alive = false;
            return false;
        }

        return true;
    }

    /// Wait for events with a timeout, then dispatch them.
    /// This is ideal for continuous rendering - it won't block indefinitely
    /// like dispatch(), allowing frame callbacks to drive rendering at vsync rate.
    /// timeout_ms: -1 = block forever, 0 = non-blocking, >0 = wait up to timeout_ms
    ///
    /// Returns false once the connection is gone. Like `poll`, independent of
    /// `running` so a hand-rolled loop can use it without entering `run`.
    pub fn dispatchWithTimeout(self: *Self, timeout_ms: i32) bool {
        std.debug.assert(timeout_ms >= -1);
        if (!self.connection_alive) return false;
        const display = self.display orelse return false;

        // Flush outgoing requests first
        while (true) {
            const flush_result = wayland.wl_display_flush(display);
            if (flush_result >= 0) break;
            // EAGAIN means write buffer is full (EAGAIN == EWOULDBLOCK on Linux)
            const errno_val = std.c._errno().*;
            if (errno_val == @intFromEnum(posix.E.AGAIN)) {
                // Poll for writability
                var pollfds = [_]posix.pollfd{
                    .{ .fd = wayland.displayGetFd(display), .events = posix.POLL.OUT, .revents = 0 },
                };
                _ = posix.poll(&pollfds, -1) catch {
                    self.connection_alive = false;
                    return false;
                };
            } else {
                self.connection_alive = false;
                return false;
            }
        }

        // Dispatch any already-pending events
        if (wayland.wl_display_dispatch_pending(display) < 0) {
            self.connection_alive = false;
            return false;
        }

        // Poll for new events with timeout
        var pollfds = [_]posix.pollfd{
            .{ .fd = wayland.displayGetFd(display), .events = posix.POLL.IN, .revents = 0 },
        };
        const poll_result = posix.poll(&pollfds, timeout_ms) catch {
            self.connection_alive = false;
            return false;
        };

        // If events arrived, dispatch them
        if (poll_result > 0 and (pollfds[0].revents & posix.POLL.IN) != 0) {
            if (wayland.wl_display_dispatch(display) < 0) {
                self.connection_alive = false;
                return false;
            }
        }

        return true;
    }

    /// Flush pending requests to the server
    pub fn flush(self: *Self) void {
        if (self.display) |display| {
            _ = wayland.wl_display_flush(display);
        }
    }

    /// Signal the platform to quit.
    ///
    /// Stops the `run` loop at its next condition test. It does not touch the
    /// connection: `deinit` owns the disconnect, and a caller driving its own
    /// loop keeps dispatching afterwards.
    pub fn quit(self: *Self) void {
        // `run` only starts with a display, and only `deinit` drops one, so a
        // loop that is still live must have a connection object to stop on.
        if (self.running) std.debug.assert(self.display != null);

        self.running = false;
    }

    /// Whether the blocking `run` loop is currently on the stack.
    ///
    /// See the `isRunning` note in `platform/contract.zig` for the three
    /// transitions this must honour. Not a liveness or usability signal — use
    /// `isConnected` for that.
    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// Whether the compositor connection can still carry traffic.
    ///
    /// What a caller driving its own loop out of `poll`/`dispatch` should test,
    /// since `isRunning` is false for the whole of such a loop by contract.
    pub fn isConnected(self: *const Self) bool {
        if (self.connection_alive) std.debug.assert(self.display != null);

        return self.connection_alive;
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

    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        if (self.cursor_shape_device != null) std.debug.assert(self.pointer != null);
        if (self.cursor_shape_device != null) std.debug.assert(self.cursor_shape_manager != null);
        if (self.cursor_shape == shape) return;
        const serial = self.pointer_enter_serial orelse return;
        const device = self.cursor_shape_device orelse return;

        const protocol_shape: u32 = switch (shape) {
            .default => 1,
            .text => 9,
            .pointer => 4,
        };
        wayland.cursorShapeDeviceSetShape(device, serial, protocol_shape);
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
        } else if (std.mem.eql(u8, interface_name, wayland.WP_CURSOR_SHAPE_MANAGER_V1_INTERFACE_NAME)) {
            self.cursor_shape_manager = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.wp_cursor_shape_manager_v1_interface,
                @min(version, 2),
            )));
            self.ensureCursorShapeDevice();
        } else if (std.mem.eql(u8, interface_name, wayland.WL_OUTPUT_INTERFACE_NAME)) {
            // Bind to first output only (for refresh rate)
            if (self.output == null) {
                self.output = @ptrCast(@alignCast(wayland.registryBind(
                    registry,
                    name,
                    wayland.getOutputInterface(),
                    @min(version, 4),
                )));
                if (self.output) |output| {
                    _ = wayland.outputAddListener(output, &output_listener, self);
                }
            }
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
                // Both shortcuts close the focused window rather than clearing
                // `running`, which is what their messages always claimed and
                // what `Window.close` already does for `xdg_toplevel.close`.
                // Stopping the loop here would resurrect the single-window
                // assumption `run` and `Window.close` were just rid of, and
                // would skip the application's close veto.
                if (!handled) {
                    // Alt+F4 to close
                    if (key == linux_input.evdev.KEY_F4 and self.modifier_alt) {
                        std.debug.print("Alt+F4 pressed - closing window\n", .{});
                        window.close();
                        return;
                    }

                    // Ctrl+Q to close
                    if (key == linux_input.evdev.KEY_Q and self.modifier_ctrl) {
                        std.debug.print("Ctrl+Q pressed - closing window\n", .{});
                        window.close();
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

// A platform in the state `initInPlace` leaves behind, minus the connection.
//
// `initInPlace` itself needs a compositor, so the two transitions reachable
// without one are driven off the field defaults it starts from. The third —
// `running` becoming true on entry to `run` — cannot be reached headlessly at
// all: `run` returns at its display guard without a socket, and blocks on
// `poll` with one. It is held instead by the `defer` that pairs with the raise
// (so no exit path can skip the clear) and by `deinit`'s `assert(!self.running)`
// (so a leak would trip on the next teardown).
fn disconnectedPlatform() LinuxPlatform {
    return .{
        .window_registry = WindowRegistry.init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
}

test "isRunning is false before run and stays false across quit" {
    var plat = disconnectedPlatform();
    defer plat.window_registry.deinit();

    try std.testing.expect(!plat.isRunning());

    // `quit` before `run` is legal and must not invent a loop to stop.
    plat.quit();
    try std.testing.expect(!plat.isRunning());
}

// The bug this change fixes: one `running` flag answered both "the blocking
// loop is live" and "the socket works", so a caller hand-rolling a loop out of
// `dispatch` saw every call refused. Pin the state that used to be
// unrepresentable — connected while not running — since that is what every
// iteration of such a loop looks like.
test "connection liveness is independent of loop state" {
    var plat = disconnectedPlatform();
    defer plat.window_registry.deinit();

    try std.testing.expect(!plat.isConnected());
    // Not connected: the dispatch helpers refuse without touching the socket.
    try std.testing.expect(!plat.poll());
    try std.testing.expect(!plat.dispatch());
    try std.testing.expect(!plat.dispatchWithTimeout(0));

    // Stand in for a live connection. Never dereferenced: both predicates read
    // flags, and the helpers are not called in this state.
    plat.display = @ptrFromInt(@alignOf(usize));
    plat.connection_alive = true;

    try std.testing.expect(plat.isConnected());
    try std.testing.expect(!plat.isRunning());
}

test "event loop waits instead of spinning for compositor frame" {
    try std.testing.expectEqual(@as(i32, HIDDEN_FRAME_POLL_MS), eventLoopPollTimeout(true, true, 240_000));
    try std.testing.expectEqual(@as(i32, 0), eventLoopPollTimeout(true, false, 240_000));
    try std.testing.expectEqual(@as(i32, 4), eventLoopPollTimeout(false, false, 240_000));
}

// A window with nothing queued and no callback in flight, open or not.
fn idleWindowLoopState(open: bool) WindowLoopState {
    return .{ .open = open, .has_queued_work = false, .waiting_for_frame = false };
}

// The loop must survive the loss of a non-last window, which is the whole
// point of the fix: `open_count` is what `run()` tests, so drive it directly
// with the two-window case that used to terminate the process.
test "loop state counts open windows, not registry entries" {
    const open = idleWindowLoopState(true);
    const closed = idleWindowLoopState(false);

    try std.testing.expectEqual(@as(u32, 2), foldLoopState(&.{ open, open }).open_count);

    // One of two windows closed: still registered, but the loop keeps running.
    try std.testing.expectEqual(@as(u32, 1), foldLoopState(&.{ open, closed }).open_count);

    // Both closed and neither reclaimed yet: the loop must still be able to
    // exit, or a closed-but-pending window would keep it alive forever.
    try std.testing.expectEqual(@as(u32, 0), foldLoopState(&.{ closed, closed }).open_count);
    try std.testing.expectEqual(@as(u32, 0), foldLoopState(&.{}).open_count);
}

// A closed window is invisible to pacing. Its `needs_redraw` and pending
// `wl_callback` are stale state that its owner has not reclaimed yet, and
// honouring either would either spin the loop at 0ms or hold it at the
// fallback cadence on behalf of a window that can no longer draw.
test "loop state ignores closed windows when pacing" {
    const closed_busy = WindowLoopState{
        .open = false,
        .has_queued_work = true,
        .waiting_for_frame = true,
    };
    const open_idle = WindowLoopState{
        .open = true,
        .has_queued_work = false,
        .waiting_for_frame = false,
    };

    const state = foldLoopState(&.{ closed_busy, open_idle });
    try std.testing.expectEqual(@as(u32, 1), state.open_count);
    try std.testing.expect(!state.has_pending_work);
    try std.testing.expect(!state.all_waiting_for_frame);
}

// Pacing is an AND across open windows: a sibling idling on a compositor
// callback must not push the timeout to the 20Hz fallback while another
// window has work queued. The single-window rows pin the reduction to the
// pre-existing behaviour.
test "loop state pacing across sibling windows" {
    const waiting = WindowLoopState{
        .open = true,
        .has_queued_work = true,
        .waiting_for_frame = true,
    };
    const ready = WindowLoopState{
        .open = true,
        .has_queued_work = true,
        .waiting_for_frame = false,
    };

    // One window, waiting: unchanged from the single-window behaviour.
    const one_waiting = foldLoopState(&.{waiting});
    try std.testing.expect(one_waiting.all_waiting_for_frame);
    try std.testing.expectEqual(@as(i32, HIDDEN_FRAME_POLL_MS), eventLoopPollTimeout(
        one_waiting.has_pending_work,
        one_waiting.all_waiting_for_frame,
        240_000,
    ));

    // Two windows, one still needing service: no fallback wait.
    const mixed = foldLoopState(&.{ waiting, ready });
    try std.testing.expect(mixed.has_pending_work);
    try std.testing.expect(!mixed.all_waiting_for_frame);
    try std.testing.expectEqual(@as(i32, 0), eventLoopPollTimeout(
        mixed.has_pending_work,
        mixed.all_waiting_for_frame,
        240_000,
    ));

    // Every open window paced by the compositor: fall back to the timed wait.
    const all_waiting = foldLoopState(&.{ waiting, waiting });
    try std.testing.expect(all_waiting.all_waiting_for_frame);
    try std.testing.expectEqual(@as(i32, HIDDEN_FRAME_POLL_MS), eventLoopPollTimeout(
        all_waiting.has_pending_work,
        all_waiting.all_waiting_for_frame,
        240_000,
    ));
}

// Capacity boundary: the fold must accept a full registry exactly, since
// `collectLoopState` sizes its stack sample buffer at `MAX_WINDOWS` and the
// registry refuses to exceed that (CLAUDE.md §24).
test "loop state folds a full registry" {
    var samples: [WindowRegistry.MAX_WINDOWS]WindowLoopState = undefined;
    for (&samples) |*sample| {
        sample.* = .{ .open = true, .has_queued_work = false, .waiting_for_frame = true };
    }

    const full = foldLoopState(&samples);
    try std.testing.expectEqual(WindowRegistry.MAX_WINDOWS, full.open_count);
    try std.testing.expect(full.all_waiting_for_frame);

    // One past the last open window: closing the final entry drops the count
    // without disturbing the rest.
    samples[WindowRegistry.MAX_WINDOWS - 1].open = false;
    const one_closed = foldLoopState(&samples);
    try std.testing.expectEqual(WindowRegistry.MAX_WINDOWS - 1, one_closed.open_count);
}
