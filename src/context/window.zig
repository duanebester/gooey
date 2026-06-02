//! Window - Unified UI Context
//!
//! Central context for the UI framework, managing layout, rendering, widgets,
//! focus, and event dispatch.
//!
//! Single struct that holds everything needed for UI, replacing the
//! App/Context/ViewContext complexity. Provides a clean API for:
//! - Layout (immediate mode)
//! - Rendering (retained scene)
//! - Widget management (retained widgets)
//! - Hit testing
//!
//! Example:
//! ```zig
//! var ui = try Window.init(allocator, window, &layout_engine, &scene, &text_system);
//! defer ui.deinit();
//!
//! // In render callback:
//! ui.beginFrame();
//! // Build UI...
//! const commands = ui.endFrame();
//! // Render commands to scene...
//! ```
//!
//! ## Composed subsystems
//!
//! Several self-contained subsystems live as peer modules and are
//! composed onto `Window` as ordinary fields:
//!
//!   - `hover: HoverState`                  — see `hover.zig`
//!   - `blur_handlers: BlurHandlerRegistry` — see `blur_handlers.zig`
//!   - `cancel_registry: CancelRegistry`    — see `cancel_registry.zig`
//!   - `a11y: A11ySystem`                   — see `a11y_system.zig`
//!
//! Methods like `updateHover` / `registerBlurHandler` / `isA11yEnabled`
//! are one-line forwarders; internal callers (`runtime/*.zig`,
//! `ui/builder.zig`) reach the sub-fields directly via `window.hover.*`
//! / `window.a11y.*` / etc.

const std = @import("std");
const builtin = @import("builtin");

// Enable verbose init logging for debugging stack overflow issues
const verbose_init_logging = false;

// WASM debug logging (no-op on native, or when verbose logging disabled)
const wasm_log = if (builtin.os.tag == .freestanding and verbose_init_logging)
    struct {
        const web_imports = @import("../platform/web/imports.zig");
        pub fn log(comptime fmt: []const u8, args: anytype) void {
            web_imports.log(fmt, args);
        }
    }
else
    struct {
        pub fn log(comptime fmt: []const u8, args: anytype) void {
            _ = fmt;
            _ = args;
        }
    };
const debugger_mod = @import("../debug/debugger.zig");
const render_stats = @import("../debug/render_stats.zig");

// Accessibility (re-exported types only — owning subsystem lives in
// `a11y_system.zig`).
const a11y = @import("../accessibility/accessibility.zig");

// Layout
const layout_mod = @import("../layout/layout.zig");
const engine_mod = @import("../layout/engine.zig");
const svg_mod = @import("../svg/mod.zig");
const image_mod = @import("../image/mod.zig");
const LayoutEngine = layout_mod.LayoutEngine;
const LayoutId = layout_mod.LayoutId;
const ElementDeclaration = layout_mod.ElementDeclaration;
const BoundingBox = layout_mod.BoundingBox;
const TextConfig = layout_mod.TextConfig;
const RenderCommand = layout_mod.RenderCommand;
const TextMeasurement = engine_mod.TextMeasurement;

const dispatch_mod = @import("dispatch.zig");
const DispatchTree = dispatch_mod.DispatchTree;

const entity_mod = @import("entity.zig");
const EntityMap = entity_mod.EntityMap;
pub const EntityId = entity_mod.EntityId;

// `App` owns application-lifetime state shared across windows (entity
// map, keymap, app-scoped globals). Each `Window` borrows its parent
// via the `app: *App` field below.
const app_mod = @import("app.zig");
const App = app_mod.App;

// `Keymap` lives on `App.globals`; `Window.keymap()` forwards to
// `self.app.keymap()`. The alias survives because the forwarder's
// return type still names `*Keymap`.
const action_mod = @import("../input/actions.zig");
const Keymap = action_mod.Keymap;

// Scene
const scene_mod = @import("../scene/scene.zig");
const Scene = scene_mod.Scene;

// Text
const text_mod = @import("../text/mod.zig");
const TextSystem = text_mod.TextSystem;

// Concrete widget state types don't leak into `Window`; focus is driven
// through the `Focusable` vtable in `context/focus.zig`, and per-widget
// retained state lives in `window.element_states`.

// Retained-state animation pools (tween / spring / motion / spring-motion).
// These keep their own typed storage rather than `element_states` because
// one widget can drive multiple concurrent animations against different
// ids — see `animation/store.zig`.
const animation_store_mod = @import("../animation/store.zig");
const AnimationStore = animation_store_mod.AnimationStore;

// Per-frame value-diffing storage backing `cx.changed(key, value)`.
const change_tracker_mod = @import("change_tracker.zig");
const ChangeTracker = change_tracker_mod.ChangeTracker;

// Platform
const platform = @import("../platform/mod.zig");
// The OS-level window handle (NSWindow on macOS, wl_surface on Linux,
// canvas on web), held by the `window: ?*PlatformWindow` field below.
const PlatformWindow = platform.PlatformWindow;

// Input
const input_mod = @import("../input/events.zig");
const InputEvent = input_mod.InputEvent;

// Focus
const focus_mod = @import("focus.zig");
const FocusManager = focus_mod.FocusManager;
const FocusId = focus_mod.FocusId;
const FocusHandle = focus_mod.FocusHandle;
const FocusEvent = focus_mod.FocusEvent;

// Handler system
const handler_mod = @import("handler.zig");
const HandlerRef = handler_mod.HandlerRef;

// Drag & Drop
const drag_mod = @import("drag.zig");
pub const DragState = drag_mod.DragState;

// Geometry
const geometry = @import("../core/geometry.zig");
const Point = geometry.Point;

// Composed subsystems. Body lives in the named files; `Window` composes
// them as ordinary fields.
const hover_mod = @import("hover.zig");
const HoverState = hover_mod.HoverState;
const blur_handlers_mod = @import("blur_handlers.zig");
const BlurHandlerRegistry = blur_handlers_mod.BlurHandlerRegistry;
const cancel_registry_mod = @import("cancel_registry.zig");
const CancelRegistry = cancel_registry_mod.CancelRegistry;
const a11y_system_mod = @import("a11y_system.zig");
const A11ySystem = a11y_system_mod.A11ySystem;

// Bundled rendering resources (text + svg + image) behind a single
// ownership flag. See `app_resources.zig`.
const app_resources_mod = @import("app_resources.zig");
const AppResources = app_resources_mod.AppResources;

// Bundled per-window per-frame rendering state (scene + dispatch tree)
// behind a single ownership flag. Held as a `rendered_frame` /
// `next_frame` pair swapped (`mem.swap`) at the frame boundary, so input
// handlers running between frames hit-test against the last fully-built
// tree (`rendered_frame.dispatch`) while build writes land in
// `next_frame.*`. See `frame.zig`.
const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;

// Explicit per-frame phase tagging. `current_phase` advances
// monotonically through `none → prepaint → paint → focus → none`;
// `assertAdvance` enforces the legal transition table at each step.
const draw_phase_mod = @import("draw_phase.zig");
pub const DrawPhase = draw_phase_mod.DrawPhase;

// Type-keyed singleton storage for cross-cutting per-window state. Only
// `Debugger` lives here (its overlay quads, frame timing, and selected
// layout id are per-window — sharing one across windows would mix
// metrics from unrelated frames); app-scoped globals live on
// `App.globals` instead.
const global_mod = @import("global.zig");
const Globals = global_mod.Globals;

// Unified `(id_hash, type_id) -> *S` keyed pool for element-attached state.
// Heap-allocated (`*ElementStates`) because the entry table is 128 KiB, too
// large for the WASM stack budget. See `element_states.zig`.
const element_states_mod = @import("element_states.zig");
const ElementStates = element_states_mod.ElementStates;

// =============================================================================
// Local infrastructure (deferred command queue)
// =============================================================================
//
// The deferred-command queue stays on `Window`: it is not a self-contained
// subsystem; it reaches into the root-state pointer and the render-request
// flag every flush.

const MAX_DEFERRED_COMMANDS = 32;

const DeferredCommand = struct {
    callback: *const fn (*Window, u64) void,
    packed_arg: u64,
};

/// Extract the State type from a handler method's first parameter.
///
/// All handler methods follow the pattern `fn(*State, ...) void` where the
/// first parameter is always a pointer to the state type. This helper uses
/// `@typeInfo` to pull the pointee type from that first parameter, eliminating
/// the need to pass the State type explicitly.
fn extractState(comptime caller: []const u8, comptime Fn: type) type {
    const info = @typeInfo(Fn);
    if (info != .@"fn") {
        @compileError(caller ++ "() expects a function, got " ++ @typeName(Fn));
    }
    const fn_info = info.@"fn";
    if (fn_info.params.len == 0) {
        @compileError(caller ++ "() expects a method with at least one parameter (*State), got a function with no parameters");
    }
    const FirstParam = fn_info.params[0].type orelse {
        @compileError(caller ++ "() expects a concrete first parameter type (*State), got anytype");
    };
    const ptr_info = @typeInfo(FirstParam);
    if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
        @compileError(caller ++ "() expects first parameter to be *State (single-item pointer), got " ++ @typeName(FirstParam));
    }
    return ptr_info.pointer.child;
}

/// Font configuration for app initialization.
/// Pass to `initOwned` / `initOwnedPtr` to control the default font.
pub const FontConfig = struct {
    /// Font family name (e.g., "Inter", "JetBrains Mono").
    /// When null, uses the platform's default sans-serif font.
    font_name: ?[]const u8 = null,

    /// Font size in points.
    font_size: f32 = 16.0,

    /// Default config — system sans-serif at 16pt.
    pub const default = FontConfig{};
};

/// Window - unified UI context
pub const Window = struct {
    allocator: std.mem.Allocator,
    // IO interface (Zig 0.16 std.Io — replaces ad-hoc global_single_threaded calls).
    // Threaded through the framework from main(); see cx.io() accessor.
    io: std.Io,

    // Layout (immediate mode - rebuilt each frame). Always owned: no init
    // path borrows the layout engine.
    layout: *LayoutEngine,

    /// Build-target Frame for the current tick. Every render-pipeline call
    /// site that produces scene primitives or dispatch nodes writes through
    /// `next_frame.scene` / `next_frame.dispatch`. At the frame boundary,
    /// `runtime/frame.zig::renderFrameImpl` calls
    /// `mem.swap(&rendered_frame, &next_frame)` then clears the new
    /// `next_frame` so the slot recycles the previous-frame buffer for the
    /// next build pass. Both slots keep `owned = true`: `mem.swap` is a
    /// physical struct exchange between two owning slots, not a hand-off
    /// through `Frame.borrowed`. Default `undefined` so test fixtures keep
    /// compiling. See `frame.zig`.
    next_frame: Frame = undefined,

    /// Previously-built Frame, stable across the input gap between frame N's
    /// build and frame N+1's swap. Input events between frames hit-test
    /// through `rendered_frame.dispatch` (the last fully-built tree, bounds
    /// already synced), which is what the double buffer is for. On the very
    /// first tick the slot is empty, so input arriving before frame 0's
    /// build hit-tests against an empty tree — a graceful no-op. Both slots
    /// keep `owned = true` (see `next_frame`). Default `undefined` so test
    /// fixtures keep compiling. See `frame.zig`.
    rendered_frame: Frame = undefined,

    /// Bundled shared rendering resources. Owns or borrows `text_system` /
    /// `svg_atlas` / `image_atlas` as one unit; `resources.owned`
    /// discriminates (single-window owns; multi-window borrows from the
    /// parent `App`). Default `undefined` so test fixtures keep compiling.
    /// See `app_resources.zig`.
    resources: AppResources = undefined,

    /// Animation pools (retained across frames). Hosts the four u32-keyed
    /// pools driving tween / spring / motion / spring-motion; see
    /// `animation/store.zig`.
    animations: AnimationStore,

    /// Per-frame value-diffing storage backing `cx.changed(key, value)`.
    /// Fixed-capacity (no allocation after init), so the default value is a
    /// complete initialisation; no init/deinit hook is needed.
    change_tracker: ChangeTracker = .{},

    /// Unified `(id_hash, type_id) -> *S` keyed pool for element-attached
    /// state. Heap-allocated because the entry table is 128 KiB (4096 slots
    /// × 32 B/slot), too large for the WASM stack. Default `undefined` so
    /// test fixtures keep compiling. See `element_states.zig`.
    element_states: *ElementStates = undefined,

    // Focus management
    focus: FocusManager,

    /// Hover state (see `hover.zig`). Owns: hovered layout id, last cursor
    /// pos, ancestor chain cache, hover-changed latch. Public field —
    /// internal callers reach in via `window.hover.*` to avoid a forwarder
    /// layer.
    hover: HoverState = .{},

    // Drag & Drop state
    /// Pending drag (mouse down, threshold not yet exceeded)
    pending_drag: ?drag_mod.PendingDrag = null,
    /// Active drag (threshold exceeded, drag in progress)
    active_drag: ?drag_mod.DragState = null,
    /// Layout ID of current drop target (for drag-over styling)
    drag_over_target: ?u32 = null,

    // `debugger` lives in `globals`; access via `window.debugger()`. The
    // accessor reads from the type-keyed store — one indirection vs. a
    // direct field, but it keeps singletons off the struct surface.

    /// Type-keyed singleton store (see `global.zig`). Owns `Debugger` only;
    /// `Keymap` and the `*const Theme` slot are app-scoped on `App.globals`.
    /// Default-constructed; populated post-init by every `init*` path via
    /// `setOwned`.
    globals: Globals = .{},

    /// Current frame phase (see `draw_phase.zig`). Advances monotonically
    /// through `none → prepaint → paint → focus → none` across the frame
    /// lifecycle. Phase-restricted methods assert against this value at
    /// entry; the helper `advancePhase` pair-asserts every legal transition.
    /// Default `.none` covers "constructed but never entered a frame".
    current_phase: DrawPhase = .none,

    /// Borrowed `*App` view onto application-lifetime state shared across
    /// windows: the entity map, and the `Keymap` / `*const Theme` slots in
    /// `app.globals`. The single-window flow heap-allocates an `App` in
    /// `runtime/runner.zig`; the multi-window flow embeds a `context.App`
    /// inside `runtime/multi_window_app.zig::App`. Either way the pointee
    /// outlives every borrowing `Window`: `Window.deinit` does not touch
    /// this field; the upstream owner tears down the `App` after the last
    /// `Window.deinit` returns. Default `undefined` so test fixtures
    /// (`testWindow`) keep compiling; every `init*` path assigns it before
    /// the first frame.
    app: *App = undefined,

    // Platform — OS-level window handle (NSWindow on macOS, wl_surface on
    // Linux, canvas on web). Named `platform_window` rather than `window`
    // so it doesn't shadow the framework `Window` struct's name inside its
    // own methods.
    platform_window: ?*PlatformWindow,

    // Frame state
    frame_count: u64 = 0,
    needs_render: bool = true,

    // Window dimensions (cached for convenience)
    width: f32 = 0,
    height: f32 = 0,
    scale_factor: f32 = 1.0,

    /// Accessibility subsystem (see `a11y_system.zig`). Owns: tree, platform
    /// bridge storage, bridge dispatcher, the "screen reader active" flag,
    /// and the periodic poll counter. `undefined` until `initOwned` /
    /// `initOwnedPtr` etc wire it.
    a11y: A11ySystem = undefined,

    // Per-window root state for handler callbacks (multi-window support)
    /// Type-erased pointer to this window's root state
    root_state_ptr: ?*anyopaque = null,
    /// Type ID for runtime type checking of root state
    root_state_type_id: usize = 0,

    // Deferred command queue (for operations that must run after event handling)
    deferred_commands: [MAX_DEFERRED_COMMANDS]DeferredCommand = undefined,
    deferred_count: u8 = 0,

    /// Blur handler registry (see `blur_handlers.zig`). Backed by the
    /// generic `SubscriberSet`; cap is `MAX_BLUR_HANDLERS` (64). `undefined`
    /// here so the parent's by-pointer init paths can `initInPlace` without
    /// a stack temp; struct-literal init paths set it explicitly.
    blur_handlers: BlurHandlerRegistry = undefined,

    /// Cancel-group registry (see `cancel_registry.zig`). Backed by the
    /// generic `SubscriberSet`; cap is `MAX_CANCEL_GROUPS` (64). All
    /// registered groups are cancelled in `deinit`.
    cancel_registry: CancelRegistry = undefined,

    // `image_loader` lives on `App`, not `Window`: a single app-scoped
    // loader lets in-flight URL fetches dedup across windows (two windows
    // fetching the same URL share one background task) and keeps the
    // pending / failed sets and fetch group app-wide.
    //
    // The forwarder methods below (`isImageLoadPending` /
    // `isImageLoadFailed`) and `beginFrame`'s drain reach through
    // `self.app.image_loader.*`.

    const Self = @This();

    /// Get the type ID for a given type. Canonical definition in entity.zig.
    pub const typeId = entity_mod.typeId;

    /// Set the root state pointer for this window's handler callbacks
    pub fn setRootState(self: *Self, comptime State: type, state_ptr: *State) void {
        self.root_state_ptr = @ptrCast(state_ptr);
        self.root_state_type_id = typeId(State);
    }

    /// Clear the root state pointer
    pub fn clearRootState(self: *Self) void {
        self.root_state_ptr = null;
        self.root_state_type_id = 0;
    }

    // =========================================================================
    // Cancel Group Registry — forwarders to `cancel_registry`
    // =========================================================================
    //
    // Body lives in `cancel_registry.zig`. The wrappers here preserve the
    // call surface used by `cx.registerCancelGroup` / external apps.

    /// Register a cancel group for automatic cancellation on teardown.
    ///
    /// Registered groups are cancelled in `deinit()` (window close / app exit),
    /// preventing use-after-free from stale background tasks. Groups are not
    /// cancelled mid-frame — `Group.cancel()` blocks, so it is only safe at
    /// teardown boundaries.
    pub fn registerCancelGroup(self: *Self, group: *std.Io.Group) void {
        self.cancel_registry.register(group);
    }

    /// Unregister a cancel group (e.g., when async work completes normally).
    ///
    /// Silent no-op when the group is not registered. The boolean returned
    /// by the underlying `CancelRegistry.unregister` is discarded — callers
    /// that need it should use the registry directly.
    pub fn unregisterCancelGroup(self: *Self, group: *std.Io.Group) void {
        _ = self.cancel_registry.unregister(group);
    }

    // =========================================================================
    // Async Image Loading — forwarders to `app.image_loader`
    // =========================================================================
    //
    // Body lives in `src/image/loader.zig` (`ImageLoader`). The loader is
    // app-scoped; these forwarders route through `self.app.image_loader.*`
    // so call sites in `runtime/render.zig` don't reach through `window.app`
    // themselves.

    /// Check whether a URL image fetch is already in flight.
    pub fn isImageLoadPending(self: *const Self, url_hash: u64) bool {
        return self.app.image_loader.isPending(url_hash);
    }

    /// Check whether a URL has previously failed to fetch.
    pub fn isImageLoadFailed(self: *const Self, url_hash: u64) bool {
        return self.app.image_loader.isFailed(url_hash);
    }

    /// Get the root state pointer with type checking
    pub fn getRootState(self: *Self, comptime State: type) ?*State {
        if (self.root_state_ptr) |ptr| {
            if (self.root_state_type_id == typeId(State)) {
                return @ptrCast(@alignCast(ptr));
            }
        }
        return null;
    }

    // =========================================================================
    // Deferred Commands
    // =========================================================================

    /// Queue a callback to run after current event handling completes.
    /// Used internally by Cx.defer().
    ///
    /// The State type is inferred from the method's first parameter.
    /// The method should be `fn(*State, *Window) void`.
    pub fn deferCommand(
        self: *Self,
        comptime method: anytype,
    ) void {
        const State = comptime extractState("deferCommand", @TypeOf(method));

        if (self.deferred_count >= MAX_DEFERRED_COMMANDS) {
            std.log.warn("Deferred command queue full ({} commands) - dropping command", .{MAX_DEFERRED_COMMANDS});
            return;
        }

        const Wrapper = struct {
            fn invoke(g: *Self, _: u64) void {
                const state_ptr = g.getRootState(State) orelse return;
                method(state_ptr, g);
                g.requestRender();
            }
        };

        self.deferred_commands[self.deferred_count] = .{
            .callback = Wrapper.invoke,
            .packed_arg = 0,
        };
        self.deferred_count += 1;
    }

    /// Queue a callback with an argument to run after current event handling completes.
    /// Used internally by Cx.deferWith().
    ///
    /// The State type is inferred from the method's first parameter.
    /// The argument is stored inline in the command struct (packed into u64),
    /// so multiple deferred calls with the same signature work correctly.
    pub fn deferCommandWith(
        self: *Self,
        arg: anytype,
        comptime method: anytype,
    ) void {
        const State = comptime extractState("deferCommandWith", @TypeOf(method));
        const Arg = @TypeOf(arg);

        comptime {
            if (@sizeOf(Arg) > @sizeOf(u64)) {
                @compileError("deferWith: argument type '" ++ @typeName(Arg) ++ "' exceeds 8 bytes. Use a pointer or index instead.");
            }
        }

        if (self.deferred_count >= MAX_DEFERRED_COMMANDS) {
            std.log.warn("Deferred command queue full ({} commands) - dropping command", .{MAX_DEFERRED_COMMANDS});
            return;
        }

        // Pack arg into u64 using the same pattern as updateWith/commandWith
        const packed_value = handler_mod.packArg(Arg, arg).id;

        const Wrapper = struct {
            fn invoke(g: *Self, packed_arg: u64) void {
                const state_ptr = g.getRootState(State) orelse return;
                const unpacked = handler_mod.unpackArg(Arg, .{ .id = packed_arg });
                method(state_ptr, g, unpacked);
                g.requestRender();
            }
        };

        self.deferred_commands[self.deferred_count] = .{
            .callback = Wrapper.invoke,
            .packed_arg = packed_value,
        };
        self.deferred_count += 1;
    }

    /// Execute all queued deferred commands.
    /// Called by runtime after event handling completes.
    pub fn flushDeferredCommands(self: *Self) void {
        const count = self.deferred_count;
        self.deferred_count = 0;

        for (self.deferred_commands[0..count]) |cmd| {
            cmd.callback(self, cmd.packed_arg);
        }
    }

    /// Check if there are pending deferred commands.
    pub fn hasDeferredCommands(self: *const Self) bool {
        return self.deferred_count > 0;
    }

    /// Initialize Window creating and owning all resources
    pub fn initOwned(allocator: std.mem.Allocator, platform_window: *PlatformWindow, font_config: FontConfig, io: std.Io) !Self {
        // Create layout engine
        const layout_engine = allocator.create(LayoutEngine) catch return error.OutOfMemory;
        layout_engine.* = LayoutEngine.init(allocator);
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

        // Allocate the two-`Frame` double buffer. Each `Frame.initOwned`
        // allocates its own heap-backed `Scene` + `DispatchTree` pair;
        // `mem.swap` between the two slots exchanges which slot points at
        // which pair. Both pairs are owned by the `Window` for its entire
        // lifetime; `Window.deinit` tears both down. The two locals are
        // copied into `result.{next,rendered}_frame` below; the heap
        // pointers inside survive the by-value copy (same shape as
        // `resources`).
        var next_frame = try Frame.initOwned(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer next_frame.deinit();

        var rendered_frame = try Frame.initOwned(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer rendered_frame.deinit();

        // Bundle text + SVG + image resources into one `AppResources`. The
        // resulting struct is copied into `result.resources` below; the heap
        // pointers it carries survive the by-value copy.
        var resources = try AppResources.initOwned(
            allocator,
            io,
            @floatCast(platform_window.scale_factor),
            .{
                .font_name = font_config.font_name,
                .font_size = font_config.font_size,
            },
        );
        errdefer resources.deinit();

        // Set up text measurement callback against the bundled text system.
        layout_engine.setMeasureTextFn(measureTextCallback, resources.text_system);

        // Heap-allocate the unified element-state pool: the 4096-slot entry
        // table is 128 KiB, too large to live by-value on `Window`, so we
        // hold a `*ElementStates` pointer. `initInPlace` zeroes every slot
        // at the final heap address so no 128 KiB by-value copy crosses a
        // stack frame. Errdefer pairs the `allocator.create` so any later
        // `try` (e.g. `globals.setOwned`) unwinds without leaking the pool.
        const element_states = allocator.create(ElementStates) catch return error.OutOfMemory;
        element_states.initInPlace(allocator);
        errdefer {
            element_states.deinit();
            allocator.destroy(element_states);
        }

        var result: Self = .{
            .allocator = allocator,
            .io = io,
            .layout = layout_engine,
            // Both `Frame` slots are copied by value; each local's `owned`
            // flag is disarmed post-literal (like `resources.owned`) so a
            // later errdefer can't tear the pointees down out from under
            // `result.{next,rendered}_frame`.
            .next_frame = next_frame,
            .rendered_frame = rendered_frame,
            // `app: *App` is left at its `undefined` default; the caller
            // (`runtime/window_context.zig`) assigns it before any frame
            // runs. `debugger` registers into `globals` post-literal (so it
            // can `try` under the `errdefer` cleanup chain); `keymap` lives
            // on `app.globals`.
            .focus = FocusManager.init(allocator),
            // Single owned `resources` field; the heap pointers it carries
            // come through the by-value copy unchanged.
            .resources = resources,
            // `change_tracker` default-initialises (fixed-capacity, no
            // alloc), so it needs no entry here.
            .animations = AnimationStore.init(allocator, io),
            // Borrowed `*ElementStates` view onto the heap allocation above.
            // Ownership transfers here: `result` is the canonical owner and
            // `Window.deinit` frees it. The errdefer above is paired by the
            // disarm post-literal (see below).
            .element_states = element_states,
            .platform_window = platform_window,
            .width = @floatCast(platform_window.size.width),
            .height = @floatCast(platform_window.size.height),
            .scale_factor = @floatCast(platform_window.scale_factor),
            // Hover state — small, by-value default is fine.
            .hover = HoverState.init(),
            // Blur handler registry — by-value init is safe (no internal pointers).
            .blur_handlers = BlurHandlerRegistry.init(),
            // Cancel registry — same.
            .cancel_registry = CancelRegistry.init(),
            // Accessibility: filled in below by `initInPlace`. The bridge
            // dispatcher embeds a pointer into `result.a11y.platform_bridge`;
            // see `initOwnedPtr` for the version without the by-value copy
            // dangling-pointer caveat.
            .a11y = undefined,
            // `image_loader` is app-scoped: the caller
            // (`WindowContext.init`) calls
            // `app.bindImageLoader(window.resources.image_atlas)` after this
            // returns and `window.app` is wired.
        };
        // `result` is now the canonical owner of the heap atlases, so disarm
        // the local `resources.owned`: otherwise a later errdefer
        // (`globals.setOwned` failure) would tear them down out from under
        // `result` and double-free when the caller drops it.
        resources.owned = false;

        // Same disarm for both halves of the double buffer:
        // `result.{next,rendered}_frame` are now the canonical owners of the
        // four heap allocations, so the local copies' errdefers must not
        // fire on a later unwind.
        next_frame.owned = false;
        rendered_frame.owned = false;

        // Initialize accessibility subsystem in place. On macOS, the
        // bridge captures the NSWindow / NSView handles passed here; on
        // other platforms they are ignored.
        const window_obj = if (builtin.os.tag == .macos) platform_window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) platform_window.ns_view else null;
        result.a11y.initInPlace(window_obj, view_obj);

        // Per-window globals hold `Debugger` only (`Keymap` is on
        // `App.globals`). The owned `*Debugger` lives in
        // `result.globals.entries` and points at a stable heap address, so
        // the by-value copy when `result` moves into the caller is safe. No
        // `errdefer` follows this last `try`: the next statement is `return
        // result`, so no unwinding path past this point exists.
        try result.globals.setOwned(allocator, debugger_mod.Debugger, .{});

        return result;
    }

    /// Initialize Window in-place using out-pointer pattern.
    /// This avoids stack overflow on WASM where the Window struct (~400KB with a11y)
    /// would exceed the default stack size if returned by value.
    ///
    /// Usage:
    /// ```
    /// const window_ptr = try allocator.create(Window);
    /// try window_ptr.initOwnedPtr(allocator, window);
    /// ```
    /// Marked noinline to prevent stack accumulation in WASM builds.
    /// Without this, the compiler inlines all sub-functions creating a 2MB+ stack frame.
    pub noinline fn initOwnedPtr(self: *Self, allocator: std.mem.Allocator, platform_window: *PlatformWindow, font_config: FontConfig, io: std.Io) !void {
        // Create layout engine
        const layout_engine = allocator.create(LayoutEngine) catch return error.OutOfMemory;
        layout_engine.* = LayoutEngine.init(allocator);
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

        // Initialise the two-`Frame` double buffer in place. Each
        // `Frame.initOwnedInPlace` allocates a Scene + DispatchTree pair
        // into the named slot; the call is `noinline` so the WASM stack
        // budget stays bounded across the internal subsystems. `mem.swap` at
        // the frame boundary exchanges the two slots; both stay
        // `owned = true` across every swap, so `Window.deinit` tears down
        // both pairs.
        try self.next_frame.initOwnedInPlace(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer self.next_frame.deinit();

        try self.rendered_frame.initOwnedInPlace(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer self.rendered_frame.deinit();

        // Initialise shared rendering resources directly into
        // `self.resources` (no stack temp). `initOwnedInPlace` is `noinline`
        // so the WASM stack budget stays bounded across the internal
        // subsystems (TextSystem ~1.7MB, atlases hundreds of KB each).
        try self.resources.initOwnedInPlace(
            allocator,
            io,
            @floatCast(platform_window.scale_factor),
            .{
                .font_name = font_config.font_name,
                .font_size = font_config.font_size,
            },
        );
        errdefer self.resources.deinit();

        // Set up text measurement callback against the bundled text system.
        layout_engine.setMeasureTextFn(measureTextCallback, self.resources.text_system);

        // Field-by-field init avoids ~400KB stack temp from struct literal
        // Core resources
        self.allocator = allocator;
        self.io = io;
        self.layout = layout_engine;
        // Per-frame rendering state lives on the double buffer: build call
        // sites reach through `self.next_frame.*`, input hit-test sites
        // through `self.rendered_frame.dispatch`. Shared atlases are reached
        // through `self.resources.*`.
        self.platform_window = platform_window;

        // `self.app` is left `undefined` here; the caller
        // (`runtime/window_context.zig` on the WASM Ptr path) assigns it
        // after `initOwnedPtr` returns.
        self.focus = FocusManager.init(allocator);
        // This path is field-by-field init (no struct-literal defaults), so
        // `change_tracker` is assigned explicitly below.
        self.animations = AnimationStore.init(allocator, io);
        self.change_tracker = .{};

        // Heap-allocate the element-state pool and initialise it in place at
        // its final address: the WASM `*Ptr` paths exist precisely so
        // 128 KiB structs never live on the stack. `errdefer` pairs the
        // `allocator.create` so a later `try self.globals.setOwned(...)`
        // failure unwinds without leaking the pool.
        self.element_states = allocator.create(ElementStates) catch return error.OutOfMemory;
        self.element_states.initInPlace(allocator);
        errdefer {
            self.element_states.deinit();
            allocator.destroy(self.element_states);
        }

        // `globals` and `current_phase` start fresh. `self` is raw memory
        // here (caller did `allocator.create` without zeroing), so explicit
        // assignment is required — even default-valued fields would
        // otherwise retain garbage.
        self.globals = .{};
        self.current_phase = .none;

        // Scalar fields
        self.width = @floatCast(platform_window.size.width);
        self.height = @floatCast(platform_window.size.height);
        self.scale_factor = @floatCast(platform_window.scale_factor);
        self.frame_count = 0;
        self.needs_render = false;
        // `debugger` registered into `globals` below.

        // Pending/active drag state (re-init explicitly — `self` was raw memory)
        self.pending_drag = null;
        self.active_drag = null;
        self.drag_over_target = null;

        // Root state slots
        self.root_state_ptr = null;
        self.root_state_type_id = 0;

        // Deferred command queue
        self.deferred_commands = undefined;
        self.deferred_count = 0;

        // Hover, blur, cancel — every subsystem with internal arrays gets
        // an in-place init to avoid a stack temp. The `self` pointer is
        // already at its final heap address, so no fixup is needed later.
        self.hover.initInPlace();
        self.blur_handlers.initInPlace();
        self.cancel_registry.initInPlace();

        // Accessibility (initInPlace avoids ~350KB stack temp). The
        // bridge dispatcher captures `&self.a11y.platform_bridge`,
        // which is correct here because `self` is at its final heap
        // address.
        const window_obj = if (builtin.os.tag == .macos) platform_window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) platform_window.ns_view else null;
        self.a11y.initInPlace(window_obj, view_obj);

        // `image_loader` is app-scoped: the caller binds it after this
        // returns and `window.app` is wired.

        // Per-window globals hold `Debugger` only (`Keymap` is on
        // `App.globals`). `self` is at its final heap address, so `setOwned`
        // writes its bookkeeping directly. No `errdefer` after this last
        // `try`: the function returns immediately after.
        try self.globals.setOwned(allocator, debugger_mod.Debugger, .{});
    }

    /// Initialize Window with shared resources (text system, SVG atlas, image atlas).
    /// Used by MultiWindowApp to share expensive resources across windows.
    /// The caller retains ownership of the shared resources.
    ///
    /// Takes a single `*const AppResources` borrowed-or-owned view from the
    /// parent. The caller retains ownership of the pointee — every `Window`
    /// produced this way embeds an `owned = false` borrowed view, so
    /// `Window.deinit` is a no-op for the shared atlases.
    pub fn initWithSharedResources(
        allocator: std.mem.Allocator,
        platform_window: *PlatformWindow,
        shared_resources: *const AppResources,
        io: std.Io,
    ) !Self {
        // Assertions: validate inputs through the bundle (every later
        // expression indexes the same three slots).
        std.debug.assert(@intFromPtr(shared_resources) != 0);
        std.debug.assert(@intFromPtr(shared_resources.text_system) != 0);
        std.debug.assert(@intFromPtr(shared_resources.svg_atlas) != 0);
        std.debug.assert(@intFromPtr(shared_resources.image_atlas) != 0);

        // Create layout engine (owned)
        const layout_engine = allocator.create(LayoutEngine) catch return error.OutOfMemory;
        layout_engine.* = LayoutEngine.init(allocator);
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

        // Allocate the two-`Frame` double buffer (owned per-window even in
        // multi-window mode: the scene + dispatch tree are per-window state
        // and cannot be shared without breaking hit-testing). Both slots
        // stay `owned = true` across the `mem.swap` at the frame boundary;
        // the `owned = false` disarms post-literal mirror `resources.owned`.
        var next_frame = try Frame.initOwned(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer next_frame.deinit();

        var rendered_frame = try Frame.initOwned(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer rendered_frame.deinit();

        // Set up text measurement callback using shared text system
        layout_engine.setMeasureTextFn(measureTextCallback, shared_resources.text_system);

        // Element-state pool is per-window even in multi-window mode (the
        // keys are per-window `LayoutId` hashes; sharing one pool across
        // windows would conflate state for unrelated elements). The
        // `AppResources` triplet is borrowed, but `element_states` is always
        // owned by this `Window`.
        const element_states = allocator.create(ElementStates) catch return error.OutOfMemory;
        element_states.initInPlace(allocator);
        errdefer {
            element_states.deinit();
            allocator.destroy(element_states);
        }

        var result: Self = .{
            .allocator = allocator,
            .io = io,
            .layout = layout_engine,
            // Both `Frame` slots are copied by value; each local's `owned`
            // flag is disarmed post-literal so a later errdefer can't tear
            // the pointees down out from under `result.{next,rendered}_frame`.
            .next_frame = next_frame,
            .rendered_frame = rendered_frame,
            // `app: *App` is set by the caller post-init. `debugger`
            // registers into `globals` below; `keymap` lives on
            // `app.globals`.
            .focus = FocusManager.init(allocator),
            // Borrowed `AppResources` view; the parent owns the pointees, so
            // `AppResources.deinit` is a no-op for `owned = false`. The three
            // pointer fields are copied through unchanged (same heap
            // addresses as `shared_resources.*`).
            .resources = AppResources.borrowed(
                allocator,
                io,
                shared_resources.text_system,
                shared_resources.svg_atlas,
                shared_resources.image_atlas,
            ),
            .animations = AnimationStore.init(allocator, io),
            // Owned `*ElementStates`; see `initOwned` for the heap-allocation
            // rationale (128 KiB > WASM stack).
            .element_states = element_states,
            .platform_window = platform_window,
            .width = @floatCast(platform_window.size.width),
            .height = @floatCast(platform_window.size.height),
            .scale_factor = @floatCast(platform_window.scale_factor),
            .hover = HoverState.init(),
            .blur_handlers = BlurHandlerRegistry.init(),
            .cancel_registry = CancelRegistry.init(),
            .a11y = undefined,
            // `image_loader` is app-scoped: in multi-window mode the parent
            // `multi_window_app::App.init` has already bound it against the
            // same shared atlas every window's borrowed `AppResources`
            // points at; this function does NOT re-bind.
        };

        // Disarm both local `owned` flags now that
        // `result.{next,rendered}_frame` are the canonical owners (prevents
        // a double-free if a later `try` unwinds via either local's
        // errdefer).
        next_frame.owned = false;
        rendered_frame.owned = false;

        // Initialize platform-specific accessibility bridge
        const window_obj = if (builtin.os.tag == .macos) platform_window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) platform_window.ns_view else null;
        result.a11y.initInPlace(window_obj, view_obj);

        // `image_loader` is app-scoped: the shared loader on `App` (bound
        // once by `multi_window_app::App.init` against this same atlas)
        // handles every window's URL fetches; this function does NOT bind.

        // Per-window globals hold `Debugger` only (`Keymap` is on
        // `app.globals`). Every window owns its own debugger so its overlay
        // quads / frame timing / selected layout id stay scoped to its own
        // scene. No `errdefer` after this last `try`: the function returns
        // immediately after.
        try result.globals.setOwned(allocator, debugger_mod.Debugger, .{});

        return result;
    }

    /// Initialize Window in-place with shared resources.
    /// Used by MultiWindowApp on WASM to avoid stack overflow.
    /// Marked noinline to prevent stack accumulation.
    ///
    /// Takes `*const AppResources` instead of three separate pointers; see
    /// `initWithSharedResources` above.
    pub noinline fn initWithSharedResourcesPtr(
        self: *Self,
        allocator: std.mem.Allocator,
        platform_window: *PlatformWindow,
        shared_resources: *const AppResources,
        io: std.Io,
    ) !void {
        // Assertions: validate inputs.
        std.debug.assert(@intFromPtr(shared_resources) != 0);
        std.debug.assert(@intFromPtr(shared_resources.text_system) != 0);
        std.debug.assert(@intFromPtr(shared_resources.svg_atlas) != 0);
        std.debug.assert(@intFromPtr(shared_resources.image_atlas) != 0);

        // Create layout engine (owned)
        const layout_engine = allocator.create(LayoutEngine) catch return error.OutOfMemory;
        layout_engine.* = LayoutEngine.init(allocator);
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

        // Initialise the two-`Frame` double buffer in place. The scene +
        // dispatch tree are per-window state and remain owned per-window
        // even in multi-window mode (only `AppResources` is borrowed); both
        // slots carry their own owning Scene + DispatchTree pair.
        try self.next_frame.initOwnedInPlace(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer self.next_frame.deinit();

        try self.rendered_frame.initOwnedInPlace(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer self.rendered_frame.deinit();

        // Set up text measurement callback using shared text system
        layout_engine.setMeasureTextFn(measureTextCallback, shared_resources.text_system);

        // Field-by-field init avoids stack temp from struct literal
        self.allocator = allocator;
        self.io = io;
        self.layout = layout_engine;

        // Borrowed `AppResources` view; the parent owns the pointees.
        // By-value init is safe — the struct only carries the three pointers
        // plus the `owned = false` flag, no internal self-references.
        self.resources = AppResources.borrowed(
            allocator,
            io,
            shared_resources.text_system,
            shared_resources.svg_atlas,
            shared_resources.image_atlas,
        );

        self.platform_window = platform_window;

        // `self.app` is left `undefined` here; the caller assigns it
        // post-init (see `initOwnedPtr`).
        self.focus = FocusManager.init(allocator);
        self.animations = AnimationStore.init(allocator, io);
        self.change_tracker = .{};

        // Element-state pool, per-window even in multi-window mode (see
        // `initWithSharedResources`). The WASM `*Ptr` paths exist precisely
        // so 128 KiB structs don't live on the stack; `initInPlace` writes
        // at the final heap address.
        self.element_states = allocator.create(ElementStates) catch return error.OutOfMemory;
        self.element_states.initInPlace(allocator);
        errdefer {
            self.element_states.deinit();
            allocator.destroy(self.element_states);
        }

        // `globals` and `current_phase` start fresh (`self` is raw memory).
        self.globals = .{};
        self.current_phase = .none;

        // Scalar fields
        self.width = @floatCast(platform_window.size.width);
        self.height = @floatCast(platform_window.size.height);
        self.scale_factor = @floatCast(platform_window.scale_factor);
        self.frame_count = 0;
        self.needs_render = false;
        // `debugger` registered into `globals` below.

        // Pending/active drag state
        self.pending_drag = null;
        self.active_drag = null;
        self.drag_over_target = null;

        // Root state slots
        self.root_state_ptr = null;
        self.root_state_type_id = 0;

        // Deferred command queue
        self.deferred_commands = undefined;
        self.deferred_count = 0;

        // Hover, blur, cancel subsystems (in-place to avoid stack temps)
        self.hover.initInPlace();
        self.blur_handlers.initInPlace();
        self.cancel_registry.initInPlace();

        // Accessibility (initInPlace avoids ~350KB stack temp)
        const window_obj = if (builtin.os.tag == .macos) platform_window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) platform_window.ns_view else null;
        self.a11y.initInPlace(window_obj, view_obj);

        // `image_loader` is app-scoped: the shared loader on `App` (bound
        // once by `multi_window_app::App.init` against this same atlas)
        // handles every window's URL fetches; this function does NOT bind.

        // Per-window globals hold `Debugger` only (`Keymap` is on
        // `app.globals`). No `errdefer` after this last `try`: the function
        // returns immediately after.
        try self.globals.setOwned(allocator, debugger_mod.Debugger, .{});
    }

    pub fn deinit(self: *Self) void {
        // `image_loader` teardown is `App`'s responsibility (closing the
        // result queue and cancelling the fetch group). The upstream owner
        // tears the `App` down *after* every `Window.deinit` has run, which
        // is the correct order: background fetches need a live result queue
        // to unwind against during the fetch group's cancel-point check.

        // Cancel all registered cancel groups before any teardown.
        // Blocking is acceptable — we are shutting down.
        self.cancel_registry.cancelAll(self.io);

        // Clean up accessibility subsystem (deinit drops the bridge).
        self.a11y.deinit();

        // Blur handlers use fixed-capacity storage, no cleanup needed

        // `change_tracker` is fixed-capacity with no allocation, so it has no
        // `deinit` to call.
        self.animations.deinit();

        // Tear down the unified element-state pool. `ElementStates.deinit`
        // walks every populated slot and runs its type-erased deinit thunk
        // before freeing each payload. Free the pool's own heap allocation
        // last (`destroy`) — `deinit` only tears down its entries, not the
        // table backing itself.
        self.element_states.deinit();
        self.allocator.destroy(self.element_states);

        self.focus.deinit();
        // The borrowed `*App` is owned upstream; the owner calls `App.deinit`
        // after every `Window.deinit` has run. `Window.deinit` deliberately
        // does not touch `self.app` — that would be a use-after-free in the
        // multi-window case where one `App` outlives many `Window`s.

        // Single teardown call covers text_system + svg_atlas + image_atlas.
        // `AppResources.deinit` is a no-op when borrowed (multi-window mode),
        // otherwise frees the three subsystems in image → svg → text order.
        self.resources.deinit();

        // Teardown covers `Debugger` only (the single per-window owned
        // global); `Keymap.deinit` runs from `App.deinit`. The thunk built
        // at `setOwned` time picks the right shape per type so each global
        // teardown matches its declared `deinit`.
        self.globals.deinit(self.allocator);

        // Tear down the two-`Frame` double buffer. Each `Frame.deinit` frees
        // its Scene + DispatchTree pair; both slots carry `owned = true`
        // regardless of how many `mem.swap` calls have run (the swap is a
        // physical struct exchange between two owning slots, not a hand-off
        // through `Frame.borrowed`). Order between the slots is irrelevant
        // (they share no inter-pointer references).
        self.next_frame.deinit();
        self.rendered_frame.deinit();

        // `layout` is always owned (no init path leaves it borrowed), so
        // free unconditionally.
        self.layout.deinit();
        self.allocator.destroy(self.layout);
    }

    // =========================================================================
    // Frame Lifecycle
    // =========================================================================

    /// Internal helper: advance `current_phase` to `next`, asserting
    /// the transition is one of the four legal advances
    /// (`none → prepaint → paint → focus → none`). Centralised so the
    /// frame-lifecycle methods read as a phase ladder rather than
    /// repeating the assert + assignment pair four times.
    fn advancePhase(self: *Self, next: DrawPhase) void {
        draw_phase_mod.assertAdvance(self.current_phase, next);
        self.current_phase = next;
    }

    /// Read-only accessor for diagnostics / tests.
    pub fn drawPhase(self: *const Self) DrawPhase {
        return self.current_phase;
    }

    /// Typed accessor for the keymap global, which lives on `App.globals`;
    /// this forwards to `self.app.keymap()` so call sites
    /// (`window.keymap().bind(...)`) don't reach through `*App` themselves.
    /// Panics if the parent `App` was never `init*`'d (a framework bug).
    pub fn keymap(self: *Self) *Keymap {
        return self.app.keymap();
    }

    /// Typed accessor for the debugger global. Same panic contract as
    /// `keymap()`.
    pub fn debugger(self: *Self) *debugger_mod.Debugger {
        return self.globals.get(debugger_mod.Debugger) orelse {
            std.debug.panic("Window.debugger(): no Debugger registered in globals (init* did not run?)", .{});
        };
    }

    /// Call at the start of each frame before building UI
    ///
    /// Per-tick app-scoped work (image-loader drain, entity-observation
    /// clear) is NOT done here: the runtime frame driver
    /// (`runtime/frame.zig::renderFrameImpl`) calls `self.app.beginFrame()`
    /// exactly once per tick before this method, so the loader has already
    /// drained into the atlas and stale observations are cleared. Doing it
    /// per-window would be redundant across N windows and would break
    /// `entities.beginFrame`'s non-idempotent contract.
    pub fn beginFrame(self: *Self) void {
        // First thing the frame does: advance into prepaint. `assertAdvance`
        // checks the previous phase was `.none`, so back-to-back
        // `beginFrame` calls without an intervening `finalizeFrame` fail
        // loudly here rather than corrupting the next frame's state.
        self.advancePhase(.prepaint);

        // Start profiler frame timing
        self.debugger().beginFrame(self.io);

        self.frame_count += 1;
        // `change_tracker` carries no per-frame state to reset (the diff is
        // keyed by call-site comptime hash, not by frame).
        self.animations.beginFrame();
        self.focus.beginFrame();
        self.resources.image_atlas.beginFrame();

        // `self.app.beginFrame()` is driven once per tick by
        // `runtime/frame.zig::renderFrameImpl`, not here: running the
        // app-scoped begin pair through every per-window forwarder would
        // discard earlier-this-tick frame observations. The driver upholds
        // the ordering invariant that `App.beginFrame` runs after every
        // window's atlas reset (so freshly-decoded pixels land post-reset)
        // and before any window observes entities (so the clear of last-tick
        // observations cannot race with this-tick observations).

        // Update cached window dimensions
        if (self.platform_window) |w| {
            self.width = @floatCast(w.size.width);
            self.height = @floatCast(w.size.height);
            self.scale_factor = @floatCast(w.scale_factor);
        }

        // Sync scale factor to text system for correct glyph rasterization
        // self.resources.text_system.setScaleFactor(self.scale_factor);

        // The build target is `next_frame.scene`. The end-of-frame
        // `mem.swap` already cleared this slot post-swap, so the clear is
        // redundant after the first frame; it covers frame 0 (no prior swap)
        // and defends a caller of `beginFrame` outside `renderFrameImpl`
        // against stale primitives.
        self.next_frame.scene.clear();

        // Connect render stats to scene for profiler tracking
        render_stats.beginFrame();
        self.next_frame.scene.setStats(&render_stats.frame_stats);

        // Update viewport only on resize
        if (self.next_frame.scene.viewport_width != self.width or self.next_frame.scene.viewport_height != self.height) {
            self.next_frame.scene.setViewport(self.width, self.height);
        }

        // Begin layout pass (timer moved to endFrame to cover only actual layout compute)
        self.layout.beginFrame(self.width, self.height);

        // Hover: clear hover_changed latch so a downstream observer
        // that didn't react in the previous frame won't see a stale `true`.
        self.hover.beginFrame();

        // Clear drag-over target (recalculated each frame during drag)
        self.drag_over_target = null;

        // Accessibility: periodic screen reader poll + tree begin
        // (a11y subsystem owns the counter and the enabled latch).
        self.a11y.beginFrame();
    }

    /// Call at the end of each frame after building UI
    /// Returns the render commands for the frame
    ///
    /// Per-tick app-scoped finalisation is NOT done here: the runtime frame
    /// driver (`runtime/frame.zig::renderFrameImpl`) calls
    /// `self.app.endFrame()` exactly once per tick after every window's
    /// `Window.endFrame` has returned, keeping the begin/end pair together
    /// at the layer the work belongs to.
    pub fn endFrame(self: *Self) ![]const RenderCommand {
        self.animations.endFrame();
        self.focus.endFrame();

        // `self.app.endFrame()` is driven once per tick by
        // `runtime/frame.zig::renderFrameImpl`, mirroring the `beginFrame`
        // lift. It is currently a no-op; the per-tick driver gives future
        // batching a single hook rather than one firing per window.

        // Request another frame if animations are running
        if (self.hasActiveAnimations()) {
            self.requestRender();
        }

        // End layout and get render commands — time only the actual layout compute
        self.debugger().beginLayout(self.io);
        const commands = try self.layout.endFrame();
        self.debugger().endLayout(self.io);

        // Accessibility: finalize tree, sync bounds, push to platform
        // (zero cost when disabled — the subsystem early-outs).
        self.a11y.endFrame(self.layout);

        // Layout has run; we are now in the paint phase. The caller draws
        // the returned commands into the scene under this phase. Advancing
        // here keeps the phase machine in one place.
        self.advancePhase(.paint);

        return commands;
    }

    /// Finalize frame timing (call after all rendering is complete)
    pub fn finalizeFrame(self: *Self) void {
        // Paint is done; walk through `.focus` (the post-paint focus / a11y
        // finalisation surface) back to `.none`. We advance through `.focus`
        // even with no work scheduled there because `assertAdvance` requires
        // monotone progression: `paint → none` is not a legal direct edge.
        self.advancePhase(.focus);
        self.debugger().endFrame(self.io, &render_stats.frame_stats);
        self.advancePhase(.none);
    }

    /// Check if any animations are running (call after endFrame)
    pub fn hasActiveAnimations(self: *const Self) bool {
        return self.animations.hasActiveAnimations();
    }

    // =========================================================================
    // Hover State — forwarders to `hover` (see `hover.zig`)
    // =========================================================================

    /// Update hover state based on mouse position.
    /// Call this on mouse_moved events. Returns true if hover state
    /// changed (requires re-render).
    ///
    /// Reads through `rendered_frame.dispatch` (the previously-built tree,
    /// alive across the input gap between frames). Input events arrive after
    /// frame N's swap and before frame N+1's build, so the dispatch tree the
    /// user is currently *seeing* lives in `rendered_frame`, with bounds
    /// already synced from the layout pass that built it.
    pub fn updateHover(self: *Self, x: f32, y: f32) bool {
        return self.hover.update(self.rendered_frame.dispatch, x, y);
    }

    /// Check if a specific layout element is currently hovered.
    pub fn isHovered(self: *const Self, layout_id: u32) bool {
        return self.hover.isHovered(layout_id);
    }

    /// Check if a layout element (by LayoutId) is currently hovered.
    pub fn isLayoutIdHovered(self: *const Self, id: LayoutId) bool {
        return self.hover.isLayoutIdHovered(id);
    }

    /// Check if the hovered element is the given layout_id OR a descendant of it.
    /// Useful for tooltips where we want to show when hovering any child element.
    pub fn isHoveredOrDescendant(self: *const Self, layout_id: u32) bool {
        return self.hover.isHoveredOrDescendant(layout_id);
    }

    /// Clear hover state (e.g., when mouse exits window).
    pub fn clearHover(self: *Self) void {
        self.hover.clear();
    }

    // =========================================================================
    // Layout Pass-through (convenience methods)
    // =========================================================================

    /// Open a layout element (container).
    ///
    /// Must be called in the `.prepaint` phase: layout is declared while the
    /// user's `render_fn` runs. Calling this after `endFrame` (which
    /// advances to `.paint`) would silently corrupt the next frame's tree.
    pub fn openElement(self: *Self, decl: ElementDeclaration) !void {
        draw_phase_mod.assertPhase(self.current_phase, .prepaint);
        try self.layout.openElement(decl);
    }

    /// Close the current layout element.
    ///
    /// Same `.prepaint` invariant as `openElement`. Pairing the assertion at
    /// both ends of the open/close bracket catches a stray `closeElement`
    /// outside the user render, which would unbalance the layout stack.
    pub fn closeElement(self: *Self) void {
        draw_phase_mod.assertPhase(self.current_phase, .prepaint);
        self.layout.closeElement();
    }

    /// Add a text element.
    ///
    /// `.prepaint` only: text declarations are part of the element tree
    /// built during the user render.
    pub fn text(self: *Self, content: []const u8, config: TextConfig) !void {
        draw_phase_mod.assertPhase(self.current_phase, .prepaint);
        try self.layout.text(content, config);
    }

    // =========================================================================
    // Widget Access — via `window.element_states.get(T, id)`
    // =========================================================================
    //
    // Callers reach engine state through
    // `window.element_states.get(EngineType, layout_id.id)` and trigger
    // focus via the generic `window.focusWidget(id)` below (which routes
    // through the `Focusable` vtable on `FocusManager` — no widget-type
    // switch). Adding a focusable widget touches only `widgets/`: the widget
    // exposes `pub fn focusable(self) Focusable` and the builder registers
    // that vtable on its `FocusHandle`; `Window` doesn't learn the type.

    /// Look up retained engine state of type `S` by string `id`, or `null`
    /// if no widget with that id has mounted yet. Generic over `S` so no
    /// concrete widget-state type leaks into `Window` (see the module note
    /// at the top of this file): the caller names the type at the call site,
    /// e.g. `g.widgetState(gooey.widgets.TextInputState, "draft")`.
    ///
    /// This is the string-keyed twin of the raw `window.element_states.get`
    /// pool call — it folds in the `LayoutId.fromString(id).id` hashing so
    /// `*Window`-shaped command handlers don't hand-roll it. `Cx.textField`
    /// and friends are the typed sugar over this same path for `*Cx`
    /// contexts; both land on the same pool lookup.
    pub fn widgetState(self: *Self, comptime S: type, id: []const u8) ?*S {
        std.debug.assert(id.len > 0);
        const id_hash: u64 = @as(u64, LayoutId.fromString(id).id);
        // A real string id never collides with `LayoutId.none` (id 0),
        // the reserved null/invalid sentinel — mirrors the `*ById`
        // accessors' precondition in `cx/element_states.zig`.
        std.debug.assert(id_hash != 0);
        return self.element_states.get(S, id_hash);
    }

    /// Focus a widget by string ID. Generic over widget type — the
    /// `FocusManager` uses the `Focusable` vtable registered on the matching
    /// `FocusHandle` to drive `blur()` on the previously focused widget and
    /// `focus()` on the new one.
    pub fn focusWidget(self: *Self, id: []const u8) void {
        // Invoke any registered blur handler for the currently-focused
        // widget before the trait flips its `focused` flag, preserving
        // on-blur semantics.
        self.invokeBlurHandlerForFocusedWidget();
        self.focus.focusWidget(id);
        // Reset the transition latch so subsequent focus changes within
        // the same frame can fire their handlers too.
        self.blur_handlers.endTransition();
        self.requestRender();
    }

    // =========================================================================
    // Hit Testing & Bounds
    // =========================================================================

    /// Get bounding box for a layout element by ID hash
    pub fn getBoundingBox(self: *Self, id: u32) ?BoundingBox {
        return self.layout.getBoundingBox(id);
    }

    /// Get bounding box by LayoutId
    pub fn getBounds(self: *Self, id: LayoutId) ?BoundingBox {
        return self.layout.getBoundingBox(id.id);
    }

    // =========================================================================
    // Focus Management
    // =========================================================================

    /// Register a focusable element for tab navigation
    pub fn registerFocusable(self: *Self, id: []const u8, tab_index: i32, tab_stop: bool) void {
        self.focus.register(FocusHandle.init(id).tabIndex(tab_index).tabStop(tab_stop));
    }

    /// Focus a specific element by ID. Routes through the `Focusable`
    /// trait on the matching `FocusHandle` — see `focusWidget`.
    pub fn focusElement(self: *Self, id: []const u8) void {
        self.invokeBlurHandlerForFocusedWidget();
        self.focus.focusByName(id);
        self.blur_handlers.endTransition();
        self.requestRender();
    }

    /// Move focus to next element in tab order. The `FocusManager`
    /// drives the underlying widget's `blur()` / `focus()` through the
    /// `Focusable` vtable; `Window` only owns the blur-handler dispatch.
    pub fn focusNext(self: *Self) void {
        self.invokeBlurHandlerForFocusedWidget();
        self.focus.focusNext();
        self.blur_handlers.endTransition();
        self.requestRender();
    }

    /// Move focus to previous element in tab order.
    pub fn focusPrev(self: *Self) void {
        self.invokeBlurHandlerForFocusedWidget();
        self.focus.focusPrev();
        self.blur_handlers.endTransition();
        self.requestRender();
    }

    /// Clear all focus. The `FocusManager` blurs the focused widget
    /// (if any) through its `Focusable` vtable — no walk over per-type
    /// widget maps required.
    pub fn blurAll(self: *Self) void {
        self.invokeBlurHandlerForFocusedWidget();
        self.focus.blur();
        self.blur_handlers.endTransition();
        self.requestRender();
    }

    /// Check if element is focused
    pub fn isElementFocused(self: *Self, id: []const u8) bool {
        return self.focus.isFocusedByName(id);
    }

    // =========================================================================
    // Blur Handler Management — forwarders to `blur_handlers`
    // =========================================================================
    //
    // Body lives in `blur_handlers.zig`. The handler registry is a generic
    // `SubscriberSet` instance; the wrappers here preserve the call surface
    // used by `runtime/frame.zig` (`window.registerBlurHandler` /
    // `window.clearBlurHandlers`).

    /// Register a blur handler for a text field ID.
    /// Called during frame rendering to register handlers from pending items.
    /// Uses fixed-capacity storage — logs warning if limit exceeded.
    pub fn registerBlurHandler(self: *Self, id: []const u8, handler: HandlerRef) void {
        self.blur_handlers.register(id, handler);
    }

    /// Clear all registered blur handlers.
    /// Called at the start of each frame before processing pending items.
    pub fn clearBlurHandlers(self: *Self) void {
        self.blur_handlers.clearAll();
    }

    /// Invoke blur handlers for any currently focused text widgets.
    /// Called before focus changes to notify the old focused element.
    ///
    /// The transition guard (in `BlurHandlerRegistry`) prevents double
    /// invocation within a single focus transition. The guard is reset
    /// by `endTransition()` from each focus-changing public method
    /// (`focusWidget`, `focusElement`, `focusNext`, `focusPrev`,
    /// `blurAll`) after a complete transition, allowing multiple focus
    /// changes per frame.
    ///
    /// We ask the registry for `getHandler(id)` against the focus manager's
    /// tracked `string_id` and dispatch — `FocusManager` knows the focused
    /// element's `FocusId` directly.
    fn invokeBlurHandlerForFocusedWidget(self: *Self) void {
        // Guard against double invocation within a single focus transition.
        if (!self.blur_handlers.beginTransition()) return;

        // Find the focused handle's string_id — that's the registry key.
        // `getFocusedHandle` returns the handle from the current frame's
        // `focus_order`; if the focused element wasn't re-registered
        // this frame there's nothing for the handler to fire against,
        // and the registry would not have stored a handler for it
        // anyway (handlers are re-registered each frame alongside the
        // widget primitive).
        const handle = self.focus.getFocusedHandle() orelse return;
        if (self.blur_handlers.getHandler(handle.string_id)) |handler| {
            handler.invoke(self);
        }
    }

    // =========================================================================
    // Entity Operations
    // =========================================================================

    /// Create a new entity. Forwards to the shared `self.app.entities`.
    pub fn createEntity(self: *Self, comptime T: type, value: T) !entity_mod.Entity(T) {
        return self.app.entities.new(T, value);
    }

    /// Read an entity's data. Forwards to `self.app.entities`.
    pub fn readEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*const T {
        return self.app.entities.read(T, entity);
    }

    /// Get mutable access to an entity. Forwards to `self.app.entities`.
    pub fn writeEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*T {
        return self.app.entities.write(T, entity);
    }

    /// Process entity notifications (called during frame). Forwards to
    /// `self.app.entities`.
    pub fn processEntityNotifications(self: *Self) bool {
        return self.app.entities.processNotifications();
    }

    /// Get the entity map: the shared `App.entities` borrowed via
    /// `self.app`. Every window borrowing the same `*App` returns the same
    /// pointer, which is the property cross-window observation needs.
    pub fn getEntities(self: *Self) *EntityMap {
        return &self.app.entities;
    }

    // =========================================================================
    // Drag & Drop
    // =========================================================================

    /// Start a pending drag (called on mouse_down over draggable element)
    /// Drag activates when cursor moves > DRAG_THRESHOLD pixels
    pub fn startPendingDrag(
        self: *Self,
        comptime T: type,
        value: *T,
        start_pos: Point(f32),
        source_id: ?u32,
    ) void {
        std.debug.assert(self.active_drag == null); // One drag at a time
        self.pending_drag = .{
            .value_ptr = value,
            .type_id = drag_mod.dragTypeId(T),
            .start_position = start_pos,
            .source_layout_id = source_id,
        };
    }

    /// Check if there's an active drag of the given type
    pub fn hasDragOfType(self: *const Self, comptime T: type) bool {
        if (self.active_drag) |drag| {
            return drag.type_id == drag_mod.dragTypeId(T);
        }
        return false;
    }

    /// Get active drag state (if any)
    pub fn getActiveDrag(self: *const Self) ?*const drag_mod.DragState {
        if (self.active_drag) |*drag| return drag;
        return null;
    }

    /// Cancel any active or pending drag
    pub fn cancelDrag(self: *Self) void {
        self.active_drag = null;
        self.pending_drag = null;
        self.drag_over_target = null;
    }

    /// Check if a layout ID is the current drag-over target
    pub fn isDragOverTarget(self: *const Self, layout_id: u32) bool {
        if (self.drag_over_target) |target| {
            return target == layout_id;
        }
        return false;
    }

    /// Check if element is being dragged (for source styling)
    pub fn isDragSource(self: *const Self, layout_id: u32) bool {
        if (self.active_drag) |drag| {
            if (drag.source_layout_id) |src| return src == layout_id;
        }
        return false;
    }

    // =========================================================================
    // Application Lifecycle
    // =========================================================================

    /// Quit the application.
    ///
    /// Portable across all platforms:
    /// - macOS: calls NSApp terminate:
    /// - Linux: signals the platform event loop to stop
    /// - WASM: no-op (browser tabs can't be closed programmatically)
    ///
    /// Use from a `command` handler:
    /// ```zig
    /// fn quitApp(_: *AppState, g: *Window) void {
    ///     g.quit();
    /// }
    /// // In render:
    /// Button{ .on_click_handler = cx.command(AppState.quitApp) }
    /// ```
    pub fn quit(self: *Self) void {
        if (comptime platform.is_wasm) {
            // No-op on web - can't quit browser
        } else if (comptime platform.is_linux) {
            if (self.platform_window) |w| {
                w.closed = true;
                w.platform.quit();
            } else {
                std.process.exit(0);
            }
        } else {
            // macOS: call NSApp terminate:
            const objc = @import("objc");
            const NSApp = objc.getClass("NSApplication") orelse return;
            const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
            app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
        }
    }

    // =========================================================================
    // Render Control
    // =========================================================================

    /// Change the font at runtime. Clears glyph and shape caches.
    /// Triggers a re-render so the new font takes effect immediately.
    pub fn setFont(self: *Self, name: []const u8, size: f32) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(size > 0 and size < 1000);

        try self.resources.text_system.loadFont(name, size);
        self.requestRender();
    }

    /// Mark that a re-render is needed
    pub fn requestRender(self: *Self) void {
        self.needs_render = true;
        if (self.platform_window) |w| {
            w.requestRender();
        }
    }

    /// Set the window appearance (light or dark mode)
    /// This affects the titlebar text color and other system UI elements (macOS)
    pub fn setAppearance(self: *Self, dark: bool) void {
        if (self.platform_window) |w| {
            w.setAppearance(dark);
        }
    }

    /// Check and clear the needs_render flag
    pub fn checkAndClearRenderFlag(self: *Self) bool {
        const result = self.needs_render;
        self.needs_render = false;
        return result;
    }

    /// Finish the scene after rendering.
    ///
    /// Finalises the build target (`next_frame.scene`). Called from
    /// `runtime/frame.zig::renderFrameImpl` *before* the end-of-frame
    /// `mem.swap` rotates the just-built scene into the `rendered_frame`
    /// slot for GPU presentation.
    pub fn finishScene(self: *Self) void {
        self.next_frame.scene.finish();
    }

    // =========================================================================
    // Resource Access
    // =========================================================================

    /// Returns the build-target `Scene` (`next_frame.scene`), the slot every
    /// render-pipeline call site writes into during the current tick.
    /// Callers that need the *currently-displayed* scene (e.g. read-back for
    /// a screenshot, debug inspection) should reach through
    /// `window.rendered_frame.scene` directly.
    pub fn getScene(self: *Self) *Scene {
        return self.next_frame.scene;
    }

    pub fn getTextSystem(self: *Self) *TextSystem {
        return self.resources.text_system;
    }

    pub fn getLayout(self: *Self) *LayoutEngine {
        return self.layout;
    }

    /// Get the OS-level window handle. Named `getPlatformWindow` to
    /// disambiguate from the framework-level `Window` struct.
    pub fn getPlatformWindow(self: *Self) ?*PlatformWindow {
        return self.platform_window;
    }

    /// Set the accent color uniform for custom shaders
    /// The alpha channel can be used as a mode selector
    pub fn setAccentColor(self: *Window, r: f32, g: f32, b: f32, a: f32) void {
        if (self.platform_window) |w| {
            if (w.renderer.getPostProcess()) |pp| {
                pp.uniforms.accent_color = .{ r, g, b, a };
            }
        }
    }

    // =========================================================================
    // Accessibility — forwarders to `a11y` (see `a11y_system.zig`)
    // =========================================================================

    /// Check if accessibility is currently active (screen reader detected)
    pub fn isA11yEnabled(self: *const Self) bool {
        return self.a11y.isEnabled();
    }

    /// Force enable accessibility (for testing/debugging)
    pub fn enableA11y(self: *Self) void {
        self.a11y.forceEnable();
    }

    /// Force disable accessibility
    pub fn disableA11y(self: *Self) void {
        self.a11y.forceDisable();
    }

    /// Get a mutable reference to the accessibility tree
    /// Only valid during frame (between beginFrame/endFrame)
    pub fn getA11yTree(self: *Self) *a11y.Tree {
        return self.a11y.getTree();
    }

    /// Announce a message to screen readers
    /// Convenience wrapper for a11y.announce()
    pub fn announce(self: *Self, message: []const u8, priority: a11y.Live) void {
        self.a11y.announce(message, priority);
    }
};

fn measureTextCallback(
    text_content: []const u8,
    _: u16, // font_id (future use)
    font_size: u16,
    _: ?f32, // max_width
    user_data: ?*anyopaque,
) TextMeasurement {
    if (user_data) |ptr| {
        const text_system: *TextSystem = @ptrCast(@alignCast(ptr));
        const metrics = text_system.getMetrics() orelse return .{ .width = 0, .height = 20 };

        // Scale factor: requested size / base font size
        const requested: f32 = @floatFromInt(font_size);

        // Assertions: validate font size values
        std.debug.assert(requested > 0);
        std.debug.assert(metrics.point_size > 0);

        const scale = requested / metrics.point_size;

        // Assertion: scale must be positive
        std.debug.assert(scale > 0);

        const base_width = text_system.measureText(text_content) catch 0;
        return .{
            .width = base_width * scale,
            .height = metrics.line_height * scale,
        };
    }
    return .{
        .width = @as(f32, @floatFromInt(text_content.len)) * 10,
        .height = 20,
    };
}

// =============================================================================
// Tests
// =============================================================================
//
// These tests cover the deferred-command queue. They construct a minimal
// `Window` via field-by-field init, leaving every resource pointer at
// `undefined` — the deferred-command path reads only `deferred_commands`,
// `deferred_count`, `root_state_*`, `needs_render`, and `platform_window`,
// so the path is exercised without standing up a full UI stack. Hover /
// blur / cancel / a11y subsystems are unit-tested in their own modules.

const testing = std.testing;

/// Build a stub `Window` for deferred-command tests. Resources stay
/// `undefined` because the tested path does not touch them; `window`
/// is `null` so `requestRender` is a no-op.
fn testWindow() Window {
    return .{
        .allocator = testing.allocator,
        .io = undefined,
        .layout = undefined,
        // The `next_frame` / `rendered_frame` defaults keep this fixture
        // compiling; the deferred-command path never reaches through either
        // Frame's `scene` / `dispatch`.
        //
        // `animations` (on `AnimationStore`) and `change_tracker` (with an
        // in-struct default) are likewise unused by this path; `animations`
        // is left `undefined` and `change_tracker` takes its default.
        .animations = undefined,
        .focus = undefined,

        // `entities` live on `App`; this path never reaches through
        // `self.app`, so `undefined` is safe. A test calling entity APIs
        // would need to wire a real `*App` (see `App.init` in `app.zig`).
        .app = undefined,
        .platform_window = null,
        .hover = HoverState.init(),
        .blur_handlers = BlurHandlerRegistry.init(),
        .cancel_registry = CancelRegistry.init(),
        .a11y = undefined,
        .deferred_count = 0,
        .deferred_commands = undefined,
        .needs_render = false,
    };
}

test "deferCommand queues command" {
    const TestState = struct {
        value: i32 = 0,
        pub fn increment(self: *@This(), _: *Window) void {
            self.value += 1;
        }
    };

    var state = TestState{};
    var g = testWindow();
    g.setRootState(TestState, &state);

    g.deferCommand(TestState.increment);
    try testing.expectEqual(@as(u8, 1), g.deferred_count);
    try testing.expect(g.hasDeferredCommands());

    g.flushDeferredCommands();
    try testing.expectEqual(@as(i32, 1), state.value);
    try testing.expectEqual(@as(u8, 0), g.deferred_count);
}

test "deferCommandWith passes argument" {
    const TestState = struct {
        value: i32 = 0,
        pub fn setValue(self: *@This(), _: *Window, new_value: i32) void {
            self.value = new_value;
        }
    };

    var state = TestState{};
    var g = testWindow();
    g.setRootState(TestState, &state);

    g.deferCommandWith(@as(i32, 42), TestState.setValue);
    g.flushDeferredCommands();
    try testing.expectEqual(@as(i32, 42), state.value);
}

test "multiple deferWith calls preserve their arguments" {
    const TestState = struct {
        sum: i32 = 0,
        pub fn addValue(self: *@This(), _: *Window, value: i32) void {
            self.sum += value;
        }
    };

    var state = TestState{};
    var g = testWindow();
    g.setRootState(TestState, &state);

    g.deferCommandWith(@as(i32, 1), TestState.addValue);
    g.deferCommandWith(@as(i32, 10), TestState.addValue);
    g.deferCommandWith(@as(i32, 100), TestState.addValue);
    try testing.expectEqual(@as(u8, 3), g.deferred_count);

    g.flushDeferredCommands();
    try testing.expectEqual(@as(i32, 111), state.sum);
}

test "deferred queue overflow is handled gracefully" {
    const TestState = struct {
        pub fn noop(_: *@This(), _: *Window) void {}
    };

    var state = TestState{};
    var g = testWindow();
    g.setRootState(TestState, &state);

    // Fill queue to capacity.
    var i: u32 = 0;
    while (i < MAX_DEFERRED_COMMANDS) : (i += 1) {
        g.deferCommand(TestState.noop);
    }
    try testing.expectEqual(@as(u8, MAX_DEFERRED_COMMANDS), g.deferred_count);

    // Overflow attempts must not corrupt the queue or the count.
    g.deferCommand(TestState.noop);
    g.deferCommand(TestState.noop);
    try testing.expectEqual(@as(u8, MAX_DEFERRED_COMMANDS), g.deferred_count);

    g.flushDeferredCommands();
    try testing.expectEqual(@as(u8, 0), g.deferred_count);
}

test "hasDeferredCommands returns correct state" {
    const TestState = struct {
        pub fn noop(_: *@This(), _: *Window) void {}
    };

    var state = TestState{};
    var g = testWindow();
    g.setRootState(TestState, &state);

    try testing.expect(!g.hasDeferredCommands());

    g.deferCommand(TestState.noop);
    try testing.expect(g.hasDeferredCommands());

    g.flushDeferredCommands();
    try testing.expect(!g.hasDeferredCommands());
}

// =============================================================================
// DrawPhase ladder tests
// =============================================================================
//
// These tests do not exercise the full frame lifecycle (which requires a
// real window, layout engine, scene, etc.) — they pin the phase machine
// invariants that the rest of the framework leans on:
//
//   1. A freshly-constructed `Window` reports `.none`.
//   2. `advancePhase` accepts the four legal forward edges.
//   3. The internal accessor matches the field.
//
// We use the `testWindow` stub from above plus direct field manipulation
// on `current_phase` — the resource-owning frame methods (`beginFrame`
// etc.) are out of reach without a full UI stack, but the ladder itself
// is observable.

test "DrawPhase: default phase is .none" {
    var g = testWindow();
    try testing.expectEqual(DrawPhase.none, g.drawPhase());
    try testing.expectEqual(DrawPhase.none, g.current_phase);
}

test "DrawPhase: advancePhase walks the legal ladder" {
    var g = testWindow();
    try testing.expectEqual(DrawPhase.none, g.drawPhase());

    g.advancePhase(.prepaint);
    try testing.expectEqual(DrawPhase.prepaint, g.drawPhase());

    g.advancePhase(.paint);
    try testing.expectEqual(DrawPhase.paint, g.drawPhase());

    g.advancePhase(.focus);
    try testing.expectEqual(DrawPhase.focus, g.drawPhase());

    g.advancePhase(.none);
    try testing.expectEqual(DrawPhase.none, g.drawPhase());
}

test "DrawPhase: drawPhase mirrors current_phase across multiple ladders" {
    // Two complete laps to confirm the wrap-around (`.focus → .none`)
    // re-enables a fresh `.none → .prepaint` start. Catches a bug
    // where `advancePhase` accidentally locks the field on first
    // wrap.
    var g = testWindow();

    var lap: u32 = 0;
    while (lap < 2) : (lap += 1) {
        g.advancePhase(.prepaint);
        try testing.expectEqual(DrawPhase.prepaint, g.drawPhase());
        g.advancePhase(.paint);
        try testing.expectEqual(DrawPhase.paint, g.drawPhase());
        g.advancePhase(.focus);
        try testing.expectEqual(DrawPhase.focus, g.drawPhase());
        g.advancePhase(.none);
        try testing.expectEqual(DrawPhase.none, g.drawPhase());
    }
}
