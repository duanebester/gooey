//! Checkbox - A toggleable boolean input widget
//!
//! Features:
//! - Click to toggle
//! - Optional label
//! - Theme-aware colors
//! - Keyboard accessible (Space/Enter to toggle when focused)
//! - Focus ring indication

const std = @import("std");
const scene_mod = @import("../core/scene.zig");
const layout_types = @import("../layout/types.zig");
const text_mod = @import("../text/mod.zig");

const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Hsla = scene_mod.Hsla;
const GlyphInstance = scene_mod.GlyphInstance;
const Color = layout_types.Color;

// =============================================================================
// Bounds
// =============================================================================

pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Bounds, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }
};

// =============================================================================
// Styling
// =============================================================================

pub const Style = struct {
    /// Size of the checkbox box (width and height)
    box_size: f32 = 18,
    /// Inner padding ratio (0.0 - 0.5) for filled square style
    inner_padding: f32 = 0.22,
    /// Border width
    border_width: f32 = 1.5,
    /// Corner radius
    corner_radius: f32 = 4,
    /// Gap between checkbox and label
    label_gap: f32 = 8,

    // Colors - stored as Color for theme compatibility
    // Converted to Hsla at render time
    background: Color = Color.white,
    background_checked: Color = Color.rgb(0.2, 0.5, 1.0), // Blue
    border_color: Color = Color.rgb(0.75, 0.75, 0.75), // Gray
    border_color_focused: Color = Color.rgb(0.2, 0.5, 1.0),
    checkmark_color: Color = Color.white,
    label_color: Color = Color.rgb(0.2, 0.2, 0.2),
};

// =============================================================================
// Checkbox Widget
// =============================================================================

pub const Checkbox = struct {
    allocator: std.mem.Allocator,

    /// Unique identifier
    id: []const u8,

    /// Position and size (set during layout)
    bounds: Bounds,

    /// Visual styling
    style: Style,

    /// Current checked state
    checked: bool,

    /// Focus state
    focused: bool,

    /// Optional label text
    label: ?[]const u8,

    /// Callback when value changes
    on_change: ?*const fn (bool) void,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: []const u8) Self {
        return .{
            .allocator = allocator,
            .id = id,
            .bounds = .{ .x = 0, .y = 0, .width = 18, .height = 18 },
            .style = .{},
            .checked = false,
            .focused = false,
            .label = null,
            .on_change = null,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    // =========================================================================
    // State Management
    // =========================================================================

    pub fn isChecked(self: *const Self) bool {
        return self.checked;
    }

    pub fn setChecked(self: *Self, value: bool) void {
        if (self.checked != value) {
            self.checked = value;
            self.notifyChange();
        }
    }

    pub fn toggle(self: *Self) void {
        self.checked = !self.checked;
        self.notifyChange();
    }

    fn notifyChange(self: *Self) void {
        if (self.on_change) |callback| {
            callback(self.checked);
        }
    }

    pub fn setLabel(self: *Self, text: ?[]const u8) void {
        self.label = text;
    }

    // =========================================================================
    // Focus Management
    // =========================================================================

    pub fn focus(self: *Self) void {
        self.focused = true;
    }

    pub fn blur(self: *Self) void {
        self.focused = false;
    }

    pub fn isFocused(self: *const Self) bool {
        return self.focused;
    }

    // =========================================================================
    // Hit Testing
    // =========================================================================

    pub fn getBounds(self: *const Self) Bounds {
        return self.bounds;
    }

    pub fn containsPoint(self: *const Self, x: f32, y: f32) bool {
        return self.bounds.contains(x, y);
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    pub fn render(self: *Self, scene: *Scene, text_system: anytype, scale_factor: f32) !void {
        const box_size = self.style.box_size;
        const x = self.bounds.x;
        const y = self.bounds.y;

        // Convert theme colors to Hsla
        const bg_color = if (self.checked)
            colorToHsla(self.style.background_checked)
        else
            colorToHsla(self.style.background);

        const border_color = if (self.focused)
            colorToHsla(self.style.border_color_focused)
        else
            colorToHsla(self.style.border_color);

        // Draw the checkbox box
        try scene.insertQuad(Quad{
            .bounds_origin_x = x,
            .bounds_origin_y = y,
            .bounds_size_width = box_size,
            .bounds_size_height = box_size,
            .background = bg_color,
            .border_color = border_color,
            .corner_radii = .{
                .top_left = self.style.corner_radius,
                .top_right = self.style.corner_radius,
                .bottom_left = self.style.corner_radius,
                .bottom_right = self.style.corner_radius,
            },
            .border_widths = .{
                .top = self.style.border_width,
                .right = self.style.border_width,
                .bottom = self.style.border_width,
                .left = self.style.border_width,
            },
        });

        // Draw filled square if checked
        if (self.checked) {
            try self.renderCheckmark(scene, x, y, box_size);
        }

        // Draw label if present
        if (self.label) |label_text| {
            if (label_text.len > 0) {
                const label_x = x + box_size + self.style.label_gap;
                const label_y = y + box_size * 0.72;
                const label_color = colorToHsla(self.style.label_color);
                _ = try text_mod.renderText(
                    scene,
                    text_system,
                    label_text,
                    label_x,
                    label_y,
                    scale_factor,
                    label_color,
                    .{ .clipped = false },
                );
            }
        }
    }

    fn renderCheckmark(self: *Self, scene: *Scene, x: f32, y: f32, size: f32) !void {
        const color = colorToHsla(self.style.checkmark_color);
        const padding = size * self.style.inner_padding;
        const inner_size = size - (padding * 2);

        // Centered filled square with slightly rounded corners
        try scene.insertQuad(Quad{
            .bounds_origin_x = x + padding,
            .bounds_origin_y = y + padding,
            .bounds_size_width = inner_size,
            .bounds_size_height = inner_size,
            .background = color,
            .corner_radii = .{
                .top_left = self.style.corner_radius * 0.4,
                .top_right = self.style.corner_radius * 0.4,
                .bottom_left = self.style.corner_radius * 0.4,
                .bottom_right = self.style.corner_radius * 0.4,
            },
        });
    }
};

// =============================================================================
// Color Conversion (Color -> Hsla)
// =============================================================================

fn colorToHsla(color: Color) Hsla {
    const r = color.r;
    const g = color.g;
    const b = color.b;

    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const l = (max_val + min_val) / 2.0;

    if (max_val == min_val) {
        return Hsla{ .h = 0, .s = 0, .l = l, .a = color.a };
    }

    const d = max_val - min_val;
    const s = if (l > 0.5) d / (2.0 - max_val - min_val) else d / (max_val + min_val);

    var h: f32 = 0;
    if (max_val == r) {
        h = (g - b) / d + (if (g < b) @as(f32, 6.0) else @as(f32, 0.0));
    } else if (max_val == g) {
        h = (b - r) / d + 2.0;
    } else {
        h = (r - g) / d + 4.0;
    }
    h /= 6.0;

    return Hsla{ .h = h, .s = s, .l = l, .a = color.a };
}

// =============================================================================
// Tests
// =============================================================================

test "Checkbox basic operations" {
    const allocator = std.testing.allocator;
    var cb = Checkbox.init(allocator, "test");
    defer cb.deinit();

    try std.testing.expect(!cb.isChecked());
    cb.toggle();
    try std.testing.expect(cb.isChecked());
    cb.setChecked(false);
    try std.testing.expect(!cb.isChecked());
}

test "Checkbox focus" {
    const allocator = std.testing.allocator;
    var cb = Checkbox.init(allocator, "test");
    defer cb.deinit();

    try std.testing.expect(!cb.isFocused());
    cb.focus();
    try std.testing.expect(cb.isFocused());
    cb.blur();
    try std.testing.expect(!cb.isFocused());
}
