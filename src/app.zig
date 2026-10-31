//! App - Convenience wrapper for quick application setup
//!
//! Provides a native-only `run()` function that handles all boilerplate:
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
//! pub fn main(init: std.process.Init) !void {
//!     try gooey.run(@TypeOf(state), &state, render, .{
//!         .title = "Counter",
//!         .limits = .nano,
//!         .font_limits = .nano,
//!     }, init);
//! }
//!
//! fn render(cx: *gooey.Cx) void {
//!     cx.render(gooey.ui.vstack(.{ .gap = 16 }, .{
//!         gooey.ui.text("Hello", .{}),
//!     }));
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
const ResourceLimits = @import("core/limits.zig").ResourceLimits;
const FontLimits = @import("core/limits.zig").FontLimits;
const cx_mod = @import("cx.zig");
const ui_mod = @import("ui/mod.zig");

// `App` owns application-lifetime state shared across windows
// (`entities`, `globals` including the `Keymap`, `image_loader`). The WASM
// bootstrap heap-allocates one `App` here and hands `*App` to the
// single `Window` it creates. Single-window flow on WASM mirrors the
// native runner (`runtime/runner.zig`) — both go through `App` even
// though there is only one borrower, so entity ownership is the same
// on every runner.
const context_app_mod = @import("context/app.zig");
const ContextApp = context_app_mod.App;

// Re-export runtime functions
pub const runCx = runtime.runCx;
pub const CxConfig = runtime.CxConfig;
pub const renderFrameCx = runtime.renderFrameCx;
pub const handleInputCx = runtime.handleInputCx;

// Re-export types
pub const Cx = cx_mod.Cx;
// The local `PlatformWindow` alias is used everywhere below where the
// OS-level handle (vs. the framework `Window` wrapper) is meant.
// `GlassStyle` is one canonical enum shared by every backend
// (`platform/interface.zig`), so tag values cannot disagree and no
// `@enumFromInt(@intFromEnum(...))` bridge can silently produce the
// wrong style.
pub const GlassStyle = platform.GlassStyle;
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
///     .limits = .small,
/// });
/// ```
pub fn App(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    comptime config: anytype,
) type {
    comptime validateConfigFields(State, @TypeOf(config));
    if (platform.is_wasm) {
        return WebApp(State, state, render, config);
    } else {
        const resource_limits = comptime resolveLimits(config);
        const font_limits = comptime resolveFontLimits(config);
        return struct {
            // `main` accepts `init: std.process.Init` per Zig 0.16's
            // "Juicy Main" contract. The value is forwarded to `runCx`
            // as the trailing argument.
            pub fn main(init: std.process.Init) !void {
                // Build a fully-defaulted `CxConfig(State)` and overwrite only
                // the fields the caller supplied. Enumerating every `CxConfig`
                // field (rather than a hand-picked subset) means `App` and
                // `runCx` can never silently drift: a new `CxConfig` field is
                // forwarded here for free, and callers never have to fall
                // back to `gooey.run(...)` just to reach `on_close`,
                // `on_resize`, `min_size`, `max_size`, `centered`, or `io`.
                var cfg: runtime.CxConfig(State) = .{
                    .limits = resource_limits,
                    .font_limits = font_limits,
                };
                const ConfigType = @TypeOf(config);
                inline for (@typeInfo(runtime.CxConfig(State)).@"struct".field_names) |field_name| {
                    // `custom_shaders` (MSL-vs-WGSL coercion), `limits`, and
                    // `font_limits` (profile names) need special handling; everything else
                    // is a straight copy when the caller provided it. Unknown
                    // caller fields were already rejected at comptime.
                    if (comptime std.mem.eql(u8, field_name, "custom_shaders")) {
                        if (@hasField(ConfigType, "custom_shaders")) {
                            cfg.custom_shaders = coerceShaders(config.custom_shaders);
                        }
                    } else if (comptime std.mem.eql(u8, field_name, "limits") or
                        std.mem.eql(u8, field_name, "font_limits"))
                    {
                        // Resolved and validated at comptime above (profile names too).
                    } else if (@hasField(ConfigType, field_name)) {
                        @field(cfg, field_name) = @field(config, field_name);
                    }
                }
                try runCx(State, state, render, cfg, init);
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
/// Note: this is the WASM-specific generator. Application code should
/// reach for `gooey.App` instead — it auto-dispatches to `WebApp` on
/// WASM targets and to the native `App` shape everywhere else.
///
/// Example (cross-platform, preferred):
/// ```zig
/// var state = AppState{};
/// const App = gooey.App(AppState, &state, render, .{
///     .title = "My App",
///     .width = 800,
///     .height = 600,
///     .limits = .small,
/// });
///
/// pub fn main(init: std.process.Init) !void {
///     try App.main(init);
/// }
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

    // The same `gooey.App` config compiles for native and web, so web accepts
    // every `CxConfig` field (native-only ones such as `glass_style` have no
    // effect in a canvas) and rejects anything else, exactly like native.
    comptime validateConfigFields(State, @TypeOf(config));
    const resource_limits = comptime resolveLimits(config);
    const font_limits = comptime resolveFontLimits(config);
    const web_imports = @import("platform/web/imports.zig");
    const WebRenderer = @import("platform/web/renderer.zig").WebRenderer;

    return struct {
        const Self = @This();

        // Global state (WASM exports can't capture closures)
        var g_initialized: bool = false;
        var g_platform: ?Platform = null;
        // `g_platform_window` is the OS-level handle; `g_window` is the
        // framework wrapper. Mirrors the `platform_window` field on
        // `Window` itself.
        var g_platform_window: ?*PlatformWindow = null;
        var g_window: ?*Window = null;
        // Heap-allocated `App` owning the shared
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

        const on_init: ?*const fn (*Cx) void = if (@hasField(@TypeOf(config), "on_init"))
            config.on_init
        else
            null;

        /// Initialize the application (called from JavaScript).
        ///
        /// Named `wasmInit` rather than `init` so it doesn't shadow the
        /// `init: std.process.Init` parameter on `WebApp.main` below.
        /// The JS-visible export name is `"init"` (the `@export` call at
        /// the bottom of this struct names the symbol independently of
        /// the Zig identifier).
        pub fn wasmInit() callconv(.c) void {
            initImpl() catch |err| {
                web_imports.err("Init failed: {}", .{err});
            };
        }

        noinline fn initImpl() !void {
            const allocator = std.heap.wasm_allocator;

            // Initialize the platform in place. `g_platform` is a module-level
            // global, so its payload address is stable for the lifetime of the
            // module — which is what `initInPlace` requires: a backend may arm
            // host callbacks that retain `self` during initialization. Setting
            // the optional to an undefined payload first gives the payload its
            // final address before anything reads it.
            g_platform = @as(Platform, undefined);
            const plat = &g_platform.?;
            try plat.initInPlace(allocator);

            // Window options are named because the boundary takes
            // `*const WindowOptions`; the struct is well over the 16-byte
            // by-value threshold. The canvas-backed window reads only these
            // three fields today, but passing the shared type keeps web on the
            // same contract as native instead of a web-local options struct.
            const window_options = platform.WindowOptions{
                .title = if (@hasField(@TypeOf(config), "title")) config.title else "Window App",
                .width = if (@hasField(@TypeOf(config), "width")) config.width else 800,
                .height = if (@hasField(@TypeOf(config), "height")) config.height else 600,
                .limits = resource_limits,
            };

            // Create window. `PlatformWindow.init` registers itself with the
            // platform, so there is no follow-up registration call here.
            g_platform_window = try PlatformWindow.init(allocator, plat, &window_options);

            // Initialize Window (owns layout, scene, text_system)
            // Heap-allocated with initOwnedPtr to avoid ~400KB stack frame on WASM
            const window_ptr = try allocator.create(Window);
            const font_cfg = window_mod.FontConfig{
                .font_name = if (@hasField(@TypeOf(config), "font")) config.font else null,
                .font_size = if (@hasField(@TypeOf(config), "font_size")) config.font_size else 16.0,
                .limits = font_limits,
            };
            // Browser integrations provide asynchronous services through explicit
            // JavaScript callbacks, so unsupported operations retain failing-I/O
            // semantics. The browser backend overrides clocks because animation
            // and interaction timing require a monotonic source.
            const io = platform.backend.io.browser;

            // Allocate the shared `App` before the
            // `Window` so it can be wired in immediately after
            // `initOwnedPtr`. `initOwnedPtr` leaves
            // `window_ptr.app` at its `undefined` default; the
            // assignment a few lines below is the latest moment
            // safe to install the borrowed pointer (any earlier
            // and the `Window` does not exist yet).
            const app_ptr = try allocator.create(ContextApp);
            // `ContextApp.initInPlace` returns `!void` because it
            // registers an owned `Keymap` in `app.globals`, and `Globals.setOwned`
            // may fail with `OutOfMemory`. On WASM the bootstrap
            // has no `defer` analog, so a failure here leaves the
            // `allocator.create(ContextApp)` allocation orphaned
            // until the browser tab teardown reclaims the entire
            // WASM heap — same lifecycle as every other `g_*`
            // global in this struct.
            try app_ptr.initInPlace(allocator, io);
            g_app = app_ptr;

            try window_ptr.initOwnedPtr(
                allocator,
                g_platform_window.?,
                font_cfg,
                &resource_limits,
                io,
            );
            // Wire the borrowed `*App` onto the freshly-
            // initialised `Window`. Mirrors the same pattern in
            // `runtime/window_context.zig::WindowContext.init`;
            // every `cx.entities.*` access reaches through this
            // pointer.
            window_ptr.app = app_ptr;
            // Bind the app-scoped `ImageLoader` against
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
            // Build target is `next_frame.*`. The
            // per-tick reset block in
            // `runtime/frame.zig::renderFrameImpl` re-fetches
            // both pointers from the post-swap `next_frame.*`
            // each tick, so this init pair only has to be
            // correct on tick 0; see the comment block on the
            // matching `Builder.init` calls in
            // `runtime/window_context.zig` for the rationale.
            g_builder.?.* = Builder.init(
                allocator,
                g_window.?.layout,
                g_window.?.next_frame.scene,
                g_window.?.next_frame.dispatch,
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

            // Atlas textures exist once, at the budget sizes; the window
            // registered its platform window as the atlas upload consumer.
            g_renderer.?.initAtlases(.{
                .uploads = g_window.?.resources.atlas_uploads,
                .key = @intFromPtr(g_platform_window.?),
                .text_size = resource_limits.atlas.text_size,
                .svg_size = resource_limits.atlas.svg_size,
                .image_size = resource_limits.atlas.image_size,
            });

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

            // Upload glyphs, icons, and images placed since the last frame.
            g_renderer.?.uploadAtlasRegions();

            // Render to GPU.
            //
            // The GPU presents `rendered_frame.scene`
            // (the post-swap display buffer set up by the
            // end-of-frame `mem.swap` in
            // `runtime/frame.zig::renderFrameImpl`). With the
            // double buffer, the just-built scene rotates through
            // `rendered_frame.scene` after every tick. Web's
            // platform layer doesn't cache a scene pointer, so
            // the read happens fresh each `frame()` call — no
            // setScene plumbing is needed on web (the
            // `getPlatformWindow` short-circuit in
            // `renderFrameImpl` covers the macOS / Linux side).
            const bg = w.background_color;
            g_renderer.?.render(g_window.?.rendered_frame.scene, vw, vh, bg.r, bg.g, bg.b, bg.a);

            // Give the platform's owner its per-turn hook, then request the
            // next frame.
            //
            // This is web's turn point: `run` armed `requestAnimationFrame`
            // and returned, so the browser owns the cycle and there is no loop
            // to fire from. Placed after input drain and render, where no
            // window callback is on the stack — the same position the native
            // backends fire from. See `WebPlatform.fireLoopTurn`.
            //
            // `|*p|` rather than `|p|`: the latter copies the whole
            // `Platform` out of the optional on every frame, which is both
            // wasted work on the hot path (CLAUDE.md §20) and a move of a
            // value that `initInPlace` exists to keep pinned.
            if (g_platform) |*p| {
                p.fireLoopTurn();
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
        /// This exists so `App.main(init)` compiles on both native and web targets.
        ///
        /// Takes `init` for signature parity with the
        /// native arm. The value is discarded because WASM initialization
        /// is driven by JavaScript calling the `callconv(.c)` exports
        /// directly (`init` / `frame` / `resize`), not by the Zig
        /// runtime calling `main`.
        pub fn main(init: std.process.Init) !void {
            _ = init;
            // WASM initialization is driven by JavaScript calling the exported init().
            // This function exists only for API compatibility.
        }

        // Export functions for WASM - this comptime block runs when the type is analyzed
        comptime {
            // Zig identifier is `wasmInit`, but the JS-visible export
            // name is `"init"`.
            @export(&Self.wasmInit, .{ .name = "init" });
            @export(&Self.frame, .{ .name = "frame" });
            @export(&Self.resize, .{ .name = "resize" });
        }
    };
}

// =============================================================================
// Internal: Utilities
// =============================================================================

/// Reject `gooey.App` config fields that `CxConfig` does not define. `App`
/// copies fields by name, so a typo such as `.tittle` would otherwise be
/// ignored without a diagnostic. The message lists every valid name.
///
/// Zig cannot test compile errors in-process. Checked by hand on
/// the 0.3.1 counter: `.tittle = "x"` fails on both `run-counter` and
/// `wasm-counter` and lists the valid fields; `.init = f` fails on
/// `wasm-counter` and points to `on_init`.
fn validateConfigFields(comptime State: type, comptime ConfigType: type) void {
    comptime {
        const config_info = @typeInfo(ConfigType);
        if (config_info != .@"struct") @compileError(
            "gooey.App config must be a struct literal such as `.{ .title = \"App\" }`, got " ++
                @typeName(ConfigType),
        );
        const Valid = runtime.CxConfig(State);
        for (config_info.@"struct".field_names) |name| {
            if (@hasField(Valid, name)) continue;
            const hint = if (std.mem.eql(u8, name, "init")) " (did you mean `on_init`?)" else "";
            @compileError("gooey.App config has unknown field `" ++ name ++ "`" ++ hint ++
                "; valid fields: " ++ configFieldList(Valid));
        }
    }
}

fn configFieldList(comptime Valid: type) []const u8 {
    comptime {
        var list: []const u8 = "";
        for (@typeInfo(Valid).@"struct".field_names, 0..) |name, index| {
            list = list ++ (if (index == 0) "" else ", ") ++ name;
        }
        return list;
    }
}

/// The app's budget from its comptime config, validated at compile time.
/// Accepts a profile name (`.limits = .nano`), a `ResourceLimits` value, or a
/// complete literal. There is no default: CLAUDE.md §2 makes the budget part of
/// every app's operational contract, so an absent `.limits` is a compile error
/// that lists the profiles, and so is a name that is not one of them.
///
/// Zig cannot test compile errors in-process. Checked by hand on
/// the 0.3.1 counter, natively and with `wasm-counter`: no `.limits`,
/// `.limits = .tiny`, `.font_limits = .tiny`, a literal missing `.frame`, a
/// literal without `.font_limits`, and `in_flight_count = 4` each fail with a
/// message naming the problem.
fn resolveLimits(comptime config: anytype) ResourceLimits {
    comptime {
        const ConfigType = @TypeOf(config);
        if (!@hasField(ConfigType, "limits")) @compileError(
            "gooey.App needs .limits: a profile (" ++ profileList() ++
                ") or a ResourceLimits literal",
        );
        const resolved: ResourceLimits = if (@TypeOf(config.limits) == @TypeOf(.enum_literal))
            @field(ResourceLimits, profileName("limits", config.limits))
        else
            copyBudgets(config.limits);
        ResourceLimits.validate(resolved);
        return resolved;
    }
}

/// The tag of a profile-name enum literal, rejected with the list of profiles
/// when it names none of them. Checked before `@field` so a typo reports the
/// valid names instead of a generic "no member named" error.
fn profileName(comptime field: []const u8, comptime profile: @TypeOf(.enum_literal)) []const u8 {
    comptime {
        const name = @tagName(profile);
        for (ResourceLimits.profile_names) |profile_name| {
            if (std.mem.eql(u8, name, profile_name)) return name;
        }
        @compileError("gooey.App ." ++ field ++ " = ." ++ name ++ " is not a profile; use " ++
            profileList());
    }
}

/// ".nano, .small, .standard, .large or .ceiling", from `profile_names`.
fn profileList() []const u8 {
    comptime {
        const names = ResourceLimits.profile_names;
        var list: []const u8 = "";
        for (names, 0..) |name, index| {
            const separator = if (index == 0) "" else if (index + 1 == names.len) " or " else ", ";
            list = list ++ separator ++ "." ++ name;
        }
        return list;
    }
}

/// Copy an explicit `.limits = .{ ... }` literal into `ResourceLimits` budget by
/// budget. Every budget is required and unknown names are rejected, each with
/// an error naming the budget; without these checks a missing budget surfaces
/// as a generic "no field named" error on the anonymous config literal.
///
/// Zig cannot test compile errors in-process. Checked by hand on
/// the 0.3.1 counter with `wasm-counter` (and `run-counter` for the first):
/// `.{ .scene = ... }` names `.window`, `.{ .window = ... }` names `.scene`, an
/// extra `.windows` lists the valid budgets, a missing field inside a budget
/// names that field, and a non-struct value is rejected. Complete literals, a
/// `ResourceLimits` value, and a profile name still compile.
fn copyBudgets(comptime source: anytype) ResourceLimits {
    comptime {
        const Source = @TypeOf(source);
        if (Source == ResourceLimits) return source;
        if (@typeInfo(Source) != .@"struct") @compileError(
            "gooey.App .limits must be a profile such as `.nano` or a ResourceLimits " ++
                "literal, got " ++ @typeName(Source),
        );
        for (@typeInfo(Source).@"struct".field_names) |name| {
            if (@hasField(ResourceLimits, name)) continue;
            @compileError("ResourceLimits has no budget `" ++ name ++ "`; valid budgets: " ++
                configFieldList(ResourceLimits));
        }
        var resolved: ResourceLimits = undefined;
        for (@typeInfo(ResourceLimits).@"struct".field_names) |name| {
            if (!@hasField(Source, name)) {
                @compileError("ResourceLimits." ++ name ++ " is missing; pass ." ++ name ++
                    " or a profile such as .limits = .nano");
            }
            @field(resolved, name) = copyFields(
                @FieldType(ResourceLimits, name),
                name,
                @field(source, name),
            );
        }
        return resolved;
    }
}

/// The app's font face set from its comptime config, validated at compile
/// time. An explicit `.font_limits` wins: a `FontLimits` value, an anonymous
/// literal such as `.{ .variants = &.{ .regular, .bold } }`, or a profile name
/// (`.font_limits = .ceiling`). Without it, the `.limits` profile name selects
/// the `FontLimits` profile of the same name. A `.limits` literal has no name
/// to follow, so it then requires `.font_limits`.
fn resolveFontLimits(comptime config: anytype) FontLimits {
    comptime {
        const ConfigType = @TypeOf(config);
        const resolved: FontLimits = if (!@hasField(ConfigType, "font_limits")) blk: {
            // `resolveLimits` already rejected an absent or unknown `.limits`.
            if (@TypeOf(config.limits) != @TypeOf(.enum_literal)) @compileError(
                "gooey.App .limits is a literal, so .font_limits must be given too: " ++
                    "a profile such as .nano or a FontLimits literal",
            );
            break :blk @field(FontLimits, profileName("limits", config.limits));
        } else if (@TypeOf(config.font_limits) == @TypeOf(.enum_literal))
            @field(FontLimits, profileName("font_limits", config.font_limits))
        else if (@TypeOf(config.font_limits) == FontLimits)
            config.font_limits
        else
            // Literals passed through `anytype` keep their own type and do
            // not coerce as a whole; their variant list does.
            .{ .variants = config.font_limits.variants };
        FontLimits.validate(resolved);
        return resolved;
    }
}

/// Copy an anonymous `.{ ... }` literal into `T` field by field. Literals passed
/// through `anytype` keep their own type and do not coerce. A missing field is a
/// compile error because budget fields deliberately have no defaults.
fn copyFields(comptime T: type, comptime budget: []const u8, comptime source: anytype) T {
    comptime {
        if (@TypeOf(source) == T) return source;
        var target: T = undefined;
        for (@typeInfo(T).@"struct".field_names) |field_name| {
            if (!@hasField(@TypeOf(source), field_name)) {
                @compileError("ResourceLimits." ++ budget ++ " is missing field '" ++
                    field_name ++ "'");
            }
            @field(target, field_name) = @field(source, field_name);
        }
        return target;
    }
}

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
