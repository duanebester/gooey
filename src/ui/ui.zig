//! UI Builder - Component-based declarative UI
//!
//! This module provides a clean, composable API for building UIs.
//! Components are structs with a `render` method. Children are tuples.
//!
//! Example:
//! ```zig
//! const ui = @import("ui");
//!
//! fn build(b: *ui.Builder) void {
//!     b.vstack(.{ .gap = 16 }, .{
//!         ui.text("Hello", .{ .size = 24 }),
//!         MyButton{ .label = "Click me", .on_click = doSomething },
//!     });
//! }
//! ```

const std = @import("std");

// Import from gooey core
const layout_mod = @import("../layout/layout.zig");
const LayoutEngine = layout_mod.LayoutEngine;
const LayoutId = layout_mod.LayoutId;
const Sizing = layout_mod.Sizing;
const SizingAxis = layout_mod.SizingAxis;
const Padding = layout_mod.Padding;
const CornerRadius = layout_mod.CornerRadius;
// const ShadowConfig = layout_mod.ShadowConfig;
const ChildAlignment = layout_mod.ChildAlignment;
const LayoutDirection = layout_mod.LayoutDirection;
const LayoutConfig = layout_mod.LayoutConfig;
const ElementDeclaration = layout_mod.ElementDeclaration;
const TextConfig = layout_mod.TextConfig;
const RenderCommand = layout_mod.RenderCommand;
const BoundingBox = layout_mod.BoundingBox;

const scene_mod = @import("../core/scene.zig");
const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;

const gooey_mod = @import("../core/gooey.zig");
const Gooey = gooey_mod.Gooey;

// Re-export for convenience
pub const Color = @import("../layout/types.zig").Color;
pub const ShadowConfig = @import("../layout/types.zig").ShadowConfig;

// =============================================================================
// Hit Region for Click Handling
// =============================================================================

pub const HitRegion = struct {
    bounds: BoundingBox,
    on_click: ?*const fn () void,
    id: u32,
};

/// Hit region for input focus handling
pub const InputHitRegion = struct {
    bounds: BoundingBox,
    id: []const u8,
};

// =============================================================================
// Style Types
// =============================================================================

/// Text styling options
pub const TextStyle = struct {
    size: u16 = 14,
    color: Color = Color.black,
    weight: Weight = .regular,
    italic: bool = false,

    pub const Weight = enum { thin, light, regular, medium, semibold, bold, black };
};

/// Box styling options
pub const BoxStyle = struct {
    // Sizing
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
    grow: bool = false,
    fill_width: bool = false, // 100% of parent width
    fill_height: bool = false, // 100% of parent height

    // Spacing
    padding: PaddingValue = .{ .all = 0 },
    gap: f32 = 0,

    // Appearance
    background: Color = Color.transparent,
    corner_radius: f32 = 0,
    border_color: Color = Color.transparent,
    border_width: f32 = 0,

    shadow: ?ShadowConfig = null,

    // Layout
    direction: Direction = .column,
    alignment: Alignment = .{ .main = .start, .cross = .start },

    pub const Direction = enum { row, column };

    pub const Alignment = struct {
        main: MainAxis = .start,
        cross: CrossAxis = .start,

        pub const MainAxis = enum { start, center, end, space_between, space_around };
        pub const CrossAxis = enum { start, center, end, stretch };
    };

    pub const PaddingValue = union(enum) {
        all: f32,
        symmetric: struct { x: f32, y: f32 },
        each: struct { top: f32, right: f32, bottom: f32, left: f32 },
    };

    /// Convert to layout Padding
    pub fn toPadding(self: BoxStyle) Padding {
        return switch (self.padding) {
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
};

/// Input field options
pub const InputStyle = struct {
    placeholder: []const u8 = "",
    secure: bool = false,
    font_size: u16 = 14,
    width: ?f32 = null,
    height: f32 = 36,
    /// Two-way binding to a string slice pointer
    bind: ?*[]const u8 = null,
};

/// Stack layout options
pub const StackStyle = struct {
    gap: f32 = 0,
    alignment: Alignment = .start,
    padding: f32 = 0,

    pub const Alignment = enum { start, center, end, stretch };
};

/// Center container options
pub const CenterStyle = struct {
    padding: f32 = 0,
};

/// Button styling options
pub const ButtonStyle = struct {
    style: Style = .primary,
    enabled: bool = true,

    pub const Style = enum { primary, secondary, danger };
};

// =============================================================================
// Primitive Descriptors
// =============================================================================

pub const PrimitiveType = enum { text, input, spacer, button, empty };

/// Text element descriptor
pub const Text = struct {
    content: []const u8,
    style: TextStyle,

    pub const primitive_type: PrimitiveType = .text;
};

/// Input field descriptor
pub const Input = struct {
    id: []const u8,
    style: InputStyle,

    pub const primitive_type: PrimitiveType = .input;
};

/// Spacer element descriptor
pub const Spacer = struct {
    min_size: f32 = 0,

    pub const primitive_type: PrimitiveType = .spacer;
};

/// Button element descriptor
pub const Button = struct {
    label: []const u8,
    style: ButtonStyle = .{},
    on_click: ?*const fn () void = null,

    pub const primitive_type: PrimitiveType = .button;
};

/// Empty element (renders nothing) - for conditionals
pub const Empty = struct {
    pub const primitive_type: PrimitiveType = .empty;
};

// =============================================================================
// Free Functions (return descriptors)
// =============================================================================

/// Create a text element
pub fn text(content: []const u8, style: TextStyle) Text {
    return .{ .content = content, .style = style };
}

/// Create a text input element
pub fn input(id: []const u8, style: InputStyle) Input {
    return .{ .id = id, .style = style };
}

/// Create a flexible spacer
pub fn spacer() Spacer {
    return .{};
}

/// Create a spacer with minimum size
pub fn spacerMin(min_size: f32) Spacer {
    return .{ .min_size = min_size };
}

/// Create a button
pub fn button(label: []const u8, on_click: ?*const fn () void) Button {
    return .{ .label = label, .on_click = on_click };
}

/// Create a styled button
pub fn buttonStyled(label: []const u8, style: ButtonStyle, on_click: ?*const fn () void) Button {
    return .{ .label = label, .style = style, .on_click = on_click };
}

/// Create an empty element (for conditionals)
pub fn empty() Empty {
    return .{};
}

/// Buffer for textFmt (thread-local static)
var fmt_buffer: [1024]u8 = undefined;

/// Create a text element with printf-style formatting
/// Note: Uses a static buffer, so the result is only valid until the next call
pub fn textFmt(comptime fmt: []const u8, args: anytype, style: TextStyle) Text {
    const result = std.fmt.bufPrint(&fmt_buffer, fmt, args) catch "...";
    return .{ .content = result, .style = style };
}

// =============================================================================
// UI Builder
// =============================================================================

/// The UI builder context passed to component render() methods
pub const Builder = struct {
    allocator: std.mem.Allocator,
    layout: *LayoutEngine,
    scene: *Scene,
    gooey: ?*Gooey = null,
    id_counter: u32 = 0,

    /// Hit regions for click detection (populated after layout)
    hit_regions: std.ArrayList(HitRegion),

    /// Pending input IDs to be rendered (collected during layout, rendered after)
    pending_inputs: std.ArrayList(PendingInput),

    /// Pending buttons for click registration (collected during layout, registered after)
    pending_buttons: std.ArrayList(PendingButton),

    /// Input hit regions for focus handling (populated after layout)
    input_regions: std.ArrayList(InputHitRegion),

    const PendingInput = struct {
        id: []const u8,
        layout_id: LayoutId,
        style: InputStyle,
    };

    const PendingButton = struct {
        layout_id: LayoutId,
        on_click: *const fn () void,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, layout_engine: *LayoutEngine, scene_ptr: *Scene) Self {
        return .{
            .allocator = allocator,
            .layout = layout_engine,
            .scene = scene_ptr,
            .hit_regions = .{},
            .pending_inputs = .{},
            .pending_buttons = .{},
            .input_regions = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.hit_regions.deinit(self.allocator);
        self.pending_inputs.deinit(self.allocator);
        self.pending_buttons.deinit(self.allocator);
        self.input_regions.deinit(self.allocator);
    }

    // =========================================================================
    // Click Handling
    // =========================================================================

    /// Register a clickable region
    pub fn registerClickRegion(self: *Self, bounds: BoundingBox, on_click: ?*const fn () void) void {
        self.hit_regions.append(self.allocator, .{
            .bounds = bounds,
            .on_click = on_click,
            .id = self.id_counter,
        }) catch {};
    }

    /// Check if a point hits any registered region and call its callback
    /// Returns true if a click was handled
    pub fn handleClick(self: *Self, x: f32, y: f32) bool {
        // First check buttons (iterate in reverse order - last rendered = on top)
        var i = self.hit_regions.items.len;
        while (i > 0) {
            i -= 1;
            const region = self.hit_regions.items[i];
            if (x >= region.bounds.x and x <= region.bounds.x + region.bounds.width and
                y >= region.bounds.y and y <= region.bounds.y + region.bounds.height)
            {
                if (region.on_click) |callback| {
                    callback();
                    return true;
                }
            }
        }

        // Then check input fields for focus
        for (self.input_regions.items) |region| {
            if (x >= region.bounds.x and x <= region.bounds.x + region.bounds.width and
                y >= region.bounds.y and y <= region.bounds.y + region.bounds.height)
            {
                if (self.gooey) |g| {
                    g.focusTextInput(region.id);
                    return true;
                }
            }
        }

        return false;
    }

    // =========================================================================
    // Container Methods
    // =========================================================================

    /// Generic box container with children
    pub fn box(self: *Self, style: BoxStyle, children: anytype) void {
        self.boxWithId(null, style, children);
    }

    /// Box with explicit ID
    pub fn boxWithId(self: *Self, id: ?[]const u8, style: BoxStyle, children: anytype) void {
        const layout_id = if (id) |i| LayoutId.fromString(i) else self.generateId();

        var sizing = Sizing.fitContent();

        if (style.width) |w| {
            sizing.width = SizingAxis.fixed(w);
        } else if (style.fill_width) {
            sizing.width = SizingAxis.percent(1.0);
        } else if (style.grow) {
            sizing.width = SizingAxis.grow();
        }

        if (style.height) |h| {
            sizing.height = SizingAxis.fixed(h);
        } else if (style.fill_height) {
            sizing.height = SizingAxis.percent(1.0);
        } else if (style.grow) {
            sizing.height = SizingAxis.grow();
        }

        const direction: LayoutDirection = switch (style.direction) {
            .row => .left_to_right,
            .column => .top_to_bottom,
        };

        const child_alignment = ChildAlignment{
            .x = switch (style.alignment.cross) {
                .start => .left,
                .center => .center,
                .end => .right,
                .stretch => .left,
            },
            .y = switch (style.alignment.main) {
                .start => .top,
                .center => .center,
                .end => .bottom,
                .space_between, .space_around => .top,
            },
        };

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = sizing,
                .padding = style.toPadding(),
                .child_gap = @intFromFloat(style.gap),
                .child_alignment = child_alignment,
                .layout_direction = direction,
            },
            .background_color = style.background,
            .corner_radius = CornerRadius.all(style.corner_radius),
            .shadow = style.shadow,
        }) catch return;

        self.processChildren(children);

        self.layout.closeElement();
    }

    /// Vertical stack (column)
    pub fn vstack(self: *Self, style: StackStyle, children: anytype) void {
        self.box(.{
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
                .main = .start,
            },
        }, children);
    }

    /// Horizontal stack (row)
    pub fn hstack(self: *Self, style: StackStyle, children: anytype) void {
        self.box(.{
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
                .main = .start,
            },
        }, children);
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

    // =========================================================================
    // Internal: Child Processing
    // =========================================================================

    fn processChildren(self: *Self, children: anytype) void {
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
                .spacer => self.renderSpacer(child),
                .button => self.renderButton(child),
                .empty => {}, // Do nothing
            }
            return;
        }

        // Check for components
        if (@hasDecl(T, "render")) {
            child.render(self);
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
        }) catch return;
    }

    fn renderInput(self: *Self, inp: Input) void {
        const layout_id = LayoutId.fromString(inp.id);

        // Create placeholder in layout
        const input_width = inp.style.width orelse 200;
        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(input_width),
                    .height = SizingAxis.fixed(inp.style.height),
                },
            },
        }) catch return;
        self.layout.closeElement();

        // Store for later rendering
        self.pending_inputs.append(self.allocator, .{
            .id = inp.id,
            .layout_id = layout_id,
            .style = inp.style,
        }) catch {};

        // Set up the actual TextInput widget if we have access to Gooey
        if (self.gooey) |g| {
            if (g.textInput(inp.id)) |text_input| {
                if (inp.style.placeholder.len > 0) {
                    text_input.setPlaceholder(inp.style.placeholder);
                }

                // Two-way binding: sync TextInput content with bound variable
                if (inp.style.bind) |bind_ptr| {
                    const current_text = text_input.getText();
                    const bound_value = bind_ptr.*;

                    // Skip if they're the same pointer (would alias)
                    if (current_text.ptr == bound_value.ptr and current_text.len == bound_value.len) {
                        // Already in sync, nothing to do
                    } else if (!std.mem.eql(u8, current_text, bound_value)) {
                        // If bound variable changed externally, update TextInput
                        text_input.setText(bound_value) catch {};
                    }
                }
            }
        }
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
        const layout_id = self.generateId();

        const bg = switch (btn.style.style) {
            .primary => if (btn.style.enabled)
                Color.rgb(0.2, 0.5, 1.0)
            else
                Color.rgb(0.5, 0.7, 1.0),
            .secondary => Color.rgb(0.9, 0.9, 0.9),
            .danger => Color.rgb(0.9, 0.3, 0.3),
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
        }) catch return;

        self.layout.text(btn.label, .{
            .color = fg,
            .font_size = 14,
        }) catch {};

        self.layout.closeElement();

        // Store for deferred hit region registration (after layout computes bounds)
        if (btn.on_click) |callback| {
            if (btn.style.enabled) {
                self.pending_buttons.append(self.allocator, .{
                    .layout_id = layout_id,
                    .on_click = callback,
                }) catch {};
            }
        }
    }

    /// Register hit regions for all pending buttons (call after endFrame)
    pub fn registerPendingHitRegions(self: *Self) void {
        for (self.pending_buttons.items) |pending| {
            const bounds = self.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                self.hit_regions.append(self.allocator, .{
                    .bounds = b,
                    .on_click = pending.on_click,
                    .id = pending.layout_id.id,
                }) catch {};
            }
        }
    }

    /// Register input regions for focus handling (call after endFrame)
    pub fn registerPendingInputRegions(self: *Self) void {
        for (self.pending_inputs.items) |pending| {
            const bounds = self.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                self.input_regions.append(self.allocator, .{
                    .bounds = b,
                    .id = pending.id,
                }) catch {};
            }
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

// =============================================================================
// Tests
// =============================================================================

test "text primitive" {
    const t = text("Hello", .{ .size = 20 });
    try std.testing.expectEqualStrings("Hello", t.content);
    try std.testing.expectEqual(@as(u16, 20), t.style.size);
}

test "spacer primitive" {
    const s = spacer();
    try std.testing.expectEqual(@as(f32, 0), s.min_size);

    const s2 = spacerMin(50);
    try std.testing.expectEqual(@as(f32, 50), s2.min_size);
}

test "button primitive" {
    const b = button("Click", null);
    try std.testing.expectEqualStrings("Click", b.label);
}

test "empty primitive" {
    const e = empty();
    try std.testing.expectEqual(PrimitiveType.empty, @TypeOf(e).primitive_type);
}
