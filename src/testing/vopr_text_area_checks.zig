//! Structural checks of every frame the text_area example builds, beside
//! its model (`vopr_text_area_model.zig`). They read the built frame, the
//! field's engine, and the layout the frame came from, and state what the
//! frame must show whatever the edits were:
//! - Caret: with the field focused, the frame's IME caret is the field's,
//!   over its selection; after the caret or text moved since the last build,
//!   the caret's line lies inside the field's rows (`follow`). Unfocused,
//!   the frame has no IME caret.
//! - Wrap: the preview's wrapped lines cover its text in order, dropping
//!   only whitespace between lines and at the end; a line never holds a
//!   newline, and the whitespace between two lines holds at most one, so
//!   the lines are the text's newline-separated lines plus the wraps. A
//!   wrap (a break with no newline) is needed: the next line's first word
//!   does not fit after the line, past one space. A line's glyphs, trailing
//!   spaces aside, fit the wrap width unless the line is one word.
//! - Height: the preview text is its lines times the line height tall, and
//!   the card that fits it (`propagateHeightChange`) is its padding, the
//!   label, the gap, and the text tall.

const std = @import("std");
const gooey = @import("gooey");
const text_area = @import("text_area_example");
const model = @import("vopr_text_area_model.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const layout = internals.layout;
const Window = internals.window.Window;
const ElementId = records.ElementId;
const LayoutEngine = layout.LayoutEngine;
const LayoutElement = layout.LayoutElement;
const WrappedLine = internals.layout.types.WrappedLine;

/// Float slack for sums of advances measured in different orders.
const epsilon: f32 = 0.01;

pub const Counts = struct {
    frames: u32,
    /// Builds after a caret move whose caret line was checked in view.
    carets_in_view: u32,
    wrapped_lines_max: u32,
    /// Breaks with no newline, checked to be needed.
    wraps: u32,
    /// Lines of one word wider than the wrap width.
    long_words: u32,
    card_heights: u32,

    pub const zero: Counts = .{
        .frames = 0,
        .carets_in_view = 0,
        .wrapped_lines_max = 0,
        .wraps = 0,
        .long_words = 0,
        .card_heights = 0,
    };

    pub fn format(self: Counts, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d} frames checked: {d} carets in view, {d} wrapped lines at " ++
            "most, {d} wraps, {d} long-word lines, {d} card heights", .{
            self.frames, self.carets_in_view, self.wrapped_lines_max,
            self.wraps,  self.long_words,     self.card_heights,
        });
    }
};

pub const Options = struct {
    area_id: ElementId,
    /// The caret or text moved since the last build (`TextArea.follow`).
    moved: bool,
    counts: *Counts,
};

/// Check the frame `tickMain` just built, with the layout it came from.
pub fn checkBuild(window: *Window, options: Options) void {
    const frame = window.built();
    checkCaret(window, frame, options);
    const index = findPreview(window.layout, frame.frame_number);
    const engine = model.findEngine(window);
    const content = if (engine.len == 0) text_area.preview_placeholder else engine.text();
    const data = &window.layout.elements.getConst(index).text_data.?;
    if (!std.mem.eql(u8, data.text, content)) {
        std.debug.panic("vopr text_area: frame {d}'s preview shows \"{s}\", not the field's " ++
            "text \"{s}\"", .{ frame.frame_number, data.text, content });
    }
    if (data.wrapped_lines) |lines| {
        checkLines(window.layout, data, lines, frame.frame_number, options.counts);
        checkHeights(window.layout, index, lines, frame.frame_number, options.counts);
        const line_count: u32 = @intCast(lines.len);
        options.counts.wrapped_lines_max = @max(options.counts.wrapped_lines_max, line_count);
    }
    options.counts.frames += 1;
}

fn checkCaret(window: *Window, frame: *const records.Frame, options: Options) void {
    if (window.focus != options.area_id) {
        if (frame.ime != null) {
            std.debug.panic("vopr text_area: frame {d} has an IME caret with the field " ++
                "unfocused", .{frame.frame_number});
        }
        return;
    }
    const engine = model.findEngine(window);
    const ime = frame.ime orelse
        std.debug.panic("vopr text_area: frame {d} has no caret in the focused field", .{
            frame.frame_number,
        });
    const start = @min(engine.cursor, engine.anchor);
    const end = @max(engine.cursor, engine.anchor);
    const same = ime.owner == options.area_id and ime.selected_start == start and
        ime.selected_end == end;
    if (!same) {
        std.debug.panic("vopr text_area: frame {d}'s IME caret is over {d}..{d}, the " ++
            "field's selection is {d}..{d}", .{
            frame.frame_number, ime.selected_start, ime.selected_end, start, end,
        });
    }
    if (!options.moved) return;
    const line_height = ime.cursor_rect.height;
    assert(line_height > 0);
    const row: f32 = @floatFromInt(std.mem.count(u8, engine.text()[0..engine.cursor], "\n"));
    const top = row * line_height - engine.scroll_y;
    const view_height = line_height * @as(f32, @floatFromInt(text_area.rows));
    if (top < -epsilon or top + line_height > view_height + epsilon) {
        std.debug.panic("vopr text_area: frame {d}: after a caret move the caret's line " ++
            "{d} is {d} px from the top of a {d} px view", .{
            frame.frame_number, row, top, view_height,
        });
    }
    options.counts.carets_in_view += 1;
}

/// The preview's text element: the only words-wrapped text of its size.
fn findPreview(engine: *const LayoutEngine, frame_number: u64) u32 {
    var found: ?u32 = null;
    for (engine.elements.items(), 0..) |*element, index| {
        const data = element.text_data orelse continue;
        if (data.config.font_size != text_area.preview_size) continue;
        if (data.config.wrap_mode != .words) continue;
        if (found != null) {
            std.debug.panic("vopr text_area: frame {d} has two preview texts", .{frame_number});
        }
        found = @intCast(index);
    }
    return found orelse
        std.debug.panic("vopr text_area: frame {d} has no preview text", .{frame_number});
}

fn checkLines(
    engine: *LayoutEngine,
    data: *const layout.TextData,
    lines: []const WrappedLine,
    frame_number: u64,
    counts: *Counts,
) void {
    const text = data.text;
    var previous_end: u32 = 0;
    for (lines, 0..) |line, index| {
        assert(line.start_offset <= text.len);
        assert(line.length <= text.len - line.start_offset);
        if (line.start_offset < previous_end) {
            failLine(frame_number, index, "starts inside the line before", text);
        }
        const gap = text[previous_end..line.start_offset];
        if (!whitespace(gap)) failLine(frame_number, index, "drops text before it", text);
        const breaks = std.mem.count(u8, gap, "\n");
        if (index == 0 and breaks > 0) failLine(frame_number, index, "drops a line", text);
        if (breaks > 1) failLine(frame_number, index, "drops an empty line", text);
        const run = text[line.start_offset..][0..line.length];
        if (std.mem.indexOfScalar(u8, run, '\n') != null) {
            failLine(frame_number, index, "holds a newline", text);
        }
        if (index > 0 and breaks == 0) {
            counts.wraps += 1;
            const before = lines[index - 1];
            checkWrapNeeded(engine, data, text[before.start_offset..][0..before.length], run);
        }
        checkWidth(engine, data, run, frame_number, index, counts);
        previous_end = line.start_offset + line.length;
    }
    if (!whitespace(text[previous_end..])) {
        failLine(frame_number, lines.len, "is missing: text after the last line is dropped", text);
    }
}

/// A line's glyphs fit the wrap width, unless it is one word.
fn checkWidth(
    engine: *LayoutEngine,
    data: *const layout.TextData,
    run: []const u8,
    frame_number: u64,
    index: usize,
    counts: *Counts,
) void {
    const drawn = std.mem.trimEnd(u8, run, " \t");
    const width = if (skip_wrap_whitespace)
        collapsedWidth(engine, data, drawn)
    else
        measure(engine, data, drawn);
    if (width <= data.container_width + epsilon) return;
    // A word wider than the line is alone on it, whatever space leads it.
    const one_word = std.mem.indexOfAny(u8, std.mem.trim(u8, drawn, " \t"), " \t") == null;
    if (one_word) {
        counts.long_words += 1;
        return;
    }
    std.debug.panic("vopr text_area: frame {d}: preview line {d} \"{s}\" is {d} px wide, " ++
        "past the {d} px wrap width, and is not one word", .{
        frame_number, index, run, width, data.container_width,
    });
}

/// A wrap is needed: the next line's first word does not fit after the
/// line before, past one space.
fn checkWrapNeeded(
    engine: *LayoutEngine,
    data: *const layout.TextData,
    before: []const u8,
    after: []const u8,
) void {
    const word_end = std.mem.indexOfAny(u8, after, " \t") orelse after.len;
    const word = after[0..word_end];
    const width = measure(engine, data, std.mem.trimEnd(u8, before, " \t")) +
        measure(engine, data, " ") + measure(engine, data, word);
    if (width > data.container_width - epsilon) return;
    std.debug.panic("vopr text_area: the preview wraps \"{s}\" before \"{s}\", but they fit " ++
        "on one line: {d} px of {d}", .{ before, word, width, data.container_width });
}

/// The text is its lines tall, and each fit-height box around it, up to
/// the card, is as tall as its content.
fn checkHeights(
    engine: *const LayoutEngine,
    index: u32,
    lines: []const WrappedLine,
    frame_number: u64,
    counts: *Counts,
) void {
    if (lines.len == 0) return;
    const element = engine.elements.getConst(index);
    const data = element.text_data.?;
    const count: f32 = @floatFromInt(lines.len);
    const text_height = count * data.config.lineHeightPx();
    const row = engine.elements.getConst(element.parent_index.?);
    const card = engine.elements.getConst(row.parent_index.?);
    const label = engine.elements.getConst(card.first_child_index.?);
    assert(label.text_data != null);
    const card_height = 2 * text_area.card_padding + label.computed.sized_height +
        text_area.card_gap + text_height;
    const heights = [_][2]f32{
        .{ element.computed.sized_height, text_height },
        .{ row.computed.bounding_box.height, text_height },
        .{ card.computed.bounding_box.height, card_height },
    };
    const names = [_][]const u8{ "preview text", "preview row", "preview card" };
    for (heights, names) |pair, name| {
        if (@abs(pair[0] - pair[1]) <= epsilon) continue;
        std.debug.panic("vopr text_area: frame {d}: the {s} is {d} px tall, but its " ++
            "{d} lines need {d}", .{ frame_number, name, pair[0], lines.len, pair[1] });
    }
    counts.card_heights += 1;
}

fn measure(engine: *LayoutEngine, data: *const layout.TextData, value: []const u8) f32 {
    if (value.len == 0) return 0;
    const measure_fn = engine.measure_text_fn.?;
    const config = data.config;
    const user_data = engine.measure_text_user_data;
    const size = measure_fn(value, config.font_id, config.font_size, null, user_data);
    assert(size.width >= 0);
    return size.width;
}

/// Temporary (`--skip-wrap-whitespace`): measure a line as the wrap does,
/// each run of spaces and tabs one space wide and none at its start, so
/// runs get past the known finding (the failing check in core_checks.zig,
/// "a wrapped line's glyphs stay inside the wrap width") to find others.
/// Remove it with the fix. Set once by the CLI before the first frame.
pub var skip_wrap_whitespace: bool = false;

fn collapsedWidth(engine: *LayoutEngine, data: *const layout.TextData, value: []const u8) f32 {
    var width: f32 = 0;
    var words = std.mem.tokenizeAny(u8, value, " \t");
    var count: u32 = 0;
    while (words.next()) |word| : (count += 1) {
        if (count > 0) width += measure(engine, data, " ");
        width += measure(engine, data, word);
    }
    return width;
}

fn whitespace(value: []const u8) bool {
    for (value) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\n') return false;
    }
    return true;
}

fn failLine(frame_number: u64, index: usize, reason: []const u8, text: []const u8) noreturn {
    std.debug.panic("vopr text_area: frame {d}: preview line {d} {s} (text \"{s}\")", .{
        frame_number, index, reason, text,
    });
}
