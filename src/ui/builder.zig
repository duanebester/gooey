//! UI Builder
//!
//! The Builder struct is the core of the declarative UI system.
//! It provides methods for creating layouts, rendering primitives,
//! and managing component context.

const std = @import("std");

// Core imports
const dispatch_mod = @import("../core/dispatch.zig");
const DispatchTree = dispatch_mod.DispatchTree;
const DispatchNodeId = dispatch_mod.DispatchNodeId;
const focus_mod = @import("../core/focus.zig");
const FocusId = focus_mod.FocusId;
const FocusHandle = focus_mod.FocusHandle;
const action_mod = @import("../core/action.zig");
const actionTypeId = action_mod.actionTypeId;
const handler_mod = @import("../core/handler.zig");
const entity_mod = @import("../core/entity.zig");
const gooey_mod = @import("../core/gooey.zig");
pub const HandlerRef = handler_mod.HandlerRef;
pub const EntityId = entity_mod.EntityId;
pub const Gooey = gooey_mod.Gooey;

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
const scene_mod = @import("../core/scene.zig");
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

/// Get a unique type ID for context type checking
fn contextTypeId(comptime T: type) usize {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

/// The UI builder context passed to component render() methods
pub const Builder = struct {
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

    const PendingScroll = struct {
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
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_inputs.deinit(self.allocator);
        self.pending_text_areas.deinit(self.allocator);
        self.pending_scrolls.deinit(self.allocator);
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
        var scroll_offset_y: f32 = 0;
        if (self.gooey) |g| {
            if (g.widgets.scrollContainer(id)) |sc| {
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

        // Outer container (the viewport)
        const viewport_width = style.width orelse 300;
        const viewport_height = style.height orelse 200;

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(viewport_width),
                    .height = SizingAxis.fixed(viewport_height),
                },
                .padding = padding,
            },
            .background_color = style.background,
            .corner_radius = if (style.corner_radius > 0) CornerRadius.all(style.corner_radius) else .{},
            .scroll = .{
                .vertical = style.vertical,
                .horizontal = style.horizontal,
                .scroll_offset = .{ .x = 0, .y = scroll_offset_y },
            },
        }) catch return;

        // Inner content container (can be taller than viewport)
        const content_id = self.generateId();
        self.layout.openElement(.{
            .id = content_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.grow(),
                    .height = if (style.content_height) |h| SizingAxis.fixed(h) else SizingAxis.fit(),
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
        self.pending_scrolls.append(self.allocator, .{
            .id = id,
            .layout_id = layout_id,
            .style = style,
            .content_layout_id = content_id,
        }) catch {};
    }

    /// Register scroll container regions and update state
    pub fn registerPendingScrollRegions(self: *Self) void {
        for (self.pending_scrolls.items) |pending| {
            const viewport_bounds = self.layout.getBoundingBox(pending.layout_id.id);
            const content_bounds = self.layout.getBoundingBox(pending.content_layout_id.id);

            if (viewport_bounds != null and content_bounds != null) {
                const vp = viewport_bounds.?;
                const ct = content_bounds.?;

                if (self.gooey) |g| {
                    if (g.widgets.scrollContainer(pending.id)) |sc| {
                        // Update bounds
                        sc.bounds = .{
                            .x = vp.x,
                            .y = vp.y,
                            .width = vp.width,
                            .height = vp.height,
                        };

                        // Update viewport and content sizes
                        sc.setViewport(vp.width, vp.height);
                        sc.setContentSize(ct.width, ct.height);

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
