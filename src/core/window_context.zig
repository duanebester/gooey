//! WindowContext - The context passed to elements during render
//!
//! This combines:
//! - Layout engine access
//! - Scene/painting access
//! - Event handler registration
//! - Focus management
//! - Entity access (via App)
//!
//! Modeled after GPUI's Window/ViewContext.

const std = @import("std");
const types = @import("element_types.zig");
const style_mod = @import("style.zig");
const entity_mod = @import("entity.zig");
const entity_map_mod = @import("entity_map.zig");
const context_mod = @import("context.zig");
const scene_mod = @import("scene.zig");
const input_mod = @import("input.zig");

pub const Bounds = types.Bounds;
pub const Size = types.Size;
pub const Point = types.Point;
pub const Pixels = types.Pixels;
pub const ElementId = types.ElementId;
pub const GlobalElementId = types.GlobalElementId;
pub const LayoutNodeId = types.LayoutNodeId;
pub const Style = style_mod.Style;
pub const Hsla = style_mod.Hsla;
pub const Scene = scene_mod.Scene;
pub const Quad = scene_mod.Quad;
pub const Shadow = scene_mod.Shadow;
pub const EntityId = entity_mod.EntityId;
pub const EntityMap = entity_map_mod.EntityMap;
pub const InputEvent = input_mod.InputEvent;

// =============================================================================
// Hitbox for event handling
// =============================================================================

pub const HitboxId = struct {
    id: u64,

    var next_id: u64 = 1;

    pub fn generate() HitboxId {
        const id = next_id;
        next_id += 1;
        return .{ .id = id };
    }
};

pub const Hitbox = struct {
    id: HitboxId,
    bounds: Bounds,
    /// Opaque user data
    data: ?*anyopaque = null,
};

// =============================================================================
// Mouse Event Handlers
// =============================================================================

pub const MouseDownHandler = *const fn (event: *const InputEvent, bounds: Bounds, ctx: ?*anyopaque) void;
pub const MouseUpHandler = *const fn (event: *const InputEvent, bounds: Bounds, ctx: ?*anyopaque) void;
pub const MouseMoveHandler = *const fn (event: *const InputEvent, bounds: Bounds, ctx: ?*anyopaque) void;
pub const ClickHandler = *const fn (event: *const InputEvent, bounds: Bounds, ctx: ?*anyopaque) void;

pub const MouseHandlers = struct {
    on_mouse_down: ?MouseDownHandler = null,
    on_mouse_up: ?MouseUpHandler = null,
    on_mouse_move: ?MouseMoveHandler = null,
    on_click: ?ClickHandler = null,
    ctx: ?*anyopaque = null,
};

// =============================================================================
// Layout Node (for layout tree)
// =============================================================================

pub const LayoutNode = struct {
    style: Style,
    children: std.ArrayList(LayoutNodeId),
    computed_bounds: Bounds = .{},

    pub fn init(allocator: std.mem.Allocator, style: Style) LayoutNode {
        return .{
            .style = style,
            .children = std.ArrayList(LayoutNodeId).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutNode) void {
        self.children.deinit();
    }
};

// =============================================================================
// WindowContext
// =============================================================================

/// WindowContext provides the rendering context for elements.
///
/// It manages:
/// - Layout tree construction
/// - Scene painting
/// - Hitbox registration
/// - Focus state
/// - Entity access
pub const WindowContext = struct {
    allocator: std.mem.Allocator,

    // Layout
    layout_nodes: std.ArrayList(LayoutNode),
    layout_stack: std.ArrayList(LayoutNodeId),

    // Painting
    scene: *Scene,

    // Hitboxes for event handling
    hitboxes: std.ArrayList(Hitbox),
    mouse_handlers: std.AutoHashMap(u64, MouseHandlers),

    // Element ID tracking
    element_id_stack: GlobalElementId,

    // Focus
    focused_element: ?ElementId = null,

    // Window info
    window_size: Size,
    scale_factor: f32,

    // Entity access (type-erased to avoid circular deps)
    app_ptr: ?*anyopaque = null,
    entities: ?*EntityMap = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, scene: *Scene, window_size: Size, scale_factor: f32) Self {
        return .{
            .allocator = allocator,
            .layout_nodes = std.ArrayList(LayoutNode).init(allocator),
            .layout_stack = std.ArrayList(LayoutNodeId).init(allocator),
            .scene = scene,
            .hitboxes = std.ArrayList(Hitbox).init(allocator),
            .mouse_handlers = std.AutoHashMap(u64, MouseHandlers).init(allocator),
            .element_id_stack = GlobalElementId.init(allocator),
            .window_size = window_size,
            .scale_factor = scale_factor,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.layout_nodes.items) |*node| {
            node.deinit();
        }
        self.layout_nodes.deinit();
        self.layout_stack.deinit();
        self.hitboxes.deinit();
        self.mouse_handlers.deinit();
        self.element_id_stack.deinit();
    }

    pub fn reset(self: *Self) void {
        for (self.layout_nodes.items) |*node| {
            node.deinit();
        }
        self.layout_nodes.clearRetainingCapacity();
        self.layout_stack.clearRetainingCapacity();
        self.hitboxes.clearRetainingCapacity();
        self.mouse_handlers.clearRetainingCapacity();
        self.element_id_stack.path.clearRetainingCapacity();
    }

    // =========================================================================
    // Layout API
    // =========================================================================

    /// Request a layout node with the given style
    pub fn request_layout(self: *Self, style: Style, children: []const LayoutNodeId) LayoutNodeId {
        var node = LayoutNode.init(self.allocator, style);
        node.children.appendSlice(children) catch {};

        const id = LayoutNodeId{ .index = @intCast(self.layout_nodes.items.len) };
        self.layout_nodes.append(node) catch return LayoutNodeId.invalid;

        // If there's a parent on the stack, add this as a child
        if (self.layout_stack.items.len > 0) {
            const parent_id = self.layout_stack.items[self.layout_stack.items.len - 1];
            if (parent_id.index < self.layout_nodes.items.len) {
                self.layout_nodes.items[parent_id.index].children.append(id) catch {};
            }
        }

        return id;
    }

    /// Push a layout context (for nested layouts)
    pub fn push_layout(self: *Self, id: LayoutNodeId) void {
        self.layout_stack.append(id) catch {};
    }

    /// Pop the current layout context
    pub fn pop_layout(self: *Self) void {
        _ = self.layout_stack.popOrNull();
    }

    /// Get computed bounds for a layout node
    pub fn layout_bounds(self: *Self, id: LayoutNodeId) Bounds {
        if (id.index < self.layout_nodes.items.len) {
            return self.layout_nodes.items[id.index].computed_bounds;
        }
        return Bounds.zero;
    }

    /// Compute layout for the tree (simplified flexbox)
    pub fn compute_layout(self: *Self, root: LayoutNodeId, available: Size) void {
        if (root.index >= self.layout_nodes.items.len) return;
        self.compute_node_layout(root, Bounds.init(0, 0, available.width, available.height));
    }

    fn compute_node_layout(self: *Self, id: LayoutNodeId, available: Bounds) void {
        if (id.index >= self.layout_nodes.items.len) return;

        var node = &self.layout_nodes.items[id.index];
        node.computed_bounds = available;

        const style = node.style;
        const content_bounds = available.inset(style.padding);

        // Simple layout: stack children based on flex direction
        const is_column = style.flex_direction == .column or style.flex_direction == .column_reverse;
        var offset: Pixels = 0;

        for (node.children.items) |child_id| {
            if (child_id.index >= self.layout_nodes.items.len) continue;

            const child_style = self.layout_nodes.items[child_id.index].style;

            // Calculate child size
            var child_width = content_bounds.size.width;
            var child_height = content_bounds.size.height;

            switch (child_style.width) {
                .px => |px| child_width = px,
                .percent => |pct| child_width = content_bounds.size.width * pct,
                .auto => {},
            }
            switch (child_style.height) {
                .px => |px| child_height = px,
                .percent => |pct| child_height = content_bounds.size.height * pct,
                .auto => {},
            }

            const child_bounds = if (is_column)
                Bounds.init(content_bounds.origin.x, content_bounds.origin.y + offset, child_width, child_height)
            else
                Bounds.init(content_bounds.origin.x + offset, content_bounds.origin.y, child_width, child_height);

            self.compute_node_layout(child_id, child_bounds);

            if (is_column) {
                offset += child_height + style.gap;
            } else {
                offset += child_width + style.gap;
            }
        }
    }

    // =========================================================================
    // Painting API
    // =========================================================================

    /// Paint a quad (rectangle)
    pub fn paint_quad(self: *Self, bounds: Bounds, style: Style) void {
        const quad = Quad{
            .bounds_origin_x = bounds.origin.x,
            .bounds_origin_y = bounds.origin.y,
            .bounds_size_width = bounds.size.width,
            .bounds_size_height = bounds.size.height,
            .background = style.background,
            .border_color = style.border_color,
            .corner_radii = .{
                .top_left = style.corner_radius.top_left,
                .top_right = style.corner_radius.top_right,
                .bottom_right = style.corner_radius.bottom_right,
                .bottom_left = style.corner_radius.bottom_left,
            },
            .border_widths = .{
                .top = style.border_width.top,
                .right = style.border_width.right,
                .bottom = style.border_width.bottom,
                .left = style.border_width.left,
            },
        };
        self.scene.insertQuad(quad) catch {};
    }

    /// Paint a shadow
    pub fn paint_shadow(self: *Self, bounds: Bounds, style: Style) void {
        if (style.shadow_blur > 0) {
            const shadow = Shadow{
                .content_origin_x = bounds.origin.x,
                .content_origin_y = bounds.origin.y,
                .content_size_width = bounds.size.width,
                .content_size_height = bounds.size.height,
                .blur_radius = style.shadow_blur,
                .color = style.shadow_color,
                .offset_x = style.shadow_offset.x,
                .offset_y = style.shadow_offset.y,
                .corner_radii = .{
                    .top_left = style.corner_radius.top_left,
                    .top_right = style.corner_radius.top_right,
                    .bottom_right = style.corner_radius.bottom_right,
                    .bottom_left = style.corner_radius.bottom_left,
                },
            };
            self.scene.insertShadow(shadow) catch {};
        }
    }

    // =========================================================================
    // Hitbox / Event API
    // =========================================================================

    /// Register a hitbox for mouse event handling
    pub fn insert_hitbox(self: *Self, bounds: Bounds, handlers: MouseHandlers) HitboxId {
        const id = HitboxId.generate();
        self.hitboxes.append(.{ .id = id, .bounds = bounds }) catch {};
        self.mouse_handlers.put(id.id, handlers) catch {};
        return id;
    }

    /// Hit test a point, returns the topmost hitbox
    pub fn hit_test(self: *Self, point: Point) ?HitboxId {
        // Iterate in reverse (last added = topmost)
        var i = self.hitboxes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.hitboxes.items[i].bounds.contains(point)) {
                return self.hitboxes.items[i].id;
            }
        }
        return null;
    }

    // =========================================================================
    // Focus API
    // =========================================================================

    pub fn focus(self: *Self, id: ElementId) void {
        self.focused_element = id;
    }

    pub fn blur(self: *Self) void {
        self.focused_element = null;
    }

    pub fn is_focused(self: *Self, id: ElementId) bool {
        if (self.focused_element) |focused| {
            return focused.eql(id);
        }
        return false;
    }

    // =========================================================================
    // Element ID Stack
    // =========================================================================

    pub fn with_element_id(self: *Self, id: ElementId, comptime f: fn (*Self) void) void {
        self.element_id_stack.push(id) catch {};
        defer _ = self.element_id_stack.pop();
        f(self);
    }

    // =========================================================================
    // Window Info
    // =========================================================================

    pub fn getWindowSize(self: *Self) Size {
        return self.window_size;
    }

    pub fn getScaleFactor(self: *Self) f32 {
        return self.scale_factor;
    }
};
