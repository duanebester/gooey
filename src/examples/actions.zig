const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const Button = gooey.Button;
const Cx = gooey.Cx;

// Define action types
const Undo = struct {};
const Redo = struct {};
const Save = struct {};
const Cancel = struct {};

const AppState = struct {
    message: []const u8 = "",
    initialized: bool = false,
};

var state = AppState{};

pub fn main() !void {
    try gooey.runCx(AppState, &state, render, .{
        .title = "Actions Demo",
    });
}

fn setupKeymap(cx: *Cx) void {
    const s = cx.state(AppState);
    if (s.initialized) return;
    s.initialized = true;

    const g = cx.gooey();
    g.keymap.bind(Undo, "cmd-z", null);
    g.keymap.bind(Redo, "cmd-shift-z", null);
    g.keymap.bind(Save, "cmd-s", "Editor");
    g.keymap.bind(Cancel, "escape", null);
}

fn render(cx: *Cx) void {
    setupKeymap(cx);

    cx.render(ui.box(.{ .padding = .{ .all = 24 }, .gap = 16, .direction = .column }, .{
        ui.onAction(Undo, doUndo),
        ui.onAction(Redo, doRedo),
        ui.onAction(Cancel, doCancel),

        ui.text("Actions Demo", .{ .size = 24 }),
        ui.text(cx.state(AppState).message, .{}),

        EditorPanel{},
        ButtonRow{},
    }));
}

const EditorPanel = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .background = ui.Color.rgb(0.95, 0.95, 0.95),
        }, .{
            ui.keyContext("Editor"),
            ui.onAction(Save, save),

            ui.input("editor", .{ .placeholder = "Type here... (cmd+s to save)" }),
        });
    }
};

const ButtonRow = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.hstack(.{
            .gap = 8,
        }, .{
            Button{ .label = "Undo (cmd+z)", .on_click = doUndo },
            Button{ .label = "Redo (cmd+shift+z)", .on_click = doRedo },
        });
    }
};

fn doUndo() void {
    state.message = "Undo!";
}
fn doRedo() void {
    state.message = "Redo!";
}
fn doCancel() void {
    state.message = "Cancelled!";
}
fn save() void {
    state.message = "Saved!";
}
