const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");
const counter = @import("counter_example");
const todo = @import("todo_example");
const actions = @import("actions_example");
const animation = @import("animation_example");
const accessible_form = @import("accessible_form_example");
const code_editor = @import("code_editor_example");
const nested_overlay = @import("nested_overlay_example");
const splitter = @import("splitter_example");
const context_menu = @import("context_menu_example");
const drag_drop = @import("drag_drop_example");
const dashboard = @import("dashboard_example");
const dynamic_counters = @import("dynamic_counters_example");
const images = @import("images_example");
const virtual_list = @import("virtual_list_example");
const data_table = @import("data_table_example");
const lucide = @import("lucide_example");
const components = @import("gooey-components");
const vopr_invariants = @import("vopr_invariants");
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
    const Driver = core_driver.CoreDriver(todo.App);
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.todo);
    defer driver.deinit();
    const query = internals.Query{ .window = &driver.app.window };

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

    driver.deliver(.{ .text_input = .{ .text = "caf\u{e9}" } });
    driver.frame();
    try testing.expectEqualStrings("caf\u{e9}", driver.app.state.draft);
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

/// A filling TextArea 20 px inside the window, holding a line longer than
/// any width the check resizes to.
const FillAreaState = struct {
    notes: []const u8 = &(@as([200]u8, @splat('a')) ++ "\nb".*),
};

const FillAreaApp = gooey.App(FillAreaState, fillAreaRender, .{
    .title = "Fill area",
    .width = 400,
    .height = 200,
    .limits = .small,
});

fn fillAreaRender(cx: *Cx) void {
    const state = cx.state(FillAreaState);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(20),
    } }, .{
        components.TextArea{ .key = "notes", .bind = &state.notes, .rows = 2, .width = null },
    }));
}

/// The clip the frame's first glyph draws in: the latest one pushed before it.
fn glyphClip(frame: *const internals.records.Frame) ?internals.records.Rect {
    var clip: ?internals.records.Rect = null;
    for (frame.paint[0..frame.paint_count]) |record| {
        switch (record) {
            .clip_push => |rect| clip = rect,
            .sprite => return clip,
            else => {},
        }
    }
    return null;
}

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

/// 750 copies of "abc ", 3,000 codepoints: past one shaping run, as one
/// unwrapped line or wrapped at 400 px.
const LongTextState = struct {
    wrap: bool = false,

    const text = blk: {
        @setEvalBranchQuota(100_000);
        var bytes: [3_000]u8 = undefined;
        for (0..750) |index| @memcpy(bytes[index * 4 ..][0..4], "abc ");
        break :blk bytes;
    };
};

const LongTextApp = gooey.App(LongTextState, longTextRender, .{
    .title = "Long text",
    .width = 400,
    .height = 200,
    .limits = .standard,
});

fn longTextRender(cx: *Cx) void {
    const state = cx.state(LongTextState);
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{
        ui.text(&LongTextState.text, .{ .wrap = if (state.wrap) .words else .none }),
    }));
}

test "a text past one shaping run draws and wraps as one run would" {
    inline for (.{ false, true }) |wrap| {
        const app = try testing.allocator.create(LongTextApp);
        defer testing.allocator.destroy(app);
        try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
        defer app.deinitHeadless();
        app.state.wrap = wrap;
        app.tick(0);
        const frame = app.window.rendered();
        // The synthetic face draws a box for a space too, and every line,
        // the last included, draws its spaces.
        try testing.expectEqual(@as(u32, 3_000), spriteCount(frame));
        var first: ?internals.records.Rect = null;
        var codepoint: u32 = 0;
        var previous_y: f32 = 0;
        for (frame.paint[0..frame.paint_count]) |record| {
            if (record != .sprite) continue;
            const bounds = record.sprite.bounds;
            if (first == null) first = bounds;
            const column = if (wrap) codepoint % 56 else codepoint;
            const x: f32 = @floatFromInt(column / 4 * 28 + column % 4 * 8);
            try testing.expectApproxEqAbs(first.?.x + x, bounds.x, 0.001);
            if (column == 0 and codepoint > 0) {
                try testing.expect(bounds.y > previous_y);
            } else if (codepoint > 0) {
                try testing.expectEqual(previous_y, bounds.y);
            }
            previous_y = bounds.y;
            codepoint += 1;
        }
        const text_element = app.window.layout.elements.items()[2];
        if (wrap) {
            try testing.expectEqual(@as(usize, 54), text_element.text_data.?.wrapped_lines.?.len);
        } else {
            try testing.expectEqual(@as(f32, 750 * 28), text_element.computed.bounding_box.width);
        }
    }
}

const WrapSpaceState = struct {
    case: u32 = 0,

    const cases = [_][]const u8{
        "aa     aa",
        "aa\t\taa",
        "aa\n   aa aa",
    };
};

const WrapSpaceApp = gooey.App(WrapSpaceState, wrapSpaceRender, .{
    .title = "Wrap spaces",
    .width = 200,
    .height = 200,
    .limits = .small,
});

fn wrapSpaceRender(cx: *Cx) void {
    const state = cx.state(WrapSpaceState);
    cx.render(ui.box(.{ .style = .{ .width = .{ .fixed = 40 } } }, .{
        ui.text(WrapSpaceState.cases[state.case], .{ .size = 16, .wrap = .words }),
    }));
}

test "a wrapped line's glyphs stay inside the wrap width" {
    var overflow_count: u32 = 0;
    for (0..WrapSpaceState.cases.len) |case| {
        const app = try testing.allocator.create(WrapSpaceApp);
        defer testing.allocator.destroy(app);
        try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
        defer app.deinitHeadless();
        app.state.case = @intCast(case);
        app.tick(0);
        const frame = app.window.rendered();
        try testing.expect(spriteCount(frame) > 0);
        var right_max: f32 = 0;
        for (frame.paint[0..frame.paint_count]) |record| {
            if (record != .sprite) continue;
            right_max = @max(right_max, record.sprite.bounds.x + record.sprite.bounds.width);
        }
        if (right_max > 40.001) {
            std.debug.print("case {d} \"{s}\": glyphs end at {d} px\n", .{
                case,
                WrapSpaceState.cases[case],
                right_max,
            });
            overflow_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 0), overflow_count);
}

const MeasureState = struct {
    measured: [measure_cases.len]Cx.TextSize = undefined,
};

const MeasureCase = struct { content: []const u8, style: ui.Text, max_width: f32 };

const measure_cases = [_]MeasureCase{
    .{ .content = "abc abc abc", .style = .{ .wrap = .words }, .max_width = 60 },
    .{ .content = "abc abc abc", .style = .{ .wrap = .none }, .max_width = 60 },
    .{ .content = "ab\n\ncd", .style = .{ .wrap = .newlines }, .max_width = 300 },
    .{
        .content = "abc abc abc",
        .style = .{ .wrap = .words, .line_height = 150 },
        .max_width = 60,
    },
    .{ .content = "   ", .style = .{ .wrap = .words }, .max_width = 60 },
    .{ .content = "abcabcabcabc abc", .style = .{ .wrap = .words, .size = 32 }, .max_width = 100 },
    .{ .content = &LongTextState.text, .style = .{ .wrap = .words }, .max_width = 400 },
};

const MeasureApp = gooey.App(MeasureState, measureRender, .{
    .title = "Measure",
    .width = 400,
    .height = 200,
    .limits = .standard,
});

fn measureRender(cx: *Cx) void {
    const state = cx.state(MeasureState);
    inline for (measure_cases, 0..) |case, index| {
        state.measured[index] = cx.measureText(case.content, case.style, case.max_width);
        cx.render(ui.box(.{ .style = .{ .width = .{ .fixed = case.max_width } } }, .{
            ui.text(case.content, case.style),
        }));
    }
}

test "cx.measureText sizes a text as layout lays it out" {
    const app = try testing.allocator.create(MeasureApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(0);
    const measured = &app.state.measured;
    var case_index: u32 = 0;
    for (app.window.layout.elements.items()) |*element| {
        if (element.text_data == null) continue;
        const bounds = element.computed.bounding_box;
        try testing.expectApproxEqAbs(bounds.width, measured[case_index].width, 0.001);
        try testing.expectApproxEqAbs(bounds.height, measured[case_index].height, 0.001);
        case_index += 1;
    }
    try testing.expectEqual(@as(u32, measure_cases.len), case_index);
    const line_height = measured[1].height;
    try testing.expectEqual(@as(f32, 56), measured[0].width);
    try testing.expectApproxEqAbs(line_height * 2, measured[0].height, 0.5);
    try testing.expectEqual(@as(f32, 80), measured[1].width);
    try testing.expectApproxEqAbs(line_height * 3, measured[2].height, 1);
    try testing.expect(measured[3].height > measured[0].height);
    try testing.expectEqual(@as(f32, 392), measured[6].width);
    try testing.expectApproxEqAbs(line_height * 54, measured[6].height, 27);
}

fn deliverAll(app: *LongRunApp, now: *u64, inputs: []const gooey.input.InputEvent) void {
    for (inputs) |event| app.window.queue.push(.{ .input = event });
    now.* += 1;
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

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
    const app = try testing.allocator.create(AreaApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const query = internals.Query{ .window = &app.window };
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
    try testing.expectApproxEqAbs(inset + line_height, caret.y, 0.001);
    try testing.expectApproxEqAbs(inset + 5 * 8, caret.x, 0.001);

    // The delta is inverted by `window.wheel_delta_inverted`, as `ScrollState.wheel` reads it.
    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
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

    const click = mouse(inset + 2.5 * 8 - 0.5, inset + line_height / 2);
    app.window.queue.push(.{ .input = .{ .mouse_down = click } });
    app.window.queue.push(.{ .input = .{ .mouse_up = click } });
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(u32, 6), query.imeSelectedRange().?.offset);

    app.window.queue.push(.{ .input = .{ .key_down = chord(.up, .{}) } });
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(u32, 2), query.imeSelectedRange().?.offset);
    try testing.expectApproxEqAbs(inset, query.imeCursorRect().?.y, 0.001);
}

test "a filling TextArea draws at the window's new width in the resize's own frame" {
    const app = try testing.allocator.create(FillAreaApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const query = internals.Query{ .window = &app.window };
    var now: u64 = 0;
    app.tick(now);
    const inset: f32 = 9; // The default padding and border.
    const click = mouse(20 + inset + 3 * 8, 20 + inset + 1);
    app.window.queue.push(.{ .input = .{ .mouse_down = click } });
    app.window.queue.push(.{ .input = .{ .mouse_up = click } });
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    for ([_]f32{ 400, 900, 250, 640 }) |width| {
        app.window.queue.push(.{ .window = .{ .resized = .{
            .width = width,
            .height = 200,
            .scale_factor = 1,
        } } });
        now += 1;
        app.tick(now);
        const area = nodeNamed(&app.window, .textarea, "").?.bounds;
        try testing.expectApproxEqAbs(@as(f32, 20), area.x, 0.001);
        try testing.expectApproxEqAbs(width - 40, area.width, 0.001);
        const clip = glyphClip(app.window.rendered()).?;
        try testing.expectApproxEqAbs(area.x + inset, clip.x, 0.001);
        try testing.expectApproxEqAbs(area.width - 2 * inset, clip.width, 0.001);
        const caret = query.imeCursorRect().?;
        try testing.expectApproxEqAbs(20 + inset + 3 * 8, caret.x, 0.001);
        try testing.expectEqual(@as(u32, 3), query.imeSelectedRange().?.offset);
        // Only the caret's blink, a third of a second or more away, is due.
        const deadline = app.window.renderDeadlineNs().?;
        try testing.expect(deadline >= now + 300 * std.time.ns_per_ms);
        try testing.expect(!app.window.render_requested);
    }
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

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
    const app = try testing.allocator.create(EditorApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const query = internals.Query{ .window = &app.window };
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
    try testing.expectApproxEqAbs(text_x + 4 * 4 + 8, caret.x, 0.001);

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

    // The delta is inverted by `window.wheel_delta_inverted`.
    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = text_x + 1, .y = text_y + 1 },
        .delta = .{ .x = 0, .y = -20 * direction },
        .modifiers = .{},
    } } });
    now += 1;
    app.tick(now);
    try testing.expectApproxEqAbs(text_y + line_height, query.imeCursorRect().?.y, 0.001);
}

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
    // Offsets follow the delta, inverted by `window.wheel_delta_inverted`.
    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = x, .y = y },
        .delta = .{ .x = 0, .y = down * direction },
        .modifiers = .{},
    } } });
    now.* += 1;
    app.tick(now.*);
}

test "a scroll box clips its content, clamps its offset, and passes the wheel on at its end" {
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

    scrollWheel(app, &now, inner_x, view.outer.bounds.y + 140, -100);
    view = ScrollView.read(&app.window);
    try testing.expectEqual(@as(f32, 0), view.outer_offset);
    try testing.expectEqual(@as(f32, 30), view.inner_offset);
}

test "wheel_delta_inverted turns the same wheel event the opposite way" {
    const inverted_before = internals.window.wheel_delta_inverted;
    defer internals.window.wheel_delta_inverted = inverted_before;
    const app = try testing.allocator.create(ScrollApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);

    var view = ScrollView.read(&app.window);
    try testing.expectEqual(@as(f32, 0), view.inner_offset);
    const event: gooey.input.InputEvent = .{ .scroll = .{
        .position = .{ .x = view.inner.bounds.x + 10, .y = view.inner.bounds.y + 10 },
        .delta = .{ .x = 0, .y = 20 },
        .modifiers = .{},
    } };
    const inverted_choices = [_]bool{ false, true };
    const offsets_expected = [_]f32{ 20, 0 };
    for (inverted_choices, offsets_expected) |inverted, offset_expected| {
        internals.window.wheel_delta_inverted = inverted;
        app.window.queue.push(.{ .input = event });
        now += 1;
        app.tick(now);
        view = ScrollView.read(&app.window);
        try testing.expectEqual(offset_expected, view.inner_offset);
        try testing.expectEqual(@as(f32, 0), view.outer_offset);
    }
}

const CullApp = gooey.App(struct {}, cullRender, .{
    .title = "Cull",
    .width = 400,
    .height = 300,
    .limits = .standard,
});

const cull_row_count: u32 = 100;
const cull_row_height: f32 = 24;
const cull_row_color = ui.Color.rgb(0.2, 0.4, 0.6);
const cull_label = "row text";

fn cullRender(cx: *Cx) void {
    const long = comptime blk: {
        @setEvalBranchQuota(10_000);
        var bytes: [800]u8 = undefined;
        for (0..200) |index| @memcpy(bytes[index * 4 ..][0..4], "abc\n");
        break :blk bytes;
    };
    cx.render(ui.box(.{ .key = .{ .name = "log" }, .style = .{
        .width = .{ .fixed = 300 },
        .height = .{ .fixed = 200 },
        .scroll = .{},
    } }, .{
        CullRows{},
        ui.text(&long, .{ .wrap = .words }),
    }));
}

const CullRows = struct {
    pub fn render(_: CullRows, cx: *Cx) void {
        var index: u32 = 0;
        while (index < cull_row_count) : (index += 1) {
            cx.render(ui.box(.{
                .key = .{ .index = index },
                .focusable = true,
                .a11y = .{ .role = .listitem, .label = cull_label },
                .style = .{
                    .width = .{ .grow = 1 },
                    .height = .{ .fixed = cull_row_height },
                    .background = .{ .rgba = cull_row_color },
                },
            }, .{ui.text(cull_label, .{ .size = 16 })}));
        }
    }
};

const CullCount = struct { fills: u32, top: f32, sprites: u32, sprite_bottom: f32 };

fn cullCount(frame: *const internals.records.Frame) CullCount {
    var count = CullCount{
        .fills = 0,
        .top = std.math.floatMax(f32),
        .sprites = 0,
        .sprite_bottom = 0,
    };
    for (frame.paint[0..frame.paint_count]) |record| {
        switch (record) {
            .quad => |quad| {
                if (quad.fill.r != cull_row_color.r or quad.fill.b != cull_row_color.b) continue;
                count.fills += 1;
                count.top = @min(count.top, quad.bounds.y);
            },
            .sprite => |sprite| {
                count.sprites += 1;
                count.sprite_bottom = @max(count.sprite_bottom, sprite.bounds.y);
            },
            else => {},
        }
    }
    return count;
}

test "a scroll box draws only what is in view, and keeps every row's hit and node" {
    const app = try testing.allocator.create(CullApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);

    var count = cullCount(app.window.rendered());
    try testing.expectEqual(@as(u32, 9), count.fills);
    try testing.expectEqual(@as(f32, 0), count.top);
    try testing.expect(count.sprites >= 9 * cull_label.len);
    try testing.expect(count.sprites <= 10 * cull_label.len);
    try testing.expect(count.sprite_bottom < 200 + cull_row_height);
    const frame = app.window.rendered();
    var focusable: u32 = 0;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.focusable) focusable += 1;
    }
    try testing.expectEqual(cull_row_count, focusable);
    var items: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role == .listitem) items += 1;
    }
    try testing.expectEqual(cull_row_count, items);

    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = 100, .y = 100 },
        .delta = .{ .x = 0, .y = 1_200 * direction },
        .modifiers = .{},
    } } });
    now += 1;
    app.tick(now);
    count = cullCount(app.window.rendered());
    try testing.expectEqual(@as(u32, 9), count.fills);
    try testing.expectEqual(@as(f32, 0), count.top);

    pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .listitem, cull_label);
    count = cullCount(app.window.rendered());
    try testing.expectEqual(@as(f32, 0), count.top);
    try testing.expect(count.fills <= 10);
}

const FollowState = struct {
    count: u32 = 20,
    target: ui.ScrollTarget = .end,

    fn log() gooey.ElementId {
        return gooey.ElementId.root.child(.{ .name = "page" }).child(.{ .name = "log" });
    }

    pub fn go(self: *FollowState, effects: *Effects) void {
        effects.scrollTo(log(), self.target);
    }

    pub fn add(self: *FollowState) void {
        self.count += 5;
    }
};

const FollowApp = gooey.App(FollowState, followRender, .{
    .title = "Follow",
    .width = 300,
    .height = 300,
    .limits = .small,
});

const follow_row_height: f32 = 24;

fn followRender(cx: *Cx) void {
    const state = cx.state(FollowState);
    const button: ui.Style = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 30 } };
    cx.render(ui.box(.{ .key = .{ .name = "page" }, .style = .{ .width = .{ .grow = 1 } } }, .{
        ui.box(.{ .style = .{ .direction = .row } }, .{
            ui.box(.{
                .key = .{ .name = "go" },
                .on_click = cx.on(FollowState.go, .{}),
                .style = button,
            }, .{}),
            ui.box(.{
                .key = .{ .name = "add" },
                .on_click = cx.on(FollowState.add, .{}),
                .style = button,
            }, .{}),
        }),
        ui.box(.{ .key = .{ .name = "log" }, .style = .{
            .width = .{ .fixed = 200 },
            .height = .{ .fixed = 200 },
            .scroll = .{ .anchor = .end },
        } }, .{FollowRows{ .count = state.count }}),
    }));
}

const FollowRows = struct {
    count: u32,

    pub fn render(self: FollowRows, cx: *Cx) void {
        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            cx.render(ui.box(.{ .key = .{ .index = index }, .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .fixed = follow_row_height },
            } }, .{}));
        }
    }
};

fn clickOnce(app: anytype, now: *u64, x: f32, y: f32) void {
    app.window.queue.push(.{ .input = .{ .mouse_down = mouse(x, y) } });
    app.window.queue.push(.{ .input = .{ .mouse_up = mouse(x, y) } });
    now.* += 1;
    app.tick(now.*);
}

fn followOffset(app: *FollowApp) f32 {
    const State = internals.window.ScrollState;
    return app.window.retained.find(State, FollowState.log()).?.offset_y;
}

fn followRowTop(app: *FollowApp, index: u32) f32 {
    const frame = app.window.rendered();
    const log = FollowState.log();
    var box_top: f32 = 0;
    var row_top: ?f32 = null;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.id == log) box_top = record.bounds.y;
    }
    // A row's hit is clipped by the box, so read its laid-out top instead.
    for (app.window.nodes[0..app.window.node_count], 0..) |*node, position| {
        if (node.id != log.child(.{ .index = index })) continue;
        row_top = app.window.layout.elements.items()[position].computed.bounding_box.y;
    }
    return row_top.? - box_top;
}

test "an end-anchored scroll box follows its content until scrolled away" {
    const app = try testing.allocator.create(FollowApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    try testing.expectEqual(@as(f32, 280), followOffset(app));
    try testing.expectEqual(@as(f32, 200 - follow_row_height), followRowTop(app, 19));
    now += 1;
    app.tick(now);

    clickOnce(app, &now, 75, 15);
    try testing.expectEqual(@as(u32, 25), app.state.count);
    try testing.expectEqual(@as(f32, 400), followOffset(app));
    try testing.expectEqual(@as(f32, 200 - follow_row_height), followRowTop(app, 24));

    scrollWheelAt(app, &now, 100, 100, -50);
    try testing.expectEqual(@as(f32, 350), followOffset(app));
    clickOnce(app, &now, 75, 15);
    try testing.expectEqual(@as(f32, 350), followOffset(app));
    scrollWheelAt(app, &now, 100, 100, 500);
    try testing.expectEqual(@as(f32, 520), followOffset(app));
    clickOnce(app, &now, 75, 15);
    try testing.expectEqual(@as(f32, 640), followOffset(app));

    const Case = struct { target: ui.ScrollTarget, offset: f32 };
    const cases = [_]Case{
        .{ .target = .start, .offset = 0 },
        .{ .target = .{ .offset = .{ .y = 100 } }, .offset = 100 },
        .{ .target = .{ .offset = .{ .y = 5_000 } }, .offset = 640 },
        .{ .target = .{ .child = .{ .key = .{ .index = 3 }, .alignment = .start } }, .offset = 72 },
        .{
            .target = .{ .child = .{ .key = .{ .index = 20 }, .alignment = .center } },
            .offset = 392,
        },
        .{ .target = .{ .child = .{ .key = .{ .index = 20 }, .alignment = .end } }, .offset = 304 },
        .{ .target = .{ .child = .{ .key = .{ .index = 20 } } }, .offset = 304 },
        .{ .target = .{ .child = .{ .key = .{ .index = 2 } } }, .offset = 48 },
        .{ .target = .{ .child = .{ .key = .{ .index = 99 } } }, .offset = 48 },
        .{ .target = .end, .offset = 640 },
    };
    for (cases) |case| {
        app.state.target = case.target;
        clickOnce(app, &now, 25, 15);
        try testing.expectEqual(case.offset, followOffset(app));
    }
    clickOnce(app, &now, 75, 15);
    try testing.expectEqual(@as(f32, 760), followOffset(app));
}

fn scrollWheelAt(app: anytype, now: *u64, x: f32, y: f32, down: f32) void {
    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = x, .y = y },
        .delta = .{ .x = 0, .y = down * direction },
        .modifiers = .{},
    } } });
    now.* += 1;
    app.tick(now.*);
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
    scrollMouse(app, &now, .{ .mouse_dragged = mouse(bar_x, box.y + 400) });
    const view = ScrollView.read(&app.window);
    try testing.expectEqual(@as(f32, 110), view.outer_offset);
    try testing.expectEqual(@as(f32, 0), view.inner_offset);
    scrollMouse(app, &now, .{ .mouse_up = mouse(bar_x, box.y + 400) });
    try testing.expect(!thumbDragged(app));
    scrollMouse(app, &now, .{ .mouse_moved = mouse(bar_x, box.y + 5) });
    try testing.expectEqual(@as(f32, 110), ScrollView.read(&app.window).outer_offset);

    const quarter = box.y + 2 + 146 * 0.25;
    scrollMouse(app, &now, .{ .mouse_down = mouse(bar_x, quarter) });
    scrollMouse(app, &now, .{ .mouse_up = mouse(bar_x, quarter) });
    try testing.expectApproxEqAbs(@as(f32, 27.5), ScrollView.read(&app.window).outer_offset, 0.01);
    try testing.expect(!thumbDragged(app));
    try testing.expectEqual(gooey.ElementId.root, app.window.scroll_drag);
}

fn mouseWith(x: f32, y: f32, button: gooey.input.MouseButton) gooey.input.MouseEvent {
    var event = mouse(x, y);
    event.button = button;
    return event;
}

/// The scroll check's app, ticked twice so the outer box's bar is laid out.
fn scrollAppReady(app: *ScrollApp, now: *u64) !void {
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

test "a second button pressed during a thumb drag leaves the drag alone" {
    const app = try testing.allocator.create(ScrollApp);
    defer testing.allocator.destroy(app);
    var now: u64 = 0;
    try scrollAppReady(app, &now);
    defer app.deinitHeadless();
    const box = ScrollView.read(&app.window).outer.bounds;
    const bar_x = box.x + box.width - 10 + 4;
    const travel: f32 = 146.0 - 146.0 * 150.0 / 260.0;
    const quarter_y = box.y + 10 + travel / 4;

    scrollMouse(app, &now, .{ .mouse_down = mouseWith(bar_x, box.y + 10, .left) });
    scrollMouse(app, &now, .{ .mouse_dragged = mouseWith(bar_x, quarter_y, .left) });
    try testing.expectApproxEqAbs(@as(f32, 27.5), ScrollView.read(&app.window).outer_offset, 0.01);
    scrollMouse(app, &now, .{ .mouse_down = mouseWith(bar_x, quarter_y, .right) });
    scrollMouse(app, &now, .{ .mouse_up = mouseWith(bar_x, quarter_y, .right) });
    try testing.expect(thumbDragged(app));
    scrollMouse(app, &now, .{ .mouse_dragged = mouseWith(bar_x, box.y + 10 + travel / 2, .left) });
    try testing.expectApproxEqAbs(@as(f32, 55), ScrollView.read(&app.window).outer_offset, 0.01);
    scrollMouse(app, &now, .{ .mouse_up = mouseWith(bar_x, box.y + 10 + travel / 2, .left) });
    try testing.expect(!thumbDragged(app));
    try testing.expectEqual(gooey.ElementId.root, app.window.scroll_drag);
}

test "a right press on a scrollbar thumb drags nothing" {
    const app = try testing.allocator.create(ScrollApp);
    defer testing.allocator.destroy(app);
    var now: u64 = 0;
    try scrollAppReady(app, &now);
    defer app.deinitHeadless();
    const box = ScrollView.read(&app.window).outer.bounds;
    const bar_x = box.x + box.width - 10 + 4;

    scrollMouse(app, &now, .{ .mouse_down = mouseWith(bar_x, box.y + 10, .right) });
    try testing.expectEqual(gooey.ElementId.root, app.window.scroll_drag);
    try testing.expect(!thumbDragged(app));
    scrollMouse(app, &now, .{ .mouse_dragged = mouseWith(bar_x, box.y + 40, .right) });
    try testing.expectEqual(@as(f32, 0), ScrollView.read(&app.window).outer_offset);
    scrollMouse(app, &now, .{ .mouse_up = mouseWith(bar_x, box.y + 40, .right) });
    try testing.expectEqual(@as(f32, 0), ScrollView.read(&app.window).outer_offset);
}

test "another button's release leaves a thumb drag alive" {
    const app = try testing.allocator.create(ScrollApp);
    defer testing.allocator.destroy(app);
    var now: u64 = 0;
    try scrollAppReady(app, &now);
    defer app.deinitHeadless();
    const box = ScrollView.read(&app.window).outer.bounds;
    const bar_x = box.x + box.width - 10 + 4;
    const travel: f32 = 146.0 - 146.0 * 150.0 / 260.0;
    const half_y = box.y + 10 + travel / 2;

    scrollMouse(app, &now, .{ .mouse_down = mouseWith(30, 200, .right) });
    scrollMouse(app, &now, .{ .mouse_down = mouseWith(bar_x, box.y + 10, .left) });
    try testing.expect(app.window.scroll_drag.isKeyed());
    scrollMouse(app, &now, .{ .mouse_up = mouseWith(bar_x, box.y + 10, .right) });
    try testing.expect(app.window.scroll_drag.isKeyed());
    scrollMouse(app, &now, .{ .mouse_dragged = mouseWith(bar_x, half_y, .left) });
    try testing.expectApproxEqAbs(@as(f32, 55), ScrollView.read(&app.window).outer_offset, 0.01);
    scrollMouse(app, &now, .{ .mouse_up = mouseWith(bar_x, half_y, .left) });
    try testing.expectEqual(gooey.ElementId.root, app.window.scroll_drag);
}

const ClickCountState = struct {
    clicks: u32 = 0,

    fn count(self: *ClickCountState) void {
        self.clicks += 1;
    }
};

const ClickCountApp = gooey.App(ClickCountState, clickCountRender, .{
    .title = "Clicks",
    .width = 200,
    .height = 100,
    .limits = .nano,
});

fn clickCountRender(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{
        ui.box(.{
            .key = .{ .name = "count" },
            .on_click = cx.on(ClickCountState.count, .{}),
            .style = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 50 } },
        }, .{}),
    }));
}

fn clickWith(app: *ClickCountApp, now: *u64, button: gooey.input.MouseButton) void {
    scrollMouse(app, now, .{ .mouse_down = mouseWith(25, 25, button) });
    scrollMouse(app, now, .{ .mouse_up = mouseWith(25, 25, button) });
}

test "only the left button clicks" {
    const app = try testing.allocator.create(ClickCountApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 1;
    app.tick(now);
    const state = &app.state;

    clickWith(app, &now, .right);
    clickWith(app, &now, .middle);
    try testing.expectEqual(@as(u32, 0), state.clicks);
    clickWith(app, &now, .left);
    try testing.expectEqual(@as(u32, 1), state.clicks);

    scrollMouse(app, &now, .{ .mouse_down = mouseWith(25, 25, .left) });
    scrollMouse(app, &now, .{ .mouse_down = mouseWith(150, 80, .right) });
    scrollMouse(app, &now, .{ .mouse_up = mouseWith(150, 80, .right) });
    try testing.expectEqual(@as(u32, 1), state.clicks);
    scrollMouse(app, &now, .{ .mouse_up = mouseWith(25, 25, .left) });
    try testing.expectEqual(@as(u32, 2), state.clicks);
}

const ReadsState = struct {
    position: ?Cx.ScrollPosition = null,
    bounds: ?ui.Rect = null,
    now_ns: u64 = 0,
    builds: u32 = 0,
};

const ReadsApp = gooey.App(ReadsState, readsRender, .{
    .title = "Reads",
    .width = 300,
    .height = 300,
    .limits = gooey.ResourceLimits.small,
});

/// A 60 px scroll box of three 30 px rows under a 20 px spacer, which reads
/// its own position and bounds before rendering, as `List` does.
fn readsRender(cx: *Cx) void {
    const state = cx.state(ReadsState);
    const key = gooey.Key{ .name = "reads" };
    state.position = cx.scroll(cx.id(key));
    state.bounds = cx.bounds(cx.id(key));
    state.now_ns = cx.now();
    state.builds += 1;
    cx.render(ui.box(.{ .style = .{ .height = .{ .fixed = 20 } } }, .{}));
    cx.render(ui.box(.{ .key = key, .style = .{
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 60 },
        .scroll = .{},
    } }, .{ScrollRows{}}));
}

test "cx.scroll, cx.bounds, and cx.now read the last frame and the tick from render" {
    const app = try testing.allocator.create(ReadsApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 1_000;
    app.tick(now);
    try testing.expect(app.state.position == null);
    try testing.expect(app.state.bounds == null);
    try testing.expectEqual(@as(u64, 1_000), app.state.now_ns);

    now = 5_000;
    app.tick(now);
    try testing.expectEqual(@as(u64, 5_000), app.state.now_ns);
    const bounds = app.state.bounds.?;
    try testing.expectEqual(@as(f32, 20), bounds.y);
    try testing.expectEqual(@as(f32, 60), bounds.height);
    const settled = app.state.position.?;
    try testing.expectEqual(@as(f32, 0), settled.offset_y);
    try testing.expectEqual(bounds.y, settled.viewport.y);
    try testing.expectEqual(bounds.height, settled.viewport.height);

    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = bounds.x + 10, .y = bounds.y + 10 },
        .delta = .{ .x = 0, .y = 20 * direction },
        .modifiers = .{},
    } } });
    const builds = app.state.builds;
    now += 1;
    app.tick(now);
    try testing.expectEqual(builds + 1, app.state.builds);
    try testing.expectEqual(@as(f32, 20), app.state.position.?.offset_y);
    try testing.expectEqual(@as(f32, 0), app.state.position.?.offset_x);
}

const NanoScrollApp = gooey.App(struct {}, scrollRender, .{
    .title = "Scroll",
    .width = 300,
    .height = 300,
    .limits = .nano,
});

test "a stalled tick's 300 held-button moves fold into one on a 64-event queue" {
    const app = try testing.allocator.create(NanoScrollApp);
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
    const move_count: u32 = 300;
    try testing.expect(move_count > app.window.queue.events.len);

    app.window.queue.push(.{ .input = .{ .mouse_down = mouse(bar_x, box.y + 10) } });
    for (1..move_count + 1) |step| {
        const fraction = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(move_count));
        const y = box.y + 10 + travel / 2 * fraction;
        app.window.queue.push(.{ .input = .{ .mouse_dragged = mouse(bar_x, y) } });
    }
    try testing.expectEqual(@as(u32, 2), app.window.queue.count);
    now += 1;
    app.tick(now);
    try testing.expectApproxEqAbs(@as(f32, 55), ScrollView.read(&app.window).outer_offset, 0.01);
}

const SelectState = struct {
    selected: ?usize = null,
    below_clicks: u32 = 0,

    const options = [_][]const u8{ "One", "Two", "Three" };

    pub fn choose(self: *SelectState, index: u32) void {
        self.selected = index;
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
                .selected = state.selected,
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
    const app = try testing.allocator.create(SelectApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    try testing.expect(!comboboxState(app).expanded);
    try testing.expect(comboboxState(app).has_popup);

    clickAt(app, &now, 20, 20);
    try testing.expect(comboboxState(app).expanded);
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
    try testing.expect(options[2].y + options[2].height > 60);
    const target = button.?;
    var chosen: ?usize = null;
    for (options, 0..) |option, index| {
        if (option.contains(target.x + 10, target.y + 4)) chosen = index;
    }
    clickAt(app, &now, target.x + 10, target.y + 4);
    try testing.expectEqual(chosen.?, app.state.selected.?);
    try testing.expectEqual(@as(u32, 0), app.state.below_clicks);
    try testing.expect(!comboboxState(app).expanded);

    clickAt(app, &now, 20, 20);
    try testing.expect(comboboxState(app).expanded);
    clickAt(app, &now, 390, 290);
    try testing.expect(!comboboxState(app).expanded);
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
    const app = try testing.allocator.create(BlockApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const query = internals.Query{ .window = &app.window };
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

fn overlayCombobox(app: *nested_overlay.App) *const internals.records.A11yNode {
    const frame = app.window.rendered();
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role == .combobox) return node;
    }
    unreachable; // The example's modal always shows its Select.
}

fn overlayComboboxExpanded(app: *nested_overlay.App) bool {
    return overlayCombobox(app).state.expanded;
}

test "nested_overlay: a Select's menu inside a modal sits above the modal" {
    const app = try testing.allocator.create(nested_overlay.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    try testing.expect(!overlayComboboxExpanded(app));
    const combobox = overlayCombobox(app).bounds;
    clickAt(app, &now, combobox.x + combobox.width / 2, combobox.y + combobox.height / 2);
    try testing.expect(overlayComboboxExpanded(app));
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
    const bravo = options[1];
    const x = bravo.x + 20;
    const y = bravo.y + bravo.height / 2;
    try testing.expect(area.?.contains(x, y));
    try testing.expect(dialogCount(frame) == 1);

    clickAt(app, &now, x, y);
    try testing.expectEqual(@as(?usize, 1), app.state.selected);
    try testing.expect(!overlayComboboxExpanded(app));
}

fn dialogCount(frame: *const internals.records.Frame) u32 {
    var count: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role == .dialog) count += 1;
    }
    return count;
}

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
        app.tick(now);
        // No frame of the state before the outcome; the render waits for it.
        try testing.expectEqual(built, app.window.frame_number);
        try testing.expect(app.window.render_requested);
        now += 1;
        app.tick(now);
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
    // The lifecycle guard panics on any allocation while running, so finishing a
    // trace proves none happened.
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

    window.queue.push(.{ .input = .{ .mouse_down = mouse(485, 175) } });
    window.queue.push(.{ .input = .{ .mouse_up = mouse(485, 175) } });
    try testing.expect(tick.tickMain(&driver.app, window, now + 1));
    try testing.expect(window.frame_in_flight.load(.acquire));
    try testing.expectEqual(@as(i32, 1), driver.app.state.count);

    window.queue.push(.{ .input = .{ .mouse_down = mouse(485, 175) } });
    window.queue.push(.{ .input = .{ .mouse_up = mouse(485, 175) } });
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
        driver.deliver(.{ .mouse_down = mouse(485, 175) });
        driver.deliver(.{ .mouse_up = mouse(485, 175) });
        driver.frame();
    }
    try testing.expectEqual(first + 3, uploads.frameCurrent());
    driver.frame();
    try testing.expectEqual(first + 3, uploads.frameCurrent());
}

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

test "boxes nest exactly to build.box_depth_max and every level lays out inside its parent" {
    const app = try testing.allocator.create(DeepApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(1);
    const box_count: u32 = gooey.ResourceLimits.nano.build.box_depth_max - 1;
    const layout = app.window.layout;
    try testing.expectEqual(box_count + 1, layout.elements.len());
    var index: u32 = 1;
    while (index <= box_count) : (index += 1) {
        const bounds = layout.elements.getConst(index).computed.bounding_box;
        const offset: f32 = @floatFromInt(index - 1);
        const side: f32 = @floatFromInt(10 + 2 * (box_count - index));
        try testing.expectEqual(offset, bounds.x);
        try testing.expectEqual(offset, bounds.y);
        try testing.expectEqual(side, bounds.width);
        try testing.expectEqual(side, bounds.height);
    }
    var deepest: u32 = 0;
    for (app.window.nodes[0..app.window.node_count]) |node| deepest = @max(deepest, node.depth);
    try testing.expectEqual(box_count, deepest);
}

const DeepApp = gooey.App(struct {}, deepRender, .{
    .title = "Deep",
    .width = 300,
    .height = 200,
    .limits = .nano,
});

fn deepRender(cx: *Cx) void {
    cx.render(DeepBoxes{ .remaining = gooey.ResourceLimits.nano.build.box_depth_max - 1 });
}

/// Two padded boxes per component level, so the component depth budget
/// (64) is not what limits the nesting; a 10 px box at the bottom.
const DeepBoxes = struct {
    remaining: u32,

    pub fn render(self: DeepBoxes, cx: *Cx) void {
        assert(self.remaining > 0);
        const pad: ui.Style = .{ .padding = .all(1) };
        const leaf = ui.box(.{ .style = .{
            .width = .{ .fixed = 10 },
            .height = .{ .fixed = 10 },
        } }, .{});
        if (self.remaining == 1) return cx.render(leaf);
        if (self.remaining == 2) return cx.render(ui.box(.{ .style = pad }, .{leaf}));
        cx.render(ui.box(.{ .style = pad }, .{
            ui.box(.{ .style = pad }, .{DeepBoxes{ .remaining = self.remaining - 2 }}),
        }));
    }
};

test "the cursor resolves from the hovered record and its ancestors" {
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
    const Driver = core_driver.CoreDriver(counter.App);
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.counter);
    defer driver.deinit();
    const state = &driver.app.state;
    driver.frame();

    driver.deliver(.{ .mouse_down = mouse(485, 175) });
    driver.frame();
    try testing.expectEqual(@as(i32, 0), state.count);
    driver.deliver(.{ .mouse_up = mouse(490, 180) });
    driver.frame();
    try testing.expectEqual(@as(i32, 1), state.count);

    driver.deliver(.{ .mouse_down = mouse(485, 175) });
    driver.deliver(.{ .mouse_up = mouse(402, 175) });
    driver.frame();
    try testing.expectEqual(@as(i32, 1), state.count);

    driver.deliver(.{ .mouse_up = mouse(485, 175) });
    driver.frame();
    try testing.expectEqual(@as(i32, 1), state.count);
}

const FontState = struct {
    pub fn useSerif(_: *FontState, effects: *Effects) void {
        effects.setFont("Synthetic Serif", 20);
    }
};

const FontApp = gooey.App(FontState, fontRender, .{
    .title = "Fonts",
    .width = 300,
    .height = 100,
    .limits = font_limits,
    .fonts = .{ .mono = .{ .system = .monospace } },
});

const font_limits = blk: {
    var value = gooey.ResourceLimits.nano;
    value.text.fonts = .{ .variants = &.{.regular}, .mono_variants = &.{.regular} };
    break :blk value;
};

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
    const app = try testing.allocator.create(FontApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const tick = internals.tick;
    const window = &app.window;
    const text_system = app.resources.text_system;
    app.tick(1);
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
    const app = try testing.allocator.create(WrapApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(1);
    var starts: [8]internals.records.Rect = undefined;
    try testing.expectEqual(@as(u32, 5), lineStarts(&app.window, &starts));
    const reference = starts[4];
    const expected_x = [_]f32{ 20.5, 76, 42, -1.75 };
    const expected_y = [_]f32{ -60, -42, -24, -12 };
    for (starts[0..4], expected_x, expected_y) |start, x, y| {
        try testing.expectApproxEqAbs(x, start.x - reference.x, 1);
        try testing.expectApproxEqAbs(y, start.y - reference.y, 1);
    }
}

const AlignCase = struct {
    direction: ui.Direction = .column,
    box_alignment: ui.Alignment,
    text_alignment: @FieldType(ui.Text, "alignment"),
    scrolled: bool = false,

    pub fn render(self: AlignCase, cx: *Cx) void {
        // A scroll box retains its offset under its key.
        const key: ?gooey.Key = if (self.scrolled) .{ .name = "scrolled" } else null;
        cx.render(ui.box(.{ .key = key, .style = .{
            .direction = self.direction,
            .width = .{ .fixed = 100 },
            .alignment = self.box_alignment,
            .scroll = if (self.scrolled) .{ .x = true, .y = false, .anchor = .end } else null,
        } }, .{
            if (self.scrolled) ui.box(.{ .style = .{
                .width = .{ .fixed = 120 },
                .height = .{ .fixed = 1 },
            } }, .{}) else null,
            ui.text("mm\nmmmmm", .{
                .size = 10,
                .wrap = .newlines,
                .alignment = self.text_alignment,
            }),
        }));
    }
};

const align_cases = [_]AlignCase{
    .{ .box_alignment = .center, .text_alignment = .center },
    .{ .box_alignment = .start, .text_alignment = .center },
    .{ .box_alignment = .{ .cross = .end }, .text_alignment = .center },
    .{ .box_alignment = .center, .text_alignment = .right },
    .{ .box_alignment = .start, .text_alignment = .right },
    .{ .box_alignment = .center, .text_alignment = .left },
    .{ .box_alignment = .{ .cross = .end }, .text_alignment = .left },
    .{ .direction = .row, .box_alignment = .{ .main = .center }, .text_alignment = .center },
    .{ .box_alignment = .start, .text_alignment = .center, .scrolled = true },
};

const AlignState = struct {};

const AlignApp = gooey.App(AlignState, alignRender, .{
    .title = "Align",
    .width = 300,
    .height = 400,
    .limits = .nano,
});

fn alignRender(cx: *Cx) void {
    cx.render(ui.box(.{}, .{
        ui.text("m", .{ .size = 10 }),
        align_cases[0],
        align_cases[1],
        align_cases[2],
        align_cases[3],
        align_cases[4],
        align_cases[5],
        align_cases[6],
        align_cases[7],
        align_cases[8],
    }));
}

test "aligned text lines sit in the parent's content width whatever the parent's alignment" {
    const app = try testing.allocator.create(AlignApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(1);
    app.tick(2);
    var starts: [1 + align_cases.len * 2]internals.records.Rect = undefined;
    try testing.expectEqual(@as(u32, starts.len), lineStarts(&app.window, &starts));
    const reference = starts[0];
    const expected_x = [align_cases.len][2]f32{
        .{ 42, 30 }, .{ 42, 30 }, .{ 42, 30 }, .{ 84, 60 },
        .{ 84, 60 }, .{ 30, 30 }, .{ 60, 60 }, .{ 42, 30 },
        .{ 22, 10 },
    };
    for (expected_x, 0..) |lines, case| {
        for (lines, 0..) |x, line| {
            const start = starts[1 + case * 2 + line];
            try testing.expectApproxEqAbs(x, start.x - reference.x, 1);
        }
    }
}

test "a host's teardown frees through the guard after stop and leaves no atlas consumer" {
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
    const Driver = core_driver.CoreDriver(actions.AppWith(.cmd));
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.actions);
    defer driver.deinit();
    const query = internals.Query{ .window = &driver.app.window };
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

const ChromeState = struct {
    clicks: u32 = 0,

    pub fn click(self: *ChromeState) void {
        self.clicks += 1;
    }

    pub fn drag(_: *ChromeState, effects: *Effects) void {
        assert(effects.pointerDrag() != null);
    }
};

const ChromeApp = gooey.App(ChromeState, chromeRender, .{
    .title = "Chrome",
    .width = 300,
    .height = 200,
    .limits = .nano,
});

fn chromeRender(cx: *Cx) void {
    const fixed = struct {
        fn size(width: f32, height: f32) ui.Style {
            return .{ .width = .{ .fixed = width }, .height = .{ .fixed = height } };
        }
    };
    var list = fixed.size(100, 168);
    list.scroll = .{};
    const grow: ui.Style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } };
    cx.render(ui.box(.{ .style = grow }, .{
        ui.box(.{ .style = .{ .direction = .row, .width = .{ .grow = 1 } } }, .{
            ui.box(.{
                .key = .{ .name = "close" },
                .style = fixed.size(40, 32),
                .on_click = cx.on(ChromeState.click, .{}),
            }, .{ui.box(.{ .style = fixed.size(20, 20) }, .{})}),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
            ui.box(.{
                .key = .{ .name = "search" },
                .style = fixed.size(60, 32),
                .focusable = true,
            }, .{}),
        }),
        ui.box(.{ .style = .{ .direction = .row, .width = .{ .grow = 1 } } }, .{
            ui.box(.{
                .key = .{ .name = "card" },
                .style = fixed.size(40, 40),
                .draggable = .of(u32, 1),
            }, .{}),
            ui.box(.{
                .key = .{ .name = "splitter" },
                .style = fixed.size(6, 40),
                .on_pointer_drag = cx.on(ChromeState.drag, .{}),
            }, .{}),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
            ui.box(.{ .key = .{ .name = "list" }, .style = list }, .{
                ui.box(.{ .style = fixed.size(90, 400) }, .{}),
            }),
        }),
    }));
}

test "pressClaims takes presses on controls and leaves empty chrome to the window" {
    const app = try testing.allocator.create(ChromeApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    // The first emit measures the list's overflow; its track needs a second.
    now += 1;
    app.tick(now);
    const query = internals.Query{ .window = &app.window };

    try testing.expect(query.pressClaims(.{ .x = 1, .y = 1 }));
    try testing.expect(query.pressClaims(.{ .x = 10, .y = 10 }));
    try testing.expect(query.pressClaims(.{ .x = 39, .y = 31 }));
    try testing.expect(!query.pressClaims(.{ .x = 40, .y = 16 }));
    try testing.expect(!query.pressClaims(.{ .x = 150, .y = 1 }));
    try testing.expect(!query.pressClaims(.{ .x = 239, .y = 31 }));
    try testing.expect(query.pressClaims(.{ .x = 299, .y = 1 }));
    try testing.expect(query.pressClaims(.{ .x = 1, .y = 50 }));
    try testing.expect(query.pressClaims(.{ .x = 45, .y = 50 }));
    try testing.expect(!query.pressClaims(.{ .x = 47, .y = 50 }));
    try testing.expect(!query.pressClaims(.{ .x = 1, .y = 150 }));
    try testing.expect(!query.pressClaims(.{ .x = 120, .y = 199 }));
    try testing.expect(query.pressClaims(.{ .x = 294, .y = 100 }));
    try testing.expect(!query.pressClaims(.{ .x = 289, .y = 100 }));
    try testing.expect(!query.pressClaims(.{ .x = 299, .y = 100 }));

    clickAt(app, &now, 1, 1);
    try testing.expectEqual(@as(u32, 1), app.state.clicks);
}

const InsetState = struct {};

/// Headless, the host is the test.
const InsetApp = gooey.App(InsetState, insetRender, .{
    .title = "Inset",
    .width = 300,
    .height = 200,
    .limits = .nano,
    .title_bar = .transparent,
});

fn insetRender(cx: *Cx) void {
    const inset = cx.titleBarInset();
    cx.render(ui.box(.{ .style = .{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .fixed = @max(inset.top, 16) },
        .padding = .{ .left = inset.left, .right = inset.right },
        .alignment = .{ .cross = .center },
    } }, .{
        ui.box(.{
            .style = .{ .width = .{ .fixed = 16 }, .height = .{ .fixed = 16 } },
            .a11y = .{ .role = .button, .label = "History" },
        }, .{}),
    }));
}

test "titleBarInset reaches the next build when the host reports a new one" {
    const app = try testing.allocator.create(InsetApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const before = nodeNamed(&app.window, .button, "History").?.bounds;
    try testing.expectEqual(@as(f32, 0), before.x);
    try testing.expectEqual(@as(f32, 0), before.y);

    app.window.queue.push(.{ .window = .{ .title_bar = .{ .top = 28, .left = 74 } } });
    now += 1;
    app.tick(now);
    const beside = nodeNamed(&app.window, .button, "History").?.bounds;
    try testing.expectEqual(@as(f32, 74), beside.x);
    try testing.expectEqual(@as(f32, 6), beside.y);

    app.window.queue.push(.{ .window = .{ .title_bar = .{} } });
    now += 1;
    app.tick(now);
    const corner = nodeNamed(&app.window, .button, "History").?.bounds;
    try testing.expectEqual(@as(f32, 0), corner.x);
    try testing.expectEqual(@as(f32, 0), corner.y);
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

const MotionPart = enum { tween, tween_on, row, loop, motion };

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
        .loop => if (s.show) {
            s.value = gooey.animation.loop(cx, .{ .name = "spin" }, 400);
        },
        .motion => s.motion = gooey.animation.motion(cx, .{ .name = "panel" }, s.show, .snappy),
    }
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}));
}

fn motionBuild(app: *MotionApp, now_ms: u64) void {
    app.window.render_requested = true;
    app.tick(now_ms * std.time.ns_per_ms);
}

fn motionIdle(app: *MotionApp) bool {
    return app.window.renderDeadlineNs() == null and !app.window.render_requested;
}

test "tweens follow the clock, wait out their delay, replay on return, and then go idle" {
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

test "a loop wraps its phase every period, and draws nothing once it is not built" {
    const ms = std.time.ns_per_ms;
    const app = try testing.allocator.create(MotionApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const s = &app.state;
    s.part = .loop;
    app.tick(1_000 * ms);
    try testing.expectEqual(@as(f32, 0), s.value);
    try testing.expectEqual(@as(?u64, 1_000 * ms), app.window.renderDeadlineNs());
    app.tick(1_100 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s.value, 1e-6);
    try testing.expectEqual(@as(?u64, 1_100 * ms), app.window.renderDeadlineNs());
    app.tick(1_400 * ms - 1);
    try testing.expect(s.value < 1);
    try testing.expect(s.value == 0 or s.value > 0.99);
    app.tick(1_900 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s.value, 1e-6);

    s.show = false;
    s.value = -1;
    motionBuild(app, 2_000);
    try testing.expectEqual(@as(f32, -1), s.value);
    try testing.expect(motionIdle(app));
    const built = app.window.frame_number;
    app.tick(12_000 * ms);
    try testing.expectEqual(built, app.window.frame_number);
    s.show = true;
    motionBuild(app, 13_050);
    try testing.expectEqual(@as(f32, 0), s.value);
    app.tick(13_250 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.value, 1e-6);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "a motion springs in, reverses mid-flight without a snap, and settles hidden" {
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
    const app = try testing.allocator.create(animation.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = std.time.ns_per_s;
    app.tick(now);
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

    animationClick(app, &now, "Start Pulse");
    for (0..120) |_| {
        now += 16 * std.time.ns_per_ms;
        app.tick(now);
        try testing.expectEqual(@as(?u64, now), app.window.renderDeadlineNs());
    }
    animationClick(app, &now, "Stop Pulse");
    try testing.expectEqual(@as(?u64, null), app.window.renderDeadlineNs());
    try testing.expect(nodeNamed(&app.window, .button, "Start Pulse") != null);
    const built = app.window.frame_number;
    app.tick(now + 10 * std.time.ns_per_s);
    try testing.expectEqual(built, app.window.frame_number);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

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
        const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
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

fn formInput(app: *accessible_form.App, now: *u64, event: gooey.input.InputEvent) void {
    app.window.queue.push(.{ .input = event });
    now.* += 1;
    app.tick(now.*);
}

test "accessible_form commits a composition into the field that lost focus" {
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const query = internals.Query{ .window = &app.window };
    var now: u64 = 0;
    app.tick(now);
    const name_field = "Full name, required field";
    const email_field = "Email address, required field";
    formType(app, &now, name_field, "ab");
    const name_id = formNode(app, .textbox, name_field).?.id;
    formInput(app, &now, .{ .composition = .{ .text = "に" } });
    try testing.expectEqual(name_id, query.imeOwner().?);
    try testing.expectEqualStrings("ab", app.state.name);

    formType(app, &now, email_field, "x");
    try testing.expectEqual(formNode(app, .textbox, email_field).?.id, query.imeOwner().?);
    try testing.expectEqualStrings("abに", app.state.name);
    try testing.expectEqualStrings("x", app.state.email);
    const frame = app.window.rendered();
    const name_node = formNode(app, .textbox, name_field).?;
    try testing.expectEqualStrings("abに", frame.text(name_node.value).?);

    formClick(app, &now, .textbox, name_field);
    try testing.expectEqual(name_id, query.imeOwner().?);
    formInput(app, &now, .{ .key_down = chord(.delete, .{}) });
    try testing.expectEqualStrings("ab", app.state.name);
    try testing.expectEqualStrings("x", app.state.email);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "accessible_form validates, announces, and submits on the core" {
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

fn editorWheelTo(app: *code_editor.App, now: *u64, name: []const u8) void {
    const list = nodeNamed(&app.window, .button, "a.zig").?.bounds;
    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
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

    editorWheelTo(app, &now, "Notes.md");
    try testing.expect(nodeNamed(&app.window, .button, "a.zig") == null);
    try testing.expect(editorRowsBuilt(app) < 47);
    editorClickRow(app, &now, "img.png");
    try testing.expectEqual(code_editor.FileStatus.image_file, app.state.status);
    try testing.expectEqualStrings("png", app.state.extension_bytes[0..app.state.extension_len]);
    editorClickRow(app, &now, "line1025.txt");
    try testing.expectEqual(code_editor.FileStatus.line_too_long, app.state.status);
    editorClickRow(app, &now, "line1024.txt");
    try testing.expectEqual(code_editor.FileStatus.displaying_code, app.state.status);
    try testing.expectEqual(@as(usize, 2 + 2 * 1024 + 1), app.state.source.len);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

fn editorLines(dir: std.Io.Dir, name: []const u8, bytes: usize) !void {
    const data = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(data);

    var line: [16]u8 = undefined;
    var offset: usize = 0;
    var index: u32 = 0;
    while (offset < bytes) : (index += 1) {
        _ = try std.fmt.bufPrint(&line, "line {d:0>10}\n", .{index});
        const count = @min(line.len, bytes - offset);
        @memcpy(data[offset..][0..count], line[0..count]);
        offset += count;
    }
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
}

/// The editor's accessibility value, which must be whole lines of `source`
/// within `a11y.value_bytes_max`; returns where it starts in `source`.
fn editorValueStart(app: *code_editor.App) !usize {
    const node = nodeNamed(&app.window, .textarea, "Enter your code here...").?;
    const value = app.window.rendered().text(node.value).?;
    try testing.expect(value.len <= code_editor.limits.a11y.value_bytes_max);
    const start = std.mem.indexOf(u8, app.state.source, value).?;
    try testing.expect(start == 0 or app.state.source[start - 1] == '\n');
    const end = start + value.len;
    try testing.expect(end == app.state.source.len or app.state.source[end - 1] == '\n');
    return start;
}

test "code_editor opens a file of up to its editor's bytes and says the caret's lines" {
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    const frame_text_bytes = code_editor.limits.build.text_bytes_frame_max;
    try editorLines(folder.dir, "over.txt", frame_text_bytes + 1);
    try editorLines(folder.dir, "full.txt", code_editor.limits.text.editor.bytes_max);
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
    const open = nodeNamed(&app.window, .button, "Open Folder").?.bounds;
    clickAt(app, &now, open.x + 4, open.y + 4);
    now += 1;
    app.tick(now);

    editorClickRow(app, &now, "full.txt");
    try testing.expectEqual(code_editor.FileStatus.displaying_code, app.state.status);
    try testing.expectEqual(code_editor.limits.text.editor.bytes_max, app.state.source.len);
    _ = try editorValueStart(app);
    editorClickRow(app, &now, "over.txt");
    try testing.expectEqual(code_editor.FileStatus.displaying_code, app.state.status);
    try testing.expectEqual(@as(usize, frame_text_bytes + 1), app.state.source.len);
    _ = try editorValueStart(app);

    const editor = nodeNamed(&app.window, .textarea, "Enter your code here...").?.bounds;
    clickAt(app, &now, editor.x + editor.width / 2, editor.y + 40);
    app.window.queue.push(.{ .input = .{ .text_input = .{ .text = "@@" } } });
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    const start = try editorValueStart(app);
    const node = nodeNamed(&app.window, .textarea, "Enter your code here...").?;
    const value = app.window.rendered().text(node.value).?;
    const marker = std.mem.indexOf(u8, value, "@@").?;
    try testing.expect(node.state.focused);
    try testing.expectEqual(marker + 2, node.selection.?.start);
    try testing.expectEqual(marker + 2, node.selection.?.end);
    try testing.expectEqual(start + marker, std.mem.indexOf(u8, app.state.source, "@@").?);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

const ChatState = struct {
    heights: [10]f32 = .{ 48, 48, 48, 72, 72, 120, 180, 48, 48, 32 },
};

const ChatRow = struct {
    index: u32,

    pub const count_max: u32 = 1000;

    pub fn height(cx: *Cx, index: u32, _: f32) f32 {
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

fn listWheel(app: anytype, now: *u64, down: f32) void {
    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
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

const SteerRow = struct {
    index: u32,

    pub const count_max: u32 = 1000;

    pub fn height(_: *Cx, index: u32, _: f32) f32 {
        return steer_heights[index % 3];
    }

    pub fn render(self: SteerRow, cx: *Cx) void {
        var label: [16]u8 = undefined;
        cx.render(ui.box(.{
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
            .a11y = .{ .role = .listitem, .label = listRowLabel(&label, self.index) },
        }, .{}));
    }
};

const steer_heights = [_]f32{ 40, 64, 100 };

const SteerState = struct {
    count: u32 = 900,
    row: u32 = 450,
    alignment: ui.ScrollAlignment = .start,

    pub fn go(self: *SteerState, effects: *Effects) void {
        const list = gooey.ElementId.root.child(.{ .name = "rows" });
        components.List(SteerRow).scrollTo(effects, list, self.row, self.alignment);
    }

    pub fn add(self: *SteerState) void {
        self.count += 1;
    }
};

const SteerApp = gooey.App(SteerState, steerRender, .{
    .title = "Steer",
    .width = 300,
    .height = 330,
    .limits = gooey.ResourceLimits.small,
});

fn steerRender(cx: *Cx) void {
    const state = cx.state(SteerState);
    const button: ui.Style = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 30 } };
    cx.render(.{
        ui.box(.{ .style = .{ .direction = .row } }, .{
            ui.box(.{
                .key = .{ .name = "go" },
                .on_click = cx.on(SteerState.go, .{}),
                .style = button,
            }, .{}),
            ui.box(.{
                .key = .{ .name = "add" },
                .on_click = cx.on(SteerState.add, .{}),
                .style = button,
            }, .{}),
        }),
        components.List(SteerRow){
            .key = "rows",
            .count = state.count,
            .gap = 8,
            .anchor = .end,
            .style = .{ .padding = .all(8) },
        },
    });
}

test "a List scrolls to a row and follows its end in the frame that asks" {
    const app = try testing.allocator.create(SteerApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    var rows = listRows(&app.window, 899);
    try testing.expectEqual(@as(f32, 330 - 8), rows.row.?.y + rows.row.?.height);

    clickOnce(app, &now, 75, 15);
    rows = listRows(&app.window, 900);
    try testing.expectEqual(@as(f32, 330 - 8), rows.row.?.y + rows.row.?.height);

    clickOnce(app, &now, 25, 15);
    rows = listRows(&app.window, 450);
    try testing.expectEqual(@as(f32, 30 + 8), rows.row.?.y);
    try testing.expectEqual(@as(f32, 34_200), listOffset(&app.window).offset_y);

    app.state.row = 10;
    app.state.alignment = .center;
    clickOnce(app, &now, 25, 15);
    rows = listRows(&app.window, 10);
    try testing.expectEqual(@as(f32, 144), rows.row.?.y);
    clickOnce(app, &now, 75, 15);
    rows = listRows(&app.window, 10);
    try testing.expectEqual(@as(f32, 144), rows.row.?.y);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "a List of per-row heights builds the rows in view, spaced by its gap and padding" {
    const App = ListApp(ChatRow);
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    now += 1;
    app.tick(now);
    var rows = listRows(&app.window, 3);
    try testing.expectEqual(@as(u32, 5), rows.count);
    try testing.expectEqual(@as(f32, 176), rows.row.?.y);
    try testing.expectEqual(@as(f32, 72), rows.row.?.height);
    try testing.expect(listRows(&app.window, 5).row == null);

    listWheel(app, &now, 500);
    try testing.expectEqual(@as(f32, 500), listOffset(&app.window).offset_y);
    rows = listRows(&app.window, 7);
    try testing.expectEqual(@as(u32, 4), rows.count);
    try testing.expectEqual(@as(f32, 8 + 644 - 500), rows.row.?.y);
    try testing.expectEqual(@as(f32, 48), rows.row.?.height);
    try testing.expect(listRows(&app.window, 5).row == null);
    try testing.expect(listRows(&app.window, 10).row == null);

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
    listWheel(app, &now, 100_000);
    try testing.expectEqual(@as(f32, 1000 * 38 - 8 + 16), listOffset(&app.window).content_height);
}

/// The list's spacers have no width, so they are not counted.
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

test "virtual_list sizes each chat bubble to its measured text, to the last" {
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
    try testing.expect(children.count >= 4);
    try testing.expect(children.count < 20);
    try testing.expectEqual(children.list.y + 8, rows[0].y);
    try expectBubblesFit(&app.window);
    const last = rows[children.count - 1];
    try testing.expect(last.y < children.list.y + children.list.height);

    listWheel(app, &now, 100_000);
    children = listChildren(&app.window, &rows);
    const end = rows[children.count - 1];
    const list_bottom = children.list.y + children.list.height - 8;
    // The offset sums 1,000 measured heights in f32: within a hundredth of a pixel.
    try testing.expectApproxEqAbs(list_bottom, end.y + end.height, 0.01);
    try expectBubblesFit(&app.window);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

fn expectBubblesFit(window: *internals.window.Window) !void {
    const elements = window.layout.elements.items();
    var checked: u32 = 0;
    var wrapped: u32 = 0;
    for (elements) |*element| {
        const text_data = element.text_data orelse continue;
        if (text_data.config.wrap_mode != .words) continue;
        const text_box = element.computed.bounding_box;
        const bubble = elements[element.parent_index.?].computed.bounding_box;
        const text_bottom = text_box.y + text_box.height;
        try testing.expectApproxEqAbs(bubble.y + bubble.height - 8, text_bottom, 0.01);
        checked += 1;
        if (text_data.wrapped_lines.?.len > 1) wrapped += 1;
    }
    try testing.expect(checked >= 3);
    try testing.expect(wrapped >= 1);
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
    const modified = nodeNamed(&app.window, .button, "Modified").?.bounds;
    try testing.expectEqual(children.list.x + children.list.width, modified.x + modified.width);

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
    painter.triangles(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } }, mesh_red);
    painter.triangles(&.{ .{ 20, 0 }, .{ 30, 0 }, .{ 20, 10 } }, mesh_red);
    painter.circle(.{ 100, 100 }, 10, mesh_blue);
    painter.line(.{ 10, 50 }, .{ 90, 50 }, 2, mesh_red);
    painter.line(.{ 0, 0 }, .{ 30, 40 }, 2, mesh_red);
    painter.polyline(&.{ .{ 0, 150 }, .{ 50, 120 }, .{ 100, 160 } }, 2, mesh_blue);
    painter.pointCloud(&.{ .{ 10, 190 }, .{ 20, 190 }, .{ 30, 190 }, .{ 40, 190 } }, 3, mesh_red);
}

test "Painter meshes pack into triangle, polyline, and point meshes" {
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
    const fan = frame.meshPoints(meshes[1].range);
    try testing.expectEqual(@as(f32, 110), fan[0].x);
    try testing.expectEqual(@as(f32, 100), fan[0].y);
    try testing.expectApproxEqAbs(@as(f32, 100 + 10 * @cos(std.math.pi / 6.0)), fan[1].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 105), fan[1].y, 1e-4);

    const packed_frame = &app.window.packed_frame;
    const Pool = internals.packed_frame.Pool;
    try testing.expectEqual(@as(u32, 3), packed_frame.counts[@backingInt(Pool.triangle_meshes)]);
    try testing.expectEqual(@as(u32, 1), packed_frame.counts[@backingInt(Pool.polylines)]);
    try testing.expectEqual(@as(u32, 1), packed_frame.counts[@backingInt(Pool.point_clouds)]);
    try testing.expectEqual(@as(u32, 3), packed_frame.meshList()[3].count);
    try testing.expectEqual(@as(u32, 14), packed_frame.triangle_count);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

test "one polyline and the triangle meshes may fill their whole frame budget" {
    for (&full_line, 0..) |*point, index| {
        const x: f32 = @floatFromInt(index % 200);
        point.* = .{ x, @floatFromInt(index / 200) };
    }
    const app = try testing.allocator.create(FullMeshApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(0);
    const frame = app.window.rendered();
    var triangle_mesh_count: u32 = 0;
    var line_point_count: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record != .mesh) continue;
        switch (record.mesh.topology) {
            .triangles => triangle_mesh_count += 1,
            .strip_expanded => line_point_count += record.mesh.range.count,
            .point_instanced => unreachable,
        }
    }
    const paint = full_mesh_limits.paint;
    try testing.expectEqual(paint.path_count_frame_max, triangle_mesh_count);
    try testing.expectEqual(paint.polyline_point_count_frame_max, line_point_count);
}

var full_line: [full_mesh_limits.paint.polyline_point_count_frame_max][2]f32 = undefined;

const full_mesh_limits = blk: {
    var value = gooey.ResourceLimits.small;
    value.paint.polyline_point_count_frame_max = 16_384;
    value.paint.path_count_frame_max = 512;
    break :blk value;
};

const FullMeshApp = gooey.App(struct {}, fullMeshRender, .{
    .title = "Full meshes",
    .width = 300,
    .height = 300,
    .limits = full_mesh_limits,
});

fn fullMeshRender(cx: *Cx) void {
    const nothing: u8 = 0;
    cx.render(ui.paint(u8, &nothing, fullMeshPaint, .{
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 200 },
    }));
}

fn fullMeshPaint(_: *const u8, painter: *ui.Painter) void {
    painter.polyline(&full_line, 1, mesh_blue);
    var index: u32 = 0;
    while (index < full_mesh_limits.paint.path_count_frame_max) : (index += 1) {
        const color = if (index % 2 == 0) mesh_red else mesh_blue;
        painter.triangles(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } }, color);
    }
}

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
    const app = try testing.allocator.create(lucide.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    // Rasterization is budgeted per frame; settle until every icon is drawn.
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

/// Resize the window to `height` before its first frame, so a test that
/// checks every element's paint sees content a scroll box would cull.
fn showWhole(app: anytype, height: f32) void {
    assert(app.window.frame_number == 0);
    assert(height > app.window.height);
    app.window.queue.push(.{ .window = .{ .resized = .{
        .width = app.window.width,
        .height = height,
        .scale_factor = app.window.scale_factor,
    } } });
}

test "images: one decode lands off the main thread and draws every cell" {
    const app = try testing.allocator.create(images.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var wake = WakeCounter{};
    app.window.images.bindWake(.{ .context = &wake, .wake = WakeCounter.wake });
    defer app.window.images.bindWake(null);
    // Tall enough to show every cell: a cell scrolled out draws nothing.
    showWhole(app, 2_000);
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

    const wide = sprites[3];
    try testing.expectEqual(@as(f32, 80), wide.bounds.width);
    try testing.expectEqual(@as(f32, 80), wide.bounds.height);
    const none = sprites[7];
    try testing.expectEqual(@as(f32, 100), none.bounds.width);
    const full_uv = sprites[4].uv.width;
    try testing.expectApproxEqAbs(full_uv * 100.0 / 512.0, none.uv.width, 1e-5);
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
    const App = dashboard.App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 2 });
    defer app.deinitHeadless();
    // Tall enough to show every chart: a chart scrolled out draws nothing.
    showWhole(app, 2_000);
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
    try testing.expect(triangle_meshes >= 1 + 3 + 5 + 2 + 3);
    try checkRevenueArea(frame);

    try testing.expectEqual(ui.Color.hex(0x0f172a), rootFill(&app.window));
    app.window.queue.push(.{ .input = .{ .key_down = chord(.t, .{}) } });
    app.tick(1);
    try testing.expect(!app.state.is_dark_theme);
    try testing.expectEqual(ui.Color.hex(0xf1f5f9), rootFill(&app.window));
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

fn isRevenueArea(fill: ui.Color) bool {
    const line = ui.Color.hex(0x06b6d4);
    return @abs(fill.a - 0.3) < 0.001 and @abs(fill.r - line.r) < 0.001 and
        @abs(fill.b - line.b) < 0.001;
}

/// The revenue area must be triangles that tile the region under its line
/// exactly once: abutting quads left anti-aliased seams (vertical stripes),
/// and overlapping triangles would blend twice. Methodology: no quad has the
/// area's colour, and the area's triangles sum to the trapezoids between the
/// revenue polyline (the frame's first) and the baseline, the area's lowest
/// point, worked out from the polyline's own points.
fn checkRevenueArea(frame: *const internals.records.Frame) !void {
    var line: ?[]const internals.records.MeshPoint = null;
    var area_triangles: f32 = 0;
    var baseline: f32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record == .quad) try testing.expect(!isRevenueArea(record.quad.fill));
        if (record != .mesh) continue;
        const points = frame.meshPoints(record.mesh.range);
        if (record.mesh.topology == .strip_expanded and line == null) line = points;
        if (record.mesh.topology != .triangles or !isRevenueArea(record.mesh.fill)) continue;
        var index: usize = 0;
        while (index < points.len) : (index += 3) {
            const a = points[index];
            const b = points[index + 1];
            const c = points[index + 2];
            area_triangles += @abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2;
            baseline = @max(baseline, @max(a.y, @max(b.y, c.y)));
        }
    }
    try testing.expectEqual(@as(usize, 12), line.?.len);
    var area_line: f32 = 0;
    for (line.?[0 .. line.?.len - 1], line.?[1..]) |from, to| {
        area_line += (to.x - from.x) * ((baseline - from.y) + (baseline - to.y)) / 2;
    }
    try testing.expect(area_line > 0);
    try testing.expectApproxEqRel(area_line, area_triangles, 0.0001);
}

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

/// Fill the frame to exactly its declared glyphs, then quads, then records, all
/// in view so none is culled when packed.
fn fullPaint(_: *const u8, painter: *ui.Painter) void {
    const paint_limits = full_limits.paint;
    const frame = internals.emit.targetOf(painter).window.built();
    const line: [64]u8 = @splat('x');
    var row: u32 = 0;
    while (paintCounts(frame).glyphs < paint_limits.glyph_count_frame_max) : (row += 1) {
        assert(row < 64);
        const left = paint_limits.glyph_count_frame_max - paintCounts(frame).glyphs;
        const y: f32 = @floatFromInt(8 + row * 8);
        _ = painter.text(line[0..@min(left, line.len)], 8, y, .{ .size = 6, .color = .black });
    }
    assert(paintCounts(frame).glyphs == paint_limits.glyph_count_frame_max);
    var quad: u32 = paintCounts(frame).quads;
    while (quad < paint_limits.quad_count_frame_max) : (quad += 1) {
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
    if (!internals.debugger.enabled) return error.SkipZigTest;
    const app = try testing.allocator.create(FullApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const counts = &app.window.packed_frame.counts;
    const quads = &counts[@backingInt(internals.packed_frame.Pool.quads)];
    const glyphs = &counts[@backingInt(internals.packed_frame.Pool.glyphs)];
    const paint_limits = full_limits.paint;
    const app_counts = paintCounts(app.window.rendered());
    try testing.expectEqual(full_limits.records.paint_record_count_frame_max, app_counts.records);
    try testing.expectEqual(paint_limits.quad_count_frame_max, app_counts.quads);
    try testing.expectEqual(paint_limits.quad_count_frame_max, quads.*);
    try testing.expectEqual(paint_limits.glyph_count_frame_max, glyphs.*);

    const toggle = gooey.input.InputEvent{ .key_down = chord(.i, .{ .cmd = true, .shift = true }) };
    scrollMouse(app, &now, toggle);
    scrollMouse(app, &now, .{ .mouse_moved = mouse(100, 100) });
    clickAt(app, &now, 100, 100);
    try testing.expectEqual(.inspector, app.window.debugger.mode);
    try testing.expect(app.window.debugger.info != null);
    const inspected = paintCounts(app.window.rendered());
    try testing.expect(inspected.records > app_counts.records);
    try testing.expect(quads.* > paint_limits.quad_count_frame_max);
    try testing.expect(glyphs.* > paint_limits.glyph_count_frame_max);

    scrollMouse(app, &now, toggle);
    try testing.expectEqual(.profiler, app.window.debugger.mode);
    const profiled = paintCounts(app.window.rendered());
    try testing.expect(profiled.quads >= app_counts.quads + 4);
    try testing.expect(glyphs.* > paint_limits.glyph_count_frame_max);
}

fn todoButton(app: *todo.App, name: []const u8) ?gooey.ui.Rect {
    const node = nodeNamed(&app.window, .button, name) orelse return null;
    return node.bounds;
}

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

test "todo acts on a todo's id and cuts a draft on a codepoint boundary" {
    var state = todo.State{};
    for ([_][]const u8{ "a", "b", "c" }) |text| {
        state.draft = text;
        state.addTodo();
    }
    const b = state.todos[1].id;
    state.remove(b);
    state.remove(b);
    state.toggle(b);
    try testing.expectEqual(@as(u32, 2), state.count);
    try testing.expectEqualStrings("c", state.todos[1].bytes[0..state.todos[1].len]);
    try testing.expect(!state.todos[1].done);

    const a127: [127]u8 = @splat('a');
    const a126: [126]u8 = @splat('a');
    state.draft = a127 ++ "\u{e9}";
    state.addTodo();
    try testing.expectEqual(@as(u32, 127), state.todos[2].len);
    state.draft = a126 ++ "\u{e9}";
    state.addTodo();
    const cut = state.todos[3].bytes[0..state.todos[3].len];
    try testing.expectEqual(@as(usize, 128), cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "a handler that clears a bound draft gets the next edit on the empty text" {
    const app = try testing.allocator.create(todo.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const input = nodeNamed(&app.window, .textbox, "What needs doing?").?.bounds;
    clickOnce(app, &now, input.x + 4, input.y + input.height / 2);
    app.window.queue.push(.{ .input = .{ .text_input = .{ .text = "abc" } } });
    now += 1;
    app.tick(now);
    try testing.expectEqualStrings("abc", app.state.draft);

    const add = todoButton(app, "Add").?;
    const center = mouse(add.x + add.width / 2, add.y + add.height / 2);
    app.window.queue.push(.{ .input = .{ .mouse_down = center } });
    app.window.queue.push(.{ .input = .{ .mouse_up = center } });
    const field = mouse(input.x + 4, input.y + input.height / 2);
    app.window.queue.push(.{ .input = .{ .mouse_down = field } });
    app.window.queue.push(.{ .input = .{ .mouse_up = field } });
    app.window.queue.push(.{ .input = .{ .text_input = .{ .text = "x" } } });
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(u32, 1), app.state.count);
    try testing.expect(nodeNamed(&app.window, .checkbox, "abc") != null);
    try testing.expectEqualStrings("x", app.state.draft);
}

test "todo keeps its header, footer, and Add in view at 20 items and narrow widths" {
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
    // Offsets follow the delta, inverted by `window.wheel_delta_inverted`.
    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
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
    const delete = todoButton(app, "Delete").?;
    try testing.expect(delete.x + delete.width <= 360 - 24);
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

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

    formClick(app, &now, .button, "Reset form to default values");
    try expectFocused(&app.window, .button, "Reset form to default values");
    try testing.expectEqual(@as(u32, 0), focusRings(&app.window, &ring));
}

test "Enter and Space click the focused control once per press" {
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

    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
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

test "focus revealed at a scroll box's end settles instead of trading an ulp" {
    const app = try testing.allocator.create(todo.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const row_count: u32 = 6;
    for (0..row_count) |_| {
        app.state.draft = "a todo";
        app.state.addTodo();
    }
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    for (0..5 + row_count * 2) |_| pressKey(app, &now, .tab, .{});
    const focused = focusedNode(&app.window).?;
    try testing.expectEqual(.button, focused.role);
    const settle_frame_max: u32 = 4;
    var frame: u32 = 0;
    while (frame < settle_frame_max and app.window.render_requested) : (frame += 1) {
        now += 1;
        app.tick(now);
    }
    try testing.expect(!app.window.render_requested);
    const delete = focusedNode(&app.window).?.bounds;
    try expectRingAround(&app.window, delete);
}

fn todoListScroll(app: *todo.App) *internals.window.ScrollState {
    const frame = app.window.rendered();
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (!record.scroll) continue;
        return app.window.retained.find(internals.window.ScrollState, record.id).?;
    }
    unreachable;
}

test "a scroll box scrolled to its end clamps to shrunk content in one frame" {
    const app = try testing.allocator.create(todo.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    for (0..30) |_| {
        app.state.draft = "a todo";
        app.state.addTodo();
    }
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    const direction: f32 = if (internals.window.wheel_delta_inverted) -1 else 1;
    app.window.queue.push(.{ .input = .{ .scroll = .{
        .position = .{ .x = 100, .y = 300 },
        .delta = .{ .x = 0, .y = 5000 * direction },
        .modifiers = .{},
    } } });
    now += 1;
    app.tick(now);
    const scroll = todoListScroll(app);
    try testing.expect(scroll.offset_y > 1000);
    try testing.expect(scroll.at_end);

    while (app.state.count > 8) app.state.remove(app.state.todos[0].id);
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    const content_height: f32 = 8 * 48.8 + 7 * 8;
    try testing.expectApproxEqAbs(content_height, scroll.content_height, 0.01);
    const offset_max = content_height - scroll.viewport.height;
    try testing.expectApproxEqAbs(offset_max, scroll.offset_y, 0.01);
    // Laid out at the new offset, the content may measure an ulp shorter,
    // and the clamp moves down that ulp once; then nothing is requested.
    const settle_frame_max: u32 = 2;
    var frame: u32 = 0;
    while (frame < settle_frame_max and app.window.render_requested) : (frame += 1) {
        now += 1;
        app.tick(now);
    }
    try testing.expect(!app.window.render_requested);
    try testing.expectApproxEqAbs(offset_max, scroll.offset_y, 0.01);
}

test "a radio group is one tab stop whose arrow keys select and wrap" {
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
    try testing.expect(!formNode(app, .combobox, "Experience level").?.state.expanded);
    try expectFocused(&app.window, .checkbox, "Subscribe to newsletter");
    try testing.expectEqual(@as(?usize, null), app.state.experience_level);
}

const reset_tooltip = "Clears every field and choice";

fn formHover(app: *accessible_form.App, now: *u64, x: f32, y: f32) void {
    app.window.queue.push(.{ .input = .{ .mouse_moved = mouse(x, y) } });
    now.* += 1;
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

fn formWait(app: *accessible_form.App, now: *u64, ms: u64) void {
    now.* += ms * std.time.ns_per_ms;
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

test "a Tooltip shows after the hover delay and hides when the pointer leaves" {
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const button = formReveal(app, &now, .button, "Reset form to default values");
    try testing.expect(formNode(app, .tooltip, reset_tooltip) == null);
    formHover(app, &now, button.x + button.width / 2, button.y + button.height / 2);
    try testing.expect(formNode(app, .tooltip, reset_tooltip) == null);
    formWait(app, &now, 490);
    try testing.expect(formNode(app, .tooltip, reset_tooltip) == null);
    formWait(app, &now, 10);
    const tooltip = formNode(app, .tooltip, reset_tooltip) orelse return error.NoTooltip;
    const below = tooltip.bounds.y >= button.y + button.height;
    const above = tooltip.bounds.y + tooltip.bounds.height <= button.y;
    try testing.expect(below or above);
    formHover(
        app,
        &now,
        tooltip.bounds.x + tooltip.bounds.width / 2,
        tooltip.bounds.y + tooltip.bounds.height / 2,
    );
    try testing.expect(formNode(app, .tooltip, reset_tooltip) == null);
}

test "a Tooltip shows at once for keyboard focus, and Escape hides it" {
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    for (0..9) |_| pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .button, "Reset form to default values");
    try testing.expect(formNode(app, .tooltip, reset_tooltip) != null);
    pressKey(app, &now, .escape, .{});
    try expectFocused(&app.window, .button, "Reset form to default values");
    try testing.expect(formNode(app, .tooltip, reset_tooltip) == null);
    pressKey(app, &now, .tab, .{ .shift = true });
    try expectFocused(&app.window, .button, "Submit registration form");
    try testing.expect(formNode(app, .tooltip, reset_tooltip) == null);
    pressKey(app, &now, .tab, .{});
    try testing.expect(formNode(app, .tooltip, reset_tooltip) != null);

    formClick(app, &now, .button, "Reset form to default values");
    formHover(app, &now, 5, 5);
    try expectFocused(&app.window, .button, "Reset form to default values");
    try testing.expect(formNode(app, .tooltip, reset_tooltip) == null);
}

fn selectedOptions(window: *internals.window.Window) u32 {
    const frame = window.rendered();
    var count: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role == .option and node.state.selected) count += 1;
    }
    return count;
}

test "a Select near the window's bottom opens its menu above, clear of the combobox" {
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    for (0..6) |_| pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .combobox, "Experience level");
    pressKey(app, &now, .down, .{});
    try expectFocused(&app.window, .option, "Beginner");
    const combobox = formNode(app, .combobox, "Experience level").?.bounds;
    const menu = formNode(app, .listbox, "Experience level").?.bounds;
    try testing.expect(combobox.y + combobox.height + menu.height > 800);
    try testing.expect(menu.y >= 0);
    try testing.expect(menu.y + menu.height <= combobox.y);
}

test "a Select opens, moves, and chooses from the keyboard" {
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
    try testing.expect(comboboxState(app).expanded);
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
    try testing.expect(!comboboxState(app).expanded);
    try expectFocused(&app.window, .combobox, "Level");

    // Reopening starts on the chosen option, which alone is selected for
    // the screen reader; Esc closes without choosing.
    pressKey(app, &now, .space, .{});
    try testing.expect(comboboxState(app).expanded);
    try expectFocused(&app.window, .option, "Three");
    try testing.expectEqual(@as(u32, 1), selectedOptions(&app.window));
    try testing.expect(focusedNode(&app.window).?.state.selected);
    pressKey(app, &now, .up, .{});
    try testing.expect(!focusedNode(&app.window).?.state.selected);
    pressKey(app, &now, .down, .{});
    pressKey(app, &now, .escape, .{});
    try testing.expect(!comboboxState(app).expanded);
    try testing.expectEqual(@as(?usize, 2), app.state.selected);
    try expectFocused(&app.window, .combobox, "Level");

    pressKey(app, &now, .@"return", .{});
    pressKey(app, &now, .up, .{});
    pressKey(app, &now, .space, .{});
    try testing.expectEqual(@as(?usize, 1), app.state.selected);
    try testing.expect(!comboboxState(app).expanded);
}

test "Tab from a Select's menu closes it and moves on, and a click opens it on the combobox" {
    const app = try testing.allocator.create(SelectApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    var ring: internals.records.Rect = undefined;
    pressKey(app, &now, .tab, .{});
    pressKey(app, &now, .down, .{});
    try testing.expect(comboboxState(app).expanded);
    pressKey(app, &now, .tab, .{});
    try testing.expect(!comboboxState(app).expanded);
    try expectFocused(&app.window, .button, "Below");
    try expectRingAround(&app.window, focusedNode(&app.window).?.bounds);
    pressKey(app, &now, .tab, .{ .shift = true });
    try expectFocused(&app.window, .combobox, "Level");
    pressKey(app, &now, .space, .{});
    try expectFocused(&app.window, .option, "One");
    pressKey(app, &now, .tab, .{ .shift = true });
    try testing.expect(!comboboxState(app).expanded);
    try expectFocused(&app.window, .button, "Below");
    try testing.expectEqual(@as(u32, 0), app.state.below_clicks);
    try testing.expectEqual(@as(?usize, null), app.state.selected);

    clickAt(app, &now, 20, 20);
    try testing.expect(comboboxState(app).expanded);
    try expectFocused(&app.window, .combobox, "Level");
    try testing.expectEqual(@as(u32, 0), focusRings(&app.window, &ring));
    pressKey(app, &now, .@"return", .{});
    try testing.expect(!comboboxState(app).expanded);
    try testing.expectEqual(@as(?usize, null), app.state.selected);
    try testing.expectEqual(@as(u32, 0), app.state.below_clicks);
}

test "keys drained together after a Select choice leave its menu closed" {
    const app = try testing.allocator.create(accessible_form.App);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    for (0..6) |_| pressKey(app, &now, .tab, .{});
    pressKey(app, &now, .down, .{});
    pressKey(app, &now, .down, .{});
    try expectFocused(&app.window, .option, "Intermediate");
    const keys = [_]gooey.input.KeyCode{ .@"return", .tab, .tab, .@"return" };
    for (keys) |key| app.window.queue.push(.{ .input = .{ .key_down = chord(key, .{}) } });
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(?usize, 1), app.state.experience_level);
    try testing.expect(!formNode(app, .combobox, "Experience level").?.state.expanded);
    try testing.expect(formNode(app, .listbox, "Experience level") == null);
    try expectFocused(&app.window, .button, "Submit registration form");
    try testing.expect(app.state.validation_errors.name);
}

test "focus on an element that leaves passes to its combobox or the next tab stop" {
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
    for (0..10) |_| pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .checkbox, "c");
    pressKey(app, &now, .tab, .{});
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

const StyleState = struct {
    pointer_events: @FieldType(ui.Style, "pointer_events") = .none,
    below_clicks: u32 = 0,
    overlay_clicks: u32 = 0,
    child_clicks: u32 = 0,

    pub fn below(self: *StyleState) void {
        self.below_clicks += 1;
    }

    pub fn overlay(self: *StyleState) void {
        self.overlay_clicks += 1;
    }

    pub fn child(self: *StyleState) void {
        self.child_clicks += 1;
    }
};

const style_config: gooey.Config(StyleState) = .{
    .title = "Style",
    .width = 500,
    .height = 300,
    .limits = .nano,
};

fn rgba(r: f32, g: f32, b: f32, a: f32) ui.ColorToken {
    return .{ .rgba = .{ .r = r, .g = g, .b = b, .a = a } };
}

fn fixedSquare(side: f32) ui.Style {
    return .{ .width = .{ .fixed = side }, .height = .{ .fixed = side } };
}

const OpacityApp = gooey.App(StyleState, opacityRender, style_config);

fn opacityRender(cx: *Cx) void {
    const state = cx.state(StyleState);
    var control = fixedSquare(40);
    control.background = rgba(0, 0, 1, 1);
    var faded = fixedSquare(60);
    faded.background = rgba(1, 0, 0, 1);
    faded.border = .{ .width = 2, .color = rgba(0, 0, 0, 0.8) };
    faded.opacity = 0.5;
    var nested = fixedSquare(10);
    nested.background = rgba(0, 1, 0, 1);
    nested.opacity = 0.5;
    var painted = fixedSquare(40);
    painted.opacity = 0.5;
    cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 10 } }, .{
        ui.box(.{ .style = control }, .{}),
        ui.box(.{ .style = faded }, .{
            ui.box(.{ .style = nested }, .{}),
            ui.text("A", .{ .color = rgba(0, 0, 0, 1) }),
        }),
        ui.paint(StyleState, state, paintTwoTriangles, painted),
    }));
}

fn paintTwoTriangles(_: *const StyleState, painter: *gooey.Painter) void {
    const b = painter.bounds;
    const color = gooey.Color{ .r = 1, .g = 0, .b = 1, .a = 1 };
    painter.triangles(&.{ .{ b.x, b.y }, .{ b.x + 10, b.y }, .{ b.x, b.y + 10 } }, color);
    painter.triangles(&.{ .{ b.x, b.y + 20 }, .{ b.x + 10, b.y + 20 }, .{ b.x, b.y + 30 } }, color);
}

test "Style.opacity fades every record its subtree draws, nested opacities multiply" {
    const app = try testing.allocator.create(OpacityApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(0);
    const frame = app.window.rendered();
    var seen = struct { control: u32 = 0, faded: u32 = 0, nested: u32 = 0, glyphs: u32 = 0 }{};
    var meshes: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        switch (record) {
            .quad => |quad| {
                if (quad.fill.b == 1 and quad.fill.r == 0) {
                    try testing.expectEqual(@as(f32, 1), quad.fill.a);
                    seen.control += 1;
                } else if (quad.fill.r == 1) {
                    try testing.expectEqual(@as(f32, 0.5), quad.fill.a);
                    try testing.expectEqual(@as(f32, 0.4), quad.border.color.a);
                    seen.faded += 1;
                } else if (quad.fill.g == 1) {
                    try testing.expectEqual(@as(f32, 0.25), quad.fill.a);
                    seen.nested += 1;
                }
            },
            .sprite => |sprite| {
                try testing.expectEqual(internals.records.AtlasKind.glyph, sprite.atlas);
                try testing.expectEqual(@as(f32, 0.5), sprite.tint.a);
                seen.glyphs += 1;
            },
            .mesh => |mesh| {
                try testing.expectEqual(@as(f32, 0.5), mesh.fill.a);
                try testing.expectEqual(@as(u32, 6), mesh.range.count);
                meshes += 1;
            },
            .clip_push, .clip_pop => {},
        }
    }
    try testing.expectEqual(@as(u32, 1), seen.control);
    try testing.expectEqual(@as(u32, 1), seen.faded);
    try testing.expectEqual(@as(u32, 1), seen.nested);
    try testing.expectEqual(@as(u32, 1), seen.glyphs);
    try testing.expectEqual(@as(u32, 1), meshes);
}

const GrowApp = gooey.App(StyleState, growRender, style_config);

fn growRender(cx: *Cx) void {
    const row: ui.Style = .{
        .direction = .row,
        .width = .{ .fixed = 430 },
        .height = .{ .fixed = 50 },
        .gap = 15,
    };
    const column: ui.Style = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 90 } };
    cx.render(ui.box(.{}, .{
        ui.box(.{ .style = row }, .{
            ui.box(.{ .key = .{ .name = "fixed" }, .style = .{
                .width = .{ .fixed = 100 },
                .height = .{ .grow = 1 },
            } }, .{}),
            ui.box(.{ .key = .{ .name = "one" }, .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 3 },
            } }, .{}),
            ui.box(.{ .key = .{ .name = "two" }, .style = .{
                .width = .{ .grow = 2 },
                .height = .{ .grow = 1 },
            } }, .{}),
        }),
        ui.box(.{ .style = column }, .{
            ui.box(.{ .key = .{ .name = "top" }, .style = .{ .height = .{ .grow = 2 } } }, .{}),
            ui.box(.{ .key = .{ .name = "bottom" }, .style = .{ .height = .{ .grow = 1 } } }, .{}),
        }),
    }));
}

test "grow siblings share free space by weight on the main axis only" {
    const app = try testing.allocator.create(GrowApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(0);
    const frame = app.window.rendered();
    try testing.expectEqual(@as(u32, 5), frame.hit_count);
    const hits = frame.hits[0..5];
    const expected_x = [3]f32{ 0, 115, 230 };
    const expected_width = [3]f32{ 100, 100, 200 };
    for (hits[0..3], expected_x, expected_width) |*record, x, width| {
        try testing.expectEqual(x, record.bounds.x);
        try testing.expectEqual(width, record.bounds.width);
        try testing.expectEqual(@as(f32, 50), record.bounds.height);
    }
    try testing.expectEqual(@as(f32, 60), hits[3].bounds.height);
    try testing.expectEqual(@as(f32, 30), hits[4].bounds.height);
    try testing.expectEqual(hits[3].bounds.y + 60, hits[4].bounds.y);
}

const FlexWrapApp = gooey.App(StyleState, flexWrapRender, style_config);

fn flexWrapRender(cx: *Cx) void {
    const tile: ui.Style = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 20 } };
    const names = [4][]const u8{ "a", "b", "c", "d" };
    cx.render(ui.box(.{ .style = .{ .width = .{ .fixed = 230 } } }, .{
        ui.box(.{ .style = .{
            .direction = .row,
            .wrap = true,
            .width = .{ .grow = 1 },
            .gap = 10,
            .alignment = .{ .main = .center },
        } }, .{
            ui.box(.{ .key = .{ .name = names[0] }, .style = tile }, .{}),
            ui.box(.{ .key = .{ .name = names[1] }, .style = tile }, .{}),
            ui.box(.{ .key = .{ .name = names[2] }, .style = tile }, .{}),
            ui.box(.{ .key = .{ .name = names[3] }, .style = tile }, .{}),
        }),
        ui.box(.{ .key = .{ .name = "picture" }, .style = .{
            .width = .{ .grow = 1 },
            .aspect_ratio = 2,
        } }, .{}),
        ui.box(.{ .key = .{ .name = "after" }, .style = tile }, .{}),
    }));
}

test "Style.wrap breaks a row into lines and Style.aspect_ratio derives a height" {
    const app = try testing.allocator.create(FlexWrapApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(0);
    const frame = app.window.rendered();
    try testing.expectEqual(@as(u32, 6), frame.hit_count);
    const hits = frame.hits[0..6];
    const expected = [4][2]f32{ .{ 10, 0 }, .{ 120, 0 }, .{ 10, 30 }, .{ 120, 30 } };
    for (hits[0..4], expected) |*record, position| {
        try testing.expectEqual(position[0], record.bounds.x);
        try testing.expectEqual(position[1], record.bounds.y);
    }
    try testing.expectEqual(@as(f32, 230), hits[4].bounds.width);
    try testing.expectEqual(@as(f32, 115), hits[4].bounds.height);
    try testing.expectEqual(@as(f32, 165), hits[5].bounds.y);
}

const PointerApp = gooey.App(StyleState, pointerRender, style_config);

fn pointerRender(cx: *Cx) void {
    const state = cx.state(StyleState);
    var below = fixedSquare(100);
    below.cursor = .pointer;
    var overlay = fixedSquare(100);
    overlay.cursor = .text;
    overlay.pointer_events = state.pointer_events;
    cx.render(ui.box(.{ .style = .{ .padding = .all(20) } }, .{
        ui.box(.{
            .key = .{ .name = "below" },
            .on_click = cx.on(StyleState.below, .{}),
            .style = below,
        }, .{}),
        ui.box(.{
            .key = .{ .name = "overlay" },
            .focusable = true,
            .on_click = cx.on(StyleState.overlay, .{}),
            .layer = .{
                .kind = .popover,
                .anchor = .{ .window = .{ .x = 20, .y = 20 } },
                .clip = .escape,
            },
            .style = overlay,
        }, .{
            ui.box(.{
                .key = .{ .name = "child" },
                .on_click = cx.on(StyleState.child, .{}),
                .style = fixedSquare(20),
            }, .{}),
        }),
    }));
}

test "pointer_events none passes the pointer to the box below but keeps its keys" {
    const app = try testing.allocator.create(PointerApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const frame = app.window.rendered();
    try testing.expectEqual(@as(u32, 3), frame.hit_count);
    const below_id = frame.hits[0].id;
    const overlay_id = frame.hits[1].id;
    try testing.expect(!frame.hits[1].pointer);
    try testing.expectEqual(frame.hits[0].bounds, frame.hits[1].bounds);

    const query = internals.Query{ .window = &app.window };
    try testing.expectEqual(@as(?gooey.ElementId, below_id), query.hitTest(.{ .x = 70, .y = 70 }));
    clickAt(app, &now, 70, 70);
    try testing.expectEqual(@as(u32, 1), app.state.below_clicks);
    try testing.expectEqual(@as(u32, 0), app.state.overlay_clicks);
    app.window.queue.push(.{ .input = .{ .mouse_moved = mouse(70, 70) } });
    now += 1;
    app.tick(now);
    try testing.expectEqual(CursorShape.pointer, app.window.cursor);

    clickAt(app, &now, 30, 30);
    try testing.expectEqual(@as(u32, 1), app.state.child_clicks);
    try testing.expectEqual(@as(u32, 1), app.state.overlay_clicks);
    try testing.expectEqual(@as(u32, 1), app.state.below_clicks);

    pressKey(app, &now, .tab, .{});
    try testing.expectEqual(overlay_id, app.window.focus);

    app.state.pointer_events = .auto;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    const hit = query.hitTest(.{ .x = 70, .y = 70 });
    try testing.expectEqual(@as(?gooey.ElementId, overlay_id), hit);
    clickAt(app, &now, 70, 70);
    try testing.expectEqual(@as(u32, 2), app.state.overlay_clicks);
    try testing.expectEqual(@as(u32, 1), app.state.below_clicks);
    try testing.expectEqual(CursorShape.text, app.window.cursor);
}

const SplitterApp = splitter.App;
const sidebar_splitter_id = gooey.ElementId.root.child(.{ .name = "panes" })
    .child(.{ .name = "sidebar splitter" });
const top_splitter_id = gooey.ElementId.root.child(.{ .name = "panes" })
    .child(.{ .name = "content" }).child(.{ .name = "top splitter" });

fn recordBounds(app: anytype, id: gooey.ElementId) internals.records.Rect {
    const frame = app.window.rendered();
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.id == id) return record.bounds;
    }
    unreachable;
}

fn dragged(x: f32, y: f32) gooey.input.InputEvent {
    return .{ .mouse_dragged = mouse(x, y) };
}

test "splitter: the sidebar follows a drag from its press, clamped, outside the window too" {
    const app = try testing.allocator.create(SplitterApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const bar = recordBounds(app, sidebar_splitter_id);
    try testing.expectEqual(@as(f32, 240), bar.x);
    try testing.expectEqual(splitter.splitter_size, bar.width);
    const y = bar.y + bar.height / 2;

    scrollMouse(app, &now, .{ .mouse_moved = mouse(243, y) });
    try testing.expectEqual(CursorShape.resize_left_right, app.window.cursor);
    scrollMouse(app, &now, .{ .mouse_down = mouse(243, y) });
    try testing.expectEqual(sidebar_splitter_id, app.window.capture.id);
    scrollMouse(app, &now, dragged(273, y));
    try testing.expectEqual(@as(f32, 270), app.state.sidebar_width);
    try testing.expectEqual(@as(f32, 270), recordBounds(app, sidebar_splitter_id).x);
    scrollMouse(app, &now, dragged(-500, y));
    try testing.expectEqual(splitter.sidebar_width_min, app.state.sidebar_width);
    try testing.expectEqual(CursorShape.resize_left_right, app.window.cursor);
    scrollMouse(app, &now, dragged(2000, y));
    try testing.expectEqual(splitter.sidebar_width_max, app.state.sidebar_width);
    scrollMouse(app, &now, dragged(273, y));
    scrollMouse(app, &now, .{ .mouse_up = mouse(273, y) });
    try testing.expectEqual(@as(f32, 270), app.state.sidebar_width);
    try testing.expectEqual(gooey.ElementId.root, app.window.capture.id);
    try testing.expectEqual(CursorShape.resize_left_right, app.window.cursor);
    // AppKit delivers the first move after a drag that left the window as an
    // entry, not a move: it must resolve the cursor all the same.
    scrollMouse(app, &now, .{ .mouse_entered = mouse(600, y) });
    try testing.expectEqual(CursorShape.default, app.window.cursor);
    scrollMouse(app, &now, dragged(700, y));
    try testing.expectEqual(@as(f32, 270), app.state.sidebar_width);
    var right = mouse(273, y);
    right.button = .right;
    scrollMouse(app, &now, .{ .mouse_down = right });
    right.position.x = 400;
    scrollMouse(app, &now, .{ .mouse_dragged = right });
    scrollMouse(app, &now, .{ .mouse_up = right });
    try testing.expectEqual(@as(f32, 270), app.state.sidebar_width);
}

test "splitter: Escape and a lost gesture restore the width the press began with" {
    const app = try testing.allocator.create(SplitterApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const y: f32 = 300;

    scrollMouse(app, &now, .{ .mouse_down = mouse(243, y) });
    scrollMouse(app, &now, dragged(293, y));
    try testing.expectEqual(@as(f32, 290), app.state.sidebar_width);
    pressKey(app, &now, .escape, .{});
    try testing.expectEqual(@as(f32, 240), app.state.sidebar_width);
    try testing.expectEqual(gooey.ElementId.root, app.window.capture.id);
    scrollMouse(app, &now, dragged(320, y));
    scrollMouse(app, &now, .{ .mouse_up = mouse(320, y) });
    try testing.expectEqual(@as(f32, 240), app.state.sidebar_width);

    scrollMouse(app, &now, .{ .mouse_down = mouse(243, y) });
    scrollMouse(app, &now, dragged(293, y));
    scrollMouse(app, &now, .pointer_cancelled);
    try testing.expectEqual(@as(f32, 240), app.state.sidebar_width);
    try testing.expectEqual(gooey.ElementId.root, app.window.capture.id);
}

test "splitter: arrow keys move a focused splitter, which reports its range" {
    const app = try testing.allocator.create(SplitterApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    pressKey(app, &now, .tab, .{});
    try testing.expectEqual(sidebar_splitter_id, app.window.focus);
    pressKey(app, &now, .right, .{});
    try testing.expectEqual(@as(f32, 256), app.state.sidebar_width);
    pressKey(app, &now, .right, .{ .shift = true });
    try testing.expectEqual(@as(f32, 320), app.state.sidebar_width);
    pressKey(app, &now, .home, .{});
    try testing.expectEqual(splitter.sidebar_width_min, app.state.sidebar_width);
    pressKey(app, &now, .end, .{});
    try testing.expectEqual(splitter.sidebar_width_max, app.state.sidebar_width);

    const frame = app.window.rendered();
    var found = false;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.id != sidebar_splitter_id) continue;
        found = true;
        try testing.expectEqual(gooey.ui.Role.separator, node.role);
        try testing.expectEqual(splitter.sidebar_width_min, node.range.?.min);
        try testing.expectEqual(splitter.sidebar_width_max, node.range.?.now);
        try testing.expectEqual(gooey.ui.Orientation.vertical, node.range.?.orientation);
        try testing.expect(node.state.focused);
    }
    try testing.expect(found);
}

test "splitter: the top pane's share follows a drag through effects.bounds" {
    const app = try testing.allocator.create(SplitterApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const bar = recordBounds(app, top_splitter_id);
    try testing.expectApproxEqAbs(@as(f32, 356.4), bar.y, 0.01);
    const x = bar.x + 100;
    const y = bar.y + 3;
    scrollMouse(app, &now, .{ .mouse_down = mouse(x, y) });
    scrollMouse(app, &now, dragged(x, y + 59.4));
    scrollMouse(app, &now, .{ .mouse_up = mouse(x, y + 59.4) });
    try testing.expectApproxEqAbs(@as(f32, 0.7), app.state.top_share, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 415.8), recordBounds(app, top_splitter_id).y, 0.01);
}

const CaptureState = struct {
    shown: bool = true,
    phases: [8]gooey.Effects.PointerDrag.Phase = undefined,
    phase_count: u32 = 0,
    box_clicks: u32 = 0,
    button_clicks: u32 = 0,

    pub fn drag(self: *CaptureState, effects: *Effects) void {
        assert(self.phase_count < self.phases.len);
        self.phases[self.phase_count] = effects.pointerDrag().?.phase;
        self.phase_count += 1;
    }

    pub fn clickBox(self: *CaptureState) void {
        self.box_clicks += 1;
    }

    pub fn clickButton(self: *CaptureState) void {
        self.button_clicks += 1;
    }

    fn expectPhases(self: *CaptureState, expected: []const gooey.Effects.PointerDrag.Phase) !void {
        try testing.expectEqualSlices(
            gooey.Effects.PointerDrag.Phase,
            expected,
            self.phases[0..self.phase_count],
        );
        self.phase_count = 0;
    }
};

const CaptureApp = gooey.App(CaptureState, captureRender, .{
    .title = "Capture",
    .width = 300,
    .height = 100,
    .limits = .nano,
});

fn captureRender(cx: *Cx) void {
    const state = cx.state(CaptureState);
    const square: ui.Style = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 50 } };
    cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 50 } }, .{
        if (state.shown) ui.box(.{
            .key = .{ .name = "captured" },
            .style = square,
            .on_pointer_drag = cx.on(CaptureState.drag, .{}),
            .on_click = cx.on(CaptureState.clickBox, .{}),
        }, .{}) else null,
        ui.box(.{
            .key = .{ .name = "button" },
            .style = square,
            .on_click = cx.on(CaptureState.clickButton, .{}),
        }, .{}),
    }));
}

test "a capture clicks only without a move, and ends quietly when its box leaves" {
    const app = try testing.allocator.create(CaptureApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);

    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    scrollMouse(app, &now, dragged(21, 20));
    scrollMouse(app, &now, .{ .mouse_up = mouse(21, 20) });
    try app.state.expectPhases(&.{ .begin, .move, .end });
    try testing.expectEqual(@as(u32, 1), app.state.box_clicks);

    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    scrollMouse(app, &now, dragged(120, 20));
    scrollMouse(app, &now, .{ .mouse_up = mouse(120, 20) });
    try app.state.expectPhases(&.{ .begin, .move, .end });
    try testing.expectEqual(@as(u32, 1), app.state.box_clicks);
    try testing.expectEqual(@as(u32, 0), app.state.button_clicks);
    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    scrollMouse(app, &now, dragged(40, 20));
    scrollMouse(app, &now, dragged(20, 20));
    scrollMouse(app, &now, .{ .mouse_up = mouse(20, 20) });
    try app.state.expectPhases(&.{ .begin, .move, .move, .end });
    try testing.expectEqual(@as(u32, 1), app.state.box_clicks);

    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    app.state.shown = false;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    scrollMouse(app, &now, dragged(30, 20));
    scrollMouse(app, &now, .{ .mouse_up = mouse(30, 20) });
    try app.state.expectPhases(&.{.begin});
    try testing.expectEqual(gooey.ElementId.root, app.window.capture.id);
    try testing.expectEqual(@as(u32, 0), app.state.button_clicks);
}

const NanoA11yApp = gooey.App(struct {}, nanoA11yRender, .{
    .title = "A11y",
    .width = 100,
    .height = 100,
    .limits = .nano,
});

fn nanoA11yRender(cx: *Cx) void {
    const count = gooey.ResourceLimits.nano.a11y.element_count_max;
    for (0..count) |_| cx.render(ui.box(.{ .a11y = .{ .role = .button, .label = "Go" } }, .{}));
}

test "a nano app records exactly its a11y.element_count_max nodes" {
    const app = try testing.allocator.create(NanoA11yApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    app.tick(1);
    const frame = app.window.rendered();
    const count = gooey.ResourceLimits.nano.a11y.element_count_max;
    try testing.expectEqual(@as(usize, count), frame.a11y.len);
    try testing.expectEqual(count, frame.a11y_count);
    try testing.expectEqual(@as(usize, count), app.window.screen_reader.tree.elements.len);
}

const DragDropApp = drag_drop.App;

fn dragDropRecord(
    app: *DragDropApp,
    id: ?drag_drop.ItemId,
    right: bool,
) *const internals.records.HitRecord {
    const frame = app.window.rendered();
    // The lists render left, then right, so tree order tells them apart.
    var lists_seen: u32 = 0;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (id) |card| {
            if (record.drag_type != 0 and record.drag_payload == card) return record;
        } else {
            if (record.drop_type == 0) continue;
            if ((lists_seen == 1) == right) return record;
            lists_seen += 1;
        }
    }
    unreachable;
}

fn quadAlphaAt(frame: *const internals.records.Frame, color: ui.Color, x: ?f32) ?f32 {
    for (frame.paint[0..frame.paint_count]) |record| {
        if (record != .quad) continue;
        const fill = record.quad.fill;
        if (fill.r != color.r or fill.g != color.g or fill.b != color.b) continue;
        if (x) |left| {
            if (record.quad.bounds.x != left) continue;
        }
        return fill.a;
    }
    return null;
}

test "drag_drop: a card drags to the other list; a short press, Escape, or a miss moves none" {
    const app = try testing.allocator.create(DragDropApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const banana = dragDropRecord(app, 1, false).bounds;
    const right_record = dragDropRecord(app, null, true);
    const right_id = right_record.id;
    const right = right_record.bounds;
    const start_x = banana.x + 20;
    const start_y = banana.y + banana.height / 2;
    scrollMouse(app, &now, .{ .mouse_down = mouse(start_x, start_y) });
    scrollMouse(app, &now, dragged(start_x + 2, start_y));
    try testing.expect(app.window.drag.phase == .armed);
    const target_x = right.x + right.width / 2;
    const target_y = right.y + right.height / 2;
    scrollMouse(app, &now, dragged(target_x, target_y));
    try testing.expect(app.window.drag.phase == .active);
    scrollMouse(app, &now, dragged(target_x + 1, target_y));
    try testing.expectEqual(right_id, app.window.drag.over);
    const frame = app.window.rendered();
    const banana_color = drag_drop.items[1].color;
    const source_alpha = quadAlphaAt(frame, banana_color, banana.x).?;
    try testing.expectApproxEqAbs(@as(f32, 0.4), source_alpha, 0.001);
    const preview_alpha = quadAlphaAt(frame, banana_color, target_x + 1 - 60).?;
    try testing.expectApproxEqAbs(@as(f32, 0.85), preview_alpha, 0.001);
    try testing.expectEqual(@as(u32, 0), app.window.press_len);

    scrollMouse(app, &now, .{ .mouse_up = mouse(target_x + 1, target_y) });
    try testing.expectEqualSlices(drag_drop.ItemId, &.{ 0, 2, 3 }, app.state.list(.left).slice());
    try testing.expectEqualSlices(drag_drop.ItemId, &.{1}, app.state.list(.right).slice());
    try testing.expect(app.window.drag.phase == .idle);
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(?f32, 1), quadAlphaAt(app.window.rendered(), banana_color, null));

    const apple = dragDropRecord(app, 0, false).bounds;
    scrollMouse(app, &now, .{ .mouse_down = mouse(apple.x + 20, apple.y + 10) });
    scrollMouse(app, &now, dragged(target_x, target_y));
    try testing.expect(app.window.drag.phase == .active);
    scrollMouse(app, &now, .{ .key_down = chord(.escape, .{}) });
    try testing.expect(app.window.drag.phase == .idle);
    scrollMouse(app, &now, .{ .mouse_up = mouse(target_x, target_y) });
    scrollMouse(app, &now, .{ .mouse_down = mouse(apple.x + 20, apple.y + 10) });
    scrollMouse(app, &now, dragged(40, 20));
    scrollMouse(app, &now, .{ .mouse_up = mouse(40, 20) });
    try testing.expectEqualSlices(drag_drop.ItemId, &.{ 0, 2, 3 }, app.state.list(.left).slice());
    try testing.expectEqualSlices(drag_drop.ItemId, &.{1}, app.state.list(.right).slice());
    try testing.expectEqual(internals.lifecycle.Lifecycle.running, app.guard.lifecycle);
}

const DropProbe = struct {
    shifted: bool = false,
    modal: bool = false,
    source_shown: bool = true,
    near_shown: bool = true,
    near_drops: u32 = 0,
    source_keys: u32 = 0,
    source_key_ups: u32 = 0,
    other_drops: u32 = 0,
    blocked_drops: u32 = 0,
    dropped: ?u32 = null,
    /// `dropPayload` of another type than the payload's gave null.
    other_type_null: bool = false,
    preview_clicks: u32 = 0,

    const Other = struct { value: u16 };

    fn dropNear(self: *DropProbe, effects: *Effects) void {
        self.near_drops += 1;
        self.dropped = effects.dropPayload(u32);
        self.other_type_null = effects.dropPayload(Other) == null;
    }

    fn dropOther(self: *DropProbe, _: *Effects) void {
        self.other_drops += 1;
    }

    fn dropBlocked(self: *DropProbe, _: *Effects) void {
        self.blocked_drops += 1;
    }

    fn clickPreview(self: *DropProbe, _: *Effects) void {
        self.preview_clicks += 1;
    }

    fn sourceKey(self: *DropProbe, effects: *Effects) void {
        const event = effects.inputEvent().?;
        if (event.* == .key_up) self.source_key_ups += 1;
        if (event.* != .key_down) return;
        self.source_keys += 1;
        if (event.key_down.key == .space) _ = effects.startDrag(probeId("source"));
    }
};

const DropProbeApp = gooey.App(DropProbe, dropProbeRender, .{
    .title = "Drop probe",
    .width = 500,
    .height = 100,
    .limits = .nano,
});

fn dropProbeSpacer(width: f32) ui.Box.Element(@TypeOf(.{})) {
    assert(width >= 0);
    return ui.box(.{ .style = .{ .width = .{ .fixed = width }, .height = .{ .fixed = 40 } } }, .{});
}

fn dropProbeRender(cx: *Cx) void {
    const s = cx.state(DropProbe);
    const cell: ui.Style = .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 40 } };
    const near_x: f32 = if (s.shifted) 200 else 100;
    cx.render(ui.box(.{
        .key = .{ .name = "row" },
        .style = .{ .direction = .row, .width = .{ .grow = 1 } },
    }, .{
        if (s.source_shown) ui.box(.{
            .key = .{ .name = "source" },
            .style = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } },
            .draggable = .of(u32, 7),
            .focusable = true,
            .on_key = cx.on(DropProbe.sourceKey, .{}),
        }, .{}) else dropProbeSpacer(40),
        dropProbeSpacer(near_x - 40),
        if (s.near_shown) ui.box(.{
            .key = .{ .name = "near" },
            .style = cell,
            .drop_target = .of(u32, cx.on(DropProbe.dropNear, .{})),
        }, .{}) else dropProbeSpacer(60),
        dropProbeSpacer(300 - near_x - 60),
        ui.box(.{
            .key = .{ .name = "other" },
            .style = cell,
            .drop_target = .of(DropProbe.Other, cx.on(DropProbe.dropOther, .{})),
        }, .{}),
        dropProbeSpacer(40),
        ui.box(.{
            .key = .{ .name = "blocked" },
            .style = cell,
            .drop_target = .of(u32, cx.on(DropProbe.dropBlocked, .{})),
        }, .{}),
        if (s.modal) ui.box(.{
            .key = .{ .name = "modal" },
            .layer = .{ .kind = .modal, .anchor = .{ .window = .{ .x = 380 } }, .clip = .escape },
            .style = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } },
        }, .{}) else null,
        if (cx.drag(u32)) |drag| ui.box(.{
            .key = .{ .name = "preview" },
            .layer = .{
                .kind = .drag,
                .anchor = .{ .window = .{ .x = drag.x - 20, .y = drag.y - 20 } },
                .clip = .escape,
            },
            .style = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } },
            .on_click = cx.on(DropProbe.clickPreview, .{}),
            .a11y = .{ .role = .button, .label = "Preview" },
        }, .{}) else null,
    }));
}

fn probeId(name: []const u8) gooey.ElementId {
    return gooey.ElementId.root.child(.{ .name = "row" }).child(.{ .name = name });
}

test "a drag preview never takes the pointer and adds no accessibility node" {
    const app = try testing.allocator.create(DropProbeApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    scrollMouse(app, &now, dragged(130, 20));
    scrollMouse(app, &now, dragged(131, 20));
    try testing.expectEqual(probeId("near"), app.window.drag.over);
    const frame = app.window.rendered();
    const query: internals.Query = .{ .window = &app.window };
    try testing.expectEqual(probeId("near"), query.hitTest(.{ .x = 131, .y = 20 }).?);
    var preview_found = false;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.id != probeId("preview")) continue;
        preview_found = true;
        try testing.expect(!record.pointer);
        try testing.expect(record.bounds.contains(131, 20));
    }
    try testing.expect(preview_found);
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        try testing.expect(node.id != probeId("preview"));
    }
    scrollMouse(app, &now, .{ .mouse_up = mouse(131, 20) });
    try testing.expectEqual(@as(u32, 1), app.state.near_drops);
    try testing.expectEqual(@as(?u32, 7), app.state.dropped);
    try testing.expect(app.state.other_type_null);
    try testing.expectEqual(@as(u32, 0), app.state.preview_clicks);
}

const TooltipProbe = struct {
    below_clicks: u32 = 0,
    tip_clicks: u32 = 0,

    fn clickBelow(self: *TooltipProbe) void {
        self.below_clicks += 1;
    }

    fn clickTip(self: *TooltipProbe) void {
        self.tip_clicks += 1;
    }
};

const TooltipProbeApp = gooey.App(TooltipProbe, tooltipProbeRender, .{
    .title = "Tooltip probe",
    .width = 200,
    .height = 100,
    .limits = .nano,
});

fn tooltipProbeRender(cx: *Cx) void {
    cx.render(ui.box(.{ .key = .{ .name = "row" } }, .{
        ui.box(.{
            .key = .{ .name = "trigger" },
            .style = .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 40 } },
        }, .{ui.box(.{
            .key = .{ .name = "tip" },
            .layer = .{ .kind = .tooltip, .anchor = .{ .parent = .{ .y = 40 } }, .clip = .escape },
            .style = .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 30 } },
            .on_click = cx.on(TooltipProbe.clickTip, .{}),
            .a11y = .{ .role = .tooltip, .label = "Tip" },
        }, .{})}),
        ui.box(.{
            .key = .{ .name = "below" },
            .style = .{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 60 } },
            .on_click = cx.on(TooltipProbe.clickBelow, .{}),
        }, .{}),
    }));
}

test "a tooltip layer never takes the pointer and keeps its accessibility node" {
    const app = try testing.allocator.create(TooltipProbeApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    scrollMouse(app, &now, .{ .mouse_moved = mouse(30, 55) });
    const tip_id = probeId("trigger").child(.{ .name = "tip" });
    const frame = app.window.rendered();
    var tip_found = false;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.id != tip_id) continue;
        tip_found = true;
        try testing.expect(!record.pointer);
        try testing.expect(record.bounds.contains(30, 55));
    }
    try testing.expect(tip_found);
    const query: internals.Query = .{ .window = &app.window };
    try testing.expectEqual(probeId("below"), query.hitTest(.{ .x = 30, .y = 55 }).?);
    try testing.expect(!app.window.isHovered(probeId("trigger")));
    var tip_node = false;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.id == tip_id) tip_node = node.role == .tooltip;
    }
    try testing.expect(tip_node);
    clickAt(app, &now, 30, 55);
    try testing.expectEqual(@as(u32, 1), app.state.below_clicks);
    try testing.expectEqual(@as(u32, 0), app.state.tip_clicks);
}

test "over follows the payload type, a flip under a still pointer, and a modal" {
    const app = try testing.allocator.create(DropProbeApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    scrollMouse(app, &now, dragged(330, 20));
    try testing.expect(app.window.drag.phase == .active);
    try testing.expectEqual(gooey.ElementId.root, app.window.drag.over);
    scrollMouse(app, &now, dragged(130, 20));
    try testing.expectEqual(probeId("near"), app.window.drag.over);
    app.state.shifted = true;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    try testing.expectEqual(gooey.ElementId.root, app.window.drag.over);
    scrollMouse(app, &now, dragged(230, 20));
    try testing.expectEqual(probeId("near"), app.window.drag.over);

    app.state.modal = true;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    scrollMouse(app, &now, dragged(430, 20));
    try testing.expectEqual(gooey.ElementId.root, app.window.drag.over);
    scrollMouse(app, &now, .{ .mouse_up = mouse(430, 20) });
    try testing.expect(app.window.drag.phase == .idle);
    try testing.expectEqual(@as(u32, 0), app.state.near_drops);
    try testing.expectEqual(@as(u32, 0), app.state.other_drops);
    try testing.expectEqual(@as(u32, 0), app.state.blocked_drops);
}

test "a drag drops its payload after its source stops rendering, and is cancelled by the platform" {
    const app = try testing.allocator.create(DropProbeApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    scrollMouse(app, &now, dragged(130, 20));
    app.state.source_shown = false;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    scrollMouse(app, &now, .{ .mouse_up = mouse(130, 20) });
    try testing.expectEqual(@as(u32, 1), app.state.near_drops);
    try testing.expectEqual(@as(?u32, 7), app.state.dropped);

    app.state.source_shown = true;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    scrollMouse(app, &now, dragged(130, 20));
    try testing.expect(app.window.drag.phase == .active);
    scrollMouse(app, &now, .pointer_cancelled);
    try testing.expect(app.window.drag.phase == .idle);
    scrollMouse(app, &now, .{ .mouse_up = mouse(130, 20) });
    try testing.expectEqual(@as(u32, 1), app.state.near_drops);
    try testing.expectEqual(@as(u32, 0), app.state.preview_clicks);
}

test "a focus loss cancels the drag and releases each held key in one event" {
    const app = try testing.allocator.create(DropProbeApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    keyDown(app, &now, .tab, .{});
    try testing.expectEqual(probeId("source"), app.window.focus);
    scrollMouse(app, &now, .{ .mouse_down = mouse(20, 20) });
    scrollMouse(app, &now, dragged(130, 20));
    try testing.expect(app.window.drag.phase == .active);

    var keys: gooey.input.HeldKeys = .empty;
    keys.set(@backingInt(gooey.input.KeyCode.a));
    keys.set(@backingInt(gooey.input.KeyCode.shift));
    scrollMouse(app, &now, .{ .focus_lost = .{ .pointer_cancelled = true, .keys_held = keys } });
    try testing.expect(app.window.drag.phase == .idle);
    try testing.expectEqual(@as(u32, 2), app.state.source_key_ups);
    scrollMouse(app, &now, .{ .mouse_up = mouse(130, 20) });
    try testing.expectEqual(@as(u32, 0), app.state.near_drops);
    try testing.expectEqual(@as(u32, 0), app.state.preview_clicks);

    scrollMouse(app, &now, .{ .focus_lost = .{ .pointer_cancelled = false, .keys_held = .empty } });
    try testing.expectEqual(@as(u32, 2), app.state.source_key_ups);
    try testing.expectEqual(probeId("source"), app.window.focus);
}

fn keyDown(app: anytype, now: *u64, key: gooey.input.KeyCode, modifiers: gooey.input.Modifiers) void {
    scrollMouse(app, now, .{ .key_down = chord(key, modifiers) });
}

test "drag_drop: Space picks a card up, Tab and the arrows choose a list, Space drops" {
    const app = try testing.allocator.create(DragDropApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    const fruits = dragDropRecord(app, null, false).id;
    const basket_record = dragDropRecord(app, null, true);
    const basket = basket_record.id;
    const basket_bounds = basket_record.bounds;
    const banana = dragDropRecord(app, 1, false);
    const banana_id = banana.id;
    const banana_bounds = banana.bounds;
    keyDown(app, &now, .tab, .{});
    keyDown(app, &now, .tab, .{});
    try testing.expectEqual(banana_id, app.window.focus);
    keyDown(app, &now, .space, .{});
    const drag = &app.window.drag;
    try testing.expect(drag.keyboard);
    try testing.expect(drag.phase == .active);
    try testing.expectEqual(gooey.ElementId.root, drag.over);
    try testing.expectEqual(banana_bounds.x + banana_bounds.width / 2, drag.x);
    const banana_color = drag_drop.items[1].color;
    const source_alpha = quadAlphaAt(app.window.rendered(), banana_color, banana_bounds.x).?;
    try testing.expectApproxEqAbs(@as(f32, 0.4), source_alpha, 0.001);
    try testing.expectEqual(@as(u32, 1), app.window.rendered().announcements.count);

    keyDown(app, &now, .tab, .{});
    try testing.expectEqual(basket, drag.over);
    try testing.expectEqual(basket, app.window.focus);
    try testing.expect(app.window.focus_visible);
    try testing.expectEqual(basket_bounds.y + basket_bounds.height / 2, drag.y);
    keyDown(app, &now, .tab, .{});
    try testing.expectEqual(fruits, drag.over);
    keyDown(app, &now, .tab, .{ .shift = true });
    try testing.expectEqual(basket, drag.over);
    keyDown(app, &now, .down, .{});
    try testing.expectEqual(fruits, drag.over);
    keyDown(app, &now, .up, .{});
    try testing.expectEqual(basket, drag.over);
    keyDown(app, &now, .a, .{});
    try testing.expectEqual(basket, drag.over);
    try testing.expectEqual(basket, app.window.focus);

    keyDown(app, &now, .space, .{});
    try testing.expect(drag.phase == .idle);
    try testing.expect(!drag.keyboard);
    try testing.expectEqualSlices(drag_drop.ItemId, &.{ 0, 2, 3 }, app.state.list(.left).slice());
    try testing.expectEqualSlices(drag_drop.ItemId, &.{1}, app.state.list(.right).slice());
    const said = app.window.rendered().announcements;
    try testing.expectEqual(@as(u32, 1), said.count);
    try testing.expectEqualStrings("Banana moved to Basket", said.text(said.slice()[0]));
    try testing.expectEqual(basket, app.window.focus);
    try testing.expect(app.window.focus_visible);

    keyDown(app, &now, .tab, .{});
    const moved_id = dragDropRecord(app, 1, false).id;
    try testing.expect(moved_id != banana_id);
    try testing.expectEqual(moved_id, app.window.focus);
    keyDown(app, &now, .space, .{});
    try testing.expect(drag.keyboard);
    keyDown(app, &now, .left, .{});
    try testing.expectEqual(basket, drag.over);
    keyDown(app, &now, .escape, .{});
    try testing.expect(drag.phase == .idle);
    try testing.expectEqual(moved_id, app.window.focus);
    keyDown(app, &now, .space, .{});
    try testing.expect(drag.keyboard);
    scrollMouse(app, &now, .{ .mouse_down = mouse(40, 20) });
    try testing.expect(drag.phase == .idle);
    scrollMouse(app, &now, .{ .mouse_up = mouse(40, 20) });
    try testing.expectEqualSlices(drag_drop.ItemId, &.{ 0, 2, 3 }, app.state.list(.left).slice());
    try testing.expectEqualSlices(drag_drop.ItemId, &.{1}, app.state.list(.right).slice());
}

test "a keyboard drag skips other types and modal-covered targets, and follows the frame" {
    const app = try testing.allocator.create(DropProbeApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var now: u64 = 0;
    app.tick(now);
    keyDown(app, &now, .tab, .{});
    try testing.expectEqual(probeId("source"), app.window.focus);
    keyDown(app, &now, .space, .{});
    const drag = &app.window.drag;
    try testing.expect(drag.keyboard);
    keyDown(app, &now, .a, .{});
    try testing.expectEqual(@as(u32, 1), app.state.source_keys);
    keyDown(app, &now, .right, .{});
    try testing.expectEqual(probeId("near"), drag.over);
    try testing.expectEqual(@as(f32, 130), drag.x);
    keyDown(app, &now, .right, .{});
    try testing.expectEqual(probeId("blocked"), drag.over);
    keyDown(app, &now, .right, .{});
    try testing.expectEqual(probeId("near"), drag.over);

    app.state.shifted = true;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    try testing.expectEqual(@as(f32, 230), drag.x);
    app.state.modal = true;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    keyDown(app, &now, .right, .{});
    try testing.expectEqual(probeId("near"), drag.over);
    keyDown(app, &now, .left, .{});
    try testing.expectEqual(probeId("near"), drag.over);

    app.state.modal = false;
    app.state.near_shown = false;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    now += 1;
    app.tick(now);
    try testing.expectEqual(gooey.ElementId.root, drag.over);
    try testing.expectEqual(probeId("source"), app.window.focus);
    keyDown(app, &now, .@"return", .{});
    try testing.expect(drag.keyboard);
    app.state.near_shown = true;
    app.window.render_requested = true;
    now += 1;
    app.tick(now);
    keyDown(app, &now, .right, .{});
    try testing.expectEqual(probeId("near"), drag.over);
    keyDown(app, &now, .@"return", .{});
    try testing.expect(drag.phase == .idle);
    try testing.expectEqual(@as(u32, 1), app.state.near_drops);
    try testing.expectEqual(@as(?u32, 7), app.state.dropped);
    try testing.expectEqual(@as(u32, 0), app.state.blocked_drops);
    try testing.expectEqual(probeId("source"), app.window.focus);
    try testing.expectEqual(@as(u32, 1), app.state.source_keys);
}

fn dragDropKey(app: *DragDropApp, key: gooey.input.KeyCode) void {
    app.window.queue.push(.{ .input = .{ .key_down = chord(key, .{}) } });
    app.window.queue.push(.{ .input = .{ .key_up = chord(key, .{}) } });
}

test "drag_drop: keyboard drags during one frame in flight keep only the newest announcement" {
    const app = try testing.allocator.create(DragDropApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    const tick = internals.tick;
    const window = &app.window;
    const slot_count = DragDropApp.limits.a11y.announcement_polite_pending_max + 1;
    comptime assert(2 * 4 + 1 > slot_count);
    app.tick(1);
    dragDropKey(app, .tab);
    try testing.expect(tick.tickMain(app, window, 2));
    try testing.expect(window.frame_in_flight.load(.acquire));
    var now: u64 = 3;
    for (0..4) |_| {
        for ([_]gooey.input.KeyCode{ .space, .tab, .space, .tab }) |key| dragDropKey(app, key);
        try testing.expect(!tick.tickMain(app, window, now));
        now += 1;
        try testing.expect(window.frame_in_flight.load(.acquire));
    }
    const moved_count = app.state.list(.right).count;
    try testing.expectEqual(@as(u32, 4), app.state.list(.left).count + moved_count);
    try testing.expect(moved_count > 0);
    dragDropKey(app, .space);
    try testing.expect(!tick.tickMain(app, window, now));
    now += 1;
    try testing.expectEqual(@as(u32, 1), window.announcements.count);
    const pending = window.announcements.slice()[0];
    try testing.expectEqual(.assertive, pending.live);
    try testing.expect(std.mem.startsWith(u8, window.announcements.text(pending), "Picked up."));

    tick.presentBuilt(window);
    try testing.expect(tick.tickMain(app, window, now));
    try testing.expectEqual(@as(u32, 0), window.announcements.count);
    tick.presentBuilt(window);
    // The flip at the start of this tick hands the frame to the screen
    // reader (`screen_reader.publish` reads the rendered frame).
    _ = tick.tickMain(app, window, now + 1);
    const delivered = window.rendered();
    try testing.expectEqual(@as(u32, 1), delivered.announcements.count);
    const said = delivered.announcements.slice()[0];
    try testing.expect(std.mem.startsWith(u8, delivered.announcements.text(said), "Picked up."));
    if (window.frame_in_flight.load(.acquire)) tick.presentBuilt(window);
    window.render_requested = true;
    app.tick(now + 2);
    try testing.expectEqual(@as(u32, 0), window.rendered().announcements.count);
}

fn menuNode(
    app: *context_menu.App,
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

fn menuApp(app: *context_menu.App, now: *u64) !void {
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    app.tick(now.*);
    now.* += 1;
    app.tick(now.*);
}

const first_task = context_menu.State.titles[0];

fn menuPress(
    app: *context_menu.App,
    now: *u64,
    point: [2]f32,
    button: gooey.input.MouseButton,
    modifiers: gooey.input.Modifiers,
) void {
    var event = mouseWith(point[0], point[1], button);
    event.modifiers = modifiers;
    app.window.queue.push(.{ .input = .{ .mouse_down = event } });
    app.window.queue.push(.{ .input = .{ .mouse_up = event } });
    for (0..2) |_| {
        now.* += 1;
        app.tick(now.*);
    }
}

fn centre(node: *const internals.records.A11yNode) [2]f32 {
    return .{ node.bounds.x + node.bounds.width / 2, node.bounds.y + node.bounds.height / 2 };
}

test "a right press opens a ContextMenu at the pointer, and a choice runs and closes it" {
    const app = try testing.allocator.create(context_menu.App);
    defer testing.allocator.destroy(app);
    var now: u64 = 0;
    try menuApp(app, &now);
    defer app.deinitHeadless();
    const card = menuNode(app, .group, first_task).?.bounds;
    const press = [2]f32{ card.x + 100, card.y + card.height / 2 };
    try testing.expect(menuNode(app, .menu, first_task) == null);
    menuPress(app, &now, press, .right, .{});
    const menu = menuNode(app, .menu, first_task) orelse return error.NoMenu;
    try testing.expectApproxEqAbs(press[0], menu.bounds.x, 0.5);
    try testing.expectApproxEqAbs(press[1], menu.bounds.y, 0.5);
    try expectFocused(&app.window, .menuitem, "Mark done");
    try testing.expect(!app.state.done[0]);
    vopr_invariants.checkFrame(&app.window, app.window.rendered());

    menuPress(app, &now, centre(menuNode(app, .menuitem, "Rename").?), .left, .{});
    try testing.expect(menuNode(app, .menu, first_task) != null);
    menuPress(app, &now, centre(menuNode(app, .menuitem, "Mark done").?), .left, .{});
    try testing.expect(app.state.done[0]);
    try testing.expect(menuNode(app, .menu, first_task) == null);
    try expectFocused(&app.window, .group, first_task);

    menuPress(app, &now, press, .right, .{});
    try testing.expect(menuNode(app, .menu, first_task) != null);
    menuPress(app, &now, .{ 500, 380 }, .left, .{});
    try testing.expect(menuNode(app, .menu, first_task) == null);
    try testing.expect(app.state.done[0]);
}

test "Shift+F10 opens a ContextMenu whose keys skip disabled rows and wrap" {
    const app = try testing.allocator.create(context_menu.App);
    defer testing.allocator.destroy(app);
    var now: u64 = 0;
    try menuApp(app, &now);
    defer app.deinitHeadless();
    pressKey(app, &now, .tab, .{});
    try expectFocused(&app.window, .group, first_task);
    const card = menuNode(app, .group, first_task).?.bounds;
    pressKey(app, &now, .f10, .{ .shift = true });
    const menu = menuNode(app, .menu, first_task) orelse return error.NoMenu;
    try testing.expectApproxEqAbs(card.x, menu.bounds.x, 0.5);
    try testing.expectApproxEqAbs(card.y + card.height, menu.bounds.y, 0.5);
    try expectFocused(&app.window, .menuitem, "Mark done");
    vopr_invariants.checkFrame(&app.window, app.window.rendered());
    const steps = [_]struct { key: gooey.input.KeyCode, name: []const u8 }{
        .{ .key = .down, .name = "Delete" },
        .{ .key = .down, .name = "Mark done" },
        .{ .key = .up, .name = "Delete" },
        .{ .key = .home, .name = "Mark done" },
        .{ .key = .end, .name = "Delete" },
    };
    for (steps) |step| {
        pressKey(app, &now, step.key, .{});
        try expectFocused(&app.window, .menuitem, step.name);
    }
    pressKey(app, &now, .escape, .{});
    try testing.expect(menuNode(app, .menu, first_task) == null);
    try expectFocused(&app.window, .group, first_task);
    try testing.expect(!app.state.removed[0]);

    pressKey(app, &now, .f10, .{ .shift = true });
    pressKey(app, &now, .@"return", .{});
    try testing.expect(app.state.done[0]);
    try testing.expect(menuNode(app, .menu, first_task) == null);
    try expectFocused(&app.window, .group, first_task);
}

test "a Ctrl+press opens a context menu only on macOS, and clicks nothing there" {
    const app = try testing.allocator.create(context_menu.App);
    defer testing.allocator.destroy(app);
    var now: u64 = 0;
    try menuApp(app, &now);
    defer app.deinitHeadless();
    const title = context_menu.State.titles[1];
    const card = menuNode(app, .group, title).?;
    menuPress(app, &now, centre(card), .left, .{ .ctrl = true });
    const opened = menuNode(app, .menu, title) != null;
    try testing.expectEqual(builtin.os.tag == .macos, opened);
}
