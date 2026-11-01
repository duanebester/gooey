//! Drag and drop example, on the core.
//!
//! Cards drag between two lists. A card carries its item id as the drag
//! payload (contract §5); each list is a drop target for item ids that
//! restyles while a card is over it, the dragged card dims, and a preview
//! follows the pointer on a `.drag` layer that the pointer passes through.

const std = @import("std");
const gooey = @import("gooey");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Effects = core.Effects;
const Color = ui.Color;

const assert = std.debug.assert;

/// What a card carries while it is dragged: an index into `items`.
pub const ItemId = u32;

pub const Item = struct { name: []const u8, color: Color };

pub const items = [_]Item{
    .{ .name = "Apple", .color = .rgb(0.9, 0.3, 0.3) },
    .{ .name = "Banana", .color = .rgb(0.95, 0.85, 0.3) },
    .{ .name = "Cherry", .color = .rgb(0.8, 0.2, 0.4) },
    .{ .name = "Date", .color = .rgb(0.6, 0.4, 0.2) },
};

pub const Side = enum(u8) { left, right };

/// One list's item ids in display order. Every item is in exactly one list.
pub const List = struct {
    ids: [items.len]ItemId = undefined,
    count: u32 = 0,

    pub fn slice(self: *const List) []const ItemId {
        assert(self.count <= items.len);
        return self.ids[0..self.count];
    }

    fn append(self: *List, id: ItemId) void {
        assert(id < items.len);
        assert(self.count < items.len);
        self.ids[self.count] = id;
        self.count += 1;
    }

    /// Remove `id` if this list holds it, keeping the others' order.
    fn remove(self: *List, id: ItemId) bool {
        assert(self.count <= items.len);
        const index = std.mem.indexOfScalar(ItemId, self.slice(), id) orelse return false;
        const tail = self.ids[index + 1 .. self.count];
        std.mem.copyForwards(ItemId, self.ids[index .. self.count - 1], tail);
        self.count -= 1;
        return true;
    }
};

pub const State = struct {
    lists: [2]List = .{ allItems(), .{} },

    fn allItems() List {
        var all: List = .{};
        for (0..items.len) |id| all.append(@intCast(id));
        return all;
    }

    pub fn list(self: *const State, side: Side) *const List {
        return &self.lists[@backingInt(side)];
    }

    /// Move the dropped item to the end of `side`'s list, as 0.3.1 did.
    pub fn dropOn(self: *State, side: Side, effects: *Effects) void {
        const id = effects.dropPayload(ItemId) orelse return;
        assert(id < items.len);
        self.move(id, side);
    }

    pub fn move(self: *State, id: ItemId, side: Side) void {
        assert(id < items.len);
        const removed = self.lists[0].remove(id) or self.lists[1].remove(id);
        assert(removed);
        self.lists[@backingInt(side)].append(id);
        assert(self.lists[0].count + self.lists[1].count == items.len);
    }
};

pub const App = core.App(State, render, .{
    .title = "Drag & Drop Demo",
    .width = 700,
    .height = 500,
    .limits = .small,
});

/// The generated entry point (contract §7).
pub const main = App.main;

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(32),
        .gap = 24,
        .background = .{ .rgba = .rgb(0.12, 0.12, 0.14) },
    } }, .{
        ui.text("Drag & Drop Demo", .{ .size = 28, .color = .{ .rgba = .white } }),
        ui.text("Drag items between the two lists", .{
            .size = 14,
            .color = .{ .rgba = .rgb(0.6, 0.6, 0.6) },
        }),
        ui.box(.{ .style = .{ .direction = .row, .gap = 32 } }, .{
            ItemList{ .side = .left, .title = "Fruits" },
            ItemList{ .side = .right, .title = "Basket" },
        }),
        DragPreview{},
    }));
}

/// A list is a drop target for item ids, highlighted while a card is over it.
const ItemList = struct {
    side: Side,
    title: []const u8,

    pub fn render(self: ItemList, cx: *Cx) void {
        const key: core.Key = .{ .name = @tagName(self.side) };
        const over = if (cx.drag(ItemId)) |drag| drag.over == cx.id(key) else false;
        const ids = cx.state(State).list(self.side).slice();
        cx.render(ui.box(.{
            .key = key,
            .drop_target = .of(ItemId, cx.on(State.dropOn, .{ .arg = self.side })),
            .style = .{
                .width_min = 200,
                .height = .{ .grow = 1 },
                .height_min = 300,
                .padding = .all(16),
                .gap = 8,
                .corner_radius = .all(12),
                .background = .{
                    .rgba = if (over) .rgb(0.25, 0.35, 0.45) else .rgb(0.18, 0.18, 0.2),
                },
                .border = .{
                    .width = 2,
                    .color = .{ .rgba = if (over) .rgb(0.4, 0.6, 0.9) else .rgb(0.25, 0.25, 0.28) },
                },
            },
        }, .{
            ui.box(.{ .style = .{ .padding = .{ .bottom = 8 } } }, .{
                ui.text(self.title, .{ .size = 18, .color = .{ .rgba = .rgb(0.8, 0.8, 0.8) } }),
            }),
            Cards{ .ids = ids },
            ui.when(ids.len == 0, emptyState),
        }));
    }
};

const Cards = struct {
    ids: []const ItemId,

    pub fn render(self: Cards, cx: *Cx) void {
        assert(self.ids.len <= items.len);
        const dragged: ?ItemId = if (cx.drag(ItemId)) |drag| drag.payload else null;
        for (self.ids) |id| {
            assert(id < items.len);
            cx.render(ui.box(.{
                .key = .{ .index = id },
                .draggable = .of(ItemId, id),
                .style = .{
                    .direction = .row,
                    .gap = 12,
                    .alignment = .center_cross,
                    .padding = .symmetric(16, 12),
                    .corner_radius = .all(8),
                    .background = .{ .rgba = items[id].color },
                    .opacity = if (dragged == id) 0.4 else 1,
                },
            }, .{
                DragHandle{},
                ui.text(items[id].name, .{ .size = 16, .color = .{ .rgba = .white } }),
            }));
        }
    }
};

/// Three short lines.
const DragHandle = struct {
    pub fn render(_: DragHandle, cx: *Cx) void {
        const line: ui.Style = .{
            .width = .{ .fixed = 16 },
            .height = .{ .fixed = 2 },
            .background = .{ .rgba = .rgba(1, 1, 1, 0.5) },
            .corner_radius = .all(1),
        };
        cx.render(ui.box(.{ .style = .{ .gap = 3 } }, .{
            ui.box(.{ .style = line }, .{}),
            ui.box(.{ .style = line }, .{}),
            ui.box(.{ .style = line }, .{}),
        }));
    }
};

fn emptyState(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(32),
        .alignment = .center,
    } }, .{
        ui.text("Drop items here", .{ .size = 14, .color = .{ .rgba = .rgb(0.4, 0.4, 0.4) } }),
    }));
}

/// The dragged card at the pointer, above everything and transparent to it,
/// so the list underneath stays the drop target.
const DragPreview = struct {
    pub fn render(_: DragPreview, cx: *Cx) void {
        const drag = cx.drag(ItemId) orelse return;
        assert(drag.payload < items.len);
        const item = items[drag.payload];
        cx.render(ui.box(.{
            .layer = .{
                .kind = .drag,
                .anchor = .{ .window = .{ .x = drag.x - 60, .y = drag.y - 20 } },
                .clip = .escape,
            },
            .style = .{
                .padding = .symmetric(16, 12),
                .corner_radius = .all(8),
                .background = .{ .rgba = item.color },
                .opacity = 0.85,
                .pointer_events = .none,
                .shadow = .{ .blur = 12, .offset_y = 4, .color = .{ .rgba = .rgba(0, 0, 0, 0.4) } },
            },
        }, .{
            ui.text(item.name, .{ .size = 16, .color = .{ .rgba = .white } }),
        }));
    }
};

test "items start on the left and move between lists in order" {
    var state: State = .{};
    try std.testing.expectEqualSlices(ItemId, &.{ 0, 1, 2, 3 }, state.list(.left).slice());
    try std.testing.expectEqual(@as(usize, 0), state.list(.right).slice().len);
    state.move(1, .right);
    state.move(3, .right);
    try std.testing.expectEqualSlices(ItemId, &.{ 0, 2 }, state.list(.left).slice());
    try std.testing.expectEqualSlices(ItemId, &.{ 1, 3 }, state.list(.right).slice());
    // A drop on its own list moves the item to that list's end.
    state.move(0, .left);
    try std.testing.expectEqualSlices(ItemId, &.{ 2, 0 }, state.list(.left).slice());
}
