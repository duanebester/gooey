//! A file dialog from a handler on the 0.4.0 core (milestone 1).
//!
//! The button's handler only requests the dialog through `Effects`. The
//! window opens it on the main thread after the drain, outside any handler,
//! and the next drain delivers the outcome to `completed` as a selected
//! path, a cancellation, or a failure. The completion handler is built while
//! rendering, like every handler (`cx.on`), and kept in the state.

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
    status: []const u8 = "No file chosen yet.",
    on_complete: ?core.Handler = null,

    pub fn open(self: *State, effects: *Effects) void {
        effects.openFileDialog(.{ .kind = .open, .on_complete = self.on_complete.? });
    }

    pub fn save(self: *State, effects: *Effects) void {
        effects.openFileDialog(.{ .kind = .save, .on_complete = self.on_complete.? });
    }

    pub fn completed(self: *State, effects: *Effects) void {
        const completion = effects.completionEvent().?;
        switch (completion.outcome) {
            .file_selected => |selected| {
                const kept = keptLength(selected);
                @memcpy(self.path_bytes[0..kept], selected[0..kept]);
                @memset(self.path_bytes[kept..], 0);
                self.path_len = @intCast(kept);
                self.status = "Selected:";
            },
            .cancelled => self.status = "Cancelled.",
            .failed => self.status = "The dialog failed.",
        }
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

pub const App = core.App(State, .{
    .title = "File dialog",
    .width = 520,
    .height = 220,
    .limits = .nano,
    .theme = &core.Theme.light,
    .keymap = &.{},
    .entities = &.{},
    .on_init = null,
});

/// The generated entry point (contract §7).
pub const main = App.main;

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    s.on_complete = cx.on(State.completed, .{});
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(24),
        .gap = 16,
    } }, .{
        ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            Button{ .label = "Open\u{2026}", .on_click = cx.on(State.open, .{}) },
            Button{
                .label = "Save\u{2026}",
                .variant = .secondary,
                .on_click = cx.on(State.save, .{}),
            },
        }),
        ui.text(s.status, .{ .size = 16 }),
        ui.text(s.chosenPath(), .{ .size = 13 }),
    }));
}
