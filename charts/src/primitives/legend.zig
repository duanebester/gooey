//! Legend Primitive for Gooey Charts
//!
//! Renders a legend showing series names and colors.
//! Supports multiple positions (top, bottom, left, right) and
//! different marker shapes (rect, circle, line).

const std = @import("std");
const gooey = @import("gooey");
const constants = @import("../constants.zig");

pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;

const MAX_LEGEND_ITEMS = constants.MAX_LEGEND_ITEMS;
const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

// =============================================================================
// Legend
// =============================================================================

pub const Legend = struct {
    /// Legend position relative to the chart area.
    pub const Position = enum {
        top,
        bottom,
        left,
        right,
    };

    /// Shape of the legend marker/swatch.
    pub const Shape = enum {
        rect,
        circle,
        line,
    };

    /// A single legend item.
    pub const Item = struct {
        label: []const u8,
        color: Color,
        shape: Shape = .rect,

        pub fn init(label: []const u8, color: Color) Item {
            std.debug.assert(label.len <= MAX_LABEL_LENGTH);
            return .{ .label = label, .color = color };
        }

        pub fn initWithShape(label: []const u8, color: Color, shape: Shape) Item {
            std.debug.assert(label.len <= MAX_LABEL_LENGTH);
            return .{ .label = label, .color = color, .shape = shape };
        }
    };

    /// Configuration options for legend rendering.
    pub const Options = struct {
        position: Position = .bottom,
        spacing: f32 = 16.0,
        item_size: f32 = 12.0,
        font_size: f32 = 12.0,
        color: Color = Color.hex(0x333333),
        background: ?Color = null,
        padding: f32 = 8.0,
        item_gap: f32 = 8.0, // Gap between marker and label
    };

    /// Bounds for positioning and layout.
    pub const Bounds = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };

    /// Result of drawing a legend, includes consumed space.
    pub const DrawResult = struct {
        consumed: Bounds,
    };

    /// Draw a legend with the given items and options.
    /// Returns the bounds consumed by the legend.
    pub fn draw(
        ctx: *DrawContext,
        bounds: Bounds,
        items: []const Item,
        opts: Options,
    ) DrawResult {
        // Assertions at API boundary
        std.debug.assert(items.len > 0 and items.len <= MAX_LEGEND_ITEMS);
        std.debug.assert(bounds.width >= 0 and bounds.height >= 0);

        // Calculate layout based on position
        const layout = calculateLayout(items, bounds, opts);

        // Draw background if specified
        if (opts.background) |bg| {
            ctx.fillRect(layout.x, layout.y, layout.width, layout.height, bg);
        }

        // Draw items based on orientation
        switch (opts.position) {
            .top, .bottom => drawHorizontal(ctx, items, layout, opts),
            .left, .right => drawVertical(ctx, items, layout, opts),
        }

        return .{ .consumed = layout };
    }

    /// Calculate the required dimensions for the legend.
    pub fn calculateDimensions(
        items: []const Item,
        opts: Options,
    ) struct { width: f32, height: f32 } {
        std.debug.assert(items.len > 0);
        std.debug.assert(items.len <= MAX_LEGEND_ITEMS);

        // Use slightly larger estimate (0.7) to ensure enough space for actual text
        const char_width = opts.font_size * 0.7;
        const item_height = @max(opts.item_size, opts.font_size);

        switch (opts.position) {
            .top, .bottom => {
                // Horizontal layout
                var total_width: f32 = opts.padding * 2;
                for (items, 0..) |item, i| {
                    if (i > 0) total_width += opts.spacing;
                    total_width += opts.item_size + opts.item_gap;
                    total_width += char_width * @as(f32, @floatFromInt(item.label.len));
                }
                const height = opts.padding * 2 + item_height;
                return .{ .width = total_width, .height = height };
            },
            .left, .right => {
                // Vertical layout
                var max_width: f32 = 0;
                for (items) |item| {
                    const item_width = opts.item_size + opts.item_gap +
                        char_width * @as(f32, @floatFromInt(item.label.len));
                    max_width = @max(max_width, item_width);
                }
                const width = opts.padding * 2 + max_width;
                const height = opts.padding * 2 +
                    item_height * @as(f32, @floatFromInt(items.len)) +
                    opts.spacing * @as(f32, @floatFromInt(items.len -| 1));
                return .{ .width = width, .height = height };
            },
        }
    }
};

// =============================================================================
// Helper Functions (kept under 70 lines each per CLAUDE.md)
// =============================================================================

/// Calculate the layout bounds for the legend.
fn calculateLayout(
    items: []const Legend.Item,
    bounds: Legend.Bounds,
    opts: Legend.Options,
) Legend.Bounds {
    std.debug.assert(items.len > 0);
    std.debug.assert(!std.math.isNan(bounds.x) and !std.math.isNan(bounds.y));

    const dims = Legend.calculateDimensions(items, opts);

    return switch (opts.position) {
        .top => .{
            .x = bounds.x + (bounds.width - dims.width) / 2,
            .y = bounds.y,
            .width = dims.width,
            .height = dims.height,
        },
        .bottom => .{
            .x = bounds.x + (bounds.width - dims.width) / 2,
            .y = bounds.y + bounds.height - dims.height,
            .width = dims.width,
            .height = dims.height,
        },
        .left => .{
            .x = bounds.x,
            .y = bounds.y + (bounds.height - dims.height) / 2,
            .width = dims.width,
            .height = dims.height,
        },
        .right => .{
            .x = bounds.x + bounds.width - dims.width,
            .y = bounds.y + (bounds.height - dims.height) / 2,
            .width = dims.width,
            .height = dims.height,
        },
    };
}

/// Draw legend items horizontally (for top/bottom positions).
fn drawHorizontal(
    ctx: *DrawContext,
    items: []const Legend.Item,
    layout: Legend.Bounds,
    opts: Legend.Options,
) void {
    std.debug.assert(items.len > 0);

    const item_height = @max(opts.item_size, opts.font_size);
    const y_center = layout.y + opts.padding + item_height / 2;

    var x = layout.x + opts.padding;

    for (items, 0..) |item, i| {
        if (i > 0) x += opts.spacing;

        // Draw marker
        drawMarker(ctx, x, y_center, opts.item_size, item.color, item.shape);
        x += opts.item_size + opts.item_gap;

        // Draw label - vertically centered with marker
        _ = ctx.drawTextVCentered(item.label, x, y_center, opts.color, opts.font_size);
        // Use actual text measurement for accurate positioning
        const text_width = ctx.measureText(item.label, opts.font_size);
        x += text_width;
    }
}

/// Draw legend items vertically (for left/right positions).
fn drawVertical(
    ctx: *DrawContext,
    items: []const Legend.Item,
    layout: Legend.Bounds,
    opts: Legend.Options,
) void {
    std.debug.assert(items.len > 0);

    const item_height = @max(opts.item_size, opts.font_size);
    // Add spacing between items in the height calculation
    const row_height = item_height + opts.spacing;
    var y = layout.y + opts.padding + item_height / 2;

    for (items, 0..) |item, i| {
        // Add row spacing for all items after the first
        if (i > 0) y += row_height;

        const x = layout.x + opts.padding;

        // Draw marker
        drawMarker(ctx, x, y, opts.item_size, item.color, item.shape);

        // Draw label - vertically centered with marker
        const label_x = x + opts.item_size + opts.item_gap;
        _ = ctx.drawTextVCentered(item.label, label_x, y, opts.color, opts.font_size);
    }
}
fn drawMarker(
    ctx: *DrawContext,
    x: f32,
    y_center: f32,
    size: f32,
    color: Color,
    shape: Legend.Shape,
) void {
    std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y_center));
    std.debug.assert(size > 0);

    switch (shape) {
        .rect => {
            ctx.fillRect(x, y_center - size / 2, size, size, color);
        },
        .circle => {
            // Draw filled circle centered at (x + radius, y_center)
            // Uses adaptive LOD - small legend markers get fewer segments
            const radius = size / 2;
            ctx.fillCircleAdaptive(x + radius, y_center, radius, color);
        },
        .line => {
            // Draw a horizontal line with a point marker
            const line_y = y_center;
            ctx.strokeLine(x, line_y, x + size, line_y, 2.0, color);
            // Draw small circle/square at center
            const marker_size = size * 0.4;
            ctx.fillRect(
                x + size / 2 - marker_size / 2,
                y_center - marker_size / 2,
                marker_size,
                marker_size,
                color,
            );
        },
    }
}

/// Render text using DrawContext.
/// Uses real text rendering when TextSystem is available, otherwise
/// falls back to placeholder rectangles for backwards compatibility.
fn drawTextSimple(
    ctx: *DrawContext,
    text: []const u8,
    x: f32,
    y: f32,
    color: Color,
    font_size: f32,
) void {
    std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
    std.debug.assert(font_size > 0);

    // Use DrawContext's drawText which handles TextSystem availability
    _ = ctx.drawText(text, x, y, color, font_size);
}

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create legend items from series data.
/// Caller provides output buffer to avoid allocation.
pub fn itemsFromSeries(
    comptime SeriesType: type,
    series: []const SeriesType,
    palette: []const Color,
    out_items: []Legend.Item,
) []Legend.Item {
    std.debug.assert(series.len <= out_items.len);
    std.debug.assert(series.len <= MAX_LEGEND_ITEMS);

    const count = @min(series.len, out_items.len);
    for (series[0..count], 0..) |*s, i| {
        const color = if (hasColorField(SeriesType, s)) s.color else palette[i % palette.len];
        out_items[i] = Legend.Item.init(s.getName(), color);
    }

    return out_items[0..count];
}

/// Check if a type has a color field.
fn hasColorField(comptime T: type, ptr: *const T) bool {
    _ = ptr;
    return @hasField(T, "color");
}

// =============================================================================
// Tests
// =============================================================================

test "Legend.Options defaults" {
    const opts = Legend.Options{};
    try std.testing.expectEqual(Legend.Position.bottom, opts.position);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), opts.spacing, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), opts.item_size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), opts.font_size, 0.001);
    try std.testing.expect(opts.background == null);
}

test "Legend.Item init" {
    const item = Legend.Item.init("Revenue", Color.hex(0x4285f4));
    try std.testing.expectEqualStrings("Revenue", item.label);
    try std.testing.expectEqual(Legend.Shape.rect, item.shape);
}

test "Legend.Item initWithShape" {
    const item = Legend.Item.initWithShape("Expenses", Color.hex(0xea4335), .line);
    try std.testing.expectEqualStrings("Expenses", item.label);
    try std.testing.expectEqual(Legend.Shape.line, item.shape);
}

test "Legend.Bounds creation" {
    const bounds = Legend.Bounds{
        .x = 10,
        .y = 20,
        .width = 400,
        .height = 50,
    };
    try std.testing.expectEqual(@as(f32, 10), bounds.x);
    try std.testing.expectEqual(@as(f32, 20), bounds.y);
    try std.testing.expectEqual(@as(f32, 400), bounds.width);
    try std.testing.expectEqual(@as(f32, 50), bounds.height);
}

test "Legend.calculateDimensions horizontal" {
    const items = [_]Legend.Item{
        Legend.Item.init("One", Color.hex(0xff0000)),
        Legend.Item.init("Two", Color.hex(0x00ff00)),
    };

    const opts = Legend.Options{ .position = .bottom };
    const dims = Legend.calculateDimensions(&items, opts);

    // Should have non-zero dimensions
    try std.testing.expect(dims.width > 0);
    try std.testing.expect(dims.height > 0);

    // Width should be greater than height for horizontal layout
    try std.testing.expect(dims.width > dims.height);
}

test "Legend.calculateDimensions vertical" {
    const items = [_]Legend.Item{
        Legend.Item.init("One", Color.hex(0xff0000)),
        Legend.Item.init("Two", Color.hex(0x00ff00)),
        Legend.Item.init("Three", Color.hex(0x0000ff)),
    };

    const opts = Legend.Options{ .position = .left };
    const dims = Legend.calculateDimensions(&items, opts);

    // Should have non-zero dimensions
    try std.testing.expect(dims.width > 0);
    try std.testing.expect(dims.height > 0);

    // Height should be larger for vertical layout with 3 items
    try std.testing.expect(dims.height > dims.width);
}

test "Legend positions" {
    try std.testing.expectEqual(@intFromEnum(Legend.Position.top), 0);
    try std.testing.expectEqual(@intFromEnum(Legend.Position.bottom), 1);
    try std.testing.expectEqual(@intFromEnum(Legend.Position.left), 2);
    try std.testing.expectEqual(@intFromEnum(Legend.Position.right), 3);
}

test "Legend shapes" {
    try std.testing.expectEqual(@intFromEnum(Legend.Shape.rect), 0);
    try std.testing.expectEqual(@intFromEnum(Legend.Shape.circle), 1);
    try std.testing.expectEqual(@intFromEnum(Legend.Shape.line), 2);
}

test "calculateLayout top position" {
    const items = [_]Legend.Item{
        Legend.Item.init("Test", Color.hex(0xff0000)),
    };

    const bounds = Legend.Bounds{ .x = 0, .y = 0, .width = 400, .height = 300 };
    const opts = Legend.Options{ .position = .top };

    const layout = calculateLayout(&items, bounds, opts);

    // Should be at top, centered horizontally
    try std.testing.expectEqual(@as(f32, 0), layout.y);
    try std.testing.expect(layout.x > 0); // Centered means x > 0 for small legend
}

test "calculateLayout bottom position" {
    const items = [_]Legend.Item{
        Legend.Item.init("Test", Color.hex(0xff0000)),
    };

    const bounds = Legend.Bounds{ .x = 0, .y = 0, .width = 400, .height = 300 };
    const opts = Legend.Options{ .position = .bottom };

    const layout = calculateLayout(&items, bounds, opts);

    // Should be at bottom
    try std.testing.expect(layout.y + layout.height <= 300);
    try std.testing.expect(layout.y > 0); // Not at y=0 since it's at bottom
}

test "calculateLayout left position" {
    const items = [_]Legend.Item{
        Legend.Item.init("Test", Color.hex(0xff0000)),
    };

    const bounds = Legend.Bounds{ .x = 0, .y = 0, .width = 400, .height = 300 };
    const opts = Legend.Options{ .position = .left };

    const layout = calculateLayout(&items, bounds, opts);

    // Should be at left edge
    try std.testing.expectEqual(@as(f32, 0), layout.x);
    try std.testing.expect(layout.y > 0); // Centered vertically
}

test "calculateLayout right position" {
    const items = [_]Legend.Item{
        Legend.Item.init("Test", Color.hex(0xff0000)),
    };

    const bounds = Legend.Bounds{ .x = 0, .y = 0, .width = 400, .height = 300 };
    const opts = Legend.Options{ .position = .right };

    const layout = calculateLayout(&items, bounds, opts);

    // Should be at right edge
    try std.testing.expect(layout.x + layout.width <= 400);
    try std.testing.expect(layout.x > 0); // Not at x=0 since it's on right
}
