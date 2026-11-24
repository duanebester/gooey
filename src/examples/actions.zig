const builtin = @import("builtin");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = components.Button;
const TextInput = components.TextInput;

const Undo = gooey.actions.Undo;
const Redo = gooey.actions.Redo;
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

pub const Modifier = enum { cmd, ctrl };

pub const modifier_native: Modifier = if (builtin.os.tag == .macos) .cmd else .ctrl;

pub const App = AppWith(modifier_native);

pub const main = App.main;

pub fn AppWith(comptime modifier: Modifier) type {
    const m = @tagName(modifier);
    return gooey.App(State, Demo(modifier).render, .{
        .title = "Actions Demo",
        .width = 800,
        .height = 600,
        .limits = .nano,
        .keymap = gooey.keymaps.text_default ++ &[_]gooey.keymaps.Binding{
            .{ .keys = m ++ "-s", .action = ui.action(Save), .key_context = .named("Editor") },
            .{ .keys = "escape", .action = ui.action(Cancel) },
        },
    });
}

fn Demo(comptime modifier: Modifier) type {
    const m = @tagName(modifier);
    return struct {
        fn render(cx: *Cx) void {
            renderDemo(cx, .{
                .placeholder = "Type here... (" ++ m ++ "+s to save)",
                .undo = "Undo (" ++ m ++ "+z)",
                .redo = "Redo (" ++ m ++ "+shift+z)",
            });
        }
    };
}

const Labels = struct {
    placeholder: []const u8,
    undo: []const u8,
    redo: []const u8,
};

fn renderDemo(cx: *Cx, labels: Labels) void {
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
        EditorPanel{ .placeholder = labels.placeholder },
        ButtonRow{ .undo = labels.undo, .redo = labels.redo },
    }));
}

const EditorPanel = struct {
    placeholder: []const u8,

    pub fn render(self: EditorPanel, cx: *Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{
            .key_context = .named("Editor"),
            .actions = &.{.{ .action = ui.action(Save), .handler = cx.on(State.save, .{}) }},
            .style = .{ .background = .{ .rgba = .rgb(0.95, 0.95, 0.95) } },
        }, .{
            TextInput{
                .key = "editor",
                .placeholder = self.placeholder,
                .bind = &s.draft,
            },
        }));
    }
};

const ButtonRow = struct {
    undo: []const u8,
    redo: []const u8,

    pub fn render(self: ButtonRow, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            Button{ .label = self.undo, .on_click = cx.on(State.undo, .{}) },
            Button{ .label = self.redo, .on_click = cx.on(State.redo, .{}) },
        }));
    }
};
