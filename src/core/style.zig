//! Style system for elements - Tailwind/GPUI inspired
//!
//! Styles define visual appearance and layout behavior.
//! They can be refined for different states (hover, active, focus).

const std = @import("std");
const types = @import("element_types.zig");

pub const Pixels = types.Pixels;
pub const Edges = types.Edges;
pub const Corners = types.Corners;

// =============================================================================
// Colors (HSLA)
// =============================================================================

pub const Hsla = struct {
    h: f32 = 0,
    s: f32 = 0,
    l: f32 = 0,
    a: f32 = 1,

    pub fn init(h: f32, s: f32, l: f32, a: f32) Hsla {
        return .{ .h = h, .s = s, .l = l, .a = a };
    }

    pub fn opacity(self: Hsla, alpha: f32) Hsla {
        var c = self;
        c.a = alpha;
        return c;
    }

    pub const transparent = Hsla{ .a = 0 };
    pub const white = Hsla{ .l = 1 };
    pub const black = Hsla{};
    pub const red = Hsla{ .h = 0, .s = 1, .l = 0.5 };
    pub const green = Hsla{ .h = 0.333, .s = 1, .l = 0.5 };
    pub const blue = Hsla{ .h = 0.666, .s = 1, .l = 0.5 };
};

/// Create HSLA from RGB hex value
pub fn rgb(hex: u32) Hsla {
    const r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0;
    const g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0;
    const b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0;

    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const l = (max_c + min_c) / 2.0;

    if (max_c == min_c) {
        return .{ .h = 0, .s = 0, .l = l, .a = 1 };
    }

    const d = max_c - min_c;
    const s = if (l > 0.5) d / (2.0 - max_c - min_c) else d / (max_c + min_c);

    var h: f32 = 0;
    if (max_c == r) {
        h = (g - b) / d + (if (g < b) @as(f32, 6.0) else 0);
    } else if (max_c == g) {
        h = (b - r) / d + 2.0;
    } else {
        h = (r - g) / d + 4.0;
    }
    h /= 6.0;

    return .{ .h = h, .s = s, .l = l, .a = 1 };
}

// =============================================================================
// Length Units
// =============================================================================

pub const Length = union(enum) {
    px: Pixels,
    percent: f32,
    auto,

    pub fn pixels(value: Pixels) Length {
        return .{ .px = value };
    }

    pub fn pct(value: f32) Length {
        return .{ .percent = value };
    }
};

// =============================================================================
// Flexbox Properties
// =============================================================================

pub const Display = enum {
    flex,
    block,
    none,
};

pub const FlexDirection = enum {
    row,
    row_reverse,
    column,
    column_reverse,

    pub fn isRow(self: FlexDirection) bool {
        return self == .row or self == .row_reverse;
    }

    pub fn isReverse(self: FlexDirection) bool {
        return self == .row_reverse or self == .column_reverse;
    }
};

pub const JustifyContent = enum {
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
    space_evenly,
};

pub const AlignItems = enum {
    flex_start,
    flex_end,
    center,
    stretch,
    baseline,
};

pub const AlignSelf = enum {
    auto,
    flex_start,
    flex_end,
    center,
    stretch,
    baseline,
};

pub const Overflow = enum {
    visible,
    hidden,
    scroll,
};

pub const Position = enum {
    relative,
    absolute,
};

pub const CursorStyle = enum {
    default,
    pointer,
    text,
    grab,
    grabbing,
    not_allowed,
    crosshair,
    move,
    ns_resize,
    ew_resize,
};

// =============================================================================
// Full Style
// =============================================================================

pub const Style = struct {
    // Display & Position
    display: Display = .flex,
    position: Position = .relative,

    // Flexbox container
    flex_direction: FlexDirection = .row,
    justify_content: JustifyContent = .flex_start,
    align_items: AlignItems = .stretch,
    flex_wrap: bool = false,
    gap: Pixels = 0,
    row_gap: ?Pixels = null,
    column_gap: ?Pixels = null,

    // Flexbox item
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Length = .auto,
    align_self: AlignSelf = .auto,

    // Size
    width: Length = .auto,
    height: Length = .auto,
    min_width: ?Pixels = null,
    min_height: ?Pixels = null,
    max_width: ?Pixels = null,
    max_height: ?Pixels = null,

    // Spacing
    padding: Edges = .{},
    margin: Edges = .{},

    // Position (when position = .absolute)
    inset_top: ?Pixels = null,
    inset_right: ?Pixels = null,
    inset_bottom: ?Pixels = null,
    inset_left: ?Pixels = null,

    // Visual
    background: Hsla = Hsla.transparent,
    border_color: Hsla = Hsla.transparent,
    border_width: Edges = .{},
    corner_radius: Corners = .{},
    opacity: f32 = 1.0,

    // Shadow
    shadow_color: Hsla = Hsla.init(0, 0, 0, 0.25),
    shadow_blur: Pixels = 0,
    shadow_offset: types.Point = .{},

    // Overflow
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,

    // Text (inherited)
    text_color: ?Hsla = null,
    font_size: ?Pixels = null,
    font_weight: ?u16 = null,
    line_height: ?Pixels = null,

    // Cursor
    cursor: ?CursorStyle = null,

    // Z-index
    z_index: ?i32 = null,

    const Self = @This();

    // === Builder Methods ===

    pub fn size(self: Self, w: Pixels, h: Pixels) Self {
        var s = self;
        s.width = .{ .px = w };
        s.height = .{ .px = h };
        return s;
    }

    pub fn fullWidth(self: Self) Self {
        var s = self;
        s.width = .{ .percent = 1.0 };
        return s;
    }

    pub fn fullHeight(self: Self) Self {
        var s = self;
        s.height = .{ .percent = 1.0 };
        return s;
    }

    pub fn full(self: Self) Self {
        return self.fullWidth().fullHeight();
    }

    pub fn bg(self: Self, color: Hsla) Self {
        var s = self;
        s.background = color;
        return s;
    }

    pub fn rounded(self: Self, radius: Pixels) Self {
        var s = self;
        s.corner_radius = Corners.all(radius);
        return s;
    }

    pub fn p(self: Self, value: Pixels) Self {
        var s = self;
        s.padding = Edges.all(value);
        return s;
    }

    pub fn px(self: Self, value: Pixels) Self {
        var s = self;
        s.padding.left = value;
        s.padding.right = value;
        return s;
    }

    pub fn py(self: Self, value: Pixels) Self {
        var s = self;
        s.padding.top = value;
        s.padding.bottom = value;
        return s;
    }

    pub fn m(self: Self, value: Pixels) Self {
        var s = self;
        s.margin = Edges.all(value);
        return s;
    }

    pub fn flexCol(self: Self) Self {
        var s = self;
        s.flex_direction = .column;
        return s;
    }

    pub fn flexRow(self: Self) Self {
        var s = self;
        s.flex_direction = .row;
        return s;
    }

    pub fn itemsCenter(self: Self) Self {
        var s = self;
        s.align_items = .center;
        return s;
    }

    pub fn justifyCenter(self: Self) Self {
        var s = self;
        s.justify_content = .center;
        return s;
    }

    pub fn center(self: Self) Self {
        return self.itemsCenter().justifyCenter();
    }

    pub fn grow(self: Self) Self {
        var s = self;
        s.flex_grow = 1;
        return s;
    }

    pub fn shrink(self: Self, value: f32) Self {
        var s = self;
        s.flex_shrink = value;
        return s;
    }

    pub fn gapSize(self: Self, value: Pixels) Self {
        var s = self;
        s.gap = value;
        return s;
    }

    pub fn border(self: Self, color: Hsla, width: Pixels) Self {
        var s = self;
        s.border_color = color;
        s.border_width = Edges.all(width);
        return s;
    }

    pub fn shadow(self: Self, blur: Pixels) Self {
        var s = self;
        s.shadow_blur = blur;
        s.shadow_offset.y = blur * 0.4;
        return s;
    }
};

// =============================================================================
// Style Refinement (for hover, active, focus states)
// =============================================================================

pub const StyleRefinement = struct {
    background: ?Hsla = null,
    border_color: ?Hsla = null,
    text_color: ?Hsla = null,
    cursor: ?CursorStyle = null,
    opacity: ?f32 = null,
    shadow_blur: ?Pixels = null,

    pub fn apply(self: StyleRefinement, base: *Style) void {
        if (self.background) |bg| base.background = bg;
        if (self.border_color) |bc| base.border_color = bc;
        if (self.text_color) |tc| base.text_color = tc;
        if (self.cursor) |c| base.cursor = c;
        if (self.opacity) |o| base.opacity = o;
        if (self.shadow_blur) |sb| base.shadow_blur = sb;
    }
};
