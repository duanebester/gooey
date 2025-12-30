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
const debugger_mod = @import("debugger.zig");
const render_stats = @import("render_stats.zig");

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
const TextInput = @import("../widgets/text_input.zig").TextInput;
const TextArea = @import("../widgets/text_area.zig").TextArea;

// Platform
const platform = @import("../platform/mod.zig");
const Window = platform.Window;

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

    svg_atlas: svg_mod.SvgAtlas,
    image_atlas: image_mod.ImageAtlas,

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

    /// UI Debugger/Inspector (toggle with Cmd+Shift+I)
    debugger: debugger_mod.Debugger = .{},

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
            .svg_atlas = try svg_mod.SvgAtlas.init(allocator, window.scale_factor),
            .image_atlas = try image_mod.ImageAtlas.init(allocator, window.scale_factor),
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

        self.svg_atlas.deinit();
        self.image_atlas.deinit();

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
        self.debugger.beginFrame();

        self.frame_count += 1;
        self.widgets.beginFrame();
        self.focus.beginFrame();
        self.image_atlas.beginFrame();

        // Clear stale entity observations from last frame
        self.entities.beginFrame();

        // Update cached window dimensions
        self.width = @floatCast(self.window.size.width);
        self.height = @floatCast(self.window.size.height);
        self.scale_factor = @floatCast(self.window.scale_factor);

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
        // Focus the specific widget if it exists (check both TextInput and TextArea)
        if (self.widgets.text_inputs.get(id)) |input| {
            input.focus();
        } else if (self.widgets.text_areas.get(id)) |ta| {
            ta.focus();
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

    /// Set the accent color uniform for custom shaders
    /// The alpha channel can be used as a mode selector
    pub fn setAccentColor(self: *Gooey, r: f32, g: f32, b: f32, a: f32) void {
        if (self.window.renderer.getPostProcess()) |pp| {
            pp.uniforms.accent_color = .{ r, g, b, a };
        }
    }
};

fn measureTextCallback(
    text_content: []const u8,
    _: u16, // font_id
    _: u16, // font_size - ignored, rendering uses base font size
    _: ?f32, // max_width
    user_data: ?*anyopaque,
) TextMeasurement {
    if (user_data) |ptr| {
        const text_system: *TextSystem = @ptrCast(@alignCast(ptr));
        const width = text_system.measureText(text_content) catch 0;
        const metrics = text_system.getMetrics() orelse return .{ .width = 0, .height = 20 };
        return .{ .width = width, .height = metrics.line_height };
    }
    return .{
        .width = @as(f32, @floatFromInt(text_content.len)) * 10,
        .height = 20,
    };
}
