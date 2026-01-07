//! UI Builder
//!
//! The Builder struct is the core of the declarative UI system.
//! It provides methods for creating layouts, rendering primitives,
//! and managing component context.

const std = @import("std");

// Core imports
const dispatch_mod = @import("../context/dispatch.zig");
const DispatchTree = dispatch_mod.DispatchTree;
const DispatchNodeId = dispatch_mod.DispatchNodeId;
const focus_mod = @import("../context/focus.zig");
const FocusId = focus_mod.FocusId;
const FocusHandle = focus_mod.FocusHandle;
const action_mod = @import("../input/actions.zig");
const actionTypeId = action_mod.actionTypeId;
const handler_mod = @import("../context/handler.zig");
const entity_mod = @import("../context/entity.zig");
const gooey_mod = @import("../context/gooey.zig");
pub const HandlerRef = handler_mod.HandlerRef;
pub const EntityId = entity_mod.EntityId;
pub const Gooey = gooey_mod.Gooey;

// Accessibility
const a11y = @import("../accessibility/accessibility.zig");

// Layout imports
const layout_types = @import("../layout/types.zig");
const BorderConfig = layout_types.BorderConfig;
const FloatingConfig = layout_types.FloatingConfig;
const layout_mod = @import("../layout/layout.zig");
const LayoutEngine = layout_mod.LayoutEngine;
const LayoutId = layout_mod.LayoutId;
const SourceLoc = layout_mod.SourceLoc;
const Sizing = layout_mod.Sizing;
const SizingAxis = layout_mod.SizingAxis;
const Padding = layout_mod.Padding;
pub const CornerRadius = layout_mod.CornerRadius;
const ChildAlignment = layout_mod.ChildAlignment;
const LayoutDirection = layout_mod.LayoutDirection;
const LayoutConfig = layout_mod.LayoutConfig;
const TextConfig = layout_mod.TextConfig;
const RenderCommand = layout_mod.RenderCommand;
const BoundingBox = layout_mod.BoundingBox;
const MainAxisDistribution = layout_mod.MainAxisDistribution;

// Scene imports
const scene_mod = @import("../scene/mod.zig");
const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;

// Element imports
const styles = @import("styles.zig");
const primitives = @import("primitives.zig");
const theme_mod = @import("theme.zig");
pub const Theme = theme_mod.Theme;

pub const Color = styles.Color;
pub const ShadowConfig = styles.ShadowConfig;
pub const AttachPoint = styles.AttachPoint;
pub const ObjectFit = styles.ObjectFit;
pub const Floating = styles.Floating;
pub const Box = styles.Box;
pub const TextStyle = styles.TextStyle;
pub const InputStyle = styles.InputStyle;
pub const TextAreaStyle = styles.TextAreaStyle;
pub const StackStyle = styles.StackStyle;
pub const CenterStyle = styles.CenterStyle;
pub const ScrollStyle = styles.ScrollStyle;
pub const UniformListStyle = styles.UniformListStyle;
pub const VirtualListStyle = styles.VirtualListStyle;
pub const DataTableStyle = styles.DataTableStyle;
pub const ButtonStyle = styles.ButtonStyle;

pub const PrimitiveType = primitives.PrimitiveType;
pub const Text = primitives.Text;
pub const Input = primitives.Input;
pub const TextAreaPrimitive = primitives.TextAreaPrimitive;
pub const Spacer = primitives.Spacer;
pub const Button = primitives.Button;
pub const ButtonHandler = primitives.ButtonHandler;
pub const Empty = primitives.Empty;
pub const SvgPrimitive = primitives.SvgPrimitive;
pub const ImagePrimitive = primitives.ImagePrimitive;
pub const KeyContextPrimitive = primitives.KeyContextPrimitive;
pub const ActionHandlerPrimitive = primitives.ActionHandlerPrimitive;
pub const ActionHandlerRefPrimitive = primitives.ActionHandlerRefPrimitive;

// Primitive functions
pub const text = primitives.text;
pub const textFmt = primitives.textFmt;
pub const input = primitives.input;
pub const textArea = primitives.textArea;
pub const spacer = primitives.spacer;
pub const spacerMin = primitives.spacerMin;
pub const svg = primitives.svg;
pub const svgIcon = primitives.svgIcon;
pub const empty = primitives.empty;
pub const keyContext = primitives.keyContext;
pub const onAction = primitives.onAction;
pub const onActionHandler = primitives.onActionHandler;
pub const when = primitives.when;

// Accessibility config
pub const AccessibleConfig = struct {
    role: a11y.Role,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    value: ?[]const u8 = null,
    state: a11y.State = .{},
    live: a11y.Live = .off,
    heading_level: a11y.types.HeadingLevel = .none,
    value_min: ?f32 = null,
    value_max: ?f32 = null,
    value_now: ?f32 = null,
    pos_in_set: ?u16 = null,
    set_size: ?u16 = null,
    /// Optional layout_id for bounds correlation (none = no correlation)
    layout_id: LayoutId = LayoutId.none,

    // =========================================================================
    // Relationships (Phase 3.2) - string IDs that will be resolved to indices
    // =========================================================================

    /// ID of element that labels this one (for aria-labelledby)
    labelled_by_id: ?[]const u8 = null,

    /// ID of element that describes this one (for aria-describedby)
    described_by_id: ?[]const u8 = null,

    /// ID of element this one controls (for aria-controls)
    controls_id: ?[]const u8 = null,
};

// Re-export accessibility types for convenience
pub const A11yRole = a11y.Role;
pub const A11yState = a11y.State;
pub const A11yLive = a11y.Live;

/// Get a unique type ID for context type checking
fn contextTypeId(comptime T: type) usize {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

/// The UI builder context passed to component render() methods
pub const Builder = struct {
    // =========================================================================
    // Limits (per CLAUDE.md: "put a limit on everything")
    // =========================================================================
    pub const MAX_PENDING_INPUTS = 256;
    pub const MAX_PENDING_TEXT_AREAS = 64;
    pub const MAX_PENDING_SCROLLS = 64;

    allocator: std.mem.Allocator,
    layout: *LayoutEngine,
    scene: *Scene,
    gooey: ?*Gooey = null,
    id_counter: u32 = 0,

    /// Dispatch tree for event routing (built alongside layout)
    dispatch: *DispatchTree,

    // Context storage for component access
    /// Type-erased context pointer (set by runWithState)
    context_ptr: ?*anyopaque = null,
    /// Type ID for runtime type checking
    context_type_id: usize = 0,
    /// Cx pointer for new-style components (set by runCx)
    cx_ptr: ?*anyopaque = null,

    /// Theme pointer for context-aware theming
    theme_ptr: ?*const Theme = null,

    /// Pending input IDs to be rendered (collected during layout, rendered after)
    pending_inputs: std.ArrayList(PendingInput),
    pending_text_areas: std.ArrayList(PendingTextArea),
    pending_scrolls: std.ArrayListUnmanaged(PendingScroll),

    /// Hashmap for O(1) scroll lookup by layout_id (avoids O(n) scan per scissor_end)
    pending_scrolls_by_layout_id: std.AutoHashMapUnmanaged(u32, usize),

    /// Currently dragged scroll container ID (avoids O(n) scan per mouse drag event)
    active_scroll_drag_id: ?[]const u8 = null,

    const PendingInput = struct {
        id: []const u8,
        layout_id: LayoutId,
        style: InputStyle,
        inner_width: f32,
        inner_height: f32,
    };

    const PendingTextArea = struct {
        id: []const u8,
        layout_id: LayoutId,
        style: TextAreaStyle,
        inner_width: f32,
        inner_height: f32,
    };

    pub const PendingScroll = struct {
        id: []const u8,
        layout_id: LayoutId,
        style: ScrollStyle,
        content_layout_id: LayoutId,
    };

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        layout_engine: *LayoutEngine,
        scene_ptr: *Scene,
        dispatch_tree: *DispatchTree,
    ) Self {
        return .{
            .allocator = allocator,
            .layout = layout_engine,
            .scene = scene_ptr,
            .dispatch = dispatch_tree,
            .pending_inputs = .{},
            .pending_scrolls = .{},
            .pending_text_areas = .{},
            .pending_scrolls_by_layout_id = .{},
            .active_scroll_drag_id = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_inputs.deinit(self.allocator);
        self.pending_text_areas.deinit(self.allocator);
        self.pending_scrolls.deinit(self.allocator);
        self.pending_scrolls_by_layout_id.deinit(self.allocator);
    }

    // =========================================================================
    // Context Access (for components to retrieve typed context)
    // =========================================================================

    /// Set the context for this builder.
    /// Called by runWithState before rendering.
    pub fn setContext(self: *Self, comptime ContextType: type, ctx: *ContextType) void {
        self.context_ptr = @ptrCast(ctx);
        self.context_type_id = contextTypeId(ContextType);
    }

    /// Clear the context (called after frame if needed)
    pub fn clearContext(self: *Self) void {
        self.context_ptr = null;
        self.context_type_id = 0;
    }

    // =========================================================================
    // Theme Access
    // =========================================================================

    /// Set the theme for this builder and all child components.
    /// Called at the start of render to establish theme context.
    pub fn setTheme(self: *Self, t: *const Theme) void {
        self.theme_ptr = t;
    }

    /// Get the current theme, falling back to light theme if none set.
    /// Components use this to resolve null color fields.
    pub fn theme(self: *Self) *const Theme {
        return self.theme_ptr orelse &Theme.light;
    }

    /// Get the typed context from within a component's render method.
    ///
    /// Returns null if no context is set or if the type doesn't match.
    ///
    /// ## Example
    ///
    /// ```zig
    /// const CounterRow = struct {
    ///     pub fn render(_: @This(), b: *ui.Builder) void {
    ///         const cx = b.getContext(gooey.Context(AppState)) orelse return;
    ///         const s = cx.state();
    ///
    ///         b.hstack(.{ .gap = 12 }, .{
    ///             ui.buttonHandler("-", cx.handler(AppState.decrement)),
    ///             ui.textFmt("Count: {}", .{s.count}, .{}),
    ///             ui.buttonHandler("+", cx.handler(AppState.increment)),
    ///         });
    ///     }
    /// };
    /// ```
    pub fn getContext(self: *Self, comptime ContextType: type) ?*ContextType {
        if (self.context_ptr) |ptr| {
            if (self.context_type_id == contextTypeId(ContextType)) {
                return @ptrCast(@alignCast(ptr));
            }
        }
        return null;
    }

    /// Get an EntityContext for an entity from within a component's render method.
    ///
    /// This is a convenience that combines `b.gooey` access with entity context creation,
    /// eliminating the need for global Gooey references in entity-based components.
    ///
    /// ## Example
    ///
    /// ```zig
    /// const CounterButtons = struct {
    ///     counter: gooey.Entity(Counter),
    ///
    ///     pub fn render(self: @This(), b: *ui.Builder) void {
    ///         var cx = b.entityContext(Counter, self.counter) orelse return;
    ///
    ///         b.hstack(.{ .gap = 8 }, .{
    ///             ui.buttonHandler("-", cx.handler(Counter.decrement)),
    ///             ui.buttonHandler("+", cx.handler(Counter.increment)),
    ///         });
    ///     }
    /// };
    /// ```
    pub fn entityContext(
        self: *Self,
        comptime T: type,
        entity: entity_mod.Entity(T),
    ) ?entity_mod.EntityContext(T) {
        const g = self.gooey orelse return null;
        return entity.context(g);
    }

    /// Get the Gooey instance from within a component.
    ///
    /// Useful for reading entity data or other Gooey operations.
    /// Returns null if Builder wasn't initialized with a Gooey reference.
    pub fn getGooey(self: *Self) ?*Gooey {
        return self.gooey;
    }

    /// Read an entity's data directly from Builder.
    /// Convenience wrapper around gooey.readEntity().
    pub fn readEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*const T {
        const g = self.gooey orelse return null;
        return g.readEntity(T, entity);
    }

    /// Write to an entity's data directly from Builder.
    /// Convenience wrapper around gooey.writeEntity().
    pub fn writeEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*T {
        const g = self.gooey orelse return null;
        return g.writeEntity(T, entity);
    }

    // =========================================================================
    // Accessibility (Phase 1)
    // =========================================================================

    /// Begin an accessible element. Call before the visual element.
    /// Returns true if a11y is active and element was pushed.
    /// Must be paired with accessibleEnd() when returns true.
    ///
    /// Focus state is automatically injected from the FocusManager based on
    /// the layout_id - components don't need to manually track focus.
    ///
    /// ## Example
    /// ```zig
    /// if (b.accessible(.{ .role = .button, .name = "Submit" })) {
    ///     defer b.accessibleEnd();
    /// }
    /// // ... render visual element ...
    /// ```
    pub fn accessible(self: *Self, config: AccessibleConfig) bool {
        const g = self.gooey orelse return false;
        if (!g.a11y_enabled) return false;

        // Phase 3: Auto-inject focus state from FocusManager
        // This centralizes focus tracking - components don't need to know about it
        var state = config.state;
        if (config.layout_id.id != 0) {
            // Check if this element is focused via FocusManager
            const focus_id = FocusId.fromLayoutId(config.layout_id);
            if (g.focus.isFocused(focus_id)) {
                state.focused = true;
            }
        }

        // Resolve string-based relationship IDs to element indices
        // Note: Target elements must be rendered earlier in the same frame
        const labelled_by: ?u16 = if (config.labelled_by_id) |id|
            g.a11y_tree.findElementByStringId(id)
        else
            null;

        const described_by: ?u16 = if (config.described_by_id) |id|
            g.a11y_tree.findElementByStringId(id)
        else
            null;

        const controls: ?u16 = if (config.controls_id) |id|
            g.a11y_tree.findElementByStringId(id)
        else
            null;

        _ = g.a11y_tree.pushElement(.{
            .layout_id = config.layout_id,
            .role = config.role,
            .name = config.name,
            .description = config.description,
            .value = config.value,
            .state = state,
            .live = config.live,
            .heading_level = config.heading_level,
            .value_min = config.value_min,
            .value_max = config.value_max,
            .value_now = config.value_now,
            .pos_in_set = config.pos_in_set,
            .set_size = config.set_size,
            // Relationships
            .labelled_by = labelled_by,
            .described_by = described_by,
            .controls = controls,
        });

        return true;
    }

    /// End current accessible element.
    /// Must be called after accessible() returns true.
    pub fn accessibleEnd(self: *Self) void {
        const g = self.gooey orelse return;
        if (g.a11y_enabled) {
            g.a11y_tree.popElement();
        }
    }

    /// Announce a message to screen readers.
    /// Use .polite for non-urgent updates, .assertive for critical alerts.
    ///
    /// ## Example
    /// ```zig
    /// b.announce("Item deleted", .polite);
    /// b.announce("Error: connection lost", .assertive);
    /// ```
    pub fn announce(self: *Self, message: []const u8, priority: a11y.Live) void {
        const g = self.gooey orelse return;
        if (g.a11y_enabled) {
            g.a11y_tree.announce(message, priority);
        }
    }

    /// Check if accessibility is currently enabled
    pub fn isA11yEnabled(self: *Self) bool {
        const g = self.gooey orelse return false;
        return g.a11y_enabled;
    }

    // =========================================================================
    // Container Methods
    // =========================================================================

    /// Generic box container with children
    pub fn box(self: *Self, props: Box, children: anytype) void {
        self.boxWithIdTracked(null, props, children, SourceLoc.none);
    }

    /// Box with source location tracking (Phase 5)
    /// Call as: b.boxTracked(props, children, @src())
    pub fn boxTracked(self: *Self, props: Box, children: anytype, src: std.builtin.SourceLocation) void {
        self.boxWithIdTracked(null, props, children, SourceLoc.from(src));
    }

    /// Box with explicit ID
    pub fn boxWithId(self: *Self, id: ?[]const u8, props: Box, children: anytype) void {
        self.boxWithIdTracked(id, props, children, SourceLoc.none);
    }

    /// Box with explicit ID and source location tracking (Phase 5)
    /// Call as: b.boxWithIdTracked("my-id", props, children, @src())
    pub fn boxWithIdTracked(self: *Self, id: ?[]const u8, props: Box, children: anytype, source_loc: SourceLoc) void {
        const layout_id = if (id) |i| LayoutId.fromString(i) else self.generateId();

        // Push dispatch node at element open
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Resolve hover styles - check if this element is currently hovered
        const is_hovered = if (self.gooey) |g|
            g.isHovered(layout_id.id)
        else
            false;

        const resolved_background = if (is_hovered and props.hover_background != null)
            props.hover_background.?
        else
            props.background;

        const resolved_border_color = if (is_hovered and props.hover_border_color != null)
            props.hover_border_color.?
        else
            props.border_color;

        var sizing = Sizing.fitContent();

        // Width sizing - grow takes precedence when combined with min/max
        const grow_w = props.grow or props.grow_width;
        if (grow_w) {
            const min_w = props.min_width orelse 0;
            const max_w = props.max_width orelse std.math.floatMax(f32);
            sizing.width = SizingAxis.growMinMax(min_w, max_w);
        } else if (props.width) |w| {
            if (props.min_width != null or props.max_width != null) {
                const min_w = props.min_width orelse 0;
                const max_w = props.max_width orelse w;
                sizing.width = SizingAxis.fitMinMax(min_w, @min(w, max_w));
            } else {
                sizing.width = SizingAxis.fixed(w);
            }
        } else if (props.min_width != null or props.max_width != null) {
            const min_w = props.min_width orelse 0;
            const max_w = props.max_width orelse std.math.floatMax(f32);
            sizing.width = SizingAxis.fitMinMax(min_w, max_w);
        } else if (props.width_percent) |p| {
            sizing.width = SizingAxis.percent(p);
        } else if (props.fill_width) {
            sizing.width = SizingAxis.percent(1.0);
        }

        // Height sizing - grow takes precedence when combined with min/max
        const grow_h = props.grow or props.grow_height;
        if (grow_h) {
            const min_h = props.min_height orelse 0;
            const max_h = props.max_height orelse std.math.floatMax(f32);
            sizing.height = SizingAxis.growMinMax(min_h, max_h);
        } else if (props.height) |h| {
            if (props.min_height != null or props.max_height != null) {
                const min_h = props.min_height orelse 0;
                const max_h = props.max_height orelse h;
                sizing.height = SizingAxis.fitMinMax(min_h, @min(h, max_h));
            } else {
                sizing.height = SizingAxis.fixed(h);
            }
        } else if (props.min_height != null or props.max_height != null) {
            const min_h = props.min_height orelse 0;
            const max_h = props.max_height orelse std.math.floatMax(f32);
            sizing.height = SizingAxis.fitMinMax(min_h, max_h);
        } else if (props.height_percent) |p| {
            sizing.height = SizingAxis.percent(p);
        } else if (props.fill_height) {
            sizing.height = SizingAxis.percent(1.0);
        }

        const direction: LayoutDirection = switch (props.direction) {
            .row => .left_to_right,
            .column => .top_to_bottom,
        };

        // Alignment mapping depends on direction:
        // - row: main=X, cross=Y
        // - column: main=Y, cross=X
        const child_alignment = if (props.direction == .row) ChildAlignment{
            .x = switch (props.alignment.main) {
                .start => .left,
                .center => .center,
                .end => .right,
                .space_between, .space_around, .space_evenly => .left,
            },
            .y = switch (props.alignment.cross) {
                .start => .top,
                .center => .center,
                .end => .bottom,
                .stretch => .top,
            },
        } else ChildAlignment{
            .x = switch (props.alignment.cross) {
                .start => .left,
                .center => .center,
                .end => .right,
                .stretch => .left,
            },
            .y = switch (props.alignment.main) {
                .start => .top,
                .center => .center,
                .end => .bottom,
                .space_between, .space_around, .space_evenly => .top,
            },
        };

        // Map main-axis distribution (for space-between, space-around, etc.)
        const main_distribution: MainAxisDistribution = switch (props.alignment.main) {
            .start => .start,
            .center => .center,
            .end => .end,
            .space_between => .space_between,
            .space_around => .space_around,
            .space_evenly => .space_evenly,
        };

        // Build border config if we have a border
        const border_config: ?BorderConfig = if (props.border_width > 0)
            BorderConfig.all(resolved_border_color, props.border_width)
        else
            null;

        // Convert floating config if present
        const floating_config: ?FloatingConfig = if (props.floating) |f|
            f.toFloatingConfig()
        else
            null;

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = sizing,
                .padding = props.toPadding(),
                .child_gap = @intFromFloat(props.gap),
                .child_alignment = child_alignment,
                .layout_direction = direction,
                .main_axis_distribution = main_distribution,
            },
            .background_color = resolved_background,
            .corner_radius = CornerRadius.all(props.corner_radius),
            .border = border_config,
            .shadow = props.shadow,
            .floating = floating_config,
            .opacity = props.opacity,
            .source_location = source_loc,
        }) catch return;

        // Mark floating elements for hit testing optimization
        if (floating_config != null) {
            self.dispatch.markFloating();
        }

        self.processChildren(children);

        self.layout.closeElement();

        // Register click handlers before popping dispatch node
        if (props.on_click) |callback| {
            self.dispatch.onClick(callback);
        }
        if (props.on_click_handler) |handler| {
            self.dispatch.onClickHandler(handler);
        }

        // Register click-outside handlers (for dropdowns, modals, etc.)
        if (props.on_click_outside) |callback| {
            self.dispatch.onClickOutside(callback);
        }
        if (props.on_click_outside_handler) |handler| {
            self.dispatch.onClickOutsideHandler(handler);
        }

        // Pop dispatch node at element close
        self.dispatch.popNode();
    }

    /// Vertical stack (column)
    pub fn vstack(self: *Self, style: StackStyle, children: anytype) void {
        self.vstackImpl(style, children, SourceLoc.none);
    }

    /// Vertical stack with source location tracking (Phase 5)
    /// Call as: b.vstackTracked(style, children, @src())
    pub fn vstackTracked(self: *Self, style: StackStyle, children: anytype, src: std.builtin.SourceLocation) void {
        self.vstackImpl(style, children, SourceLoc.from(src));
    }

    fn vstackImpl(self: *Self, style: StackStyle, children: anytype, loc: SourceLoc) void {
        self.boxWithIdTracked(null, .{
            .direction = .column,
            .gap = style.gap,
            .padding = .{ .all = style.padding },
            .alignment = .{
                .cross = switch (style.alignment) {
                    .start => .start,
                    .center => .center,
                    .end => .end,
                    .stretch => .stretch,
                },
            },
        }, children, loc);
    }

    /// Horizontal stack (row)
    pub fn hstack(self: *Self, style: StackStyle, children: anytype) void {
        self.hstackImpl(style, children, SourceLoc.none);
    }

    /// Horizontal stack with source location tracking (Phase 5)
    /// Call as: b.hstackTracked(style, children, @src())
    pub fn hstackTracked(self: *Self, style: StackStyle, children: anytype, src: std.builtin.SourceLocation) void {
        self.hstackImpl(style, children, SourceLoc.from(src));
    }

    fn hstackImpl(self: *Self, style: StackStyle, children: anytype, loc: SourceLoc) void {
        self.boxWithIdTracked(null, .{
            .direction = .row,
            .gap = style.gap,
            .padding = .{ .all = style.padding },
            .alignment = .{
                .cross = switch (style.alignment) {
                    .start => .start,
                    .center => .center,
                    .end => .end,
                    .stretch => .stretch,
                },
            },
        }, children, loc);
    }

    /// Center children in available space
    pub fn center(self: *Self, style: CenterStyle, children: anytype) void {
        self.box(.{
            .grow = true,
            .padding = .{ .all = style.padding },
            .alignment = .{ .main = .center, .cross = .center },
        }, children);
    }

    // =========================================================================
    // Component Integration
    // =========================================================================

    /// Render any component (struct with `render` method)
    pub fn with(self: *Self, component: anytype) void {
        const T = @TypeOf(component);
        if (@typeInfo(T) == .@"struct" and @hasDecl(T, "render")) {
            component.render(self);
        } else {
            @compileError("with() requires a struct with a `render` method");
        }
    }

    // =========================================================================
    // Conditionals
    // =========================================================================

    /// Render children only if condition is true
    pub fn when(self: *Self, condition: bool, children: anytype) void {
        if (condition) {
            self.processChildren(children);
        }
    }

    /// Render with value if optional is non-null
    pub fn maybe(self: *Self, optional: anytype, comptime render_fn: anytype) void {
        if (optional) |value| {
            const result = render_fn(value);
            self.processChild(result);
        }
    }

    // =========================================================================
    // Iteration
    // =========================================================================

    /// Render for each item in a slice
    pub fn each(self: *Self, items: anytype, comptime render_fn: anytype) void {
        for (items, 0..) |item, index| {
            const result = render_fn(item, index);
            self.processChild(result);
        }
    }

    /// Create a scrollable container
    /// Usage: b.scroll("my_scroll", .{ .height = 200 }, .{ ...children... });
    pub fn scroll(self: *Self, id: []const u8, style: ScrollStyle, children: anytype) void {
        const layout_id = LayoutId.fromString(id);

        // Get scroll offset from retained widget
        var scroll_offset_x: f32 = 0;
        var scroll_offset_y: f32 = 0;
        if (self.gooey) |g| {
            if (g.widgets.scrollContainer(id)) |sc| {
                scroll_offset_x = sc.state.offset_x;
                scroll_offset_y = sc.state.offset_y;
            }
        }

        // Convert padding
        const padding: Padding = switch (style.padding) {
            .all => |v| Padding.all(@intFromFloat(v)),
            .symmetric => |s| Padding.symmetric(@intFromFloat(s.x), @intFromFloat(s.y)),
            .each => |e| .{
                .top = @intFromFloat(e.top),
                .right = @intFromFloat(e.right),
                .bottom = @intFromFloat(e.bottom),
                .left = @intFromFloat(e.left),
            },
        };

        // Compute viewport sizing (same pattern as boxWithIdTracked)
        var sizing = Sizing.fitContent();

        // Width sizing
        const grow_w = style.grow or style.grow_width;
        if (grow_w) {
            sizing.width = SizingAxis.grow();
        } else if (style.width) |w| {
            sizing.width = SizingAxis.fixed(w);
        } else if (style.fill_width) {
            sizing.width = SizingAxis.percent(1.0);
        } else {
            // Default fallback for scroll containers
            sizing.width = SizingAxis.fixed(300);
        }

        // Height sizing
        const grow_h = style.grow or style.grow_height;
        if (grow_h) {
            sizing.height = SizingAxis.grow();
        } else if (style.height) |h| {
            sizing.height = SizingAxis.fixed(h);
        } else if (style.fill_height) {
            sizing.height = SizingAxis.percent(1.0);
        } else {
            // Default fallback for scroll containers
            sizing.height = SizingAxis.fixed(200);
        }

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = sizing,
                .padding = padding,
            },
            .background_color = style.background,
            .corner_radius = if (style.corner_radius > 0) CornerRadius.all(style.corner_radius) else .{},
            .scroll = .{
                .vertical = style.vertical,
                .horizontal = style.horizontal,
                .scroll_offset = .{ .x = scroll_offset_x, .y = scroll_offset_y },
            },
        }) catch return;

        // Inner content container (can be taller than viewport)
        const content_id = self.generateId();
        // Content sizing: use fit() for scrollable directions (allows overflow),
        // grow() for non-scrollable directions (fills viewport)
        const content_width_sizing = if (style.content_width) |w|
            SizingAxis.fixed(w)
        else if (style.horizontal)
            SizingAxis.fit() // fit to children, allows horizontal overflow
        else
            SizingAxis.grow(); // fill viewport width

        const content_height_sizing = if (style.content_height) |h|
            SizingAxis.fixed(h)
        else if (style.vertical)
            SizingAxis.fit() // fit to children, allows vertical overflow
        else
            SizingAxis.grow(); // fill viewport height

        self.layout.openElement(.{
            .id = content_id,
            .layout = .{
                .sizing = .{
                    .width = content_width_sizing,
                    .height = content_height_sizing,
                },
                .layout_direction = .top_to_bottom,
                .child_gap = style.gap,
            },
        }) catch return;

        // Process children
        self.processChildren(children);

        // Close content container
        self.layout.closeElement();

        // Close viewport
        self.layout.closeElement();

        // Store for later processing
        const index = self.pending_scrolls.items.len;
        self.pending_scrolls.append(self.allocator, .{
            .id = id,
            .layout_id = layout_id,
            .style = style,
            .content_layout_id = content_id,
        }) catch return;

        // Add to hashmap for O(1) lookup by layout_id
        self.pending_scrolls_by_layout_id.put(self.allocator, layout_id.id, index) catch {};
    }

    /// Find a pending scroll by its layout ID (for rendering scrollbars inline with commands)
    /// O(1) lookup for pending scroll by layout_id (uses hashmap)
    pub fn findPendingScrollByLayoutId(self: *const Self, layout_id_value: u32) ?*const PendingScroll {
        if (self.pending_scrolls_by_layout_id.get(layout_id_value)) |index| {
            if (index < self.pending_scrolls.items.len) {
                return &self.pending_scrolls.items[index];
            }
        }
        return null;
    }

    /// Track which scroll container is being dragged (for O(1) drag event handling)
    pub fn setActiveScrollDrag(self: *Self, id: ?[]const u8) void {
        self.active_scroll_drag_id = id;
    }

    /// Get the currently dragged scroll container ID
    pub fn getActiveScrollDrag(self: *const Self) ?[]const u8 {
        return self.active_scroll_drag_id;
    }

    // =========================================================================
    // Uniform List (Virtualized)
    // =========================================================================

    const uniform_list = @import("../widgets/uniform_list.zig");
    const UniformListState = uniform_list.UniformListState;

    /// Computed layout parameters for uniform list (avoids recomputation).
    const UniformListLayout = struct {
        layout_id: LayoutId,
        sizing: Sizing,
        padding: Padding,
        content_height: f32,
        top_spacer_height: f32,
        bottom_spacer_height: f32,
        range: uniform_list.VisibleRange,
        gap: u16,
    };

    /// Compute sizing from UniformListStyle - extracted to reduce duplication.
    fn computeUniformListSizing(style: UniformListStyle) Sizing {
        var sizing = Sizing.fitContent();

        // Width sizing (default to grow if unspecified)
        const grow_w = style.grow or style.grow_width;
        if (grow_w) {
            sizing.width = SizingAxis.grow();
        } else if (style.width) |w| {
            sizing.width = SizingAxis.fixed(w);
        } else if (style.fill_width) {
            sizing.width = SizingAxis.percent(1.0);
        } else {
            sizing.width = SizingAxis.grow(); // Default: grow to fill
        }

        // Height sizing (default to fixed for virtualization)
        const grow_h = style.grow or style.grow_height;
        if (grow_h) {
            sizing.height = SizingAxis.grow();
        } else if (style.height) |h| {
            sizing.height = SizingAxis.fixed(h);
        } else if (style.fill_height) {
            sizing.height = SizingAxis.percent(1.0);
        } else {
            sizing.height = SizingAxis.fixed(uniform_list.DEFAULT_VIEWPORT_HEIGHT);
        }

        return sizing;
    }

    /// Convert style padding to layout Padding - extracted to reduce duplication.
    fn computeUniformListPadding(style: UniformListStyle) Padding {
        return switch (style.padding) {
            .all => |v| Padding.all(@intFromFloat(v)),
            .symmetric => |s| Padding.symmetric(@intFromFloat(s.x), @intFromFloat(s.y)),
            .each => |e| .{
                .top = @intFromFloat(e.top),
                .right = @intFromFloat(e.right),
                .bottom = @intFromFloat(e.bottom),
                .left = @intFromFloat(e.left),
            },
        };
    }

    /// Sync scroll state between UniformListState and retained ScrollContainer.
    /// Resolves PendingScrollRequest with accurate viewport dimensions to avoid jitter.
    fn syncUniformListScroll(self: *Self, id: []const u8, state: *UniformListState) void {
        const g = self.gooey orelse return;
        const sc = g.widgets.scrollContainer(id) orelse return;

        // Update viewport dimensions FIRST so calculations are accurate
        state.viewport_height_px = sc.state.viewport_height;

        if (state.pending_scroll) |request| {
            // Resolve the scroll request with current accurate viewport dimensions
            const target: f32 = switch (request) {
                .absolute => |offset| offset,
                .to_top => 0,
                .to_end => state.maxScrollOffset(),
                .to_item => |item| state.resolveScrollToItem(item.index, item.strategy),
            };

            // Apply resolved scroll to ScrollContainer (clamped to valid range)
            const max_scroll = sc.state.maxScrollY();
            sc.state.offset_y = std.math.clamp(target, 0, max_scroll);
            state.scroll_offset_px = sc.state.offset_y;
            state.pending_scroll = null; // Consume the request
        } else {
            // Normal sync: read current offset from ScrollContainer
            state.scroll_offset_px = sc.state.offset_y;
        }
    }

    /// Compute all layout parameters for uniform list.
    fn computeUniformListLayout(
        id: []const u8,
        state: *const UniformListState,
        style: UniformListStyle,
    ) UniformListLayout {
        const range = state.visibleRange();
        const content_height = state.contentHeight();

        return .{
            .layout_id = LayoutId.fromString(id),
            .sizing = computeUniformListSizing(style),
            .padding = computeUniformListPadding(style),
            .content_height = content_height,
            .top_spacer_height = state.topSpacerHeight(range),
            .bottom_spacer_height = state.bottomSpacerHeight(range),
            .range = range,
            .gap = @intFromFloat(style.gap),
        };
    }

    /// Open the scroll viewport and content container elements.
    /// Returns the content_id, or null if layout failed.
    fn openUniformListElements(
        self: *Self,
        params: UniformListLayout,
        style: UniformListStyle,
        scroll_offset: f32,
    ) ?LayoutId {
        // Open scroll viewport element
        self.layout.openElement(.{
            .id = params.layout_id,
            .layout = .{
                .sizing = params.sizing,
                .padding = params.padding,
            },
            .background_color = style.background,
            .corner_radius = if (style.corner_radius > 0) CornerRadius.all(style.corner_radius) else .{},
            .scroll = .{
                .vertical = true,
                .horizontal = false,
                .scroll_offset = .{ .x = 0, .y = scroll_offset },
            },
        }) catch {
            std.debug.assert(false); // Layout allocation failed
            return null;
        };

        // Inner content container with full virtual height
        const content_id = self.generateId();
        self.layout.openElement(.{
            .id = content_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.grow(),
                    .height = SizingAxis.fixed(params.content_height),
                },
                .layout_direction = .top_to_bottom,
                .child_gap = params.gap,
            },
        }) catch {
            self.layout.closeElement(); // Close viewport
            std.debug.assert(false); // Layout allocation failed
            return null;
        };

        return content_id;
    }

    /// Render a spacer element of given height for uniform list virtualization.
    fn renderUniformListSpacer(self: *Self, height: f32) void {
        if (height <= 0) return;

        const spacer_id = self.generateId();
        self.layout.openElement(.{
            .id = spacer_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.grow(),
                    .height = SizingAxis.fixed(height),
                },
            },
        }) catch {
            std.debug.assert(false); // Spacer allocation failed
            return;
        };
        self.layout.closeElement();
    }

    /// Register scroll handling for the uniform list.
    fn registerUniformListScroll(
        self: *Self,
        id: []const u8,
        params: UniformListLayout,
        content_id: LayoutId,
        style: UniformListStyle,
    ) void {
        const index = self.pending_scrolls.items.len;
        self.pending_scrolls.append(self.allocator, .{
            .id = id,
            .layout_id = params.layout_id,
            .style = .{
                .vertical = true,
                .horizontal = false,
                .scrollbar_size = style.scrollbar_size,
                .track_color = style.track_color,
                .thumb_color = style.thumb_color,
                .content_height = params.content_height,
            },
            .content_layout_id = content_id,
        }) catch {
            std.debug.assert(false); // Scroll registration failed
            return;
        };

        self.pending_scrolls_by_layout_id.put(self.allocator, params.layout_id.id, index) catch {
            std.debug.assert(false); // Scroll map insertion failed
        };
    }

    /// Render a virtualized uniform-height list.
    /// Only renders visible items for O(1) layout regardless of total item count.
    ///
    /// The `render_item` callback is called once per visible item with:
    /// - `index`: the item's index in the full list (0 to item_count-1)
    /// - `builder`: the Builder to render children into
    ///
    /// IMPORTANT: The height of each rendered item MUST match `state.item_height_px`.
    ///
    /// Example:
    /// ```zig
    /// var list_state = UniformListState.init(@intCast(items.len), 32.0);
    ///
    /// b.uniformList("file-list", &list_state, .{ .height = 400 }, renderFileItem);
    ///
    /// fn renderFileItem(index: u32, builder: *Builder) void {
    ///     const item = my_items[index];
    ///     builder.box(.{ .height = 32 }, .{ text(item.name, .{}) });
    /// }
    /// ```
    pub fn uniformList(
        self: *Self,
        id: []const u8,
        state: *UniformListState,
        style: UniformListStyle,
        render_item: *const fn (index: u32, builder: *Self) void,
    ) void {
        // Sync gap from style to state for correct height calculations
        state.gap_px = style.gap;

        // Sync scroll state with retained ScrollContainer
        self.syncUniformListScroll(id, state);

        // Compute layout parameters
        const params = computeUniformListLayout(id, state, style);

        // Open viewport and content elements
        const content_id = self.openUniformListElements(params, style, state.scroll_offset_px) orelse return;

        // Top spacer (items above visible range)
        self.renderUniformListSpacer(params.top_spacer_height);

        // Render only visible items
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            render_item(i, self);
        }

        // Bottom spacer (items below visible range)
        self.renderUniformListSpacer(params.bottom_spacer_height);

        // Close content container and viewport
        self.layout.closeElement();
        self.layout.closeElement();

        // Register for scroll handling
        self.registerUniformListScroll(id, params, content_id, style);
    }

    /// Render a virtualized uniform-height list with context pointer.
    /// Like uniformList, but passes a context pointer to the render callback
    /// for accessing external data without globals.
    ///
    /// Example:
    /// ```zig
    /// b.uniformListWithContext("list", &list_state, .{ .height = 400 }, &my_state, renderItem);
    ///
    /// fn renderItem(index: u32, state: *MyState, builder: *Builder) void {
    ///     const item = state.items[index];
    ///     builder.box(.{ .height = 32 }, .{ text(item.name, .{}) });
    /// }
    /// ```
    pub fn uniformListWithContext(
        self: *Self,
        id: []const u8,
        state: *UniformListState,
        style: UniformListStyle,
        context: anytype,
        render_item: *const fn (index: u32, ctx: @TypeOf(context), builder: *Self) void,
    ) void {
        // Sync gap from style to state for correct height calculations
        state.gap_px = style.gap;

        // Sync scroll state with retained ScrollContainer
        self.syncUniformListScroll(id, state);

        // Compute layout parameters
        const params = computeUniformListLayout(id, state, style);

        // Open viewport and content elements
        const content_id = self.openUniformListElements(params, style, state.scroll_offset_px) orelse return;

        // Top spacer (items above visible range)
        self.renderUniformListSpacer(params.top_spacer_height);

        // Render only visible items with context
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            render_item(i, context, self);
        }

        // Bottom spacer (items below visible range)
        self.renderUniformListSpacer(params.bottom_spacer_height);

        // Close content container and viewport
        self.layout.closeElement();
        self.layout.closeElement();

        // Register for scroll handling
        self.registerUniformListScroll(id, params, content_id, style);
    }

    // =========================================================================
    // Virtual List (variable-height items)
    // =========================================================================

    const virtual_list = @import("../widgets/virtual_list.zig");
    const VirtualListState = virtual_list.VirtualListState;

    /// Layout parameters for virtual list rendering
    const VirtualListLayout = struct {
        layout_id: LayoutId,
        sizing: Sizing,
        padding: Padding,
        content_height: f32,
        top_spacer_height: f32,
        bottom_spacer_height: f32,
        range: @import("../widgets/virtual_list.zig").VisibleRange,
        gap: u16,
    };

    /// Sync scroll state between VirtualListState and retained ScrollContainer.
    fn syncVirtualListScroll(self: *Self, id: []const u8, state: *VirtualListState) void {
        const g = self.gooey orelse return;
        const sc = g.widgets.scrollContainer(id) orelse return;

        // Update viewport dimensions FIRST so calculations are accurate
        state.viewport_height_px = sc.state.viewport_height;

        if (state.pending_scroll) |request| {
            // Resolve the scroll request with current accurate viewport dimensions
            const target: f32 = switch (request) {
                .absolute => |offset| offset,
                .to_top => 0,
                .to_end => state.maxScrollOffset(),
                .to_item => |item| state.resolveScrollToItem(item.index, item.strategy),
            };

            // Apply resolved scroll to ScrollContainer (clamped to valid range)
            const max_scroll = sc.state.maxScrollY();
            sc.state.offset_y = std.math.clamp(target, 0, max_scroll);
            state.scroll_offset_px = sc.state.offset_y;
            state.pending_scroll = null; // Consume the request
        } else {
            // Normal sync: read current offset from ScrollContainer
            state.scroll_offset_px = sc.state.offset_y;
        }
    }

    /// Compute sizing for virtual list viewport
    fn computeVirtualListSizing(style: VirtualListStyle) Sizing {
        var sizing = Sizing{
            .width = SizingAxis.fit(),
            .height = SizingAxis.fit(),
        };

        // Fixed dimensions
        if (style.width) |w| sizing.width = SizingAxis.fixed(w);
        if (style.height) |h| sizing.height = SizingAxis.fixed(h);

        // Flexible sizing
        if (style.grow) {
            sizing.width = SizingAxis.grow();
            sizing.height = SizingAxis.grow();
        }
        if (style.grow_width) sizing.width = SizingAxis.grow();
        if (style.grow_height) sizing.height = SizingAxis.grow();
        if (style.fill_width) sizing.width = SizingAxis.percent(1.0);
        if (style.fill_height) sizing.height = SizingAxis.percent(1.0);

        return sizing;
    }

    /// Compute padding for virtual list viewport
    fn computeVirtualListPadding(style: VirtualListStyle) Padding {
        return switch (style.padding) {
            .all => |v| Padding.all(@intFromFloat(v)),
            .symmetric => |s| Padding.symmetric(@intFromFloat(s.x), @intFromFloat(s.y)),
            .each => |i| .{
                .top = @intFromFloat(i.top),
                .bottom = @intFromFloat(i.bottom),
                .left = @intFromFloat(i.left),
                .right = @intFromFloat(i.right),
            },
        };
    }

    /// Compute all layout parameters for virtual list.
    fn computeVirtualListLayout(
        id: []const u8,
        state: *const VirtualListState,
        style: VirtualListStyle,
    ) VirtualListLayout {
        const range = state.visibleRange();
        const content_height = state.contentHeight();

        return .{
            .layout_id = LayoutId.fromString(id),
            .sizing = computeVirtualListSizing(style),
            .padding = computeVirtualListPadding(style),
            .content_height = content_height,
            .top_spacer_height = state.topSpacerHeight(range),
            .bottom_spacer_height = state.bottomSpacerHeight(range),
            .range = range,
            .gap = @intFromFloat(style.gap),
        };
    }

    /// Open the scroll viewport and content container elements for virtual list.
    fn openVirtualListElements(
        self: *Self,
        params: VirtualListLayout,
        style: VirtualListStyle,
        scroll_offset: f32,
    ) ?LayoutId {
        // Open scroll viewport element
        self.layout.openElement(.{
            .id = params.layout_id,
            .layout = .{
                .sizing = params.sizing,
                .padding = params.padding,
            },
            .background_color = style.background,
            .corner_radius = if (style.corner_radius > 0) CornerRadius.all(style.corner_radius) else .{},
            .scroll = .{
                .vertical = true,
                .horizontal = false,
                .scroll_offset = .{ .x = 0, .y = scroll_offset },
            },
        }) catch {
            std.debug.assert(false); // Layout allocation failed
            return null;
        };

        // Inner content container with full virtual height
        const content_id = self.generateId();
        self.layout.openElement(.{
            .id = content_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.grow(),
                    .height = SizingAxis.fixed(params.content_height),
                },
                .layout_direction = .top_to_bottom,
                .child_gap = params.gap,
            },
        }) catch {
            self.layout.closeElement(); // Close viewport
            std.debug.assert(false); // Layout allocation failed
            return null;
        };

        return content_id;
    }

    /// Render a spacer element for virtual list virtualization.
    fn renderVirtualListSpacer(self: *Self, height: f32) void {
        if (height <= 0) return;

        const spacer_id = self.generateId();
        self.layout.openElement(.{
            .id = spacer_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.grow(),
                    .height = SizingAxis.fixed(height),
                },
            },
        }) catch {
            std.debug.assert(false); // Spacer allocation failed
            return;
        };
        self.layout.closeElement();
    }

    /// Register scroll handling for the virtual list.
    fn registerVirtualListScroll(
        self: *Self,
        id: []const u8,
        params: VirtualListLayout,
        content_id: LayoutId,
        style: VirtualListStyle,
    ) void {
        const index = self.pending_scrolls.items.len;
        self.pending_scrolls.append(self.allocator, .{
            .id = id,
            .layout_id = params.layout_id,
            .style = .{
                .vertical = true,
                .horizontal = false,
                .scrollbar_size = style.scrollbar_size,
                .track_color = style.track_color,
                .thumb_color = style.thumb_color,
                .content_height = params.content_height,
            },
            .content_layout_id = content_id,
        }) catch {
            std.debug.assert(false); // Scroll registration failed
            return;
        };

        self.pending_scrolls_by_layout_id.put(self.allocator, params.layout_id.id, index) catch {
            std.debug.assert(false); // Scroll map insertion failed
        };
    }

    /// Render a virtualized variable-height list.
    ///
    /// Unlike `uniformList` where all items have the same height, `virtualList`
    /// supports items with different heights. The render callback must return
    /// the actual height of each rendered item, which is cached for efficient
    /// scroll calculations.
    ///
    /// IMPORTANT: The render callback MUST return the exact height of the
    /// rendered item. This height is cached and used for scroll calculations.
    ///
    /// Example:
    /// ```zig
    /// var list_state = VirtualListState.init(100, 32.0); // count, default height
    ///
    /// b.virtualList("chat", &list_state, .{ .height = 400 }, renderMessage);
    ///
    /// fn renderMessage(index: u32, builder: *Builder) f32 {
    ///     const msg = messages[index];
    ///     const height: f32 = if (msg.has_image) 120.0 else 48.0;
    ///     builder.box(.{ .height = height }, .{ text(msg.text, .{}) });
    ///     return height; // Return actual height for caching
    /// }
    /// ```
    pub fn virtualList(
        self: *Self,
        id: []const u8,
        state: *VirtualListState,
        style: VirtualListStyle,
        render_item: *const fn (index: u32, builder: *Self) f32,
    ) void {
        // Sync gap from style to state for correct height calculations
        state.gap_px = style.gap;

        // Sync scroll state with retained ScrollContainer
        self.syncVirtualListScroll(id, state);

        // Compute layout parameters
        const params = computeVirtualListLayout(id, state, style);

        // Open viewport and content elements
        const content_id = self.openVirtualListElements(params, style, state.scroll_offset_px) orelse return;

        // Top spacer (items above visible range)
        self.renderVirtualListSpacer(params.top_spacer_height);

        // Render only visible items and cache their heights
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            const height = render_item(i, self);
            state.setHeight(i, height);
        }

        // Bottom spacer (items below visible range)
        self.renderVirtualListSpacer(params.bottom_spacer_height);

        // Close content container and viewport
        self.layout.closeElement();
        self.layout.closeElement();

        // Register for scroll handling
        self.registerVirtualListScroll(id, params, content_id, style);
    }

    /// Render a virtualized variable-height list with context pointer.
    /// Like virtualList, but passes a context pointer to the render callback
    /// for accessing external data without globals.
    ///
    /// Example:
    /// ```zig
    /// const ctx = RenderContext{ .messages = &my_messages };
    /// b.virtualListWithContext("chat", &list_state, .{}, ctx, renderMessage);
    ///
    /// fn renderMessage(index: u32, ctx: RenderContext, builder: *Builder) f32 {
    ///     const msg = ctx.messages[index];
    ///     const height: f32 = if (msg.expanded) 100.0 else 40.0;
    ///     builder.box(.{ .height = height }, .{ text(msg.text, .{}) });
    ///     return height;
    /// }
    /// ```
    pub fn virtualListWithContext(
        self: *Self,
        id: []const u8,
        state: *VirtualListState,
        style: VirtualListStyle,
        context: anytype,
        render_item: *const fn (index: u32, ctx: @TypeOf(context), builder: *Self) f32,
    ) void {
        // Sync gap from style to state for correct height calculations
        state.gap_px = style.gap;

        // Sync scroll state with retained ScrollContainer
        self.syncVirtualListScroll(id, state);

        // Compute layout parameters
        const params = computeVirtualListLayout(id, state, style);

        // Open viewport and content elements
        const content_id = self.openVirtualListElements(params, style, state.scroll_offset_px) orelse return;

        // Top spacer (items above visible range)
        self.renderVirtualListSpacer(params.top_spacer_height);

        // Render only visible items with context and cache their heights
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            const height = render_item(i, context, self);
            state.setHeight(i, height);
        }

        // Bottom spacer (items below visible range)
        self.renderVirtualListSpacer(params.bottom_spacer_height);

        // Close content container and viewport
        self.layout.closeElement();
        self.layout.closeElement();

        // Register for scroll handling
        self.registerVirtualListScroll(id, params, content_id, style);
    }

    // =========================================================================
    // Data Table (virtualized 2D table, uniform row height)
    // =========================================================================

    const data_table = @import("../widgets/data_table.zig");
    pub const DataTableState = data_table.DataTableState;

    /// Layout parameters for data table rendering
    const DataTableLayout = struct {
        layout_id: LayoutId,
        sizing: Sizing,
        padding: Padding,
        content_width: f32,
        content_height: f32,
        visible_range: data_table.VisibleRange2D,
        top_spacer: f32,
        bottom_spacer: f32,
        left_spacer: f32,
        right_spacer: f32,
        row_gap: u16,
    };

    /// Compute sizing from DataTableStyle
    fn computeDataTableSizing(style: DataTableStyle) Sizing {
        var sizing = Sizing.fitContent();

        // Width sizing
        const grow_w = style.grow or style.grow_width;
        if (grow_w) {
            sizing.width = SizingAxis.grow();
        } else if (style.width) |w| {
            sizing.width = SizingAxis.fixed(w);
        } else if (style.fill_width) {
            sizing.width = SizingAxis.percent(1.0);
        } else {
            sizing.width = SizingAxis.fixed(data_table.DEFAULT_VIEWPORT_WIDTH);
        }

        // Height sizing
        const grow_h = style.grow or style.grow_height;
        if (grow_h) {
            sizing.height = SizingAxis.grow();
        } else if (style.height) |h| {
            sizing.height = SizingAxis.fixed(h);
        } else if (style.fill_height) {
            sizing.height = SizingAxis.percent(1.0);
        } else {
            sizing.height = SizingAxis.fixed(data_table.DEFAULT_VIEWPORT_HEIGHT);
        }

        return sizing;
    }

    /// Convert style padding to layout Padding
    fn computeDataTablePadding(style: DataTableStyle) Padding {
        return switch (style.padding) {
            .all => |v| Padding.all(@intFromFloat(v)),
            .symmetric => |s| Padding.symmetric(@intFromFloat(s.x), @intFromFloat(s.y)),
            .each => |e| .{
                .top = @intFromFloat(e.top),
                .right = @intFromFloat(e.right),
                .bottom = @intFromFloat(e.bottom),
                .left = @intFromFloat(e.left),
            },
        };
    }

    /// Sync scroll state between DataTableState and retained ScrollContainer
    fn syncDataTableScroll(self: *Self, id: []const u8, state: *DataTableState) void {
        const g = self.gooey orelse return;
        const sc = g.widgets.scrollContainer(id) orelse return;

        // Update viewport dimensions FIRST so calculations are accurate
        state.viewport_width_px = sc.state.viewport_width;
        state.viewport_height_px = sc.state.viewport_height;

        if (state.pending_scroll != null) {
            // Resolve the scroll request with current accurate viewport dimensions
            state.resolvePendingScroll();
            // Apply resolved scroll to ScrollContainer
            const max_x = sc.state.maxScrollX();
            const max_y = sc.state.maxScrollY();
            sc.state.offset_x = std.math.clamp(state.scroll_offset_x, 0, max_x);
            sc.state.offset_y = std.math.clamp(state.scroll_offset_y, 0, max_y);
        } else {
            // Normal sync: read current offset from ScrollContainer
            state.scroll_offset_x = sc.state.offset_x;
            state.scroll_offset_y = sc.state.offset_y;
        }
    }

    /// Compute all layout parameters for data table
    fn computeDataTableLayout(
        id: []const u8,
        state: *const DataTableState,
        style: DataTableStyle,
    ) DataTableLayout {
        const range = state.visibleRange();

        return .{
            .layout_id = LayoutId.fromString(id),
            .sizing = computeDataTableSizing(style),
            .padding = computeDataTablePadding(style),
            .content_width = state.contentWidth(),
            .content_height = state.contentHeight(),
            .visible_range = range,
            .top_spacer = state.topSpacerHeight(range.rows),
            .bottom_spacer = state.bottomSpacerHeight(range.rows),
            .left_spacer = state.leftSpacerWidth(range.cols),
            .right_spacer = state.rightSpacerWidth(range.cols),
            .row_gap = @intFromFloat(style.row_gap),
        };
    }

    /// Open the scroll viewport and content container elements for data table
    fn openDataTableElements(
        self: *Self,
        params: DataTableLayout,
        style: DataTableStyle,
        scroll_x: f32,
        scroll_y: f32,
    ) ?LayoutId {
        // Open scroll viewport element (both axes)
        self.layout.openElement(.{
            .id = params.layout_id,
            .layout = .{
                .sizing = params.sizing,
                .padding = params.padding,
            },
            .background_color = style.background,
            .corner_radius = if (style.corner_radius > 0) CornerRadius.all(style.corner_radius) else .{},
            .scroll = .{
                .vertical = true,
                .horizontal = true,
                .scroll_offset = .{ .x = scroll_x, .y = scroll_y },
            },
        }) catch {
            std.debug.assert(false);
            return null;
        };

        // Inner content container with full virtual size
        const content_id = self.generateId();
        self.layout.openElement(.{
            .id = content_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(params.content_width),
                    .height = SizingAxis.fixed(params.content_height),
                },
                .layout_direction = .top_to_bottom,
                .child_gap = params.row_gap,
            },
        }) catch {
            self.layout.closeElement();
            std.debug.assert(false);
            return null;
        };

        return content_id;
    }

    /// Render a spacer element for data table virtualization
    fn renderDataTableSpacer(self: *Self, width: f32, height: f32) void {
        if (width <= 0 and height <= 0) return;

        const spacer_id = self.generateId();
        self.layout.openElement(.{
            .id = spacer_id,
            .layout = .{
                .sizing = .{
                    .width = if (width > 0) SizingAxis.fixed(width) else SizingAxis.grow(),
                    .height = if (height > 0) SizingAxis.fixed(height) else SizingAxis.grow(),
                },
            },
        }) catch {
            std.debug.assert(false);
            return;
        };
        self.layout.closeElement();
    }

    /// Register scroll handling for the data table
    fn registerDataTableScroll(
        self: *Self,
        id: []const u8,
        params: DataTableLayout,
        content_id: LayoutId,
        style: DataTableStyle,
    ) void {
        const index = self.pending_scrolls.items.len;
        self.pending_scrolls.append(self.allocator, .{
            .id = id,
            .layout_id = params.layout_id,
            .style = .{
                .vertical = true,
                .horizontal = true,
                .scrollbar_size = style.scrollbar_size,
                .track_color = style.track_color,
                .thumb_color = style.thumb_color,
                .content_height = params.content_height,
                .content_width = params.content_width,
            },
            .content_layout_id = content_id,
        }) catch {
            std.debug.assert(false);
            return;
        };

        self.pending_scrolls_by_layout_id.put(self.allocator, params.layout_id.id, index) catch {
            std.debug.assert(false);
        };
    }

    /// Render a virtualized data table.
    /// Only renders visible cells for O(1) layout regardless of total size.
    ///
    /// The `render_cell` callback receives (row, col, builder) for each visible cell.
    /// The `render_header` callback receives (col, builder) for each visible header cell.
    ///
    /// Example:
    /// ```zig
    /// var table = DataTableState.init(1000, 32.0);
    /// table.addColumn(.{ .width_px = 200 }) catch unreachable;
    ///
    /// b.dataTable("users", &table, .{ .height = 400 }, renderCell, renderHeader);
    /// ```
    pub fn dataTable(
        self: *Self,
        id: []const u8,
        state: *DataTableState,
        style: DataTableStyle,
        render_cell: *const fn (row: u32, col: u32, builder: *Self) void,
        render_header: ?*const fn (col: u32, builder: *Self) void,
    ) void {
        // Sync gap from style to state
        state.row_gap_px = style.row_gap;

        // Sync scroll state
        self.syncDataTableScroll(id, state);

        // Compute layout parameters
        const params = computeDataTableLayout(id, state, style);

        // Open viewport and content elements
        const content_id = self.openDataTableElements(
            params,
            style,
            state.scroll_offset_x,
            state.scroll_offset_y,
        ) orelse return;

        // Render header row if enabled
        if (state.show_header) {
            if (render_header) |header_fn| {
                self.renderDataTableHeader(state, params, style, header_fn);
            }
        }

        // Top spacer (rows above visible range)
        if (params.top_spacer > 0) {
            self.renderDataTableSpacer(params.content_width, params.top_spacer);
        }

        // Render visible rows
        const range = params.visible_range;
        var row = range.rows.start;
        while (row < range.rows.end) : (row += 1) {
            self.renderDataTableRow(state, row, range.cols, params, style, render_cell);
        }

        // Bottom spacer (rows below visible range)
        if (params.bottom_spacer > 0) {
            self.renderDataTableSpacer(params.content_width, params.bottom_spacer);
        }

        // Close content container and viewport
        self.layout.closeElement();
        self.layout.closeElement();

        // Register for scroll handling
        self.registerDataTableScroll(id, params, content_id, style);
    }

    /// Render header row for data table
    fn renderDataTableHeader(
        self: *Self,
        state: *const DataTableState,
        params: DataTableLayout,
        style: DataTableStyle,
        render_header: *const fn (col: u32, builder: *Self) void,
    ) void {
        // Open header row container
        self.layout.openElement(.{
            .id = self.generateId(),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(params.content_width),
                    .height = SizingAxis.fixed(state.header_height_px),
                },
                .layout_direction = .left_to_right,
            },
            .background_color = style.header_background,
        }) catch return;

        // Left spacer
        if (params.left_spacer > 0) {
            self.renderDataTableSpacer(params.left_spacer, state.header_height_px);
        }

        // Render visible header cells
        const col_range = params.visible_range.cols;
        var col = col_range.start;
        while (col < col_range.end) : (col += 1) {
            const col_width = state.columns[col].width_px;
            const header_id = self.generateId();

            // Push dispatch node for click handling
            _ = self.dispatch.pushNode();
            self.dispatch.setLayoutId(header_id.id);

            self.layout.openElement(.{
                .id = header_id,
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.fixed(col_width),
                        .height = SizingAxis.fixed(state.header_height_px),
                    },
                },
            }) catch {
                self.dispatch.popNode();
                continue;
            };

            // Register header click handler if column is sortable
            if (style.on_header_click) |callback| {
                if (state.columns[col].sortable) {
                    self.dispatch.onClickWithData(callback, col);
                }
            }

            render_header(col, self);
            self.layout.closeElement();
            self.dispatch.popNode();
        }

        // Right spacer
        if (params.right_spacer > 0) {
            self.renderDataTableSpacer(params.right_spacer, state.header_height_px);
        }

        self.layout.closeElement(); // header row
    }

    /// Render a single data row
    fn renderDataTableRow(
        self: *Self,
        state: *const DataTableState,
        row: u32,
        col_range: data_table.ColRange,
        params: DataTableLayout,
        style: DataTableStyle,
        render_cell: *const fn (row: u32, col: u32, builder: *Self) void,
    ) void {
        // Determine row background
        const is_selected = state.selection.isRowSelected(row);
        const is_alternate = row % 2 == 1;
        const bg = if (is_selected)
            style.row_selected_background
        else if (is_alternate)
            style.row_alternate_background
        else
            style.row_background;

        const row_id = self.generateId();

        // Push dispatch node for row click handling
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(row_id.id);

        // Open row container
        self.layout.openElement(.{
            .id = row_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(params.content_width),
                    .height = SizingAxis.fixed(state.row_height_px),
                },
                .layout_direction = .left_to_right,
            },
            .background_color = bg,
        }) catch {
            self.dispatch.popNode();
            return;
        };

        // Register row click handler
        if (style.on_row_click) |callback| {
            self.dispatch.onClickWithData(callback, row);
        }

        // Left spacer for columns before visible range
        if (params.left_spacer > 0) {
            self.renderDataTableSpacer(params.left_spacer, state.row_height_px);
        }

        // Render visible cells
        var col = col_range.start;
        while (col < col_range.end) : (col += 1) {
            const col_width = state.columns[col].width_px;

            self.layout.openElement(.{
                .id = self.generateId(),
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.fixed(col_width),
                        .height = SizingAxis.fixed(state.row_height_px),
                    },
                },
            }) catch continue;

            render_cell(row, col, self);
            self.layout.closeElement();
        }

        // Right spacer
        if (params.right_spacer > 0) {
            self.renderDataTableSpacer(params.right_spacer, state.row_height_px);
        }

        self.layout.closeElement(); // row container
        self.dispatch.popNode();
    }

    /// Render a virtualized data table with context pointer.
    /// Like dataTable, but passes a context pointer to the render callbacks.
    pub fn dataTableWithContext(
        self: *Self,
        id: []const u8,
        state: *DataTableState,
        style: DataTableStyle,
        context: anytype,
        render_cell: *const fn (row: u32, col: u32, ctx: @TypeOf(context), builder: *Self) void,
        render_header: ?*const fn (col: u32, ctx: @TypeOf(context), builder: *Self) void,
    ) void {
        // Sync gap from style to state
        state.row_gap_px = style.row_gap;

        // Sync scroll state
        self.syncDataTableScroll(id, state);

        // Compute layout parameters
        const params = computeDataTableLayout(id, state, style);

        // Open viewport and content elements
        const content_id = self.openDataTableElements(
            params,
            style,
            state.scroll_offset_x,
            state.scroll_offset_y,
        ) orelse return;

        // Render header row if enabled
        if (state.show_header) {
            if (render_header) |header_fn| {
                self.renderDataTableHeaderWithContext(state, params, style, context, header_fn);
            }
        }

        // Top spacer
        if (params.top_spacer > 0) {
            self.renderDataTableSpacer(params.content_width, params.top_spacer);
        }

        // Render visible rows
        const range = params.visible_range;
        var row = range.rows.start;
        while (row < range.rows.end) : (row += 1) {
            self.renderDataTableRowWithContext(state, row, range.cols, params, style, context, render_cell);
        }

        // Bottom spacer
        if (params.bottom_spacer > 0) {
            self.renderDataTableSpacer(params.content_width, params.bottom_spacer);
        }

        // Close elements
        self.layout.closeElement();
        self.layout.closeElement();

        // Register for scroll handling
        self.registerDataTableScroll(id, params, content_id, style);
    }

    /// Render header row with context
    fn renderDataTableHeaderWithContext(
        self: *Self,
        state: *const DataTableState,
        params: DataTableLayout,
        style: DataTableStyle,
        context: anytype,
        render_header: *const fn (col: u32, ctx: @TypeOf(context), builder: *Self) void,
    ) void {
        self.layout.openElement(.{
            .id = self.generateId(),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(params.content_width),
                    .height = SizingAxis.fixed(state.header_height_px),
                },
                .layout_direction = .left_to_right,
            },
            .background_color = style.header_background,
        }) catch return;

        if (params.left_spacer > 0) {
            self.renderDataTableSpacer(params.left_spacer, state.header_height_px);
        }

        const col_range = params.visible_range.cols;
        var col = col_range.start;
        while (col < col_range.end) : (col += 1) {
            const col_width = state.columns[col].width_px;
            const header_id = self.generateId();

            // Push dispatch node for click handling
            _ = self.dispatch.pushNode();
            self.dispatch.setLayoutId(header_id.id);

            self.layout.openElement(.{
                .id = header_id,
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.fixed(col_width),
                        .height = SizingAxis.fixed(state.header_height_px),
                    },
                },
            }) catch {
                self.dispatch.popNode();
                continue;
            };

            // Register header click handler if column is sortable
            if (style.on_header_click) |callback| {
                if (state.columns[col].sortable) {
                    self.dispatch.onClickWithData(callback, col);
                }
            }

            render_header(col, context, self);
            self.layout.closeElement();
            self.dispatch.popNode();
        }

        if (params.right_spacer > 0) {
            self.renderDataTableSpacer(params.right_spacer, state.header_height_px);
        }

        self.layout.closeElement();
    }

    /// Render data row with context
    fn renderDataTableRowWithContext(
        self: *Self,
        state: *const DataTableState,
        row: u32,
        col_range: data_table.ColRange,
        params: DataTableLayout,
        style: DataTableStyle,
        context: anytype,
        render_cell: *const fn (row: u32, col: u32, ctx: @TypeOf(context), builder: *Self) void,
    ) void {
        const is_selected = state.selection.isRowSelected(row);
        const is_alternate = row % 2 == 1;
        const bg = if (is_selected)
            style.row_selected_background
        else if (is_alternate)
            style.row_alternate_background
        else
            style.row_background;

        const row_id = self.generateId();

        // Push dispatch node for row click handling
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(row_id.id);

        self.layout.openElement(.{
            .id = row_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(params.content_width),
                    .height = SizingAxis.fixed(state.row_height_px),
                },
                .layout_direction = .left_to_right,
            },
            .background_color = bg,
        }) catch {
            self.dispatch.popNode();
            return;
        };

        // Register row click handler
        if (style.on_row_click) |callback| {
            self.dispatch.onClickWithData(callback, row);
        }

        if (params.left_spacer > 0) {
            self.renderDataTableSpacer(params.left_spacer, state.row_height_px);
        }

        var col = col_range.start;
        while (col < col_range.end) : (col += 1) {
            const col_width = state.columns[col].width_px;

            self.layout.openElement(.{
                .id = self.generateId(),
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.fixed(col_width),
                        .height = SizingAxis.fixed(state.row_height_px),
                    },
                },
            }) catch continue;

            render_cell(row, col, context, self);
            self.layout.closeElement();
        }

        if (params.right_spacer > 0) {
            self.renderDataTableSpacer(params.right_spacer, state.row_height_px);
        }

        self.layout.closeElement();
        self.dispatch.popNode();
    }

    /// Register scroll container regions and update state
    pub fn registerPendingScrollRegions(self: *Self) void {
        for (self.pending_scrolls.items) |pending| {
            const viewport_bounds = self.layout.getBoundingBox(pending.layout_id.id);
            const viewport_content = self.layout.getContentBox(pending.layout_id.id);
            const content_bounds = self.layout.getBoundingBox(pending.content_layout_id.id);

            if (viewport_bounds != null and viewport_content != null and content_bounds != null) {
                const vp = viewport_bounds.?;
                const vp_content = viewport_content.?;
                const ct = content_bounds.?;

                if (self.gooey) |g| {
                    if (g.widgets.scrollContainer(pending.id)) |sc| {
                        // Update bounds (full bounding box for hit testing)
                        sc.bounds = .{
                            .x = vp.x,
                            .y = vp.y,
                            .width = vp.width,
                            .height = vp.height,
                        };

                        // Update viewport size using content box (inside padding)
                        // This ensures scroll range accounts for padding correctly
                        sc.setViewport(vp_content.width, vp_content.height);
                        sc.setContentSize(ct.width, ct.height);

                        // Apply scroll directions
                        sc.style.horizontal = pending.style.horizontal;
                        sc.style.vertical = pending.style.vertical;

                        // Apply theme colors if provided
                        if (pending.style.track_color) |c| sc.style.track_color = c;
                        if (pending.style.thumb_color) |c| sc.style.thumb_color = c;
                        sc.style.scrollbar_size = pending.style.scrollbar_size;
                    }
                }
            }
        }
    }

    // =========================================================================
    // Internal: Child Processing
    // =========================================================================

    pub fn processChildren(self: *Self, children: anytype) void {
        const T = @TypeOf(children);
        const type_info = @typeInfo(T);

        if (type_info == .@"struct" and type_info.@"struct".is_tuple) {
            inline for (children) |child| {
                self.processChild(child);
            }
        } else {
            self.processChild(children);
        }
    }

    fn processChild(self: *Self, child: anytype) void {
        const T = @TypeOf(child);
        const type_info = @typeInfo(T);

        // Handle null (from conditionals)
        if (T == @TypeOf(null)) {
            return;
        }

        // Handle optional types
        if (type_info == .optional) {
            if (child) |val| {
                self.processChild(val);
            }
            return;
        }

        if (type_info != .@"struct") {
            return;
        }

        // Check for primitives
        if (@hasDecl(T, "primitive_type")) {
            const prim_type: PrimitiveType = T.primitive_type;
            switch (prim_type) {
                .text => self.renderText(child),
                .input => self.renderInput(child),
                .text_area => self.renderTextArea(child),
                .spacer => self.renderSpacer(child),
                .button => self.renderButton(child),
                .key_context => self.renderKeyContext(child),
                .action_handler => self.renderActionHandler(child),
                .button_handler => self.renderButtonHandler(child),
                .action_handler_ref => self.renderActionHandlerRef(child),
                .svg => self.renderSvg(child),
                .image => self.renderImage(child),
                .empty => {}, // Do nothing

            }
            return;
        }

        // Check for components
        // Check for components (structs with render method)
        if (@hasDecl(T, "render")) {
            const render_fn = @field(T, "render");
            const RenderFnType = @TypeOf(render_fn);
            const fn_info = @typeInfo(RenderFnType).@"fn";

            // Check if render expects *Cx (new pattern) or *Builder (old pattern)
            if (fn_info.params.len >= 2) {
                const SecondParam = fn_info.params[1].type orelse *Self;

                if (SecondParam == *Self) {
                    // Old pattern: render(self, *Builder)
                    child.render(self);
                } else if (self.cx_ptr) |cx_raw| {
                    // New pattern: render(self, *Cx) - cast and call
                    const CxType = SecondParam;
                    const cx: CxType = @ptrCast(@alignCast(cx_raw));
                    child.render(cx);
                } else {
                    // Cx not available, skip
                }
            }
            return;
        }

        // Handle nested tuples
        if (type_info.@"struct".is_tuple) {
            inline for (child) |nested| {
                self.processChild(nested);
            }
            return;
        }
    }

    // =========================================================================
    // Internal: Primitive Rendering
    // =========================================================================

    fn renderText(self: *Self, txt: Text) void {
        self.layout.text(txt.content, .{
            .color = txt.style.color,
            .font_size = txt.style.size,
            .wrap_mode = switch (txt.style.wrap) {
                .none => .none,
                .words => .words,
                .newlines => .newlines,
            },
            .alignment = switch (txt.style.alignment) {
                .left => .left,
                .center => .center,
                .right => .right,
            },
            .decoration = .{
                .underline = txt.style.underline,
                .strikethrough = txt.style.strikethrough,
            },
        }) catch return;
    }

    fn renderInput(self: *Self, inp: Input) void {
        const layout_id = LayoutId.fromString(inp.id);

        // Push dispatch node
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Register as focusable
        const focus_id = FocusId.init(inp.id);
        self.dispatch.setFocusable(focus_id);

        // Check if this input is focused (for border color)
        const is_focused = if (self.gooey) |g|
            if (g.textInput(inp.id)) |ti| ti.isFocused() else false
        else
            false;

        // Calculate height: use explicit height or auto-size from font metrics
        const chrome = (inp.style.padding + inp.style.border_width) * 2;
        const input_height = inp.style.height orelse blk: {
            // Auto-size: get line height from font metrics
            const line_height = if (self.gooey) |g|
                if (g.text_system.getMetrics()) |m| m.line_height else 20.0
            else
                20.0; // Fallback
            break :blk line_height + chrome;
        };

        // Calculate inner content size (text area)
        const input_width = inp.style.width orelse 200;
        const inner_width = input_width - chrome;
        const inner_height = input_height - chrome;

        // Create the outer box with chrome
        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(input_width),
                    .height = SizingAxis.fixed(input_height),
                },
                .padding = Padding.all(@intFromFloat(inp.style.padding + inp.style.border_width)),
            },
            .background_color = inp.style.background,
            .corner_radius = CornerRadius.all(inp.style.corner_radius),
            .border = BorderConfig.all(
                if (is_focused) inp.style.border_color_focused else inp.style.border_color,
                inp.style.border_width,
            ),
        }) catch {
            self.dispatch.popNode();
            return;
        };
        self.layout.closeElement();

        // Store for later text rendering with inner dimensions
        self.pending_inputs.append(self.allocator, .{
            .id = inp.id,
            .layout_id = layout_id,
            .style = inp.style,
            .inner_width = inner_width,
            .inner_height = inner_height,
        }) catch {};

        // Register focus with FocusManager
        if (self.gooey) |g| {
            g.focus.register(FocusHandle.init(inp.id)
                .tabIndex(inp.style.tab_index)
                .tabStop(inp.style.tab_stop));
        }

        self.dispatch.popNode();
    }

    fn renderTextArea(self: *Self, ta: TextAreaPrimitive) void {
        const layout_id = LayoutId.fromString(ta.id);

        // Push dispatch node
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Register as focusable
        const focus_id = FocusId.init(ta.id);
        self.dispatch.setFocusable(focus_id);

        // Check if this textarea is focused (for border color)
        const is_focused = if (self.gooey) |g|
            if (g.textArea(ta.id)) |text_area| text_area.isFocused() else false
        else
            false;

        // Calculate height: use explicit height or auto-size from rows * line_height
        const chrome = (ta.style.padding + ta.style.border_width) * 2;
        const textarea_height = ta.style.height orelse blk: {
            const line_height = if (self.gooey) |g|
                if (g.text_system.getMetrics()) |m| m.line_height else 20.0
            else
                20.0;
            const rows_f: f32 = @floatFromInt(ta.style.rows);
            break :blk (line_height * rows_f) + chrome;
        };

        // Calculate dimensions
        const textarea_width = ta.style.width orelse 300;
        const inner_width = textarea_width - chrome;
        const inner_height = textarea_height - chrome;

        // Create the outer box with chrome
        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(textarea_width),
                    .height = SizingAxis.fixed(textarea_height),
                },
                .padding = Padding.all(@intFromFloat(ta.style.padding + ta.style.border_width)),
            },
            .background_color = ta.style.background,
            .corner_radius = CornerRadius.all(ta.style.corner_radius),
            .border = BorderConfig.all(
                if (is_focused) ta.style.border_color_focused else ta.style.border_color,
                ta.style.border_width,
            ),
        }) catch {
            self.dispatch.popNode();
            return;
        };
        self.layout.closeElement();

        // Store for later text rendering
        self.pending_text_areas.append(self.allocator, .{
            .id = ta.id,
            .layout_id = layout_id,
            .style = ta.style,
            .inner_width = inner_width,
            .inner_height = inner_height,
        }) catch {};

        // Register focus with FocusManager
        if (self.gooey) |g| {
            g.focus.register(FocusHandle.init(ta.id)
                .tabIndex(ta.style.tab_index)
                .tabStop(ta.style.tab_stop));
        }

        self.dispatch.popNode();
    }

    fn renderSpacer(self: *Self, spc: Spacer) void {
        _ = spc;
        self.layout.openElement(.{
            .id = self.generateId(),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.grow(),
                    .height = SizingAxis.grow(),
                },
            },
        }) catch return;
        self.layout.closeElement();
    }

    fn renderButton(self: *Self, btn: Button) void {
        // Use explicit ID if provided, otherwise derive from label
        const layout_id = if (btn.id) |id| LayoutId.fromString(id) else LayoutId.fromString(btn.label);

        // Push dispatch node for this button
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Check hover state
        const is_hovered = btn.style.enabled and
            if (self.gooey) |g| g.isHovered(layout_id.id) else false;

        const bg = switch (btn.style.style) {
            .primary => if (!btn.style.enabled)
                Color.rgb(0.5, 0.7, 1.0)
            else if (is_hovered)
                Color.rgb(0.3, 0.6, 1.0) // Lighter on hover
            else
                Color.rgb(0.2, 0.5, 1.0),
            .secondary => if (is_hovered)
                Color.rgb(0.82, 0.82, 0.82) // Darker on hover
            else
                Color.rgb(0.9, 0.9, 0.9),
            .danger => if (is_hovered)
                Color.rgb(1.0, 0.4, 0.4) // Lighter on hover
            else
                Color.rgb(0.9, 0.3, 0.3),
        };
        const fg = switch (btn.style.style) {
            .primary, .danger => Color.white,
            .secondary => Color.rgb(0.3, 0.3, 0.3),
        };

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = Sizing.fitContent(),
                .padding = Padding.symmetric(24, 10),
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = bg,
            .corner_radius = CornerRadius.all(6),
        }) catch {
            self.dispatch.popNode();
            return;
        };

        self.layout.text(btn.label, .{
            .color = fg,
            .font_size = 14,
        }) catch {};

        self.layout.closeElement();

        // Register click handler with dispatch tree
        if (btn.on_click) |callback| {
            if (btn.style.enabled) {
                self.dispatch.onClick(callback);
            }
        }

        self.dispatch.popNode();
    }

    fn renderButtonHandler(self: *Self, btn: ButtonHandler) void {
        // Use explicit ID if provided, otherwise derive from label
        const layout_id = if (btn.id) |id| LayoutId.fromString(id) else LayoutId.fromString(btn.label);

        // Push dispatch node for this button
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Check hover state
        const is_hovered = btn.style.enabled and
            if (self.gooey) |g| g.isHovered(layout_id.id) else false;

        const bg = switch (btn.style.style) {
            .primary => if (!btn.style.enabled)
                Color.rgb(0.5, 0.7, 1.0)
            else if (is_hovered)
                Color.rgb(0.3, 0.6, 1.0) // Lighter on hover
            else
                Color.rgb(0.2, 0.5, 1.0),
            .secondary => if (is_hovered)
                Color.rgb(0.82, 0.82, 0.82) // Darker on hover
            else
                Color.rgb(0.9, 0.9, 0.9),
            .danger => if (is_hovered)
                Color.rgb(1.0, 0.4, 0.4) // Lighter on hover
            else
                Color.rgb(0.9, 0.3, 0.3),
        };
        const fg = switch (btn.style.style) {
            .primary, .danger => Color.white,
            .secondary => Color.rgb(0.3, 0.3, 0.3),
        };

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = Sizing.fitContent(),
                .padding = Padding.symmetric(24, 10),
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = bg,
            .corner_radius = CornerRadius.all(6),
        }) catch {
            self.dispatch.popNode();
            return;
        };

        self.layout.text(btn.label, .{
            .color = fg,
            .font_size = 14,
        }) catch {};

        self.layout.closeElement();

        // Register handler-based click handler
        if (btn.style.enabled) {
            self.dispatch.onClickHandler(btn.handler);
        }

        self.dispatch.popNode();
    }

    fn renderSvg(self: *Self, prim: SvgPrimitive) void {
        // Generate a unique layout ID for this SVG instance
        const layout_id = self.generateId();

        // Use layout engine's svg method - this creates the element AND
        // ensures the SVG command is emitted inline with other primitives
        // for correct z-ordering
        self.layout.svg(layout_id, prim.width, prim.height, .{
            .path = prim.path,
            .color = prim.color,
            .stroke_color = prim.stroke_color,
            .stroke_width = prim.stroke_width,
            .has_fill = prim.has_fill,
            .viewbox = prim.viewbox,
        }) catch return;
    }

    fn renderImage(self: *Self, prim: ImagePrimitive) void {
        // Generate a unique layout ID for this image instance
        const layout_id = self.generateId();

        // Convert fit enum to u8
        const fit_u8: u8 = switch (prim.fit) {
            .contain => 0,
            .cover => 1,
            .fill => 2,
            .none => 3,
            .scale_down => 4,
        };

        // Convert corner radius to layout type if present
        const corner_rad: ?CornerRadius = if (prim.corner_radius) |cr|
            cr
        else
            null;

        // Use layout engine's image method - this creates the element AND
        // ensures the image command is emitted inline with other primitives
        // for correct z-ordering
        self.layout.image(layout_id, prim.width, prim.height, .{
            .source = prim.source,
            .width = prim.width,
            .height = prim.height,
            .fit = fit_u8,
            .corner_radius = corner_rad,
            .tint = prim.tint,
            .grayscale = prim.grayscale,
            .opacity = prim.opacity,
        }) catch return;
    }

    fn renderActionHandlerRef(self: *Self, ah: ActionHandlerRefPrimitive) void {
        self.dispatch.onActionHandlerRaw(ah.action_type, ah.handler);
    }

    fn renderKeyContext(self: *Self, ctx: KeyContextPrimitive) void {
        self.dispatch.setKeyContext(ctx.context);
    }

    fn renderActionHandler(self: *Self, handler: ActionHandlerPrimitive) void {
        const node_id = self.dispatch.currentNode();
        if (self.dispatch.getNode(node_id)) |node| {
            node.action_listeners.append(self.allocator, .{
                .action_type = handler.action_type,
                .callback = handler.callback,
            }) catch {};
        }
    }

    // =========================================================================
    // Internal: ID Generation
    // =========================================================================

    fn generateId(self: *Self) LayoutId {
        self.id_counter += 1;
        return LayoutId.fromInt(self.id_counter);
    }
};
