//! Drag & Drop Example
//!
//! Demonstrates:
//! - Draggable items with stable state storage
//! - Drop targets with visual feedback
//! - Moving items between two lists
//! - Drag-over styling (background color change)
//! - Works on macOS, Linux, and WASM

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Gooey = gooey.Gooey;

// =============================================================================
// Item Type - What we're dragging
// =============================================================================

const Item = struct {
    id: u32,
    name: []const u8,
    color: ui.Color,
};

/// Which list side (shared between ItemList and ItemsRenderer)
const Side = enum { left, right };

// =============================================================================
// Application State
// =============================================================================

const MAX_ITEMS = 8;

const AppState = struct {
    // Left list items (stable storage for drag pointers)
    left_items: [MAX_ITEMS]?Item = .{null} ** MAX_ITEMS,
    left_count: usize = 0,

    // Right list items
    right_items: [MAX_ITEMS]?Item = .{null} ** MAX_ITEMS,
    right_count: usize = 0,

    const Self = @This();

    pub fn init() Self {
        var s = Self{};

        // Initialize left list with some items
        const initial_items = [_]Item{
            .{ .id = 1, .name = "Apple", .color = ui.Color.rgb(0.9, 0.3, 0.3) },
            .{ .id = 2, .name = "Banana", .color = ui.Color.rgb(0.95, 0.85, 0.3) },
            .{ .id = 3, .name = "Cherry", .color = ui.Color.rgb(0.8, 0.2, 0.4) },
            .{ .id = 4, .name = "Date", .color = ui.Color.rgb(0.6, 0.4, 0.2) },
        };

        for (initial_items) |item| {
            s.left_items[s.left_count] = item;
            s.left_count += 1;
        }

        return s;
    }

    /// Find and remove an item by ID from either list
    fn removeItem(self: *Self, id: u32) ?Item {
        // Check left list
        for (&self.left_items, 0..) |*slot, i| {
            if (slot.*) |item| {
                if (item.id == id) {
                    const removed = item;
                    // Shift remaining items
                    var j = i;
                    while (j + 1 < self.left_count) : (j += 1) {
                        self.left_items[j] = self.left_items[j + 1];
                    }
                    self.left_items[self.left_count - 1] = null;
                    self.left_count -= 1;
                    return removed;
                }
            }
        }

        // Check right list
        for (&self.right_items, 0..) |*slot, i| {
            if (slot.*) |item| {
                if (item.id == id) {
                    const removed = item;
                    var j = i;
                    while (j + 1 < self.right_count) : (j += 1) {
                        self.right_items[j] = self.right_items[j + 1];
                    }
                    self.right_items[self.right_count - 1] = null;
                    self.right_count -= 1;
                    return removed;
                }
            }
        }

        return null;
    }

    /// Add item to left list
    fn addToLeft(self: *Self, item: Item) void {
        if (self.left_count < MAX_ITEMS) {
            self.left_items[self.left_count] = item;
            self.left_count += 1;
        }
    }

    /// Add item to right list
    fn addToRight(self: *Self, item: Item) void {
        if (self.right_count < MAX_ITEMS) {
            self.right_items[self.right_count] = item;
            self.right_count += 1;
        }
    }

    /// Handle drop on left list
    pub fn onDropLeft(self: *Self, g: *Gooey) void {
        if (g.getActiveDrag()) |drag| {
            if (drag.getValue(Item)) |item| {
                if (self.removeItem(item.id)) |removed| {
                    self.addToLeft(removed);
                }
            }
        }
    }

    /// Handle drop on right list
    pub fn onDropRight(self: *Self, g: *Gooey) void {
        if (g.getActiveDrag()) |drag| {
            if (drag.getValue(Item)) |item| {
                if (self.removeItem(item.id)) |removed| {
                    self.addToRight(removed);
                }
            }
        }
    }

    /// Get mutable pointer to left item at index
    pub fn getLeftItem(self: *Self, index: usize) ?*Item {
        if (index < self.left_count) {
            if (self.left_items[index]) |*item| {
                return item;
            }
        }
        return null;
    }

    /// Get mutable pointer to right item at index
    pub fn getRightItem(self: *Self, index: usize) ?*Item {
        if (index < self.right_count) {
            if (self.right_items[index]) |*item| {
                return item;
            }
        }
        return null;
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState.init();

const App = gooey.App(AppState, &state, render, .{
    .title = "Drag & Drop Demo",
    .width = 700,
    .height = 500,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 32 },
        .gap = 24,
        .direction = .column,
        .background = ui.Color.rgb(0.12, 0.12, 0.14),
    }, .{
        // Title
        ui.text("Drag & Drop Demo", .{
            .size = 28,
            .color = ui.Color.white,
        }),

        ui.text("Drag items between the two lists", .{
            .size = 14,
            .color = ui.Color.rgba(0.6, 0.6, 0.6, 1.0),
        }),

        // Two columns with lists
        ListColumns{},

        // Drag preview overlay (renders on top when dragging)
        DragPreview{},
    });
}

// =============================================================================
// Components
// =============================================================================

const ListColumns = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.hstack(.{
            .gap = 32,
            .alignment = .stretch,
        }, .{
            ItemList{ .side = .left, .title = "Fruits" },
            ItemList{ .side = .right, .title = "Basket" },
        });
    }
};

const ItemList = struct {
    side: Side,
    title: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        const count = if (self.side == .left) s.left_count else s.right_count;

        const drop_handler = if (self.side == .left)
            cx.command(AppState, AppState.onDropLeft)
        else
            cx.command(AppState, AppState.onDropRight);

        // List container (drop target)
        cx.box(.{
            .drop_target = ui.DropTarget.init(Item, drop_handler),
            .background = ui.Color.rgb(0.18, 0.18, 0.2),
            .drag_over_background = ui.Color.rgb(0.25, 0.35, 0.45),
            .corner_radius = 12,
            .padding = .{ .all = 16 },
            .gap = 8,
            .direction = .column,
            .grow = true,
            .min_width = 200,
            .min_height = 300,
            .border_width = 2,
            .border_color = ui.Color.rgb(0.25, 0.25, 0.28),
            .drag_over_border_color = ui.Color.rgb(0.4, 0.6, 0.9),
        }, .{
            // List title
            ui.text(self.title, .{
                .size = 18,
                .color = ui.Color.rgba(0.8, 0.8, 0.8, 1.0),
            }),

            ui.spacerMin(8),

            // Items - render each item
            ItemsRenderer{ .side = self.side, .count = count },

            // Empty state
            ui.when(count == 0, EmptyState{}),

            // Spacer to push content up
            ui.spacer(),
        });
    }
};

const ItemsRenderer = struct {
    side: Side,
    count: usize,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        for (0..self.count) |i| {
            const item_ptr = if (self.side == .left)
                s.getLeftItem(i)
            else
                s.getRightItem(i);

            if (item_ptr) |item| {
                cx.box(.{}, .{
                    DraggableCard{ .item = item },
                });
            }
        }
    }
};

const DraggableCard = struct {
    item: *Item,

    pub fn render(self: @This(), b: *ui.Builder) void {
        const item = self.item;

        // Check if this item is being dragged (for opacity)
        const is_being_dragged = if (b.gooey) |g| blk: {
            if (g.getActiveDrag()) |drag| {
                if (drag.getValue(Item)) |dragged| {
                    break :blk dragged.id == item.id;
                }
            }
            break :blk false;
        } else false;

        b.box(.{
            .draggable = ui.Draggable.init(Item, item),
            .background = item.color,
            .corner_radius = 8,
            .padding = .{ .symmetric = .{ .x = 16, .y = 12 } },
            .opacity = if (is_being_dragged) 0.4 else 1.0,
        }, .{
            DragCardContent{ .item = item },
        });
    }
};

const DragCardContent = struct {
    item: *Item,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.hstack(.{ .gap = 12, .alignment = .center }, .{
            // Drag handle icon (three lines)
            DragHandle{},
            // Item name
            ui.text(self.item.name, .{
                .size = 16,
                .color = ui.Color.white,
            }),
        });
    }
};

const DragHandle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.vstack(.{ .gap = 3 }, .{
            HandleLine{},
            HandleLine{},
            HandleLine{},
        });
    }
};

const HandleLine = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .width = 16,
            .height = 2,
            .background = ui.Color.rgba(1, 1, 1, 0.5),
            .corner_radius = 1,
        }, .{});
    }
};

const EmptyState = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .alignment = .{ .main = .center, .cross = .center },
            .padding = .{ .all = 32 },
            .grow = true,
        }, .{
            ui.text("Drop items here", .{
                .size = 14,
                .color = ui.Color.rgba(0.4, 0.4, 0.4, 1.0),
            }),
        });
    }
};

/// Drag preview - floating element that follows cursor during drag
const DragPreview = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const g = cx.gooey();

        // Only render if there's an active drag
        const drag = g.getActiveDrag() orelse return;

        // Get the dragged item
        const item = drag.getValue(Item) orelse return;

        // Position preview at cursor with slight offset
        const preview_x = drag.cursor_position.x - 60; // Center horizontally
        const preview_y = drag.cursor_position.y - 20; // Slightly above cursor

        cx.box(.{
            .floating = .{
                .offset_x = preview_x,
                .offset_y = preview_y,
                .z_index = 1000, // On top of everything
            },
            .pointer_events = .none, // Don't block drop targets underneath
            .background = item.color,
            .corner_radius = 8,
            .padding = .{ .symmetric = .{ .x = 16, .y = 12 } },
            .opacity = 0.85,
            .shadow = .{
                .blur_radius = 12,
                .color = ui.Color.rgba(0, 0, 0, 0.4),
                .offset_y = 4,
            },
        }, .{
            ui.text(item.name, .{
                .size = 16,
                .color = ui.Color.white,
            }),
        });
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AppState init" {
    const s = AppState.init();
    try std.testing.expectEqual(@as(usize, 4), s.left_count);
    try std.testing.expectEqual(@as(usize, 0), s.right_count);
}

test "AppState remove and add" {
    var s = AppState.init();

    // Remove from left
    const removed = s.removeItem(2); // Banana
    try std.testing.expect(removed != null);
    try std.testing.expectEqual(@as(usize, 3), s.left_count);

    // Add to right
    s.addToRight(removed.?);
    try std.testing.expectEqual(@as(usize, 1), s.right_count);
    try std.testing.expectEqualStrings("Banana", s.right_items[0].?.name);
}
