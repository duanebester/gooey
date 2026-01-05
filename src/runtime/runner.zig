//! Runner
//!
//! Platform initialization, window creation, and event loop management.
//! This is the main entry point for running a gooey application.
//!
//! ## Architecture Notes
//!
//! **Single-Window Limitation**: The current implementation uses static mutable
//! state in `CallbackState` to bridge between the platform's C-style callbacks
//! and the Zig runtime. This design:
//!
//! - Prevents running multiple windows simultaneously from the same process
//! - Is acceptable for single-window desktop applications (the common case)
//! - Could be extended for multi-window support by passing state through the
//!   platform's callback userdata mechanism (future enhancement)
//!
//! **Frame Budget**: In debug builds, warnings are emitted when frame rendering
//! exceeds 16.67ms (60 FPS budget). This helps identify performance issues early.
//! The first few frames are skipped since initialization is expected to be slow.

const std = @import("std");
const builtin = @import("builtin");

// Platform abstraction
const platform = @import("../platform/mod.zig");
const interface_mod = @import("../platform/interface.zig");

// Core imports
const gooey_mod = @import("../context/gooey.zig");
const geometry_mod = @import("../core/geometry.zig");
const input_mod = @import("../input/mod.zig");
const handler_mod = @import("../context/handler.zig");
const cx_mod = @import("../cx.zig");
const ui_mod = @import("../ui/mod.zig");

// Runtime imports
const frame_mod = @import("frame.zig");
const input_handler = @import("input.zig");

const Platform = platform.Platform;
const Window = platform.Window;
const Gooey = gooey_mod.Gooey;
const Cx = cx_mod.Cx;
const Builder = ui_mod.Builder;
const InputEvent = input_mod.InputEvent;

// =============================================================================
// Frame Budget Configuration (debug builds only)
// =============================================================================

/// Threshold for warning (only warn if significantly over budget)
const FRAME_WARNING_THRESHOLD_NS: i128 = 20_000_000; // 20ms

/// Number of frames to skip before warning (initialization is expected to be slow)
const FRAME_BUDGET_SKIP_COUNT: u32 = 3;

/// Run a gooey application with the Cx context API
///
/// This function initializes the platform, creates a window, sets up the
/// rendering context, and runs the main event loop.
///
/// **Note**: Only one instance of `runCx` can be active at a time due to
/// static callback state. See module documentation for details.
pub fn runCx(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    config: CxConfig(State),
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize platform
    var plat = try Platform.init();
    defer plat.deinit();

    // Linux-specific: set up Wayland listeners to get compositor/globals
    if (platform.is_linux) {
        try plat.setupListeners();
    }

    // Default background color
    const bg_color = config.background_color orelse geometry_mod.Color.init(0.95, 0.95, 0.95, 1.0);

    // Create window
    var window = try Window.init(allocator, &plat, .{
        .title = config.title,
        .width = config.width,
        .height = config.height,
        .background_color = bg_color,
        .custom_shaders = config.custom_shaders,
        // Glass/transparency options
        .background_opacity = config.background_opacity,
        .glass_style = @enumFromInt(@intFromEnum(config.glass_style)),
        .glass_corner_radius = config.glass_corner_radius,
        .titlebar_transparent = config.titlebar_transparent,
        .full_size_content = config.full_size_content,
    });
    defer window.deinit();

    // Linux-specific: register window with platform for pointer/input handling
    if (platform.is_linux) {
        plat.setActiveWindow(window);
    }

    // Initialize Gooey with owned resources
    var gooey_ctx = try Gooey.initOwned(allocator, window);
    defer gooey_ctx.deinit();

    // Initialize UI Builder
    var builder = Builder.init(
        allocator,
        gooey_ctx.layout,
        gooey_ctx.scene,
        gooey_ctx.dispatch,
    );
    defer builder.deinit();
    builder.gooey = &gooey_ctx;

    // Create unified Cx context
    var cx = Cx{
        ._allocator = allocator,
        ._gooey = &gooey_ctx,
        ._builder = &builder,
        .state_ptr = @ptrCast(state),
        .state_type_id = handler_mod.typeId(State),
    };

    // Set cx_ptr on builder so components can receive *Cx
    builder.cx_ptr = @ptrCast(&cx);

    // Set root state for handler callbacks
    handler_mod.setRootState(State, state);
    defer handler_mod.clearRootState();

    // Store references for callbacks
    // NOTE: Static state limits this to single-window applications.
    // See module documentation for architectural notes.
    const CallbackState = struct {
        var g_cx: *Cx = undefined;
        var g_on_event: ?*const fn (*Cx, InputEvent) bool = null;
        var g_building: bool = false;
        var g_frame_count: u32 = 0;

        fn onRender(win: *Window) void {
            _ = win;
            if (g_building) return;
            g_building = true;
            defer g_building = false;

            // Frame timing for budget warnings (debug builds only, skip first few frames)
            const start_time = if (builtin.mode == .Debug)
                std.time.nanoTimestamp()
            else
                0;

            frame_mod.renderFrameCx(g_cx, render) catch |err| {
                std.debug.print("Render error: {}\n", .{err});
            };

            // Check frame budget in debug builds (skip initialization frames)
            if (builtin.mode == .Debug) {
                g_frame_count += 1;
                if (g_frame_count > FRAME_BUDGET_SKIP_COUNT) {
                    const elapsed = std.time.nanoTimestamp() - start_time;
                    if (elapsed > FRAME_WARNING_THRESHOLD_NS) {
                        const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
                        std.debug.print("⚠️  Frame budget exceeded: {d:.2}ms (target: 16.67ms)\n", .{elapsed_ms});
                    }
                }
            }
        }

        fn onInput(win: *Window, event: InputEvent) bool {
            _ = win;
            return input_handler.handleInputCx(g_cx, g_on_event, event);
        }
    };

    CallbackState.g_cx = &cx;
    CallbackState.g_on_event = config.on_event;

    // Set callbacks
    window.setRenderCallback(CallbackState.onRender);
    window.setInputCallback(CallbackState.onInput);
    window.setTextAtlas(gooey_ctx.text_system.getAtlas());
    window.setSvgAtlas(gooey_ctx.svg_atlas.getAtlas());
    window.setImageAtlas(gooey_ctx.image_atlas.getAtlas());
    window.setScene(gooey_ctx.scene);

    // Run the event loop
    plat.run();
}

/// Configuration for runCx()
pub fn CxConfig(comptime State: type) type {
    _ = State; // State type captured for type safety
    const shader_mod = @import("../core/shader.zig");

    return struct {
        title: []const u8 = "Gooey App",
        width: f64 = 800,
        height: f64 = 600,
        background_color: ?geometry_mod.Color = null,

        /// Optional event handler for raw input events
        on_event: ?*const fn (*Cx, InputEvent) bool = null,

        /// Custom shaders (cross-platform - MSL for macOS, WGSL for web)
        custom_shaders: []const shader_mod.CustomShader = &.{},

        // Glass/transparency options (macOS only)

        /// Background opacity (0.0 = fully transparent, 1.0 = opaque)
        background_opacity: f32 = 1.0,

        /// Glass blur style
        glass_style: interface_mod.WindowOptions.GlassStyleCompat = .none,

        /// Corner radius for glass effect
        glass_corner_radius: f32 = 16.0,

        /// Make titlebar transparent
        titlebar_transparent: bool = false,

        /// Extend content under titlebar
        full_size_content: bool = false,
    };
}
