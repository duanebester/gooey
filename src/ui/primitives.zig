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
pub const ButtonStyle = styles.ButtonStyle;
pub const CornerRadius = styles.CornerRadius;
pub const ObjectFit = styles.ObjectFit;
pub const HandlerRef = styles.HandlerRef;

// Action system
const action_mod = @import("../core/action.zig");
const actionTypeId = action_mod.actionTypeId;

// =============================================================================
// Primitive Type Enum
// =============================================================================

pub const PrimitiveType = enum {
    text,
    text_area,
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
