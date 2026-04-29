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
//! ## PR 3 — context/ subsystem extractions
//!
//! Per `docs/cleanup-implementation-plan.md` PR 3, four subsystems that were
//! previously bolted directly onto `Window` now live as peer modules:
//!
//!   - `hover: HoverState`        — see `hover.zig`         (was 6 fields here)
//!   - `blur_handlers: BlurHandlerRegistry` — see `blur_handlers.zig`
//!   - `cancel_registry: CancelRegistry`    — see `cancel_registry.zig`
//!   - `a11y: A11ySystem`         — see `a11y_system.zig`   (was 5 fields here)
//!
//! Both `BlurHandlerRegistry` and `CancelRegistry` are backed by the new
//! generic `SubscriberSet` (cleanup item #8) — two distinct call shapes
//! validating the trait before PR 8 leans on it for `element_states`.
//!
//! No public API change: every method that previously sat on `Window`
//! (`updateHover`, `registerBlurHandler`, `registerCancelGroup`,
//! `isA11yEnabled`, …) is preserved as a one-line forwarder. Internal
//! framework callers (`runtime/*.zig`, `ui/builder.zig`) reach into the
//! sub-fields directly via `window.hover.*` / `window.a11y.*` / etc.

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
// `a11y_system.zig` per PR 3).
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

// PR 7b.3 — `App` owns application-lifetime state shared across
// windows. The entity map lives there now (was a per-window
// `EntityMap` field on this struct). PR 7b.4 — `Keymap` and the
// `*const Theme` slot moved off `Window.globals` onto
// `App.globals`; only `Debugger` remains as a per-window owned
// global on this struct. Future slices add `image_loader`. Each
// `Window` borrows the parent `App` via the `app: *App` field
// below. See `app.zig` and `docs/cleanup-implementation-plan.md`
// PR 7b.3 / 7b.4.
const app_mod = @import("app.zig");
const App = app_mod.App;

// PR 7b.4 — `Keymap` is no longer registered on `Window.globals`;
// the slot lives on `App.globals` and `Window.keymap()` is now
// a forwarder to `self.app.keymap()`. The import alias survives
// only because the forwarder's return type still names `*Keymap`
// — every call site in this file that used to read or write the
// slot directly has been retired. A future cleanup that retires
// the forwarder altogether (once enough callers route through
// `*App` directly) can drop both the alias and the import in
// one sweep.
const action_mod = @import("../input/actions.zig");
const Keymap = action_mod.Keymap;

// Scene
const scene_mod = @import("../scene/scene.zig");
const Scene = scene_mod.Scene;

// Text
const text_mod = @import("../text/mod.zig");
const TextSystem = text_mod.TextSystem;

// Widgets
const widget_store_mod = @import("widget_store.zig");
const WidgetStore = widget_store_mod.WidgetStore;

// PR 4 — break the `context → widgets` backward edge.
//
// Concrete widget state types (`TextInput`, `TextArea`, `CodeEditorState`)
// no longer leak into `Window`. Focus is driven through the `Focusable`
// vtable in `context/focus.zig`, and direct widget access goes through
// `window.widgets.*` from callers higher up the stack (`runtime/`, `cx.zig`,
// user examples). See `docs/cleanup-implementation-plan.md` PR 4 and the
// cleanup direction in `docs/architectural-cleanup-plan.md` §4.

// Platform
const platform = @import("../platform/mod.zig");
// PR 7b.1a — `platform.Window` renamed to `platform.PlatformWindow`
// to free up the `Window` name for the framework-level wrapper
// landing in PR 7b.1b. This alias names the OS-level handle
// (NSWindow on macOS, wl_surface on Linux, canvas on web). The
// `window: ?*PlatformWindow` field below holds that handle.
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

// Extracted subsystems (PR 3). Body lives in the named files; `Window`
// composes them as ordinary fields.
const hover_mod = @import("hover.zig");
const HoverState = hover_mod.HoverState;
const blur_handlers_mod = @import("blur_handlers.zig");
const BlurHandlerRegistry = blur_handlers_mod.BlurHandlerRegistry;
const cancel_registry_mod = @import("cancel_registry.zig");
const CancelRegistry = cancel_registry_mod.CancelRegistry;
const a11y_system_mod = @import("a11y_system.zig");
const A11ySystem = a11y_system_mod.A11ySystem;

// PR 7a — bundled rendering resources (text + svg + image) with a
// single ownership flag. See `app_resources.zig` and
// `docs/cleanup-implementation-plan.md` PR 7a. Retires the
// per-field `*_owned: bool` triplet on `Window`.
const app_resources_mod = @import("app_resources.zig");
const AppResources = app_resources_mod.AppResources;

// PR 7c.3a — bundled per-window per-frame rendering state
// (scene + dispatch tree) with a single ownership flag. Same
// shape as `AppResources` but for the per-frame transients. The
// ownership-uniform single-window shape lands first; PR 7c.3c
// introduces the `rendered_frame` / `next_frame` double buffer
// and the `borrowed` constructor on `Frame` becomes load-bearing.
// See `frame.zig` and `docs/cleanup-implementation-plan.md` PR
// 7c.3a.
const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;

// PR 6 — explicit per-frame phase tagging. `current_phase` advances
// monotonically through `none → prepaint → paint → focus → none`;
// `assertAdvance` enforces the legal transition table at each step.
// See `docs/cleanup-implementation-plan.md` PR 6 and CLAUDE.md §3
// ("Assertion Density").
const draw_phase_mod = @import("draw_phase.zig");
pub const DrawPhase = draw_phase_mod.DrawPhase;

// PR 6 — type-keyed singleton storage for cross-cutting state.
// Pre-7b.4 this slot owned `Keymap` + `Debugger` + the future
// `*const Theme` slot; PR 7b.4 lifts `Keymap` and `*const Theme`
// onto `App.globals` and leaves only `Debugger` here on `Window`
// (its overlay quads, frame timing, and selected layout id are
// per-window concerns — sharing one debugger across windows would
// mix metrics from two unrelated frames). Adding a new
// per-window global is still a one-line `setOwned` at init; the
// app-scoped equivalents go on `App.globals` instead. See
// `src/context/global.zig` and the file header on `app.zig`.
const global_mod = @import("global.zig");
const Globals = global_mod.Globals;

// =============================================================================
// Local infrastructure (deferred command queue)
// =============================================================================
//
// The deferred-command queue stays on `Window` — unlike the four registries
// extracted in PR 3, it is not a self-contained subsystem; it reaches into
// the root-state pointer and the render-request flag every flush. Pulling
// it out would require dragging both back through a parameter list.

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

    // Layout (immediate mode - rebuilt each frame). Always owned —
    // the PR 7a `_owned` audit confirmed no init path borrows the
    // layout engine, so the tautological `layout_owned: bool` flag
    // retired alongside the `AppResources` extraction.
    layout: *LayoutEngine,

    /// PR 7c.3a — bundled per-window per-frame rendering state.
    /// Owns `scene: *Scene` and `dispatch: *DispatchTree` as one
    /// unit; `frame.owned` is always `true` in the single-`Frame`
    /// shape that lands in 7c.3a (every `Window.init*` path
    /// allocates a fresh owning `Frame`). The `borrowed` shape is
    /// reserved for PR 7c.3c, where `mem.swap` between
    /// `rendered_frame` and `next_frame` will produce transient
    /// views over shared backing storage. Default `undefined` so
    /// test fixtures that omit it (`testWindow` below) keep
    /// compiling without explicit initialisation. See
    /// `frame.zig` and `docs/cleanup-implementation-plan.md` PR
    /// 7c.3a.
    frame: Frame = undefined,

    /// PR 7c.3a — back-compat alias mirroring `frame.scene`. Kept
    /// so the ~99 internal `self.scene.*` / `window.scene.*` call
    /// sites compile against the new bundle without a wholesale
    /// sweep in this slice. PR 7c.3b retires the alias by
    /// rewriting every call site to reach through
    /// `window.frame.scene` (same pattern PR 7a → 7b.6 used for
    /// the `text_system` / `svg_atlas` / `image_atlas` triplet).
    /// Always populated from `frame.scene` by every `init*` path
    /// — same heap address, just a duplicated pointer field.
    scene: *Scene,

    /// PR 7a — bundled shared rendering resources. Owns or borrows
    /// `text_system` / `svg_atlas` / `image_atlas` as one unit;
    /// `resources.owned` discriminates the two shapes (single-window
    /// owns; multi-window borrows from the parent `App`). Replaces
    /// the previous `text_system_owned` / `svg_atlas_owned` /
    /// `image_atlas_owned` flag triplet on this struct. Default
    /// `undefined` so test fixtures that omit it
    /// (`testWindow` below) keep compiling without explicit
    /// initialisation. See `app_resources.zig` and
    /// `docs/cleanup-implementation-plan.md` PR 7a.
    resources: AppResources = undefined,

    // PR 7b.6 — back-compat aliases retired. The pre-7b.6 fields
    // `text_system: *TextSystem` / `svg_atlas: *SvgAtlas` /
    // `image_atlas: *ImageAtlas` mirrored `resources.*` to keep
    // the ~28 internal `window.text_system` / `window.svg_atlas` /
    // `window.image_atlas` call sites working across the 7a
    // landing. PR 7b.6 rewrites every call site to reach through
    // `window.resources.*` and drops the three pointer fields,
    // collapsing the duplicate ownership-shape footprint on
    // `Window` to a single `resources` field.

    // Widgets (retained across frames)
    widgets: WidgetStore,

    // Focus management
    focus: FocusManager,

    /// Hover state (PR 3 extraction — see `hover.zig`).
    /// Owns: hovered layout id, last cursor pos, ancestor chain cache,
    /// hover-changed latch. Public field — internal callers reach in
    /// via `window.hover.*` to avoid yet another forwarder layer.
    hover: HoverState = .{},

    // Drag & Drop state
    /// Pending drag (mouse down, threshold not yet exceeded)
    pending_drag: ?drag_mod.PendingDrag = null,
    /// Active drag (threshold exceeded, drag in progress)
    active_drag: ?drag_mod.DragState = null,
    /// Layout ID of current drop target (for drag-over styling)
    drag_over_target: ?u32 = null,

    // PR 6 — `debugger` lives in `globals` now. Access via
    // `window.debugger()`. The accessor reads from the type-keyed
    // store; one indirection vs. a direct field, but it removes the
    // last hard-coded singleton from the struct surface and makes
    // adding future globals (settings, telemetry) a one-liner.

    /// PR 7c.3a — back-compat alias mirroring `frame.dispatch`.
    /// Kept so the ~68 internal `self.dispatch.*` /
    /// `window.dispatch.*` call sites compile against the new
    /// bundle without a wholesale sweep in this slice. PR 7c.3b
    /// retires the alias by rewriting every call site to reach
    /// through `window.frame.dispatch`. Always populated from
    /// `frame.dispatch` by every `init*` path — same heap
    /// address, just a duplicated pointer field.
    dispatch: *DispatchTree,

    // PR 6 / 7b.4 — `keymap` lives in `app.globals` now (see
    // `app.zig`). `window.keymap()` is a forwarder so callers
    // don't have to reach through `window.app.keymap()` themselves;
    // a future cleanup may collapse the forwarder once enough
    // callers route through `*App` directly.

    /// Type-keyed singleton store (PR 6 — see `global.zig`).
    /// PR 7b.4 — owns `Debugger` only; `Keymap` lifted onto
    /// `App.globals`, and the `*const Theme` slot is now also
    /// app-scoped (populated lazily by `Builder.setTheme` against
    /// `window.app.globals`). Default-constructed
    /// (`entries = @splat(Entry.empty)`); populated post-init by
    /// every `init*` path via `setOwned`.
    globals: Globals = .{},

    /// Current frame phase (PR 6 — see `draw_phase.zig`). Advances
    /// monotonically through `none → prepaint → paint → focus →
    /// none` across the frame lifecycle. Phase-restricted methods
    /// assert against this value at entry; the helper `advancePhase`
    /// pair-asserts every legal transition. Default `.none` covers
    /// "constructed but never entered a frame".
    current_phase: DrawPhase = .none,

    /// PR 7b.3 / 7b.4 — borrowed `*App` view onto application-
    /// lifetime state shared across windows. Owns `entities`
    /// (lifted off `Window` in 7b.3) and the `Keymap` /
    /// `*const Theme` slots in `app.globals` (lifted in 7b.4);
    /// future 7b slices add `image_loader`. The single-window
    /// flow heap-allocates an `App` in `runtime/runner.zig` and
    /// hands a pointer here; the multi-window flow embeds a
    /// `context.App` inside `runtime/multi_window_app.zig::App`
    /// and hands a pointer to that. Either way the pointee
    /// outlives every borrowing `Window` — `Window.deinit` does
    /// not touch this field; the upstream owner tears down the
    /// `App` after the last `Window.deinit` returns.
    ///
    /// Default `undefined` so test fixtures (`testWindow`) and
    /// init paths that haven't been threaded through the new
    /// param yet keep compiling; every framework `init*` path
    /// assigns this field before the first frame runs.
    app: *App = undefined,

    // Platform — OS-level window handle (NSWindow on macOS, wl_surface
    // on Linux, canvas on web). PR 7b.1b renamed this field from
    // `window` to `platform_window` because the surrounding struct
    // itself was renamed `Gooey → Window`; without this rename, every
    // `self.window` inside `Window`'s methods would shadow the
    // framework wrapper's name with the platform handle's name. The
    // GPUI `App ↔ Window ↔ Context<T>` sketch in
    // `architectural-cleanup-plan.md` §10 uses the same naming
    // (`platform_window: PlatformWindow`).
    platform_window: ?*PlatformWindow,

    // Frame state
    frame_count: u64 = 0,
    needs_render: bool = true,

    // Window dimensions (cached for convenience)
    width: f32 = 0,
    height: f32 = 0,
    scale_factor: f32 = 1.0,

    /// Accessibility subsystem (PR 3 extraction — see `a11y_system.zig`).
    /// Owns: tree, platform bridge storage, bridge dispatcher, the
    /// "screen reader active" flag, and the periodic poll counter.
    /// `undefined` until `initOwned` / `initOwnedPtr` etc wire it.
    a11y: A11ySystem = undefined,

    // Per-window root state for handler callbacks (multi-window support)
    /// Type-erased pointer to this window's root state
    root_state_ptr: ?*anyopaque = null,
    /// Type ID for runtime type checking of root state
    root_state_type_id: usize = 0,

    // Deferred command queue (for operations that must run after event handling)
    deferred_commands: [MAX_DEFERRED_COMMANDS]DeferredCommand = undefined,
    deferred_count: u8 = 0,

    /// Blur handler registry (PR 3 extraction — see `blur_handlers.zig`).
    /// Backed by the generic `SubscriberSet`; cap is `MAX_BLUR_HANDLERS`
    /// (64). `undefined` here so the parent's by-pointer init paths can
    /// `initInPlace` without a stack temp; struct-literal init paths set
    /// it explicitly.
    blur_handlers: BlurHandlerRegistry = undefined,

    /// Cancel-group registry (PR 3 extraction — see `cancel_registry.zig`).
    /// Backed by the generic `SubscriberSet`; cap is `MAX_CANCEL_GROUPS`
    /// (64). All registered groups are cancelled in `deinit`.
    cancel_registry: CancelRegistry = undefined,

    // PR 7b.5 — `image_loader` lifted off `Window` onto `App`.
    // Pre-7b.5 every `Window` carried its own `ImageLoader`,
    // which made cross-window dedup of in-flight URL fetches
    // structurally impossible (window A and window B fetching
    // the same URL in the same frame would each launch a
    // background task and double the bandwidth). Post-7b.5 a
    // single `ImageLoader` lives on `App`, the pending /
    // failed sets are app-scoped, and the fetch group covers
    // every window.
    //
    // The forwarder methods below (`isImageLoadPending` /
    // `isImageLoadFailed`) and `beginFrame`'s drain reach
    // through `self.app.image_loader.*` now. The
    // `fixupImageLoadQueue` method retired alongside this
    // field — `App` is initialised at its final heap address
    // and `App.bindImageLoader` runs `initInPlace` directly,
    // so the by-value-copy queue dangle that `fixupQueue`
    // was guarding against cannot happen on the new path.

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
    // call surface used by `cx.registerCancelGroup` / external apps until
    // a future PR threads `*CancelRegistry` directly through `Cx`.

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
    /// Silent no-op when the group is not registered, matching the
    /// pre-extraction behaviour. The boolean returned by the underlying
    /// `CancelRegistry.unregister` is discarded — callers that need it
    /// should use the registry directly.
    pub fn unregisterCancelGroup(self: *Self, group: *std.Io.Group) void {
        _ = self.cancel_registry.unregister(group);
    }

    // =========================================================================
    // Async Image Loading — forwarders to `app.image_loader`
    // =========================================================================
    //
    // Body lives in `src/image/loader.zig` (`ImageLoader`). PR 7b.5
    // lifted the loader off `Window` onto `App`; these forwarders
    // route through `self.app.image_loader.*` so existing call
    // sites in `runtime/render.zig` keep working without churn.
    // The pre-7b.5 `fixupImageLoadQueue` forwarder retired
    // alongside the field — `App.bindImageLoader` runs
    // `initInPlace` at the loader's final heap address, so no
    // by-value-copy queue dangle can happen on the new path.
    //
    // Forwarders rather than direct `window.app.image_loader.*`
    // access at every call site keeps PR 7b.5 a focused lift —
    // a follow-up cleanup can retire the forwarders once
    // `runtime/render.zig` is comfortable reaching through
    // `window.app` directly.

    /// Check whether a URL image fetch is already in flight.
    /// Routed through the app-scoped loader (PR 7b.5).
    pub fn isImageLoadPending(self: *const Self, url_hash: u64) bool {
        return self.app.image_loader.isPending(url_hash);
    }

    /// Check whether a URL has previously failed to fetch.
    /// Routed through the app-scoped loader (PR 7b.5).
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

        // PR 7c.3a — bundle scene + dispatch into one `Frame`.
        // Replaces the previous two `allocator.create` + init +
        // `setViewport`/`enableCulling` + errdefer blocks. The
        // resulting struct is copied into `result.frame` below;
        // the heap pointers it carries survive the by-value copy
        // unchanged (same shape as the `resources` copy further
        // down). `result.scene` / `result.dispatch` are populated
        // as back-compat aliases mirroring the same heap
        // addresses; PR 7c.3b retires them.
        var frame = try Frame.initOwned(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer frame.deinit();

        // PR 7a — bundle text + SVG + image resources into one
        // `AppResources`. Replaces three separate `allocator.create`
        // + init + errdefer blocks plus the inline font-load step.
        // The resulting struct is copied into `result.resources`
        // below; the heap pointers it carries survive the by-value
        // copy unchanged.
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

        // Set up text measurement callback against the bundled text
        // system (same heap address as before, just routed through
        // the bundle).
        layout_engine.setMeasureTextFn(measureTextCallback, resources.text_system);

        var result: Self = .{
            .allocator = allocator,
            .io = io,
            .layout = layout_engine,
            // PR 7c.3a — `frame` is copied by value below; the
            // back-compat aliases (`scene` / `dispatch`) reach
            // into the same heap addresses. The local `frame`'s
            // `owned` flag is disarmed post-literal (mirroring
            // the `resources.owned = false` pattern) so a later
            // errdefer can't tear the pointees down out from
            // under `result.frame`.
            .frame = frame,
            .scene = frame.scene,
            .dispatch = frame.dispatch,
            // PR 7b.3 — `entities` lifted off `Window` onto `App`.
            // The `app: *App` field is left at its `undefined`
            // default here; the caller (`runtime/window_context.zig`)
            // assigns it after this returns. The follow-up slice
            // threads `app: *App` through this function's
            // signature so the field is set before any frame runs.
            // PR 6 / 7b.4 — `debugger` registers into `globals`
            // below (post-literal so it can `try` and we can
            // `errdefer` the cleanup chain). `keymap` lives on
            // `app.globals` now and is registered there by
            // `App.init` / `initInPlace`.
            .focus = FocusManager.init(allocator),
            // PR 7a — single owned `resources` field replaces the
            // `text_system` / `svg_atlas` / `image_atlas` triplet
            // plus their `*_owned` flags. The three pointer fields
            // below are back-compat aliases populated from the same
            // heap addresses (see field-decl doc-comments).
            .resources = resources,
            .widgets = WidgetStore.init(allocator, io),
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
            // PR 7b.5 — `image_loader` retired from `Window`'s
            // field list. The shared loader lives on `App` now;
            // `WindowContext.init` (the caller of this function)
            // calls `app.bindImageLoader(window.resources.image_atlas)`
            // after `Window.initOwned` returns and `window.app`
            // has been wired. The pre-7b.5 `.image_loader =
            // undefined` slot + `fixupImageLoadQueue` call below
            // both retired — `App.bindImageLoader` runs
            // `initInPlace` at the loader's final heap address,
            // so the by-value-copy queue dangle that the fixup
            // was guarding against cannot happen on the new path.
        };
        // PR 7a — `result.resources` was set by-value above. Now
        // that `result` is the canonical owner of the heap atlases,
        // disarm the local `resources.owned` so a later errdefer
        // (`globals.setOwned` failures) doesn't tear them down out
        // from under `result`. Without this, a partial init would
        // hit a double-free when the caller drops `result` after a
        // success path that copies into the heap slot.
        resources.owned = false;

        // PR 7c.3a — same disarm pattern for the `frame` bundle.
        // `result.frame` is now the canonical owner of the
        // scene + dispatch heap allocations; the local `frame`
        // carried an `owned = true` flag through the by-value
        // copy, and its errdefer would tear the pointees down
        // if a later `try` (e.g. `globals.setOwned`) unwinds.
        // Without this, that path would double-free against
        // `result.frame.deinit()` in the caller.
        frame.owned = false;

        // Initialize accessibility subsystem in place. On macOS, the
        // bridge captures the NSWindow / NSView handles passed here; on
        // other platforms they are ignored.
        const window_obj = if (builtin.os.tag == .macos) platform_window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) platform_window.ns_view else null;
        result.a11y.initInPlace(window_obj, view_obj);

        // PR 7b.5 — image-loader init retired from `Window`. The
        // caller (`runtime/window_context.zig::WindowContext.init`)
        // calls `app.bindImageLoader(window.resources.image_atlas)`
        // after this function returns and `window.app` has been
        // assigned. The atlas pointer reached here is the same
        // heap address either way (lives on `Window.resources`
        // for single-window mode); only the binder moved.

        // PR 6 / 7b.4 — populate per-window globals. Only
        // `Debugger` remains here; `Keymap` lifted onto
        // `App.globals` (registered by `App.init` /
        // `initInPlace`). The owned `*Debugger` lives in
        // `result.globals.entries`; ownership transfers when
        // `result` is moved into the caller's storage (the entry
        // holds a pointer to a stable heap address, so the
        // by-value copy is safe — no fixup needed unlike
        // `image_loader`).
        //
        // No `errdefer result.globals.deinit(allocator)` follows
        // this last `try` — the next statement is `return result`,
        // so an unwinding path past this point is structurally
        // impossible. The pre-7b.4 errdefer here was paired with
        // the now-retired `Keymap.setOwned` above; with that
        // gone, the dangling errdefer would have been dead code.
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

        // PR 7c.3a — bundle scene + dispatch via `Frame.initOwnedInPlace`,
        // writing directly into `self.frame` (no stack temp).
        // `initOwnedInPlace` is `noinline` per CLAUDE.md §14 so
        // the WASM stack budget stays bounded across the two
        // internal subsystems. Replaces the previous two
        // `allocator.create` + init + setViewport/enableCulling +
        // errdefer blocks. The back-compat aliases (`self.scene`
        // / `self.dispatch`) are populated from the same heap
        // addresses in the field-by-field block below; PR 7c.3b
        // retires them.
        try self.frame.initOwnedInPlace(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer self.frame.deinit();

        // PR 7a — initialise shared rendering resources directly
        // into `self.resources` (no stack temp). `initOwnedInPlace`
        // is `noinline` per CLAUDE.md §14 so the WASM stack budget
        // stays bounded across the three internal subsystems
        // (TextSystem ~1.7MB, atlases hundreds of KB each).
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

        // Set up text measurement callback against the bundled text
        // system.
        layout_engine.setMeasureTextFn(measureTextCallback, self.resources.text_system);

        // Field-by-field init avoids ~400KB stack temp from struct literal
        // Core resources
        self.allocator = allocator;
        self.io = io;
        self.layout = layout_engine;
        // PR 7c.3a — back-compat aliases mirror `self.frame.*`.
        // Same heap address as the bundle's owned pointees.
        self.scene = self.frame.scene;
        self.dispatch = self.frame.dispatch;
        // PR 7b.6 — back-compat aliases removed. The three pointer
        // fields that mirrored `self.resources.*` retired alongside
        // the call-site sweep; reach through `self.resources.*` for
        // the shared atlases now.
        self.platform_window = platform_window;

        // PR 7b.3 — `entities` lifted off `Window` onto `App`.
        // `self.app` is left `undefined` here; the caller
        // (`runtime/window_context.zig` on the WASM Ptr path)
        // assigns it after `initOwnedPtr` returns. The follow-up
        // slice threads `app: *App` through this function's
        // signature so the field is set inline.
        self.focus = FocusManager.init(allocator);
        self.widgets = WidgetStore.init(allocator, io);

        // PR 6 — `globals` and `current_phase` start fresh. `self`
        // is raw memory at this point (caller did `allocator.create`
        // without zeroing), so explicit assignment is required —
        // even default-valued fields would otherwise retain garbage.
        self.globals = .{};
        self.current_phase = .none;

        // PR 7a — SVG and image atlas creation moved up into
        // `self.resources.initOwnedInPlace` near the top of this
        // function. The aliases were assigned alongside `text_system`
        // in the field-by-field block above. No work remains here.

        // Scalar fields
        self.width = @floatCast(platform_window.size.width);
        self.height = @floatCast(platform_window.size.height);
        self.scale_factor = @floatCast(platform_window.scale_factor);
        self.frame_count = 0;
        self.needs_render = false;
        // PR 6 — `debugger` registered into `globals` below.

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

        // PR 7b.5 — image-loader init retired from `Window`. The
        // caller (`runtime/window_context.zig::WindowContext.init`
        // on native, `app.zig::WebApp.initImpl` on WASM) calls
        // `app.bindImageLoader(window.resources.image_atlas)` after
        // this function returns and `window.app` has been wired.
        // The shared loader runs `initInPlace` directly at its
        // final `App` heap address, so the by-value-copy queue
        // dangle that the pre-7b.5 fixup was guarding against
        // cannot happen on the new path.

        // PR 6 / 7b.4 — populate per-window globals. Only
        // `Debugger` remains here; `Keymap` lifted onto
        // `App.globals`. `self` is at its final heap address;
        // `setOwned` writes its bookkeeping directly there, no
        // fixup required. No `errdefer` after this last `try`:
        // see the matching note in `initOwned` — the pre-7b.4
        // errdefer protected an intermediate state between two
        // `setOwned` calls; with `Keymap` lifted onto `App` only
        // the `Debugger` registration remains, and the function
        // returns immediately after.
        try self.globals.setOwned(allocator, debugger_mod.Debugger, .{});
    }

    /// Initialize Window with shared resources (text system, SVG atlas, image atlas).
    /// Used by MultiWindowApp to share expensive resources across windows.
    /// The caller retains ownership of the shared resources.
    ///
    /// PR 7b.6 — collapsed signature: takes a single `*const AppResources`
    /// borrowed-or-owned view from the parent (e.g. `App`'s own owning
    /// `AppResources`). Replaces the pre-7b.6 triplet of
    /// `shared_text_system: *TextSystem` / `shared_svg_atlas: *SvgAtlas`
    /// / `shared_image_atlas: *ImageAtlas` parameters that this function
    /// inherited from before the `AppResources` extraction. The caller
    /// retains ownership of the `*const AppResources` pointee — every
    /// `Window` produced this way embeds an `owned = false` borrowed
    /// view, so `Window.deinit` is a no-op for the shared atlases.
    pub fn initWithSharedResources(
        allocator: std.mem.Allocator,
        platform_window: *PlatformWindow,
        shared_resources: *const AppResources,
        io: std.Io,
    ) !Self {
        // Assertions: validate inputs. Reach through the bundle so the
        // pre-7b.6 per-pointer null checks survive — every later
        // expression in this function indexes the same three slots.
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

        // PR 7c.3a — bundle scene + dispatch into one `Frame`
        // (owned per-window even in multi-window mode — the
        // scene + dispatch tree are per-window state and
        // cannot be shared without breaking hit-testing).
        // Same shape as the matching block in `initOwned`. The
        // `frame.owned = false` disarm post-literal mirrors
        // the `resources.owned = false` pattern.
        var frame = try Frame.initOwned(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer frame.deinit();

        // Set up text measurement callback using shared text system
        layout_engine.setMeasureTextFn(measureTextCallback, shared_resources.text_system);

        var result: Self = .{
            .allocator = allocator,
            .io = io,
            .layout = layout_engine,
            // PR 7c.3a — `frame` is copied by value below; the
            // back-compat aliases (`scene` / `dispatch`) reach
            // into the same heap addresses as `frame.scene` /
            // `frame.dispatch`. The local `frame.owned` is
            // disarmed post-literal so a later errdefer can't
            // tear the pointees down out from under
            // `result.frame`.
            .frame = frame,
            .scene = frame.scene,
            .dispatch = frame.dispatch,
            // PR 7b.3 — `entities` lifted off `Window` onto `App`.
            // `app: *App` is set by the caller post-init; see the
            // matching note in `initOwned` above.
            // PR 6 / 7b.4 — `debugger` registers into `globals`
            // below; `keymap` lives on `app.globals`.
            .focus = FocusManager.init(allocator),
            // PR 7a / 7b.6 — borrowed `AppResources` view; the parent
            // (e.g. `MultiWindowApp`) owns the underlying pointees.
            // `AppResources.deinit` is a no-op for `owned = false`,
            // matching the pre-extraction `*_owned = false` semantics.
            // The bundle's three pointer fields are copied through
            // unchanged — same heap addresses as `shared_resources.*`.
            .resources = AppResources.borrowed(
                allocator,
                io,
                shared_resources.text_system,
                shared_resources.svg_atlas,
                shared_resources.image_atlas,
            ),
            .widgets = WidgetStore.init(allocator, io),
            .platform_window = platform_window,
            .width = @floatCast(platform_window.size.width),
            .height = @floatCast(platform_window.size.height),
            .scale_factor = @floatCast(platform_window.scale_factor),
            .hover = HoverState.init(),
            .blur_handlers = BlurHandlerRegistry.init(),
            .cancel_registry = CancelRegistry.init(),
            .a11y = undefined,
            // PR 7b.5 — `image_loader` retired from `Window`'s
            // field list. In multi-window mode the parent
            // `multi_window_app::App.init` has already called
            // `context_app.bindImageLoader(resources.image_atlas)`
            // against the same shared atlas every window's
            // borrowed `AppResources` points at; this function
            // does NOT re-bind. See the matching comment block
            // in `initOwned` and the file header.
        };

        // PR 7c.3a — disarm the local `frame.owned` flag now
        // that `result.frame` is the canonical owner. Mirrors
        // the `resources.owned = false` line in `initOwned`;
        // the rationale is identical (prevent a double-free
        // against `result.frame.deinit()` if a later `try`
        // unwinds via the local `frame`'s errdefer).
        frame.owned = false;

        // Initialize platform-specific accessibility bridge
        const window_obj = if (builtin.os.tag == .macos) platform_window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) platform_window.ns_view else null;
        result.a11y.initInPlace(window_obj, view_obj);

        // PR 7b.5 — image-loader init retired from `Window`. The
        // shared loader on `App` (already bound by
        // `multi_window_app::App.init` against the same atlas
        // this function's `shared_resources.image_atlas` points
        // at) handles every window's URL fetches. The
        // `shared_resources.image_atlas` here is identical heap
        // address to what `bindImageLoader` was called with —
        // every window in a multi-window app has the same
        // shared atlas in its borrowed `AppResources`, and
        // there is exactly one bind per `App` lifetime.

        // PR 6 / 7b.4 — same globals registration as `initOwned`.
        // Only `Debugger` is per-window here; `Keymap` lives on
        // `app.globals`. The shared-resources path doesn't change
        // the per-window `Debugger`'s lifetime — every window
        // still owns its own debugger so its overlay quads /
        // frame timing / selected layout id stay scoped to its
        // own scene. No `errdefer` after this last `try`: see the
        // matching note in `initOwned`.
        try result.globals.setOwned(allocator, debugger_mod.Debugger, .{});

        return result;
    }

    /// Initialize Window in-place with shared resources.
    /// Used by MultiWindowApp on WASM to avoid stack overflow.
    /// Marked noinline to prevent stack accumulation.
    ///
    /// PR 7b.6 — collapsed signature: takes `*const AppResources`
    /// instead of three separate pointers. See the comment on
    /// `initWithSharedResources` above for the rationale.
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

        // PR 7c.3a — bundle scene + dispatch via
        // `Frame.initOwnedInPlace`, writing directly into
        // `self.frame` (no stack temp). Same shape as the matching
        // block in `initOwnedPtr`. The scene + dispatch tree are
        // per-window state and remain owned per-window even in
        // multi-window mode (only `AppResources` is borrowed).
        try self.frame.initOwnedInPlace(
            allocator,
            @floatCast(platform_window.size.width),
            @floatCast(platform_window.size.height),
        );
        errdefer self.frame.deinit();

        // Set up text measurement callback using shared text system
        layout_engine.setMeasureTextFn(measureTextCallback, shared_resources.text_system);

        // Field-by-field init avoids stack temp from struct literal
        self.allocator = allocator;
        self.io = io;
        self.layout = layout_engine;
        // PR 7c.3a — back-compat aliases mirror `self.frame.*`.
        // Same heap address as the bundle's owned pointees.
        self.scene = self.frame.scene;
        self.dispatch = self.frame.dispatch;

        // PR 7a / 7b.6 — borrowed `AppResources` view; the parent
        // owns the pointees. By-value init is safe — the struct only
        // carries the three pointers plus the `owned = false` flag,
        // no internal self-references. The bundle's pointer fields
        // are copied through unchanged.
        self.resources = AppResources.borrowed(
            allocator,
            io,
            shared_resources.text_system,
            shared_resources.svg_atlas,
            shared_resources.image_atlas,
        );

        self.platform_window = platform_window;

        // PR 7b.3 — `entities` lifted off `Window` onto `App`.
        // `self.app` is left `undefined` here; the caller assigns
        // it post-init. See the matching note in `initOwnedPtr`.
        self.focus = FocusManager.init(allocator);
        self.widgets = WidgetStore.init(allocator, io);

        // PR 6 — `globals` and `current_phase` start fresh (same as
        // `initOwnedPtr` — `self` is raw memory).
        self.globals = .{};
        self.current_phase = .none;

        // Scalar fields
        self.width = @floatCast(platform_window.size.width);
        self.height = @floatCast(platform_window.size.height);
        self.scale_factor = @floatCast(platform_window.scale_factor);
        self.frame_count = 0;
        self.needs_render = false;
        // PR 6 — `debugger` registered into `globals` below.

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

        // PR 7b.5 — image-loader init retired from `Window`. The
        // shared loader on `App` (bound once by
        // `multi_window_app::App.init` against the same atlas
        // `shared_resources.image_atlas` points at) handles
        // every window's URL fetches. See the matching comment
        // in `initWithSharedResources` and the file header on
        // `App` for the two-phase init rationale.

        // PR 6 / 7b.4 — same per-window globals registration as
        // `initOwnedPtr`. Only `Debugger` here; `Keymap` lives on
        // `app.globals`. No `errdefer` after this last `try`:
        // see the matching note in `initOwned`.
        try self.globals.setOwned(allocator, debugger_mod.Debugger, .{});
    }

    pub fn deinit(self: *Self) void {
        // PR 7b.5 — image-loader teardown retired from
        // `Window.deinit`. The shared loader lives on `App`
        // now; `App.deinit` is responsible for closing the
        // result queue and cancelling the fetch group. The
        // upstream owner (`runtime/runner.zig` in single-window
        // mode, `multi_window_app::App.deinit` in multi-window
        // mode) tears the `App` down *after* every
        // `Window.deinit` has run, which is the correct order:
        // background fetches need a live result queue to
        // unwind against, and `App.deinit`'s `cancel` of the
        // fetch group needs the queue still open during the
        // cancel-point check on background tasks.

        // Cancel all registered cancel groups before any teardown.
        // Blocking is acceptable — we are shutting down.
        self.cancel_registry.cancelAll(self.io);

        // Clean up accessibility subsystem (deinit drops the bridge).
        self.a11y.deinit();

        // Blur handlers use fixed-capacity storage, no cleanup needed

        self.widgets.deinit();
        self.focus.deinit();
        // PR 7b.3 — `entities` lifted onto `App`. The borrowed
        // `*App` is owned upstream (single-window: by
        // `runtime/window_context.zig`; multi-window: by
        // `runtime/multi_window_app.zig::App`); both call
        // `App.deinit` after every `Window.deinit` has run.
        // `Window.deinit` deliberately does not touch
        // `self.app` — it would be a use-after-free in the
        // multi-window case where one `App` outlives many
        // `Window` instances.

        // PR 7a — single teardown call covers text_system +
        // svg_atlas + image_atlas. `AppResources.deinit` is a no-op
        // when borrowed (multi-window mode), otherwise frees the
        // three subsystems in image → svg → text order. Replaces
        // three flag-guarded free blocks (`*_owned: bool` triplet)
        // at this point in the function.
        self.resources.deinit();

        // PR 6 / 7b.4 — teardown covers `Debugger` only (the
        // single per-window owned global remaining after 7b.4).
        // `Keymap.deinit` runs from `App.deinit` instead. The
        // thunk built at `setOwned` time picks the right shape
        // per type (`fn(*Self) void` vs.
        // `fn(*Self, Allocator) void`), so
        // each global teardown matches its declared `deinit`.
        self.globals.deinit(self.allocator);

        // PR 7c.3a — single teardown call covers scene +
        // dispatch tree. `Frame.deinit` frees both heap
        // pointees in dispatch → scene order (matches the
        // pre-7c.3a free order in this function), or no-ops if
        // `frame.owned == false` (reserved for the PR 7c.3c
        // double-buffer borrowed-view shape, not yet wired).
        // Replaces the previous two pairs of `T.deinit` +
        // `allocator.destroy` calls. The back-compat aliases
        // (`self.scene` / `self.dispatch`) are NOT separately
        // freed — they're mirror pointers into the same heap
        // addresses `frame.deinit` just released; touching
        // them after this point would be a use-after-free.
        self.frame.deinit();

        // PR 7a — `layout` is always owned (no init path ever
        // leaves it borrowed); the tautological `layout_owned`
        // flag retired alongside the `AppResources` extraction.
        // Free unconditionally. (`scene` joined `dispatch`
        // inside `Frame` in PR 7c.3a — see the `frame.deinit`
        // call above.)
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

    /// PR 6 — read-only accessor for diagnostics / tests.
    pub fn drawPhase(self: *const Self) DrawPhase {
        return self.current_phase;
    }

    /// PR 6 / 7b.4 — typed accessor for the keymap global.
    /// Pre-7b.4 the slot lived on `Window.globals`; post-7b.4 it
    /// lives on `App.globals` and this is a forwarder. The
    /// forwarder is preserved so existing call sites
    /// (`window.keymap().bind(...)` / `window.keymap().match(...)`)
    /// keep working without churn — a follow-up cleanup may
    /// retire it once enough callers route through `*App`
    /// directly. Panics if the parent `App` was never `init*`'d
    /// (a framework bug, not a runtime fallback).
    pub fn keymap(self: *Self) *Keymap {
        return self.app.keymap();
    }

    /// PR 6 — typed accessor for the debugger global. Same panic
    /// contract as `keymap()`.
    pub fn debugger(self: *Self) *debugger_mod.Debugger {
        return self.globals.get(debugger_mod.Debugger) orelse {
            std.debug.panic("Window.debugger(): no Debugger registered in globals (init* did not run?)", .{});
        };
    }

    /// Call at the start of each frame before building UI
    ///
    /// Per-tick app-scoped work (image-loader drain, entity-
    /// observation clear) is NOT done here — see PR 7c.2. The
    /// runtime frame driver (`runtime/frame.zig::renderFrameImpl`)
    /// calls `self.app.beginFrame()` exactly once per tick before
    /// invoking this method, so by the time control reaches here
    /// the loader has already drained into the atlas and stale
    /// frame observations from the previous tick have been
    /// cleared. Pre-7c.2 those calls lived inline in this
    /// function, which made multi-window flows redundant
    /// (N windows borrowing one `App` ran the begin pair N times
    /// per tick) and worse, broke `entities.beginFrame`'s
    /// non-idempotent contract on the second call onwards.
    pub fn beginFrame(self: *Self) void {
        // PR 6 — first thing the frame does: advance into prepaint.
        // `assertAdvance` checks the previous phase was `.none`, so
        // back-to-back `beginFrame` calls without an intervening
        // `finalizeFrame` fail loudly here rather than corrupting
        // the next frame's state.
        self.advancePhase(.prepaint);

        // Start profiler frame timing
        self.debugger().beginFrame(self.io);

        self.frame_count += 1;
        self.widgets.beginFrame();
        self.focus.beginFrame();
        self.resources.image_atlas.beginFrame();

        // PR 7c.2 — `self.app.beginFrame()` was hoisted out of
        // this function up to `runtime/frame.zig::renderFrameImpl`,
        // which calls it exactly once per tick before driving any
        // window's `Window.beginFrame`. This is the structural
        // fix the 7c.1 comment block flagged: with N windows
        // borrowing one `App`, running the app-scoped begin pair
        // through every per-window forwarder discarded
        // earlier-this-tick frame observations on the second
        // call onwards. Lifting the call to the runtime layer
        // removes the redundancy and the correctness gap in one
        // step. The post-PR ordering invariant the runtime
        // driver upholds is: `App.beginFrame` runs after every
        // `Window`'s atlas has been reset for the tick (so
        // freshly-decoded pixels land in the post-reset atlas)
        // and before any window's render observes entities (so
        // the clear of last-tick observations cannot race with
        // this-tick observations). Currently only one window
        // renders per tick, so the constraint is trivially
        // satisfied; a future tick-driver landing in 7c.3+ will
        // preserve it across N windows.

        // Update cached window dimensions
        if (self.platform_window) |w| {
            self.width = @floatCast(w.size.width);
            self.height = @floatCast(w.size.height);
            self.scale_factor = @floatCast(w.scale_factor);
        }

        // Sync scale factor to text system for correct glyph rasterization
        // self.resources.text_system.setScaleFactor(self.scale_factor);

        // Clear scene for new frame
        self.scene.clear();

        // Connect render stats to scene for profiler tracking
        render_stats.beginFrame();
        self.scene.setStats(&render_stats.frame_stats);

        // Update viewport only on resize
        if (self.scene.viewport_width != self.width or self.scene.viewport_height != self.height) {
            self.scene.setViewport(self.width, self.height);
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
    /// Per-tick app-scoped finalisation is NOT done here — see
    /// PR 7c.2. The runtime frame driver
    /// (`runtime/frame.zig::renderFrameImpl`) calls
    /// `self.app.endFrame()` exactly once per tick after every
    /// window's `Window.endFrame` has returned. Pre-7c.2 the
    /// call lived inline here for symmetry with the (now
    /// hoisted) `App.beginFrame`; lifting both halves keeps the
    /// pair together at the layer the work belongs to.
    pub fn endFrame(self: *Self) ![]const RenderCommand {
        self.widgets.endFrame();
        self.focus.endFrame();

        // PR 7c.2 — `self.app.endFrame()` was hoisted out of
        // this function up to `runtime/frame.zig::renderFrameImpl`,
        // mirroring the `beginFrame` lift. `App.endFrame` is
        // currently a no-op (`EntityMap.endFrame` itself is a
        // no-op), so the visible behaviour is unchanged; the
        // motivation is layering, not behaviour. Future
        // batching optimisations the `App.endFrame` hook is
        // reserved for now have a single per-tick driver to
        // hang off rather than firing once per window per tick.

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

        // PR 6 — layout has run; we are now in the paint phase. The
        // caller (`runtime/frame.zig`) will draw the returned
        // commands into the scene under this phase. Advancing here
        // (rather than in the caller) keeps the phase machine in
        // one place.
        self.advancePhase(.paint);

        return commands;
    }

    /// Finalize frame timing (call after all rendering is complete)
    pub fn finalizeFrame(self: *Self) void {
        // PR 6 — paint is done; walk through `.focus` (post-paint
        // focus / a11y finalisation surface — wired up in PR 7) and
        // back to `.none`. We advance through `.focus` even though
        // no work is currently scheduled there because
        // `assertAdvance` requires monotone progression: `paint →
        // none` is not a legal direct edge.
        self.advancePhase(.focus);
        self.debugger().endFrame(self.io, &render_stats.frame_stats);
        self.advancePhase(.none);
    }

    /// Check if any animations are running (call after endFrame)
    pub fn hasActiveAnimations(self: *const Self) bool {
        return self.widgets.hasActiveAnimations();
    }

    // =========================================================================
    // Hover State — forwarders to `hover` (PR 3 extraction, see `hover.zig`)
    // =========================================================================

    /// Update hover state based on mouse position.
    /// Call this on mouse_moved events AFTER bounds have been synced.
    /// Returns true if hover state changed (requires re-render).
    pub fn updateHover(self: *Self, x: f32, y: f32) bool {
        return self.hover.update(self.dispatch, x, y);
    }

    /// Refresh hover state using last known mouse position.
    /// Call this after bounds have been synced to fix frame delay issues.
    pub fn refreshHover(self: *Self) void {
        self.hover.refresh(self.dispatch);
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
    /// PR 6 — must be called in the `.prepaint` phase: layout is
    /// being declared while the user's `render_fn` is running.
    /// Calling this after `endFrame` (which advances to `.paint`)
    /// would silently corrupt the next frame's tree.
    pub fn openElement(self: *Self, decl: ElementDeclaration) !void {
        draw_phase_mod.assertPhase(self.current_phase, .prepaint);
        try self.layout.openElement(decl);
    }

    /// Close the current layout element.
    ///
    /// PR 6 — same `.prepaint` invariant as `openElement`. Pairing
    /// the assertion at both ends of the open/close bracket
    /// (CLAUDE.md §3) catches a stray `closeElement` outside the
    /// user render, which would unbalance the layout stack.
    pub fn closeElement(self: *Self) void {
        draw_phase_mod.assertPhase(self.current_phase, .prepaint);
        self.layout.closeElement();
    }

    /// Add a text element.
    ///
    /// PR 6 — `.prepaint` only: text declarations are part of the
    /// element tree built during the user render.
    pub fn text(self: *Self, content: []const u8, config: TextConfig) !void {
        draw_phase_mod.assertPhase(self.current_phase, .prepaint);
        try self.layout.text(content, config);
    }

    // =========================================================================
    // Widget Access — moved to `window.widgets.*`
    // =========================================================================
    //
    // PR 4 (`docs/cleanup-implementation-plan.md`): the per-widget-type
    // forwarders (`textInput` / `textArea` / `codeEditor` / their
    // `*OrPanic` siblings, `getFocused*`, and `focusText*` /
    // `focusCodeEditor`) used to live here, each one importing the
    // concrete widget state type and so dragging the
    // `context → widgets` backward edge into `Window`. They are deleted
    // outright — callers in `runtime/`, `cx.zig`, and user code reach
    // through `window.widgets.textInput(id)` / `window.widgets.textArea(id)`
    // / `window.widgets.codeEditor(id)` directly, and trigger focus via
    // the generic `window.focusWidget(id)` below (which routes through
    // the `Focusable` vtable on `FocusManager` — no widget-type switch).
    //
    // Adding a new focusable widget type now touches only `widgets/`:
    // the widget exposes `pub fn focusable(self) Focusable` and the
    // builder registers that vtable on its `FocusHandle`. `Window`
    // doesn't need to learn about the new type.

    /// Focus a widget by string ID. Generic over widget type — the
    /// `FocusManager` uses the `Focusable` vtable registered on the
    /// matching `FocusHandle` to drive `blur()` on the previously
    /// focused widget and `focus()` on the new one. Replaces the old
    /// per-type `focusTextInput` / `focusTextArea` / `focusCodeEditor`
    /// (and the `focusWidgetById(comptime T, id)` switch).
    pub fn focusWidget(self: *Self, id: []const u8) void {
        // Invoke any registered blur handler for the currently-focused
        // widget before the trait flips its `focused` flag — keeps the
        // existing on-blur semantics that `focusTextInput` &c. used to
        // provide via `syncWidgetFocus`.
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
    /// trait on the matching `FocusHandle` — see `focusWidget` for the
    /// rationale and the PR 4 cleanup direction.
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
    /// widget maps required (PR 4).
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
    /// PR 4: previously this walked every per-type widget map in
    /// `WidgetStore` to find the focused widget — that walk is gone now
    /// that `FocusManager` knows the focused element's `FocusId`
    /// directly. We just ask the registry for `getHandler(id)` against
    /// the focus manager's tracked `string_id` and dispatch.
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

    /// Create a new entity.
    ///
    /// PR 7b.3 — forwards to `self.app.entities`. Pre-7b.3 the
    /// map lived as a direct field on `Window`; the lift to
    /// `App` is transparent to this forwarder's call sites.
    pub fn createEntity(self: *Self, comptime T: type, value: T) !entity_mod.Entity(T) {
        return self.app.entities.new(T, value);
    }

    /// Read an entity's data.
    /// PR 7b.3 — forwards to `self.app.entities`.
    pub fn readEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*const T {
        return self.app.entities.read(T, entity);
    }

    /// Get mutable access to an entity.
    /// PR 7b.3 — forwards to `self.app.entities`.
    pub fn writeEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*T {
        return self.app.entities.write(T, entity);
    }

    /// Process entity notifications (called during frame).
    /// PR 7b.3 — forwards to `self.app.entities`.
    pub fn processEntityNotifications(self: *Self) bool {
        return self.app.entities.processNotifications();
    }

    /// Get the entity map. PR 7b.3 — returns the shared
    /// `App.entities` borrowed via `self.app`. Pre-7b.3 this
    /// returned a per-window map; post-7b.3 every window
    /// borrowing the same `*App` returns the same pointer,
    /// which is the property cross-window observation needs.
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

    /// Finish the scene after rendering
    pub fn finishScene(self: *Self) void {
        self.scene.finish();
    }

    // =========================================================================
    // Resource Access
    // =========================================================================

    pub fn getScene(self: *Self) *Scene {
        return self.scene;
    }

    pub fn getTextSystem(self: *Self) *TextSystem {
        return self.resources.text_system;
    }

    pub fn getLayout(self: *Self) *LayoutEngine {
        return self.layout;
    }

    /// Get the OS-level window handle. Renamed from `getWindow` in
    /// PR 7b.1b to disambiguate from the framework-level `Window`
    /// struct that this method now lives on.
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
    // Accessibility — forwarders to `a11y` (PR 3 extraction, see `a11y_system.zig`)
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
// These tests cover the deferred-command queue, which stays on `Window`.
// They construct a minimal `Window` value via field-by-field init, leaving
// every resource pointer at `undefined` — the deferred-command path
// reads only `deferred_commands`, `deferred_count`, `root_state_*`,
// `needs_render`, and `window`, so the test exercise the path without
// standing up a full UI stack.
//
// Hover / blur / cancel / a11y subsystems have their own unit tests in
// the respective modules; this file no longer needs to test them.

const testing = std.testing;

/// Build a stub `Window` for deferred-command tests. Resources stay
/// `undefined` because the tested path does not touch them; `window`
/// is `null` so `requestRender` is a no-op.
fn testWindow() Window {
    return .{
        .allocator = testing.allocator,
        .io = undefined,
        .layout = undefined,
        .scene = undefined,
        .widgets = undefined,
        .focus = undefined,
        .dispatch = undefined,

        // PR 7b.3 — `entities` lifted onto `App`. The deferred-
        // command tests this fixture is built for never reach
        // through `self.app`, so `undefined` is safe; any test
        // that calls into entity APIs would need to wire a
        // real `*App` (see `App.init` in `app.zig`).
        .app = undefined,
        .platform_window = null,
        .hover = HoverState.init(),
        .blur_handlers = BlurHandlerRegistry.init(),
        .cancel_registry = CancelRegistry.init(),
        .a11y = undefined,
        // PR 7b.5 — `image_loader` retired from `Window`'s
        // field list; lives on `App` now. The deferred-command
        // tests this fixture is built for never reach the
        // loader, so the field's removal is invisible to them.
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
// PR 6 — DrawPhase ladder tests
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
