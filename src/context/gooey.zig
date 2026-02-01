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

// Accessibility
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
const TextInput = @import("../widgets/text_input_state.zig").TextInput;
const TextArea = @import("../widgets/text_area_state.zig").TextArea;
const CodeEditorState = @import("../widgets/code_editor_state.zig").CodeEditorState;

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

// Deferred command infrastructure
const MAX_DEFERRED_COMMANDS = 32;

const DeferredCommand = struct {
    callback: *const fn (*Gooey, u64) void,
    packed_arg: u64,
};

// Blur handler infrastructure (fixed-capacity to avoid dynamic allocation)
const MAX_BLUR_HANDLERS: usize = 64;

const BlurHandlerEntry = struct {
    id: []const u8,
    handler: HandlerRef,
};

/// Gooey - unified UI context
pub const Gooey = struct {
    allocator: std.mem.Allocator,

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

    // Hover state - tracks which layout element is currently hovered
    // This is the layout_id (hash) of the hovered element, persists across frames
    hovered_layout_id: ?u32 = null,

    // Last known mouse position (for re-hit-testing after bounds sync)
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,

    // Cached ancestor layout_ids of the hovered element (for isHoveredOrDescendant)
    // This is populated in updateHover before dispatch tree is reset
    hovered_ancestors: [32]u32 = [_]u32{0} ** 32,
    hovered_ancestor_count: u8 = 0,

    // Track if hover changed to trigger re-render
    hover_changed: bool = false,

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

    // Accessibility (Phase 1: Gooey Integration, Phase 2: Platform Bridges)
    /// Accessibility tree (rebuilt each frame, zero-alloc after init)
    a11y_tree: a11y.Tree,

    /// Platform-specific bridge storage (macOS: MacBridge, others: null)
    a11y_platform_bridge: a11y.PlatformBridge,

    /// Platform accessibility bridge interface (VoiceOver, AT-SPI2, ARIA)
    a11y_bridge: a11y.Bridge,

    /// Is accessibility enabled? (cached, checked periodically)
    a11y_enabled: bool = false,

    /// Frame counter for periodic screen reader checks
    a11y_check_counter: u32 = 0,

    // Thread Dispatcher (Phase 5: Gooey owns dispatcher)
    /// Thread dispatcher for cross-thread callbacks to main thread.
    /// Null on WASM (no threads). Initialized automatically on native platforms.
    /// Owned by Gooey - automatically cleaned up in deinit().
    thread_dispatcher: if (platform.is_wasm) void else ?*platform.Dispatcher =
        if (platform.is_wasm) {} else null,

    // Per-window root state for handler callbacks (multi-window support)
    /// Type-erased pointer to this window's root state
    root_state_ptr: ?*anyopaque = null,
    /// Type ID for runtime type checking of root state
    root_state_type_id: usize = 0,

    // Deferred command queue (for operations that must run after event handling)
    deferred_commands: [MAX_DEFERRED_COMMANDS]DeferredCommand = undefined,
    deferred_count: u8 = 0,

    // Blur handlers for text fields (registered per frame from pending items)
    // Fixed-capacity storage to avoid dynamic allocation during rendering
    blur_handlers: [MAX_BLUR_HANDLERS]?BlurHandlerEntry = [_]?BlurHandlerEntry{null} ** MAX_BLUR_HANDLERS,
    blur_handler_count: usize = 0,

    // Guard to prevent double blur handler invocation within the same focus transition
    blur_handlers_invoked_this_transition: bool = false,

    const Self = @This();

    /// Get the type ID for a given type (used for runtime type checking).
    pub fn typeId(comptime T: type) usize {
        const name_ptr: [*]const u8 = @typeName(T).ptr;
        return @intFromPtr(name_ptr);
    }

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
    pub fn deferCommand(
        self: *Self,
        comptime State: type,
        comptime method: fn (*State, *Self) void,
    ) void {
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
    /// The argument is stored inline in the command struct (packed into u64),
    /// so multiple deferred calls with the same signature work correctly.
    pub fn deferCommandWith(
        self: *Self,
        comptime State: type,
        comptime Arg: type,
        arg: Arg,
        comptime method: fn (*State, *Self, Arg) void,
    ) void {
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
    pub fn initOwned(allocator: std.mem.Allocator, window: *Window) !Self {
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
        text_system.* = try TextSystem.initWithScale(allocator, @floatCast(window.scale_factor));
        errdefer {
            text_system.deinit();
            allocator.destroy(text_system);
        }

        // Load default font - use system monospace for proper SF Mono behavior
        try text_system.loadSystemFont(.sans_serif, 16.0);

        // Set up text measurement callback
        layout_engine.setMeasureTextFn(measureTextCallback, text_system);

        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        // Create SVG atlas (owned)
        const svg_atlas = allocator.create(svg_mod.SvgAtlas) catch return error.OutOfMemory;
        svg_atlas.* = try svg_mod.SvgAtlas.init(allocator, window.scale_factor);
        errdefer {
            svg_atlas.deinit();
            allocator.destroy(svg_atlas);
        }

        // Create image atlas (owned)
        const image_atlas = allocator.create(image_mod.ImageAtlas) catch return error.OutOfMemory;
        image_atlas.* = try image_mod.ImageAtlas.init(allocator, window.scale_factor);
        errdefer {
            image_atlas.deinit();
            allocator.destroy(image_atlas);
        }

        var result: Self = .{
            .allocator = allocator,
            .layout = layout_engine,
            .layout_owned = true,
            .scene = scene,
            .scene_owned = true,
            .dispatch = dispatch,
            .entities = EntityMap.init(allocator),
            .keymap = Keymap.init(allocator),
            .focus = FocusManager.init(allocator),
            .text_system = text_system,
            .text_system_owned = true,
            .svg_atlas = svg_atlas,
            .svg_atlas_owned = true,
            .image_atlas = image_atlas,
            .image_atlas_owned = true,
            .widgets = WidgetStore.init(allocator),
            .window = window,
            .width = @floatCast(window.size.width),
            .height = @floatCast(window.size.height),
            .scale_factor = @floatCast(window.scale_factor),
            // Accessibility: static init, no allocations
            .a11y_tree = a11y.Tree.init(),
            .a11y_platform_bridge = undefined,
            .a11y_bridge = undefined, // Initialized below
            // Blur handlers for text fields (fixed-capacity, no allocation needed)
            .blur_handlers = [_]?BlurHandlerEntry{null} ** MAX_BLUR_HANDLERS,
            .blur_handler_count = 0,
        };

        // Initialize platform-specific accessibility bridge (Phase 2)
        // On macOS: MacBridge with VoiceOver support
        // On other platforms: NullBridge (no-op)
        const window_obj = if (builtin.os.tag == .macos) window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) window.ns_view else null;
        result.a11y_bridge = a11y.createPlatformBridge(&result.a11y_platform_bridge, window_obj, view_obj);

        // Initialize thread dispatcher (native only, Phase 5)
        if (!platform.is_wasm) {
            const dispatcher_ptr = try allocator.create(platform.Dispatcher);
            errdefer allocator.destroy(dispatcher_ptr);
            dispatcher_ptr.* = platform.Dispatcher.init(allocator);
            result.thread_dispatcher = dispatcher_ptr;

            // Wire to platform on Linux (automatic, no user action needed)
            if (platform.is_linux) {
                window.platform.setDispatcher(dispatcher_ptr);
            }
        }

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
    pub noinline fn initOwnedPtr(self: *Self, allocator: std.mem.Allocator, window: *Window) !void {
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
        try text_system.initInPlace(allocator, @floatCast(window.scale_factor));
        errdefer {
            text_system.deinit();
            allocator.destroy(text_system);
        }

        // Load default font - use system monospace for proper SF Mono behavior
        try text_system.loadSystemFont(.sans_serif, 16.0);

        // Set up text measurement callback
        layout_engine.setMeasureTextFn(measureTextCallback, text_system);

        // Create dispatch tree
        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        // Field-by-field init avoids ~400KB stack temp from struct literal
        // Core resources
        self.allocator = allocator;
        self.layout = layout_engine;
        self.layout_owned = true;
        self.scene = scene;
        self.scene_owned = true;
        self.dispatch = dispatch;
        self.text_system = text_system;
        self.text_system_owned = true;
        self.window = window;

        // Small structs
        self.entities = EntityMap.init(allocator);
        self.keymap = Keymap.init(allocator);
        self.focus = FocusManager.init(allocator);
        self.widgets = WidgetStore.init(allocator);

        // Create SVG atlas (owned)
        const svg_atlas = allocator.create(svg_mod.SvgAtlas) catch return error.OutOfMemory;
        svg_atlas.* = try svg_mod.SvgAtlas.init(allocator, window.scale_factor);
        self.svg_atlas = svg_atlas;
        self.svg_atlas_owned = true;

        // Create image atlas (owned)
        const image_atlas = allocator.create(image_mod.ImageAtlas) catch return error.OutOfMemory;
        image_atlas.* = try image_mod.ImageAtlas.init(allocator, window.scale_factor);
        self.image_atlas = image_atlas;
        self.image_atlas_owned = true;

        // Scalar fields
        self.width = @floatCast(window.size.width);
        self.height = @floatCast(window.size.height);
        self.scale_factor = @floatCast(window.scale_factor);
        self.frame_count = 0;
        self.needs_render = false;
        self.hovered_layout_id = null;
        self.last_mouse_x = 0;
        self.last_mouse_y = 0;
        self.hovered_ancestor_count = 0;
        self.hover_changed = false;
        self.debugger = .{};

        // Blur handlers for text fields (fixed-capacity, no allocation needed)
        self.blur_handlers = [_]?BlurHandlerEntry{null} ** MAX_BLUR_HANDLERS;
        self.blur_handler_count = 0;
        self.blur_handlers_invoked_this_transition = false;

        // Accessibility (initInPlace avoids ~350KB stack temp)
        self.a11y_tree.initInPlace();
        self.a11y_enabled = false;
        self.a11y_check_counter = 0;

        // Platform-specific accessibility bridge
        const window_obj = if (builtin.os.tag == .macos) window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) window.ns_view else null;
        self.a11y_bridge = a11y.createPlatformBridge(&self.a11y_platform_bridge, window_obj, view_obj);

        // Initialize thread dispatcher (native only, Phase 5)
        if (!platform.is_wasm) {
            const dispatcher_ptr = try allocator.create(platform.Dispatcher);
            errdefer allocator.destroy(dispatcher_ptr);
            dispatcher_ptr.* = platform.Dispatcher.init(allocator);
            self.thread_dispatcher = dispatcher_ptr;

            // Wire to platform on Linux (automatic, no user action needed)
            if (platform.is_linux) {
                window.platform.setDispatcher(dispatcher_ptr);
            }
        }
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
            .layout = layout_engine,
            .layout_owned = true,
            .scene = scene,
            .scene_owned = true,
            .dispatch = dispatch,
            .entities = EntityMap.init(allocator),
            .keymap = Keymap.init(allocator),
            .focus = FocusManager.init(allocator),
            // Shared resources (not owned)
            .text_system = shared_text_system,
            .text_system_owned = false,
            .svg_atlas = shared_svg_atlas,
            .svg_atlas_owned = false,
            .image_atlas = shared_image_atlas,
            .image_atlas_owned = false,
            .widgets = WidgetStore.init(allocator),
            .window = window,
            .width = @floatCast(window.size.width),
            .height = @floatCast(window.size.height),
            .scale_factor = @floatCast(window.scale_factor),
            // Accessibility: static init, no allocations
            .a11y_tree = a11y.Tree.init(),
            .a11y_platform_bridge = undefined,
            .a11y_bridge = undefined,
            // Blur handlers for text fields (fixed-capacity, no allocation needed)
            .blur_handlers = [_]?BlurHandlerEntry{null} ** MAX_BLUR_HANDLERS,
            .blur_handler_count = 0,
        };

        // Initialize platform-specific accessibility bridge
        const window_obj = if (builtin.os.tag == .macos) window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) window.ns_view else null;
        result.a11y_bridge = a11y.createPlatformBridge(&result.a11y_platform_bridge, window_obj, view_obj);

        // Initialize thread dispatcher (native only, Phase 5)
        if (!platform.is_wasm) {
            const dispatcher_ptr = try allocator.create(platform.Dispatcher);
            errdefer allocator.destroy(dispatcher_ptr);
            dispatcher_ptr.* = platform.Dispatcher.init(allocator);
            result.thread_dispatcher = dispatcher_ptr;

            // Wire to platform on Linux (automatic, no user action needed)
            if (platform.is_linux) {
                window.platform.setDispatcher(dispatcher_ptr);
            }
        }

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
        self.entities = EntityMap.init(allocator);
        self.keymap = Keymap.init(allocator);
        self.focus = FocusManager.init(allocator);
        self.widgets = WidgetStore.init(allocator);

        // Scalar fields
        self.width = @floatCast(window.size.width);
        self.height = @floatCast(window.size.height);
        self.scale_factor = @floatCast(window.scale_factor);
        self.frame_count = 0;
        self.needs_render = false;
        self.hovered_layout_id = null;
        self.last_mouse_x = 0;
        self.last_mouse_y = 0;
        self.hovered_ancestor_count = 0;
        self.hover_changed = false;
        self.debugger = .{};

        // Blur handlers for text fields (fixed-capacity, no allocation needed)
        self.blur_handlers = [_]?BlurHandlerEntry{null} ** MAX_BLUR_HANDLERS;
        self.blur_handler_count = 0;
        self.blur_handlers_invoked_this_transition = false;

        // Accessibility
        self.a11y_tree.initInPlace();
        self.a11y_enabled = false;
        self.a11y_check_counter = 0;

        // Platform-specific accessibility bridge
        const window_obj = if (builtin.os.tag == .macos) window.ns_window else null;
        const view_obj = if (builtin.os.tag == .macos) window.ns_view else null;
        self.a11y_bridge = a11y.createPlatformBridge(&self.a11y_platform_bridge, window_obj, view_obj);

        // Initialize thread dispatcher (native only, Phase 5)
        if (!platform.is_wasm) {
            const dispatcher_ptr = try allocator.create(platform.Dispatcher);
            errdefer allocator.destroy(dispatcher_ptr);
            dispatcher_ptr.* = platform.Dispatcher.init(allocator);
            self.thread_dispatcher = dispatcher_ptr;

            // Wire to platform on Linux (automatic, no user action needed)
            if (platform.is_linux) {
                window.platform.setDispatcher(dispatcher_ptr);
            }
        }
    }

    pub fn deinit(self: *Self) void {
        // Clean up thread dispatcher (native only, Phase 5)
        if (!platform.is_wasm) {
            if (self.thread_dispatcher) |d| {
                d.deinit();
                self.allocator.destroy(d);
            }
        }

        // Clean up accessibility bridge
        self.a11y_bridge.deinit();

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
    // Thread Dispatcher API (Phase 5)
    // =========================================================================

    /// Dispatch a callback to run on the main thread.
    /// Safe to call from any thread. Returns error on WASM (single-threaded).
    ///
    /// Usage:
    /// ```
    /// const Ctx = struct { app: *MyApp };
    /// try gooey.dispatchOnMainThread(Ctx, .{ .app = self }, struct {
    ///     fn handler(ctx: *Ctx) void {
    ///         ctx.app.handleOnMain();
    ///     }
    /// }.handler);
    /// ```
    pub fn dispatchOnMainThread(
        self: *Self,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        if (platform.is_wasm) return error.NotSupported;
        if (self.thread_dispatcher) |d| {
            try d.dispatchOnMainThread(Context, context, callback);
        } else {
            return error.NotInitialized;
        }
    }

    /// Dispatch a callback to run on the main thread after a delay.
    /// Safe to call from any thread. Returns error on WASM (single-threaded).
    ///
    /// Usage:
    /// ```
    /// // Run after 100ms
    /// try gooey.dispatchAfter(100_000_000, Ctx, .{ .app = self }, handler);
    /// ```
    pub fn dispatchAfter(
        self: *Self,
        delay_ns: u64,
        comptime Context: type,
        context: Context,
        comptime callback: fn (*Context) void,
    ) !void {
        if (platform.is_wasm) return error.NotSupported;
        if (self.thread_dispatcher) |d| {
            try d.dispatchAfter(delay_ns, Context, context, callback);
        } else {
            return error.NotInitialized;
        }
    }

    /// Check if current thread is the main/UI thread.
    /// Always returns true on WASM (single-threaded).
    pub fn isMainThread() bool {
        if (platform.is_wasm) return true;
        return platform.Dispatcher.isMainThread();
    }

    /// Get the underlying dispatcher for advanced usage.
    /// Returns null on WASM or if not initialized.
    pub fn getDispatcher(self: *Self) ?*platform.Dispatcher {
        if (platform.is_wasm) return null;
        return self.thread_dispatcher;
    }

    // =========================================================================
    // Frame Lifecycle
    // =========================================================================

    /// Call at the start of each frame before building UI
    pub fn beginFrame(self: *Self) void {
        // Start profiler frame timing
        self.debugger.beginFrame();

        self.frame_count += 1;
        self.widgets.beginFrame();
        self.focus.beginFrame();
        self.image_atlas.*.beginFrame();

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

        // Begin layout pass
        self.debugger.beginLayout();
        self.layout.beginFrame(self.width, self.height);

        // Clear hover_changed flag at frame start
        self.hover_changed = false;

        // Clear drag-over target (recalculated each frame during drag)
        self.drag_over_target = null;

        // Accessibility: periodic screen reader check (not every frame)
        self.a11y_check_counter += 1;
        if (self.a11y_check_counter >= a11y.constants.SCREEN_READER_CHECK_INTERVAL) {
            self.a11y_check_counter = 0;
            self.a11y_enabled = self.a11y_bridge.isActive();
        }

        // Begin a11y tree if enabled (zero-cost when disabled)
        if (self.a11y_enabled) {
            self.a11y_tree.beginFrame();
        }
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

        // End layout and get render commands
        const commands = try self.layout.endFrame();
        self.debugger.endLayout();

        // Accessibility: finalize and sync to platform (zero-cost when disabled)
        if (self.a11y_enabled) {
            self.a11y_tree.endFrame();

            // Sync bounds from layout to accessibility elements
            self.a11y_tree.syncBounds(self.layout);

            // Use syncFrame for complete frame sync
            self.a11y_bridge.syncFrame(&self.a11y_tree);
        }

        return commands;
    }

    /// Finalize frame timing (call after all rendering is complete)
    pub fn finalizeFrame(self: *Self) void {
        self.debugger.endFrame(&render_stats.frame_stats);
    }

    /// Check if any animations are running (call after endFrame)
    pub fn hasActiveAnimations(self: *const Self) bool {
        return self.widgets.hasActiveAnimations();
    }

    // =========================================================================
    // Hover State
    // =========================================================================

    /// Update hover state based on mouse position.
    /// Call this on mouse_moved events AFTER bounds have been synced.
    /// Returns true if hover state changed (requires re-render).
    pub fn updateHover(self: *Self, x: f32, y: f32) bool {
        // Store mouse position for re-hit-testing after bounds sync
        self.last_mouse_x = x;
        self.last_mouse_y = y;

        const old_hovered = self.hovered_layout_id;

        // Reset ancestor cache
        self.hovered_ancestor_count = 0;

        // Hit test using dispatch tree (which has bounds from last frame)
        if (self.dispatch.hitTest(x, y)) |node_id| {
            if (self.dispatch.getNodeConst(node_id)) |node| {
                self.hovered_layout_id = node.layout_id;

                // Cache the ancestor chain (walk up parent links)
                // This must happen NOW before dispatch tree is reset next frame
                var current = node_id;
                while (current.isValid() and self.hovered_ancestor_count < 32) {
                    if (self.dispatch.getNodeConst(current)) |n| {
                        if (n.layout_id) |lid| {
                            self.hovered_ancestors[self.hovered_ancestor_count] = lid;
                            self.hovered_ancestor_count += 1;
                        }
                        current = n.parent;
                    } else {
                        break;
                    }
                }
            } else {
                self.hovered_layout_id = null;
            }
        } else {
            self.hovered_layout_id = null;
        }

        // Check if hover changed
        const changed = old_hovered != self.hovered_layout_id;
        if (changed) {
            self.hover_changed = true;
        }
        return changed;
    }

    /// Refresh hover state using last known mouse position.
    /// Call this after bounds have been synced to fix frame delay issues.
    pub fn refreshHover(self: *Self) void {
        _ = self.updateHover(self.last_mouse_x, self.last_mouse_y);
    }

    /// Check if a specific layout element is currently hovered.
    pub fn isHovered(self: *const Self, layout_id: u32) bool {
        return self.hovered_layout_id == layout_id;
    }

    /// Check if a layout element (by LayoutId) is currently hovered.
    pub fn isLayoutIdHovered(self: *const Self, id: LayoutId) bool {
        return self.hovered_layout_id == id.id;
    }

    /// Check if the hovered element is the given layout_id OR a descendant of it.
    /// This is useful for tooltips where we want to show when hovering any child element.
    /// Uses the cached ancestor chain from the last updateHover call.
    pub fn isHoveredOrDescendant(self: *const Self, layout_id: u32) bool {
        // Check cached ancestor chain (populated during updateHover, before dispatch reset)
        for (self.hovered_ancestors[0..self.hovered_ancestor_count]) |ancestor_id| {
            if (ancestor_id == layout_id) return true;
        }
        return false;
    }

    /// Clear hover state (e.g., when mouse exits window)
    pub fn clearHover(self: *Self) void {
        if (self.hovered_layout_id != null) {
            self.hovered_layout_id = null;
            self.hover_changed = true;
        }
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
    // Widget Access
    // =========================================================================

    /// Get or create a TextInput by ID
    /// Returns null on allocation failure
    pub fn textInput(self: *Self, id: []const u8) ?*TextInput {
        return self.widgets.textInput(id);
    }

    /// Focus a TextInput by ID
    pub fn focusTextInput(self: *Self, id: []const u8) void {
        self.widgets.focusTextInput(id);
        // Also update FocusManager so action dispatch works
        self.focus.focusByName(id);
        self.requestRender();
    }

    /// Get currently focused TextInput
    pub fn getFocusedTextInput(self: *Self) ?*TextInput {
        return self.widgets.getFocusedTextInput();
    }

    pub fn textArea(self: *Self, id: []const u8) ?*TextArea {
        return self.widgets.textArea(id);
    }

    pub fn textAreaOrPanic(self: *Self, id: []const u8) *TextArea {
        return self.widgets.textAreaOrPanic(id);
    }

    pub fn focusTextArea(self: *Self, id: []const u8) void {
        // Blur any currently focused TextInput
        if (self.getFocusedTextInput()) |current| {
            current.blur();
        }
        // Blur any currently focused TextArea
        if (self.getFocusedTextArea()) |current| {
            current.blur();
        }
        // Focus the new one
        if (self.widgets.textArea(id)) |ta| {
            ta.focus();
        } else {}
        // Also update FocusManager so action dispatch works
        self.focus.focusByName(id);
        self.requestRender();
    }

    pub fn getFocusedTextArea(self: *Self) ?*TextArea {
        return self.widgets.getFocusedTextArea();
    }

    // =========================================================================
    // Code Editor
    // =========================================================================

    pub fn codeEditor(self: *Self, id: []const u8) ?*CodeEditorState {
        return self.widgets.codeEditor(id);
    }

    pub fn codeEditorOrPanic(self: *Self, id: []const u8) *CodeEditorState {
        return self.widgets.codeEditorOrPanic(id);
    }

    pub fn focusCodeEditor(self: *Self, id: []const u8) void {
        // Blur any currently focused TextInput
        if (self.getFocusedTextInput()) |current| {
            current.blur();
        }
        // Blur any currently focused TextArea
        if (self.getFocusedTextArea()) |current| {
            current.blur();
        }
        // Blur any currently focused CodeEditor
        if (self.getFocusedCodeEditor()) |current| {
            current.blur();
        }
        // Focus the new one
        if (self.widgets.codeEditor(id)) |ce| {
            ce.focus();
        } else {}
        // Also update FocusManager so action dispatch works
        self.focus.focusByName(id);
        self.requestRender();
    }

    pub fn getFocusedCodeEditor(self: *Self) ?*CodeEditorState {
        return self.widgets.getFocusedCodeEditor();
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

    /// Focus a specific element by ID
    pub fn focusElement(self: *Self, id: []const u8) void {
        self.focus.focusByName(id);
        // Also update widget focus state
        self.syncWidgetFocus(id);
        self.requestRender();
    }

    /// Move focus to next element in tab order
    pub fn focusNext(self: *Self) void {
        self.focus.focusNext();
        // Sync widget focus
        if (self.focus.getFocusedHandle()) |handle| {
            self.syncWidgetFocus(handle.string_id);
        }
        self.requestRender();
    }

    /// Move focus to previous element in tab order
    pub fn focusPrev(self: *Self) void {
        self.focus.focusPrev();
        if (self.focus.getFocusedHandle()) |handle| {
            self.syncWidgetFocus(handle.string_id);
        }
        self.requestRender();
    }

    /// Clear all focus
    pub fn blurAll(self: *Self) void {
        // Invoke blur handlers for any focused text fields before blurring
        self.invokeBlurHandlersForFocusedWidgets();
        self.focus.blur();
        self.widgets.blurAll();
        // Reset guard after complete focus transition to allow subsequent focus changes
        self.blur_handlers_invoked_this_transition = false;
        self.requestRender();
    }

    /// Check if element is focused
    pub fn isElementFocused(self: *Self, id: []const u8) bool {
        return self.focus.isFocusedByName(id);
    }

    /// Sync widget focus state with FocusManager.
    /// Invokes blur handlers for the previously focused widget, then focuses the new one.
    fn syncWidgetFocus(self: *Self, id: []const u8) void {
        // Invoke blur handlers for any focused text fields before blurring
        self.invokeBlurHandlersForFocusedWidgets();
        // Blur all widgets first
        self.widgets.blurAll();
        // Focus the specific widget if it exists (check both TextInput and TextArea)
        if (self.widgets.text_inputs.get(id)) |input| {
            input.focus();
        } else if (self.widgets.text_areas.get(id)) |ta| {
            ta.focus();
        }
        // Reset guard after complete focus transition to allow subsequent focus changes
        self.blur_handlers_invoked_this_transition = false;
    }

    // =========================================================================
    // Blur Handler Management
    // =========================================================================

    /// Register a blur handler for a text field ID.
    /// Called during frame rendering to register handlers from pending items.
    /// Uses fixed-capacity storage - logs warning if limit exceeded.
    pub fn registerBlurHandler(self: *Self, id: []const u8, handler: HandlerRef) void {
        std.debug.assert(id.len > 0); // ID must not be empty
        std.debug.assert(id.len <= 256); // Reasonable ID length limit

        // Check if already registered (update existing)
        // Only iterate up to blur_handler_count - slots beyond are guaranteed null
        for (self.blur_handlers[0..self.blur_handler_count]) |*slot| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, entry.id, id)) {
                    entry.handler = handler;
                    return;
                }
            }
        }

        // Find empty slot
        if (self.blur_handler_count < MAX_BLUR_HANDLERS) {
            self.blur_handlers[self.blur_handler_count] = .{ .id = id, .handler = handler };
            self.blur_handler_count += 1;
        } else {
            std.log.warn("Blur handler limit ({d}) exceeded - dropping handler for '{s}'", .{ MAX_BLUR_HANDLERS, id });
        }
    }

    /// Clear all registered blur handlers.
    /// Called at the start of each frame before processing pending items.
    pub fn clearBlurHandlers(self: *Self) void {
        // Only clear slots that were actually used
        for (self.blur_handlers[0..self.blur_handler_count]) |*slot| {
            slot.* = null;
        }
        self.blur_handler_count = 0;
        self.blur_handlers_invoked_this_transition = false;
    }

    /// Look up a blur handler by field ID.
    fn getBlurHandler(self: *const Self, id: []const u8) ?HandlerRef {
        // Only search slots that are actually populated
        for (self.blur_handlers[0..self.blur_handler_count]) |slot| {
            if (slot) |entry| {
                if (std.mem.eql(u8, entry.id, id)) {
                    return entry.handler;
                }
            }
        }
        return null;
    }

    /// Invoke blur handlers for any currently focused text widgets.
    /// Called before focus changes to notify the old focused element.
    ///
    /// The guard (`blur_handlers_invoked_this_frame`) prevents double invocation within
    /// a single focus transition. For example, when `blurAll()` is called, it invokes
    /// this function and then calls `widgets.blurAll()`. Without the guard, nested calls
    /// could fire handlers twice. The guard is reset after each complete focus transition
    /// in `syncWidgetFocus()` and `blurAll()`, allowing multiple focus changes per frame.
    fn invokeBlurHandlersForFocusedWidgets(self: *Self) void {
        // Guard against double invocation within a single focus transition
        if (self.blur_handlers_invoked_this_transition) return;
        self.blur_handlers_invoked_this_transition = true;

        // Check TextInputs
        var ti_it = self.widgets.text_inputs.iterator();
        while (ti_it.next()) |entry| {
            if (entry.value_ptr.*.isFocused()) {
                if (self.getBlurHandler(entry.key_ptr.*)) |handler| {
                    handler.invoke(self);
                }
            }
        }
        // Check TextAreas
        var ta_it = self.widgets.text_areas.iterator();
        while (ta_it.next()) |entry| {
            if (entry.value_ptr.*.isFocused()) {
                if (self.getBlurHandler(entry.key_ptr.*)) |handler| {
                    handler.invoke(self);
                }
            }
        }
        // Check CodeEditors
        var ce_it = self.widgets.code_editors.iterator();
        while (ce_it.next()) |entry| {
            if (entry.value_ptr.*.isFocused()) {
                if (self.getBlurHandler(entry.key_ptr.*)) |handler| {
                    handler.invoke(self);
                }
            }
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
    // Render Control
    // =========================================================================

    /// Mark that a re-render is needed
    pub fn requestRender(self: *Self) void {
        self.needs_render = true;
        if (self.window) |w| {
            w.requestRender();
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
    // Accessibility (Phase 1)
    // =========================================================================

    /// Check if accessibility is currently active (screen reader detected)
    pub fn isA11yEnabled(self: *const Self) bool {
        return self.a11y_enabled;
    }

    /// Force enable accessibility (for testing/debugging)
    pub fn enableA11y(self: *Self) void {
        self.a11y_enabled = true;
    }

    /// Force disable accessibility
    pub fn disableA11y(self: *Self) void {
        self.a11y_enabled = false;
    }

    /// Get a mutable reference to the accessibility tree
    /// Only valid during frame (between beginFrame/endFrame)
    pub fn getA11yTree(self: *Self) *a11y.Tree {
        return &self.a11y_tree;
    }

    /// Announce a message to screen readers
    /// Convenience wrapper for a11y_tree.announce()
    pub fn announce(self: *Self, message: []const u8, priority: a11y.Live) void {
        if (self.a11y_enabled) {
            self.a11y_tree.announce(message, priority);
        }
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

test "deferCommand queues command" {
    const TestState = struct {
        value: i32 = 0,

        pub fn increment(self: *@This(), _: *Gooey) void {
            self.value += 1;
        }
    };

    // Heap-allocate Gooey (>400KB - too large for stack per CLAUDE.md)
    const gooey = try std.testing.allocator.create(Gooey);
    defer std.testing.allocator.destroy(gooey);

    gooey.deferred_count = 0;
    gooey.root_state_ptr = null;
    gooey.root_state_type_id = 0;
    gooey.needs_render = false;
    gooey.window = null; // No window for tests

    var state = TestState{};
    gooey.setRootState(TestState, &state);

    // Queue a deferred command
    gooey.deferCommand(TestState, TestState.increment);

    // Should be queued but not executed yet
    try std.testing.expectEqual(@as(u8, 1), gooey.deferred_count);
    try std.testing.expectEqual(@as(i32, 0), state.value);

    // Flush should execute the command
    gooey.flushDeferredCommands();

    try std.testing.expectEqual(@as(u8, 0), gooey.deferred_count);
    try std.testing.expectEqual(@as(i32, 1), state.value);
}

test "deferCommandWith passes argument" {
    const TestState = struct {
        value: i32 = 0,

        pub fn setValue(self: *@This(), _: *Gooey, val: i32) void {
            self.value = val;
        }
    };

    // Heap-allocate Gooey (>400KB - too large for stack per CLAUDE.md)
    const gooey = try std.testing.allocator.create(Gooey);
    defer std.testing.allocator.destroy(gooey);

    gooey.deferred_count = 0;
    gooey.root_state_ptr = null;
    gooey.root_state_type_id = 0;
    gooey.needs_render = false;
    gooey.window = null; // No window for tests

    var state = TestState{};
    gooey.setRootState(TestState, &state);

    // Queue a deferred command with argument
    gooey.deferCommandWith(TestState, i32, 42, TestState.setValue);

    try std.testing.expectEqual(@as(u8, 1), gooey.deferred_count);
    try std.testing.expectEqual(@as(i32, 0), state.value);

    gooey.flushDeferredCommands();

    try std.testing.expectEqual(@as(i32, 42), state.value);
}

test "multiple deferWith calls preserve their arguments" {
    const TestState = struct {
        sum: i32 = 0,

        pub fn addValue(self: *@This(), _: *Gooey, val: i32) void {
            self.sum += val;
        }
    };

    // Heap-allocate Gooey (>400KB - too large for stack per CLAUDE.md)
    const gooey = try std.testing.allocator.create(Gooey);
    defer std.testing.allocator.destroy(gooey);

    gooey.deferred_count = 0;
    gooey.root_state_ptr = null;
    gooey.root_state_type_id = 0;
    gooey.needs_render = false;
    gooey.window = null; // No window for tests

    var state = TestState{};
    gooey.setRootState(TestState, &state);

    // Queue multiple commands with different arguments
    gooey.deferCommandWith(TestState, i32, 10, TestState.addValue);
    gooey.deferCommandWith(TestState, i32, 20, TestState.addValue);
    gooey.deferCommandWith(TestState, i32, 30, TestState.addValue);

    try std.testing.expectEqual(@as(u8, 3), gooey.deferred_count);

    gooey.flushDeferredCommands();

    // All three should have executed with their own arguments
    try std.testing.expectEqual(@as(i32, 60), state.sum);
}

test "deferred queue overflow is handled gracefully" {
    const TestState = struct {
        pub fn noop(_: *@This(), _: *Gooey) void {}
    };

    // Heap-allocate Gooey (>400KB - too large for stack per CLAUDE.md)
    const gooey = try std.testing.allocator.create(Gooey);
    defer std.testing.allocator.destroy(gooey);

    gooey.deferred_count = 0;
    gooey.root_state_ptr = null;
    gooey.root_state_type_id = 0;
    gooey.needs_render = false;
    gooey.window = null; // No window for tests

    var state = TestState{};
    gooey.setRootState(TestState, &state);

    // Fill the queue
    for (0..MAX_DEFERRED_COMMANDS) |_| {
        gooey.deferCommand(TestState, TestState.noop);
    }

    try std.testing.expectEqual(@as(u8, MAX_DEFERRED_COMMANDS), gooey.deferred_count);

    // This should not crash, just log a warning and drop the command
    gooey.deferCommand(TestState, TestState.noop);

    // Queue size should not exceed max
    try std.testing.expectEqual(@as(u8, MAX_DEFERRED_COMMANDS), gooey.deferred_count);

    // Clean up
    gooey.flushDeferredCommands();
}

test "hasDeferredCommands returns correct state" {
    // Heap-allocate Gooey (>400KB - too large for stack per CLAUDE.md)
    const gooey = try std.testing.allocator.create(Gooey);
    defer std.testing.allocator.destroy(gooey);

    gooey.deferred_count = 0;

    try std.testing.expect(!gooey.hasDeferredCommands());

    gooey.deferred_count = 1;
    try std.testing.expect(gooey.hasDeferredCommands());

    gooey.deferred_count = 0;
    try std.testing.expect(!gooey.hasDeferredCommands());
}
