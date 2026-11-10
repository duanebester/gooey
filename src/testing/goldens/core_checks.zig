//! Milestone 1 exit checks for the 0.4.0 core on TestBackend (plan, phase 3):
//! the IME rect query is answered synchronously, a file dialog requested by a
//! handler opens on the main thread outside the handler, and counter and
//! todo run their traces with no allocation after initialization (the
//! lifecycle guard panics on one) within their component-depth budget.

const std = @import("std");
const gooey = @import("gooey");
const counter = @import("counter_example");
const todo = @import("todo_example");
const actions = @import("actions_example");
const animation = @import("animation_example");
const accessible_form = @import("accessible_form_example");
const code_editor = @import("code_editor_example");
const nested_overlay = @import("nested_overlay_example");
const dashboard = @import("dashboard_example");
const dynamic_counters = @import("dynamic_counters_example");
const images = @import("images_example");
const virtual_list = @import("virtual_list_example");
const data_table = @import("data_table_example");
const lucide = @import("lucide_example");
const components = @import("gooey-components");
const core_driver = @import("core.zig");
const trace_mod = @import("trace.zig");
const traces = @import("traces.zig");

const internals = gooey.internals;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const TextBuffer = gooey.testing.record_dump.TextBuffer;

const testing = std.testing;
const assert = std.debug.assert;

/// Set to print the depth and stack measurements recorded in the plan.
const print_measurements = false;

fn mouse(x: f32, y: f32) gooey.input.MouseEvent {
    return .{
        .position = .{ .x = x, .y = y },
        .button = .left,
        .click_count = 1,
        .modifiers = .{},
    };
}

test "the IME rect query is answered synchronously from the rendered frame" {
    // Goal: a platform asking for the caret rect inside its IME callback gets
    // an answer without a tick. Methodology: focus todo's draft, compose, and
    // query between ticks. Expected rects come from the synthetic face: "ca"
    // is two 0.5 em glyphs at 16 px, 16 px wide, after the 9 px inset at x 24.
    const Driver = core_driver.CoreDriver(todo.App);
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.todo);
    defer driver.deinit();
    const query = gooey.Query{ .window = &driver.app.window };

    driver.frame();
    try testing.expectEqual(@as(?internals.records.Rect, null), query.imeCursorRect());
    driver.deliver(.{ .mouse_down = mouse(204, 93) });
    driver.frame();
    const empty = query.imeCursorRect().?;
    try testing.expectEqual(@as(f32, 33), empty.x);
    try testing.expectApproxEqAbs(@as(f32, 83.6), empty.y, 0.001);

    driver.deliver(.{ .composition = .{ .text = "ca" } });
    // Before the tick the query still describes the frame on screen.
    try testing.expectEqual(@as(f32, 33), query.imeCursorRect().?.x);
    driver.frame();
    try testing.expectEqual(@as(f32, 49), query.imeCursorRect().?.x);
    try testing.expectEqual(@as(u32, 0), query.imeSelectedRange().?.offset);

    // Committing straight over the preedit, as AppKit's insertText: does,
    // replaces it (0.3.1 asserts here; see the plan's "Noticed" list).
    driver.deliver(.{ .text_input = .{ .text = "caf\u{e9}" } });
    driver.frame();
    try testing.expectEqualStrings("caf\u{e9}", driver.app.state.draft);
    // Three 0.5 em glyphs and one past ASCII at 0.7 em: 24 + 11.2 px.
    try testing.expectApproxEqAbs(@as(f32, 33 + 35.2), query.imeCursorRect().?.x, 0.001);
    try testing.expectEqual(@as(u32, 5), query.imeSelectedRange().?.offset);

    // The range is the selection, not just the caret, so VoiceOver can read
    // it: Shift+Left selects the two-byte é.
    driver.deliver(.{ .key_down = chord(.left, .{ .shift = true }) });
    driver.frame();
    const selected = query.imeSelectedRange().?;
    try testing.expectEqual(@as(u32, 3), selected.offset);
    try testing.expectEqual(@as(u32, 2), selected.len);
}

/// A two-row TextArea, for the area check.
const AreaState = struct { notes: []const u8 = "" };

const AreaApp = gooey.App(AreaState, areaRender, .{
    .title = "Area",
    .width = 300,
    .height = 200,
    .limits = .small,
});

fn areaRender(cx: *Cx) void {
    const state = cx.state(AreaState);
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{
        components.TextArea{ .key = "notes", .bind = &state.notes, .rows = 2 },
    }));
}

/// `count` copies of the two-byte "é", built at comptime.
fn repeatedE(comptime count: u32) [2 * count]u8 {
    @setEvalBranchQuota(4 * count + 1000);
    var bytes: [2 * count]u8 = undefined;
    for (0..count) |index| {
        bytes[2 * index] = 0xC3;
        bytes[2 * index + 1] = 0xA9;
    }
    return bytes;
}

test "one shaped run holds run_codepoint_count_max codepoints and no more" {
    // Goal: the per-run bound every shaper and the text scratch hold, in
    // codepoints rather than bytes. Method: shape exactly the bound in
    // two-byte codepoints (twice the bound in bytes), then one ASCII
    // codepoint past it, which must fail before reaching the shaper.
    const app = try testing.allocator.create(LongRunApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const text_system = app.window.resources.text_system;
    const bound = gooey.text.run_codepoint_count_max;
    const at_bound = comptime repeatedE(bound);
    var run = try text_system.shapeText(.app, &at_bound, .regular, null);
    try testing.expectEqual(@as(usize, bound), run.glyphs.len);
    run.deinit(text_system.run_allocator);
    const past_bound: [bound + 1]u8 = @splat('a');
    try testing.expectError(
        error.TextRunTooLong,
        text_system.shapeText(.app, &past_bound, .regular, null),
    );
}

/// One run one glyph longer than the text system's 128-glyph stack buffers,
/// shown as a text element or as a TextArea line.
const LongRunState = struct {
    area: bool = false,
    notes: []const u8 = &long_run,

    const long_run: [129]u8 = @splat('a');
};

const LongRunApp = gooey.App(LongRunState, longRunRender, .{
    .title = "Long run",
    .width = 1400,
    .height = 200,
    .limits = .small,
});

fn longRunRender(cx: *Cx) void {
    const state = cx.state(LongRunState);
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{
        if (state.area) components.TextArea{
            .key = "notes",
            .bind = &state.notes,
            .rows = 1,
            .width = 1300,
        } else null,
        if (state.area) null else ui.text(&LongRunState.long_run, .{}),
    }));
}

fn spriteCount(frame: *const internals.records.Frame) u32 {
    var count: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record == .sprite) count += 1;
    }
    return count;
}

test "a run past 128 glyphs places every glyph, as text and as a TextArea line" {
    // Goal: glyph placement batches its 128-entry stack buffers. Before
    // batching, a 129-glyph run failed an assertion in Debug and wrote past
    // the buffers in release. Method: paint 129 'a's as a text element and as
    // a TextArea line wide enough to show them all; count the glyph sprites,
    // and check that the last glyph sits 128 advances (8 px) after the first.
    inline for (.{ false, true }) |area| {
        const app = try testing.allocator.create(LongRunApp);
        defer testing.allocator.destroy(app);
        try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
        defer app.deinitHeadless();
        app.state.area = area;
        app.tick(0);
        const frame = app.window.rendered();
        try testing.expectEqual(@as(u32, 129), spriteCount(frame));
        var first: ?f32 = null;
        var last: f32 = 0;
        for (frame.paint[0..frame.paint_count]) |record| {
            if (record != .sprite) continue;
            if (first == null) first = record.sprite.bounds.x;
            last = record.sprite.bounds.x;
        }
        try testing.expectApproxEqAbs(first.? + 128 * 8, last, 0.001);
    }
}

fn deliverAll(app: *LongRunApp, now: *u64, inputs: []const gooey.input.InputEvent) void {
    for (inputs) |event| app.window.queue.push(.{ .input = event });
    now.* += 1;
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

/// A clipboard service that counts the writes it receives and reads empty.
const CountingClipboard = struct {
    fn read(context: *anyopaque, out: []u8) u32 {
        _ = context;
        assert(out.len > 0);
        return 0;
    }

    fn write(context: *anyopaque, text: []const u8) void {
        assert(text.len > 0);
        const writes: *u32 = @ptrCast(@alignCast(context));
        writes.* += 1;
    }
};

test "a TextArea refuses a line's 1025th character and keeps running" {
    // Goal: typing, an IME commit, a paste, and a join stop at the line bound
    // (`line_codepoint_count_max`) rather than reaching the paint, where a
    // longer run fails fast. Method: bind a TextArea to a line of 1024 'c's,
    // put the caret at its end, then type, commit, and paste past the bound;
    // each edit keeps only what fits, cut on a codepoint boundary, and the
    // app keeps ticking with its lifecycle still running.
    const app = try testing.allocator.create(LongRunApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const full: [internals.text_engine.line_codepoint_count_max]u8 = @splat('c');
    app.state.area = true;
    app.state.notes = &full;
    var now: u64 = 0;
    app.tick(now);
    const command: gooey.input.Modifiers = if (@import("builtin").os.tag == .macos)
        .{ .cmd = true }
    else
        .{ .ctrl = true };
    deliverAll(app, &now, &.{
        .{ .mouse_down = mouse(20, 12) },
        .{ .mouse_up = mouse(20, 12) },
        .{ .key_down = chord(.end, .{}) },
        .{ .text_input = .{ .text = "d" } },
    });
    try testing.expectEqualStrings(&full, app.state.notes);

    // Three codepoints free: the commit keeps "東京!" and drops the "x".
    deliverAll(app, &now, &.{
        .{ .key_down = chord(.delete, .{}) },
        .{ .key_down = chord(.delete, .{}) },
        .{ .key_down = chord(.delete, .{}) },
        .{ .text_input = .{ .text = "\u{6771}\u{4eac}!x" } },
    });
    try testing.expectEqualStrings(full[0..1021] ++ "\u{6771}\u{4eac}!", app.state.notes);

    // A new line starts empty, so a paste fills it to the bound and no more.
    const pasted: [1030]u8 = @splat('p');
    app.window.clipboard.write(&pasted);
    deliverAll(app, &now, &.{
        .{ .key_down = chord(.@"return", .{}) },
        .{ .key_down = chord(.v, command) },
    });
    const notes = app.state.notes;
    const newline = std.mem.indexOfScalar(u8, notes, '\n').?;
    try testing.expectEqualStrings(pasted[0..1024], notes[newline + 1 ..]);

    // Two full lines: removing the newline between them, by Backspace, by
    // typing over a selection that holds it, or by cutting it, would join
    // 2048 codepoints. The refused cut leaves the clipboard alone too.
    var writes: u32 = 0;
    app.window.clipboard.service = .{
        .context = &writes,
        .read = CountingClipboard.read,
        .write = CountingClipboard.write,
    };
    deliverAll(app, &now, &.{
        .{ .key_down = chord(.home, .{}) },
        .{ .key_down = chord(.delete, .{}) },
        .{ .key_down = chord(.left, .{ .shift = true }) },
        .{ .text_input = .{ .text = "q" } },
        .{ .key_down = chord(.x, command) },
    });
    const both = full[0..1021] ++ "\u{6771}\u{4eac}!\n" ++ pasted[0..1024];
    try testing.expectEqualStrings(both, app.state.notes);
    try testing.expectEqual(@as(u32, 0), writes);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "a TextArea takes lines, follows the caret, and places it where clicked" {
    // Goal: the area's engine through the real router, layout, and paint.
    // Methodology: type three lines into two rows, so the area scrolls one
    // line; read the caret from the IME query (its rect is the caret's), then
    // click on the first visible line and move up. The synthetic face draws
    // ASCII at 8 px per glyph, so a click just left of 2.5 glyphs lands at
    // column 2, and one past it would land at 3.
    const app = try testing.allocator.create(AreaApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const query = gooey.Query{ .window = &app.window };
    var now: u64 = 0;
    app.tick(now);
    const inset: f32 = 9; // The default padding and border.
    app.window.queue.push(.{ .input = .{ .mouse_down = mouse(inset + 1, inset + 1) } });
    app.window.queue.push(.{ .input = .{ .mouse_up = mouse(inset + 1, inset + 1) } });
    for ([_][]const u8{ "one", "two", "three" }, 0..) |line, index| {
        if (index > 0) {
            app.window.queue.push(.{ .input = .{ .key_down = chord(.@"return", .{}) } });
        }
        app.window.queue.push(.{ .input = .{ .text_input = .{ .text = line } } });
    }
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    try testing.expectEqualStrings("one\ntwo\nthree", app.state.notes);
    const caret = query.imeCursorRect().?;
    const line_height = caret.height;
    // Line 2 of 3 in two rows: scrolled by one line, so it is the second row.
    try testing.expectApproxEqAbs(inset + line_height, caret.y, 0.001);
    try testing.expectApproxEqAbs(inset + 5 * 8, caret.x, 0.001);

    // The wheel over the area scrolls it, clamped at both ends; over the
    // window outside it, nothing scrolls. `down` is pixels toward the end,
    // and 20 px is past one line; the delta is inverted on macOS, as
    // `ScrollState.wheel` reads it.
    const direction: f32 = if (@import("builtin").os.tag == .macos) -1 else 1;
    const wheel_events = [_]struct { x: f32, y: f32, down: f32, caret_y: f32 }{
        .{ .x = inset + 1, .y = inset + 1, .down = -20, .caret_y = inset + 2 * line_height },
        .{ .x = inset + 1, .y = 150, .down = 200, .caret_y = inset + 2 * line_height },
        .{ .x = inset + 1, .y = inset + 1, .down = 200, .caret_y = inset + line_height },
    };
    for (wheel_events) |step| {
        app.window.queue.push(.{ .input = .{ .scroll = .{
            .position = .{ .x = step.x, .y = step.y },
            .delta = .{ .x = 0, .y = step.down * direction },
            .modifiers = .{},
        } } });
        now += 1;
        app.tick(now);
        try testing.expectApproxEqAbs(step.caret_y, query.imeCursorRect().?.y, 0.001);
    }

    // The first visible row is "two"; 2.5 glyphs in is nearest "tw|o".
    const click = mouse(inset + 2.5 * 8 - 0.5, inset + line_height / 2);
    app.window.queue.push(.{ .input = .{ .mouse_down = click } });
    app.window.queue.push(.{ .input = .{ .mouse_up = click } });
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(u32, 6), query.imeSelectedRange().?.offset);

    // Up keeps column 2 and scrolls the first line back into view.
    app.window.queue.push(.{ .input = .{ .key_down = chord(.up, .{}) } });
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(u32, 2), query.imeSelectedRange().?.offset);
    try testing.expectApproxEqAbs(inset, query.imeCursorRect().?.y, 0.001);
}

/// A one-row CodeEditor, for the editor check. No profile reserves editors.
const EditorState = struct { source: []const u8 = "" };

const editor_limits = limits: {
    var limits = gooey.ResourceLimits.small;
    limits.text.editor.count_max = 1;
    break :limits limits;
};

const EditorApp = gooey.App(EditorState, editorRender, .{
    .title = "Editor",
    .width = 400,
    .height = 200,
    .limits = editor_limits,
});

fn editorRender(cx: *Cx) void {
    const state = cx.state(EditorState);
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{
        components.CodeEditor{ .key = "source", .bind = &state.source, .rows = 1 },
    }));
}

test "a CodeEditor indents with Tab, selects a line from its gutter, and scrolls" {
    // Goal: what the editor adds to the area, through the real router and
    // layout. Methodology: type two lines with a Tab into one row, so the
    // editor scrolls one line; click the gutter beside the visible line, then
    // wheel up. The text starts after the border, the 50 px gutter, its 1 px
    // separator, and the padding.
    const app = try testing.allocator.create(EditorApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const query = gooey.Query{ .window = &app.window };
    const text_x: f32 = 1 + 50 + 1 + 8;
    const text_y: f32 = 1 + 8;
    var now: u64 = 0;
    app.tick(now);
    app.window.queue.push(.{ .input = .{ .mouse_down = mouse(text_x + 1, text_y + 1) } });
    app.window.queue.push(.{ .input = .{ .mouse_up = mouse(text_x + 1, text_y + 1) } });
    app.window.queue.push(.{ .input = .{ .text_input = .{ .text = "fn main() {" } } });
    app.window.queue.push(.{ .input = .{ .key_down = chord(.@"return", .{}) } });
    app.window.queue.push(.{ .input = .{ .key_down = chord(.tab, .{}) } });
    app.window.queue.push(.{ .input = .{ .text_input = .{ .text = "x" } } });
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    try testing.expectEqualStrings("fn main() {\n    x", app.state.source);
    const caret = query.imeCursorRect().?;
    const line_height = caret.height;
    try testing.expectApproxEqAbs(text_y, caret.y, 0.001);
    // Four spaces at 4 px, then "x" at 8 px.
    try testing.expectApproxEqAbs(text_x + 4 * 4 + 8, caret.x, 0.001);

    // The visible row is line 2; its number selects it, newline-less.
    const gutter_click = mouse(20, text_y + line_height / 2);
    app.window.queue.push(.{ .input = .{ .mouse_down = gutter_click } });
    app.window.queue.push(.{ .input = .{ .mouse_up = gutter_click } });
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    const selected = query.imeSelectedRange().?;
    try testing.expectEqual(@as(u32, 12), selected.offset);
    try testing.expectEqual(@as(u32, 5), selected.len);

    // The wheel reaches the editor: 20 px toward the start, past one line
    // and inverted on macOS, so line 2 moves down a row.
    const direction: f32 = if (@import("builtin").os.tag == .macos) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = text_x + 1, .y = text_y + 1 },
        .delta = .{ .x = 0, .y = -20 * direction },
        .modifiers = .{},
    } } });
    now += 1;
    app.tick(now);
    try testing.expectApproxEqAbs(text_y + line_height, query.imeCursorRect().?.y, 0.001);
}

/// A scroll box holding a shorter scroll box and a filler, for the scroll
/// check. The inner box shows 60 of its 90 px; the outer shows 150 of 260.
const ScrollApp = gooey.App(struct {}, scrollRender, .{
    .title = "Scroll",
    .width = 300,
    .height = 300,
    .limits = gooey.ResourceLimits.small,
});

const scroll_row_height: f32 = 30;

fn scrollRender(cx: *Cx) void {
    const fixed = struct {
        fn height(value: f32) ui.Style {
            return .{ .width = .{ .fixed = 200 }, .height = .{ .fixed = value } };
        }
    };
    var outer = fixed.height(150);
    outer.scroll = .{};
    var inner = fixed.height(60);
    inner.scroll = .{};
    cx.render(ui.box(.{ .key = .{ .name = "outer" }, .style = outer }, .{
        ui.box(.{ .key = .{ .name = "inner" }, .style = inner }, .{ScrollRows{}}),
        ui.box(.{ .style = fixed.height(200) }, .{}),
    }));
}

const ScrollRows = struct {
    pub fn render(_: ScrollRows, cx: *Cx) void {
        for (0..3) |index| {
            cx.render(ui.box(.{
                .key = .{ .index = index },
                .style = .{
                    .width = .{ .fixed = 200 },
                    .height = .{ .fixed = scroll_row_height },
                    .background = .{ .rgba = ui.Color.white },
                },
            }, .{}));
        }
    }
};

/// The rendered frame's two scroll boxes and their retained offsets.
const ScrollView = struct {
    outer: *const internals.records.HitRecord,
    inner: *const internals.records.HitRecord,
    inner_index: u32,
    outer_offset: f32,
    inner_offset: f32,

    fn read(window: *internals.window.Window) ScrollView {
        const frame = window.rendered();
        var outer: ?*const internals.records.HitRecord = null;
        var inner_index: u32 = internals.records.index_none;
        for (frame.hits[0..frame.hit_count], 0..) |*record, index| {
            if (!record.scroll) continue;
            if (record.parent == internals.records.index_none) {
                outer = record;
            } else {
                inner_index = @intCast(index);
            }
        }
        const inner = &frame.hits[inner_index];
        const State = internals.window.ScrollState;
        return .{
            .outer = outer.?,
            .inner = inner,
            .inner_index = inner_index,
            .outer_offset = window.retained.find(State, outer.?.id).?.offset_y,
            .inner_offset = window.retained.find(State, inner.id).?.offset_y,
        };
    }
};

fn scrollWheel(app: *ScrollApp, now: *u64, x: f32, y: f32, down: f32) void {
    // Offsets follow the delta, inverted on macOS (`ScrollState.wheel`).
    const direction: f32 = if (@import("builtin").os.tag == .macos) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = x, .y = y },
        .delta = .{ .x = 0, .y = down * direction },
        .modifiers = .{},
    } } });
    now.* += 1;
    app.tick(now.*);
}

test "a scroll box clips its content, clamps its offset, and passes the wheel on at its end" {
    // Goal: `Style.scroll` through the real router, layout, and emit.
    // Methodology: wheel the inner box past its end, then again so the outer
    // box takes it; wheel the outer past its start. The inner box's rows
    // must hit only inside its clip, which leaves room for its scrollbar.
    const app = try testing.allocator.create(ScrollApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    // The first emit measures the overflow, so the scrollbar's clip needs one
    // more frame; after it the content is steady and nothing re-renders.
    try testing.expect(app.window.render_requested);
    now += 1;
    app.tick(now);
    try testing.expect(!app.window.render_requested);

    var view = ScrollView.read(&app.window);
    const inner_x = view.inner.bounds.x + 10;
    const inner_y = view.inner.bounds.y + 10;
    scrollWheel(app, &now, inner_x, inner_y, 20);
    view = ScrollView.read(&app.window);
    try testing.expectEqual(@as(f32, 20), view.inner_offset);
    try testing.expectEqual(@as(f32, 0), view.outer_offset);
    // The inner box moved 10 of the 50 to its end, so it keeps the wheel.
    scrollWheel(app, &now, inner_x, inner_y, 50);
    view = ScrollView.read(&app.window);
    try testing.expectEqual(@as(f32, 30), view.inner_offset);
    try testing.expectEqual(@as(f32, 0), view.outer_offset);

    // Row 0 is scrolled out of the inner clip and row 1 fills its top half,
    // 200 px wide less the 10 px scrollbar room.
    const frame = app.window.rendered();
    var rows: u32 = 0;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.parent != view.inner_index) continue;
        rows += 1;
        if (rows == 1) try testing.expectEqual(@as(f32, 0), record.bounds.height);
        if (rows == 2) {
            try testing.expectEqual(view.inner.bounds.y, record.bounds.y);
            try testing.expectEqual(scroll_row_height, record.bounds.height);
            try testing.expectEqual(@as(f32, 190), record.bounds.width);
        }
    }
    try testing.expectEqual(@as(u32, 3), rows);

    scrollWheel(app, &now, inner_x, inner_y, 50);
    view = ScrollView.read(&app.window);
    try testing.expectEqual(@as(f32, 30), view.inner_offset);
    try testing.expectEqual(@as(f32, 50), view.outer_offset);

    // Past the outer box's start, over the filler: it clamps to zero.
    scrollWheel(app, &now, inner_x, view.outer.bounds.y + 140, -100);
    view = ScrollView.read(&app.window);
    try testing.expectEqual(@as(f32, 0), view.outer_offset);
    try testing.expectEqual(@as(f32, 30), view.inner_offset);
}

fn scrollMouse(app: anytype, now: *u64, event: gooey.input.InputEvent) void {
    app.window.queue.push(.{ .input = event });
    now.* += 1;
    app.tick(now.*);
}

fn thumbDragged(app: *ScrollApp) bool {
    const frame = app.window.rendered();
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record != .quad) continue;
        if (record.quad.fill.a == 0.5 and record.quad.fill.r == 0) return true;
    }
    return false;
}

test "a scroll box's thumb drags and its track jumps, as 0.3.1's did" {
    // Goal: scrollbar parity with 0.3.1's ScrollContainer. Methodology: the
    // outer box shows 150 of 260 px, so its 146 px track holds an 84.23 px
    // thumb with 61.77 px of travel for 110 px of offset. Drag the thumb half
    // its travel and past its end, then press the track a quarter down. (The
    // inner box's bar lies under the outer one's gutter, outside its clip.)
    const app = try testing.allocator.create(ScrollApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    const box = ScrollView.read(&app.window).outer.bounds;
    const bar_x = box.x + box.width - 10 + 4;
    const travel: f32 = 146.0 - 146.0 * 150.0 / 260.0;

    scrollMouse(app, &now, .{ .mouse_down = mouse(bar_x, box.y + 10) });
    try testing.expect(thumbDragged(app));
    scrollMouse(app, &now, .{ .mouse_dragged = mouse(bar_x, box.y + 10 + travel / 2) });
    try testing.expectApproxEqAbs(@as(f32, 55), ScrollView.read(&app.window).outer_offset, 0.01);
    // Dragging past the end clamps; the inner box does not move.
    scrollMouse(app, &now, .{ .mouse_dragged = mouse(bar_x, box.y + 400) });
    const view = ScrollView.read(&app.window);
    try testing.expectEqual(@as(f32, 110), view.outer_offset);
    try testing.expectEqual(@as(f32, 0), view.inner_offset);
    scrollMouse(app, &now, .{ .mouse_up = mouse(bar_x, box.y + 400) });
    try testing.expect(!thumbDragged(app));
    // Moving after the release drags nothing.
    scrollMouse(app, &now, .{ .mouse_moved = mouse(bar_x, box.y + 5) });
    try testing.expectEqual(@as(f32, 110), ScrollView.read(&app.window).outer_offset);

    // At the end the thumb sits at the bottom; the track's top quarter
    // jumps to a quarter of the offset.
    const quarter = box.y + 2 + 146 * 0.25;
    scrollMouse(app, &now, .{ .mouse_down = mouse(bar_x, quarter) });
    scrollMouse(app, &now, .{ .mouse_up = mouse(bar_x, quarter) });
    try testing.expectApproxEqAbs(@as(f32, 27.5), ScrollView.read(&app.window).outer_offset, 0.01);
    try testing.expect(!thumbDragged(app));
    try testing.expectEqual(gooey.ElementId.root, app.window.scroll_drag);
}

/// A Select in a clipped panel above a button, for the popover check. The
/// panel is shorter than the open menu, and the menu covers the button.
const SelectState = struct {
    selected: ?usize = null,
    open: bool = false,
    below_clicks: u32 = 0,

    const options = [_][]const u8{ "One", "Two", "Three" };

    pub fn toggle(self: *SelectState) void {
        self.open = !self.open;
    }

    pub fn close(self: *SelectState) void {
        self.open = false;
    }

    pub fn choose(self: *SelectState, index: u32) void {
        self.selected = index;
        self.open = false;
    }

    pub fn below(self: *SelectState) void {
        self.below_clicks += 1;
    }
};

const SelectApp = gooey.App(SelectState, selectRender, .{
    .title = "Select",
    .width = 400,
    .height = 300,
    .limits = gooey.ResourceLimits.small,
});

fn selectRender(cx: *Cx) void {
    const state = cx.state(SelectState);
    var on_select: [SelectState.options.len]gooey.Handler = undefined;
    for (&on_select, 0..) |*handler, index| {
        handler.* = cx.on(SelectState.choose, .{ .arg = @as(u32, @intCast(index)) });
    }
    cx.render(ui.box(.{ .style = .{ .padding = .all(10), .gap = 8 } }, .{
        ui.box(.{ .style = .{ .height = .{ .fixed = 50 }, .clip = .clip } }, .{
            components.Select{
                .key = "level",
                .options = &SelectState.options,
                .on_select = &on_select,
                .on_toggle = cx.on(SelectState.toggle, .{}),
                .on_close = cx.on(SelectState.close, .{}),
                .selected = state.selected,
                .open = state.open,
                .accessible_name = "Level",
                .accessible_description = "How far along you are",
            },
        }),
        components.Button{ .label = "Below", .on_click = cx.on(SelectState.below, .{}) },
    }));
}

fn clickAt(app: anytype, now: *u64, x: f32, y: f32) void {
    app.window.queue.push(.{ .input = .{ .mouse_down = mouse(x, y) } });
    app.window.queue.push(.{ .input = .{ .mouse_up = mouse(x, y) } });
    now.* += 1;
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

fn comboboxState(app: *SelectApp) gooey.accessibility.State {
    const frame = app.window.rendered();
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != .combobox) continue;
        assert(std.mem.eql(u8, "How far along you are", frame.text(node.description).?));
        return node.state;
    }
    unreachable;
}

test "a Select's menu opens on a popover above content and outside its clip" {
    // Goal: the `.popover` layer through the real router and emit. Method:
    // open the menu, whose options overflow the 50 px clipped panel and
    // cover the button below it; click where an option and the button
    // overlap; reopen and click outside. The option must win the click.
    const app = try testing.allocator.create(SelectApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    try testing.expect(!comboboxState(app).expanded);
    try testing.expect(comboboxState(app).has_popup);

    clickAt(app, &now, 20, 20);
    try testing.expect(app.state.open);
    try testing.expect(comboboxState(app).expanded);
    const frame = app.window.rendered();
    var button: ?internals.records.Rect = null;
    var options: [3]internals.records.Rect = undefined;
    var option_count: u32 = 0;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.on_click == internals.records.index_none) continue;
        if (record.fragment == 1) {
            options[option_count] = record.bounds;
            option_count += 1;
        } else if (record.bounds.y > 50) {
            button = record.bounds;
        }
    }
    try testing.expectEqual(@as(u32, 3), option_count);
    // The panel clips at y = 60; the menu escapes it.
    try testing.expect(options[2].y + options[2].height > 60);
    const target = button.?;
    var chosen: ?usize = null;
    for (options, 0..) |option, index| {
        if (option.contains(target.x + 10, target.y + 4)) chosen = index;
    }
    clickAt(app, &now, target.x + 10, target.y + 4);
    try testing.expectEqual(chosen.?, app.state.selected.?);
    try testing.expectEqual(@as(u32, 0), app.state.below_clicks);
    try testing.expect(!app.state.open);

    clickAt(app, &now, 20, 20);
    try testing.expect(app.state.open);
    clickAt(app, &now, 390, 290);
    try testing.expect(!app.state.open);
    try testing.expectEqual(chosen.?, app.state.selected.?);
    try testing.expect(!comboboxState(app).expanded);
}

/// A button in content beside a small modal that does not cover it, for the
/// modal blocking check: the modal's own records never reach the button, so
/// only the blocking rule keeps the pointer off it.
const BlockState = struct {
    modal_open: bool = true,
    below_clicks: u32 = 0,
    inside_clicks: u32 = 0,

    pub fn below(self: *BlockState) void {
        self.below_clicks += 1;
    }

    pub fn inside(self: *BlockState) void {
        self.inside_clicks += 1;
        self.modal_open = false;
    }
};

const BlockApp = gooey.App(BlockState, blockRender, .{
    .title = "Block",
    .width = 400,
    .height = 300,
    .limits = .nano,
});

fn blockRender(cx: *Cx) void {
    const state = cx.state(BlockState);
    cx.render(ui.box(.{ .style = .{ .padding = .all(10) } }, .{
        components.Button{ .label = "Below", .on_click = cx.on(BlockState.below, .{}) },
        if (state.modal_open) ui.box(.{
            .layer = .{
                .kind = .modal,
                .anchor = .{ .window = .{ .x = 200, .y = 150 } },
                .clip = .escape,
            },
            .style = .{ .width = .{ .fixed = 120 }, .height = .{ .fixed = 80 } },
        }, .{
            components.Button{ .label = "Inside", .on_click = cx.on(BlockState.inside, .{}) },
        }) else null,
    }));
}

test "a modal blocks the pointer on every fragment opened before it" {
    // Goal: contract §6, "a modal fragment blocks hit testing of earlier
    // fragments". Method: a 120 x 80 modal at (200, 150) leaves the content
    // button at the top left uncovered; clicking, hovering, and the hit
    // query over the button must all miss it until the modal closes.
    const app = try testing.allocator.create(BlockApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const query = gooey.Query{ .window = &app.window };
    const frame = app.window.rendered();
    try testing.expect(frame.modal_hit_start > 0);
    const below = frame.hits[0..frame.modal_hit_start];
    var button: ?internals.records.Rect = null;
    for (below) |*record| {
        if (record.on_click != internals.records.index_none) button = record.bounds;
    }
    const target = button.?;
    try testing.expect(target.x + target.width < 200);
    const x = target.x + target.width / 2;
    const y = target.y + target.height / 2;
    try testing.expectEqual(@as(?gooey.ElementId, null), query.hitTest(.{ .x = x, .y = y }));
    clickAt(app, &now, x, y);
    try testing.expectEqual(@as(u32, 0), app.state.below_clicks);

    clickAt(app, &now, 230, 165);
    try testing.expectEqual(@as(u32, 1), app.state.inside_clicks);
    try testing.expectEqual(@as(u32, 0), app.window.rendered().modal_hit_start);
    try testing.expect(query.hitTest(.{ .x = x, .y = y }) != null);
    clickAt(app, &now, x, y);
    try testing.expectEqual(@as(u32, 1), app.state.below_clicks);
}

test "nested_overlay: a Select's menu inside a modal sits above the modal" {
    // Goal: contract §6, "a layer opened inside a layer's fragment comes
    // after that fragment", through the ported 0.3.1 regression example.
    // Method: the modal and its Select start open; the menu's options cover
    // the modal's keyed yellow area. The options must come after the modal
    // in paint and hit order and take the click over the area beneath.
    const app = try testing.allocator.create(nested_overlay.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const frame = app.window.rendered();
    // Content has no hit records here, so the modal's are the first.
    const modal_start = frame.modal_hit_start;
    const modal_fragment = frame.hits[modal_start].fragment;
    try testing.expect(modal_fragment > 0);
    var area: ?internals.records.Rect = null;
    var options: [nested_overlay.options.len]internals.records.Rect = undefined;
    var option_count: u32 = 0;
    for (frame.hits[modal_start..frame.hit_count]) |*record| {
        if (record.fragment == modal_fragment) {
            if (record.bounds.height == 120) area = record.bounds;
        } else {
            try testing.expect(record.fragment > modal_fragment);
            if (record.on_click == internals.records.index_none) continue;
            options[option_count] = record.bounds;
            option_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, nested_overlay.options.len), option_count);
    // "Bravo" lies over the yellow area, as the example promises.
    const bravo = options[1];
    const x = bravo.x + 20;
    const y = bravo.y + bravo.height / 2;
    try testing.expect(area.?.contains(x, y));
    try testing.expect(dialogCount(frame) == 1);

    clickAt(app, &now, x, y);
    try testing.expectEqual(@as(?usize, 1), app.state.selected);
    try testing.expect(!app.state.select_open);
}

fn dialogCount(frame: *const internals.records.Frame) u32 {
    var count: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role == .dialog) count += 1;
    }
    return count;
}

/// An app whose button opens a file dialog, for the dialog check. Its first
/// three clicks open a multiple selection; the fourth saves with a name it
/// builds in its state.
const DialogState = struct {
    clicks: u32 = 0,
    name: [11]u8 = "draft-0.txt".*,
    path_bytes: [256]u8 = undefined,
    path_len: u32 = 0,
    path_count: u32 = 0,
    cancelled: u32 = 0,
    failed: u32 = 0,

    pub fn completed(self: *DialogState, effects: *Effects) void {
        const completion = effects.completionEvent().?;
        switch (completion.outcome) {
            .file_selected => |paths| {
                @memcpy(self.path_bytes[0..paths.bytes.len], paths.bytes);
                self.path_len = @intCast(paths.bytes.len);
                self.path_count = paths.count;
            },
            .cancelled => self.cancelled += 1,
            .failed => self.failed += 1,
        }
    }
};

const DialogApp = gooey.App(DialogState, dialogRender, .{
    .title = "Dialog",
    .width = 200,
    .height = 100,
    .limits = .nano,
});

fn dialogRender(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{
        components.Button{ .label = "Open", .on_click = cx.on(openDialog, .{}) },
    }));
}

fn openDialog(self: *DialogState, effects: *Effects) void {
    const on_complete = effects.handler(DialogState.completed);
    self.clicks += 1;
    if (self.clicks <= 3) {
        effects.openFileDialog(.{
            .kind = .{ .open = .{ .files = true, .directories = false, .multiple = true } },
            .on_complete = on_complete,
        });
        return;
    }
    self.name[6] = '0' + @as(u8, @intCast(self.clicks));
    effects.openFileDialog(.{
        .kind = .{ .save = .{ .directory = "/tmp", .suggested_name = &self.name } },
        .on_complete = on_complete,
    });
}

/// A dialog service that records where it ran and answers from a script.
const ScriptedDialog = struct {
    window: *const internals.window.Window,
    main_thread: std.Thread.Id,
    opened_on_main: u32 = 0,
    opened_in_drain: u32 = 0,
    answers: []const internals.events.Completion.Outcome,
    next: u32 = 0,
    saved_name: [16]u8 = undefined,
    saved_name_len: u32 = 0,

    fn open(
        context: *anyopaque,
        scratch: std.mem.Allocator,
        request_id: u32,
        request: internals.handler.FileDialogRequest,
    ) ?internals.events.Completion.Outcome {
        const self: *ScriptedDialog = @ptrCast(@alignCast(context));
        _ = scratch;
        _ = request_id;
        switch (request.kind) {
            .open => |options| std.debug.assert(options.multiple),
            .save => |options| {
                const name = options.suggested_name.?;
                @memcpy(self.saved_name[0..name.len], name);
                self.saved_name_len = @intCast(name.len);
                std.debug.assert(std.mem.eql(u8, options.directory.?, "/tmp"));
                // The window's copy, not the handler's state.
                const copy = self.window.dialog_request_bytes;
                std.debug.assert(name.ptr == copy.ptr + "/tmp".len);
            },
        }
        if (std.Thread.getCurrentId() == self.main_thread) self.opened_on_main += 1;
        if (self.window.phase == .drain) self.opened_in_drain += 1;
        const answer = self.answers[self.next];
        self.next += 1;
        return answer;
    }
};

test "a file dialog opened from a handler runs on the main thread after the handler" {
    // Goal: plan exit criterion and decision 11's options. Methodology: click
    // a button whose handler requests a dialog; the scripted service records
    // the thread and phase it ran in, and answers two selected paths, then
    // cancelled, then failed, then one saved path. Each answer must reach
    // the completion handler as a distinct outcome a tick later, and only
    // that tick may build (the Mac's stale frame after a dialog). The save's
    // folder and name must reach the service from the window's own copy.
    const app = try testing.allocator.create(DialogApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var service = ScriptedDialog{
        .window = &app.window,
        .main_thread = std.Thread.getCurrentId(),
        .answers = &.{
            .{ .file_selected = .{ .bytes = "/tmp/notes.txt\x00/tmp/b", .count = 2 } },
            .cancelled,
            .{ .failed = error.AccessDenied },
            .{ .file_selected = .{ .bytes = "/tmp/draft-4.txt", .count = 1 } },
        },
    };
    app.window.file_dialog = .{ .context = &service, .open = ScriptedDialog.open };

    var now: u64 = 0;
    app.tick(now);
    var round: u32 = 0;
    while (round < 4) : (round += 1) {
        app.window.queue.push(.{ .input = .{ .mouse_down = mouse(20, 20) } });
        app.window.queue.push(.{ .input = .{ .mouse_up = mouse(20, 20) } });
        const built = app.window.frame_number;
        now += 1;
        app.tick(now); // The click opens the dialog after the drain.
        // No frame of the state before the outcome; the render waits for it.
        try testing.expectEqual(built, app.window.frame_number);
        try testing.expect(app.window.render_requested);
        now += 1;
        app.tick(now); // The next drain delivers the outcome and builds once.
        try testing.expectEqual(built + 1, app.window.frame_number);
        if (round == 0) {
            try testing.expectEqual(@as(u32, 2), app.state.path_count);
            const selected = app.state.path_bytes[0..app.state.path_len];
            try testing.expectEqualStrings("/tmp/notes.txt\x00/tmp/b", selected);
        }
    }
    try testing.expectEqual(@as(u32, 4), service.opened_on_main);
    try testing.expectEqual(@as(u32, 4), service.opened_in_drain);
    try testing.expectEqualStrings("draft-4.txt", service.saved_name[0..service.saved_name_len]);
    try testing.expectEqual(@as(u32, 1), app.state.path_count);
    const saved = app.state.path_bytes[0..app.state.path_len];
    try testing.expectEqualStrings("/tmp/draft-4.txt", saved);
    try testing.expectEqual(@as(u32, 1), app.state.cancelled);
    try testing.expectEqual(@as(u32, 1), app.state.failed);
}

test "a file dialog that stays open completes later through the queue" {
    // Goal: the deferred half of `FileDialogService` (Linux's portal keeps
    // its loop turning). Methodology: the service returns no outcome and
    // records the request ids. The tick that opened a dialog must still
    // build, two dialogs may be open at once, and each completion pushed
    // between ticks must reach its handler, in either order, free its slot,
    // and build the frame that shows it.
    const app = try testing.allocator.create(DialogApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var service = DeferredDialog{};
    app.window.file_dialog = .{ .context = &service, .open = DeferredDialog.open };

    var now: u64 = 0;
    app.tick(now);
    var opened: u32 = 0;
    while (opened < 2) : (opened += 1) {
        app.window.queue.push(.{ .input = .{ .mouse_down = mouse(20, 20) } });
        app.window.queue.push(.{ .input = .{ .mouse_up = mouse(20, 20) } });
        const built = app.window.frame_number;
        now += 1;
        app.tick(now);
        // Nothing waited on the dialog, so the click's frame is built.
        try testing.expectEqual(built + 1, app.window.frame_number);
        try testing.expectEqual(opened + 1, service.count);
        try testing.expect(app.window.dialog_handlers[service.ids[opened]] != null);
    }
    try testing.expect(service.ids[0] != service.ids[1]);

    // The second dialog closes first.
    app.window.queue.push(.{ .completion = .{
        .request_id = service.ids[1],
        .outcome = .cancelled,
    } });
    var built = app.window.frame_number;
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(u32, 1), app.state.cancelled);
    try testing.expectEqual(built + 1, app.window.frame_number);
    try testing.expect(app.window.dialog_handlers[service.ids[1]] == null);
    try testing.expect(app.window.dialog_handlers[service.ids[0]] != null);

    const paths = internals.events.Paths{ .bytes = "/tmp/a\x00/tmp/bc", .count = 2 };
    app.window.queue.push(.{ .completion = .{
        .request_id = service.ids[0],
        .outcome = .{ .file_selected = paths },
    } });
    built = app.window.frame_number;
    now += 1;
    app.tick(now);
    try testing.expectEqual(built + 1, app.window.frame_number);
    try testing.expectEqual(@as(u32, 2), app.state.path_count);
    const selected = app.state.path_bytes[0..app.state.path_len];
    try testing.expectEqualStrings("/tmp/a\x00/tmp/bc", selected);
    try testing.expect(app.window.dialog_handlers[service.ids[0]] == null);
}

test "counter and todo run their traces with no allocation after init" {
    // Goal: plan exit criterion and the depth measurement approved decision 1
    // asks for. Methodology: every core allocation goes through the
    // lifecycle guard, which panics while running, so finishing each trace
    // proves none happened. The deepest nesting must fit the budget.
    inline for (.{
        .{ counter.App, counter.render, &traces.counter },
        .{ todo.App, todo.render, &traces.todo },
    }) |case| {
        const Driver = core_driver.CoreDriver(case[0]);
        const driver = try testing.allocator.create(Driver);
        defer testing.allocator.destroy(driver);
        try driver.initInPlace(testing.allocator, testing.io, case[2]);
        defer driver.deinit();
        const storage = try testing.allocator.alloc(u8, 256 * 1024);
        defer testing.allocator.free(storage);
        var out = TextBuffer.init(storage, "trace");
        trace_mod.run(driver, case[2], &out);
        const window = &driver.app.window;
        try testing.expectEqual(
            internals.lifecycle.Lifecycle.running,
            driver.app.guard.lifecycle,
        );
        try testing.expect(window.component_depth_peak >= 3);
        try testing.expect(window.component_depth_peak <= case[0].limits.build.component_depth_max);
        if (print_measurements) {
            std.debug.print("{s}: depth {d}, {d} stack bytes per level, {d} init bytes\n", .{
                case[2].name,
                window.component_depth_peak,
                window.stackBytesPerLevel(),
                driver.app.guard.init_bytes,
            });
        }
    }
}

test "a frame in flight defers the next build while input keeps draining" {
    // Goal: contract rule 1's handoff, run on one thread. Methodology: build
    // a frame with `tickMain` and hold it in flight; a second click must
    // still reach its handler (against the rendered frame) but must neither
    // build nor flip until the render side presents, and the main thread
    // flips and builds at its next tick.
    const Driver = core_driver.CoreDriver(counter.App);
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.counter);
    defer driver.deinit();
    const tick = internals.tick;
    const window = &driver.app.window;
    driver.frame();
    const first = window.rendered().frame_number;
    const now = driver.now_ns;

    window.queue.push(.{ .input = .{ .mouse_down = mouse(155, 245) } });
    window.queue.push(.{ .input = .{ .mouse_up = mouse(155, 245) } });
    try testing.expect(tick.tickMain(&driver.app, window, now + 1));
    try testing.expect(window.frame_in_flight.load(.acquire));
    try testing.expectEqual(@as(i32, 1), driver.app.state.count);

    window.queue.push(.{ .input = .{ .mouse_down = mouse(155, 245) } });
    window.queue.push(.{ .input = .{ .mouse_up = mouse(155, 245) } });
    try testing.expect(!tick.tickMain(&driver.app, window, now + 2));
    try testing.expectEqual(@as(i32, 2), driver.app.state.count);
    try testing.expect(window.render_requested);
    try testing.expectEqual(first, window.rendered().frame_number);

    tick.presentBuilt(window);
    try testing.expect(!window.frame_in_flight.load(.acquire));
    // Presented but not yet flipped: the query still sees the old frame.
    try testing.expectEqual(first, window.rendered().frame_number);
    try testing.expect(tick.tickMain(&driver.app, window, now + 3));
    try testing.expectEqual(first + 1, window.rendered().frame_number);
    try testing.expectEqual(first + 2, window.built().frame_number);
    tick.presentBuilt(window);
}

test "every build opens an atlas frame so the glyph LRU can evict" {
    // Goal: regression for the Mac run that exhausted counter's nano text
    // atlas: the core never opened atlas frames, so every glyph stayed
    // protected "since frame 1" and the LRU never evicted. Methodology: the
    // synthetic face's glyphs are too few to fill the atlas, so check the
    // mechanism directly: each built frame advances the atlas frame clock,
    // and a tick that builds nothing leaves it alone.
    const Driver = core_driver.CoreDriver(counter.App);
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.counter);
    defer driver.deinit();
    const uploads = driver.app.resources.atlas_uploads;
    driver.frame();
    const first = uploads.frameCurrent();
    try testing.expect(first > 0);
    var click: u32 = 0;
    while (click < 3) : (click += 1) {
        driver.deliver(.{ .mouse_down = mouse(155, 245) });
        driver.deliver(.{ .mouse_up = mouse(155, 245) });
        driver.frame();
    }
    try testing.expectEqual(first + 3, uploads.frameCurrent());
    driver.frame(); // Nothing requested a render.
    try testing.expectEqual(first + 3, uploads.frameCurrent());
}

/// Four 40 px rows above empty space, for the cursor check: a Button, a
/// TextInput, a box that sets only a cursor around a keyed child that sets
/// none, and a keyed box whose cursor follows its state.
const CursorState = struct {
    draft: []const u8 = "",
    text: bool = false,

    fn toggle(self: *CursorState) void {
        self.text = !self.text;
    }
};

const CursorApp = gooey.App(CursorState, cursorRender, .{
    .title = "Cursor",
    .width = 300,
    .height = 200,
    .limits = .nano,
});

const CursorShape = @FieldType(internals.window.Window, "cursor");

fn cursorRender(cx: *Cx) void {
    const state = cx.state(CursorState);
    const row: ui.Style = .{ .height = .{ .fixed = 40 } };
    const square: ui.Style = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 30 } };
    var flip = square;
    flip.cursor = if (state.text) .text else .pointer;
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{
        ui.box(.{ .style = row }, .{
            components.Button{ .label = "Go", .on_click = cx.on(CursorState.toggle, .{}) },
        }),
        ui.box(.{ .style = row }, .{
            components.TextInput{ .key = "draft", .bind = &state.draft },
        }),
        ui.box(.{ .style = row }, .{
            ui.box(.{ .style = .{ .padding = .all(5), .cursor = .pointer } }, .{
                ui.box(.{ .key = .{ .name = "leaf" }, .style = square }, .{}),
            }),
        }),
        ui.box(.{ .style = row }, .{
            ui.box(.{
                .key = .{ .name = "flip" },
                .on_click = cx.on(CursorState.toggle, .{}),
                .style = flip,
            }, .{}),
        }),
    }));
}

fn cursorAt(app: *CursorApp, now: *u64, x: f32, y: f32) CursorShape {
    app.window.queue.push(.{ .input = .{ .mouse_moved = mouse(x, y) } });
    now.* += 1;
    app.tick(now.*);
    return app.window.cursor;
}

test "the cursor resolves from the hovered record and its ancestors" {
    // Goal: the cursor hosts apply after a tick comes from the record under
    // the pointer, as `Box.cursor` did in 0.3.1. Method: move over each row.
    // The leaf sets no cursor, so its cursor-only parent's applies; a box
    // whose cursor changes under a still pointer resolves anew from the next
    // frame; empty space and a pointer outside the window give `.default`.
    const app = try testing.allocator.create(CursorApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    try testing.expectEqual(CursorShape.default, app.window.cursor);
    try testing.expectEqual(CursorShape.pointer, cursorAt(app, &now, 4, 4));
    try testing.expectEqual(CursorShape.text, cursorAt(app, &now, 4, 44));
    try testing.expectEqual(CursorShape.pointer, cursorAt(app, &now, 10, 90));
    try testing.expectEqual(CursorShape.pointer, cursorAt(app, &now, 2, 82));
    try testing.expectEqual(CursorShape.pointer, cursorAt(app, &now, 10, 130));
    try testing.expectEqual(CursorShape.default, cursorAt(app, &now, 10, 180));
    try testing.expectEqual(CursorShape.default, cursorAt(app, &now, 280, 4));

    // The flip box turns its cursor to `.text` while the pointer stays put.
    _ = cursorAt(app, &now, 10, 130);
    clickAt(app, &now, 10, 130);
    try testing.expect(app.state.text);
    try testing.expectEqual(CursorShape.text, app.window.cursor);
    app.window.queue.push(.{ .input = .{ .mouse_exited = mouse(10, 130) } });
    now += 1;
    app.tick(now);
    try testing.expectEqual(CursorShape.default, app.window.cursor);
}

test "clicks fire on release over the pressed control" {
    // Goal: decision 7's click-on-release rule. Methodology: on counter, a
    // press alone must not click; releasing over the pressed "+" clicks it
    // once; pressing "+" and releasing over "-" clicks neither; a release
    // with no press clicks nothing. Expected counts follow from step 1.
    const Driver = core_driver.CoreDriver(counter.App);
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.counter);
    defer driver.deinit();
    const state = &driver.app.state;
    driver.frame();

    driver.deliver(.{ .mouse_down = mouse(155, 245) });
    driver.frame();
    try testing.expectEqual(@as(i32, 0), state.count);
    driver.deliver(.{ .mouse_up = mouse(160, 250) });
    driver.frame();
    try testing.expectEqual(@as(i32, 1), state.count);

    driver.deliver(.{ .mouse_down = mouse(155, 245) });
    driver.deliver(.{ .mouse_up = mouse(70, 245) });
    driver.frame();
    try testing.expectEqual(@as(i32, 1), state.count);

    driver.deliver(.{ .mouse_up = mouse(155, 245) });
    driver.frame();
    try testing.expectEqual(@as(i32, 1), state.count);
}

const FontState = struct {
    pub fn useSerif(_: *FontState, effects: *Effects) void {
        effects.setFont("Synthetic Serif", 20);
    }
};

/// Two families (decision 8): the app family and a synthetic `.monospace`
/// second family, whose glyphs all advance by 0.6 em.
const FontApp = gooey.App(FontState, fontRender, .{
    .title = "Fonts",
    .width = 300,
    .height = 100,
    .limits = .nano,
    .fonts = .{
        .mono = .{ .system = .monospace },
        .limits = .{ .variants = &.{.regular}, .mono_variants = &.{.regular} },
    },
});

fn fontRender(cx: *Cx) void {
    cx.render(ui.box(.{
        .key = .{ .name = "fonts" },
        .on_click = cx.on(FontState.useSerif, .{}),
        .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 4 },
    }, .{
        ui.text("mmm", .{ .size = 16 }),
        ui.text("mmm", .{ .size = 16, .family = .mono }),
    }));
}

/// The x of every glyph sprite in the rendered frame, in paint order.
fn spriteXs(window: *const internals.window.Window, out: []f32) u32 {
    const frame = window.rendered();
    var count: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        switch (record) {
            .sprite => |sprite| {
                std.debug.assert(count < out.len);
                out[count] = sprite.bounds.x;
                count += 1;
            },
            else => {},
        }
    }
    return count;
}

test "mono text draws with the second family's advances" {
    // Goal: decision 8's `Text.family`. Methodology: the synthetic app face
    // advances 'm' by 0.8 em and the synthetic `.monospace` face by 0.6 em,
    // so at 16 px the app run's glyphs sit 12.8 px apart and the mono run's
    // 9.6 px apart. A run measured or placed with the wrong family would
    // show the other spacing. Glyphs snap to whole pixels, hence the
    // tolerance on each run's two-advance span.
    const app = try testing.allocator.create(FontApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(1);
    var xs: [8]f32 = undefined;
    try testing.expectEqual(@as(u32, 6), spriteXs(&app.window, &xs));
    try testing.expectApproxEqAbs(@as(f32, 25.6), xs[2] - xs[0], 1);
    try testing.expectApproxEqAbs(@as(f32, 19.2), xs[5] - xs[3], 1);
}

test "effects.setFont reloads the app family once no frame is in flight" {
    // Goal: decision 8's `setFont`, applied after the drain. Methodology: the
    // first click lands while a frame is in flight, so the reload waits: the
    // app family stays at 16 pt until the render side presents, then the
    // next tick loads it at 20 pt. The mono family keeps its own size.
    const app = try testing.allocator.create(FontApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const tick = internals.tick;
    const window = &app.window;
    const text_system = app.resources.text_system;
    app.tick(1); // A rendered frame for the click to hit.
    window.render_requested = true;
    try testing.expect(tick.tickMain(app, window, 2));
    try testing.expect(window.frame_in_flight.load(.acquire));

    window.queue.push(.{ .input = .{ .mouse_down = mouse(10, 10) } });
    window.queue.push(.{ .input = .{ .mouse_up = mouse(10, 10) } });
    try testing.expect(!tick.tickMain(app, window, 3));
    try testing.expect(window.pending_font != null);
    try testing.expectEqual(@as(f32, 16), text_system.getMetrics().?.point_size);

    tick.presentBuilt(window);
    try testing.expect(tick.tickMain(app, window, 4));
    try testing.expect(window.pending_font == null);
    try testing.expectEqual(@as(f32, 20), text_system.getMetrics().?.point_size);
    try testing.expectEqual(@as(f32, 16), text_system.getMetricsFor(.mono).point_size);
    tick.presentBuilt(window);
}

const WrapState = struct {};

const WrapApp = gooey.App(WrapState, wrapRender, .{
    .title = "Wrap",
    .width = 300,
    .height = 200,
    .limits = .nano,
});

/// A 110 px column with 10 px of left padding, so text wraps against 100 px.
fn wrapRender(cx: *Cx) void {
    cx.render(ui.box(.{
        .style = .{ .width = .{ .fixed = 110 }, .padding = .{ .left = 10 } },
    }, .{
        ui.text("mmm mmm mmm mmm", .{
            .size = 10,
            .wrap = .words,
            .line_height = 150,
            .alignment = .right,
        }),
        ui.text("mm\nmmm mmm mmm mmm", .{ .size = 10, .wrap = .newlines, .alignment = .center }),
        ui.text("m", .{ .size = 10 }),
    }));
}

/// The first sprite of each run of glyphs that share a top edge.
fn lineStarts(window: *const internals.window.Window, out: []internals.records.Rect) u32 {
    const frame = window.rendered();
    var count: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        const sprite = switch (record) {
            .sprite => |sprite| sprite,
            else => continue,
        };
        if (count > 0 and out[count - 1].y == sprite.bounds.y) continue;
        std.debug.assert(count < out.len);
        out[count] = sprite.bounds;
        count += 1;
    }
    return count;
}

test "wrapped text draws one run per line, pitched and aligned like its layout box" {
    // Goal: decision 9's `wrap`, `line_height`, and `alignment`. Methodology:
    // the synthetic face advances 'm' by 0.8 em and space by 0.25 em with a
    // 1.2 em line height, so at 10 px "mmm" is 24 px, a space 2.5 px, and a
    // line 12 px. In 100 px, ".words" fits three words (77 px) and wraps the
    // fourth (24 px); right-aligned they start 23 and 76 px in, 18 px apart
    // at 150%. ".newlines" ignores the width: "mm" (16 px) and the 103.5 px
    // line center at 42 and -1.75 px, 12 px apart. Each block's height is
    // its line count times its pitch (36 and 24 px), so the blocks stack
    // above the last text at -60 and -24 px. Every line starts with 'm', so
    // the unwrapped last text is the reference for both axes; glyphs snap to
    // whole pixels.
    const app = try testing.allocator.create(WrapApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(1);
    var starts: [8]internals.records.Rect = undefined;
    try testing.expectEqual(@as(u32, 5), lineStarts(&app.window, &starts));
    const reference = starts[4];
    const expected_x = [_]f32{ 23, 76, 42, -1.75 };
    const expected_y = [_]f32{ -60, -42, -24, -12 };
    for (starts[0..4], expected_x, expected_y) |start, x, y| {
        try testing.expectApproxEqAbs(x, start.x - reference.x, 1);
        try testing.expectApproxEqAbs(y, start.y - reference.y, 1);
    }
}

test "a host's teardown frees through the guard after stop and leaves no atlas consumer" {
    // Goal: the shutdown order every platform host follows (Bug A on Linux:
    // frees under a running guard, then an atlas consumer left registered).
    // Methodology: replay a host's lifecycle on TestBackend. A host record is
    // reserved through the guard during init and registers an atlas consumer;
    // after a tick, `stop` leaves `running`, the host unregisters and frees
    // its record, and `deinit` frees the core, whose upload journal asserts
    // that no consumer is left. A free before `stop` would panic in the guard.
    const app = try testing.allocator.create(WrapApp);
    defer testing.allocator.destroy(app);
    app.beginInit(testing.allocator);
    try app.initCore(testing.io, 1);
    const gpa = app.guard.allocator();
    const host_record = try gpa.create([64]u8);
    const key = @intFromPtr(host_record);
    app.resources.registerAtlasConsumer(key);
    app.window.atlas_consumer_key = key;
    app.finishInit();
    app.tick(1);
    try testing.expectEqual(@as(u32, 1), app.resources.atlas_uploads.consumer_count);

    app.stop();
    app.resources.unregisterAtlasConsumer(key);
    gpa.destroy(host_record);
    try testing.expectEqual(@as(u32, 0), app.resources.atlas_uploads.consumer_count);
    app.deinit();
}

const ThemeState = struct {
    pub fn goDark(_: *ThemeState, effects: *Effects) void {
        effects.setTheme(&gooey.Theme.dark);
        effects.announce("Dark theme", .polite);
    }
};

const ThemeApp = gooey.App(ThemeState, themeRender, .{
    .title = "Theme",
    .width = 200,
    .height = 100,
    .limits = .nano,
});

fn themeRender(cx: *Cx) void {
    cx.render(ui.box(.{
        .key = .{ .name = "page" },
        .on_click = cx.on(ThemeState.goDark, .{}),
        .a11y = .{ .role = .heading, .label = "Settings", .heading_level = .h2 },
        .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .background = .surface },
    }, .{
        ui.box(.{
            .a11y = .{ .role = .link, .label = "Docs", .live = .polite, .href = "https://x.dev" },
            .style = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } },
        }, .{}),
    }));
}

fn firstFill(frame: *const internals.records.Frame) internals.records.Color {
    for (frame.paint[0..frame.paint_count]) |record| {
        switch (record) {
            .quad => |quad| return quad.fill,
            else => {},
        }
    }
    unreachable;
}

test "setTheme reaches the next build and announcements ride exactly one frame" {
    // Goal: decision 10's C11 and C9 on the core. Methodology: click while a
    // frame is in flight, so neither request may touch that frame; the next
    // build resolves tokens and the clear colour against the dark theme and
    // carries the announcement, and the build after it carries none. The
    // accessibility fields reach the rendered frame unchanged.
    const app = try testing.allocator.create(ThemeApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const tick = internals.tick;
    const window = &app.window;
    const light = &gooey.Theme.light;
    const dark = &gooey.Theme.dark;
    app.tick(1);
    const first = window.rendered();
    try testing.expectEqual(@as(u32, 2), first.a11y_count);
    try testing.expectEqual(.h2, first.a11y[0].heading_level);
    try testing.expectEqual(.polite, first.a11y[1].live);
    try testing.expectEqualStrings("https://x.dev", first.text(first.a11y[1].href).?);
    try testing.expectEqual(light.surface, firstFill(first));

    window.render_requested = true;
    try testing.expect(tick.tickMain(app, window, 2));
    window.queue.push(.{ .input = .{ .mouse_down = mouse(100, 50) } });
    window.queue.push(.{ .input = .{ .mouse_up = mouse(100, 50) } });
    try testing.expect(!tick.tickMain(app, window, 3));
    try testing.expectEqual(light.bg, window.clear_color);
    try testing.expectEqual(@as(u32, 0), window.built().announcements.count);

    tick.presentBuilt(window);
    try testing.expect(tick.tickMain(app, window, 4));
    tick.presentBuilt(window);
    app.tick(5);
    const darkened = window.rendered();
    try testing.expectEqual(dark.bg, window.clear_color);
    try testing.expectEqual(dark.surface, firstFill(darkened));
    try testing.expectEqual(@as(u32, 1), darkened.announcements.count);
    const said = darkened.announcements.slice()[0];
    try testing.expectEqual(.polite, said.live);
    try testing.expectEqualStrings("Dark theme", darkened.announcements.text(said));

    window.render_requested = true;
    app.tick(6);
    try testing.expectEqual(@as(u32, 0), window.rendered().announcements.count);
}

test "keymapClaims answers from the rendered focus path" {
    // Goal: the synchronous query platforms ask before handing a key to the
    // IME (`performKeyEquivalent`) agrees with what the drain dispatches.
    // Methodology: cmd-s is bound only in the editor's context, so it is
    // claimed only once the editor input is focused; an unbound key never
    // is, and a global binding always is.
    const Driver = core_driver.CoreDriver(actions.AppWith(.cmd));
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.actions);
    defer driver.deinit();
    const query = gooey.Query{ .window = &driver.app.window };
    const save = chord(.s, .{ .cmd = true });
    driver.frame();
    try testing.expect(!query.keymapClaims(save));
    try testing.expect(query.keymapClaims(chord(.z, .{ .cmd = true })));
    try testing.expect(!query.keymapClaims(chord(.a, .{})));

    driver.deliver(.{ .mouse_down = mouse(124, 120) });
    driver.deliver(.{ .mouse_up = mouse(124, 120) });
    driver.frame();
    try testing.expect(query.keymapClaims(save));
    try testing.expect(!query.keymapClaims(chord(.a, .{})));
}

fn chord(key: gooey.input.KeyCode, modifiers: gooey.input.Modifiers) gooey.input.KeyEvent {
    return .{
        .key = key,
        .modifiers = modifiers,
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = false,
    };
}

const ClockState = struct {
    /// The delay each build asks for; 0 asks for nothing.
    delay_ms: u32 = 100,
    builds: u32 = 0,
};

const ClockApp = gooey.App(ClockState, clockRender, .{
    .title = "Clock",
    .width = 100,
    .height = 100,
    .limits = .nano,
});

fn clockRender(cx: *Cx) void {
    const state = cx.state(ClockState);
    state.builds += 1;
    if (state.delay_ms > 0) cx.requestRenderAfter(state.delay_ms);
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}));
}

test "cx.requestRenderAfter renders once at the earliest deadline of the last build" {
    // Goal: the per-window deadline (contract §5). Methodology: a build at
    // t = 1 ms asks for 100 ms. Ticks before 101 ms build nothing; the tick
    // at 101 ms builds and renews it. A build that asks for nothing clears
    // the deadline, so no later tick builds.
    const ms = std.time.ns_per_ms;
    const app = try testing.allocator.create(ClockApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const state = &app.state;
    app.tick(1 * ms);
    try testing.expectEqual(@as(u32, 1), state.builds);
    try testing.expectEqual(@as(?u64, 101 * ms), app.window.renderDeadlineNs());
    app.tick(50 * ms);
    app.tick(101 * ms - 1);
    try testing.expectEqual(@as(u32, 1), state.builds);
    app.tick(101 * ms);
    try testing.expectEqual(@as(u32, 2), state.builds);
    try testing.expectEqual(@as(?u64, 201 * ms), app.window.renderDeadlineNs());
    state.delay_ms = 0;
    app.tick(201 * ms);
    try testing.expectEqual(@as(u32, 3), state.builds);
    try testing.expectEqual(@as(?u64, null), app.window.renderDeadlineNs());
    app.tick(10_000 * ms);
    try testing.expectEqual(@as(u32, 3), state.builds);
}

/// Which helper `motionRender` builds, so each check sees only its own
/// render requests.
const MotionPart = enum { tween, tween_on, row, motion };

const MotionState = struct {
    part: MotionPart = .tween,
    show: bool = true,
    trigger: u64 = 0,
    value: f32 = -1,
    motion: gooey.animation.Motion = gooey.animation.Motion.hidden,
};

const MotionApp = gooey.App(MotionState, motionRender, .{
    .title = "Motion",
    .width = 100,
    .height = 100,
    .limits = .nano,
});

fn motionRender(cx: *Cx) void {
    const s = cx.state(MotionState);
    const linear: gooey.animation.Tween = .{
        .duration_ms = 100,
        .easing = gooey.animation.Easing.linear,
    };
    switch (s.part) {
        .tween => s.value = gooey.animation.tween(cx, .{ .name = "fade" }, linear),
        .tween_on => s.value = gooey.animation.tweenOn(cx, .{ .name = "pulse" }, s.trigger, linear),
        .row => if (s.show) {
            var delayed = linear;
            delayed.delay_ms = 50;
            s.value = gooey.animation.tween(cx, .{ .index = 3 }, delayed);
        },
        .motion => s.motion = gooey.animation.motion(cx, .{ .name = "panel" }, s.show, .snappy),
    }
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}));
}

/// Change the state as a handler would, then build at `now_ms`.
fn motionBuild(app: *MotionApp, now_ms: u64) void {
    app.window.render_requested = true;
    app.tick(now_ms * std.time.ns_per_ms);
}

fn motionIdle(app: *MotionApp) bool {
    return app.window.renderDeadlineNs() == null and !app.window.render_requested;
}

test "tweens follow the clock, wait out their delay, replay on return, and then go idle" {
    // Goal: `animation.tween` and `tweenOn` against the window clock, with
    // render requests only while they move. Method: build a 100 ms linear
    // tween at 0, 50, and 100 ms; a 50 ms delayed one must ask for its first
    // frame at the delay's end, not sooner; a finished one hidden for a build
    // plays again; a trigger tween starts at 1 and replays from 0 on change.
    const ms = std.time.ns_per_ms;
    const app = try testing.allocator.create(MotionApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const s = &app.state;
    app.tick(1_000 * ms);
    try testing.expectEqual(@as(f32, 0), s.value);
    try testing.expectEqual(@as(?u64, 1_000 * ms), app.window.renderDeadlineNs());
    app.tick(1_050 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.value, 1e-6);
    app.tick(1_100 * ms);
    try testing.expectEqual(@as(f32, 1), s.value);
    try testing.expect(motionIdle(app));

    s.part = .row;
    motionBuild(app, 2_000);
    try testing.expectEqual(@as(f32, 0), s.value);
    try testing.expectEqual(@as(?u64, 2_050 * ms), app.window.renderDeadlineNs());
    app.tick(2_049 * ms);
    try testing.expectEqual(@as(?u64, 2_050 * ms), app.window.renderDeadlineNs());
    app.tick(2_100 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.value, 1e-6);
    app.tick(2_150 * ms);
    try testing.expectEqual(@as(f32, 1), s.value);
    // Built again without leaving: it stays finished.
    motionBuild(app, 2_200);
    try testing.expectEqual(@as(f32, 1), s.value);
    try testing.expect(motionIdle(app));
    s.show = false;
    motionBuild(app, 2_300);
    s.show = true;
    motionBuild(app, 2_400);
    try testing.expectEqual(@as(f32, 0), s.value);
    app.tick(2_500 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.value, 1e-6);

    s.part = .tween_on;
    motionBuild(app, 3_000);
    try testing.expectEqual(@as(f32, 1), s.value);
    try testing.expect(motionIdle(app));
    s.trigger = 7;
    motionBuild(app, 3_100);
    try testing.expectEqual(@as(f32, 0), s.value);
    app.tick(3_125 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s.value, 1e-6);
    app.tick(3_200 * ms);
    try testing.expectEqual(@as(f32, 1), s.value);
    try testing.expect(motionIdle(app));
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "a motion springs in, reverses mid-flight without a snap, and settles hidden" {
    // Goal: `animation.motion`'s enter and exit, and that a toggle keeps the
    // spring's velocity (0.3.1's springMotion). Method: show at 1 s and step
    // at 60 Hz for 100 ms; hide, and the next frame must still be further in
    // (the spring was moving out) and report `.exiting`. Step to rest: the
    // motion ends hidden with nothing left to draw.
    const ms = std.time.ns_per_ms;
    const app = try testing.allocator.create(MotionApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const s = &app.state;
    s.part = .motion;
    var now: u64 = 1_000 * ms;
    app.tick(now);
    try testing.expectEqual(gooey.animation.Phase.entering, s.motion.phase);
    try testing.expectEqual(@as(f32, 0), s.motion.progress);
    for (0..6) |_| {
        now += 16 * ms;
        app.tick(now);
    }
    const before = s.motion.progress;
    try testing.expect(before > 0.2);
    try testing.expect(before < 0.95);
    s.show = false;
    now += 16 * ms;
    motionBuild(app, now / ms);
    try testing.expectEqual(gooey.animation.Phase.exiting, s.motion.phase);
    try testing.expect(s.motion.visible);
    try testing.expect(s.motion.progress > before);
    var frames: u32 = 0;
    while (!motionIdle(app)) : (frames += 1) {
        try testing.expect(frames < 120);
        now += 16 * ms;
        app.tick(now);
    }
    try testing.expectEqual(gooey.animation.Motion.hidden, s.motion);
    const built = app.window.frame_number;
    app.tick(now + 10_000 * ms);
    try testing.expectEqual(built, app.window.frame_number);
}

/// Tick at 60 Hz until the window has nothing left to draw; returns the
/// frames built on the way.
fn animationSettle(app: *animation.App, now: *u64) u32 {
    const built = app.window.frame_number;
    var ticks: u32 = 0;
    while (app.window.renderDeadlineNs() != null or app.window.render_requested) : (ticks += 1) {
        assert(ticks < 240); // Four seconds: every animation here is shorter.
        now.* += 16 * std.time.ns_per_ms;
        app.tick(now.*);
    }
    return @intCast(app.window.frame_number - built);
}

fn animationClick(app: *animation.App, now: *u64, label: []const u8) void {
    const bounds = nodeNamed(&app.window, .button, label).?.bounds;
    clickAt(app, now, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
}

test "animation plays its entrances, toggles, and stagger, then goes idle" {
    // Goal: the animation example on the core: every animation ends and the
    // window then draws nothing, with no allocation after init (the
    // lifecycle guard panics on one). Method: settle the launch fade and
    // panel spring; show the list and count its rows; interrupt the panel's
    // exit with a show; pulse the counter; hide the list. Each must settle
    // within the bound and leave no render pending.
    const app = try testing.allocator.create(animation.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = std.time.ns_per_s;
    app.tick(now);
    // The 500 ms fade alone needs about 31 frames at 60 Hz.
    try testing.expect(animationSettle(app, &now) >= 30);
    try testing.expect(nodeNamed(&app.window, .button, "Hide Panel") != null);

    animationClick(app, &now, "Show List");
    try testing.expect(animationSettle(app, &now) > 10);
    try testing.expect(nodeNamed(&app.window, .button, "Hide List") != null);

    animationClick(app, &now, "Hide Panel");
    now += 100 * std.time.ns_per_ms;
    app.tick(now);
    animationClick(app, &now, "Show Panel");
    try testing.expect(animationSettle(app, &now) > 0);

    animationClick(app, &now, "+");
    try testing.expectEqual(@as(i32, 1), app.state.count);
    try testing.expect(animationSettle(app, &now) > 5);
    animationClick(app, &now, "Hide List");
    try testing.expect(animationSettle(app, &now) > 5);
    const built = app.window.frame_number;
    app.tick(now + 10 * std.time.ns_per_s);
    try testing.expectEqual(built, app.window.frame_number);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

/// The rendered accessibility node named `name`, by role.
fn formNode(
    app: *accessible_form.App,
    role: gooey.ui.Role,
    name: []const u8,
) ?*const internals.records.A11yNode {
    const frame = app.window.rendered();
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != role) continue;
        if (std.mem.eql(u8, frame.text(node.name) orelse "", name)) return node;
    }
    return null;
}

/// Scroll the form until the node is in the window; returns its bounds.
fn formReveal(
    app: *accessible_form.App,
    now: *u64,
    role: gooey.ui.Role,
    name: []const u8,
) internals.records.Rect {
    var node = formNode(app, role, name).?;
    var steps: u32 = 0;
    while (node.bounds.y < 10 or node.bounds.y + node.bounds.height > 790) : (steps += 1) {
        assert(steps < 20);
        const down: f32 = if (node.bounds.y < 10) -200 else 200;
        const direction: f32 = if (@import("builtin").os.tag == .macos) -1 else 1;
        app.window.queue.push(.{ .input = .{ .scroll = .{
            .position = .{ .x = 300, .y = 400 },
            .delta = .{ .x = 0, .y = down * direction },
            .modifiers = .{},
        } } });
        now.* += 1;
        app.tick(now.*);
        node = formNode(app, role, name).?;
    }
    return node.bounds;
}

/// Click the centre of a node, scrolling the form first so it is visible.
fn formClick(app: *accessible_form.App, now: *u64, role: gooey.ui.Role, name: []const u8) void {
    const bounds = formReveal(app, now, role, name);
    clickAt(app, now, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
}

fn formType(app: *accessible_form.App, now: *u64, name: []const u8, text: []const u8) void {
    formClick(app, now, .textbox, name);
    app.window.queue.push(.{ .input = .{ .text_input = .{ .text = text } } });
    now.* += 1;
    app.tick(now.*);
}

test "accessible_form validates, announces, and submits on the core" {
    // Goal: the accessible_form port end to end through the router, with the
    // lifecycle guard proving no allocation after init. Methodology: submit
    // the empty form and read the alerts, field descriptions, and the
    // assertive announcement; fill it in, pick a radio, an experience level,
    // and the terms, then submit and read the success alert.
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    const radio = formNode(app, .radio, "Phone").?;
    try testing.expectEqual(@as(?u16, 2), radio.pos_in_set);
    try testing.expectEqual(@as(?u16, 3), radio.set_size);
    try testing.expect(!radio.state.checked);

    // The announcement rides the one frame the submit builds.
    const submit = formReveal(app, &now, .button, "Submit registration form");
    const submit_x = submit.x + submit.width / 2;
    const submit_y = submit.y + submit.height / 2;
    app.window.queue.push(.{ .input = .{ .mouse_down = mouse(submit_x, submit_y) } });
    app.window.queue.push(.{ .input = .{ .mouse_up = mouse(submit_x, submit_y) } });
    now += 1;
    app.tick(now);
    try testing.expect(formNode(app, .alert, "Name is required") != null);
    try testing.expect(formNode(app, .alert, "Valid email is required") != null);
    const frame = app.window.rendered();
    try testing.expectEqual(@as(u32, 1), frame.announcements.count);
    const said = frame.announcements.slice()[0];
    const said_text = frame.announcements.text(said);
    try testing.expectEqualStrings("Please fix the errors in the form", said_text);
    const name_field = formNode(app, .textbox, "Full name, required field").?;
    try testing.expectEqualStrings("Error: Name is required", frame.text(name_field.description).?);

    formType(app, &now, "Full name, required field", "Ada Lovelace");
    formType(app, &now, "Email address, required field", "ada@example.com");
    formClick(app, &now, .radio, "Phone");
    try testing.expect(formNode(app, .radio, "Phone").?.state.checked);
    formClick(app, &now, .combobox, "Experience level");
    try testing.expect(formNode(app, .combobox, "Experience level").?.state.expanded);
    // The first option sits just below the 40 px trigger.
    const combobox = formNode(app, .combobox, "Experience level").?.bounds;
    clickAt(app, &now, combobox.x + 20, combobox.y + 60);
    try testing.expectEqual(@as(?usize, 0), app.state.experience_level);
    formClick(app, &now, .checkbox, "Accept terms and conditions, required");
    formClick(app, &now, .button, "Submit registration form");
    try testing.expect(app.state.show_success);
    try testing.expectEqualStrings("Ada Lovelace", app.state.name);
    const success = "Registration successful! Thank you for signing up.";
    try testing.expect(formNode(app, .alert, success) != null);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

/// A folder dialog that answers with one path, as the platform's would.
const FolderDialog = struct {
    path: []const u8,
    opened: u32 = 0,

    fn open(
        context: *anyopaque,
        scratch: std.mem.Allocator,
        request_id: u32,
        request: internals.handler.FileDialogRequest,
    ) ?internals.events.Completion.Outcome {
        const self: *FolderDialog = @ptrCast(@alignCast(context));
        _ = scratch;
        _ = request_id;
        assert(request.kind.open.directories);
        assert(!request.kind.open.files);
        self.opened += 1;
        return .{ .file_selected = .{ .bytes = self.path, .count = 1 } };
    }
};

/// A dialog service whose dialogs stay open: it records each request id and
/// returns no outcome, as Linux's portal host does.
const DeferredDialog = struct {
    ids: [2]u32 = undefined,
    count: u32 = 0,

    fn open(
        context: *anyopaque,
        scratch: std.mem.Allocator,
        request_id: u32,
        request: internals.handler.FileDialogRequest,
    ) ?internals.events.Completion.Outcome {
        const self: *DeferredDialog = @ptrCast(@alignCast(context));
        _ = scratch;
        assert(request.kind == .open);
        assert(self.count < self.ids.len);
        self.ids[self.count] = request_id;
        self.count += 1;
        return null;
    }
};

/// The rendered accessibility node named `name`, by role, in any app.
fn nodeNamed(
    window: *internals.window.Window,
    role: gooey.ui.Role,
    name: []const u8,
) ?*const internals.records.A11yNode {
    const frame = window.rendered();
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != role) continue;
        if (std.mem.eql(u8, frame.text(node.name) orelse "", name)) return node;
    }
    return null;
}

/// The file rows the list built this frame: buttons other than the dialog's.
fn editorRowsBuilt(app: *code_editor.App) u32 {
    const frame = app.window.rendered();
    var count: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != .button) continue;
        if (std.mem.eql(u8, frame.text(node.name) orelse "", "Open Folder")) continue;
        count += 1;
    }
    return count;
}

fn editorClickRow(app: *code_editor.App, now: *u64, name: []const u8) void {
    const row = nodeNamed(&app.window, .button, name).?.bounds;
    clickAt(app, now, row.x + row.width / 2, row.y + row.height / 2);
}

/// Resize the window to `height` and settle: the resize renders, then the
/// emit that measures the list's new viewport may ask for one more.
fn editorResize(app: *code_editor.App, now: *u64, height: f32) void {
    app.window.queue.push(.{ .window = .{ .resized = .{
        .width = 1000,
        .height = height,
        .scale_factor = 1,
    } } });
    now.* += 1;
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

/// Wheel the file list down until the row named `name` is built.
fn editorWheelTo(app: *code_editor.App, now: *u64, name: []const u8) void {
    const list = nodeNamed(&app.window, .button, "a.zig").?.bounds;
    const direction: f32 = if (@import("builtin").os.tag == .macos) -1 else 1;
    var steps: u32 = 0;
    while (nodeNamed(&app.window, .button, name) == null) : (steps += 1) {
        assert(steps < 10);
        app.window.queue.push(.{ .input = .{ .scroll = .{
            .position = .{ .x = list.x + 10, .y = list.y + 10 },
            .delta = .{ .x = 0, .y = 400 * direction },
            .modifiers = .{},
        } } });
        now.* += 1;
        app.tick(now.*);
        now.* += 1;
        app.tick(now.*);
    }
}

/// A folder of 47 visible files: 40 numbered text files and seven that
/// exercise each status, plus a hidden file and a folder the list skips.
/// `line1024.txt` holds a line of 1024 two-byte codepoints, at the shaping
/// bound in codepoints but twice it in bytes; `line1025.txt` is one past.
fn editorFolder(dir: std.Io.Dir) !void {
    const io = testing.io;
    var name_buffer: [16]u8 = undefined;
    for (0..40) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "file{d:0>2}.txt", .{index});
        try dir.writeFile(io, .{ .sub_path = name, .data = name });
    }
    try dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try dir.writeFile(io, .{ .sub_path = "bad.txt", .data = "\xff\xfe" });
    try dir.writeFile(io, .{ .sub_path = "img.png", .data = "\x89PNG" });
    try dir.writeFile(io, .{ .sub_path = "Notes.md", .data = "# Notes\n" });
    const at_bound = "x\n".* ++ repeatedE(gooey.text.run_codepoint_count_max) ++ "\n".*;
    try dir.writeFile(io, .{ .sub_path = "line1024.txt", .data = &at_bound });
    const past_bound: [gooey.text.run_codepoint_count_max + 1]u8 = @splat('a');
    try dir.writeFile(io, .{ .sub_path = "line1025.txt", .data = &past_bound });
    try dir.writeFile(io, .{ .sub_path = ".hidden", .data = "x" });
    try dir.createDir(io, "sub", .default_dir);
    const big = try testing.allocator.alloc(u8, code_editor.file_bytes_max + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try dir.writeFile(io, .{ .sub_path = "big.txt", .data = big });
}

test "code_editor's editor fills its panel at any window height" {
    // Goal: the editor's rows follow the window, as 0.3.1's growing editor
    // did, so none draws past its border. Method: settle at the 700 px
    // launch height, then shrink to 635 px (the height the Windows report
    // used) and grow to 900. At each, the editor's bottom must sit inside
    // the panel (window less the 16 px outer and 8 px panel padding) and
    // within one line of it, so it fills without overflowing, and the
    // window must go idle: the resize's extra render converges.
    const app = try testing.allocator.create(code_editor.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    const line_height = app.window.resources.text_system.getMetrics().?.line_height;
    for ([_]f32{ 700, 635, 900 }) |height| {
        if (height != 700) editorResize(app, &now, height);
        const editor = nodeNamed(&app.window, .textarea, "Enter your code here...").?.bounds;
        const panel_bottom = height - 16 - 8;
        try testing.expect(editor.y + editor.height <= panel_bottom);
        try testing.expect(editor.y + editor.height > panel_bottom - line_height);
        // Settled: the one render the stale height asked for is spent, and
        // nothing more is pending, so an idle window draws no more frames.
        now += 1;
        app.tick(now);
        try testing.expect(app.window.renderDeadlineNs() == null);
        try testing.expect(!app.window.render_requested);
    }
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "code_editor lists a folder in a List and opens its files on the core" {
    // Goal: the code_editor port end to end, with the lifecycle guard
    // proving no allocation after init. Methodology: choose a folder of 47
    // files through a scripted dialog; the List must build only the rows in
    // view, sorted without case, and build the last rows once wheeled to the
    // end. Clicking rows opens a text file into the editor and shows the
    // binary, too-large, image, and line-too-long statuses for the others.
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try editorFolder(folder.dir);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try folder.dir.realPath(testing.io, &path_buffer);

    const app = try testing.allocator.create(code_editor.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var dialog = FolderDialog{ .path = path_buffer[0..path_len] };
    app.window.file_dialog = .{ .context = &dialog, .open = FolderDialog.open };
    var now: u64 = 0;
    app.tick(now);
    try testing.expectEqual(@as(u32, 0), editorRowsBuilt(app));
    const editor = nodeNamed(&app.window, .textarea, "Enter your code here...").?;
    try testing.expect(std.mem.startsWith(u8, app.window.rendered().text(editor.value).?, "const"));

    const open = nodeNamed(&app.window, .button, "Open Folder").?.bounds;
    clickAt(app, &now, open.x + 4, open.y + 4);
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(u32, 1), dialog.opened);
    try testing.expectEqual(@as(u32, 47), app.state.file_count);
    try testing.expectEqualStrings("a.zig", app.state.files[0].text());
    try testing.expectEqualStrings("Notes.md", app.state.files[46].text());
    // Rows of 26 px in a list about 22 rows tall: the visible ones and one
    // partial row, never the folder's last file.
    const built = editorRowsBuilt(app);
    try testing.expect(built >= 10);
    try testing.expect(built < 30);
    try testing.expect(nodeNamed(&app.window, .button, "Notes.md") == null);
    // A taller window shows more rows: its render builds against the old
    // viewport, and the emit that measures the new one asks for another.
    editorResize(app, &now, 1000);
    try testing.expect(editorRowsBuilt(app) >= built + 10);
    try testing.expect(nodeNamed(&app.window, .button, "Notes.md") == null);

    editorClickRow(app, &now, "a.zig");
    try testing.expectEqualStrings("const a = 1;\n", app.state.source);
    const opened = nodeNamed(&app.window, .textarea, "Enter your code here...").?;
    try testing.expectEqualStrings("const a = 1;\n", app.window.rendered().text(opened.value).?);
    editorClickRow(app, &now, "bad.txt");
    try testing.expectEqual(code_editor.FileStatus.binary_file, app.state.status);
    editorClickRow(app, &now, "big.txt");
    try testing.expectEqual(code_editor.FileStatus.file_too_large, app.state.status);

    // Wheel the list to its end: its last rows are built, its first are not.
    editorWheelTo(app, &now, "Notes.md");
    try testing.expect(nodeNamed(&app.window, .button, "a.zig") == null);
    try testing.expect(editorRowsBuilt(app) < 47);
    editorClickRow(app, &now, "img.png");
    try testing.expectEqual(code_editor.FileStatus.image_file, app.state.status);
    try testing.expectEqualStrings("png", app.state.extension_bytes[0..app.state.extension_len]);
    // A line past the shaping bound is refused; one at it opens and paints
    // as eight batches of glyphs.
    editorClickRow(app, &now, "line1025.txt");
    try testing.expectEqual(code_editor.FileStatus.line_too_long, app.state.status);
    editorClickRow(app, &now, "line1024.txt");
    try testing.expectEqual(code_editor.FileStatus.displaying_code, app.state.status);
    try testing.expectEqual(@as(usize, 2 + 2 * 1024 + 1), app.state.source.len);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

/// Chat rows of 0.3.1's virtual_list_example: its five message heights in
/// its ten-row pattern, read from the app's state as a real app's would be.
const ChatState = struct {
    heights: [10]f32 = .{ 48, 48, 48, 72, 72, 120, 180, 48, 48, 32 },
};

const ChatRow = struct {
    index: u32,

    pub const count_max: u32 = 1000;

    pub fn height(cx: *Cx, index: u32) f32 {
        return cx.state(ChatState).heights[index % 10];
    }

    pub fn render(self: ChatRow, cx: *Cx) void {
        var label: [16]u8 = undefined;
        cx.render(ui.box(.{
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
            .a11y = .{ .role = .listitem, .label = listRowLabel(&label, self.index) },
        }, .{}));
    }
};

/// Uniform rows of 30 px, with the same gap and padding as the chat list.
const PlainRow = struct {
    index: u32,

    pub const row_height: f32 = 30;

    pub fn render(self: PlainRow, cx: *Cx) void {
        var label: [16]u8 = undefined;
        cx.render(ui.box(.{
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
            .a11y = .{ .role = .listitem, .label = listRowLabel(&label, self.index) },
        }, .{}));
    }
};

fn listRowLabel(buffer: *[16]u8, index: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "row {d}", .{index}) catch unreachable;
}

fn ListApp(comptime Row: type) type {
    const render = struct {
        fn render(cx: *Cx) void {
            cx.render(components.List(Row){
                .key = "rows",
                .count = 1000,
                .gap = 8,
                .style = .{ .padding = .all(8), .background = .{ .surface = {} } },
            });
        }
    }.render;
    return gooey.App(ChatState, render, .{
        .title = "List",
        .width = 300,
        .height = 300,
        .limits = gooey.ResourceLimits.small,
    });
}

/// The rows built this frame, and the a11y bounds of row `index` if built.
fn listRows(window: *internals.window.Window, index: u32) struct {
    count: u32,
    row: ?internals.records.Rect,
} {
    var label: [16]u8 = undefined;
    const name = listRowLabel(&label, index);
    const frame = window.rendered();
    var count: u32 = 0;
    var row: ?internals.records.Rect = null;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != .listitem) continue;
        count += 1;
        if (std.mem.eql(u8, frame.text(node.name) orelse "", name)) row = node.bounds;
    }
    return .{ .count = count, .row = row };
}

/// Wheel the list down by `down` px at its centre and settle the render the
/// emit requests once it measures the new rows.
fn listWheel(app: anytype, now: *u64, down: f32) void {
    const direction: f32 = if (@import("builtin").os.tag == .macos) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = 150, .y = 150 },
        .delta = .{ .x = 0, .y = down * direction },
        .modifiers = .{},
    } } });
    now.* += 1;
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

fn listOffset(window: *internals.window.Window) *const internals.window.ScrollState {
    const frame = window.rendered();
    for (frame.hits[0..frame.hit_count]) |*record| {
        const State = internals.window.ScrollState;
        if (window.retained.find(State, record.id)) |state| return state;
    }
    unreachable;
}

test "a List of per-row heights builds the rows in view, spaced by its gap and padding" {
    // Goal: variable row heights, as 0.3.1's virtual list, with the
    // lifecycle guard proving no allocation after init. Methodology: 1,000
    // rows, exactly the type's count_max, of the 0.3.1 chat heights (a ten-
    // row cycle of 796 px with 8 px gaps) in a 300 px list padded by 8. Row
    // tops are worked out by hand from that cycle, not from the List, at the
    // start, 500 px down, and at the end.
    const App = ListApp(ChatRow);
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    // Rows 0-4 start at 0, 56, 112, 168, 248 (+8 padding); row 5 at 328 is
    // past the 292 px the padding leaves in view.
    var rows = listRows(&app.window, 3);
    try testing.expectEqual(@as(u32, 5), rows.count);
    try testing.expectEqual(@as(f32, 176), rows.row.?.y);
    try testing.expectEqual(@as(f32, 72), rows.row.?.height);
    try testing.expect(listRows(&app.window, 5).row == null);

    // 500 px down the view spans content 492-792: row 6 (456-636) through
    // row 9 (756-788); row 10 starts at 796.
    listWheel(app, &now, 500);
    try testing.expectEqual(@as(f32, 500), listOffset(&app.window).offset_y);
    rows = listRows(&app.window, 7);
    try testing.expectEqual(@as(u32, 4), rows.count);
    try testing.expectEqual(@as(f32, 8 + 644 - 500), rows.row.?.y);
    try testing.expectEqual(@as(f32, 48), rows.row.?.height);
    try testing.expect(listRows(&app.window, 5).row == null);
    try testing.expect(listRows(&app.window, 10).row == null);

    // 100 cycles less the last gap, plus padding: 79,608 px of content, so
    // the end is 79,308 down, where row 999 (32 px) ends at the padding.
    listWheel(app, &now, 100_000);
    const state = listOffset(&app.window);
    try testing.expectEqual(@as(f32, 79_608), state.content_height);
    try testing.expectEqual(@as(f32, 79_308), state.offset_y);
    rows = listRows(&app.window, 999);
    try testing.expectEqual(@as(f32, 300 - 8), rows.row.?.y + rows.row.?.height);
    try testing.expect(listRows(&app.window, 0).row == null);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "a List of one row height takes its gap and padding into the rows in view" {
    // Goal: the constant-time range of uniform rows with a gap. Methodology:
    // 30 px rows 8 px apart pitch at 38 px. At the start, rows 0-7 start
    // before 292 px (row 7 at 266). 500 px down the view spans content
    // 492-792: the pitch puts row 12 (456-486) first, an extra row above
    // the view, row 13 (494) first in it, and row 20 (760) last.
    const App = ListApp(PlainRow);
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    var rows = listRows(&app.window, 7);
    try testing.expectEqual(@as(f32, 8 + 266), rows.row.?.y);
    try testing.expectEqual(@as(f32, 30), rows.row.?.height);
    try testing.expect(listRows(&app.window, 0).row != null);

    listWheel(app, &now, 500);
    rows = listRows(&app.window, 13);
    try testing.expectEqual(@as(f32, 8 + 494 - 500), rows.row.?.y);
    try testing.expect(listRows(&app.window, 20).row != null);
    try testing.expect(listRows(&app.window, 11).row == null);
    try testing.expect(listRows(&app.window, 22).row == null);
    // 1,000 rows less the last gap, plus padding.
    listWheel(app, &now, 100_000);
    try testing.expectEqual(@as(f32, 1000 * 38 - 8 + 16), listOffset(&app.window).content_height);
}

/// The list's scroll record and the hit records of its rows. Its spacers
/// have no width, so they are not counted.
fn listChildren(window: *internals.window.Window, rows: []internals.records.Rect) struct {
    list: internals.records.Rect,
    count: u32,
} {
    const frame = window.rendered();
    var list_index: ?u32 = null;
    for (frame.hits[0..frame.hit_count], 0..) |*record, index| {
        if (record.scroll) list_index = @intCast(index);
    }
    var count: u32 = 0;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.parent != list_index.?) continue;
        if (record.bounds.width == 0) continue;
        rows[count] = record.bounds;
        count += 1;
    }
    return .{ .list = frame.hits[list_index.?].bounds, .count = count };
}

test "virtual_list builds the chat messages in view at their heights, to the last" {
    // Goal: the virtual_list port end to end, with the lifecycle guard
    // proving no allocation after init. Methodology: each row built must be
    // its message's height plus the 8 px gap, the first at the list's top
    // padding; wheeled to the end, the last row must end at the padding.
    const App = virtual_list.App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    var rows: [64]internals.records.Rect = undefined;
    var children = listChildren(&app.window, &rows);
    try testing.expect(children.count >= 5);
    try testing.expect(children.count < 20);
    try testing.expectEqual(children.list.y + 8, rows[0].y);
    // Hit bounds are clipped to the list, so the partial last row is shorter.
    for (rows[0 .. children.count - 1], 0..) |row, index| {
        try testing.expectEqual(virtual_list.messages[index].height() + 8, row.height);
    }
    // Rows past the view's bottom are not built.
    const last = rows[children.count - 1];
    try testing.expect(last.y < children.list.y + children.list.height);

    listWheel(app, &now, 100_000);
    children = listChildren(&app.window, &rows);
    const end = rows[children.count - 1];
    try testing.expectEqual(virtual_list.messages[999].height(), end.height);
    try testing.expectEqual(children.list.y + children.list.height - 8, end.y + end.height);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

fn tableHeader(app: *data_table.App, now: *u64, label: []const u8) void {
    const header = nodeNamed(&app.window, .button, label).?.bounds;
    clickAt(app, now, header.x + 4, header.y + 4);
}

fn tableSorted(state: *const data_table.State, up: bool) bool {
    var index: u32 = 1;
    while (index < data_table.row_count) : (index += 1) {
        const previous = state.rows[state.order[index - 1]].size_bytes;
        const current = state.rows[state.order[index]].size_bytes;
        if (up and previous > current) return false;
        if (!up and previous < current) return false;
    }
    return true;
}

test "data_table sorts 10,000 rows from its headers and builds only the rows in view" {
    // Goal: the data_table port end to end, with the lifecycle guard
    // proving no allocation after init. Methodology: click the Size header
    // three times; the order must be ascending, then descending (checked
    // against every adjacent pair of rows), then the generated order, and
    // the header's name must carry the arrow. Only rows in view are built.
    const App = data_table.App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    var rows: [64]internals.records.Rect = undefined;
    const children = listChildren(&app.window, &rows);
    try testing.expect(children.count >= 10);
    try testing.expect(children.count < 30);
    try testing.expectEqual(@as(f32, 32), rows[0].height);
    try testing.expectEqual(@as(u32, 3), app.state.order[3]);

    tableHeader(app, &now, "Size");
    try testing.expect(tableSorted(&app.state, true));
    try testing.expectEqual(data_table.Column.size, app.state.sort_column.?);
    try testing.expect(nodeNamed(&app.window, .button, "Size ▲") != null);
    tableHeader(app, &now, "Size ▲");
    try testing.expect(tableSorted(&app.state, false));
    try testing.expect(!tableSorted(&app.state, true));
    tableHeader(app, &now, "Size ▼");
    try testing.expect(app.state.sort_column == null);
    for (app.state.order, 0..) |order, index| {
        try testing.expectEqual(@as(u32, @intCast(index)), order);
    }
    try testing.expect(nodeNamed(&app.window, .button, "Size") != null);
    // Another column starts ascending.
    tableHeader(app, &now, "Size");
    tableHeader(app, &now, "ID");
    try testing.expectEqual(data_table.Column.id, app.state.sort_column.?);
    try testing.expectEqual(data_table.SortDirection.ascending, app.state.sort_direction);
    try testing.expectEqual(@as(u32, 0), app.state.order[0]);
}

const MeshApp = gooey.App(struct {}, meshRender, .{
    .title = "Meshes",
    .width = 300,
    .height = 300,
    .limits = gooey.ResourceLimits.small,
});

const mesh_red = ui.Color.rgb(1, 0, 0);
const mesh_blue = ui.Color.rgb(0, 0, 1);

fn meshRender(cx: *Cx) void {
    const nothing: u8 = 0;
    cx.render(ui.paint(u8, &nothing, meshPaint, .{
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 200 },
    }));
}

fn meshPaint(_: *const u8, painter: *ui.Painter) void {
    // Two red triangles in a row join one mesh; the blue circle starts another.
    painter.triangles(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } }, mesh_red);
    painter.triangles(&.{ .{ 20, 0 }, .{ 30, 0 }, .{ 20, 10 } }, mesh_red);
    painter.circle(.{ 100, 100 }, 10, mesh_blue);
    painter.line(.{ 10, 50 }, .{ 90, 50 }, 2, mesh_red);
    painter.line(.{ 0, 0 }, .{ 30, 40 }, 2, mesh_red);
    painter.polyline(&.{ .{ 0, 150 }, .{ 50, 120 }, .{ 100, 160 } }, 2, mesh_blue);
    painter.pointCloud(&.{ .{ 10, 190 }, .{ 20, 190 }, .{ 30, 190 }, .{ 40, 190 } }, 3, mesh_red);
}

test "Painter meshes pack into the scene's paths, polylines, and point clouds" {
    // Goal: paint meshes end to end on TestBackend, under the lifecycle
    // guard (packing triangles must not allocate the scene's frame meshes
    // after init). Methodology: the paint function draws two touching red
    // triangle fills, a circle of 10 px (12 sides at scale 1, so 10 fan
    // triangles), an axis-aligned and a diagonal line, a polyline, and a
    // point cloud. The records and the packed scene are checked by kind and
    // count, and the circle's first fan triangle by its corners.
    const app = try testing.allocator.create(MeshApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(0);
    const frame = app.window.rendered();
    var meshes: [8]internals.records.Mesh = undefined;
    var mesh_count: usize = 0;
    var quads: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        switch (record) {
            .mesh => |mesh| {
                meshes[mesh_count] = mesh;
                mesh_count += 1;
            },
            .quad => |quad| if (quad.fill.r == 1 and quad.bounds.height == 2) {
                quads += 1;
                try testing.expectEqual(@as(f32, 49), quad.bounds.y);
                try testing.expectEqual(@as(f32, 80), quad.bounds.width);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 1), quads);
    try testing.expectEqual(@as(usize, 5), mesh_count);
    const Topology = internals.records.Mesh.Topology;
    try testing.expectEqual(Topology.triangles, meshes[0].topology);
    try testing.expectEqual(@as(u32, 6), meshes[0].range.count);
    try testing.expectEqual(@as(u32, 30), meshes[1].range.count);
    try testing.expectEqual(@as(f32, 1), meshes[1].fill.b);
    try testing.expectEqual(@as(u32, 6), meshes[2].range.count);
    try testing.expectEqual(Topology.strip_expanded, meshes[3].topology);
    try testing.expectEqual(@as(f32, 2), meshes[3].width);
    try testing.expectEqual(Topology.point_instanced, meshes[4].topology);
    try testing.expectEqual(@as(u32, 4), meshes[4].range.count);
    // The fan starts at the circle's rightmost corner; the next corner is
    // 30 degrees on. The paint box sits at the window's origin.
    const fan = frame.meshPoints(meshes[1].range);
    try testing.expectEqual(@as(f32, 110), fan[0].x);
    try testing.expectEqual(@as(f32, 100), fan[0].y);
    try testing.expectApproxEqAbs(@as(f32, 100 + 10 * @cos(std.math.pi / 6.0)), fan[1].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 105), fan[1].y, 1e-4);

    const scene = app.window.scene;
    try testing.expectEqual(@as(usize, 3), scene.pathCount());
    try testing.expectEqual(@as(usize, 1), scene.polylineCount());
    try testing.expectEqual(@as(usize, 1), scene.pointCloudCount());
    try testing.expectEqual(@as(u32, 3), scene.getPolylines()[0].point_count);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

/// The 32 px icon cells built this frame, in tree order.
fn lucideCells(window: *internals.window.Window, cells: []internals.records.Rect) u32 {
    const frame = window.rendered();
    var count: u32 = 0;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.bounds.width != 32) continue;
        if (record.bounds.height != 32) continue;
        cells[count] = record.bounds;
        count += 1;
    }
    return count;
}

fn lucideCellQuad(
    window: *internals.window.Window,
    cell: internals.records.Rect,
) ?ui.Color {
    const frame = window.rendered();
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record != .quad) continue;
        const bounds = record.quad.bounds;
        if (bounds.x != cell.x or bounds.y != cell.y) continue;
        if (bounds.width == 32) return record.quad.fill;
    }
    return null;
}

test "lucide_demo builds the icon rows in view and lights the cell under the pointer" {
    // Goal: the lucide_demo port end to end, with the lifecycle guard
    // proving no allocation after init. Methodology: only whole rows of 16
    // cells in view are built, each with an SVG sprite once rasterized; the
    // cell under the pointer takes the hover colour and its neighbour keeps
    // the cell colour; wheeled to the end, the last row holds the remainder.
    const app = try testing.allocator.create(lucide.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    // Rasterization is budgeted per frame; settle until every icon is drawn
    // (87 ticks at the time of writing).
    var settle: u32 = 0;
    while (settle < 200) : (settle += 1) {
        app.tick(now);
        now += 1;
        if (!app.window.render_requested) break;
    }
    try testing.expect(!app.window.render_requested);
    var cells: [1024]internals.records.Rect = undefined;
    const count = lucideCells(&app.window, &cells);
    try testing.expectEqual(@as(u32, 0), count % 16);
    try testing.expect(count >= 16 * 15);
    try testing.expect(count < 16 * 30);
    var sprites: u32 = 0;
    const frame = app.window.rendered();
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record == .sprite and record.sprite.atlas == .svg) sprites += 1;
    }
    // Rows past the clip are built and drawn but hit nothing, so every
    // whole row in view has a sprite per cell, and some rows below do too.
    try testing.expectEqual(@as(u32, 0), sprites % 16);
    try testing.expect(sprites >= count);
    try testing.expect(sprites <= count + 3 * 16);

    const hover = ui.Color.hex(0x334155);
    const plain = ui.Color.hex(0x1e293b);
    try testing.expectEqual(plain.r, lucideCellQuad(&app.window, cells[1]).?.r);
    const pointer = mouse(cells[1].x + 16, cells[1].y + 16);
    app.window.queue.push(.{ .input = .{ .mouse_moved = pointer } });
    app.tick(now);
    now += 1;
    try testing.expectEqual(hover.r, lucideCellQuad(&app.window, cells[1]).?.r);
    try testing.expectEqual(plain.r, lucideCellQuad(&app.window, cells[0]).?.r);

    listWheel(app, &now, 100_000);
    settle = 0;
    while (settle < 200 and app.window.render_requested) : (settle += 1) {
        app.tick(now);
        now += 1;
    }
    const end_count = lucideCells(&app.window, &cells);
    const remainder = lucide.TOTAL_ICONS % 16;
    try testing.expectEqual(if (remainder == 0) 0 else 16 - remainder, (16 - end_count % 16) % 16);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

/// Counts the image worker's wakes, as a host's `scheduleTick` would.
const WakeCounter = struct {
    count: std.atomic.Value(u32) = .init(0),

    fn wake(context: *anyopaque) void {
        const self: *WakeCounter = @ptrCast(@alignCast(context));
        _ = self.count.fetchAdd(1, .release);
    }
};

/// Tick until the image worker's decode lands, waiting 1 ms between ticks;
/// a decode that takes more than 5 s fails the test.
fn settleImages(app: anytype, now: *u64) !void {
    var attempt: u32 = 0;
    while (attempt < 5_000) : (attempt += 1) {
        if (app.window.images.landed_count > 0) return;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
        now.* += 1;
        app.tick(now.*);
    }
    return error.DecodeNeverLanded;
}

fn imageSprites(
    frame: *const internals.records.Frame,
    out: []internals.records.Sprite,
) u32 {
    var count: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record != .sprite) continue;
        if (record.sprite.atlas != .image) continue;
        out[count] = record.sprite;
        count += 1;
    }
    return count;
}

test "images: one decode lands off the main thread and draws every cell" {
    // Goal: the async loader's contract. Methodology: the images example
    // draws one file in 18 cells. The first frame queues one request and
    // draws no image; the worker decodes off the main thread, wakes the
    // host, and the next emit lands it, so every cell draws from one atlas
    // entry with no allocation after init (the lifecycle guard). Expected
    // bounds come from the logo's 512² source and each cell's box.
    const app = try testing.allocator.create(images.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var wake = WakeCounter{};
    app.window.images.bindWake(.{ .context = &wake, .wake = WakeCounter.wake });
    defer app.window.images.bindWake(null);
    var now: u64 = 0;
    app.tick(now);
    var sprites: [32]internals.records.Sprite = undefined;
    try testing.expectEqual(@as(u32, 0), imageSprites(app.window.rendered(), &sprites));
    var pending: u32 = 0;
    for (app.window.images.entries) |entry| {
        if (entry.state == .pending) pending += 1;
    }
    try testing.expectEqual(@as(u32, 1), pending);

    try settleImages(app, &now);
    try testing.expect(wake.count.load(.acquire) >= 1);
    now += 1;
    app.tick(now);
    const count = imageSprites(app.window.rendered(), &sprites);
    const cell_count = images.sizing.len + images.fit_modes.len + images.corner_radius.len +
        images.effects.len;
    try testing.expectEqual(@as(u32, cell_count), count);
    for (app.window.images.entries) |entry| try testing.expect(entry.state == .free);
    try testing.expectEqual(@as(u32, 1), app.window.images.landed_count);

    // 200x80 contain: an 80 px square centred, 60 px in.
    const wide = sprites[3];
    try testing.expectEqual(@as(f32, 80), wide.bounds.width);
    try testing.expectEqual(@as(f32, 80), wide.bounds.height);
    // `none` shows the middle 100 of 512 source px at their own size.
    const none = sprites[7];
    try testing.expectEqual(@as(f32, 100), none.bounds.width);
    const full_uv = sprites[4].uv.width;
    try testing.expectApproxEqAbs(full_uv * 100.0 / 512.0, none.uv.width, 1e-5);
    // Effects carry through to the record.
    const combined = sprites[cell_count - 1];
    try testing.expectEqual(@as(f32, 0.8), combined.grayscale);
    try testing.expectEqual(@as(f32, 0.9), combined.opacity);
    try testing.expectEqual(@as(f32, 40), combined.corners.top_left);
    try testing.expectEqual(@as(f32, 1), sprites[cell_count - 5].tint.b);
    try testing.expectEqual(@as(f32, 1), sprites[cell_count - 4].grayscale);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

fn missingImageRender(cx: *Cx) void {
    const nothing: u8 = 0;
    cx.render(ui.paint(u8, &nothing, missingImagePaint, .{
        .width = .{ .fixed = 50 },
        .height = .{ .fixed = 50 },
    }));
}

fn missingImagePaint(_: *const u8, painter: *ui.Painter) void {
    painter.image("assets/no-such-image.png", painter.bounds, .{ .fit = .contain });
}

test "images: a missing file fails once and is not read again" {
    // Goal: a missing file is an operating error, not a crash, and does not
    // re-read the disk every frame. Methodology: paint a missing path, let
    // its failure land, then render again: the entry stays failed, nothing
    // more is queued, and nothing is drawn.
    const MissingApp = gooey.App(struct {}, missingImageRender, .{
        .title = "Missing",
        .width = 100,
        .height = 100,
        .limits = gooey.ResourceLimits.nano,
    });
    const app = try testing.allocator.create(MissingApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    var attempt: u32 = 0;
    while (attempt < 5_000) : (attempt += 1) {
        if (app.window.images.entries[0].state == .failed) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
        now += 1;
        app.window.render_requested = true;
        app.tick(now);
    }
    try testing.expect(app.window.images.entries[0].state == .failed);
    const head = app.window.images.request_head.load(.acquire);
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    try testing.expectEqual(head, app.window.images.request_head.load(.acquire));
    var sprites: [4]internals.records.Sprite = undefined;
    try testing.expectEqual(@as(u32, 0), imageSprites(app.window.rendered(), &sprites));
    try testing.expectEqual(@as(u32, 0), app.window.images.landed_count);
}

test "dashboard draws every chart within .standard and t switches its theme" {
    // Goal: the charts reach the core's mesh records within the dashboard's
    // `.standard` limits (an overflow panics), every series draws, and the
    // keymap's "t" toggles the theme. Methodology: one frame, then the mesh
    // records by kind: the two line series are one polyline each and one
    // marker cloud each at radius 4; the three scatter segments are one
    // cloud each at radius 7 and 0.85 alpha. The root box's fill is the
    // dark background, then the light one after "t".
    const App = dashboard.App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 2 });
    defer app.deinitHeadless();
    app.tick(0);

    const Cloud = struct { radius: f32, alpha: f32, blue: f32 };
    const expected_clouds = [_]Cloud{
        .{ .radius = 4, .alpha = 1, .blue = ui.Color.hex(0x06b6d4).b },
        .{ .radius = 4, .alpha = 1, .blue = ui.Color.hex(0x94a3b8).b },
        .{ .radius = 7, .alpha = 0.85, .blue = ui.Color.hex(0x8b5cf6).b },
        .{ .radius = 7, .alpha = 0.85, .blue = ui.Color.hex(0x06b6d4).b },
        .{ .radius = 7, .alpha = 0.85, .blue = ui.Color.hex(0x64748b).b },
    };
    var clouds: u32 = 0;
    var lines: u32 = 0;
    var triangle_meshes: u32 = 0;
    const frame = app.window.rendered();
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record != .mesh) continue;
        const mesh = record.mesh;
        switch (mesh.topology) {
            .triangles => triangle_meshes += 1,
            .strip_expanded => {
                try testing.expectEqual(@as(u32, 12), mesh.range.count);
                try testing.expectEqual(@as(f32, 2.5), mesh.width);
                lines += 1;
            },
            .point_instanced => {
                const want = expected_clouds[clouds];
                try testing.expectEqual(want.radius, mesh.width);
                try testing.expectApproxEqAbs(want.alpha, mesh.fill.a, 0.001);
                try testing.expectApproxEqAbs(want.blue, mesh.fill.b, 0.001);
                clouds += 1;
            },
        }
    }
    try testing.expectEqual(@as(u32, 2), lines);
    try testing.expectEqual(@as(u32, expected_clouds.len), clouds);
    // The accent dot, the legend's three circles, two rings of slices, and
    // the conversion ring's centre circles: one mesh per run of a colour.
    try testing.expect(triangle_meshes >= 1 + 3 + 5 + 2 + 3);

    try testing.expectEqual(ui.Color.hex(0x0f172a), rootFill(&app.window));
    app.window.queue.push(.{ .input = .{ .key_down = chord(.t, .{}) } });
    app.tick(1);
    try testing.expect(!app.state.is_dark_theme);
    try testing.expectEqual(ui.Color.hex(0xf1f5f9), rootFill(&app.window));
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

/// The fill of the frame's window-sized quad: the root box's background.
fn rootFill(window: *internals.window.Window) ui.Color {
    const frame = window.rendered();
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record != .quad) continue;
        const bounds = record.quad.bounds;
        if (bounds.width == window.width and bounds.height == window.height) {
            return record.quad.fill;
        }
    }
    unreachable;
}

test "dynamic_counters creates, removes within a drain, and reuses entity slots" {
    // Goal: entities through the real router and tick (decision 17). Method:
    // add three counters and bump the third; in one drain, remove it and
    // click its "+" (the frame still names it, so the handler must reach
    // it); after the tick its slot must be free, zeroed, and one generation
    // on, and the next add must reuse it fresh. Then fill to the example's
    // cap of ten, under the `.nano` pool's 16, with no allocation after init.
    const App = dynamic_counters.App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);

    for (0..3) |_| countersClick(app, &now, "+ Add Counter", 0);
    try testing.expectEqual(@as(u32, 3), app.state.counter_count);
    countersClick(app, &now, "+", 2);
    countersClick(app, &now, "+", 2);
    countersClick(app, &now, "-", 0);
    try testing.expectEqual(@as(i32, -1), countersValue(app, 0).count);
    try testing.expectEqual(@as(i32, 2), countersValue(app, 2).count);

    // Remove, then "+" on the removed card, in one drain.
    const remove = nodeNamed(&app.window, .button, "- Remove Counter").?.bounds;
    const plus = countersButton(app, "+", 2).bounds;
    for ([_]gooey.ui.Rect{ remove, plus }) |bounds| {
        const x = bounds.x + bounds.width / 2;
        const y = bounds.y + bounds.height / 2;
        app.window.queue.push(.{ .input = .{ .mouse_down = mouse(x, y) } });
        app.window.queue.push(.{ .input = .{ .mouse_up = mouse(x, y) } });
    }
    now += 1;
    app.tick(now);
    const pool = &app.entity_pools[0];
    try testing.expectEqual(@as(u32, 2), app.state.counter_count);
    try testing.expectEqual(@as(u32, 1), pool.generations[2]);
    for (pool.valueBytes(2)) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expect(countersButtonIndex(app, "+", 2) == null);

    countersClick(app, &now, "+ Add Counter", 0);
    const reused = app.state.counters[2];
    try testing.expectEqual(@as(u32, 2), reused.slot);
    try testing.expectEqual(@as(u32, 1), reused.generation);
    try testing.expectEqual(@as(i32, 0), countersValue(app, 2).count);
    try testing.expectEqualStrings("Counter C", countersValue(app, 2).label);

    for (0..8) |_| countersClick(app, &now, "+ Add Counter", 0);
    try testing.expectEqual(@as(u32, dynamic_counters.counter_count_max), app.state.counter_count);
    try testing.expectEqual(@as(u32, 16 - 10), pool.free_count);
    try testing.expect(countersButton(app, "+", 9).bounds.width > 0);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

fn countersValue(app: *dynamic_counters.App, index: u32) *const dynamic_counters.Counter {
    const handle = app.state.counters[index];
    const bytes = app.entity_pools[0].valueBytes(handle.slot);
    return @ptrCast(@alignCast(bytes.ptr));
}

/// The `nth` button named `name`, in tree order.
fn countersButtonIndex(
    app: *dynamic_counters.App,
    name: []const u8,
    nth: u32,
) ?*const internals.records.A11yNode {
    const frame = app.window.rendered();
    var seen: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != .button) continue;
        if (!std.mem.eql(u8, frame.text(node.name) orelse "", name)) continue;
        if (seen == nth) return node;
        seen += 1;
    }
    return null;
}

fn countersButton(
    app: *dynamic_counters.App,
    name: []const u8,
    nth: u32,
) *const internals.records.A11yNode {
    return countersButtonIndex(app, name, nth).?;
}

fn countersClick(app: *dynamic_counters.App, now: *u64, name: []const u8, nth: u32) void {
    const bounds = countersButton(app, name, nth).bounds;
    clickAt(app, now, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
}

/// A box built with a source location beside one without, for the inspector
/// check.
const InspectApp = gooey.App(struct {}, inspectRender, .{
    .title = "Inspect",
    .width = 400,
    .height = 300,
    .limits = gooey.ResourceLimits.small,
});

fn inspectSource() std.builtin.SourceLocation {
    return @src();
}

fn inspectRender(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{ .direction = .row } }, .{
        ui.box(.{ .style = .{
            .width = .{ .fixed = 200 },
            .height = .{ .fixed = 100 },
            .source = inspectSource(),
        } }, .{}),
        ui.box(.{ .style = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } } }, .{}),
    }));
}

test "the inspector selects the element under a press and shows its source" {
    // Goal: `Style.source` reaches the inspector's selection in a safe build
    // (contract decision 16). Methodology: open the inspector with
    // Cmd+Shift+I, press inside the annotated box, then inside its sibling,
    // which has no source; cycling through the profiler closes it again.
    if (!internals.debugger.enabled) return error.SkipZigTest;
    const app = try testing.allocator.create(InspectApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const toggle = gooey.input.InputEvent{ .key_down = chord(.i, .{ .cmd = true, .shift = true }) };
    scrollMouse(app, &now, toggle);
    try testing.expectEqual(.inspector, app.window.debugger.mode);
    try testing.expect(app.window.debugger.info == null);

    clickAt(app, &now, 50, 50);
    const annotated = app.window.debugger.info.?;
    try testing.expectEqual(@as(f32, 200), annotated.bounds.width);
    try testing.expectEqual(inspectSource().line, annotated.source.?.line);
    try testing.expectEqualStrings("core_checks.zig", annotated.source.?.basename());

    clickAt(app, &now, 250, 50);
    const plain = app.window.debugger.info.?;
    try testing.expectEqual(@as(f32, 100), plain.bounds.width);
    try testing.expect(plain.source == null);

    scrollMouse(app, &now, toggle);
    try testing.expectEqual(.profiler, app.window.debugger.mode);
    scrollMouse(app, &now, toggle);
    try testing.expectEqual(.disabled, app.window.debugger.mode);
    try testing.expect(app.window.debugger.info == null);
}

/// `.nano` with records cut to what `fullPaint` fills: every quad, glyph, and
/// paint record the app declares.
const full_limits = blk: {
    var limits = gooey.ResourceLimits.nano;
    limits.records.paint_record_count_frame_max = 4_096;
    break :blk limits;
};

const FullApp = gooey.App(struct {}, fullRender, .{
    .title = "Full",
    .width = 800,
    .height = 600,
    .limits = full_limits,
});

fn fullRender(cx: *Cx) void {
    const nothing: u8 = 0;
    cx.render(ui.paint(u8, &nothing, fullPaint, .{
        .width = .{ .fixed = 800 },
        .height = .{ .fixed = 600 },
    }));
}

const PaintCounts = struct { records: u32, quads: u32, glyphs: u32 };

fn paintCounts(frame: *const internals.records.Frame) PaintCounts {
    var counts = PaintCounts{ .records = frame.paint_count, .quads = 0, .glyphs = 0 };
    for (frame.paint[0..frame.paint_count]) |record| {
        switch (record) {
            .quad => counts.quads += 1,
            .sprite => counts.glyphs += 1,
            else => {},
        }
    }
    return counts;
}

/// Fill the frame to exactly its declared glyphs, then quads, then records:
/// lines of 64 glyphs, 2 px quads, and empty clip pairs, all in view so none
/// is culled when packed.
fn fullPaint(_: *const u8, painter: *ui.Painter) void {
    const scene_limits = full_limits.scene;
    const frame = painter.window.built();
    const line: [64]u8 = @splat('x');
    var row: u32 = 0;
    while (paintCounts(frame).glyphs < scene_limits.glyph_count_frame_max) : (row += 1) {
        assert(row < 64);
        const left = scene_limits.glyph_count_frame_max - paintCounts(frame).glyphs;
        const y: f32 = @floatFromInt(8 + row * 8);
        _ = painter.text(line[0..@min(left, line.len)], 8, y, .{ .size = 6, .color = .black });
    }
    assert(paintCounts(frame).glyphs == scene_limits.glyph_count_frame_max);
    var quad: u32 = paintCounts(frame).quads;
    while (quad < scene_limits.quad_count_frame_max) : (quad += 1) {
        const x: f32 = @floatFromInt(400 + (quad % 64) * 4);
        const y: f32 = @floatFromInt(8 + (quad / 64) * 4);
        painter.fill(.{ .x = x, .y = y, .width = 2, .height = 2 }, .black);
    }
    const records_left = full_limits.records.paint_record_count_frame_max - frame.paint_count;
    assert(records_left % 2 == 0);
    var pair: u32 = 0;
    while (pair < records_left / 2) : (pair += 1) {
        painter.pushClip(.{ .x = 0, .y = 0, .width = 800, .height = 600 });
        painter.popClip();
    }
}

test "the debugger opens over an app filled to exactly its limits" {
    // Goal: the overlay paints into its own headroom, never the app's budget
    // (contract decision 16), so a correct app cannot crash from opening it.
    // Methodology: the app fills its declared quads, glyphs, and paint
    // records exactly; open the inspector, hover and select its element, then
    // the profiler, and check each frame and scene holds the app's full
    // budget plus the overlay.
    if (!internals.debugger.enabled) return error.SkipZigTest;
    const app = try testing.allocator.create(FullApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const scene = app.window.scene;
    const scene_limits = full_limits.scene;
    const app_counts = paintCounts(app.window.rendered());
    try testing.expectEqual(full_limits.records.paint_record_count_frame_max, app_counts.records);
    try testing.expectEqual(scene_limits.quad_count_frame_max, app_counts.quads);
    try testing.expectEqual(scene_limits.quad_count_frame_max, scene.quads.items.len);
    try testing.expectEqual(scene_limits.glyph_count_frame_max, scene.glyphs.items.len);

    const toggle = gooey.input.InputEvent{ .key_down = chord(.i, .{ .cmd = true, .shift = true }) };
    scrollMouse(app, &now, toggle);
    scrollMouse(app, &now, .{ .mouse_moved = mouse(100, 100) });
    clickAt(app, &now, 100, 100);
    try testing.expectEqual(.inspector, app.window.debugger.mode);
    try testing.expect(app.window.debugger.info != null);
    const inspected = paintCounts(app.window.rendered());
    try testing.expect(inspected.records > app_counts.records);
    try testing.expect(scene.quads.items.len > scene_limits.quad_count_frame_max);
    try testing.expect(scene.glyphs.items.len > scene_limits.glyph_count_frame_max);

    scrollMouse(app, &now, toggle);
    try testing.expectEqual(.profiler, app.window.debugger.mode);
    const profiled = paintCounts(app.window.rendered());
    // The panel, the graph, its target line, and at least one bar.
    try testing.expect(profiled.quads >= app_counts.quads + 4);
    try testing.expect(scene.glyphs.items.len > scene_limits.glyph_count_frame_max);
}

/// The bounds of the first button named `name`, or null when none is built.
fn todoButton(app: *todo.App, name: []const u8) ?gooey.ui.Rect {
    const node = nodeNamed(&app.window, .button, name) orelse return null;
    return node.bounds;
}

/// The checkbox rows the list built, and the first one's top.
fn todoRowCount(app: *todo.App, first_y: *f32) u32 {
    const frame = app.window.rendered();
    var count: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != .checkbox) continue;
        if (count == 0) first_y.* = node.bounds.y;
        count += 1;
    }
    return count;
}

fn todoResize(app: *todo.App, now: *u64, width: f32, height: f32) void {
    app.window.queue.push(.{ .window = .{ .resized = .{
        .width = width,
        .height = height,
        .scale_factor = 1,
    } } });
    now.* += 1;
    app.tick(now.*);
}

test "the first frame fits a window whose size changed before the host bound it" {
    // Goal: a window resized before `bindCore` (AppKit fitting it to the
    // screen, a tiling compositor's first configure) gets a first frame of
    // its own size, not the app's configured 480x560. Methodology: bind the
    // configured geometry and expect nothing queued, then a scale change
    // alone and a size change alone, each queueing one resize; the first
    // build must carry the window's viewport and lay Add out across it.
    const app = try testing.allocator.create(todo.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.window.bindViewport(.{ .width = 480, .height = 560, .scale_factor = 1 });
    try testing.expectEqual(@as(u32, 0), app.window.queue.count);
    app.window.bindViewport(.{ .width = 480, .height = 560, .scale_factor = 2 });
    try testing.expectEqual(@as(u32, 1), app.window.queue.count);
    app.window.queue.clear();
    app.window.bindViewport(.{ .width = 700, .height = 420, .scale_factor = 1 });
    try testing.expectEqual(@as(u32, 1), app.window.queue.count);
    app.tick(0);
    const frame = app.window.rendered();
    try testing.expectEqual(@as(u64, 1), frame.frame_number);
    try testing.expectEqual(@as(f32, 700), frame.viewport_width);
    try testing.expectEqual(@as(f32, 420), frame.viewport_height);
    const add = todoButton(app, "Add").?;
    try testing.expectApproxEqAbs(@as(f32, 700 - 24), add.x + add.width, 0.01);
}

test "todo keeps its header, footer, and Add in view at 20 items and narrow widths" {
    // Goal: the default example holds its layout past a screenful (SER9 saw
    // rows overlap the header from 8 items) and down to narrow windows (Add
    // went off screen at 350 px). Methodology: add 20 todos at 480x560; Add,
    // the filters, and Clear completed must keep their places inside the
    // padding, and a wheel over the list must move the rows up while the
    // header stays. Then narrow the window to 360 px and check Add ends at
    // the right padding with a row's Delete inside it.
    const app = try testing.allocator.create(todo.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const add_before = todoButton(app, "Add").?;
    const clear_before = todoButton(app, "Clear completed").?;
    for (0..20) |_| {
        app.state.draft = "a todo that needs doing";
        app.state.addTodo();
    }
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(u32, 20), app.state.count);
    try testing.expectEqual(add_before, todoButton(app, "Add").?);
    // "20 left" is wider than "0 left", so only Clear completed's row holds.
    try testing.expectApproxEqAbs(clear_before.y, todoButton(app, "Clear completed").?.y, 0.01);
    try testing.expect(add_before.x + add_before.width <= 480 - 24);
    try testing.expect(clear_before.y + clear_before.height <= 560 - 24);

    var first_top: f32 = 0;
    _ = todoRowCount(app, &first_top);
    const all = todoButton(app, "All").?;
    try testing.expect(first_top > all.y + all.height);
    // Offsets follow the delta, inverted on macOS (`ScrollState.wheel`).
    const direction: f32 = if (@import("builtin").os.tag == .macos) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = 100, .y = 300 },
        .delta = .{ .x = 0, .y = 200 * direction },
        .modifiers = .{},
    } } });
    now += 1;
    app.tick(now);
    var scrolled_top: f32 = 0;
    _ = todoRowCount(app, &scrolled_top);
    try testing.expect(scrolled_top < first_top);
    try testing.expectEqual(all, todoButton(app, "All").?);
    try testing.expectApproxEqAbs(clear_before.y, todoButton(app, "Clear completed").?.y, 0.01);

    todoResize(app, &now, 360, 560);
    const add_narrow = todoButton(app, "Add").?;
    try testing.expectApproxEqAbs(@as(f32, 360 - 24), add_narrow.x + add_narrow.width, 0.01);
    const input = nodeNamed(&app.window, .textbox, "What needs doing?").?.bounds;
    try testing.expect(input.width > 100);
    try testing.expect(input.x + input.width < add_narrow.x);
    // Rows fill the list, so Delete ends inside it.
    const delete = todoButton(app, "Delete").?;
    try testing.expect(delete.x + delete.width <= 360 - 24);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

// =============================================================================
// Keyboard access
// =============================================================================

/// Press `key` once and settle: the drain routes it against the frame on
/// screen, and the build shows the result.
fn pressKey(
    app: anytype,
    now: *u64,
    key: gooey.input.KeyCode,
    modifiers: gooey.input.Modifiers,
) void {
    app.window.queue.push(.{ .input = .{ .key_down = chord(key, modifiers) } });
    now.* += 1;
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

/// The accessibility node holding keyboard focus in the frame on screen.
fn focusedNode(window: *internals.window.Window) ?*const internals.records.A11yNode {
    const frame = window.rendered();
    var found: ?*const internals.records.A11yNode = null;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (!node.state.focused) continue;
        assert(found == null);
        found = node;
    }
    return found;
}

fn expectFocused(window: *internals.window.Window, role: gooey.ui.Role, name: []const u8) !void {
    const node = focusedNode(window) orelse return error.NothingFocused;
    const frame = window.rendered();
    try testing.expectEqualStrings(name, frame.text(node.name) orelse "");
    try testing.expectEqual(role, node.role);
}

/// The focus rings in the frame on screen: transparent quads with a 2 px
/// border in the theme's `border_focus`. Returns how many, and the last.
fn focusRings(window: *internals.window.Window, ring: *internals.records.Rect) u32 {
    const frame = window.rendered();
    const color = window.theme.border_focus;
    var count: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |*record| {
        if (record.* != .quad) continue;
        const quad = record.quad;
        if (quad.fill.a != 0 or quad.border.width != 2) continue;
        if (!std.meta.eql(quad.border.color, color)) continue;
        ring.* = quad.bounds;
        count += 1;
    }
    return count;
}

/// A ring 2 px outside `bounds` and 2 px wide.
fn expectRingAround(window: *internals.window.Window, bounds: internals.records.Rect) !void {
    var ring: internals.records.Rect = undefined;
    try testing.expectEqual(@as(u32, 1), focusRings(window, &ring));
    try testing.expectEqual(bounds.x - 4, ring.x);
    try testing.expectEqual(bounds.y - 4, ring.y);
    try testing.expectEqual(bounds.width + 8, ring.width);
    try testing.expectEqual(bounds.height + 8, ring.height);
}

test "Tab walks accessible_form's controls in tree order and draws the focus ring" {
    // Goal: Tab reaches every control, components and the app's own radios
    // alike, in tree order, wrapping at both ends, and only keyboard focus
    // draws a ring, scrolled into the window. Methodology: Tab from nothing
    // focused through the whole form, taller than its 800 px window, and
    // once more, then Shift+Tab back; the expected order is read off the
    // example's render. A click on a focused control keeps focus but drops
    // the ring.
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const Stop = struct { role: gooey.ui.Role, name: []const u8 };
    const order = [_]Stop{
        .{ .role = .textbox, .name = "Full name, required field" },
        .{ .role = .textbox, .name = "Email address, required field" },
        .{ .role = .textbox, .name = "Phone number, optional field" },
        // Only the selected radio is a tab stop.
        .{ .role = .radio, .name = "Email" },
        .{ .role = .checkbox, .name = "Subscribe to newsletter" },
        .{ .role = .combobox, .name = "Experience level" },
        .{ .role = .checkbox, .name = "Accept terms and conditions, required" },
        .{ .role = .button, .name = "Submit registration form" },
        .{ .role = .button, .name = "Reset form to default values" },
    };
    try testing.expect(focusedNode(&app.window) == null);
    var ring: internals.records.Rect = undefined;
    try testing.expectEqual(@as(u32, 0), focusRings(&app.window, &ring));
    for (order) |stop| {
        pressKey(app, &now, .tab, .{});
        try expectFocused(&app.window, stop.role, stop.name);
        // The form scrolls each control and its 4 px ring into the window,
        // up to float rounding of the offset.
        const bounds = focusedNode(&app.window).?.bounds;
        try testing.expect(bounds.y - 4 >= -0.01);
        try testing.expect(bounds.y + bounds.height + 4 <= 800.01);
        try expectRingAround(&app.window, bounds);
    }
    // Wrapping to the first field scrolls the form back up to it.
    pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, order[0].role, order[0].name);
    try testing.expect(focusedNode(&app.window).?.bounds.y - 4 >= -0.01);
    pressKey(app, &now, .tab, .{ .shift = true });
    var index: usize = order.len;
    while (index > 0) {
        index -= 1;
        try expectFocused(&app.window, order[index].role, order[index].name);
        pressKey(app, &now, .tab, .{ .shift = true });
    }
    try expectFocused(&app.window, order[order.len - 1].role, order[order.len - 1].name);

    // A pointer press on the focused Reset button keeps it focused, ringless.
    formClick(app, &now, .button, "Reset form to default values");
    try expectFocused(&app.window, .button, "Reset form to default values");
    try testing.expectEqual(@as(u32, 0), focusRings(&app.window, &ring));
}

test "Enter and Space click the focused control once per press" {
    // Goal: the core's activation rule. Methodology: on accessible_form,
    // focus the newsletter checkbox (checked by default) by Tab and toggle it
    // with Space and Enter; a key repeat, Cmd+Enter, and Ctrl+Space must not
    // click. Space in a text field clicks nothing. Enter on a radio
    // selects it, and Enter on Submit submits, which announces.
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    try testing.expect(app.state.newsletter);
    for (0..5) |_| pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .checkbox, "Subscribe to newsletter");
    pressKey(app, &now, .space, .{});
    try testing.expect(!app.state.newsletter);
    pressKey(app, &now, .@"return", .{});
    try testing.expect(app.state.newsletter);
    var repeat = chord(.space, .{});
    repeat.is_repeat = true;
    app.window.queue.push(.{ .input = .{ .key_down = repeat } });
    pressKey(app, &now, .@"return", .{ .cmd = true });
    pressKey(app, &now, .space, .{ .ctrl = true });
    try testing.expect(app.state.newsletter);
    try expectFocused(&app.window, .checkbox, "Subscribe to newsletter");

    pressKey(app, &now, .tab, .{ .shift = true });
    try expectFocused(&app.window, .radio, "Email");
    // Unselect it behind the frame's back, so the click shows.
    app.state.contact_method = .phone;
    pressKey(app, &now, .keypad_enter, .{});
    try testing.expect(formNode(app, .radio, "Email").?.state.checked);

    // A text field has no `on_click`, so Space there clicks nothing; its
    // text arrives as text input.
    formClick(app, &now, .textbox, "Full name, required field");
    pressKey(app, &now, .space, .{});
    app.window.queue.push(.{ .input = .{ .text_input = .{ .text = "Ada" } } });
    now += 1;
    app.tick(now);
    try testing.expectEqualStrings("Ada", app.state.name);
    try testing.expect(app.state.newsletter);

    for (0..7) |_| pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .button, "Submit registration form");
    pressKey(app, &now, .@"return", .{});
    try testing.expect(formNode(app, .alert, "Valid email is required") != null);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "keyboard focus stays in view when a layout change moves it, but not after a wheel" {
    // Goal: the reveal follows the focused box when content around it
    // changes size, not only when focus moves, and leaves a scroll the user
    // made alone. Methodology: on accessible_form, Tab to Submit, which
    // scrolls it to the bottom of the 800 px window, and press Enter on the
    // empty form: three error messages appear above it, pushing it down by
    // more than its margin. It must stay in the window with its ring. Then
    // wheel the form up, which moves Submit off the bottom: it stays there.
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    for (0..8) |_| pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .button, "Submit registration form");
    const before = focusedNode(&app.window).?.bounds;
    try testing.expect(before.y + before.height + 4 <= 800.01);
    try testing.expect(before.y + before.height > 700);
    pressKey(app, &now, .@"return", .{});
    try testing.expect(formNode(app, .alert, "Name is required") != null);
    try expectFocused(&app.window, .button, "Submit registration form");
    const after = focusedNode(&app.window).?.bounds;
    try testing.expect(after.y - 4 >= -0.01);
    try testing.expect(after.y + after.height + 4 <= 800.01);
    try expectRingAround(&app.window, after);

    const direction: f32 = if (@import("builtin").os.tag == .macos) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = 300, .y = 400 },
        .delta = .{ .x = 0, .y = -300 * direction },
        .modifiers = .{},
    } } });
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    const wheeled = focusedNode(&app.window).?.bounds;
    try testing.expect(wheeled.y > 800);
    try expectFocused(&app.window, .button, "Submit registration form");
}

test "a radio group is one tab stop whose arrow keys select and wrap" {
    // Goal: accessible_form's radios behave as a native group. Methodology:
    // Tab enters at the selected option; Down and Right select the next,
    // Up and Left the previous, wrapping at both ends, with focus and its
    // ring following; Tab leaves the group in one press and Shift+Tab
    // comes back to the option now selected. Then Shift+Tab from the open
    // Select's menu closes it and lands on the newsletter checkbox before
    // it, past the radios.
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    for (0..4) |_| pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .radio, "Email");
    const Step = struct { key: gooey.input.KeyCode, method: accessible_form.State.ContactMethod };
    const steps = [_]Step{
        .{ .key = .down, .method = .phone },
        .{ .key = .right, .method = .mail },
        .{ .key = .down, .method = .email },
        .{ .key = .up, .method = .mail },
        .{ .key = .left, .method = .phone },
    };
    const names = [_][]const u8{ "Email", "Phone", "Postal Mail" };
    for (steps) |step| {
        pressKey(app, &now, step.key, .{});
        try testing.expectEqual(step.method, app.state.contact_method);
        const name = names[@backingInt(step.method)];
        try expectFocused(&app.window, .radio, name);
        try testing.expect(focusedNode(&app.window).?.state.checked);
        try expectRingAround(&app.window, focusedNode(&app.window).?.bounds);
    }
    pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .checkbox, "Subscribe to newsletter");
    pressKey(app, &now, .tab, .{ .shift = true });
    try expectFocused(&app.window, .radio, "Phone");

    pressKey(app, &now, .tab, .{});
    pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .combobox, "Experience level");
    pressKey(app, &now, .down, .{});
    try expectFocused(&app.window, .option, "Beginner");
    pressKey(app, &now, .tab, .{ .shift = true });
    try testing.expect(!app.state.experience_open);
    try expectFocused(&app.window, .checkbox, "Subscribe to newsletter");
    try testing.expectEqual(@as(?usize, null), app.state.experience_level);
}

test "a Select opens, moves, and chooses from the keyboard" {
    // Goal: the Select's keys through its retained key handler and
    // `effects.click`, with focus as the highlight. Methodology: on the
    // three-option Select, Tab to the combobox, open with Down, walk the
    // options with Down past the end, Up, Home, and End, and choose with
    // Enter; reopen with Space on the chosen option and close with Esc; then
    // choose with Up and Space.
    const app = try testing.allocator.create(SelectApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .combobox, "Level");
    try expectRingAround(&app.window, focusedNode(&app.window).?.bounds);
    pressKey(app, &now, .down, .{});
    try testing.expect(app.state.open);
    try expectFocused(&app.window, .option, "One");
    try testing.expectEqual(@as(?u16, 1), focusedNode(&app.window).?.pos_in_set);
    try testing.expectEqual(@as(?u16, 3), focusedNode(&app.window).?.set_size);
    try expectRingAround(&app.window, focusedNode(&app.window).?.bounds);
    pressKey(app, &now, .down, .{});
    pressKey(app, &now, .down, .{});
    pressKey(app, &now, .down, .{});
    try expectFocused(&app.window, .option, "Three");
    pressKey(app, &now, .up, .{});
    try expectFocused(&app.window, .option, "Two");
    pressKey(app, &now, .home, .{});
    try expectFocused(&app.window, .option, "One");
    pressKey(app, &now, .end, .{});
    try expectFocused(&app.window, .option, "Three");
    pressKey(app, &now, .@"return", .{});
    try testing.expectEqual(@as(?usize, 2), app.state.selected);
    try testing.expect(!app.state.open);
    try expectFocused(&app.window, .combobox, "Level");

    // Reopening starts on the chosen option; Esc closes without choosing.
    pressKey(app, &now, .space, .{});
    try testing.expect(app.state.open);
    try expectFocused(&app.window, .option, "Three");
    pressKey(app, &now, .escape, .{});
    try testing.expect(!app.state.open);
    try testing.expectEqual(@as(?usize, 2), app.state.selected);
    try expectFocused(&app.window, .combobox, "Level");

    pressKey(app, &now, .@"return", .{});
    pressKey(app, &now, .up, .{});
    pressKey(app, &now, .space, .{});
    try testing.expectEqual(@as(?usize, 1), app.state.selected);
    try testing.expect(!app.state.open);
}

test "Tab from a Select's menu closes it and moves on, and a click opens it on the combobox" {
    // Goal: Tab and Shift+Tab from an open menu close it and reach the next
    // or previous tab stop in one press, without stepping into the closing
    // menu's options, which the frame on screen still holds; and the pointer
    // path still works beside the keys. Methodology: here the button follows
    // the Select, and the options follow both in hit order, so Shift+Tab
    // from the combobox wraps past the options to the button only if they
    // are not tab stops. Open with Down and Space, leave with Tab and
    // Shift+Tab, then click the trigger and close with Enter; the button is
    // never clicked.
    const app = try testing.allocator.create(SelectApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    var ring: internals.records.Rect = undefined;
    pressKey(app, &now, .tab, .{});
    pressKey(app, &now, .down, .{});
    try testing.expect(app.state.open);
    pressKey(app, &now, .tab, .{});
    try testing.expect(!app.state.open);
    try expectFocused(&app.window, .button, "Below");
    try expectRingAround(&app.window, focusedNode(&app.window).?.bounds);
    pressKey(app, &now, .tab, .{ .shift = true });
    try expectFocused(&app.window, .combobox, "Level");
    pressKey(app, &now, .space, .{});
    try expectFocused(&app.window, .option, "One");
    pressKey(app, &now, .tab, .{ .shift = true });
    try testing.expect(!app.state.open);
    try expectFocused(&app.window, .button, "Below");
    try testing.expectEqual(@as(u32, 0), app.state.below_clicks);
    try testing.expectEqual(@as(?usize, null), app.state.selected);

    // A click opens the menu with focus on the combobox, ringless, where
    // Enter closes it again.
    clickAt(app, &now, 20, 20);
    try testing.expect(app.state.open);
    try expectFocused(&app.window, .combobox, "Level");
    try testing.expectEqual(@as(u32, 0), focusRings(&app.window, &ring));
    pressKey(app, &now, .@"return", .{});
    try testing.expect(!app.state.open);
    try testing.expectEqual(@as(?usize, null), app.state.selected);
    try testing.expectEqual(@as(u32, 0), app.state.below_clicks);
}

test "focus on an element that leaves passes to its combobox or the next tab stop" {
    // Goal: lost focus goes somewhere sensible instead of nowhere, so the
    // next Tab continues from there. Methodology: choose a Select option
    // with the pointer, which removes the pressed option: focus passes to
    // its combobox, ringless as the press left it. Then on todo, delete the
    // last row with Enter on its Delete button: focus passes to the next
    // tab stop, Clear completed, with its ring, and Shift+Tab goes on to the
    // previous row's Delete button.
    const select = try testing.allocator.create(SelectApp);
    defer testing.allocator.destroy(select);
    try select.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer select.deinitHeadless();
    var now: u64 = 0;
    select.tick(now);
    var ring: internals.records.Rect = undefined;
    pressKey(select, &now, .tab, .{});
    pressKey(select, &now, .down, .{});
    try expectFocused(&select.window, .option, "One");
    const frame = select.window.rendered();
    var two: ?internals.records.Rect = null;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (std.mem.eql(u8, frame.text(node.name) orelse "", "Two")) two = node.bounds;
    }
    clickAt(select, &now, two.?.x + 10, two.?.y + 4);
    try testing.expectEqual(@as(?usize, 1), select.state.selected);
    try expectFocused(&select.window, .combobox, "Level");
    try testing.expectEqual(@as(u32, 0), focusRings(&select.window, &ring));

    const app = try testing.allocator.create(todo.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    for ([_][]const u8{ "a", "b", "c" }) |text| {
        app.state.draft = text;
        app.state.addTodo();
    }
    now = 0;
    app.tick(now);
    // The input, Add, three filters, then each row's checkbox and Delete.
    for (0..11) |_| pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .button, "Delete");
    pressKey(app, &now, .@"return", .{});
    try testing.expectEqual(@as(u32, 2), app.state.count);
    try expectFocused(&app.window, .button, "Clear completed");
    try expectRingAround(&app.window, focusedNode(&app.window).?.bounds);
    pressKey(app, &now, .tab, .{ .shift = true });
    try expectFocused(&app.window, .button, "Delete");
    pressKey(app, &now, .space, .{});
    try testing.expectEqual(@as(u32, 1), app.state.count);
    try testing.expectEqualStrings("a", app.state.todos[0].bytes[0..1]);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

/// A CodeEditor beside a Button, for the claimed-Tab check.
const EditorButtonState = struct {
    source: []const u8 = "",
    clicks: u32 = 0,

    pub fn click(self: *EditorButtonState) void {
        self.clicks += 1;
    }
};

const EditorButtonApp = gooey.App(EditorButtonState, editorButtonRender, .{
    .title = "Editor and button",
    .width = 400,
    .height = 200,
    .limits = editor_limits,
});

fn editorButtonRender(cx: *Cx) void {
    const state = cx.state(EditorButtonState);
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .gap = 8 } }, .{
        components.CodeEditor{ .key = "source", .bind = &state.source, .rows = 2 },
        components.Button{ .label = "Run", .on_click = cx.on(EditorButtonState.click, .{}) },
    }));
}

test "a Tab the focused editor claims indents and keeps focus" {
    // Goal: Tab moves focus only when no key handler stopped it, so an
    // editor's indent does not also send focus to the next control.
    // Methodology: Tab into the editor, Tab again to indent, and check the
    // indent and that focus stayed; Shift+Tab, which the editor leaves alone,
    // then moves focus back around to the button, where Enter clicks it.
    const app = try testing.allocator.create(EditorButtonApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    pressKey(app, &now, .tab, .{});
    const editor = app.window.focus;
    try testing.expect(editor != .root);
    pressKey(app, &now, .tab, .{});
    try testing.expectEqualStrings("    ", app.state.source);
    try testing.expectEqual(editor, app.window.focus);
    pressKey(app, &now, .tab, .{ .shift = true });
    try expectFocused(&app.window, .button, "Run");
    pressKey(app, &now, .@"return", .{});
    try testing.expectEqual(@as(u32, 1), app.state.clicks);
}

test "Tab stays inside a modal, so Enter never clicks what the modal blocks" {
    // Goal: keyboard focus follows the pointer's modal rule (contract §6).
    // Methodology: with the small modal open over the content button, Tab
    // from nothing and again must land on the modal's button both times;
    // Enter clicks it and closes the modal, which passes focus to the
    // content button, the tab stop before it, where Tab stays and Space
    // clicks.
    const app = try testing.allocator.create(BlockApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .button, "Inside");
    pressKey(app, &now, .tab, .{ .shift = true });
    try expectFocused(&app.window, .button, "Inside");
    pressKey(app, &now, .@"return", .{});
    try testing.expectEqual(@as(u32, 1), app.state.inside_clicks);
    try testing.expectEqual(@as(u32, 0), app.state.below_clicks);
    try expectFocused(&app.window, .button, "Below");
    try expectRingAround(&app.window, focusedNode(&app.window).?.bounds);
    pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .button, "Below");
    pressKey(app, &now, .space, .{});
    try testing.expectEqual(@as(u32, 1), app.state.below_clicks);
}
