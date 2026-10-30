//! Todo on the 0.4.0 core (milestone 1).
//!
//! A port of `todo.zig` written against the core contract, including the
//! filter bar and footer, so its golden can be compared with the 0.3.1
//! golden. The draft is a `TextInput` bound to `State.draft`; IME
//! composition reaches its retained engine through the router like any key.
//! Rows render through a component loop: `components.List` needs scrolling,
//! which arrives in phase 4.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Button = components.core.Button;
const Checkbox = components.core.Checkbox;
const TextInput = components.core.TextInput;

const todo_count_max = 64;
const todo_bytes_max = 128;

const Todo = struct {
    bytes: [todo_bytes_max]u8 = @splat(0),
    len: u32 = 0,
    done: bool = false,

    fn text(self: *const Todo) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Filter = enum { all, active, done };

pub const State = struct {
    todos: [todo_count_max]Todo = @splat(.{}),
    count: u32 = 0,
    draft: []const u8 = "",
    filter: Filter = .all,

    /// Append the trimmed `value`; blank values and a full list are ignored.
    fn push(self: *State, value: []const u8) void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.count == todo_count_max) return;
        const slot = &self.todos[self.count];
        const kept = @min(trimmed.len, todo_bytes_max);
        @memcpy(slot.bytes[0..kept], trimmed[0..kept]);
        slot.len = @intCast(kept);
        slot.done = false;
        self.count += 1;
    }

    pub fn addTodo(self: *State) void {
        self.push(self.draft);
        self.draft = "";
    }

    pub fn toggle(self: *State, index: u32) void {
        if (index >= self.count) return;
        self.todos[index].done = !self.todos[index].done;
    }

    pub fn remove(self: *State, index: u32) void {
        if (index >= self.count) return;
        var position = index;
        while (position + 1 < self.count) : (position += 1) {
            self.todos[position] = self.todos[position + 1];
        }
        self.count -= 1;
    }

    pub fn setFilter(self: *State, filter: Filter) void {
        self.filter = filter;
    }

    pub fn clearCompleted(self: *State) void {
        var kept: u32 = 0;
        for (self.todos[0..self.count]) |todo| {
            if (todo.done) continue;
            self.todos[kept] = todo;
            kept += 1;
        }
        self.count = kept;
    }

    fn remaining(self: *const State) u32 {
        var count: u32 = 0;
        for (self.todos[0..self.count]) |*todo| {
            if (!todo.done) count += 1;
        }
        return count;
    }

    fn visible(self: *const State, todo: *const Todo) bool {
        return switch (self.filter) {
            .all => true,
            .active => !todo.done,
            .done => todo.done,
        };
    }
};

pub const App = core.App(State, render, .{
    .title = "Todos",
    .width = 480,
    .height = 560,
    .limits = .small,
    .theme = &core.Theme.light,
    .keymap = &.{},
    .entities = &.{},
    .on_init = null,
});

/// The generated entry point (contract §7).
pub const main = App.main;

const spacer = ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{});

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(24),
        .gap = 16,
        .background = .{ .rgba = .rgb(0.96, 0.96, 0.97) },
    } }, .{
        ui.text("Todos", .{ .size = 28, .color = .{ .rgba = .rgb(0.1, 0.1, 0.15) } }),
        ui.box(.{ .style = .{ .direction = .row, .gap = 8, .alignment = .center_cross } }, .{
            TextInput{
                .key = "new-todo",
                .placeholder = "What needs doing?",
                .bind = &s.draft,
                .width = 360,
            },
            Button{ .label = "Add", .on_click = cx.on(State.addTodo, .{}) },
        }),
        FilterBar{},
        ui.when(s.count == 0, emptyHint),
        ui.when(s.count > 0, todoList),
        spacer,
        Footer{},
    }));
}

fn emptyHint(cx: *Cx) void {
    cx.render(ui.text(
        "Nothing yet \u{2014} add your first todo above.",
        .{ .size = 14, .color = .{ .rgba = .rgb(0.5, 0.5, 0.55) } },
    ));
}

fn todoList(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{ .gap = 8 } }, .{TodoItems{}}));
}

const FilterBar = struct {
    pub fn render(_: FilterBar, cx: *Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            FilterButton{ .label = "All", .filter = .all, .active = s.filter == .all },
            FilterButton{ .label = "Active", .filter = .active, .active = s.filter == .active },
            FilterButton{ .label = "Done", .filter = .done, .active = s.filter == .done },
        }));
    }
};

const FilterButton = struct {
    label: []const u8,
    filter: Filter,
    active: bool,

    pub fn render(self: FilterButton, cx: *Cx) void {
        cx.render(Button{
            .label = self.label,
            .size = .small,
            .variant = if (self.active) .primary else .secondary,
            .on_click = cx.on(State.setFilter, .{ .arg = self.filter }),
        });
    }
};

const TodoItems = struct {
    pub fn render(_: TodoItems, cx: *Cx) void {
        const s = cx.state(State);
        for (s.todos[0..s.count], 0..) |*todo, index| {
            if (!s.visible(todo)) continue;
            cx.render(TodoRow{ .index = @intCast(index) });
        }
    }
};

const row_style: ui.Style = .{
    .direction = .row,
    .gap = 12,
    .alignment = .center_cross,
    .padding = .all(10),
    .background = .{ .rgba = ui.Color.white },
    .corner_radius = .all(8),
};

const TodoRow = struct {
    index: u32,

    pub fn render(self: TodoRow, cx: *Cx) void {
        const todo = &cx.state(State).todos[self.index];
        const color = if (todo.done) ui.Color.rgb(0.6, 0.6, 0.6) else ui.Color.rgb(0.1, 0.1, 0.1);
        cx.render(ui.box(.{ .key = .{ .index = self.index }, .style = row_style }, .{
            Checkbox{
                .checked = todo.done,
                .on_click = cx.on(State.toggle, .{ .arg = self.index }),
            },
            ui.text(todo.text(), .{ .size = 16, .color = .{ .rgba = color } }),
            spacer,
            Button{
                .label = "Delete",
                .variant = .danger,
                .size = .small,
                .on_click = cx.on(State.remove, .{ .arg = self.index }),
            },
        }));
    }
};

const Footer = struct {
    pub fn render(_: Footer, cx: *Cx) void {
        const s = cx.state(State);
        var buffer: [32]u8 = undefined;
        // 32 bytes hold any u32 and " left".
        const left = std.fmt.bufPrint(&buffer, "{d} left", .{s.remaining()}) catch unreachable;
        cx.render(ui.box(.{
            .style = .{ .direction = .row, .gap = 12, .alignment = .center_cross },
        }, .{
            ui.text(left, .{ .size = 14, .color = .{ .rgba = .rgb(0.4, 0.4, 0.45) } }),
            spacer,
            Button{
                .label = "Clear completed",
                .variant = .secondary,
                .size = .small,
                .on_click = cx.on(State.clearCompleted, .{}),
            },
        }));
    }
};

test "the model adds trimmed drafts, toggles, removes, and clears" {
    // Goal: the state methods the handlers call, without a window.
    var s = State{ .draft = "  buy milk  " };
    s.addTodo();
    try std.testing.expectEqualStrings("buy milk", s.todos[0].text());
    try std.testing.expectEqualStrings("", s.draft);
    s.push("b");
    s.push("c");
    s.toggle(0);
    s.toggle(2);
    try std.testing.expectEqual(@as(u32, 1), s.remaining());
    s.remove(1);
    try std.testing.expectEqual(@as(u32, 2), s.count);
    s.clearCompleted();
    try std.testing.expectEqual(@as(u32, 0), s.count);
}
