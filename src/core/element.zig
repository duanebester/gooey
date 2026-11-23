const std = @import("std");
const id_mod = @import("id.zig");
const records = @import("records.zig");
const handler_mod = @import("handler.zig");
const layers = @import("layers.zig");
const geometry = @import("../geometry/geometry.zig");
const a11y_types = @import("../accessibility/types.zig");
const ui_theme = @import("theme.zig");

const assert = std.debug.assert;

pub const Key = id_mod.Key;
pub const Handler = handler_mod.Handler;
pub const Color = geometry.Color;
pub const Theme = ui_theme.Theme;
pub const Corners = records.Corners;
pub const Layer = layers.Layer;
pub const Anchor = layers.Anchor;
pub const Role = a11y_types.Role;
pub const HeadingLevel = a11y_types.HeadingLevel;
pub const Live = a11y_types.Live;
pub const Orientation = a11y_types.Orientation;
pub const TextSelection = @import("../accessibility/element.zig").TextSelection;

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

pub const Alignment = struct {
    main: Main = .start,
    cross: Cross = .start,

    pub const Main = enum { start, center, end, space_between, space_around, space_evenly };
    pub const Cross = enum { start, center, end };

    pub const start: Alignment = .{};
    pub const center: Alignment = .{ .main = .center, .cross = .center };
    pub const center_cross: Alignment = .{ .cross = .center };
};

pub const grid_track_count_max: u8 = 32;

pub const Grid = struct {
    columns: []const Track,
    rows: []const Track = &.{},
    row_implicit: Track = .fit,
    row_gap: ?f32 = null,

    pub const track_count_max = grid_track_count_max;
};

pub const Track = struct {
    sizing: Sizing = .fit,
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),
    cell_alignment: ?Alignment.Cross = null,

    pub const fit: Track = .{};

    pub fn fixed(size: f32) Track {
        return .{ .sizing = .{ .fixed = size } };
    }

    pub fn grow(weight: f32) Track {
        return .{ .sizing = .{ .grow = weight } };
    }

    pub fn percent(fraction: f32) Track {
        return .{ .sizing = .{ .percent = fraction } };
    }
};

pub const Cell = struct {
    column: ?u8 = null,
    column_span: u8 = 1,
    row: bool = false,
};

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
    on_primary,
    on_danger,
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
pub const Scroll = struct {
    x: bool = false,
    y: bool = true,
    anchor: ScrollAnchor = .start,
};

pub const ScrollAnchor = enum { start, end };

pub const ScrollTarget = union(enum) {
    start,
    end,
    offset: ScrollOffset,
    child: ScrollChild,
};

pub const ScrollOffset = struct { x: f32 = 0, y: f32 = 0 };

pub const ScrollChild = struct {
    key: Key,
    alignment: ScrollAlignment = .nearest,
};

pub const ScrollAlignment = enum { start, center, end, nearest };
pub const CursorShape = @import("../platform/interface.zig").CursorShape;
pub const PointerEvents = enum { auto, none };

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
    wrap: bool = false,
    aspect_ratio: ?f32 = null,
    grid: ?Grid = null,
    cell: Cell = .{},
    background: ?ColorToken = null,
    border: ?Border = null,
    corner_radius: Corners = .zero,
    shadow: ?Shadow = null,
    opacity: f32 = 1,
    clip: ClipPolicy = .none,
    scroll: ?Scroll = null,
    cursor: ?CursorShape = null,
    pointer_events: PointerEvents = .auto,
    source: ?std.builtin.SourceLocation = null,
};

pub const KeyContext = struct {
    hash: u64,

    pub fn named(comptime name: []const u8) KeyContext {
        comptime assert(name.len > 0);
        return .{ .hash = comptime nonZeroHash(name) };
    }
};

pub const ActionBinding = struct { action: u64, handler: Handler };

pub fn action(comptime Action: type) u64 {
    comptime assert(@typeInfo(Action) == .@"struct");
    return comptime nonZeroHash(@typeName(Action));
}

fn nonZeroHash(comptime name: []const u8) u64 {
    const hash = std.hash.Wyhash.hash(0, name);
    return if (hash == 0) 1 else hash;
}

pub const A11y = struct {
    role: Role,
    label: ?[]const u8 = null,
    value: ?[]const u8 = null,
    checked: bool = false,
    selected: bool = false,
    disabled: bool = false,
    heading_level: HeadingLevel = .none,
    live: Live = .off,
    href: ?[]const u8 = null,
    description: ?[]const u8 = null,
    expanded: bool = false,
    has_popup: bool = false,
    pos_in_set: ?u16 = null,
    set_size: ?u16 = null,
    range: ?Range = null,
    selection: ?TextSelection = null,

    pub const Range = struct { min: f32, max: f32, now: f32, orientation: Orientation };
};

pub const Box = struct {
    key: ?Key = null,
    style: Style = .{},
    layer: ?Layer = null,
    focusable: bool = false,
    tab_stop: bool = true,
    key_context: ?KeyContext = null,
    on_click: ?Handler = null,
    on_click_outside: ?Handler = null,
    on_context_menu: ?Handler = null,
    on_key: ?Handler = null,
    on_pointer_drag: ?Handler = null,
    draggable: ?DragSource = null,
    drop_target: ?DropTarget = null,
    actions: []const ActionBinding = &.{},
    a11y: ?A11y = null,

    pub fn Element(comptime Children: type) type {
        return struct {
            box: Box,
            children: Children,

            pub const core_element: ElementKind = .box;
        };
    }
};

pub const DragSource = struct {
    type_id: usize,
    payload: u64,

    pub fn of(comptime T: type, payload: T) DragSource {
        comptime assert(@sizeOf(T) <= @sizeOf(u64));
        comptime assert(@typeInfo(T) != .pointer);
        const source: DragSource = .{
            .type_id = handler_mod.typeId(T),
            .payload = handler_mod.packArg(T, payload),
        };
        assert(source.type_id != 0);
        return source;
    }
};

pub const DropTarget = struct {
    type_id: usize,
    on_drop: Handler,

    pub fn of(comptime T: type, on_drop: Handler) DropTarget {
        comptime assert(@sizeOf(T) <= @sizeOf(u64));
        const target: DropTarget = .{ .type_id = handler_mod.typeId(T), .on_drop = on_drop };
        assert(target.type_id != 0);
        return target;
    }
};

pub const FontWeight = @import("../text/types.zig").FontWeight;
pub const FontFamily = @import("../text/types.zig").FontFamily;

pub const Text = struct {
    size: ?u16 = null,
    color: ?ColorToken = null,
    weight: FontWeight = .regular,
    italic: bool = false,
    family: FontFamily = .app,
    wrap: enum { none, words, newlines } = .none,
    line_height: ?u16 = null,
    alignment: enum { left, center, right } = .left,
    line_count_max: ?u8 = null,
    overflow: enum { clip, ellipsis } = .clip,

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

pub const When = struct {
    condition: bool,
    render_fn: *const fn (cx: *Cx) void,

    pub const core_element: ElementKind = .when;
};

pub fn when(condition: bool, comptime render_fn: fn (cx: *Cx) void) When {
    return .{ .condition = condition, .render_fn = render_fn };
}

pub const Cx = @import("cx.zig").Cx;
pub const Painter = @import("emit.zig").Painter;

test "color tokens resolve against the theme" {
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
