//! UI Primitives
//!
//! Low-level primitive types for the UI system: Text, Input, Spacer, Empty, etc.
//! These are the building blocks that get rendered by the Builder.

const std = @import("std");

// Import styles
const styles = @import("styles.zig");
pub const Color = styles.Color;
pub const TextStyle = styles.TextStyle;
pub const InputStyle = styles.InputStyle;
pub const TextAreaStyle = styles.TextAreaStyle;
pub const CodeEditorStyle = styles.CodeEditorStyle;
pub const ButtonStyle = styles.ButtonStyle;
pub const CornerRadius = styles.CornerRadius;
pub const ObjectFit = styles.ObjectFit;
pub const HandlerRef = styles.HandlerRef;

// Action system
const action_mod = @import("../input/actions.zig");
const actionTypeId = action_mod.actionTypeId;

// =============================================================================
// Primitive Type Enum
// =============================================================================

pub const PrimitiveType = enum {
    text,
    text_area,
    code_editor,
    input,
    spacer,
    button,
    button_handler,
    empty,
    key_context,
    action_handler,
    action_handler_ref,
    svg,
    image,
    // Container elements
    box_element,
    hstack,
    vstack,
    scroll,
};

// =============================================================================
// Text Primitives
// =============================================================================

/// Text element descriptor
pub const Text = struct {
    content: []const u8,
    style: TextStyle,

    pub const primitive_type: PrimitiveType = .text;
};

/// Create a text element
pub fn text(content: []const u8, style: TextStyle) Text {
    return .{ .content = content, .style = style };
}

/// Rotating buffer pool for textFmt (allows multiple calls per frame)
var fmt_buffers: [16][256]u8 = undefined;
var fmt_buffer_index: usize = 0;

/// Create a formatted text element
pub fn textFmt(comptime fmt: []const u8, args: anytype, style: TextStyle) Text {
    const buffer = &fmt_buffers[fmt_buffer_index];
    fmt_buffer_index = (fmt_buffer_index + 1) % fmt_buffers.len;
    const result = std.fmt.bufPrint(buffer, fmt, args) catch "...";
    return .{ .content = result, .style = style };
}

// =============================================================================
// Input Primitives
// =============================================================================

/// Input field descriptor
pub const Input = struct {
    id: []const u8,
    style: InputStyle,

    pub const primitive_type: PrimitiveType = .input;
};

/// Create a text input element
pub fn input(id: []const u8, style: InputStyle) Input {
    return .{ .id = id, .style = style };
}

/// Text area descriptor
pub const TextAreaPrimitive = struct {
    id: []const u8,
    style: TextAreaStyle,

    pub const primitive_type: PrimitiveType = .text_area;
};

/// Create a text area element
pub fn textArea(id: []const u8, style: TextAreaStyle) TextAreaPrimitive {
    return .{ .id = id, .style = style };
}

// =============================================================================
// Code Editor Primitive
// =============================================================================

/// Code editor element descriptor (line numbers, syntax highlighting)
pub const CodeEditorPrimitive = struct {
    id: []const u8,
    style: CodeEditorStyle,

    pub const primitive_type: PrimitiveType = .code_editor;
};

/// Create a code editor element
pub fn codeEditor(id: []const u8, style: CodeEditorStyle) CodeEditorPrimitive {
    return .{ .id = id, .style = style };
}

// =============================================================================
// Button Primitives
// =============================================================================

/// Button element descriptor
pub const Button = struct {
    id: ?[]const u8 = null, // Override ID (defaults to label hash)
    label: []const u8,
    style: ButtonStyle = .{},
    on_click: ?*const fn () void = null,

    pub const primitive_type: PrimitiveType = .button;
};

/// Button with HandlerRef (new pattern with context access)
pub const ButtonHandler = struct {
    id: ?[]const u8 = null, // Override ID (defaults to label hash)
    label: []const u8,
    style: ButtonStyle = .{},
    handler: HandlerRef,

    pub const primitive_type: PrimitiveType = .button_handler;
};

// =============================================================================
// Spacer Primitive
// =============================================================================

/// Spacer element descriptor
pub const Spacer = struct {
    min_size: f32 = 0,

    pub const primitive_type: PrimitiveType = .spacer;
};

/// Create a flexible spacer
pub fn spacer() Spacer {
    return .{};
}

/// Create a spacer with minimum size
pub fn spacerMin(min_size: f32) Spacer {
    return .{ .min_size = min_size };
}

// =============================================================================
// Empty Primitive
// =============================================================================

/// Empty element (renders nothing) - for conditionals
pub const Empty = struct {
    pub const primitive_type: PrimitiveType = .empty;
};

/// Create an empty element (for conditionals)
pub fn empty() Empty {
    return .{};
}

// =============================================================================
// SVG Primitive
// =============================================================================

/// SVG element descriptor - renders a pre-loaded SVG mesh
pub const SvgPrimitive = struct {
    path: []const u8 = "",
    /// Mesh ID (from svg_mesh.meshId())
    mesh_id: u64 = 0,
    /// Width of the SVG element
    width: f32 = 24,
    /// Height of the SVG element
    height: f32 = 24,
    /// Fill color
    color: Color = Color.black,
    /// Stroke color (null = no stroke)
    stroke_color: ?Color = null,
    /// Stroke width in logical pixels
    stroke_width: f32 = 1.0,
    /// Whether to fill the path
    has_fill: bool = true,
    /// Source viewbox size (for proper scaling)
    viewbox: f32 = 24,

    pub const primitive_type: PrimitiveType = .svg;
};

/// Create an SVG element with the given size and color
pub fn svg(mesh_id: u64, width: f32, height: f32, color: Color) SvgPrimitive {
    return .{ .mesh_id = mesh_id, .width = width, .height = height, .color = color };
}

/// Create an SVG icon with viewbox support
pub fn svgIcon(mesh_id: u64, width: f32, height: f32, color: Color, viewbox: f32) SvgPrimitive {
    return .{
        .mesh_id = mesh_id,
        .width = width,
        .height = height,
        .color = color,
        .viewbox = viewbox,
    };
}

// =============================================================================
// Image Primitive
// =============================================================================

/// Image element descriptor - renders an image from atlas
pub const ImagePrimitive = struct {
    /// Image source path (file path or embedded asset)
    source: []const u8,

    /// Explicit width (null = intrinsic)
    width: ?f32 = null,
    /// Explicit height (null = intrinsic)
    height: ?f32 = null,

    /// Object fit mode (imported from image/atlas.zig)
    fit: ObjectFit = .contain,

    /// Corner radius for rounded images
    corner_radius: ?CornerRadius = null,

    /// Tint color (multiplied with image)
    tint: ?Color = null,

    /// Grayscale effect (0-1)
    grayscale: f32 = 0,

    /// Opacity (0-1)
    opacity: f32 = 1,

    pub const primitive_type: PrimitiveType = .image;
};

// =============================================================================
// Action/Context Primitives
// =============================================================================

/// Key context descriptor - sets dispatch context when rendered
pub const KeyContextPrimitive = struct {
    context: []const u8,
    pub const primitive_type: PrimitiveType = .key_context;
};

/// Set key context for dispatch (use inside box children)
pub fn keyContext(context: []const u8) KeyContextPrimitive {
    return .{ .context = context };
}

/// Action handler descriptor - registers action handler when rendered
pub const ActionHandlerPrimitive = struct {
    action_type: usize, // ActionTypeId
    callback: *const fn () void,
    pub const primitive_type: PrimitiveType = .action_handler;
};

/// Action handler with HandlerRef
pub const ActionHandlerRefPrimitive = struct {
    action_type: usize,
    handler: HandlerRef,
    pub const primitive_type: PrimitiveType = .action_handler_ref;
};

/// Register an action handler (use inside box children)
pub fn onAction(comptime Action: type, callback: *const fn () void) ActionHandlerPrimitive {
    return .{
        .action_type = actionTypeId(Action),
        .callback = callback,
    };
}

/// Register an action handler using HandlerRef (new pattern)
pub fn onActionHandler(comptime Action: type, ref: HandlerRef) ActionHandlerRefPrimitive {
    return .{
        .action_type = actionTypeId(Action),
        .handler = ref,
    };
}

// =============================================================================
// Conditional Rendering
// =============================================================================

/// Conditional rendering - returns a struct that renders children only if condition is true
pub fn when(condition: bool, children: anytype) When(@TypeOf(children)) {
    return .{ .condition = condition, .children = children };
}

/// Conditional wrapper type
pub fn When(comptime ChildrenType: type) type {
    return struct {
        condition: bool,
        children: ChildrenType,

        const Builder = @import("builder.zig").Builder;

        pub fn render(self: @This(), b: *Builder) void {
            if (self.condition) {
                b.processChildren(self.children);
            }
        }
    };
}

/// Render with value if optional is non-null
pub fn maybe(optional: anytype, comptime render_fn: anytype) Maybe(@TypeOf(optional), render_fn) {
    return .{ .optional = optional };
}

/// Maybe wrapper type - renders content if optional has a value
pub fn Maybe(comptime OptionalType: type, comptime render_fn: anytype) type {
    return struct {
        optional: OptionalType,

        const Builder = @import("builder.zig").Builder;

        pub fn render(self: @This(), b: *Builder) void {
            if (self.optional) |value| {
                const result = render_fn(value);
                b.processChildren(result);
            }
        }
    };
}

/// Render for each item in a slice
pub fn each(items: anytype, comptime render_fn: anytype) Each(@TypeOf(items), render_fn) {
    return .{ .items = items };
}

/// Each wrapper type - renders content for each item in a slice
pub fn Each(comptime ItemsType: type, comptime render_fn: anytype) type {
    return struct {
        items: ItemsType,

        const Builder = @import("builder.zig").Builder;

        pub fn render(self: @This(), b: *Builder) void {
            for (self.items, 0..) |item, index| {
                const result = render_fn(item, index);
                b.processChildren(result);
            }
        }
    };
}

// =============================================================================
// Container Elements (Phase 1: cx/ui separation)
// =============================================================================

/// Box element descriptor - returns a struct that can be rendered via cx.render()
pub fn BoxElement(comptime ChildrenType: type, comptime tracked: bool) type {
    return struct {
        style: styles.Box,
        children: ChildrenType,
        source_loc: if (tracked) std.builtin.SourceLocation else void,

        pub const primitive_type: PrimitiveType = .box_element;

        const Builder = @import("builder.zig").Builder;

        pub fn render(self: @This(), b: *Builder) void {
            if (tracked) {
                b.boxTracked(self.style, self.children, self.source_loc);
            } else {
                b.box(self.style, self.children);
            }
        }
    };
}

/// Create a box element (returns struct for cx.render())
pub fn box(style: styles.Box, children: anytype) BoxElement(@TypeOf(children), false) {
    return .{ .style = style, .children = children, .source_loc = {} };
}

/// Create a box element with source location tracking (returns struct for cx.render())
/// Usage: ui.boxTracked(.{ ... }, .{ ... }, @src())
pub fn boxTracked(style: styles.Box, children: anytype, src: std.builtin.SourceLocation) BoxElement(@TypeOf(children), true) {
    return .{ .style = style, .children = children, .source_loc = src };
}

/// HStack element descriptor - horizontal stack that returns a struct
pub fn HStackElement(comptime ChildrenType: type, comptime tracked: bool) type {
    return struct {
        style: styles.StackStyle,
        children: ChildrenType,
        source_loc: if (tracked) std.builtin.SourceLocation else void,

        pub const primitive_type: PrimitiveType = .hstack;

        const Builder = @import("builder.zig").Builder;

        pub fn render(self: @This(), b: *Builder) void {
            if (tracked) {
                b.hstackTracked(self.style, self.children, self.source_loc);
            } else {
                b.hstack(self.style, self.children);
            }
        }
    };
}

/// Create an hstack element (returns struct for cx.render())
pub fn hstack(style: styles.StackStyle, children: anytype) HStackElement(@TypeOf(children), false) {
    return .{ .style = style, .children = children, .source_loc = {} };
}

/// Create an hstack element with source location tracking (returns struct for cx.render())
/// Usage: ui.hstackTracked(.{ ... }, .{ ... }, @src())
pub fn hstackTracked(style: styles.StackStyle, children: anytype, src: std.builtin.SourceLocation) HStackElement(@TypeOf(children), true) {
    return .{ .style = style, .children = children, .source_loc = src };
}

/// VStack element descriptor - vertical stack that returns a struct
pub fn VStackElement(comptime ChildrenType: type, comptime tracked: bool) type {
    return struct {
        style: styles.StackStyle,
        children: ChildrenType,
        source_loc: if (tracked) std.builtin.SourceLocation else void,

        pub const primitive_type: PrimitiveType = .vstack;

        const Builder = @import("builder.zig").Builder;

        pub fn render(self: @This(), b: *Builder) void {
            if (tracked) {
                b.vstackTracked(self.style, self.children, self.source_loc);
            } else {
                b.vstack(self.style, self.children);
            }
        }
    };
}

/// Create a vstack element (returns struct for cx.render())
pub fn vstack(style: styles.StackStyle, children: anytype) VStackElement(@TypeOf(children), false) {
    return .{ .style = style, .children = children, .source_loc = {} };
}

/// Create a vstack element with source location tracking (returns struct for cx.render())
/// Usage: ui.vstackTracked(.{ ... }, .{ ... }, @src())
pub fn vstackTracked(style: styles.StackStyle, children: anytype, src: std.builtin.SourceLocation) VStackElement(@TypeOf(children), true) {
    return .{ .style = style, .children = children, .source_loc = src };
}

/// Scroll element descriptor - scrollable container that returns a struct
pub fn ScrollElement(comptime ChildrenType: type, comptime tracked: bool) type {
    return struct {
        id: []const u8,
        style: styles.ScrollStyle,
        children: ChildrenType,
        source_loc: if (tracked) std.builtin.SourceLocation else void,

        pub const primitive_type: PrimitiveType = .scroll;

        const Builder = @import("builder.zig").Builder;

        pub fn render(self: @This(), b: *Builder) void {
            // scroll always uses ID, no tracked variant in builder
            _ = self.source_loc;
            b.scroll(self.id, self.style, self.children);
        }
    };
}

/// Create a scroll element (returns struct for cx.render())
/// Usage: ui.scroll("my-scroll", .{ .height = 300, .content_height = 600 }, .{ children })
pub fn scroll(id: []const u8, style: styles.ScrollStyle, children: anytype) ScrollElement(@TypeOf(children), false) {
    return .{ .id = id, .style = style, .children = children, .source_loc = {} };
}

/// Create a scroll element with source location tracking (returns struct for cx.render())
/// Usage: ui.scrollTracked("my-scroll", .{ ... }, .{ ... }, @src())
pub fn scrollTracked(id: []const u8, style: styles.ScrollStyle, children: anytype, src: std.builtin.SourceLocation) ScrollElement(@TypeOf(children), true) {
    return .{ .id = id, .style = style, .children = children, .source_loc = src };
}

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

test "empty primitive" {
    const e = empty();
    try std.testing.expectEqual(PrimitiveType.empty, @TypeOf(e).primitive_type);
}

test "box element primitive" {
    const b = box(.{ .width = 100, .height = 50 }, .{});
    try std.testing.expectEqual(PrimitiveType.box_element, @TypeOf(b).primitive_type);
    try std.testing.expectEqual(@as(?f32, 100), b.style.width);
    try std.testing.expectEqual(@as(?f32, 50), b.style.height);
}

test "hstack element primitive" {
    const h = hstack(.{ .gap = 8 }, .{});
    try std.testing.expectEqual(PrimitiveType.hstack, @TypeOf(h).primitive_type);
    try std.testing.expectEqual(@as(f32, 8), h.style.gap);
}

test "vstack element primitive" {
    const v = vstack(.{ .gap = 12, .alignment = .center }, .{});
    try std.testing.expectEqual(PrimitiveType.vstack, @TypeOf(v).primitive_type);
    try std.testing.expectEqual(@as(f32, 12), v.style.gap);
    try std.testing.expectEqual(styles.StackStyle.Alignment.center, v.style.alignment);
}

test "scroll element primitive" {
    const s = scroll("my-scroll", .{ .height = 300, .content_height = 600 }, .{});
    try std.testing.expectEqual(PrimitiveType.scroll, @TypeOf(s).primitive_type);
    try std.testing.expectEqualStrings("my-scroll", s.id);
    try std.testing.expectEqual(@as(?f32, 300), s.style.height);
    try std.testing.expectEqual(@as(?f32, 600), s.style.content_height);
}

test "scroll element with children" {
    const s = scroll("scroll-with-children", .{ .height = 200, .gap = 8 }, .{
        text("Item 1", .{}),
        text("Item 2", .{}),
        text("Item 3", .{}),
    });
    try std.testing.expectEqual(PrimitiveType.scroll, @TypeOf(s).primitive_type);
    try std.testing.expectEqualStrings("scroll-with-children", s.id);
    try std.testing.expectEqual(@as(usize, 3), s.children.len);
}

test "nested container elements" {
    // Verify nested containers compile and have correct structure
    const nested = box(.{ .width = 200 }, .{
        hstack(.{ .gap = 8 }, .{
            text("A", .{}),
            text("B", .{}),
        }),
        vstack(.{ .gap = 4 }, .{
            text("C", .{}),
            spacer(),
        }),
    });

    try std.testing.expectEqual(PrimitiveType.box_element, @TypeOf(nested).primitive_type);
    try std.testing.expectEqual(@as(?f32, 200), nested.style.width);

    // Children tuple has 2 elements
    try std.testing.expectEqual(@as(usize, 2), nested.children.len);
}

test "box with all style options" {
    const b = box(.{
        .width = 100,
        .height = 50,
        .padding = .{ .all = 16 },
        .gap = 8,
        .background = Color.white,
        .corner_radius = 4,
        .direction = .row,
        .alignment = .{ .main = .center, .cross = .center },
    }, .{});

    try std.testing.expectEqual(@as(?f32, 100), b.style.width);
    try std.testing.expectEqual(@as(?f32, 50), b.style.height);
    try std.testing.expectEqual(@as(f32, 8), b.style.gap);
    try std.testing.expectEqual(@as(f32, 4), b.style.corner_radius);
    try std.testing.expectEqual(styles.Box.Direction.row, b.style.direction);
}

test "container with conditional children" {
    const show = true;
    const container = vstack(.{ .gap = 8 }, .{
        text("Always visible", .{}),
        when(show, .{text("Conditional", .{})}),
    });

    try std.testing.expectEqual(PrimitiveType.vstack, @TypeOf(container).primitive_type);
    try std.testing.expectEqual(@as(usize, 2), container.children.len);
}

test "boxTracked with source location" {
    const src = @src();
    const b = boxTracked(.{ .width = 100 }, .{}, src);
    try std.testing.expectEqual(PrimitiveType.box_element, @TypeOf(b).primitive_type);
    try std.testing.expectEqual(@as(?f32, 100), b.style.width);
    try std.testing.expectEqualStrings("primitives.zig", b.source_loc.file[b.source_loc.file.len - 14 ..]);
}

test "hstackTracked with source location" {
    const src = @src();
    const h = hstackTracked(.{ .gap = 16 }, .{}, src);
    try std.testing.expectEqual(PrimitiveType.hstack, @TypeOf(h).primitive_type);
    try std.testing.expectEqual(@as(f32, 16), h.style.gap);
    try std.testing.expectEqualStrings("primitives.zig", h.source_loc.file[h.source_loc.file.len - 14 ..]);
}

test "vstackTracked with source location" {
    const src = @src();
    const v = vstackTracked(.{ .gap = 24, .alignment = .end }, .{}, src);
    try std.testing.expectEqual(PrimitiveType.vstack, @TypeOf(v).primitive_type);
    try std.testing.expectEqual(@as(f32, 24), v.style.gap);
    try std.testing.expectEqual(styles.StackStyle.Alignment.end, v.style.alignment);
    try std.testing.expectEqualStrings("primitives.zig", v.source_loc.file[v.source_loc.file.len - 14 ..]);
}

test "scrollTracked with source location" {
    const src = @src();
    const s = scrollTracked("tracked-scroll", .{ .height = 400 }, .{}, src);
    try std.testing.expectEqual(PrimitiveType.scroll, @TypeOf(s).primitive_type);
    try std.testing.expectEqualStrings("tracked-scroll", s.id);
    try std.testing.expectEqual(@as(?f32, 400), s.style.height);
    try std.testing.expectEqualStrings("primitives.zig", s.source_loc.file[s.source_loc.file.len - 14 ..]);
}

test "maybe primitive with value" {
    const opt: ?i32 = 42;
    const m = maybe(opt, struct {
        fn render(value: i32) Text {
            _ = value;
            return text("Has value", .{});
        }
    }.render);

    // Verify the maybe struct was created
    try std.testing.expect(m.optional != null);
    try std.testing.expectEqual(@as(i32, 42), m.optional.?);
}

test "maybe primitive with null" {
    const opt: ?i32 = null;
    const m = maybe(opt, struct {
        fn render(value: i32) Text {
            _ = value;
            return text("Has value", .{});
        }
    }.render);

    // Verify the maybe struct was created with null
    try std.testing.expect(m.optional == null);
}

test "each primitive" {
    const items = [_]i32{ 1, 2, 3 };
    const e = each(&items, struct {
        fn render(item: i32, index: usize) Text {
            _ = item;
            _ = index;
            return text("Item", .{});
        }
    }.render);

    // Verify the each struct was created with the items
    try std.testing.expectEqual(@as(usize, 3), e.items.len);
}

test "each primitive in container" {
    const items = [_][]const u8{ "A", "B", "C" };
    const container = vstack(.{ .gap = 4 }, .{
        each(&items, struct {
            fn render(item: []const u8, _: usize) Text {
                return text(item, .{});
            }
        }.render),
    });

    try std.testing.expectEqual(PrimitiveType.vstack, @TypeOf(container).primitive_type);
}
