//! File dialogs from handlers on the 0.4.0 core.
//!
//! Each button's handler only requests a dialog through `Effects`, with
//! GPUI's options (decision 11): open files, several files, or a folder, or
//! save with a suggested name. The window opens the dialog on the main
//! thread after the drain, outside any handler, and the next drain delivers
//! the outcome to `completed`: the selected paths, a cancellation, or a
//! failure. The request names its completion handler directly with
//! `effects.handler` (decision 7).

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Effects = core.Effects;
const Button = components.core.Button;

/// Longest path the state keeps; longer paths are cut at a UTF-8 boundary.
const path_bytes_max = 512;

pub const State = struct {
    path_bytes: [path_bytes_max]u8 = @splat(0),
    path_len: u32 = 0,
    status_bytes: [64]u8 = @splat(0),
    status_len: u32 = 0,

    pub fn openFile(_: *State, effects: *Effects) void {
        open(effects, .{ .files = true, .directories = false, .multiple = false });
    }

    pub fn openFiles(_: *State, effects: *Effects) void {
        open(effects, .{ .files = true, .directories = false, .multiple = true });
    }

    pub fn openFolder(_: *State, effects: *Effects) void {
        open(effects, .{ .files = false, .directories = true, .multiple = false });
    }

    pub fn save(_: *State, effects: *Effects) void {
        effects.openFileDialog(.{
            .kind = .{ .save = .{ .directory = null, .suggested_name = "untitled.txt" } },
            .on_complete = effects.handler(State.completed),
        });
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

    fn open(effects: *Effects, options: core.PathPromptOptions) void {
        effects.openFileDialog(.{
            .kind = .{ .open = options },
            .on_complete = effects.handler(State.completed),
        });
    }

    fn setStatus(self: *State, comptime format: []const u8, args: anytype) void {
        // Every format above fits 64 bytes with the largest path count
        // (`dialog_path_count_max` is at most 1,024), so bufPrint cannot fail.
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

pub const App = core.App(State, render, .{
    .title = "File dialog",
    .width = 680,
    .height = 220,
    .limits = .nano,
});

/// The generated entry point (contract §7).
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
