const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const ContextMenu = components.ContextMenu;
const MenuItem = components.MenuItem;

const assert = std.debug.assert;

pub const task_count: u32 = 3;

pub const State = struct {
    done: [task_count]bool = .{ false, true, false },
    removed: [task_count]bool = .{ false, false, false },
    last_action: []const u8 = "Right-click a card, or focus one and press Shift+F10.",

    pub const titles = [task_count][]const u8{
        "Write the release notes",
        "Tag 0.6.6",
        "Reply to issues",
    };

    pub fn toggleDone(self: *State, index: u32) void {
        assert(index < task_count);
        assert(!self.removed[index]);
        self.done[index] = !self.done[index];
        self.last_action = if (self.done[index]) "Marked done." else "Marked not done.";
    }

    pub fn remove(self: *State, index: u32) void {
        assert(index < task_count);
        assert(!self.removed[index]);
        self.removed[index] = true;
        self.last_action = "Deleted.";
    }
};

pub const App = gooey.App(State, render, .{
    .title = "Context menu",
    .width = 520,
    .height = 400,
    .limits = .small,
});

pub const main = App.main;

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(24),
        .gap = 12,
        .background = .bg,
    } }, .{
        ui.text("Tasks", .{ .size = 22, .weight = .semibold }),
        TaskCards{},
        ui.text(s.last_action, .{ .color = .subtext, .wrap = .words }),
    }));
}

const TaskCards = struct {
    pub fn render(_: TaskCards, cx: *Cx) void {
        const s = cx.state(State);
        var index: u32 = 0;
        while (index < task_count) : (index += 1) {
            if (s.removed[index]) continue;
            cx.render(TaskCard{ .index = index, .done = s.done[index] });
        }
    }
};

const TaskCard = struct {
    index: u32,
    done: bool,

    const menu_keys = [task_count][]const u8{ "task-0", "task-1", "task-2" };

    pub fn render(self: TaskCard, cx: *Cx) void {
        assert(self.index < task_count);
        const items = [_]MenuItem{
            .{
                .label = if (self.done) "Mark not done" else "Mark done",
                .on_select = cx.on(State.toggleDone, .{ .arg = self.index }),
            },
            .{ .label = "Rename", .disabled = true },
            .{ .separator = true },
            .{
                .label = "Delete",
                .shortcut = "Del",
                .danger = true,
                .on_select = cx.on(State.remove, .{ .arg = self.index }),
            },
        };
        cx.render(ContextMenu(Card){
            .key = menu_keys[self.index],
            .items = &items,
            .accessible_name = State.titles[self.index],
            .child = .{ .title = State.titles[self.index], .done = self.done },
        });
    }
};

const Card = struct {
    title: []const u8,
    done: bool,

    pub fn render(self: Card, cx: *Cx) void {
        assert(self.title.len > 0);
        cx.render(ui.box(.{
            .key = .{ .name = "card" },
            .style = .{
                .direction = .row,
                .width = .{ .fixed = 360 },
                .padding = .symmetric(16, 12),
                .alignment = .{ .main = .space_between, .cross = .center },
                .background = .surface,
                .border = .{ .width = 1, .color = .border },
                .corner_radius = .all(8),
            },
            .focusable = true,
            .a11y = .{ .role = .group, .label = self.title },
        }, .{
            ui.text(self.title, .{}),
            ui.text(if (self.done) "Done" else "Open", .{
                .color = if (self.done) .success else .muted,
            }),
        }));
    }
};
