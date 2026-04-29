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
const window_mod = @import("context/window.zig");
const input_mod = @import("input/mod.zig");
const shader_mod = @import("core/shader.zig");
const cx_mod = @import("cx.zig");
const ui_mod = @import("ui/mod.zig");

// PR 7b.3 — `App` owns application-lifetime state shared across
// windows (currently `entities`; later 7b slices add `keymap` /
// `globals` / `image_loader`). The WASM bootstrap heap-allocates
// one `App` here and hands `*App` to the single `Window` it
// creates. Single-window flow on WASM mirrors the native runner
// (`runtime/runner.zig`) — both go through `App` even though
// there is only one borrower today, so the future runner
// consolidation is a no-op for entity ownership.
const context_app_mod = @import("context/app.zig");
const ContextApp = context_app_mod.App;

// Re-export runtime functions
pub const runCx = runtime.runCx;
pub const CxConfig = runtime.CxConfig;
pub const renderFrameCx = runtime.renderFrameCx;
pub const handleInputCx = runtime.handleInputCx;

// Re-export types
pub const Cx = cx_mod.Cx;
// PR 7b.1a — `platform.Window` was renamed to `platform.PlatformWindow`
// to free up the `Window` name for the upcoming `Window → Window` rename
// in PR 7b.1b. The local `PlatformWindow` alias is used everywhere
// below where the OS-level handle (vs. the framework wrapper) is meant.
pub const GlassStyle = platform.PlatformWindow.GlassStyle;
const Platform = platform.Platform;
const PlatformWindow = platform.PlatformWindow;
const Window = window_mod.Window;
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
                    .title = if (@hasField(@TypeOf(config), "title")) config.title else "Window App",
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
        // PR 7b.1b — `g_window` (OS-level handle) renamed to
        // `g_platform_window` so the framework wrapper rename
        // (`Window → Window`) can claim `g_window` for itself in the
        // sweep below. Mirrors the field rename on `Window` itself
        // (`window → platform_window`) and the §10 GPUI sketch.
        var g_platform_window: ?*PlatformWindow = null;
        var g_window: ?*Window = null;
        // PR 7b.3 — heap-allocated `App` owning the shared
        // `EntityMap`. WASM has no `defer` analog at file
        // scope, so this leaks at process exit — same lifecycle
        // as every other `g_*` global in this struct (the
        // browser tab teardown reclaims the entire WASM heap).
        var g_app: ?*ContextApp = null;
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
            g_platform_window = try PlatformWindow.init(allocator, &g_platform.?, .{
                .title = if (@hasField(@TypeOf(config), "title")) config.title else "Window App",
                .width = if (@hasField(@TypeOf(config), "width")) config.width else 800,
                .height = if (@hasField(@TypeOf(config), "height")) config.height else 600,
            });

            // Initialize Window (owns layout, scene, text_system)
            // Heap-allocated with initOwnedPtr to avoid ~400KB stack frame on WASM
            const window_ptr = try allocator.create(Window);
            const font_cfg = window_mod.FontConfig{
                .font_name = if (@hasField(@TypeOf(config), "font")) config.font else null,
                .font_size = if (@hasField(@TypeOf(config), "font_size")) config.font_size else 16.0,
            };
            // WASM uses single-threaded IO — no fibers, sequential execution.
            const io = std.Io.Threaded.global_single_threaded.io();

            // PR 7b.3 — allocate the shared `App` before the
            // `Window` so it can be wired in immediately after
            // `initOwnedPtr`. `initOwnedPtr` leaves
            // `window_ptr.app` at its `undefined` default; the
            // assignment a few lines below is the latest moment
            // safe to install the borrowed pointer (any earlier
            // and the `Window` does not exist yet).
            const app_ptr = try allocator.create(ContextApp);
            // PR 7b.4 — `ContextApp.initInPlace` returns `!void`
            // now (was `void`) because it registers an owned
            // `Keymap` in `app.globals`, and `Globals.setOwned`
            // may fail with `OutOfMemory`. On WASM the bootstrap
            // has no `defer` analog, so a failure here leaves the
            // `allocator.create(ContextApp)` allocation orphaned
            // until the browser tab teardown reclaims the entire
            // WASM heap — same lifecycle as every other `g_*`
            // global in this struct.
            try app_ptr.initInPlace(allocator, io);
            g_app = app_ptr;

            try window_ptr.initOwnedPtr(allocator, g_platform_window.?, font_cfg, io);
            // PR 7b.3 — wire the borrowed `*App` onto the freshly-
            // initialised `Window`. Mirrors the same pattern in
            // `runtime/window_context.zig::WindowContext.init`;
            // every `cx.entities.*` access reaches through this
            // pointer.
            window_ptr.app = app_ptr;
            // PR 7b.5 — bind the app-scoped `ImageLoader` against
            // the window's owning `image_atlas`. Mirrors the
            // single-window native path in
            // `runtime/window_context.zig::WindowContext.init`:
            // `Window.initOwnedPtr` creates the owning
            // `AppResources` (and the backing `ImageAtlas`), so
            // this is the first moment a stable `*ImageAtlas` is
            // available to hand to the loader. `bindImageLoader`
            // is idempotent on same-atlas re-binds (no-op on the
            // second call), so the WASM-vs-native split here is
            // structural rather than behavioural — both bind once
            // per `App` lifetime against the same single window's
            // atlas. See `context/app.zig` file header for the
            // two-phase init rationale.
            app_ptr.bindImageLoader(window_ptr.resources.image_atlas);
            g_window = window_ptr;

            // Initialize Builder
            g_builder = try allocator.create(Builder);
            g_builder.?.* = Builder.init(
                allocator,
                g_window.?.layout,
                g_window.?.scene,
                g_window.?.dispatch,
            );
            g_builder.?.window = g_window.?;

            // Create Cx context
            g_cx = Cx{
                ._allocator = allocator,
                ._window = g_window.?,
                ._builder = g_builder.?,
                .state_ptr = @ptrCast(state),
                .state_type_id = cx_mod.typeId(State),
            };

            // Wire up builder to cx
            g_builder.?.cx_ptr = @ptrCast(&g_cx.?);

            // Set root state on this window's Window instance (not globally)
            // This enables multi-window support where each window has its own state
            g_window.?.setRootState(State, state);

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
            g_renderer.?.uploadAtlas(g_window.?.resources.text_system);
            g_renderer.?.uploadSvgAtlas(g_window.?.resources.svg_atlas);

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

            const w = g_platform_window orelse return;
            const cx = &g_cx.?;

            // Update window size
            w.updateSize();
            g_window.?.width = @floatCast(w.size.width);
            g_window.?.height = @floatCast(w.size.height);
            g_window.?.scale_factor = @floatCast(w.scale_factor);

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
            g_renderer.?.syncAtlas(g_window.?.resources.text_system);
            g_renderer.?.syncSvgAtlas(g_window.?.resources.svg_atlas);
            g_renderer.?.syncImageAtlas(g_window.?.resources.image_atlas);

            // Render to GPU
            const bg = w.background_color;
            g_renderer.?.render(g_window.?.scene, vw, vh, bg.r, bg.g, bg.b, bg.a);

            // Request next frame
            if (g_platform) |p| {
                if (p.isRunning()) web_imports.requestAnimationFrame();
            }
        }

        /// Handle window resize (called from JavaScript)
        pub fn resize(width: u32, height: u32) callconv(.c) void {
            _ = width;
            _ = height;
            if (g_platform_window) |w| w.updateSize();
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
