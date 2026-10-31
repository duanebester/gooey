//! Elements: `box`, `text`, and `paint` (contract §1).
//!
//! Elements are plain values built in a render function and consumed by
//! `Cx.render` in the same call. `Style` holds what can be shared (layout and
//! appearance); `Box` holds what is per element (key, handlers, focus, and
//! accessibility). Child dispatch lives in `cx.zig`.

const std = @import("std");
const id_mod = @import("id.zig");
const records = @import("records.zig");
const handler_mod = @import("handler.zig");
const layers = @import("layers.zig");
const geometry = @import("../geometry/geometry.zig");
const a11y_types = @import("../accessibility/types.zig");
const ui_theme = @import("../ui/theme.zig");

const assert = std.debug.assert;

pub const Key = id_mod.Key;
pub const Handler = handler_mod.Handler;
pub const Color = geometry.Color;
pub const Theme = ui_theme.Theme;
pub const Corners = records.Corners;
pub const Layer = layers.Layer;
pub const Role = a11y_types.Role;

pub const Direction = enum { row, column };
pub const Sizing = union(enum) { fit, grow: f32, fixed: f32, percent: f32 };

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub const zero: Edges = .{};

    pub fn all(value: f32) Edges {
        assert(value >= 0);
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn symmetric(horizontal: f32, vertical: f32) Edges {
        assert(horizontal >= 0);
        assert(vertical >= 0);
        return .{ .top = vertical, .right = horizontal, .bottom = vertical, .left = horizontal };
    }
};

/// Main-axis distribution and cross-axis placement of a box's children.
pub const Alignment = struct {
    main: Main = .start,
    cross: Cross = .start,

    pub const Main = enum { start, center, end, space_between, space_around, space_evenly };
    pub const Cross = enum { start, center, end };

    pub const start: Alignment = .{};
    pub const center: Alignment = .{ .main = .center, .cross = .center };
    pub const center_cross: Alignment = .{ .cross = .center };
};

/// A theme token or a literal colour. Tokens resolve against the app's
/// `Theme` when the element is built, so one style serves every theme.
pub const ColorToken = union(enum) {
    bg,
    surface,
    overlay,
    primary,
    secondary,
    accent,
    success,
    warning,
    danger,
    text,
    subtext,
    muted,
    border,
    border_focus,
    rgba: Color,

    pub fn literal(color: Color) ColorToken {
        return .{ .rgba = color };
    }

    pub fn resolve(self: ColorToken, theme: *const Theme) Color {
        return switch (self) {
            .rgba => |color| color,
            inline else => |_, tag| @field(theme, @tagName(tag)),
        };
    }
};

pub const Border = struct {
    width: f32 = 1,
    color: ColorToken = .border,
};

pub const Shadow = struct {
    blur: f32 = 0,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    color: ColorToken = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0.15 } },
};

pub const ClipPolicy = enum { none, clip };
pub const Scroll = struct { x: bool = false, y: bool = true };
pub const CursorShape = enum { default, pointer, text };
pub const PointerEvents = enum { auto, none };

/// Layout and appearance: plain data with no per-element arguments, so a
/// `Style` can be a shared constant, chosen per state, and compared.
pub const Style = struct {
    direction: Direction = .column,
    width: Sizing = .fit,
    height: Sizing = .fit,
    width_min: ?f32 = null,
    width_max: ?f32 = null,
    height_min: ?f32 = null,
    height_max: ?f32 = null,
    padding: Edges = .zero,
    gap: f32 = 0,
    alignment: Alignment = .start,
    background: ?ColorToken = null,
    border: ?Border = null,
    corner_radius: Corners = .zero,
    shadow: ?Shadow = null,
    opacity: f32 = 1,
    clip: ClipPolicy = .none,
    scroll: ?Scroll = null,
    cursor: ?CursorShape = null,
    pointer_events: PointerEvents = .auto,
};

/// A comptime-hashed key context name (contract §5). Keymaps arrive with the
/// router's keymap support in phase 4; milestone 1 rejects a set context.
pub const KeyContext = struct { hash: u64 };
pub const ActionBinding = struct { action: u64, handler: Handler };
pub const DragSource = struct { type_id: usize, payload: u64 };
pub const DropTarget = struct { type_id: usize, on_drop: Handler };

/// Accessibility annotation. Strings are copied when the box is built.
pub const A11y = struct {
    role: Role,
    label: ?[]const u8 = null,
    value: ?[]const u8 = null,
    checked: bool = false,
    disabled: bool = false,
};

/// Per-instance identity and behaviour (contract §1).
pub const Box = struct {
    key: ?Key = null,
    style: Style = .{},
    layer: ?Layer = null,
    focusable: bool = false,
    key_context: ?KeyContext = null,
    on_click: ?Handler = null,
    on_click_outside: ?Handler = null,
    on_key: ?Handler = null,
    actions: []const ActionBinding = &.{},
    draggable: ?DragSource = null,
    drop_target: ?DropTarget = null,
    a11y: ?A11y = null,

    pub fn Element(comptime Children: type) type {
        return struct {
            box: Box,
            children: Children,

            pub const core_element: ElementKind = .box;
        };
    }
};

pub const FontWeight = @import("../text/types.zig").FontWeight;
pub const FontFamily = @import("../text/types.zig").FontFamily;

/// Text appearance. `size` and `color` default to the theme's base size and
/// `text` token.
pub const Text = struct {
    size: ?u16 = null,
    color: ?ColorToken = null,
    weight: FontWeight = .regular,
    italic: bool = false,
    /// `.mono` draws with `Config.fonts.mono` (contract decision 8); using it
    /// with no second family loaded panics on the first frame.
    family: FontFamily = .app,
    /// Wrapping against the parent's content width (contract decision 9):
    /// `.words` breaks between words and at newlines, `.newlines` only at
    /// newlines. Wrapped lines count against the frame's glyph and record limits.
    wrap: enum { none, words, newlines } = .none,
    /// Line pitch in percent of the font's line height; null keeps the font's.
    line_height: ?u16 = null,
    /// Line placement within the parent's content width, as in 0.3.1.
    alignment: enum { left, center, right } = .left,

    pub const Element = struct {
        content: []const u8,
        style: Text,

        pub const core_element: ElementKind = .text;
    };
};

pub const ElementKind = enum { box, text, paint, when };

pub fn box(options: Box, children: anytype) Box.Element(@TypeOf(children)) {
    return .{ .box = options, .children = children };
}

pub fn text(content: []const u8, style: Text) Text.Element {
    return .{ .content = content, .style = style };
}

/// A painted leaf. `data` must stay valid until the tick's emit phase ends,
/// so it points at app state, retained state, or a constant.
pub fn Paint(comptime Data: type) type {
    return struct {
        data: *const Data,
        paint_fn: *const fn (data: *const Data, painter: *Painter) void,
        style: Style,

        pub const core_element: ElementKind = .paint;
        pub const PaintData = Data;
    };
}

pub fn paint(
    comptime Data: type,
    data: *const Data,
    comptime paint_fn: fn (data: *const Data, painter: *Painter) void,
    style: Style,
) Paint(Data) {
    return .{ .data = data, .paint_fn = paint_fn, .style = style };
}

/// Render `render_fn` only when `condition` holds; the subtree is not built
/// otherwise.
pub const When = struct {
    condition: bool,
    render_fn: *const fn (cx: *Cx) void,

    pub const core_element: ElementKind = .when;
};

pub fn when(condition: bool, comptime render_fn: fn (cx: *Cx) void) When {
    return .{ .condition = condition, .render_fn = render_fn };
}

// Declared after use: Cx and Painter live with the code that drives them.
pub const Cx = @import("cx.zig").Cx;
pub const Painter = @import("emit.zig").Painter;

test "color tokens resolve against the theme" {
    // Goal: every token name matches a Theme field. Method: resolve a token
    // and a literal against the light theme.
    const theme = &Theme.light;
    const primary = (ColorToken{ .primary = {} }).resolve(theme);
    try std.testing.expectEqual(theme.primary.r, primary.r);
    const literal = ColorToken.literal(Color.white).resolve(theme);
    try std.testing.expectEqual(@as(f32, 1), literal.g);
    inline for (@typeInfo(ColorToken).@"union".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "rgba")) {
            try std.testing.expect(@hasField(Theme, name));
        }
    }
}
