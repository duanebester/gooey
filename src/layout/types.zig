//! Layout system types inspired by Clay.h
//!
//! These types define the declarative layout configuration
//! used to describe UI element sizing, positioning, and behavior.

const std = @import("std");

// ============================================================================
// Sizing Types
// ============================================================================

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
        percent: f32,
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

    /// Percentage of parent (0.0 - 1.0)
    pub fn percent(p: f32) SizingAxis {
        return .{ .value = .{ .percent = p } };
    }

    /// Get the sizing type
    pub fn getType(self: SizingAxis) SizingType {
        return self.value;
    }

    /// Get min constraint
    pub fn getMin(self: SizingAxis) f32 {
        return switch (self.value) {
            .percent => 0,
            inline else => |mm| mm.min,
        };
    }

    /// Get max constraint
    pub fn getMax(self: SizingAxis) f32 {
        return switch (self.value) {
            .percent => std.math.floatMax(f32),
            inline else => |mm| mm.max,
        };
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
// Color
// ============================================================================

/// RGBA color (0.0-1.0 range)
pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb8(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = 1,
        };
    }

    pub fn hex(value: u32) Color {
        if (value > 0xFFFFFF) {
            return .{
                .r = @as(f32, @floatFromInt((value >> 24) & 0xFF)) / 255.0,
                .g = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
                .b = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
                .a = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
            };
        } else {
            return .{
                .r = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
                .g = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
                .b = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
                .a = 1.0,
            };
        }
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
};

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

    pub fn row(gap: u16) LayoutConfig {
        return .{ .layout_direction = .left_to_right, .child_gap = gap };
    }

    pub fn column(gap: u16) LayoutConfig {
        return .{ .layout_direction = .top_to_bottom, .child_gap = gap };
    }

    pub fn centered() LayoutConfig {
        return .{ .child_alignment = ChildAlignment.center() };
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
};

pub const FloatingConfig = struct {
    offset: struct { x: f32 = 0, y: f32 = 0 } = .{},
    z_index: i16 = 0,
    attach_to_parent: bool = true,
    parent_id: ?u32 = null,
    element_attach: AttachPoint = .left_top,
    parent_attach: AttachPoint = .left_top,
};

// ============================================================================
// Scroll Config
// ============================================================================

pub const ScrollConfig = struct {
    horizontal: bool = false,
    vertical: bool = false,
    scroll_offset: struct { x: f32 = 0, y: f32 = 0 } = .{},
};

// ============================================================================
// Text Config
// ============================================================================

pub const TextConfig = struct {
    color: Color = Color.black,
    font_id: u16 = 0,
    font_size: u16 = 14,
    letter_spacing: i16 = 0,
    line_height: u16 = 120,
    wrap_mode: WrapMode = .none,

    pub const WrapMode = enum { none, words, newlines };
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
    try std.testing.expectEqual(.fixed, sizing.width.value);
    try std.testing.expectEqual(@as(f32, 100), sizing.width.getMin());
}

test "padding helpers" {
    const p = Padding.symmetric(10, 20);
    try std.testing.expectEqual(@as(u16, 10), p.left);
    try std.testing.expectEqual(@as(f32, 20), p.totalX());
}
