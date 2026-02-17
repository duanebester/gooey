//! App - Convenience wrapper for quick application setup
//!
//! Provides a simple `run()` function that handles all boilerplate:
//! - Platform initialization
//! - Window creation
//! - UI context setup
//! - Event loop
//!
//! Example:
//! ```zig
//! const gooey = @import("gooey");
//!
//! var state = struct { count: i32 = 0 }{};
//!
//! pub fn main() !void {
//!     try gooey.run(.{
//!         .title = "Counter",
//!         .render = render,
//!     });
//! }
//!
//! fn render(ui: *gooey.UI) void {
//!     ui.vstack(.{ .gap = 16 }, .{
//!         gooey.ui.text("Hello", .{}),
//!     });
//! }
//! ```

const std = @import("std");

// Platform abstraction
const platform = @import("platform/mod.zig");

// Runtime module (handles frame rendering, input, event loop)
const runtime = @import("runtime/mod.zig");
const runtime_render = @import("runtime/render.zig");

// Core imports
const gooey_mod = @import("context/gooey.zig");
const input_mod = @import("input/mod.zig");
const shader_mod = @import("core/shader.zig");
const cx_mod = @import("cx.zig");
const ui_mod = @import("ui/mod.zig");

// Re-export runtime functions
pub const runCx = runtime.runCx;
pub const CxConfig = runtime.CxConfig;
pub const renderFrameCx = runtime.renderFrameCx;
pub const handleInputCx = runtime.handleInputCx;

// Re-export types
pub const Cx = cx_mod.Cx;
pub const GlassStyle = platform.Window.GlassStyle;
const Platform = platform.Platform;
const Window = platform.Window;
const Gooey = gooey_mod.Gooey;
const Builder = ui_mod.Builder;
const InputEvent = input_mod.InputEvent;

// =============================================================================
// Unified App - Works for both Native and Web
// =============================================================================

/// Unified app entry point generator. On native, generates `main()`.
/// On web, generates WASM exports (init/frame/resize).
///
/// Example:
/// ```zig
/// var state = AppState{};
/// const App = gooey.App(AppState, &state, render, .{
///     .title = "My App",
///     .width = 800,
///     .height = 600,
/// });
/// ```
pub fn App(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    comptime config: anytype,
) type {
    if (platform.is_wasm) {
        return WebApp(State, state, render, config);
    } else {
        return struct {
            pub fn main() !void {
                try runCx(State, state, render, .{
                    .title = if (@hasField(@TypeOf(config), "title")) config.title else "Gooey App",
                    .width = if (@hasField(@TypeOf(config), "width")) config.width else 800,
                    .height = if (@hasField(@TypeOf(config), "height")) config.height else 600,
                    .background_color = if (@hasField(@TypeOf(config), "background_color")) config.background_color else null,
                    .on_init = if (@hasField(@TypeOf(config), "init")) config.init else null,
                    .on_event = if (@hasField(@TypeOf(config), "on_event")) config.on_event else null,
                    // Custom shaders (cross-platform - MSL for macOS, WGSL for web)
                    .custom_shaders = if (@hasField(@TypeOf(config), "custom_shaders")) coerceShaders(config.custom_shaders) else &.{},
                    // Glass/transparency options
                    .background_opacity = if (@hasField(@TypeOf(config), "background_opacity")) config.background_opacity else 1.0,
                    .glass_style = if (@hasField(@TypeOf(config), "glass_style")) config.glass_style else .none,
                    .glass_corner_radius = if (@hasField(@TypeOf(config), "glass_corner_radius")) config.glass_corner_radius else 16.0,
                    .titlebar_transparent = if (@hasField(@TypeOf(config), "titlebar_transparent")) config.titlebar_transparent else false,
                    .full_size_content = if (@hasField(@TypeOf(config), "full_size_content")) config.full_size_content else false,
                    // Font configuration
                    .font = if (@hasField(@TypeOf(config), "font")) config.font else null,
                    .font_size = if (@hasField(@TypeOf(config), "font_size")) config.font_size else 16.0,
                });
            }
        };
    }
}

// =============================================================================
// WebApp - WASM Export Generator
// =============================================================================

/// Generates WASM exports for running a gooey app in the browser.
/// The returned struct contains init/frame/resize functions that are
/// automatically exported via @export when the type is analyzed.
///
/// Example:
/// ```zig
/// var state = AppState{};
///
/// // Create the WebApp type - this triggers the exports
/// const App = gooey.WebApp(AppState, &state, render, .{
///     .title = "My App",
///     .width = 800,
///     .height = 600,
/// });
///
/// // Force type analysis to ensure exports are emitted
/// comptime { _ = App; }
/// ```
pub fn WebApp(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    comptime config: anytype,
) type {
    // Only generate for WASM targets
    if (!platform.is_wasm) {
        return struct {};
    }

    const web_imports = @import("platform/web/imports.zig");
    const WebRenderer = @import("platform/web/renderer.zig").WebRenderer;

    return struct {
        const Self = @This();

        // Global state (WASM exports can't capture closures)
        var g_initialized: bool = false;
        var g_platform: ?Platform = null;
        var g_window: ?*Window = null;
        var g_gooey: ?*Gooey = null;
        var g_builder: ?*Builder = null;
        var g_cx: ?Cx = null;
        var g_renderer: ?*WebRenderer = null;

        const on_event: ?*const fn (*Cx, InputEvent) bool = if (@hasField(@TypeOf(config), "on_event"))
            config.on_event
        else
            null;

        const on_init: ?*const fn (*Cx) void = if (@hasField(@TypeOf(config), "init"))
            config.init
        else
            null;

        /// Initialize the application (called from JavaScript)
        pub fn init() callconv(.c) void {
            initImpl() catch |err| {
                web_imports.err("Init failed: {}", .{err});
            };
        }

        noinline fn initImpl() !void {
            const allocator = std.heap.wasm_allocator;

            // Initialize platform
            g_platform = try Platform.init();

            // Create window
            g_window = try Window.init(allocator, &g_platform.?, .{
                .title = if (@hasField(@TypeOf(config), "title")) config.title else "Gooey App",
                .width = if (@hasField(@TypeOf(config), "width")) config.width else 800,
                .height = if (@hasField(@TypeOf(config), "height")) config.height else 600,
            });

            // Initialize Gooey (owns layout, scene, text_system)
            // Heap-allocated with initOwnedPtr to avoid ~400KB stack frame on WASM
            const gooey_ptr = try allocator.create(Gooey);
            const font_cfg = gooey_mod.FontConfig{
                .font_name = if (@hasField(@TypeOf(config), "font")) config.font else null,
                .font_size = if (@hasField(@TypeOf(config), "font_size")) config.font_size else 16.0,
            };
            try gooey_ptr.initOwnedPtr(allocator, g_window.?, font_cfg);
            g_gooey = gooey_ptr;

            // Initialize Builder
            g_builder = try allocator.create(Builder);
            g_builder.?.* = Builder.init(
                allocator,
                g_gooey.?.layout,
                g_gooey.?.scene,
                g_gooey.?.dispatch,
            );
            g_builder.?.gooey = g_gooey.?;

            // Create Cx context
            g_cx = Cx{
                ._allocator = allocator,
                ._gooey = g_gooey.?,
                ._builder = g_builder.?,
                .state_ptr = @ptrCast(state),
                .state_type_id = cx_mod.typeId(State),
            };

            // Wire up builder to cx
            g_builder.?.cx_ptr = @ptrCast(&g_cx.?);

            // Set root state on this window's Gooey instance (not globally)
            // This enables multi-window support where each window has its own state
            g_gooey.?.setRootState(State, state);

            // Initialize GPU renderer
            // Heap-allocated with initInPlace to avoid ~1.15MB stack frame on WASM
            const renderer_ptr = try allocator.create(WebRenderer);
            renderer_ptr.initInPlace(allocator);
            g_renderer = renderer_ptr;

            // Load custom shaders (WGSL for web)
            const custom_shaders = if (@hasField(@TypeOf(config), "custom_shaders"))
                coerceShaders(config.custom_shaders)
            else
                &[_]shader_mod.CustomShader{};

            for (custom_shaders, 0..) |shader, i| {
                if (shader.wgsl) |wgsl_source| {
                    var name_buf: [32]u8 = undefined;
                    const name = std.fmt.bufPrint(&name_buf, "custom_{d}", .{i}) catch "custom";
                    g_renderer.?.addCustomShader(wgsl_source, name) catch |err| {
                        web_imports.err("Failed to load custom shader {d}: {}", .{ i, err });
                    };
                }
            }

            // Upload initial atlases
            g_renderer.?.uploadAtlas(g_gooey.?.text_system);
            g_renderer.?.uploadSvgAtlas(g_gooey.?.svg_atlas);

            g_initialized = true;

            // Initialize WASM image loader for transparent async image loading
            runtime_render.initWasmImageLoader(allocator);

            // Call user init callback if provided
            if (on_init) |init_fn| {
                init_fn(&g_cx.?);
            }

            // Start the animation loop
            if (g_platform) |*p| p.run();
        }

        pub fn frame(timestamp: f64) callconv(.c) void {
            _ = timestamp;
            if (!g_initialized) return;

            const w = g_window orelse return;
            const cx = &g_cx.?;

            // Update window size
            w.updateSize();
            g_gooey.?.width = @floatCast(w.size.width);
            g_gooey.?.height = @floatCast(w.size.height);
            g_gooey.?.scale_factor = @floatCast(w.scale_factor);

            // =========================================================
            // INPUT PROCESSING (zero JS calls)
            // =========================================================

            // Import keyboard modules
            const key_events_mod = @import("platform/web/key_events.zig");
            const text_buffer_mod = @import("platform/web/text_buffer.zig");

            // 1. Process key events (navigation, shortcuts, modifiers)
            _ = key_events_mod.processEvents(struct {
                fn handler(event: InputEvent) bool {
                    return runtime.handleInputCx(&g_cx.?, on_event, event);
                }
            }.handler);

            // 2. Process text input (typing, emoji, IME)
            _ = text_buffer_mod.processTextInput(struct {
                fn handler(event: InputEvent) bool {
                    return runtime.handleInputCx(&g_cx.?, on_event, event);
                }
            }.handler);

            // 2b. Process IME composition events (preedit text)
            const composition_buffer_mod = @import("platform/web/composition_buffer.zig");
            _ = composition_buffer_mod.processComposition(struct {
                fn handler(event: InputEvent) bool {
                    return runtime.handleInputCx(&g_cx.?, on_event, event);
                }
            }.handler);

            // 3. Process scroll events
            const scroll_events_mod = @import("platform/web/scroll_events.zig");
            _ = scroll_events_mod.processEvents(struct {
                fn handler(event: InputEvent) bool {
                    return runtime.handleInputCx(&g_cx.?, on_event, event);
                }
            }.handler);

            // 4. Process mouse events (new ring buffer approach)
            const mouse_events_mod = @import("platform/web/mouse_events.zig");
            _ = mouse_events_mod.processEvents(struct {
                fn handler(event: InputEvent) bool {
                    return runtime.handleInputCx(&g_cx.?, on_event, event);
                }
            }.handler);

            // =========================================================
            // RENDER
            // =========================================================

            // Render frame using existing gooey infrastructure
            runtime.renderFrameCx(cx, render) catch |err| {
                web_imports.err("Render error: {}", .{err});
                return;
            };

            // Get viewport dimensions (use LOGICAL pixels, not physical)
            const vw: f32 = @floatCast(w.size.width);
            const vh: f32 = @floatCast(w.size.height);

            // Sync atlas textures if glyphs/icons/images were added
            g_renderer.?.syncAtlas(g_gooey.?.text_system);
            g_renderer.?.syncSvgAtlas(g_gooey.?.svg_atlas);
            g_renderer.?.syncImageAtlas(g_gooey.?.image_atlas);

            // Render to GPU
            const bg = w.background_color;
            g_renderer.?.render(g_gooey.?.scene, vw, vh, bg.r, bg.g, bg.b, bg.a);

            // Request next frame
            if (g_platform) |p| {
                if (p.isRunning()) web_imports.requestAnimationFrame();
            }
        }

        /// Handle window resize (called from JavaScript)
        pub fn resize(width: u32, height: u32) callconv(.c) void {
            _ = width;
            _ = height;
            if (g_window) |w| w.updateSize();
        }

        /// No-op main for API compatibility with native App.
        /// On WASM, JavaScript calls init() directly via the exported function.
        /// This exists so `App.main()` compiles on both native and web targets.
        pub fn main() !void {
            // WASM initialization is driven by JavaScript calling the exported init().
            // This function exists only for API compatibility.
        }

        // Export functions for WASM - this comptime block runs when the type is analyzed
        comptime {
            @export(&Self.init, .{ .name = "init" });
            @export(&Self.frame, .{ .name = "frame" });
            @export(&Self.resize, .{ .name = "resize" });
        }
    };
}

// =============================================================================
// Internal: Utilities
// =============================================================================

fn coerceShaders(comptime shaders: anytype) []const shader_mod.CustomShader {
    const len = shaders.len;
    if (len == 0) return &.{};

    const result = comptime blk: {
        var r: [len]shader_mod.CustomShader = undefined;
        for (0..len) |i| {
            const s = shaders[i];
            r[i] = .{
                .msl = if (@hasField(@TypeOf(s), "msl")) s.msl else null,
                .wgsl = if (@hasField(@TypeOf(s), "wgsl")) s.wgsl else null,
            };
        }
        break :blk r;
    };
    return &result;
}
