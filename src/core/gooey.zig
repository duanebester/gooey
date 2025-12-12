//! Gooey - Unified UI context
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

// Layout
const layout_mod = @import("../layout/layout.zig");
const engine_mod = @import("../layout/engine.zig");
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

const action_mod = @import("action.zig");
const Keymap = action_mod.Keymap;

// Scene
const scene_mod = @import("scene.zig");
const Scene = scene_mod.Scene;

// Text
const text_mod = @import("../text/mod.zig");
const TextSystem = text_mod.TextSystem;

// Widgets
const widget_store_mod = @import("widget_store.zig");
const WidgetStore = widget_store_mod.WidgetStore;
const TextInput = @import("../elements/text_input.zig").TextInput;

// Platform
const Window = @import("../platform/mac/window.zig").Window;

// Input
const input_mod = @import("input.zig");
const InputEvent = input_mod.InputEvent;

// Focus
const focus_mod = @import("focus.zig");
const FocusManager = focus_mod.FocusManager;
const FocusId = focus_mod.FocusId;
const FocusHandle = focus_mod.FocusHandle;
const FocusEvent = focus_mod.FocusEvent;

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

    // Widgets (retained across frames)
    widgets: WidgetStore,

    // Focus management
    focus: FocusManager,

    /// Dispatch tree for event routing
    dispatch: *DispatchTree,

    /// Keymap for action bindings
    keymap: Keymap,

    /// Entity storage for GPUI-style state management
    entities: EntityMap,

    // Platform
    window: *Window,

    // Frame state
    frame_count: u64 = 0,
    needs_render: bool = true,

    // Window dimensions (cached for convenience)
    width: f32 = 0,
    height: f32 = 0,
    scale_factor: f32 = 1.0,

    const Self = @This();

    /// Initialize Gooey with existing resources (non-owning)
    /// Use this when you already have LayoutEngine, Scene, TextSystem created
    pub fn init(
        allocator: std.mem.Allocator,
        window: *Window,
        layout_engine: *LayoutEngine,
        scene: *Scene,
        text_system: *TextSystem,
    ) Self {
        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);
        return .{
            .allocator = allocator,
            .layout = layout_engine,
            .scene = scene,
            .dispatch = dispatch,
            .entities = EntityMap.init(allocator),
            .keymap = Keymap.init(allocator),
            .focus = FocusManager.init(allocator),
            .text_system = text_system,
            .widgets = WidgetStore.init(allocator),
            .window = window,
            .width = @floatCast(window.size.width),
            .height = @floatCast(window.size.height),
            .scale_factor = @floatCast(window.scale_factor),
        };
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

        // Create text system
        const text_system = allocator.create(TextSystem) catch return error.OutOfMemory;
        text_system.* = try TextSystem.initWithScale(allocator, @floatCast(window.scale_factor));
        errdefer {
            text_system.deinit();
            allocator.destroy(text_system);
        }

        // Load default font
        try text_system.loadFont("SF Mono", 16.0); // Changed from "Menlo"

        // Set up text measurement callback
        layout_engine.setMeasureTextFn(measureTextCallback, text_system);

        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        return .{
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
            .widgets = WidgetStore.init(allocator),
            .window = window,
            .width = @floatCast(window.size.width),
            .height = @floatCast(window.size.height),
            .scale_factor = @floatCast(window.scale_factor),
        };
    }

    pub fn deinit(self: *Self) void {
        self.widgets.deinit();
        self.focus.deinit();
        self.entities.deinit();

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
        self.frame_count += 1;
        self.widgets.beginFrame();
        self.focus.beginFrame();

        // Update cached window dimensions
        self.width = @floatCast(self.window.size.width);
        self.height = @floatCast(self.window.size.height);
        self.scale_factor = @floatCast(self.window.scale_factor);

        // Clear scene for new frame
        self.scene.clear();

        // Begin layout pass
        self.layout.beginFrame(self.width, self.height);
    }

    /// Call at the end of each frame after building UI
    /// Returns the render commands for the frame
    pub fn endFrame(self: *Self) ![]const RenderCommand {
        self.widgets.endFrame();
        self.focus.endFrame();

        // End layout and get render commands
        return try self.layout.endFrame();
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
        self.focus.blur();
        self.widgets.blurAll();
        self.requestRender();
    }

    /// Check if element is focused
    pub fn isElementFocused(self: *Self, id: []const u8) bool {
        return self.focus.isFocusedByName(id);
    }

    /// Sync widget focus state with FocusManager
    fn syncWidgetFocus(self: *Self, id: []const u8) void {
        // Blur all widgets first
        self.widgets.blurAll();
        // Focus the specific widget if it exists
        if (self.widgets.text_inputs.get(id)) |input| {
            input.focus();
        } else if (self.widgets.checkboxes.get(id)) |cb| {
            cb.focus();
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
    // Render Control
    // =========================================================================

    /// Mark that a re-render is needed
    pub fn requestRender(self: *Self) void {
        self.needs_render = true;
        self.window.requestRender();
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

    pub fn getWindow(self: *Self) *Window {
        return self.window;
    }
};

/// Text measurement callback for layout engine
fn measureTextCallback(
    text_content: []const u8,
    _: u16, // font_id
    _: u16, // font_size
    _: ?f32, // max_width
    user_data: ?*anyopaque,
) TextMeasurement {
    if (user_data) |ptr| {
        const text_system: *TextSystem = @ptrCast(@alignCast(ptr));
        const width = text_system.measureText(text_content) catch 0;
        const metrics = text_system.getMetrics();
        return .{
            .width = width,
            .height = if (metrics) |m| m.line_height else 20,
        };
    }
    return .{
        .width = @as(f32, @floatFromInt(text_content.len)) * 10,
        .height = 20,
    };
}
