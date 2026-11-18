//! VOPR: deterministic simulation testing of the core, after TigerBeetle's.
//!
//! One generator, driven by `std.testing.Smith`, turns bytes into a stream of
//! actions against a headless app on the goldens' `CoreDriver`: pointer
//! clicks and moves aimed at the rendered frame's hit records, wheel scrolls,
//! keys, committed and composed text, clock gaps, and the two sides of a tick
//! (`tickMain` and `presentBuilt`) driven separately, so a frame stays in
//! flight while input keeps arriving. The same generator serves `zig build
//! vopr -- [seed]`, whose bytes come from a seeded PRNG, and a
//! `std.testing.fuzz` target, whose bytes come from the fuzzer.
//!
//! Swarm testing: every `swarm_epoch_step_count` steps the generator draws a
//! fresh `Swarm` (action-kind weights, some of them zero, and how pointer
//! targets are picked), so a seed goes deep in a few directions instead of
//! staying near the initial state: filling todo's list, typing past its
//! 128-byte cut, holding frames in flight, or working a full list.
//!
//! Every action keeps the core inside its declared budget (`limits.events`)
//! and away from wall-clock paths, so any panic or failed assertion is a
//! finding: a core bug, or a harness bug to fix here. On top of the core's
//! own assertions, the harness checks after every action that the event queue
//! is empty after `tickMain`, the rendered frame number never decreases, and
//! the render side is idle with no frame in flight. Each run ends with a
//! bounded quiescence loop that must settle. The seed CLI also runs two
//! instances side by side on the same bytes and requires identical frame
//! dumps after every action (determinism).
//!
//! Resource sketch, per action: at most 3 queued events and 16 bytes of text
//! (`text_bytes_action_max`); per `tickMain`, at most the queue's capacity,
//! which the generator never exceeds. Per run: one app and one 64 KiB
//! `NullRenderer` per instance, reserved before the first action, and
//! `bytes_cli` Smith bytes for the CLI. A 12,000-step CLI run takes under a
//! second in Debug; frames over a full list dominate.

const std = @import("std");
const gooey = @import("gooey");
const todo = @import("todo_example");
const core = @import("goldens/core.zig");
const TodoModel = @import("vopr_todo_model.zig").TodoModel;
const trace_mod = @import("goldens/trace.zig");

const assert = std.debug.assert;

const Smith = std.testing.Smith;
const input = gooey.input;
const internals = gooey.internals;
const tick = internals.tick;
const records = internals.records;
const Window = internals.window.Window;

/// Steps one `zig build vopr` run takes before its quiescence loop: enough
/// for a seed that fills todo's list to then work it while full.
pub const step_count_cli: u32 = 12_000;
/// Steps between fresh `Swarm` draws, so one seed can fill the list in one
/// epoch and filter, check, and delete over it in the next.
const swarm_epoch_step_count: u32 = 3_000;
/// Most steps one fuzz input may ask for, so one input is bounded work.
const step_count_fuzz_max: u32 = 256;
/// Most Smith choices one action makes, a text action's: its kind, its
/// length, and one per unit. Each choice reads one `u64`.
const choice_count_action_max: u32 = 2 + text_unit_count_max;
/// Smith bytes the CLI reserves per step, so its PRNG input never runs dry.
const bytes_per_action_max: u32 = choice_count_action_max * @sizeOf(u64);
/// Smith bytes one `Swarm` draw reads.
const bytes_swarm: u32 = Swarm.choice_count * @sizeOf(u64);
/// Smith bytes the CLI reserves for a run: every epoch's swarm and step.
const bytes_cli: u32 = bytes_swarm * (1 + @divFloor(step_count_cli, swarm_epoch_step_count)) +
    step_count_cli * bytes_per_action_max;
/// Rounds of `tickMain` plus `presentBuilt` a run gets to settle at its end.
/// A scroll box that lost content can take a frame per viewport to settle:
/// a full list is about ten viewports of todo's, so 32 leaves headroom.
const quiescence_round_max: u32 = 32;
/// Units (from `text_alphabet`) in one text or composition action.
const text_unit_count_max: u32 = 8;
/// Bytes in one text or composition action: the longest unit is 2 bytes.
const text_bytes_action_max: u32 = text_unit_count_max * 2;
/// Events one pointer action queues: a move, a press, and a release.
const pointer_event_count_max: u32 = 3;
/// Scale factor of every simulated window, as the goldens use.
const scale_factor: f32 = 2;

/// Small, so typed text repeats and collides; "é" is two UTF-8 bytes, so
/// text and draft limits can cut inside a codepoint.
pub const text_alphabet = [_][]const u8{ "a", "b", "Z", "1", " ", "é" };

/// Keys a todo can act on. `.i` is absent, so Cmd/Ctrl+Shift+I, the
/// debugger toggle (which reads the real clock), can never be generated.
const key_choices = [_]input.KeyCode{
    .@"return", .tab,   .delete, .forward_delete, .escape, .space,
    .left,      .right, .up,     .down,           .home,   .end,
    .a,         .c,     .v,      .x,              .z,
};

/// `text_engine.uses_cmd` is pinned false, so Ctrl is the edit modifier.
const modifier_choices = [_]input.Modifiers{
    .{},
    .{ .shift = true },
    .{ .ctrl = true },
    .{ .ctrl = true, .shift = true },
    .{ .alt = true },
};

/// Clock gaps: none, one 60 Hz frame, a caret blink, and a long idle.
const gap_ns_choices = [_]u64{ 0, 16_666_667, 1_000_000_000, 10_000_000_000 };

comptime {
    for (key_choices) |key| assert(key != .i);
    for (text_alphabet) |unit| assert(unit.len <= 2);
    assert(text_bytes_action_max <= internals.limits.EventLimits.nano.text_bytes_max);
}

/// `zig build vopr -- [seed] [--verbose]`: run one seed against todo. With
/// no seed, a random one is drawn and printed, so any run can be replayed.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const options = parseArgs(init.minimal.args.vector) orelse {
        std.debug.print("usage: vopr [seed] [--verbose]\n", .{});
        return error.InvalidArguments;
    };
    const seed = options.seed orelse seed: {
        var random_seed: u64 = 0;
        init.io.random(std.mem.asBytes(&random_seed));
        break :seed random_seed;
    };
    std.debug.print("vopr: todo seed {d}, {d} steps\n", .{ seed, step_count_cli });

    const bytes = try gpa.alloc(u8, bytes_cli);
    defer gpa.free(bytes);

    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(bytes);
    const summary = try runPaired(todo.App, TodoModel, gpa, init.io, bytes, .{
        .step_count = step_count_cli,
        .verbose = options.verbose,
    });
    std.debug.print("vopr: todo seed {d} passed: {d} steps, quiesced in {d} rounds, " ++
        "frame {d}, {d} draws, dump hash {x:0>16}\n", .{
        seed,
        summary.step_count,
        summary.quiescence_round_count,
        summary.frame_number,
        summary.draw_count,
        summary.dump_hash,
    });
}

const CliOptions = struct {
    seed: ?u64,
    verbose: bool,
};

/// Null on an argument it does not understand.
fn parseArgs(args: []const [*:0]const u8) ?CliOptions {
    assert(args.len >= 1);
    var options: CliOptions = .{ .seed = null, .verbose = false };
    for (args[1..]) |pointer| {
        const arg = std.mem.span(pointer);
        if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else {
            if (options.seed != null) return null;
            options.seed = std.fmt.parseInt(u64, arg, 0) catch return null;
        }
    }
    return options;
}

pub const Summary = struct {
    step_count: u32,
    /// Rounds the last `quiesce` ran before nothing was left to do.
    quiescence_round_count: u32,
    frame_number: u64,
    draw_count: u64,
    dump_hash: u64,
};

pub const RunOptions = struct {
    step_count: u32,
    /// Print each action before it runs, so a failing seed shows its steps.
    verbose: bool,
};

/// Drive two instances from the same bytes, both allocated at once, and
/// require the same frames after every action. Any dependence on addresses,
/// leftover global state, or the clock shows up as a differing dump hash.
pub fn runPaired(
    comptime App: type,
    comptime Model: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    options: RunOptions,
) !Summary {
    assert(options.step_count > 0);
    const V = Vopr(App, Model);
    var smith_first: Smith = .{ .in = bytes };
    var smith_second: Smith = .{ .in = bytes };
    const first = try gpa.create(V);
    defer gpa.destroy(first);
    try first.initInPlace(gpa, io, &smith_first);
    defer first.deinit();

    const second = try gpa.create(V);
    defer gpa.destroy(second);
    try second.initInPlace(gpa, io, &smith_second);
    defer second.deinit();

    checkSame(V, first, second, 0);
    var step_index: u32 = 0;
    while (step_index < options.step_count) : (step_index += 1) {
        const action = first.generate(&smith_first);
        if (options.verbose) {
            if (step_index % swarm_epoch_step_count == 0) {
                std.debug.print("swarm: {f}\n", .{first.swarm});
            }
            std.debug.print("step {d}: {f}\n", .{ step_index, action });
        }
        first.perform(action);
        second.perform(second.generate(&smith_second));
        checkSame(V, first, second, step_index);
    }
    first.quiesce();
    second.quiesce();
    checkSame(V, first, second, step_index);
    assert(smith_first.in.?.len == smith_second.in.?.len);
    return first.summary(step_index);
}

fn checkSame(comptime V: type, first: *V, second: *V, step_index: u32) void {
    assert(first != second);
    const a = first.summary(step_index);
    const b = second.summary(step_index);
    if (a.frame_number != b.frame_number or a.draw_count != b.draw_count or
        a.dump_hash != b.dump_hash)
    {
        std.debug.panic("vopr: instances diverged at step {d}: frame {d} vs {d}, " ++
            "{d} vs {d} draws, dump hash {x} vs {x}", .{
            step_index,   a.frame_number, b.frame_number, a.draw_count,
            b.draw_count, a.dump_hash,    b.dump_hash,
        });
    }
}

pub const Action = union(enum) {
    pointer: Pointer,
    key: Chord,
    /// Committed text, never empty.
    text: []const u8,
    /// IME preedit; empty ends the composition.
    compose: []const u8,
    /// A wheel scroll at a point, in logical pixels.
    scroll: Scroll,
    wait_ns: u64,
    tick_main,
    /// Generated only while a frame is in flight (`presentBuilt` asserts it).
    present,

    pub const Pointer = struct {
        kind: enum { click, move },
        x: f32,
        y: f32,
        click_count: u32,
    };

    pub const Chord = struct {
        key: input.KeyCode,
        modifiers: input.Modifiers,
    };

    pub const Scroll = struct {
        x: f32,
        y: f32,
        delta_y: f32,
    };

    pub fn format(self: Action, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .pointer => |pointer| try writer.print("{t} ({d:.2}, {d:.2}) clicks={d}", .{
                pointer.kind,
                pointer.x,
                pointer.y,
                pointer.click_count,
            }),
            .key => |chord| try writer.print("key {t}{s}{s}{s}", .{
                chord.key,
                if (chord.modifiers.shift) " +shift" else "",
                if (chord.modifiers.ctrl) " +ctrl" else "",
                if (chord.modifiers.alt) " +alt" else "",
            }),
            .text => |text| try writer.print("text \"{s}\"", .{text}),
            .compose => |text| try writer.print("compose \"{s}\"", .{text}),
            .scroll => |scroll| try writer.print("scroll ({d:.2}, {d:.2}) by {d}", .{
                scroll.x,
                scroll.y,
                scroll.delta_y,
            }),
            .wait_ns => |gap_ns| try writer.print("wait {d} ns", .{gap_ns}),
            .tick_main => try writer.writeAll("tickMain"),
            .present => try writer.writeAll("presentBuilt"),
        }
    }
};

const ActionKind = std.meta.Tag(Action);

const kind_count = std.enums.values(ActionKind).len;

/// One seed's action mix, drawn from its first bytes (swarm testing, as in
/// TigerBeetle's VOPR). A uniform mix keeps every seed near the initial state;
/// a skewed one goes deep in one direction: a seed that mostly types and
/// clicks the first records fills the list, one that rarely presents holds
/// frames in flight, and one that mostly scrolls walks a long list.
pub const Swarm = struct {
    /// Relative weight of each action kind, by tag value; 0 disables it.
    kind_weights: [kind_count]u32,
    kind_weight_total: u32,
    /// Percent of pointer and scroll actions aimed only at records that can
    /// change state: a click or key handler, focus, or a scroll box.
    interactive_percent: u32,
    /// Pointer and scroll targets are drawn uniformly from the first this
    /// many candidates in tree order, or all of them when 0. A short prefix
    /// keeps clicking the first controls: todo's draft and Add, so the list
    /// fills.
    target_prefix_count: u32,
    /// Percent of pointer actions that click rather than move.
    click_percent: u32,

    /// Most weight one action kind can draw.
    const kind_weight_max: u32 = 16;
    const interactive_percent_choices = [_]u32{ 0, 50, 90 };
    const target_prefix_count_choices = [_]u32{ 2, 3, 5, 8, 0 };
    const click_percent_choices = [_]u32{ 25, 50, 90 };
    /// Smith choices `generate` makes.
    const choice_count = 2 * kind_count + 3;

    pub fn generate(smith: *Smith) Swarm {
        var swarm: Swarm = undefined;
        swarm.kind_weight_total = 0;
        for (std.enums.values(ActionKind)) |kind| {
            // A quarter of kinds are off for the seed. `tickMain` and
            // `presentBuilt` stay on, so frames always move eventually.
            const off = choose(smith, 4, "kind off") == 0;
            const weight = 1 + choose(smith, kind_weight_max, "kind weight");
            const required = kind == .tick_main or kind == .present;
            swarm.kind_weights[@backingInt(kind)] = if (off and !required) 0 else weight;
            swarm.kind_weight_total += swarm.kind_weights[@backingInt(kind)];
        }
        swarm.interactive_percent = interactive_percent_choices[
            choose(smith, interactive_percent_choices.len, "interactive")
        ];
        swarm.target_prefix_count = target_prefix_count_choices[
            choose(smith, target_prefix_count_choices.len, "target prefix")
        ];
        swarm.click_percent = click_percent_choices[
            choose(smith, click_percent_choices.len, "click percent")
        ];
        assert(swarm.kind_weights[@backingInt(ActionKind.tick_main)] > 0);
        assert(swarm.kind_weight_total <= kind_count * kind_weight_max);
        return swarm;
    }

    fn chooseKind(self: *const Swarm, smith: *Smith) ActionKind {
        assert(self.kind_weight_total > 0);
        var remaining = choose(smith, self.kind_weight_total, "kind");
        for (std.enums.values(ActionKind)) |kind| {
            const weight = self.kind_weights[@backingInt(kind)];
            if (remaining < weight) return kind;
            remaining -= weight;
        }
        unreachable;
    }

    pub fn format(self: Swarm, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (std.enums.values(ActionKind)) |kind| {
            try writer.print("{t}={d} ", .{ kind, self.kind_weights[@backingInt(kind)] });
        }
        try writer.print("interactive={d}% prefix={d} click={d}%", .{
            self.interactive_percent,
            self.target_prefix_count,
            self.click_percent,
        });
    }
};

/// `Model` is the app's reference model (see `vopr_todo_model.zig`): it is
/// told every input action, brackets every `tickMain`, and checks the app's
/// state after every step.
pub fn Vopr(comptime App: type, comptime Model: type) type {
    return struct {
        driver: Driver,
        model: Model,
        /// The highest `rendered().frame_number` seen; it must never drop.
        frame_number_rendered: u64,
        /// Rounds the last `quiesce` ran, for the CLI's summary.
        quiescence_round_count: u32,
        /// Rolling hash of every frame dump the renderer was asked to draw.
        dump_hasher: std.hash.Wyhash,
        /// Backing for the action being generated; the queue copies it.
        text_bytes: [text_bytes_action_max]u8,
        /// The current epoch's action mix.
        swarm: Swarm,
        /// Actions generated so far, which sets the epochs.
        action_count: u32,

        const Self = @This();
        const Driver = core.CoreDriver(App);

        /// Initialize in place (the app must not move), draw the seed's
        /// action mix from `smith`, then settle the first frame so pointer
        /// actions have hit records to aim at.
        pub noinline fn initInPlace(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            smith: *Smith,
        ) !void {
            // Edit shortcuts use Ctrl on every host, so a seed replays anywhere.
            internals.text_engine.uses_cmd = false;
            const trace = trace_mod.Trace{
                .name = "vopr",
                .width = @floatFromInt(App.width),
                .height = @floatFromInt(App.height),
                .scale_factor = scale_factor,
                .steps = &.{},
            };
            try self.driver.initInPlace(gpa, io, &trace);
            self.frame_number_rendered = 0;
            self.quiescence_round_count = 0;
            self.dump_hasher = .init(0);
            self.text_bytes = @splat(0);
            self.swarm = .generate(smith);
            self.action_count = 0;
            self.model.init();
            assert(self.driver.now_ns == 0);
            assert(self.driver.renderer.draw_count == 0);
            self.quiesce();
            assert(self.driver.app.window.rendered().frame_number > 0);
        }

        pub fn deinit(self: *Self) void {
            assert(!self.window().frame_in_flight.load(.acquire));
            self.driver.deinit();
        }

        pub fn step(self: *Self, smith: *Smith) void {
            self.perform(self.generate(smith));
        }

        /// Run `action` and check the harness invariants after it.
        pub fn perform(self: *Self, action: Action) void {
            switch (action) {
                .pointer, .key, .text, .compose, .scroll => self.model.queue(action),
                .wait_ns, .tick_main, .present => {},
            }
            switch (action) {
                .pointer => |pointer| self.deliverPointer(pointer),
                .key => |chord| {
                    self.deliver(.{ .key_down = keyEvent(chord) });
                    self.deliver(.{ .key_up = keyEvent(chord) });
                },
                .text => |text| {
                    assert(text.len > 0);
                    self.deliver(.{ .text_input = .{ .text = text } });
                },
                .compose => |text| self.deliver(.{ .composition = .{ .text = text } }),
                .scroll => |scroll| self.deliver(.{ .scroll = .{
                    .position = .{ .x = scroll.x, .y = scroll.y },
                    .delta = .{ .x = 0, .y = scroll.delta_y },
                    .modifiers = .{},
                } }),
                .wait_ns => |gap_ns| self.driver.now_ns += gap_ns,
                .tick_main => self.tickMain(),
                .present => self.present(),
            }
            self.check();
        }

        /// The next action. Input that would overflow the queue's events or
        /// text bytes before the next drain becomes a `tickMain`, and so does
        /// a present with no frame in flight: both keep the run in budget.
        pub fn generate(self: *Self, smith: *Smith) Action {
            if (self.action_count > 0 and self.action_count % swarm_epoch_step_count == 0) {
                self.swarm = .generate(smith);
            }
            self.action_count += 1;
            const kind = self.swarm.chooseKind(smith);
            const in_flight = self.window().frame_in_flight.load(.acquire);
            return switch (kind) {
                .pointer => if (self.queueHasRoom(pointer_event_count_max, 0))
                    .{ .pointer = self.generatePointer(smith) }
                else
                    .tick_main,
                .key => if (self.queueHasRoom(2, 0)) .{ .key = .{
                    .key = key_choices[choose(smith, key_choices.len, "key")],
                    .modifiers = modifier_choices[
                        choose(smith, modifier_choices.len, "modifiers")
                    ],
                } } else .tick_main,
                .text => if (self.queueHasRoom(1, text_bytes_action_max))
                    .{ .text = self.generateText(smith, 1) }
                else
                    .tick_main,
                .compose => if (self.queueHasRoom(1, text_bytes_action_max))
                    .{ .compose = self.generateText(smith, 0) }
                else
                    .tick_main,
                .scroll => if (self.queueHasRoom(1, 0))
                    .{ .scroll = self.generateScroll(smith) }
                else
                    .tick_main,
                .wait_ns => .{ .wait_ns = gap_ns_choices[
                    choose(smith, gap_ns_choices.len, "gap")
                ] },
                .tick_main => .tick_main,
                .present => if (in_flight) .present else .tick_main,
            };
        }

        /// Run `tickMain` and present until nothing is requested, in flight,
        /// or awaiting a flip, at a fixed clock so no deadline fires.
        pub fn quiesce(self: *Self) void {
            const win = self.window();
            var round: u32 = 0;
            while (round < quiescence_round_max) : (round += 1) {
                if (win.frame_in_flight.load(.acquire)) self.present();
                if (!win.render_requested and !win.awaiting_flip) break;
                self.tickMain();
                self.check();
            }
            assert(round <= quiescence_round_max);
            self.quiescence_round_count = round;
            const in_flight = win.frame_in_flight.load(.acquire);
            if (win.render_requested or in_flight or win.awaiting_flip) {
                std.debug.panic("vopr: no quiescence after {d} rounds: render_requested " ++
                    "{}, frame_in_flight {}, awaiting_flip {} (frame {d}, {d} draws)", .{
                    quiescence_round_max,
                    win.render_requested,
                    in_flight,
                    win.awaiting_flip,
                    self.frame_number_rendered,
                    self.driver.renderer.draw_count,
                });
            }
            assert(win.phase == .idle);
            assert(win.render_phase == .idle);
        }

        pub fn summary(self: *Self, step_count: u32) Summary {
            assert(self.window().phase == .idle);
            return .{
                .step_count = step_count,
                .quiescence_round_count = self.quiescence_round_count,
                .frame_number = self.frame_number_rendered,
                .draw_count = self.driver.renderer.draw_count,
                .dump_hash = self.dump_hasher.final(),
            };
        }

        fn window(self: *Self) *Window {
            return &self.driver.app.window;
        }

        fn deliver(self: *Self, event: input.InputEvent) void {
            assert(self.window().phase == .idle);
            assert(self.window().queue.room() > 0);
            self.driver.deliver(event);
        }

        /// Whether `event_count` more events and `text_bytes` more bytes of
        /// text fit before the next drain, and the model can record one more
        /// action: the queue folds moves and scrolls, the model does not.
        fn queueHasRoom(self: *Self, event_count: u32, text_bytes: u32) bool {
            assert(event_count > 0);
            const queue = &self.window().queue;
            assert(queue.text_len <= queue.text_bytes.len);
            const text_room: u64 = queue.text_bytes.len - queue.text_len;
            if (self.model.pendingRoom() == 0) return false;
            return queue.room() >= event_count and text_room >= text_bytes;
        }

        fn tickMain(self: *Self) void {
            const win = self.window();
            self.model.beginDrain(win);
            const published = tick.tickMain(&self.driver.app, win, self.driver.now_ns);
            if (published) assert(win.frame_in_flight.load(.acquire));
            self.model.endDrain(win, published);
            // Todo opens no file dialog, so every drain empties the queue.
            if (win.queue.count != 0) {
                std.debug.panic("vopr: {d} events left queued after tickMain", .{
                    win.queue.count,
                });
            }
        }

        /// The render side: pack and draw the frame in flight, then fold the
        /// renderer's text dump (not raw packed buffers, which hold padding
        /// and addresses) into the rolling hash.
        fn present(self: *Self) void {
            const win = self.window();
            const draw_count = self.driver.renderer.draw_count;
            assert(win.frame_in_flight.load(.acquire));
            tick.presentBuilt(win);
            assert(self.driver.renderer.draw_count == draw_count + 1);
            const dump = self.driver.renderer.frameDump();
            const dump_len: u64 = dump.len;
            self.dump_hasher.update(std.mem.asBytes(&dump_len));
            self.dump_hasher.update(dump);
        }

        /// Invariants between actions, beyond the core's own assertions.
        fn check(self: *Self) void {
            const win = self.window();
            assert(win.phase == .idle);
            const frame_number = win.rendered().frame_number;
            if (frame_number < self.frame_number_rendered) {
                std.debug.panic("vopr: rendered frame number went from {d} to {d}", .{
                    self.frame_number_rendered,
                    frame_number,
                });
            }
            self.frame_number_rendered = frame_number;
            self.model.check(&self.driver.app.state, self.action_count);
            if (win.frame_in_flight.load(.acquire)) {
                // Published frames are flipped only after they are presented.
                assert(win.awaiting_flip);
            } else {
                if (win.render_phase != .idle) {
                    std.debug.panic("vopr: render phase {t} with no frame in flight", .{
                        win.render_phase,
                    });
                }
            }
        }

        fn deliverPointer(self: *Self, pointer: Action.Pointer) void {
            const position: input.MouseEvent = .{
                .position = .{ .x = pointer.x, .y = pointer.y },
                .button = .left,
                .click_count = 0,
                .modifiers = .{},
            };
            self.deliver(.{ .mouse_moved = position });
            if (pointer.kind == .move) return;
            var press = position;
            press.click_count = pointer.click_count;
            self.deliver(.{ .mouse_down = press });
            self.deliver(.{ .mouse_up = press });
        }

        fn generatePointer(self: *Self, smith: *Smith) Action.Pointer {
            const point = self.generatePoint(smith);
            const click = choose(smith, 100, "pointer kind") < self.swarm.click_percent;
            return .{
                .kind = if (click) .click else .move,
                .x = point.x,
                .y = point.y,
                .click_count = 1 + choose(smith, 2, "click count"),
            };
        }

        /// A rank in [0, candidate_count), uniform over the seed's prefix.
        fn targetRank(self: *const Self, smith: *Smith, candidate_count: u32) u32 {
            assert(candidate_count > 0);
            const prefix_count = self.swarm.target_prefix_count;
            const count = if (prefix_count == 0)
                candidate_count
            else
                @min(prefix_count, candidate_count);
            const rank = choose(smith, count, "target");
            assert(rank < candidate_count);
            return rank;
        }

        /// A wheel step: a pixel, a line, or a page, either way.
        fn generateScroll(self: *Self, smith: *Smith) Action.Scroll {
            const delta_choices = [_]f32{ -400, -40, -1, 1, 40, 400 };
            const point = self.generatePoint(smith);
            return .{
                .x = point.x,
                .y = point.y,
                .delta_y = delta_choices[choose(smith, delta_choices.len, "scroll delta")],
            };
        }

        /// A point of a rendered hit record (its centre, an edge, or any
        /// point inside), within the window; anywhere when there is none.
        fn generatePoint(self: *Self, smith: *Smith) Point {
            const win = self.window();
            const frame = win.rendered();
            const hits = frame.hits[0..frame.hit_count];
            const interactive_only =
                choose(smith, 100, "interactive only") < self.swarm.interactive_percent;
            const candidate_count = countTargets(hits, interactive_only);
            const target: records.Rect = if (candidate_count == 0) .{
                .x = 0,
                .y = 0,
                .width = win.width,
                .height = win.height,
            } else hits[
                nthTarget(hits, interactive_only, self.targetRank(smith, candidate_count))
            ].bounds;
            const point = pointIn(smith, target);
            return .{
                .x = std.math.clamp(point.x, 0, win.width),
                .y = std.math.clamp(point.y, 0, win.height),
            };
        }

        /// `unit_count_min` or more units of `text_alphabet`, written into
        /// `text_bytes`; the slice lives until the next generated action.
        fn generateText(self: *Self, smith: *Smith, unit_count_min: u32) []const u8 {
            assert(unit_count_min <= 1);
            const unit_count = unit_count_min +
                choose(smith, text_unit_count_max + 1 - unit_count_min, "text length");
            assert(unit_count <= text_unit_count_max);
            var len: u32 = 0;
            var unit_index: u32 = 0;
            while (unit_index < unit_count) : (unit_index += 1) {
                const unit = text_alphabet[choose(smith, text_alphabet.len, "text unit")];
                assert(len + unit.len <= self.text_bytes.len);
                @memcpy(self.text_bytes[len..][0..unit.len], unit);
                len += @intCast(unit.len);
            }
            assert(std.unicode.utf8ValidateSlice(self.text_bytes[0..len]));
            return self.text_bytes[0..len];
        }
    };
}

/// A key event with no characters, as the goldens' traces send. Never the
/// debugger toggle, whose overlay reads the real clock.
fn keyEvent(chord: Action.Chord) input.KeyEvent {
    const event: input.KeyEvent = .{
        .key = chord.key,
        .modifiers = chord.modifiers,
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = false,
    };
    assert(!internals.debugger.isToggle(&event));
    assert(event.key != .unknown);
    return event;
}

const Point = struct { x: f32, y: f32 };

/// Whether a click, key, or wheel on `record` can change state.
fn isInteractive(record: *const records.HitRecord) bool {
    if (record.on_click != records.index_none) return true;
    if (record.on_key != records.index_none) return true;
    return record.focusable or record.scroll;
}

fn countTargets(hits: []const records.HitRecord, interactive_only: bool) u32 {
    if (!interactive_only) return @intCast(hits.len);
    var count: u32 = 0;
    for (hits) |*record| {
        if (isInteractive(record)) count += 1;
    }
    assert(count <= hits.len);
    return count;
}

/// The index in `hits` of the `rank`th target, counting from 0.
fn nthTarget(hits: []const records.HitRecord, interactive_only: bool, rank: u32) u32 {
    assert(rank < hits.len);
    if (!interactive_only) return rank;
    var seen: u32 = 0;
    for (hits, 0..) |*record, index| {
        if (!isInteractive(record)) continue;
        if (seen == rank) return @intCast(index);
        seen += 1;
    }
    unreachable;
}

/// A point of `bounds`: its centre, a point on one of its four edges (the
/// right and bottom edges are one past the box), or a point inside.
fn pointIn(smith: *Smith, bounds: records.Rect) Point {
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    const fraction_x = fraction(smith);
    const fraction_y = fraction(smith);
    const inside: Point = .{
        .x = bounds.x + fraction_x * bounds.width,
        .y = bounds.y + fraction_y * bounds.height,
    };
    return switch (choose(smith, 6, "point")) {
        0 => .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 },
        1 => .{ .x = bounds.x, .y = inside.y },
        2 => .{ .x = bounds.x + bounds.width, .y = inside.y },
        3 => .{ .x = inside.x, .y = bounds.y },
        4 => .{ .x = inside.x, .y = bounds.y + bounds.height },
        5 => inside,
        else => unreachable,
    };
}

/// A fraction in [0, 1] in thousandths, so points land on exact edges too.
fn fraction(smith: *Smith) f32 {
    const thousandths = choose(smith, 1001, "fraction");
    assert(thousandths <= 1000);
    return @as(f32, @floatFromInt(thousandths)) / 1000;
}

/// A choice in [0, count). Each choice reads one full `u64` and reduces it:
/// `Smith` maps a value outside a ranged read's weights to the range's
/// minimum, so with PRNG bytes as input a ranged read would almost always
/// return 0. `site` names the choice, giving the fuzzer one id per site.
fn choose(smith: *Smith, count: u64, comptime site: []const u8) u32 {
    assert(count > 0);
    assert(count <= std.math.maxInt(u32));
    const hash = comptime std.hash.Fnv1a_32.hash(site);
    const choice: u32 = @intCast(smith.valueWithHash(u64, hash) % count);
    assert(choice < count);
    return choice;
}

fn fuzzTodo(_: void, smith: *Smith) anyerror!void {
    const V = Vopr(todo.App, TodoModel);
    const vopr = try std.testing.allocator.create(V);
    defer std.testing.allocator.destroy(vopr);
    try vopr.initInPlace(std.testing.allocator, std.testing.io, smith);
    defer vopr.deinit();

    const step_count = 1 + choose(smith, step_count_fuzz_max, "step count");
    var step_index: u32 = 0;
    while (step_index < step_count) : (step_index += 1) vopr.step(smith);
    vopr.quiesce();
}

test "fuzz: todo vopr" {
    // Goal: the fuzz target runs under `zig build test`. Methodology: outside
    // fuzz mode `std.testing.fuzz` replays only the corpus, so seed it with
    // PRNG inputs long enough for a few hundred actions each.
    const corpus_count = 4;
    const bytes = try std.testing.allocator.alloc(
        u8,
        corpus_count * step_count_fuzz_max * bytes_per_action_max,
    );
    defer std.testing.allocator.free(bytes);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    prng.random().bytes(bytes);
    var corpus: [corpus_count][]const u8 = undefined;
    const input_len = @divExact(bytes.len, corpus_count);
    for (&corpus, 0..) |*entry, index| entry.* = bytes[index * input_len ..][0..input_len];
    try std.testing.fuzz({}, fuzzTodo, .{ .corpus = &corpus });
}

test "two instances fed the same bytes draw the same frames" {
    // Goal: the seed CLI's determinism self-check passes, and a run makes
    // progress. Methodology: run one seed through `runPaired`, which panics
    // on the first differing frame, and require frames beyond the first.
    const step_count = 300;
    const byte_count = bytes_swarm + step_count * bytes_per_action_max;
    const bytes = try std.testing.allocator.alloc(u8, byte_count);
    defer std.testing.allocator.free(bytes);

    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(bytes);
    const options: RunOptions = .{ .step_count = step_count, .verbose = false };
    const summary = try runPaired(
        todo.App,
        TodoModel,
        std.testing.allocator,
        std.testing.io,
        bytes,
        options,
    );
    try std.testing.expectEqual(@as(u32, step_count), summary.step_count);
    try std.testing.expect(summary.frame_number > 10);
    try std.testing.expect(summary.draw_count >= summary.frame_number);
}
