//! ScrollContainer - A scrollable viewport for overflow content
//!
//! Features:
//! - Vertical and/or horizontal scrolling
//! - Scroll wheel support
//! - Scrollbar track and thumb rendering
//! - Content clipping
//! - Momentum/inertia (future)
//!
//! The scroll container clips its children to its bounds and allows
//! scrolling when content exceeds the viewport size.

const std = @import("std");
const builtin = @import("builtin");
const scene_mod = @import("../scene/mod.zig");
const layout_types = @import("../layout/types.zig");

const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Hsla = scene_mod.Hsla;
const ContentMask = scene_mod.ContentMask;
const Color = layout_types.Color;
const BoundingBox = layout_types.BoundingBox;

// =============================================================================
// Styling
// =============================================================================

pub const Style = struct {
    /// Show vertical scrollbar
    vertical: bool = true,
    /// Show horizontal scrollbar
    horizontal: bool = false,
    /// Scrollbar width/height
    scrollbar_size: f32 = 8,
    /// Padding around scrollbar
    scrollbar_padding: f32 = 2,
    /// Minimum thumb size
    min_thumb_size: f32 = 30,
    /// Track color
    track_color: Color = Color.rgba(0, 0, 0, 0.05),
    /// Thumb color
    thumb_color: Color = Color.rgba(0, 0, 0, 0.3),
    /// Thumb color when hovered
    thumb_hover_color: Color = Color.rgba(0, 0, 0, 0.5),
    /// Thumb corner radius
    thumb_radius: f32 = 4,
    /// Auto-hide scrollbars when not scrolling
    auto_hide: bool = false,
};

// =============================================================================
// Scroll State
// =============================================================================

pub const ScrollState = struct {
    /// Current scroll offset
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    /// Content size (set after layout)
    content_width: f32 = 0,
    content_height: f32 = 0,
    /// Viewport size (the visible area)
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    /// Is thumb being dragged?
    dragging_vertical: bool = false,
    dragging_horizontal: bool = false,
    /// Drag start position
    drag_start_y: f32 = 0,
    drag_start_x: f32 = 0,
    drag_start_offset_y: f32 = 0,
    drag_start_offset_x: f32 = 0,
    /// Hover state
    thumb_hovered: bool = false,

    const Self = @This();

    /// Maximum scroll offset for vertical
    pub fn maxScrollY(self: *const Self) f32 {
        return @max(0, self.content_height - self.viewport_height);
    }

    /// Maximum scroll offset for horizontal
    pub fn maxScrollX(self: *const Self) f32 {
        return @max(0, self.content_width - self.viewport_width);
    }

    /// Can scroll vertically?
    pub fn canScrollY(self: *const Self) bool {
        return self.content_height > self.viewport_height;
    }

    /// Can scroll horizontally?
    pub fn canScrollX(self: *const Self) bool {
        return self.content_width > self.viewport_width;
    }

    /// Scroll by delta (e.g., from scroll wheel)
    pub fn scrollBy(self: *Self, delta_x: f32, delta_y: f32) void {
        // macOS uses "natural scrolling" (scroll up = content moves down)
        // Linux/Windows use traditional scrolling (scroll up = content moves up)
        const direction: f32 = if (builtin.os.tag == .macos) -1.0 else 1.0;
        self.offset_x = std.math.clamp(self.offset_x + delta_x * direction, 0, self.maxScrollX());
        self.offset_y = std.math.clamp(self.offset_y + delta_y * direction, 0, self.maxScrollY());
    }

    /// Scroll to absolute position
    pub fn scrollTo(self: *Self, x: f32, y: f32) void {
        self.offset_x = std.math.clamp(x, 0, self.maxScrollX());
        self.offset_y = std.math.clamp(y, 0, self.maxScrollY());
    }

    /// Scroll to top
    pub fn scrollToTop(self: *Self) void {
        self.offset_y = 0;
    }

    /// Scroll to bottom
    pub fn scrollToBottom(self: *Self) void {
        self.offset_y = self.maxScrollY();
    }

    /// Get scroll percentage (0.0 - 1.0)
    pub fn scrollPercentY(self: *const Self) f32 {
        const max = self.maxScrollY();
        if (max <= 0) return 0;
        return self.offset_y / max;
    }

    pub fn scrollPercentX(self: *const Self) f32 {
        const max = self.maxScrollX();
        if (max <= 0) return 0;
        return self.offset_x / max;
    }
};

// =============================================================================
// ScrollContainer Widget
// =============================================================================

pub const ScrollContainer = struct {
    allocator: std.mem.Allocator,

    /// Unique identifier
    id: []const u8,

    /// Viewport bounds (set during layout)
    bounds: BoundingBox,

    /// Scroll state
    state: ScrollState,

    /// Visual styling
    style: Style,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: []const u8) Self {
        return .{
            .allocator = allocator,
            .id = id,
            .bounds = .{},
            .state = .{},
            .style = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    // =========================================================================
    // Layout Integration
    // =========================================================================

    /// Set viewport size (call after layout)
    pub fn setViewport(self: *Self, width: f32, height: f32) void {
        self.state.viewport_width = width;
        self.state.viewport_height = height;
        // Clamp scroll to new bounds
        self.state.offset_x = std.math.clamp(self.state.offset_x, 0, self.state.maxScrollX());
        self.state.offset_y = std.math.clamp(self.state.offset_y, 0, self.state.maxScrollY());
    }

    /// Set content size (call after measuring children)
    pub fn setContentSize(self: *Self, width: f32, height: f32) void {
        self.state.content_width = width;
        self.state.content_height = height;
        // Clamp scroll to new bounds (content may have shrunk)
        self.state.offset_x = std.math.clamp(self.state.offset_x, 0, self.state.maxScrollX());
        self.state.offset_y = std.math.clamp(self.state.offset_y, 0, self.state.maxScrollY());
    }

    /// Get the current scroll offset
    pub fn getScrollOffset(self: *const Self) struct { x: f32, y: f32 } {
        return .{ .x = self.state.offset_x, .y = self.state.offset_y };
    }

    /// Get clip bounds for children
    pub fn getClipBounds(self: *const Self) ContentMask.ClipBounds {
        // Reduce viewport for scrollbar space
        var width = self.bounds.width;
        var height = self.bounds.height;

        if (self.style.vertical and self.state.canScrollY()) {
            width -= self.style.scrollbar_size + self.style.scrollbar_padding;
        }
        if (self.style.horizontal and self.state.canScrollX()) {
            height -= self.style.scrollbar_size + self.style.scrollbar_padding;
        }

        return .{
            .x = self.bounds.x,
            .y = self.bounds.y,
            .width = width,
            .height = height,
        };
    }

    // =========================================================================
    // Event Handling
    // =========================================================================

    /// Handle scroll wheel event. Returns true if handled.
    pub fn handleScroll(self: *Self, delta_x: f64, delta_y: f64) bool {
        const can_scroll_x = self.style.horizontal and self.state.canScrollX();
        const can_scroll_y = self.style.vertical and self.state.canScrollY();

        if (!can_scroll_x and !can_scroll_y) return false;

        const dx: f32 = if (can_scroll_x) @floatCast(delta_x) else 0;
        const dy: f32 = if (can_scroll_y) @floatCast(delta_y) else 0;

        if (dx == 0 and dy == 0) return false;

        self.state.scrollBy(dx, dy);
        return true;
    }

    /// Check if point is inside scrollbar thumb (for drag detection)
    pub fn hitTestThumb(self: *const Self, x: f32, y: f32) ?enum { vertical, horizontal } {
        if (self.style.vertical and self.state.canScrollY()) {
            const thumb = self.getVerticalThumbBounds();
            if (x >= thumb.x and x < thumb.x + thumb.width and
                y >= thumb.y and y < thumb.y + thumb.height)
            {
                return .vertical;
            }
        }
        if (self.style.horizontal and self.state.canScrollX()) {
            const thumb = self.getHorizontalThumbBounds();
            if (x >= thumb.x and x < thumb.x + thumb.width and
                y >= thumb.y and y < thumb.y + thumb.height)
            {
                return .horizontal;
            }
        }
        return null;
    }

    /// Start dragging the scrollbar thumb
    pub fn startDrag(self: *Self, which: enum { vertical, horizontal }, mouse_x: f32, mouse_y: f32) void {
        switch (which) {
            .vertical => {
                self.state.dragging_vertical = true;
                self.state.drag_start_y = mouse_y;
                self.state.drag_start_offset_y = self.state.offset_y;
            },
            .horizontal => {
                self.state.dragging_horizontal = true;
                self.state.drag_start_x = mouse_x;
                self.state.drag_start_offset_x = self.state.offset_x;
            },
        }
    }

    /// Update drag position
    pub fn updateDrag(self: *Self, mouse_x: f32, mouse_y: f32) void {
        if (self.state.dragging_vertical) {
            const track_height = self.bounds.height - self.style.scrollbar_padding * 2;
            const thumb_height = self.getThumbSize(.vertical);
            const scroll_range = track_height - thumb_height;

            if (scroll_range > 0) {
                const delta = mouse_y - self.state.drag_start_y;
                const scroll_delta = (delta / scroll_range) * self.state.maxScrollY();
                self.state.offset_y = std.math.clamp(
                    self.state.drag_start_offset_y + scroll_delta,
                    0,
                    self.state.maxScrollY(),
                );
            }
        }
        if (self.state.dragging_horizontal) {
            const track_width = self.bounds.width - self.style.scrollbar_padding * 2;
            const thumb_width = self.getThumbSize(.horizontal);
            const scroll_range = track_width - thumb_width;

            if (scroll_range > 0) {
                const delta = mouse_x - self.state.drag_start_x;
                const scroll_delta = (delta / scroll_range) * self.state.maxScrollX();
                self.state.offset_x = std.math.clamp(
                    self.state.drag_start_offset_x + scroll_delta,
                    0,
                    self.state.maxScrollX(),
                );
            }
        }
    }

    /// End dragging
    pub fn endDrag(self: *Self) void {
        self.state.dragging_vertical = false;
        self.state.dragging_horizontal = false;
    }

    /// Handle click on scrollbar track (area outside thumb)
    /// Returns true if click was on track and scrolling occurred
    pub fn handleTrackClick(self: *Self, x: f32, y: f32) bool {
        // Check vertical track
        if (self.style.vertical and self.state.canScrollY()) {
            const track_x = self.bounds.x + self.bounds.width - self.style.scrollbar_size - self.style.scrollbar_padding;
            const track_y = self.bounds.y + self.style.scrollbar_padding;
            const track_width = self.style.scrollbar_size;
            const track_height = self.bounds.height - self.style.scrollbar_padding * 2;

            if (track_height <= 0) return false;

            // Check if click is in vertical track area
            if (x >= track_x and x < track_x + track_width and
                y >= track_y and y < track_y + track_height)
            {
                const thumb = self.getVerticalThumbBounds();

                // Only handle if click is NOT on thumb (thumb clicks are handled by startDrag)
                if (y < thumb.y or y >= thumb.y + thumb.height) {
                    // Calculate target scroll position based on click position
                    const click_percent = (y - track_y) / track_height;
                    const target_offset = click_percent * self.state.maxScrollY();

                    // Jump to position (could also do page scroll here)
                    self.state.scrollTo(self.state.offset_x, target_offset);
                    return true;
                }
            }
        }

        // Check horizontal track
        if (self.style.horizontal and self.state.canScrollX()) {
            const track_x = self.bounds.x + self.style.scrollbar_padding;
            const track_y = self.bounds.y + self.bounds.height - self.style.scrollbar_size - self.style.scrollbar_padding;
            const track_width = self.bounds.width - self.style.scrollbar_padding * 2;
            const track_height = self.style.scrollbar_size;

            if (track_width <= 0) return false;

            // Check if click is in horizontal track area
            if (x >= track_x and x < track_x + track_width and
                y >= track_y and y < track_y + track_height)
            {
                const thumb = self.getHorizontalThumbBounds();

                // Only handle if click is NOT on thumb
                if (x < thumb.x or x >= thumb.x + thumb.width) {
                    // Calculate target scroll position based on click position
                    const click_percent = (x - track_x) / track_width;
                    const target_offset = click_percent * self.state.maxScrollX();

                    // Jump to position
                    self.state.scrollTo(target_offset, self.state.offset_y);
                    return true;
                }
            }
        }

        return false;
    }

    // =========================================================================
    // Scrollbar Geometry
    // =========================================================================

    fn getThumbSize(self: *const Self, axis: enum { vertical, horizontal }) f32 {
        return switch (axis) {
            .vertical => blk: {
                const track_height = self.bounds.height - self.style.scrollbar_padding * 2;
                const ratio = self.state.viewport_height / self.state.content_height;
                break :blk @max(self.style.min_thumb_size, track_height * ratio);
            },
            .horizontal => blk: {
                const track_width = self.bounds.width - self.style.scrollbar_padding * 2;
                const ratio = self.state.viewport_width / self.state.content_width;
                break :blk @max(self.style.min_thumb_size, track_width * ratio);
            },
        };
    }

    fn getVerticalThumbBounds(self: *const Self) BoundingBox {
        const track_x = self.bounds.x + self.bounds.width - self.style.scrollbar_size - self.style.scrollbar_padding;
        const track_y = self.bounds.y + self.style.scrollbar_padding;
        const track_height = self.bounds.height - self.style.scrollbar_padding * 2;

        const thumb_height = self.getThumbSize(.vertical);
        const scroll_range = track_height - thumb_height;
        const thumb_y = track_y + (scroll_range * self.state.scrollPercentY());

        return .{
            .x = track_x,
            .y = thumb_y,
            .width = self.style.scrollbar_size,
            .height = thumb_height,
        };
    }

    fn getHorizontalThumbBounds(self: *const Self) BoundingBox {
        const track_x = self.bounds.x + self.style.scrollbar_padding;
        const track_y = self.bounds.y + self.bounds.height - self.style.scrollbar_size - self.style.scrollbar_padding;
        const track_width = self.bounds.width - self.style.scrollbar_padding * 2;

        const thumb_width = self.getThumbSize(.horizontal);
        const scroll_range = track_width - thumb_width;
        const thumb_x = track_x + (scroll_range * self.state.scrollPercentX());

        return .{
            .x = thumb_x,
            .y = track_y,
            .width = thumb_width,
            .height = self.style.scrollbar_size,
        };
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    /// Render scrollbars (call after children are rendered)
    pub fn renderScrollbars(self: *Self, scene: *Scene) !void {
        // Vertical scrollbar
        if (self.style.vertical and self.state.canScrollY()) {
            try self.renderVerticalScrollbar(scene);
        }

        // Horizontal scrollbar
        if (self.style.horizontal and self.state.canScrollX()) {
            try self.renderHorizontalScrollbar(scene);
        }
    }

    fn renderVerticalScrollbar(self: *Self, scene: *Scene) !void {
        const track_x = self.bounds.x + self.bounds.width - self.style.scrollbar_size - self.style.scrollbar_padding;
        const track_y = self.bounds.y + self.style.scrollbar_padding;
        const track_height = self.bounds.height - self.style.scrollbar_padding * 2;

        // Track background (use clipped insert to respect parent scroll container clips)
        try scene.insertQuadClipped(Quad{
            .bounds_origin_x = track_x,
            .bounds_origin_y = track_y,
            .bounds_size_width = self.style.scrollbar_size,
            .bounds_size_height = track_height,
            .background = colorToHsla(self.style.track_color),
            .corner_radii = .{
                .top_left = self.style.thumb_radius,
                .top_right = self.style.thumb_radius,
                .bottom_left = self.style.thumb_radius,
                .bottom_right = self.style.thumb_radius,
            },
        });

        // Thumb
        const thumb = self.getVerticalThumbBounds();
        const thumb_color = if (self.state.dragging_vertical or self.state.thumb_hovered)
            self.style.thumb_hover_color
        else
            self.style.thumb_color;

        try scene.insertQuadClipped(Quad{
            .bounds_origin_x = thumb.x,
            .bounds_origin_y = thumb.y,
            .bounds_size_width = thumb.width,
            .bounds_size_height = thumb.height,
            .background = colorToHsla(thumb_color),
            .corner_radii = .{
                .top_left = self.style.thumb_radius,
                .top_right = self.style.thumb_radius,
                .bottom_left = self.style.thumb_radius,
                .bottom_right = self.style.thumb_radius,
            },
        });
    }

    fn renderHorizontalScrollbar(self: *Self, scene: *Scene) !void {
        const track_x = self.bounds.x + self.style.scrollbar_padding;
        const track_y = self.bounds.y + self.bounds.height - self.style.scrollbar_size - self.style.scrollbar_padding;
        const track_width = self.bounds.width - self.style.scrollbar_padding * 2;

        // Track background (use clipped insert to respect parent scroll container clips)
        try scene.insertQuadClipped(Quad{
            .bounds_origin_x = track_x,
            .bounds_origin_y = track_y,
            .bounds_size_width = track_width,
            .bounds_size_height = self.style.scrollbar_size,
            .background = colorToHsla(self.style.track_color),
            .corner_radii = .{
                .top_left = self.style.thumb_radius,
                .top_right = self.style.thumb_radius,
                .bottom_left = self.style.thumb_radius,
                .bottom_right = self.style.thumb_radius,
            },
        });

        // Thumb
        const thumb = self.getHorizontalThumbBounds();
        const thumb_color = if (self.state.dragging_horizontal or self.state.thumb_hovered)
            self.style.thumb_hover_color
        else
            self.style.thumb_color;

        try scene.insertQuadClipped(Quad{
            .bounds_origin_x = thumb.x,
            .bounds_origin_y = thumb.y,
            .bounds_size_width = thumb.width,
            .bounds_size_height = thumb.height,
            .background = colorToHsla(thumb_color),
            .corner_radii = .{
                .top_left = self.style.thumb_radius,
                .top_right = self.style.thumb_radius,
                .bottom_left = self.style.thumb_radius,
                .bottom_right = self.style.thumb_radius,
            },
        });
    }
};

// =============================================================================
// Color Conversion
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

test "ScrollState basic" {
    var state = ScrollState{};
    state.content_height = 1000;
    state.viewport_height = 300;

    try std.testing.expect(state.canScrollY());
    try std.testing.expectEqual(@as(f32, 700), state.maxScrollY());

    state.scrollBy(0, -100); // scroll down
    try std.testing.expectEqual(@as(f32, 100), state.offset_y);
}

test "ScrollState clamping" {
    var state = ScrollState{};
    state.content_height = 500;
    state.viewport_height = 300;

    state.scrollBy(0, -1000); // try to scroll way past end
    try std.testing.expectEqual(@as(f32, 200), state.offset_y);

    state.scrollBy(0, 1000); // try to scroll way past start
    try std.testing.expectEqual(@as(f32, 0), state.offset_y);
}
