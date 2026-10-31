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
const components = @import("gooey-components");
const core_driver = @import("core.zig");
const trace_mod = @import("trace.zig");
const traces = @import("traces.zig");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Effects = core.Effects;
const TextBuffer = gooey.testing.record_dump.TextBuffer;

const testing = std.testing;

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
    const query = core.Query{ .window = &driver.app.window };

    driver.frame();
    try testing.expectEqual(@as(?core.internals.records.Rect, null), query.imeCursorRect());
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

const AreaApp = core.App(AreaState, areaRender, .{
    .title = "Area",
    .width = 300,
    .height = 200,
    .limits = .small,
});

fn areaRender(cx: *Cx) void {
    const state = cx.state(AreaState);
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{
        components.core.TextArea{ .key = "notes", .bind = &state.notes, .rows = 2 },
    }));
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
    const query = core.Query{ .window = &app.window };
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

/// An app whose button opens a file dialog, for the dialog check.
const DialogState = struct {
    path_bytes: [256]u8 = undefined,
    path_len: u32 = 0,
    cancelled: u32 = 0,
    failed: u32 = 0,

    pub fn completed(self: *DialogState, effects: *Effects) void {
        const completion = effects.completionEvent().?;
        switch (completion.outcome) {
            .file_selected => |path| {
                @memcpy(self.path_bytes[0..path.len], path);
                self.path_len = @intCast(path.len);
            },
            .cancelled => self.cancelled += 1,
            .failed => self.failed += 1,
        }
    }
};

const DialogApp = core.App(DialogState, dialogRender, .{
    .title = "Dialog",
    .width = 200,
    .height = 100,
    .limits = .nano,
});

fn dialogRender(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{
        components.core.Button{ .label = "Open", .on_click = cx.on(openDialog, .{}) },
    }));
}

fn openDialog(_: *DialogState, effects: *Effects) void {
    const on_complete = effects.handler(DialogState.completed);
    effects.openFileDialog(.{ .kind = .open, .on_complete = on_complete });
}

/// A dialog service that records where it ran and answers from a script.
const ScriptedDialog = struct {
    window: *const core.internals.window.Window,
    main_thread: std.Thread.Id,
    opened_on_main: u32 = 0,
    opened_in_drain: u32 = 0,
    answers: []const core.internals.events.Completion.Outcome,
    next: u32 = 0,

    fn open(
        context: *anyopaque,
        scratch: std.mem.Allocator,
        request: core.internals.handler.FileDialogRequest,
    ) core.internals.events.Completion.Outcome {
        const self: *ScriptedDialog = @ptrCast(@alignCast(context));
        _ = scratch;
        std.debug.assert(request.kind == .open);
        if (std.Thread.getCurrentId() == self.main_thread) self.opened_on_main += 1;
        if (self.window.phase == .drain) self.opened_in_drain += 1;
        const answer = self.answers[self.next];
        self.next += 1;
        return answer;
    }
};

test "a file dialog opened from a handler runs on the main thread after the handler" {
    // Goal: plan exit criterion. Methodology: click a button whose handler
    // requests a dialog; the scripted service records the thread and phase it
    // ran in, and answers selected, then cancelled, then failed. Each answer
    // must reach the completion handler as a distinct outcome a tick later.
    const app = try testing.allocator.create(DialogApp);
    defer testing.allocator.destroy(app);
    try app.initHeadless(testing.allocator, testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();
    var service = ScriptedDialog{
        .window = &app.window,
        .main_thread = std.Thread.getCurrentId(),
        .answers = &.{
            .{ .file_selected = "/tmp/notes.txt" },
            .cancelled,
            .{ .failed = error.AccessDenied },
        },
    };
    app.window.file_dialog = .{ .context = &service, .open = ScriptedDialog.open };

    var now: u64 = 0;
    app.tick(now);
    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        app.window.queue.push(.{ .input = .{ .mouse_down = mouse(20, 20) } });
        app.window.queue.push(.{ .input = .{ .mouse_up = mouse(20, 20) } });
        now += 1;
        app.tick(now); // The click opens the dialog after the drain.
        now += 1;
        app.tick(now); // The next drain delivers the outcome.
    }
    try testing.expectEqual(@as(u32, 3), service.opened_on_main);
    try testing.expectEqual(@as(u32, 3), service.opened_in_drain);
    try testing.expectEqualStrings("/tmp/notes.txt", app.state.path_bytes[0..app.state.path_len]);
    try testing.expectEqual(@as(u32, 1), app.state.cancelled);
    try testing.expectEqual(@as(u32, 1), app.state.failed);
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
            core.internals.lifecycle.Lifecycle.running,
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
    const tick = core.internals.tick;
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
const FontApp = core.App(FontState, fontRender, .{
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
fn spriteXs(window: *const core.internals.window.Window, out: []f32) u32 {
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
    const tick = core.internals.tick;
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

const WrapApp = core.App(WrapState, wrapRender, .{
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
fn lineStarts(window: *const core.internals.window.Window, out: []core.internals.records.Rect) u32 {
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
    var starts: [8]core.internals.records.Rect = undefined;
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
        effects.setTheme(&core.Theme.dark);
        effects.announce("Dark theme", .polite);
    }
};

const ThemeApp = core.App(ThemeState, themeRender, .{
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

fn firstFill(frame: *const core.internals.records.Frame) core.internals.records.Color {
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
    const tick = core.internals.tick;
    const window = &app.window;
    const light = &core.Theme.light;
    const dark = &core.Theme.dark;
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
    const Driver = core_driver.CoreDriver(actions.App);
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.actions);
    defer driver.deinit();
    const query = core.Query{ .window = &driver.app.window };
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

const ClockApp = core.App(ClockState, clockRender, .{
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
