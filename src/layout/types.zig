//! Layout system types inspired by Clay.h
//!
//! These types define the declarative layout configuration
//! used to describe UI element sizing, positioning, and behavior.

const std = @import("std");

// ============================================================================
// Shared Types (Phase 3.4)
// ============================================================================

/// Shared 2D offset type for scroll offsets, floating offsets, etc.
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

// ============================================================================
// Sizing Types
// ============================================================================

/// Percent sizing with min/max constraints (Phase 1 addition)
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

/// How an element determines its size along an axis
pub const SizingType = enum {
    /// Size to fit content (text, children)
    fit,
    /// Expand to fill available space (flex grow)
    grow,
    /// Fixed pixel size
    fixed,
    /// Percentage of parent's content area
    percent,
};

/// Min/max constraints for sizing
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

/// Sizing configuration for a single axis
pub const SizingAxis = struct {
    value: SizingValue = .{ .fit = .{} },

    pub const SizingValue = union(SizingType) {
        fit: SizingMinMax,
        grow: SizingMinMax,
        fixed: SizingMinMax,
        percent: PercentSizing,
    };

    /// Fit to content with optional min/max constraints
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

    /// Grow to fill available space with optional min/max
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

    /// Fixed pixel size
    pub fn fixed(size: f32) SizingAxis {
        return .{ .value = .{ .fixed = SizingMinMax.fixed(size) } };
    }

    /// Get the sizing type
    pub fn getType(self: SizingAxis) SizingType {
        return self.value;
    }

    /// Get min constraint
    pub fn getMin(self: SizingAxis) f32 {
        return switch (self.value) {
            .percent => |p| p.min,
            inline else => |mm| mm.min,
        };
    }

    /// Get max constraint
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

/// Complete sizing configuration (width + height)
pub const Sizing = struct {
    width: SizingAxis = .{},
    height: SizingAxis = .{},

    /// Both dimensions fit content
    pub fn fitContent() Sizing {
        return .{ .width = SizingAxis.fit(), .height = SizingAxis.fit() };
    }

    /// Both dimensions grow to fill
    pub fn fill() Sizing {
        return .{ .width = SizingAxis.grow(), .height = SizingAxis.grow() };
    }

    /// Fixed size in both dimensions
    pub fn fixed(width: f32, height: f32) Sizing {
        return .{
            .width = SizingAxis.fixed(width),
            .height = SizingAxis.fixed(height),
        };
    }

    /// Width grows, height fits content
    pub fn horizontalFill() Sizing {
        return .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() };
    }

    /// Width fits, height grows
    pub fn verticalFill() Sizing {
        return .{ .width = SizingAxis.fit(), .height = SizingAxis.grow() };
    }
};

// ============================================================================
// Layout Direction & Alignment
// ============================================================================

/// Direction children are laid out
pub const LayoutDirection = enum {
    /// Horizontal: left to right
    left_to_right,
    /// Vertical: top to bottom
    top_to_bottom,

    pub fn isHorizontal(self: LayoutDirection) bool {
        return self == .left_to_right;
    }

    pub fn isVertical(self: LayoutDirection) bool {
        return self == .top_to_bottom;
    }
};

/// Horizontal alignment within container
pub const AlignmentX = enum {
    left,
    center,
    right,
};

/// Vertical alignment within container
pub const AlignmentY = enum {
    top,
    center,
    bottom,
};

/// Main axis distribution mode for children
pub const MainAxisDistribution = enum {
    /// Children packed at start (default)
    start,
    /// Children centered
    center,
    /// Children packed at end
    end,
    /// Equal space between children, no space at edges
    space_between,
    /// Equal space around children (half space at edges)
    space_around,
    /// Equal space between and around children
    space_evenly,
};

/// Child alignment configuration
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

// ============================================================================
// Padding
// ============================================================================

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

    /// Total horizontal padding
    pub fn totalX(self: Padding) f32 {
        return @as(f32, @floatFromInt(self.left)) + @as(f32, @floatFromInt(self.right));
    }

    /// Total vertical padding
    pub fn totalY(self: Padding) f32 {
        return @as(f32, @floatFromInt(self.top)) + @as(f32, @floatFromInt(self.bottom));
    }
};

// ============================================================================
// Corner Radius
// ============================================================================

/// Corner radii for rounded rectangles
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

// ============================================================================
// Border Configuration
// ============================================================================

/// Border width on each side
pub const BorderWidth = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    pub fn all(w: f32) BorderWidth {
        return .{ .left = w, .right = w, .top = w, .bottom = w };
    }
};

/// Border configuration
pub const BorderConfig = struct {
    color: Color = Color.black,
    width: BorderWidth = .{},

    pub fn all(color: Color, w: f32) BorderConfig {
        return .{ .color = color, .width = BorderWidth.all(w) };
    }
};

// ============================================================================
// Shadow Configuration
// ============================================================================

/// Shadow configuration for drop shadows
pub const ShadowConfig = struct {
    /// Shadow blur radius (0 = no shadow)
    blur_radius: f32 = 0,
    /// Shadow color (RGBA)
    color: Color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.15 },
    /// Horizontal offset
    offset_x: f32 = 0,
    /// Vertical offset (positive = down)
    offset_y: f32 = 4,

    /// Create a simple drop shadow with default color
    pub fn drop(blur: f32) ShadowConfig {
        return .{
            .blur_radius = blur,
            .offset_y = blur * 0.4,
        };
    }

    /// Create a shadow with custom blur and offset
    pub fn offset(blur: f32, x: f32, y: f32) ShadowConfig {
        return .{
            .blur_radius = blur,
            .offset_x = x,
            .offset_y = y,
        };
    }

    /// Create a shadow with custom color
    pub fn colored(blur: f32, color: Color) ShadowConfig {
        return .{
            .blur_radius = blur,
            .color = color,
            .offset_y = blur * 0.4,
        };
    }

    /// Check if shadow is visible
    pub fn isVisible(self: ShadowConfig) bool {
        return self.blur_radius > 0 and self.color.a > 0;
    }
};

// ============================================================================
// Color
// ============================================================================

pub const Color = @import("../core/geometry.zig").Color;

// ============================================================================
// Layout Config
// ============================================================================

/// Complete layout configuration for an element
pub const LayoutConfig = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: u16 = 0,
    child_alignment: ChildAlignment = .{},
    layout_direction: LayoutDirection = .left_to_right,
    /// Main axis distribution mode for children
    main_axis_distribution: MainAxisDistribution = .start,
    /// Aspect ratio (width / height). When set, height is derived from width.
    aspect_ratio: ?f32 = null,

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

// ============================================================================
// Floating Config
// ============================================================================

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
    z_index: i16 = 0,
    attach_to_parent: bool = true,
    parent_id: ?u32 = null,
    element_attach: AttachPoint = .left_top,
    parent_attach: AttachPoint = .left_top,
    /// Whether to expand to match parent dimensions
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

// ============================================================================
// Scroll Config
// ============================================================================

pub const ScrollConfig = struct {
    horizontal: bool = false,
    vertical: bool = false,
    scroll_offset: Offset2D = .{},
};

// ============================================================================
// Text Config
// ============================================================================
/// A single line of wrapped text
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

    /// Calculate line height in pixels
    pub fn lineHeightPx(self: TextConfig) f32 {
        const font_size_f: f32 = @floatFromInt(self.font_size);
        const line_height_pct: f32 = @as(f32, @floatFromInt(self.line_height)) / 100.0;
        return font_size_f * line_height_pct;
    }
};

// ============================================================================
// Bounding Box (layout output)
// ============================================================================

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
