const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const Color = ui.Color;

const assert = std.debug.assert;

pub const ItemId = u32;

pub const Item = struct { name: []const u8, color: Color };

pub const items = [_]Item{
    .{ .name = "Apple", .color = .rgb(0.9, 0.3, 0.3) },
    .{ .name = "Banana", .color = .rgb(0.95, 0.85, 0.3) },
    .{ .name = "Cherry", .color = .rgb(0.8, 0.2, 0.4) },
    .{ .name = "Date", .color = .rgb(0.6, 0.4, 0.2) },
};

pub const Side = enum(u8) { left, right };

pub const titles = [_][]const u8{ "Fruits", "Basket" };

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

    pub fn dropOn(self: *State, side: Side, effects: *Effects) void {
        const id = effects.dropPayload(ItemId) orelse return;
        assert(id < items.len);
        self.move(id, side);
        const event = effects.inputEvent() orelse return;
        if (event.* == .key_down) {
            effects.announce(drop_messages[@backingInt(side)][id], .assertive);
        }
    }

    pub fn pickUp(_: *State, card: gooey.ElementId, effects: *Effects) void {
        const event = effects.inputEvent() orelse return;
        if (event.* != .key_down) return;
        const key = &event.key_down;
        if (key.key != .space or key.is_repeat) return;
        if (key.modifiers.cmd or key.modifiers.ctrl or key.modifiers.alt) return;
        if (!effects.startDrag(card)) return;
        effects.announce(pick_up_message, .assertive);
    }

    pub fn move(self: *State, id: ItemId, side: Side) void {
        assert(id < items.len);
        const removed = self.lists[0].remove(id) or self.lists[1].remove(id);
        assert(removed);
        self.lists[@backingInt(side)].append(id);
        assert(self.lists[0].count + self.lists[1].count == items.len);
    }
};

const pick_up_message = "Picked up. Tab or arrows choose a list, Space drops, Escape cancels.";

const drop_messages = blk: {
    var messages: [2][items.len][]const u8 = undefined;
    for (titles, 0..) |title, side| {
        for (items, 0..) |item, id| messages[side][id] = item.name ++ " moved to " ++ title;
    }
    break :blk messages;
};

pub const App = gooey.App(State, render, .{
    .title = "Drag & Drop Demo",
    .width = 700,
    .height = 500,
    .limits = .small,
});

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
            ItemList{ .side = .left },
            ItemList{ .side = .right },
        }),
        DragPreview{},
    }));
}

const ItemList = struct {
    side: Side,

    pub fn render(self: ItemList, cx: *Cx) void {
        const key: gooey.Key = .{ .name = @tagName(self.side) };
        const title = titles[@backingInt(self.side)];
        const over = if (cx.drag(ItemId)) |drag| drag.over == cx.id(key) else false;
        const ids = cx.state(State).list(self.side).slice();
        cx.render(ui.box(.{
            .key = key,
            .drop_target = .of(ItemId, cx.on(State.dropOn, .{ .arg = self.side })),
            .focusable = true,
            .tab_stop = false,
            .a11y = .{ .role = .list, .label = title },
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
            ui.text(title, .{ .size = 18, .color = .{ .rgba = .rgb(0.8, 0.8, 0.8) } }),
            ui.box(.{ .style = .{ .height = .{ .grow = 1 } } }, .{}),
            Cards{ .ids = ids },
            ui.when(ids.len == 0, emptyState),
            ui.box(.{ .style = .{ .height = .{ .grow = 1 } } }, .{}),
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
            const key: gooey.Key = .{ .index = id };
            cx.render(ui.box(.{
                .key = key,
                .draggable = .of(ItemId, id),
                .focusable = true,
                .on_key = cx.on(State.pickUp, .{ .arg = cx.id(key) }),
                .a11y = .{
                    .role = .button,
                    .label = items[id].name,
                    .description = "Space picks it up to move it",
                },
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
                .shadow = .{ .blur = 12, .offset_y = 4, .color = .{ .rgba = .rgba(0, 0, 0, 0.4) } },
            },
        }, .{
            ui.text(item.name, .{ .size = 16, .color = .{ .rgba = .white } }),
        }));
    }
};
