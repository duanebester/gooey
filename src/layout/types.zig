const std = @import("std");

pub const Offset2D = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn zero() Offset2D {
        return .{};
    }

    pub fn init(x: f32, y: f32) Offset2D {
        return .{ .x = x, .y = y };
    }
};

pub const PercentSizing = struct {
    value: f32,
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),

    pub fn of(p: f32) PercentSizing {
        return .{ .value = p };
    }

    pub fn withMin(self: PercentSizing, min_val: f32) PercentSizing {
        return .{ .value = self.value, .min = min_val, .max = self.max };
    }

    pub fn withMax(self: PercentSizing, max_val: f32) PercentSizing {
        return .{ .value = self.value, .min = self.min, .max = max_val };
    }
};

pub const SizingType = enum {
    fit,
    grow,
    fixed,
    percent,
};

pub const SizingMinMax = struct {
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),

    pub fn fixed(size: f32) SizingMinMax {
        return .{ .min = size, .max = size };
    }

    pub fn atLeast(min_val: f32) SizingMinMax {
        return .{ .min = min_val, .max = std.math.floatMax(f32) };
    }

    pub fn atMost(max_val: f32) SizingMinMax {
        return .{ .min = 0, .max = max_val };
    }

    pub fn between(min_val: f32, max_val: f32) SizingMinMax {
        return .{ .min = min_val, .max = max_val };
    }
};

/// Grow constraints: min/max like `SizingMinMax`, plus the share of a
/// parent's free main-axis space relative to grow siblings.
pub const GrowSizing = struct {
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),
    /// Grow siblings split free space in proportion to their weights.
    weight: f32 = 1,
};

pub const SizingAxis = struct {
    value: SizingValue = .{ .fit = .{} },

    pub const SizingValue = union(SizingType) {
        fit: SizingMinMax,
        grow: GrowSizing,
        fixed: SizingMinMax,
        percent: PercentSizing,
    };

    pub fn fit() SizingAxis {
        return .{ .value = .{ .fit = .{} } };
    }

    pub fn fitMin(min_val: f32) SizingAxis {
        return .{ .value = .{ .fit = .{ .min = min_val } } };
    }

    pub fn fitMax(max_val: f32) SizingAxis {
        return .{ .value = .{ .fit = .{ .max = max_val } } };
    }

    pub fn fitMinMax(min_val: f32, max_val: f32) SizingAxis {
        return .{ .value = .{ .fit = .{ .min = min_val, .max = max_val } } };
    }

    pub fn grow() SizingAxis {
        return .{ .value = .{ .grow = .{} } };
    }

    pub fn growMin(min_val: f32) SizingAxis {
        return .{ .value = .{ .grow = .{ .min = min_val } } };
    }

    pub fn growMax(max_val: f32) SizingAxis {
        return .{ .value = .{ .grow = .{ .max = max_val } } };
    }

    pub fn growMinMax(min_val: f32, max_val: f32) SizingAxis {
        return .{ .value = .{ .grow = .{ .min = min_val, .max = max_val } } };
    }

    pub fn growWeighted(weight: f32, min_val: f32, max_val: f32) SizingAxis {
        std.debug.assert(weight > 0);
        std.debug.assert(std.math.isFinite(weight));
        return .{ .value = .{ .grow = .{ .min = min_val, .max = max_val, .weight = weight } } };
    }

    pub fn fixed(size: f32) SizingAxis {
        return .{ .value = .{ .fixed = SizingMinMax.fixed(size) } };
    }

    pub fn getType(self: SizingAxis) SizingType {
        return self.value;
    }

    pub fn getMin(self: SizingAxis) f32 {
        return switch (self.value) {
            .percent => |p| p.min,
            inline else => |mm| mm.min,
        };
    }

    pub fn getMax(self: SizingAxis) f32 {
        return switch (self.value) {
            .percent => |p| p.max,
            inline else => |mm| mm.max,
        };
    }

    pub fn percent(p: f32) SizingAxis {
        return .{ .value = .{ .percent = PercentSizing.of(p) } };
    }

    pub fn percentMin(p: f32, min_val: f32) SizingAxis {
        return .{ .value = .{ .percent = PercentSizing.of(p).withMin(min_val) } };
    }

    pub fn percentMinMax(p: f32, min_val: f32, max_val: f32) SizingAxis {
        return .{ .value = .{ .percent = .{ .value = p, .min = min_val, .max = max_val } } };
    }
};

pub const Sizing = struct {
    width: SizingAxis = .{},
    height: SizingAxis = .{},

    pub fn fitContent() Sizing {
        return .{ .width = SizingAxis.fit(), .height = SizingAxis.fit() };
    }

    pub fn fill() Sizing {
        return .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() };
    }

    pub fn fixed(width: f32, height: f32) Sizing {
        return .{
            .width = SizingAxis.fixed(width),
            .height = SizingAxis.fixed(height),
        };
    }

    pub fn horizontalFill() Sizing {
        return .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() };
    }

    pub fn verticalFill() Sizing {
        return .{ .width = SizingAxis.fit(), .height = SizingAxis.grow() };
    }
};

pub const LayoutDirection = enum {
    left_to_right,
    top_to_bottom,

    pub fn isHorizontal(self: LayoutDirection) bool {
        return self == .left_to_right;
    }

    pub fn isVertical(self: LayoutDirection) bool {
        return self == .top_to_bottom;
    }
};

pub const AlignmentX = enum {
    left,
    center,
    right,
};

pub const AlignmentY = enum {
    top,
    center,
    bottom,
};

pub const MainAxisDistribution = enum {
    start,
    center,
    end,
    /// Equal space between children, no space at edges
    space_between,
    /// Equal space around children (half space at edges)
    space_around,
    /// Equal space between and around children
    space_evenly,
};

pub const ChildAlignment = struct {
    x: AlignmentX = .left,
    y: AlignmentY = .top,

    pub fn center() ChildAlignment {
        return .{ .x = .center, .y = .center };
    }

    pub fn topLeft() ChildAlignment {
        return .{ .x = .left, .y = .top };
    }

    pub fn topCenter() ChildAlignment {
        return .{ .x = .center, .y = .top };
    }

    pub fn topRight() ChildAlignment {
        return .{ .x = .right, .y = .top };
    }

    pub fn centerLeft() ChildAlignment {
        return .{ .x = .left, .y = .center };
    }

    pub fn centerRight() ChildAlignment {
        return .{ .x = .right, .y = .center };
    }

    pub fn bottomLeft() ChildAlignment {
        return .{ .x = .left, .y = .bottom };
    }

    pub fn bottomCenter() ChildAlignment {
        return .{ .x = .center, .y = .bottom };
    }

    pub fn bottomRight() ChildAlignment {
        return .{ .x = .right, .y = .bottom };
    }
};

/// Padding/margin on each side (u16 for compact storage)
pub const Padding = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn all(p: u16) Padding {
        return .{ .left = p, .right = p, .top = p, .bottom = p };
    }

    pub fn symmetric(horizontal: u16, vertical: u16) Padding {
        return .{ .left = horizontal, .right = horizontal, .top = vertical, .bottom = vertical };
    }

    pub fn p_horizontal(h: u16) Padding {
        return .{ .left = h, .right = h, .top = 0, .bottom = 0 };
    }

    pub fn p_vertical(v: u16) Padding {
        return .{ .left = 0, .right = 0, .top = v, .bottom = v };
    }

    pub fn totalX(self: Padding) f32 {
        return @as(f32, @floatFromInt(self.left)) + @as(f32, @floatFromInt(self.right));
    }

    pub fn totalY(self: Padding) f32 {
        return @as(f32, @floatFromInt(self.top)) + @as(f32, @floatFromInt(self.bottom));
    }
};

pub const CornerRadius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_left: f32 = 0,
    bottom_right: f32 = 0,

    pub fn all(r: f32) CornerRadius {
        return .{ .top_left = r, .top_right = r, .bottom_left = r, .bottom_right = r };
    }

    pub fn top(r: f32) CornerRadius {
        return .{ .top_left = r, .top_right = r, .bottom_left = 0, .bottom_right = 0 };
    }

    pub fn bottom(r: f32) CornerRadius {
        return .{ .top_left = 0, .top_right = 0, .bottom_left = r, .bottom_right = r };
    }
};

pub const BorderWidth = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    pub fn all(w: f32) BorderWidth {
        return .{ .left = w, .right = w, .top = w, .bottom = w };
    }
};

pub const BorderConfig = struct {
    color: Color = Color.black,
    width: BorderWidth = .{},

    pub fn all(color: Color, w: f32) BorderConfig {
        return .{ .color = color, .width = BorderWidth.all(w) };
    }
};

pub const ShadowConfig = struct {
    blur_radius: f32 = 0,
    color: Color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.15 },
    offset_x: f32 = 0,
    offset_y: f32 = 4,

    pub fn drop(blur: f32) ShadowConfig {
        // 0.4: offset y scales with blur radius; aesthetic constant.
        return .{
            .blur_radius = blur,
            .offset_y = blur * 0.4,
        };
    }

    pub fn offset(blur: f32, x: f32, y: f32) ShadowConfig {
        return .{
            .blur_radius = blur,
            .offset_x = x,
            .offset_y = y,
        };
    }

    pub fn colored(blur: f32, color: Color) ShadowConfig {
        // Same 0.4 blur-to-offset ratio as `drop`.
        return .{
            .blur_radius = blur,
            .color = color,
            .offset_y = blur * 0.4,
        };
    }

    pub fn isVisible(self: ShadowConfig) bool {
        return self.blur_radius > 0 and self.color.a > 0;
    }
};

pub const Color = @import("../geometry/geometry.zig").Color;

pub const LayoutConfig = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: u16 = 0,
    child_alignment: ChildAlignment = .{},
    layout_direction: LayoutDirection = .left_to_right,
    main_axis_distribution: MainAxisDistribution = .start,
    /// Aspect ratio (width / height). When set, height is derived from width.
    aspect_ratio: ?f32 = null,
    /// Break a `left_to_right` row into lines at its content width, as CSS
    /// `flex-wrap: wrap`: children keep their own widths, grow children share
    /// each line's free width, and lines stack top to bottom `child_gap`
    /// apart. Its minimum width is its widest child's.
    wrap: bool = false,

    pub fn row(gap: u16) LayoutConfig {
        return .{ .layout_direction = .left_to_right, .child_gap = gap };
    }

    pub fn column(gap: u16) LayoutConfig {
        return .{ .layout_direction = .top_to_bottom, .child_gap = gap };
    }

    pub fn centered() LayoutConfig {
        return .{ .child_alignment = ChildAlignment.center() };
    }

    pub fn withAspectRatio(self: LayoutConfig, ratio: f32) LayoutConfig {
        var result = self;
        result.aspect_ratio = ratio;
        return result;
    }
};

pub const AttachPoint = enum {
    left_top,
    left_center,
    left_bottom,
    center_top,
    center_center,
    center_bottom,
    right_top,
    right_center,
    right_bottom,

    pub fn normalizedX(self: AttachPoint) f32 {
        return switch (self) {
            .left_top, .left_center, .left_bottom => 0.0,
            .center_top, .center_center, .center_bottom => 0.5,
            .right_top, .right_center, .right_bottom => 1.0,
        };
    }

    pub fn normalizedY(self: AttachPoint) f32 {
        return switch (self) {
            .left_top, .center_top, .right_top => 0.0,
            .left_center, .center_center, .right_center => 0.5,
            .left_bottom, .center_bottom, .right_bottom => 1.0,
        };
    }
};

pub const FloatingConfig = struct {
    offset: Offset2D = .{},
    /// Position against the direct parent; false positions against the
    /// viewport (modals).
    attach_to_parent: bool = true,
    element_attach: AttachPoint = .left_top,
    parent_attach: AttachPoint = .left_top,
    expand: struct {
        width: bool = false,
        height: bool = false,
    } = .{},

    pub fn dropdown() FloatingConfig {
        return .{ .element_attach = .left_top, .parent_attach = .left_bottom };
    }

    pub fn tooltip() FloatingConfig {
        return .{ .element_attach = .center_bottom, .parent_attach = .center_top, .offset = .{ .y = -4 } };
    }

    pub fn modal() FloatingConfig {
        return .{ .attach_to_parent = false, .element_attach = .center_center, .parent_attach = .center_center };
    }
};

pub const ScrollConfig = struct {
    horizontal: bool = false,
    vertical: bool = false,
    /// The offset children are placed at. With a `target`, the position pass
    /// resolves it against this frame's content and writes the offset it
    /// used back here, for the caller to keep.
    scroll_offset: Offset2D = .{},
    target: ScrollTarget = .none,
};

/// Where a scroll container's offset comes from this frame: `scroll_offset`
/// (`.none`), or a place in the content the position pass measures: its
/// start or end, an offset clamped to it, or one child brought into view.
pub const ScrollTarget = union(enum) {
    none,
    start,
    end,
    offset: Offset2D,
    child: ScrollChild,
};

pub const ScrollChild = struct {
    /// The child's element index; it must be a direct, non-floating child.
    index: u32,
    alignment: ScrollAlignment,
};

pub const ScrollAlignment = enum { start, center, end, nearest };

pub const WrappedLine = struct {
    start_offset: u32,
    length: u32,
    width: f32,
};

pub const TextConfig = struct {
    color: Color = Color.black,
    font_id: u16 = 0,
    font_size: u16 = 16,
    letter_spacing: i16 = 0,
    line_height: u16 = 120,
    wrap_mode: WrapMode = .none,
    alignment: TextAlignment = .left,
    decoration: TextDecorationConfig = .{},

    pub const WrapMode = enum { none, words, newlines };
    pub const TextAlignment = enum { left, center, right };

    pub const TextDecorationConfig = packed struct {
        underline: bool = false,
        strikethrough: bool = false,
        _padding: u6 = 0,
    };

    pub fn lineHeightPx(self: TextConfig) f32 {
        const font_size_f: f32 = @floatFromInt(self.font_size);
        const line_height_pct: f32 = @as(f32, @floatFromInt(self.line_height)) / 100.0;
        return font_size_f * line_height_pct;
    }
};

pub const BoundingBox = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(x: f32, y: f32, width: f32, height: f32) BoundingBox {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn contains(self: BoundingBox, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }

    pub fn right(self: BoundingBox) f32 {
        return self.x + self.width;
    }

    pub fn bottom(self: BoundingBox) f32 {
        return self.y + self.height;
    }

    pub fn intersects(self: BoundingBox, other: BoundingBox) bool {
        return self.x < other.right() and self.right() > other.x and
            self.y < other.bottom() and self.bottom() > other.y;
    }

    pub fn intersection(self: BoundingBox, other: BoundingBox) BoundingBox {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.right(), other.right());
        const y2 = @min(self.bottom(), other.bottom());
        if (x2 <= x1 or y2 <= y1) return .{};
        return .{ .x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1 };
    }

    pub const zero = BoundingBox{};
};

test "sizing constructors" {
    const sizing = Sizing.fixed(100, 200);
    try std.testing.expectEqual(.fixed, std.meta.activeTag(sizing.width.value));
    try std.testing.expectEqual(@as(f32, 100), sizing.width.getMin());
}

test "padding helpers" {
    const p = Padding.symmetric(10, 20);
    try std.testing.expectEqual(@as(u16, 10), p.left);
    try std.testing.expectEqual(@as(f32, 20), p.totalX());
}
