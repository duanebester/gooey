const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = components.Button;
const TextArea = components.TextArea;

const assert = std.debug.assert;

pub const notes_bytes_max = 4 * 1024;
pub const rows = 5;
pub const preview_size = 14;
pub const preview_placeholder = "Nothing to preview";
pub const card_padding: f32 = 12;
pub const card_gap: f32 = 6;
pub const label_size = 12;
pub const rule_inset: f32 = 8;

pub const limits = blk: {
    var value = gooey.ResourceLimits.small;
    value.text.area = .{ .count_max = 1, .bytes_max = notes_bytes_max, .undo_depth_max = 64 };
    value.paint.glyph_count_frame_max = 16 * 1024;
    value.records.paint_record_count_frame_max = 12 * 1024;
    value.text.shaped_run_count_max = 512;
    break :blk value;
};

const long_line = repeatedLine("Long ", 1020);

const over_line = repeatedLine("Over ", 1030);

fn repeatedLine(comptime prefix: []const u8, comptime count: u32) []const u8 {
    assert(prefix.len < count);
    const repeats = (count - prefix.len) / 3;
    var bytes: [count]u8 = @splat('x');
    @memcpy(bytes[0..prefix.len], prefix);
    for (0..repeats) |index| @memcpy(bytes[prefix.len + index * 3 ..][0..3], "ab ");
    assert(bytes[count - 1] == 'x');
    const result = bytes;
    return &result;
}

pub const sample = "Notes\n" ++
    "\tIndented with a tab, and caf\u{e9}.\n" ++
    "\n" ++
    "A short line\n" ++
    "Antidisestablishmentarianism-without-a-single-break-anywhere\n" ++
    long_line ++ "\n" ++
    over_line ++ "\n" ++
    "Last line, a little longer than the short one";

comptime {
    @setEvalBranchQuota(10_000);
    assert(std.unicode.utf8CountCodepoints(long_line) catch unreachable == 1020);
    assert(std.unicode.utf8CountCodepoints(over_line) catch unreachable == 1030);
    assert(sample.len < notes_bytes_max);
    assert(notes_bytes_max <= limits.text.area.bytes_max);
}

pub const State = struct {
    notes: []const u8 = "",

    pub fn loadSample(self: *State) void {
        self.notes = sample;
        assert(self.notes.len == sample.len);
    }

    pub fn clear(self: *State) void {
        self.notes = "";
        assert(self.notes.len == 0);
    }
};

pub const App = gooey.App(State, render, .{
    .keymap = gooey.keymaps.text_default,
    .title = "Text Area",
    .width = 640,
    .height = 560,
    .limits = limits,
});

pub const main = App.main;

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(16),
        .gap = 12,
    } }, .{
        ui.text("Notes", .{ .size = 18, .weight = .bold }),
        TextArea{
            .key = "notes",
            .bind = &s.notes,
            .placeholder = "Write notes here",
            .width = null,
            .rows = rows,
        },
        ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            Button{ .label = "Sample", .on_click = cx.on(State.loadSample, .{}) },
            Button{
                .label = "Clear",
                .variant = .secondary,
                .on_click = cx.on(State.clear, .{}),
            },
        }),
        Preview{},
    }));
}

const Preview = struct {
    pub fn render(_: Preview, cx: *Cx) void {
        const s = cx.state(State);
        const theme = cx.theme();
        const content = if (s.notes.len == 0) preview_placeholder else s.notes;
        cx.render(ui.box(.{ .key = .{ .name = "preview-scroll" }, .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .scroll = .{},
        } }, .{
            ui.box(.{ .key = .{ .name = "preview" }, .style = .{
                .width = .{ .grow = 1 },
                .padding = .all(card_padding),
                .gap = card_gap,
                .background = .surface,
                .corner_radius = .all(theme.radius_md),
            } }, .{
                ui.text("Preview", .{ .size = label_size, .color = .muted }),
                ui.box(.{ .style = .{
                    .direction = .row,
                    .width = .{ .grow = 1 },
                    .padding = .{ .left = rule_inset },
                } }, .{
                    ui.text(content, .{ .size = preview_size, .wrap = .words }),
                }),
            }),
        }));
    }
};
