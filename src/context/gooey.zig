//! Gooey - Unified UI Context
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
//! var ui = try Gooey.init(allocator, window, &layout_engine, &scene, &text_system);
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
//! previously bolted directly onto `Gooey` now live as peer modules:
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
//! No public API change: every method that previously sat on `Gooey`
//! (`updateHover`, `registerBlurHandler`, `registerCancelGroup`,
//! `isA11yEnabled`, …) is preserved as a one-line forwarder. Internal
//! framework callers (`runtime/*.zig`, `ui/builder.zig`) reach into the
//! sub-fields directly via `gooey.hover.*` / `gooey.a11y.*` / etc.

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
// no longer leak into `Gooey`. Focus is driven through the `Focusable`
// vtable in `context/focus.zig`, and direct widget access goes through
// `gooey.widgets.*` from callers higher up the stack (`runtime/`, `cx.zig`,
// user examples). See `docs/cleanup-implementation-plan.md` PR 4 and the
// cleanup direction in `docs/architectural-cleanup-plan.md` §4.

// Platform
const platform = @import("../platform/mod.zig");
const Window = platform.Window;

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

// Extracted subsystems (PR 3). Body lives in the named files; `Gooey`
// composes them as ordinary fields.
const hover_mod = @import("hover.zig");
const HoverState = hover_mod.HoverState;
const blur_handlers_mod = @import("blur_handlers.zig");
const BlurHandlerRegistry = blur_handlers_mod.BlurHandlerRegistry;
const cancel_registry_mod = @import("cancel_registry.zig");
const CancelRegistry = cancel_registry_mod.CancelRegistry;
const a11y_system_mod = @import("a11y_system.zig");
const A11ySystem = a11y_system_mod.A11ySystem;

// =============================================================================
// Local infrastructure (deferred command queue)
// =============================================================================
//
// The deferred-command queue stays on `Gooey` — unlike the four registries
// extracted in PR 3, it is not a self-contained subsystem; it reaches into
// the root-state pointer and the render-request flag every flush. Pulling
// it out would require dragging both back through a parameter list.

const MAX_DEFERRED_COMMANDS = 32;

const DeferredCommand = struct {
    callback: *const fn (*Gooey, u64) void,
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

/// Gooey - unified UI context
pub const Gooey = struct {
    allocator: std.mem.Allocator,
    // IO interface (Zig 0.16 std.Io — replaces ad-hoc global_single_threaded calls).
    // Threaded through the framework from main(); see cx.io() accessor.
    io: std.Io,

    // Layout (immediate mode - rebuilt each frame)
    layout: *LayoutEngine,
    layout_owned: bool = false,

    // Rendering (retained)
    scene: *Scene,
    scene_owned: bool = false,

    // Text rendering
    text_system: *TextSystem,
    text_system_owned: bool = false,

    // SVG and Image atlases (pointers for resource sharing)
    svg_atlas: *svg_mod.SvgAtlas,
    svg_atlas_owned: bool = false,
    image_atlas: *image_mod.ImageAtlas,
    image_atlas_owned: bool = false,

    // Widgets (retained across frames)
    widgets: WidgetStore,

    // Focus management
    focus: FocusManager,

    /// Hover state (PR 3 extraction — see `hover.zig`).
    /// Owns: hovered layout id, last cursor pos, ancestor chain cache,
    /// hover-changed latch. Public field — internal callers reach in
    /// via `gooey.hover.*` to avoid yet another forwarder layer.
    hover: HoverState = .{},

    // Drag & Drop state
    /// Pending drag (mouse down, threshold not yet exceeded)
    pending_drag: ?drag_mod.PendingDrag = null,
    /// Active drag (threshold exceeded, drag in progress)
    active_drag: ?drag_mod.DragState = null,
    /// Layout ID of current drop target (for drag-over styling)
    drag_over_target: ?u32 = null,

    /// UI Debugger/Inspector (toggle with Cmd+Shift+I)
    debugger: debugger_mod.Debugger = .{},

    /// Dispatch tree for event routing
    dispatch: *DispatchTree,

    /// Keymap for action bindings
    keymap: Keymap,

    /// Entity storage for GPUI-style state management
    entities: EntityMap,

    // Platform
    window: ?*Window,

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

    // Async image loading — URL fetch + decode + atlas cache.
    //
    // Owned subsystem (PR 1 extraction): see `src/image/loader.zig`.
    // Initialized in place so the embedded `Io.Queue`'s pointer to the
    // backing result buffer is stable. Forwarder methods on `Gooey`
    // (`isImageLoadPending`, `isImageLoadFailed`, ...) preserve the call
    // surface used by `runtime/render.zig` until PR 7 reroutes call
    // sites to `gooey.image_loader.*` directly.
    image_loader: image_mod.ImageLoader = undefined,

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
    // Async Image Loading — forwarders to `image_loader`
    // =========================================================================
    //
    // Body lives in `src/image/loader.zig` (`ImageLoader`). The wrappers
    // here preserve the existing call surface used by `runtime/render.zig`
    // (`gooey_ctx.isImageLoadPending`, `gooey_ctx.isImageLoadFailed`, ...)
    // so PR 1 stays a focused move. PR 7 reroutes call sites directly
    // to `gooey.image_loader.*`.

    /// Re-bind the loader's queue pointer after a by-value copy.
    ///
    /// Required after `initOwned` / `initWithSharedResources` because those
    /// build `Self` on the stack and copy to heap, leaving the queue's
    /// internal pointer dangling. The `Ptr`-style init paths do NOT need
    /// this — they write at the final address.
    pub fn fixupImageLoadQueue(self: *Self) void {
        self.image_loader.fixupQueue();
    }

    /// Check whether a URL image fetch is already in flight.
    pub fn isImageLoadPending(self: *const Self, url_hash: u64) bool {
        return self.image_loader.isPending(url_hash);
    }

    /// Check whether a URL has previously failed to fetch.
    pub fn isImageLoadFailed(self: *const Self, url_hash: u64) bool {
        return self.image_loader.isFailed(url_hash);
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
    /// The method should be `fn(*State, *Gooey) void`.
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

    /// Initialize Gooey creating and owning all resources
    pub fn initOwned(allocator: std.mem.Allocator, window: *Window, font_config: FontConfig, io: std.Io) !Self {
        // Create layout engine
        const layout_engine = allocator.create(LayoutEngine) catch return error.OutOfMemory;
        layout_engine.* = LayoutEngine.init(allocator);
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

        // Create scene
        const scene = allocator.create(Scene) catch return error.OutOfMemory;
        scene.* = Scene.init(allocator);
        errdefer {
            scene.deinit();
            allocator.destroy(scene);
        }

        // Enable viewport culling with initial window size
        scene.setViewport(
            @floatCast(window.size.width),
            @floatCast(window.size.height),
        );
        scene.enableCulling();

        // Create text system
        const text_system = allocator.create(TextSystem) catch return error.OutOfMemory;
        text_system.* = try TextSystem.initWithScale(allocator, @floatCast(window.scale_factor), io);
        errdefer {
            text_system.deinit();
            allocator.destroy(text_system);
        }

        // Load font from config (named font or system default)
        if (font_config.font_name) |name| {
            try text_system.loadFont(name, font_config.font_size);
        } else {
            try text_system.loadSystemFont(.sans_serif, font_config.font_size);
        }

        // Set up text measurement callback
        layout_engine.setMeasureTextFn(measureTextCallback, text_system);

        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        // Create SVG atlas (owned)
        const svg_atlas = allocator.create(svg_mod.SvgAtlas) catch return error.OutOfMemory;
        svg_atlas.* = try svg_mod.SvgAtlas.init(allocator, window.scale_factor, io);
        errdefer {
            svg_atlas.deinit();
            allocator.destroy(svg_atlas);
        }

        // Create image atlas (owned)
        const image_atlas = allocator.create(image_mod.ImageAtlas) catch return error.OutOfMemory;
        image_atlas.* = try image_mod.ImageAtlas.init(allocator, window.scale_factor, io);
        errdefer {
            image_atlas.deinit();
            allocator.destroy(image_atlas);
        }

        var result: Self = .{
            .allocator = allocator,
            .io = io,
            .layout = layout_engine,
            .layout_owned = true,
            .scene = scene,
            .scene_owned = true,
            .dispatch = dispatch,
            .entities = EntityMap.init(allocator, io),
            .keymap = Keymap.init(allocator),
            .focus = FocusManager.init(allocator),
            .text_system = text_system,
            .text_system_owned = true,
            .svg_atlas = svg_atlas,
            .svg_atlas_owned = true,
            .image_atlas = image_atlas,
            .image_atlas_owned = true,
            .widgets = WidgetStore.init(allocator, io),
            .window = window,
            .width = @floatCast(window.size.width),
            .height = @floatCast(window.size.height),
            .scale_factor = @floatCast(window.scale_factor),
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
            // Image loader: zero-init the slot. Caller MUST invoke
            // `fixupImageLoadQueue` after copying `result` to its final
            // heap address — the embedded `Io.Queue` holds a pointer
            // into `result_buffer` that dangles after the by-value copy.
            .image_loader = undefined,
        };

        // Initialize accessibility subsystem in place. On macOS, the
        // bridge captures the NSWindow / NSView handles passed here; on
        // other platforms they are ignored.
        const window_obj = if (builtin.os.tag == .macos) window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) window.ns_view else null;
        result.a11y.initInPlace(window_obj, view_obj);

        // Initialize the image loader subsystem in place. The result is
        // about to be copied to the caller's heap address; the queue
        // pointer will dangle until `fixupImageLoadQueue` re-binds it.
        result.image_loader.initInPlace(io, allocator, image_atlas);

        return result;
    }

    /// Initialize Gooey in-place using out-pointer pattern.
    /// This avoids stack overflow on WASM where the Gooey struct (~400KB with a11y)
    /// would exceed the default stack size if returned by value.
    ///
    /// Usage:
    /// ```
    /// const gooey_ptr = try allocator.create(Gooey);
    /// try gooey_ptr.initOwnedPtr(allocator, window);
    /// ```
    /// Marked noinline to prevent stack accumulation in WASM builds.
    /// Without this, the compiler inlines all sub-functions creating a 2MB+ stack frame.
    pub noinline fn initOwnedPtr(self: *Self, allocator: std.mem.Allocator, window: *Window, font_config: FontConfig, io: std.Io) !void {
        // Create layout engine
        const layout_engine = allocator.create(LayoutEngine) catch return error.OutOfMemory;
        layout_engine.* = LayoutEngine.init(allocator);
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

        // Create scene
        const scene = allocator.create(Scene) catch return error.OutOfMemory;
        scene.* = Scene.init(allocator);
        errdefer {
            scene.deinit();
            allocator.destroy(scene);
        }

        // Enable viewport culling with initial window size
        scene.setViewport(
            @floatCast(window.size.width),
            @floatCast(window.size.height),
        );
        scene.enableCulling();

        // Create text system (initInPlace avoids 1.7MB stack temp)
        const text_system = allocator.create(TextSystem) catch return error.OutOfMemory;
        try text_system.initInPlace(allocator, @floatCast(window.scale_factor), io);
        errdefer {
            text_system.deinit();
            allocator.destroy(text_system);
        }

        // Load font from config (named font or system default)
        if (font_config.font_name) |name| {
            try text_system.loadFont(name, font_config.font_size);
        } else {
            try text_system.loadSystemFont(.sans_serif, font_config.font_size);
        }

        // Set up text measurement callback
        layout_engine.setMeasureTextFn(measureTextCallback, text_system);

        // Create dispatch tree
        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        // Field-by-field init avoids ~400KB stack temp from struct literal
        // Core resources
        self.allocator = allocator;
        self.io = io;
        self.layout = layout_engine;
        self.layout_owned = true;
        self.scene = scene;
        self.scene_owned = true;
        self.dispatch = dispatch;
        self.text_system = text_system;
        self.text_system_owned = true;
        self.window = window;

        // Small structs
        self.entities = EntityMap.init(allocator, io);
        self.keymap = Keymap.init(allocator);
        self.focus = FocusManager.init(allocator);
        self.widgets = WidgetStore.init(allocator, io);

        // Create SVG atlas (owned)
        const svg_atlas = allocator.create(svg_mod.SvgAtlas) catch return error.OutOfMemory;
        svg_atlas.* = try svg_mod.SvgAtlas.init(allocator, window.scale_factor, io);
        self.svg_atlas = svg_atlas;
        self.svg_atlas_owned = true;

        // Create image atlas (owned)
        const image_atlas = allocator.create(image_mod.ImageAtlas) catch return error.OutOfMemory;
        image_atlas.* = try image_mod.ImageAtlas.init(allocator, window.scale_factor, io);
        self.image_atlas = image_atlas;
        self.image_atlas_owned = true;

        // Scalar fields
        self.width = @floatCast(window.size.width);
        self.height = @floatCast(window.size.height);
        self.scale_factor = @floatCast(window.scale_factor);
        self.frame_count = 0;
        self.needs_render = false;
        self.debugger = .{};

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
        const window_obj = if (builtin.os.tag == .macos) window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) window.ns_view else null;
        self.a11y.initInPlace(window_obj, view_obj);

        // Initialize image loader in place — safe here because `self` is
        // already at its final heap address (no struct-literal copy can
        // dangle the embedded queue pointer).
        self.image_loader.initInPlace(io, allocator, image_atlas);
    }

    /// Initialize Gooey with shared resources (text system, SVG atlas, image atlas).
    /// Used by MultiWindowApp to share expensive resources across windows.
    /// The caller retains ownership of the shared resources.
    pub fn initWithSharedResources(
        allocator: std.mem.Allocator,
        window: *Window,
        shared_text_system: *TextSystem,
        shared_svg_atlas: *svg_mod.SvgAtlas,
        shared_image_atlas: *image_mod.ImageAtlas,
        io: std.Io,
    ) !Self {
        // Assertions: validate inputs
        std.debug.assert(@intFromPtr(shared_text_system) != 0);
        std.debug.assert(@intFromPtr(shared_svg_atlas) != 0);
        std.debug.assert(@intFromPtr(shared_image_atlas) != 0);

        // Create layout engine (owned)
        const layout_engine = allocator.create(LayoutEngine) catch return error.OutOfMemory;
        layout_engine.* = LayoutEngine.init(allocator);
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

        // Create scene (owned)
        const scene = allocator.create(Scene) catch return error.OutOfMemory;
        scene.* = Scene.init(allocator);
        errdefer {
            scene.deinit();
            allocator.destroy(scene);
        }

        // Enable viewport culling with initial window size
        scene.setViewport(
            @floatCast(window.size.width),
            @floatCast(window.size.height),
        );
        scene.enableCulling();

        // Set up text measurement callback using shared text system
        layout_engine.setMeasureTextFn(measureTextCallback, shared_text_system);

        // Create dispatch tree (owned)
        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        var result: Self = .{
            .allocator = allocator,
            .io = io,
            .layout = layout_engine,
            .layout_owned = true,
            .scene = scene,
            .scene_owned = true,
            .dispatch = dispatch,
            .entities = EntityMap.init(allocator, io),
            .keymap = Keymap.init(allocator),
            .focus = FocusManager.init(allocator),
            // Shared resources (not owned)
            .text_system = shared_text_system,
            .text_system_owned = false,
            .svg_atlas = shared_svg_atlas,
            .svg_atlas_owned = false,
            .image_atlas = shared_image_atlas,
            .image_atlas_owned = false,
            .widgets = WidgetStore.init(allocator, io),
            .window = window,
            .width = @floatCast(window.size.width),
            .height = @floatCast(window.size.height),
            .scale_factor = @floatCast(window.scale_factor),
            .hover = HoverState.init(),
            .blur_handlers = BlurHandlerRegistry.init(),
            .cancel_registry = CancelRegistry.init(),
            .a11y = undefined,
            // Image loader: see comment in `initOwned` — by-value copy
            // requires a `fixupImageLoadQueue` call after the result is
            // moved to its final heap address.
            .image_loader = undefined,
        };

        // Initialize platform-specific accessibility bridge
        const window_obj = if (builtin.os.tag == .macos) window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) window.ns_view else null;
        result.a11y.initInPlace(window_obj, view_obj);

        // Initialize the image loader against the SHARED atlas.
        result.image_loader.initInPlace(io, allocator, shared_image_atlas);

        return result;
    }

    /// Initialize Gooey in-place with shared resources.
    /// Used by MultiWindowApp on WASM to avoid stack overflow.
    /// Marked noinline to prevent stack accumulation.
    pub noinline fn initWithSharedResourcesPtr(
        self: *Self,
        allocator: std.mem.Allocator,
        window: *Window,
        shared_text_system: *TextSystem,
        shared_svg_atlas: *svg_mod.SvgAtlas,
        shared_image_atlas: *image_mod.ImageAtlas,
        io: std.Io,
    ) !void {
        // Assertions: validate inputs
        std.debug.assert(@intFromPtr(shared_text_system) != 0);
        std.debug.assert(@intFromPtr(shared_svg_atlas) != 0);
        std.debug.assert(@intFromPtr(shared_image_atlas) != 0);

        // Create layout engine (owned)
        const layout_engine = allocator.create(LayoutEngine) catch return error.OutOfMemory;
        layout_engine.* = LayoutEngine.init(allocator);
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

        // Create scene (owned)
        const scene = allocator.create(Scene) catch return error.OutOfMemory;
        scene.* = Scene.init(allocator);
        errdefer {
            scene.deinit();
            allocator.destroy(scene);
        }

        // Enable viewport culling with initial window size
        scene.setViewport(
            @floatCast(window.size.width),
            @floatCast(window.size.height),
        );
        scene.enableCulling();

        // Set up text measurement callback using shared text system
        layout_engine.setMeasureTextFn(measureTextCallback, shared_text_system);

        // Create dispatch tree (owned)
        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        // Field-by-field init avoids stack temp from struct literal
        self.allocator = allocator;
        self.io = io;
        self.layout = layout_engine;
        self.layout_owned = true;
        self.scene = scene;
        self.scene_owned = true;
        self.dispatch = dispatch;

        // Shared resources (not owned)
        self.text_system = shared_text_system;
        self.text_system_owned = false;
        self.svg_atlas = shared_svg_atlas;
        self.svg_atlas_owned = false;
        self.image_atlas = shared_image_atlas;
        self.image_atlas_owned = false;

        self.window = window;

        // Small structs
        self.entities = EntityMap.init(allocator, io);
        self.keymap = Keymap.init(allocator);
        self.focus = FocusManager.init(allocator);
        self.widgets = WidgetStore.init(allocator, io);

        // Scalar fields
        self.width = @floatCast(window.size.width);
        self.height = @floatCast(window.size.height);
        self.scale_factor = @floatCast(window.scale_factor);
        self.frame_count = 0;
        self.needs_render = false;
        self.debugger = .{};

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
        const window_obj = if (builtin.os.tag == .macos) window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) window.ns_view else null;
        self.a11y.initInPlace(window_obj, view_obj);

        // Initialize image loader against the SHARED atlas. Safe to do
        // here without a fixup because `self` is already at its final
        // heap address (the embedded queue pointer cannot dangle).
        self.image_loader.initInPlace(io, allocator, shared_image_atlas);
    }

    pub fn deinit(self: *Self) void {
        // Tear down the image loader subsystem first: closes the result
        // queue (background tasks see closure on next put), cancels the
        // fetch group (in-flight tasks unwind cleanly). Blocking is
        // acceptable here — we are shutting down.
        self.image_loader.deinit();

        // Cancel all registered cancel groups before any teardown.
        // Blocking is acceptable — we are shutting down.
        self.cancel_registry.cancelAll(self.io);

        // Clean up accessibility subsystem (deinit drops the bridge).
        self.a11y.deinit();

        // Blur handlers use fixed-capacity storage, no cleanup needed

        self.widgets.deinit();
        self.focus.deinit();
        self.entities.deinit();

        if (self.svg_atlas_owned) {
            self.svg_atlas.deinit();
            self.allocator.destroy(self.svg_atlas);
        }
        if (self.image_atlas_owned) {
            self.image_atlas.deinit();
            self.allocator.destroy(self.image_atlas);
        }

        // Clean up dispatch tree
        self.dispatch.deinit();
        self.allocator.destroy(self.dispatch);

        self.keymap.deinit();

        if (self.text_system_owned) {
            self.text_system.deinit();
            self.allocator.destroy(self.text_system);
        }
        if (self.scene_owned) {
            self.scene.deinit();
            self.allocator.destroy(self.scene);
        }
        if (self.layout_owned) {
            self.layout.deinit();
            self.allocator.destroy(self.layout);
        }
    }

    // =========================================================================
    // Frame Lifecycle
    // =========================================================================

    /// Call at the start of each frame before building UI
    pub fn beginFrame(self: *Self) void {
        // Start profiler frame timing
        self.debugger.beginFrame(self.io);

        self.frame_count += 1;
        self.widgets.beginFrame();
        self.focus.beginFrame();
        self.image_atlas.*.beginFrame();

        // Drain async image load results and cache into atlas.
        // Order matters: must run after `image_atlas.beginFrame()` so
        // any per-frame atlas reset has completed before we write
        // freshly-decoded pixels into it.
        self.image_loader.drain();

        // Clear stale entity observations from last frame
        self.entities.beginFrame();

        // Update cached window dimensions
        if (self.window) |w| {
            self.width = @floatCast(w.size.width);
            self.height = @floatCast(w.size.height);
            self.scale_factor = @floatCast(w.scale_factor);
        }

        // Sync scale factor to text system for correct glyph rasterization
        // self.text_system.setScaleFactor(self.scale_factor);

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
    pub fn endFrame(self: *Self) ![]const RenderCommand {
        self.widgets.endFrame();
        self.focus.endFrame();

        // Finalize frame observations
        self.entities.endFrame();

        // Request another frame if animations are running
        if (self.hasActiveAnimations()) {
            self.requestRender();
        }

        // End layout and get render commands — time only the actual layout compute
        self.debugger.beginLayout(self.io);
        const commands = try self.layout.endFrame();
        self.debugger.endLayout(self.io);

        // Accessibility: finalize tree, sync bounds, push to platform
        // (zero cost when disabled — the subsystem early-outs).
        self.a11y.endFrame(self.layout);

        return commands;
    }

    /// Finalize frame timing (call after all rendering is complete)
    pub fn finalizeFrame(self: *Self) void {
        self.debugger.endFrame(self.io, &render_stats.frame_stats);
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

    /// Open a layout element (container)
    pub fn openElement(self: *Self, decl: ElementDeclaration) !void {
        try self.layout.openElement(decl);
    }

    /// Close the current layout element
    pub fn closeElement(self: *Self) void {
        self.layout.closeElement();
    }

    /// Add a text element
    pub fn text(self: *Self, content: []const u8, config: TextConfig) !void {
        try self.layout.text(content, config);
    }

    // =========================================================================
    // Widget Access — moved to `gooey.widgets.*`
    // =========================================================================
    //
    // PR 4 (`docs/cleanup-implementation-plan.md`): the per-widget-type
    // forwarders (`textInput` / `textArea` / `codeEditor` / their
    // `*OrPanic` siblings, `getFocused*`, and `focusText*` /
    // `focusCodeEditor`) used to live here, each one importing the
    // concrete widget state type and so dragging the
    // `context → widgets` backward edge into `Gooey`. They are deleted
    // outright — callers in `runtime/`, `cx.zig`, and user code reach
    // through `gooey.widgets.textInput(id)` / `gooey.widgets.textArea(id)`
    // / `gooey.widgets.codeEditor(id)` directly, and trigger focus via
    // the generic `gooey.focusWidget(id)` below (which routes through
    // the `Focusable` vtable on `FocusManager` — no widget-type switch).
    //
    // Adding a new focusable widget type now touches only `widgets/`:
    // the widget exposes `pub fn focusable(self) Focusable` and the
    // builder registers that vtable on its `FocusHandle`. `Gooey`
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
    /// `Focusable` vtable; `Gooey` only owns the blur-handler dispatch.
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
    // used by `runtime/frame.zig` (`gooey.registerBlurHandler` /
    // `gooey.clearBlurHandlers`).

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

    /// Create a new entity
    pub fn createEntity(self: *Self, comptime T: type, value: T) !entity_mod.Entity(T) {
        return self.entities.new(T, value);
    }

    /// Read an entity's data
    pub fn readEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*const T {
        return self.entities.read(T, entity);
    }

    /// Get mutable access to an entity
    pub fn writeEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*T {
        return self.entities.write(T, entity);
    }

    /// Process entity notifications (called during frame)
    pub fn processEntityNotifications(self: *Self) bool {
        return self.entities.processNotifications();
    }

    /// Get the entity map
    pub fn getEntities(self: *Self) *EntityMap {
        return &self.entities;
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
    /// fn quitApp(_: *AppState, g: *Gooey) void {
    ///     g.quit();
    /// }
    /// // In render:
    /// Button{ .on_click_handler = cx.command(AppState.quitApp) }
    /// ```
    pub fn quit(self: *Self) void {
        if (comptime platform.is_wasm) {
            // No-op on web - can't quit browser
        } else if (comptime platform.is_linux) {
            if (self.window) |w| {
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

        try self.text_system.loadFont(name, size);
        self.requestRender();
    }

    /// Mark that a re-render is needed
    pub fn requestRender(self: *Self) void {
        self.needs_render = true;
        if (self.window) |w| {
            w.requestRender();
        }
    }

    /// Set the window appearance (light or dark mode)
    /// This affects the titlebar text color and other system UI elements (macOS)
    pub fn setAppearance(self: *Self, dark: bool) void {
        if (self.window) |w| {
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
        return self.text_system;
    }

    pub fn getLayout(self: *Self) *LayoutEngine {
        return self.layout;
    }

    pub fn getWindow(self: *Self) ?*Window {
        return self.window;
    }

    /// Set the accent color uniform for custom shaders
    /// The alpha channel can be used as a mode selector
    pub fn setAccentColor(self: *Gooey, r: f32, g: f32, b: f32, a: f32) void {
        if (self.window) |w| {
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
// These tests cover the deferred-command queue, which stays on `Gooey`.
// They construct a minimal `Gooey` value via field-by-field init, leaving
// every resource pointer at `undefined` — the deferred-command path
// reads only `deferred_commands`, `deferred_count`, `root_state_*`,
// `needs_render`, and `window`, so the test exercise the path without
// standing up a full UI stack.
//
// Hover / blur / cancel / a11y subsystems have their own unit tests in
// the respective modules; this file no longer needs to test them.

const testing = std.testing;

/// Build a stub `Gooey` for deferred-command tests. Resources stay
/// `undefined` because the tested path does not touch them; `window`
/// is `null` so `requestRender` is a no-op.
fn testGooey() Gooey {
    return .{
        .allocator = testing.allocator,
        .io = undefined,
        .layout = undefined,
        .scene = undefined,
        .text_system = undefined,
        .svg_atlas = undefined,
        .image_atlas = undefined,
        .widgets = undefined,
        .focus = undefined,
        .dispatch = undefined,
        .keymap = undefined,
        .entities = undefined,
        .window = null,
        .hover = HoverState.init(),
        .blur_handlers = BlurHandlerRegistry.init(),
        .cancel_registry = CancelRegistry.init(),
        .a11y = undefined,
        .image_loader = undefined,
        .deferred_count = 0,
        .deferred_commands = undefined,
        .needs_render = false,
    };
}

test "deferCommand queues command" {
    const TestState = struct {
        value: i32 = 0,
        pub fn increment(self: *@This(), _: *Gooey) void {
            self.value += 1;
        }
    };

    var state = TestState{};
    var g = testGooey();
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
        pub fn setValue(self: *@This(), _: *Gooey, new_value: i32) void {
            self.value = new_value;
        }
    };

    var state = TestState{};
    var g = testGooey();
    g.setRootState(TestState, &state);

    g.deferCommandWith(@as(i32, 42), TestState.setValue);
    g.flushDeferredCommands();
    try testing.expectEqual(@as(i32, 42), state.value);
}

test "multiple deferWith calls preserve their arguments" {
    const TestState = struct {
        sum: i32 = 0,
        pub fn addValue(self: *@This(), _: *Gooey, value: i32) void {
            self.sum += value;
        }
    };

    var state = TestState{};
    var g = testGooey();
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
        pub fn noop(_: *@This(), _: *Gooey) void {}
    };

    var state = TestState{};
    var g = testGooey();
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
        pub fn noop(_: *@This(), _: *Gooey) void {}
    };

    var state = TestState{};
    var g = testGooey();
    g.setRootState(TestState, &state);

    try testing.expect(!g.hasDeferredCommands());

    g.deferCommand(TestState.noop);
    try testing.expect(g.hasDeferredCommands());

    g.flushDeferredCommands();
    try testing.expect(!g.hasDeferredCommands());
}
