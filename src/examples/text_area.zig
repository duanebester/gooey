//! Text area: a multi-line `TextArea` above a preview that wraps its text.
//!
//! The field edits lines split on '\n', as 0.3.1's did: no soft wrap, up
//! and down keep the column they started from, and the lines scroll to keep
//! the caret in view. The preview below draws the same text wrapped at word
//! boundaries to the window's width, in a card whose height fits it, so a
//! typed newline, a long word, or a resize changes how many lines the card
//! takes. "Sample" loads notes whose lines differ in length, with a tab, an
//! accented letter, a word no line can break, and a line 4 characters short
//! of the field's bound of 1,024 per line; "Clear" empties them.
//!
//! Every byte is reserved before the event loop: the notes live in the one
//! area slot this app's limits reserve, and `State.notes` only points at
//! them (or at a constant, until the field adopts it at the next build).

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = components.Button;
const TextArea = components.TextArea;

const assert = std.debug.assert;

/// The field's bytes, and the clipboard's: enough for two lines near the
/// per-line bound with room to spare.
pub const notes_bytes_max = 4 * 1024;
/// Lines the field shows; the rest scroll.
pub const rows = 5;
/// The preview's text size, which the VOPR measures its lines at.
pub const preview_size = 14;
/// What the preview shows for empty notes.
pub const preview_placeholder = "Nothing to preview";
/// The preview card's padding, and the gap under its label.
pub const card_padding: f32 = 12;
pub const card_gap: f32 = 6;
pub const label_size = 12;
/// The preview text's indent inside its row. The text is the row's only
/// child, so it wraps to the row's content width: a sibling would take
/// width the text's container width does not subtract.
pub const rule_inset: f32 = 8;

/// The `small` profile with one area of `notes_bytes_max`. A full field
/// wraps to about 4,000 glyphs in the preview on top of the field's own
/// lines, so the glyph budget (which also bounds wrapped lines) is raised;
/// each wrapped line is a shaped run, so the run cache is too. Each glyph
/// drawn is also a paint record: at most `notes_bytes_max` in the field and
/// as many in the preview, plus a selection rect per line in view (fewer
/// than 1,024 at the framebuffer's height), the composition, the caret,
/// and under 100 for the buttons, label, and boxes, so paint records get
/// 12K where `small` has 8K.
pub const limits = blk: {
    var value = gooey.ResourceLimits.small;
    value.text.area = .{ .count_max = 1, .bytes_max = notes_bytes_max, .undo_depth_max = 64 };
    value.paint.glyph_count_frame_max = 16 * 1024;
    value.records.paint_record_count_frame_max = 12 * 1024;
    value.text.shaped_run_count_max = 512;
    break :blk value;
};

/// 1,020 codepoints, just under the engine's 1,024 per line, so typing on
/// it soon reaches the bound.
const long_line = repeatedLine("Long ", 1020);

/// 1,030 codepoints, past the bound, as an app may assign: edits may
/// shorten or split it but never grow it, and joins it takes part in are
/// judged against it (`text_engine.longestLineSpanned`).
const over_line = repeatedLine("Over ", 1030);

/// `prefix`, then "ab " repeated, then "x" padding to `count` codepoints.
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
    .title = "Text Area",
    .width = 640,
    .height = 560,
    .limits = limits,
});

/// The generated entry point (contract §7).
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

/// The notes wrapped at words. The card fits its content's height, inside a
/// scroll box that keeps a long preview from compressing the field.
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
