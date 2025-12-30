//! Runner
//!
//! Platform initialization, window creation, and event loop management.
//! This is the main entry point for running a gooey application.

const std = @import("std");

// Platform abstraction
const platform = @import("../platform/mod.zig");
const interface_mod = @import("../platform/interface.zig");

// Core imports
const gooey_mod = @import("../core/gooey.zig");
const geometry_mod = @import("../core/geometry.zig");
const input_mod = @import("../core/input.zig");
const handler_mod = @import("../core/handler.zig");
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

/// Run a gooey application with the Cx context API
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
        .state_type_id = cx_mod.typeId(State),
    };

    // Set cx_ptr on builder so components can receive *Cx
    builder.cx_ptr = @ptrCast(&cx);

    // Set root state for handler callbacks
    handler_mod.setRootState(State, state);
    defer handler_mod.clearRootState();

    // Store references for callbacks
    const CallbackState = struct {
        var g_cx: *Cx = undefined;
        var g_on_event: ?*const fn (*Cx, InputEvent) bool = null;
        var g_building: bool = false;

        fn onRender(win: *Window) void {
            _ = win;
            if (g_building) return;
            g_building = true;
            defer g_building = false;

            frame_mod.renderFrameCx(g_cx, render) catch |err| {
                std.debug.print("Render error: {}\n", .{err});
            };
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
