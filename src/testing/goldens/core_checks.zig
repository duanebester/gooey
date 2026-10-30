//! Milestone 1 exit checks for the 0.4.0 core on TestBackend (plan, phase 3):
//! the IME rect query is answered synchronously, a file dialog requested by a
//! handler opens on the main thread outside the handler, and counter and
//! todo run their traces with no allocation after initialization (the
//! lifecycle guard panics on one) within their component-depth budget.

const std = @import("std");
const gooey = @import("gooey");
const counter = @import("core_counter_example");
const todo = @import("core_todo_example");
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
    const Driver = core_driver.CoreDriver(todo.App, todo.render);
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

const DialogApp = core.App(DialogState, .{
    .title = "Dialog",
    .width = 200,
    .height = 100,
    .limits = .nano,
    .theme = &core.Theme.light,
    .keymap = &.{},
    .entities = &.{},
    .on_init = null,
});

var dialog_on_complete: ?core.Handler = null;

fn dialogRender(cx: *Cx) void {
    dialog_on_complete = cx.on(DialogState.completed, .{});
    cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{
        components.core.Button{ .label = "Open", .on_click = cx.on(openDialog, .{}) },
    }));
}

fn openDialog(_: *DialogState, effects: *Effects) void {
    effects.openFileDialog(.{ .kind = .open, .on_complete = dialog_on_complete.? });
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
    defer app.deinit();
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
    app.tickWith(dialogRender, now);
    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        app.window.queue.push(.{ .input = .{ .mouse_down = mouse(20, 20) } });
        now += 1;
        app.tickWith(dialogRender, now); // The click opens the dialog after the drain.
        now += 1;
        app.tickWith(dialogRender, now); // The next drain delivers the outcome.
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
        const Driver = core_driver.CoreDriver(case[0], case[1]);
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
    const Driver = core_driver.CoreDriver(counter.App, counter.render);
    const driver = try testing.allocator.create(Driver);
    defer testing.allocator.destroy(driver);
    try driver.initInPlace(testing.allocator, testing.io, &traces.counter);
    defer driver.deinit();
    const tick = core.internals.tick;
    const Root = struct {
        pub fn render(cx: *Cx) void {
            counter.render(cx);
        }
    };
    var root = Root{};
    const window = &driver.app.window;
    driver.frame();
    const first = window.rendered().frame_number;
    const now = driver.now_ns;

    window.queue.push(.{ .input = .{ .mouse_down = mouse(155, 245) } });
    try testing.expect(tick.tickMain(&root, window, now + 1));
    try testing.expect(window.frame_in_flight.load(.acquire));
    try testing.expectEqual(@as(i32, 1), driver.app.state.count);

    window.queue.push(.{ .input = .{ .mouse_down = mouse(155, 245) } });
    try testing.expect(!tick.tickMain(&root, window, now + 2));
    try testing.expectEqual(@as(i32, 2), driver.app.state.count);
    try testing.expect(window.render_requested);
    try testing.expectEqual(first, window.rendered().frame_number);

    tick.presentBuilt(window);
    try testing.expect(!window.frame_in_flight.load(.acquire));
    // Presented but not yet flipped: the query still sees the old frame.
    try testing.expectEqual(first, window.rendered().frame_number);
    try testing.expect(tick.tickMain(&root, window, now + 3));
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
    const Driver = core_driver.CoreDriver(counter.App, counter.render);
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
        driver.frame();
    }
    try testing.expectEqual(first + 3, uploads.frameCurrent());
    driver.frame(); // Nothing requested a render.
    try testing.expectEqual(first + 3, uploads.frameCurrent());
}
