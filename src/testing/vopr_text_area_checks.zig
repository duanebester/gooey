//! Structural checks of every frame the text_area example builds, beside its
//! model (`vopr_text_area_model.zig`): the IME caret over the field's
//! selection and in view after a move, the preview's wrapping as GPUI's
//! `LineWrapper` packs lines (`sizing_pass.LinePacker`) - lines cover the
//! text in order, no line holds a newline, a line is as wide as its
//! codepoints measured together and fits the wrap width unless it cannot
//! break further - and the preview's and card's heights.

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
    carets_in_view: u32,
    wrapped_lines_max: u32,
    wraps: u32,
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
        const wraps = gap.len == 0 and index > 0;
        if (index == 0 and gap.len > 0) failLine(frame_number, index, "drops text", text);
        if (index > 0 and !wraps and !std.mem.eql(u8, gap, "\n")) {
            failLine(frame_number, index, "drops text or a line before it", text);
        }
        const run = text[line.start_offset..][0..line.length];
        if (std.mem.indexOfScalar(u8, run, '\n') != null) {
            failLine(frame_number, index, "holds a newline", text);
        }
        if (wraps) {
            counts.wraps += 1;
            checkWrapNeeded(engine, data, lines[index - 1], line);
        }
        checkWidth(engine, data, line, frame_number, index, counts);
        previous_end = line.start_offset + line.length;
    }
    const rest = text[previous_end..];
    if (rest.len > 0 and !std.mem.eql(u8, rest, "\n")) {
        failLine(frame_number, lines.len, "is missing: text after the last line is dropped", text);
    }
}

/// A line is as wide as its codepoints measured together, and its width
/// says so; it fits the wrap width unless it is one word, no whitespace,
/// or one space or tab.
fn checkWidth(
    engine: *LayoutEngine,
    data: *const layout.TextData,
    line: WrappedLine,
    frame_number: u64,
    index: usize,
    counts: *Counts,
) void {
    const run = data.text[line.start_offset..][0..line.length];
    const width = measure(engine, data, run);
    if (@abs(width - line.width) > epsilon) {
        std.debug.panic("vopr text_area: frame {d}: preview line {d} \"{s}\" says it is {d} " ++
            "px wide, but its codepoints measure {d}", .{
            frame_number, index, run, line.width, width,
        });
    }
    if (width <= data.container_width + epsilon) return;
    // What cannot break further may pass the width alone on its line: one
    // word, or one space or tab in a width narrower than it.
    const one_word = std.mem.indexOfAny(u8, run, " \t") == null;
    const one_space = run.len == 1;
    if (one_word or one_space) {
        counts.long_words += 1;
        return;
    }
    std.debug.panic("vopr text_area: frame {d}: preview line {d} \"{s}\" is {d} px wide, " ++
        "past the {d} px wrap width, and is not one word", .{
        frame_number, index, run, width, data.container_width,
    });
}

/// A wrap is needed: what starts the next line does not fit after the
/// line before. A next line starting with a word moved there because the
/// word, or the whitespace after it in the text, did not fit; one starting
/// with whitespace broke where its first space or tab did not fit.
fn checkWrapNeeded(
    engine: *LayoutEngine,
    data: *const layout.TextData,
    before: WrappedLine,
    after: WrappedLine,
) void {
    const text = data.text;
    assert(before.start_offset + before.length == after.start_offset);
    assert(after.start_offset < text.len);
    const start = after.start_offset;
    var end = start + 1;
    if (!isSpace(text[start])) {
        // The word, then its whitespace up to the next word or newline.
        while (end < text.len and !isSpace(text[end]) and text[end] != '\n') end += 1;
        while (end < text.len and isSpace(text[end])) end += 1;
    }
    const head = text[before.start_offset..][0..before.length];
    // Whitespace breaks only after a line's first word: past others, the
    // word moves down with its whitespace instead.
    const body = std.mem.trimEnd(u8, head, " \t");
    if (isSpace(text[start]) and std.mem.indexOfAny(u8, body, " \t") != null) {
        std.debug.panic("vopr text_area: the preview breaks inside the whitespace after " ++
            "\"{s}\", which is not the line's only word", .{head});
    }
    const width = measure(engine, data, text[before.start_offset..end]);
    if (width > data.container_width - epsilon) return;
    std.debug.panic("vopr text_area: the preview wraps \"{s}\" before \"{s}\", but they fit " ++
        "on one line: {d} px of {d}", .{ head, text[start..end], width, data.container_width });
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

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn failLine(frame_number: u64, index: usize, reason: []const u8, text: []const u8) noreturn {
    std.debug.panic("vopr text_area: frame {d}: preview line {d} {s} (text \"{s}\")", .{
        frame_number, index, reason, text,
    });
}
