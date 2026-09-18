//! Runner
//!
//! Platform initialization, window creation, and event loop management.
//! This is the main entry point for running a gooey application.
//!
//! Window lifecycle callbacks:
//! - `on_close`: called when window is about to close; return false to prevent.
//! - `on_resize`: called when window size changes (after resize completes).
//!
//! Each window owns a per-window `WindowContext` stored in the window's
//! user_data pointer (Cx, Window, Builder, callbacks), so the single-window
//! flow and multi-window flow share one callback model.
//!
//! Backend-specific initialization order is the backend's business: each
//! `Platform.initInPlace` completes its own host wiring. That replaced a
//! by-value `Platform.init()` plus a Linux-only `plat.setupListeners()`
//! follow-up call in `runCx` — Wayland registry listeners retain `&self`, so
//! they could only be armed once the value had reached its final address, and
//! shared runtime code should not encode which protocol needs a second phase.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

// Platform abstraction
const platform = @import("../platform/mod.zig");
const interface_mod = @import("../platform/interface.zig");

// Core imports
const geometry_mod = @import("../core/geometry.zig");
const input_mod = @import("../input/mod.zig");
const handler_mod = @import("../context/handler.zig");
const cx_mod = @import("../cx.zig");
const window_mod = @import("../context/window.zig");
const FontConfig = window_mod.FontConfig;

// `App` owns application-lifetime state shared across windows (the entity
// map, keymap, image loader). The single-window flow heap-allocates one
// `App` in `runCx` and hands `*App` to the `WindowContext`; routing through
// `App` even with one borrower is the precondition for cross-window
// observation.
const app_mod = @import("../context/app.zig");
const App = app_mod.App;

// Runtime imports
const window_context = @import("window_context.zig");

const Platform = platform.Platform;
// `PlatformWindow` is the OS-level handle; the `Window` name is reserved for
// the framework-level wrapper (see `src/platform/mod.zig`).
const PlatformWindow = platform.PlatformWindow;
const Cx = cx_mod.Cx;
const InputEvent = input_mod.InputEvent;

/// Run a gooey application with the Cx context API.
///
/// Initializes the platform, creates a window, sets up the rendering context,
/// and runs the main event loop. Each window gets its own `WindowContext`
/// stored in user_data.
///
/// `init` is the Zig 0.16 `std.process.Init` value threaded through from
/// `pub fn main(init: std.process.Init)`; it supplies the allocator (`init.gpa`)
/// and the runtime-selected `Io` (`init.io`). It is last because the preceding
/// parameters are all comptime-known.
pub fn runCx(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    config: CxConfig(State),
    init: std.process.Init,
) !void {
    // `init.gpa` is the runtime-supplied allocator (leak-checking in Debug).
    // It outlives `main`, so it outlives this function's stack frame.
    const allocator = init.gpa;

    // Whether this frame still owns what it acquires below. Every teardown
    // `defer` is guarded by it rather than running unconditionally, because an
    // early `return` still runs every registered `defer`: a handoff to the
    // host cannot be expressed by returning. It stays true for the whole of
    // setup, so both drive models unwind fully on the error paths.
    var owned = true;

    // Initialize the platform in place. `plat` lives in this frame, which
    // outlives the event loop, so the address native listeners capture during
    // initialization stays valid.
    var plat: Platform = undefined;
    try plat.initInPlace(allocator);
    defer if (owned) plat.deinit();

    const window_options = windowOptions(State, config);

    // Create window. `PlatformWindow.init` registers itself with the platform
    // and, where the host requires it, routes input to itself — so there is no
    // longer a Linux-only `plat.setActiveWindow(window)` call here.
    var window = try PlatformWindow.init(allocator, &plat, &window_options);
    defer if (owned) window.deinit();

    // Resolve IO: caller-provided instance, else the runtime-selected `init.io`.
    const io = config.io orelse init.io;

    // Defers are ordered so the `App` outlives the `Window`: any cancel-group
    // teardown driven by window close still has a live `EntityMap` to walk.
    const app_ptr = try allocator.create(App);
    defer if (owned) allocator.destroy(app_ptr);
    // `initInPlace` may fail with `OutOfMemory` (it registers an owned
    // `Keymap`); the `destroy` defer above still runs on that error path.
    try app_ptr.initInPlace(allocator, io);
    defer if (owned) app_ptr.deinit();

    // Create per-window context (replaces static CallbackState)
    const WinCtx = window_context.WindowContext(State);
    const win_ctx = try WinCtx.init(allocator, window, state, render, .{
        .font_name = config.font,
        .font_size = config.font_size,
    }, app_ptr, io);
    defer if (owned) win_ctx.deinit();

    win_ctx.setCallbacks(config.on_event, config.on_close, config.on_resize);

    // Set root state on this window's Window instance (not globally)
    // This enables multi-window support where each window has its own state
    win_ctx.window.setRootState(State, state);
    defer if (owned) win_ctx.window.clearRootState();

    // Connect WindowContext to window (sets user_data and callbacks)
    win_ctx.setupWindow(window);

    // Call user init callback if provided (after full setup, before first frame)
    if (config.on_init) |init_fn| {
        init_fn(win_ctx.getCx());
    }

    // Run the event loop, then re-decide ownership of what `run` left behind.
    plat.run();
    owned = ownsTeardownAfterRun(platform.drive_model, plat.isRunning());

    // After a handoff the host calls back through the window it still holds, so
    // that window must still be registered — otherwise nothing can reach this
    // state again and suppressing teardown leaks it instead of handing it over.
    if (!owned) assert(plat.windowCount() >= 1);
}

/// Whether `runCx`'s frame still owns teardown now that `plat.run()` returned.
///
/// This is `platform.drive_model`'s runtime consumer. The model is taken as a
/// parameter rather than read from `platform.drive_model` here so that both
/// prongs are analyzed on every target: with a comptime-known operand Zig drops
/// the untaken prong, and every target that instantiates `runCx` today is
/// `blocking_event_loop`. `host_running` is `plat.isRunning()` from the caller.
///
/// What the `host_callback` result guarantees: the heap state `runCx` built
/// (`App`, `WindowContext`, `PlatformWindow`) is left live for the host's next
/// callback instead of being freed underneath it. What it does not guarantee:
/// that `&plat` survives, because `plat` is a local of `runCx`'s frame. A
/// host-driven backend therefore still must not enter `runCx` — web goes
/// through `WebApp` in `src/app.zig` — and closing that hole needs platform
/// ownership hoisted above this function (see `docs/platform_interface_design.md`,
/// "Known gaps").
fn ownsTeardownAfterRun(model: platform.DriveModel, host_running: bool) bool {
    return switch (model) {
        // `run` returned because the host loop stopped, so nothing can call
        // back into this frame's state: tearing it down here is correct, and
        // the `defer`s already registered do it in the right order.
        //
        // A blocking backend must report a stopped loop by the time `run`
        // returns. This was previously left unasserted because Linux kept
        // `running` true when `run` early-returned on a null display; Linux now
        // raises the flag only after that guard and clears it with a `defer`,
        // so every backend agrees and the postcondition is checkable.
        .blocking_event_loop => blk: {
            assert(!host_running);
            break :blk true;
        },

        // `run` armed a host callback and returned with the host still holding
        // `&plat` and the window's `user_data`. Freeing now would pull live
        // state out from under the next callback, so ownership passes to the
        // host and every guarded `defer` above becomes a no-op.
        .host_callback => blk: {
            // The host only keeps calling back while the loop is live, so a
            // dead loop means there is no owner to hand anything to and
            // suppressing teardown would be a plain leak.
            assert(host_running);
            break :blk false;
        },
    };
}

/// Translate `CxConfig` into the platform-agnostic `WindowOptions` the boundary
/// takes. Pure computation, pushed out of `runCx` so the parent holds only
/// control flow and resource ownership.
///
/// The result is named at the call site rather than passed as a literal because
/// the boundary takes `*const WindowOptions`; the struct is far over the
/// 16-byte by-value threshold, so the caller needs an addressable local.
fn windowOptions(comptime State: type, config: CxConfig(State)) interface_mod.WindowOptions {
    // A zero-extent window is a caller bug, not an operating error: every
    // backend derives swapchain and surface extents from these.
    assert(config.width > 0);
    assert(config.height > 0);

    const bg_color = config.background_color orelse
        geometry_mod.Color.rgba(0.95, 0.95, 0.95, 1.0);

    return .{
        .title = config.title,
        .width = config.width,
        .height = config.height,
        .background_color = bg_color,
        .custom_shaders = config.custom_shaders,
        // Size constraints
        .min_size = config.min_size,
        .max_size = config.max_size,
        .centered = config.centered,
        // Glass/transparency options. `glass_style` is passed straight through:
        // there is now one canonical `GlassStyle` shared by every backend, so
        // the previous `@enumFromInt(@intFromEnum(...))` bridge between two
        // differently ordered enums is gone.
        .background_opacity = config.background_opacity,
        .glass_style = config.glass_style,
        .glass_corner_radius = config.glass_corner_radius,
        .titlebar_transparent = config.titlebar_transparent,
        .full_size_content = config.full_size_content,
    };
}

/// Configuration for runCx()
pub fn CxConfig(comptime State: type) type {
    _ = State; // State type captured for type safety
    const shader_mod = @import("../core/shader.zig");

    return struct {
        title: []const u8 = "Window App",
        width: f64 = 800,
        height: f64 = 600,
        background_color: ?geometry_mod.Color = null,

        // Window size constraints

        /// Minimum window size (optional)
        min_size: ?geometry_mod.Size(f64) = null,

        /// Maximum window size (optional)
        max_size: ?geometry_mod.Size(f64) = null,

        /// Start window centered on screen
        centered: bool = true,

        // Event callbacks

        /// Called once after platform, window, and Window context are initialized,
        /// before the first render. Use for one-time setup (HTTP clients, API keys, etc.)
        on_init: ?*const fn (*Cx) void = null,

        /// Optional event handler for raw input events
        on_event: ?*const fn (*Cx, InputEvent) bool = null,

        /// Called when window is about to close. Return false to prevent close.
        on_close: ?*const fn (*Cx) bool = null,

        /// Called when window size changes (width, height in logical pixels)
        on_resize: ?*const fn (*Cx, f64, f64) void = null,

        /// Font family name (e.g., "Inter", "JetBrains Mono").
        /// When null, uses the platform's default sans-serif font.
        font: ?[]const u8 = null,

        /// Default font size in points.
        font_size: f32 = 16.0,

        /// Custom shaders (cross-platform - MSL for macOS, WGSL for web)
        custom_shaders: []const shader_mod.CustomShader = &.{},

        // Glass/transparency options (macOS only)

        /// Background opacity (0.0 = fully transparent, 1.0 = opaque)
        background_opacity: f64 = 1.0,

        /// Glass blur style
        glass_style: interface_mod.GlassStyle = .none,

        /// Corner radius for glass effect
        glass_corner_radius: f64 = 16.0,

        /// Make titlebar transparent
        titlebar_transparent: bool = false,

        /// Extend content under titlebar
        full_size_content: bool = false,

        /// IO interface for async work (filesystem, network, concurrency).
        /// When null, falls back to `init.io` (the runtime-selected default
        /// from `pub fn main(init: std.process.Init)`).
        io: ?std.Io = null,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "ownsTeardownAfterRun keeps teardown only for a blocking event loop" {
    // Goal: cover both drive models on every target. `runCx` reaches this with
    // `platform.drive_model`, which is `blocking_event_loop` on both native
    // backends, so a comptime branch would leave the `host_callback` decision
    // unanalyzed everywhere it is built today. Passing the model as a runtime
    // argument is what makes the second prong compiled and executed here.
    // Each prong now accepts exactly one `host_running` value, so these two
    // calls cover the whole legal input space. The rejected combinations are
    // contract violations rather than cases with a defined answer, and both
    // prongs assert them: a blocking backend must have stopped its loop before
    // `run` returns, and a host-driven one must still be live or there is no
    // owner to hand the state to. Neither is reachable through `expectPanic`,
    // so the positive space is what a test can pin.
    try std.testing.expect(ownsTeardownAfterRun(.blocking_event_loop, false));
    try std.testing.expect(!ownsTeardownAfterRun(.host_callback, true));
}

test "windowOptions carries CxConfig through to the boundary struct" {
    // Goal: pin the two values `runCx` no longer builds inline — the default
    // background colour and the straight-through `glass_style` — since the
    // translation moved into a helper.
    const Empty = struct {};
    const defaults = windowOptions(Empty, .{});
    try std.testing.expectEqual(@as(f64, 800), defaults.width);
    try std.testing.expectEqual(interface_mod.GlassStyle.none, defaults.glass_style);
    try std.testing.expectEqual(@as(f32, 0.95), defaults.background_color.r);

    const custom = windowOptions(Empty, .{
        .width = 320,
        .height = 240,
        .glass_style = .blur,
        .centered = false,
    });
    try std.testing.expectEqual(@as(f64, 320), custom.width);
    try std.testing.expectEqual(@as(f64, 240), custom.height);
    try std.testing.expectEqual(interface_mod.GlassStyle.blur, custom.glass_style);
    try std.testing.expect(!custom.centered);
}
