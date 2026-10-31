//! Actions: keymaps, key contexts, and action handlers on the core.
//!
//! Undo, Redo, and Cancel are bound globally and handled by the root box.
//! Save is bound only inside the "Editor" key context, so cmd-s does nothing
//! until focus is inside the editor panel. The layout matches the 0.3.1
//! actions example, so its golden is compared with the 0.3.1 golden.

const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Button = components.core.Button;
const TextInput = components.core.TextInput;

const Undo = struct {};
const Redo = struct {};
const Save = struct {};
const Cancel = struct {};

pub const State = struct {
    message: []const u8 = "",
    draft: []const u8 = "",

    pub fn undo(self: *State) void {
        self.message = "Undo!";
    }

    pub fn redo(self: *State) void {
        self.message = "Redo!";
    }

    pub fn cancel(self: *State) void {
        self.message = "Cancelled!";
    }

    pub fn save(self: *State) void {
        self.message = "Saved!";
    }
};

pub const App = core.App(State, render, .{
    .title = "Actions Demo",
    .width = 800,
    .height = 600,
    .limits = .nano,
    .keymap = &.{
        .{ .keys = "cmd-z", .action = ui.action(Undo) },
        .{ .keys = "cmd-shift-z", .action = ui.action(Redo) },
        .{ .keys = "cmd-s", .action = ui.action(Save), .key_context = .named("Editor") },
        .{ .keys = "escape", .action = ui.action(Cancel) },
    },
});

pub const main = App.main;

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{
        .actions = &.{
            .{ .action = ui.action(Undo), .handler = cx.on(State.undo, .{}) },
            .{ .action = ui.action(Redo), .handler = cx.on(State.redo, .{}) },
            .{ .action = ui.action(Cancel), .handler = cx.on(State.cancel, .{}) },
        },
        .style = .{ .padding = .all(24), .gap = 16 },
    }, .{
        ui.text("Actions Demo", .{ .size = 24 }),
        ui.text(s.message, .{ .size = 14 }),
        EditorPanel{},
        ButtonRow{},
    }));
}

const EditorPanel = struct {
    pub fn render(_: EditorPanel, cx: *Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{
            .key_context = .named("Editor"),
            .actions = &.{.{ .action = ui.action(Save), .handler = cx.on(State.save, .{}) }},
            .style = .{ .background = .{ .rgba = .rgb(0.95, 0.95, 0.95) } },
        }, .{
            TextInput{
                .key = "editor",
                .placeholder = "Type here... (cmd+s to save)",
                .bind = &s.draft,
            },
        }));
    }
};

const ButtonRow = struct {
    pub fn render(_: ButtonRow, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            Button{ .label = "Undo (cmd+z)", .on_click = cx.on(State.undo, .{}) },
            Button{ .label = "Redo (cmd+shift+z)", .on_click = cx.on(State.redo, .{}) },
        }));
    }
};
