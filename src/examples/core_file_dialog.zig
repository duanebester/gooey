const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const Button = components.Button;

const path_bytes_max = 512;

pub const State = struct {
    path_bytes: [path_bytes_max]u8 = @splat(0),
    path_len: u32 = 0,
    status_bytes: [64]u8 = @splat(0),
    status_len: u32 = 0,

    pub fn openFile(self: *State, effects: *Effects) void {
        self.open(effects, .{ .files = true, .directories = false, .multiple = false });
    }

    pub fn openFiles(self: *State, effects: *Effects) void {
        self.open(effects, .{ .files = true, .directories = false, .multiple = true });
    }

    pub fn openFolder(self: *State, effects: *Effects) void {
        self.open(effects, .{ .files = false, .directories = true, .multiple = false });
    }

    pub fn save(self: *State, effects: *Effects) void {
        effects.openFileDialog(.{
            .kind = .{ .save = .{ .directory = null, .suggested_name = "untitled.txt" } },
            .on_complete = effects.handler(State.completed),
        }) catch |err| self.refused(err);
    }

    pub fn completed(self: *State, effects: *Effects) void {
        const completion = effects.completionEvent().?;
        self.path_len = 0;
        switch (completion.outcome) {
            .file_selected => |paths| {
                const first = paths.first();
                const kept = keptLength(first);
                @memcpy(self.path_bytes[0..kept], first[0..kept]);
                @memset(self.path_bytes[kept..], 0);
                self.path_len = @intCast(kept);
                if (paths.count == 1) {
                    self.setStatus("Selected:", .{});
                } else {
                    self.setStatus("Selected {d} paths; the first:", .{paths.count});
                }
            },
            .cancelled => self.setStatus("Cancelled.", .{}),
            .failed => self.setStatus("The dialog failed.", .{}),
        }
    }

    fn open(self: *State, effects: *Effects, options: gooey.PathPromptOptions) void {
        effects.openFileDialog(.{
            .kind = .{ .open = options },
            .on_complete = effects.handler(State.completed),
        }) catch |err| self.refused(err);
    }

    fn refused(self: *State, err: Effects.DialogError) void {
        switch (err) {
            error.DialogBusy => self.setStatus("A dialog is already open.", .{}),
        }
    }

    fn setStatus(self: *State, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_bytes, format, args) catch unreachable;
        self.status_len = @intCast(text.len);
    }

    fn status(self: *const State) []const u8 {
        if (self.status_len == 0) return "No file chosen yet.";
        return self.status_bytes[0..self.status_len];
    }

    fn chosenPath(self: *const State) []const u8 {
        return self.path_bytes[0..self.path_len];
    }
};

fn keptLength(value: []const u8) usize {
    if (value.len <= path_bytes_max) return value.len;
    var end: usize = path_bytes_max;
    while (end > 0 and value[end] & 0xC0 == 0x80) end -= 1;
    std.debug.assert(end <= path_bytes_max);
    return end;
}

pub const App = gooey.App(State, render, .{
    .title = "File dialog",
    .width = 680,
    .height = 220,
    .limits = .nano,
});

pub const main = App.main;

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(24),
        .gap = 16,
    } }, .{
        ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            Button{ .label = "Open\u{2026}", .on_click = cx.on(State.openFile, .{}) },
            Button{ .label = "Open Files\u{2026}", .on_click = cx.on(State.openFiles, .{}) },
            Button{ .label = "Open Folder\u{2026}", .on_click = cx.on(State.openFolder, .{}) },
            Button{
                .label = "Save\u{2026}",
                .variant = .secondary,
                .on_click = cx.on(State.save, .{}),
            },
        }),
        ui.text(s.status(), .{ .size = 16 }),
        ui.text(s.chosenPath(), .{ .size = 13 }),
    }));
}
