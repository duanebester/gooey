//! VOPR: deterministic simulation testing of the core, after TigerBeetle's.
//!
//! One generator, driven by `std.testing.Smith`, turns bytes into a stream of
//! actions against a headless app on the goldens' `CoreDriver`: pointer
//! clicks, moves, and held presses of the left, right, and middle buttons
//! (overlapping in any order, never a press of a button that is down) aimed
//! at the rendered frame's hit records, held-button
//! drag gestures (a press mostly on a draggable, moves onto drop targets,
//! outside them, and back, then a release or none), wheel scrolls, keys,
//! committed and composed text, clock gaps, window resizes (size and scale),
//! and the two sides of a tick
//! (`tickMain` and `presentBuilt`) driven separately, so a frame stays in
//! flight while input keeps arriving. The same generator serves `zig build
//! vopr -- [--app NAME] [seed]`, whose bytes come from a seeded PRNG, and a
//! `std.testing.fuzz` target per app, whose bytes come from the fuzzer. Each
//! app (`Workload`) has a reference model, which lists the action kinds its
//! swarm draws: todo's never drags, so its seeds replay as before.
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
//! the render side is idle with no frame in flight; on every new rendered
//! frame, the model-free invariants of `vopr_invariants.zig`; and every
//! `Swarm.rebuild_period` actions, that a current frame rebuilt with no input
//! and no clock advance draws the same dump (`checkStableRebuild`). Each run
//! ends with a
//! bounded quiescence loop that must settle. The seed CLI also runs two
//! instances side by side on the same bytes and requires identical frame
//! dumps after every action (determinism).
//!
//! Resource sketch, per action: at most 5 queued events (a click that first
//! releases a held gesture's button) and 16 bytes of text
//! (`text_bytes_action_max`); per `tickMain`, at most the queue's capacity,
//! which the generator never exceeds. Per run: one app and one 64 KiB
//! `NullRenderer` per instance, reserved before the first action, and
//! `bytes_cli` Smith bytes for the CLI. A 12,000-step CLI run takes under a
//! second in Debug; frames over a full list dominate.

const std = @import("std");
const gooey = @import("gooey");
const todo = @import("todo_example");
const drag_drop = @import("drag_drop_example");
const virtual_list = @import("virtual_list_example");
const core = @import("goldens/core.zig");
const TodoModel = @import("vopr_todo_model.zig").TodoModel;
const DragDropModel = @import("vopr_drag_drop_model.zig").DragDropModel;
const VirtualListModel = @import("vopr_virtual_list_model.zig").VirtualListModel;
const invariants = @import("vopr_invariants.zig");
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
const bytes_swarm: u32 = Swarm.choice_count_max * @sizeOf(u64);
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
/// Events one pointer action queues: a move, a press, and a release. A
/// gesture step queues at most two: a move and a press or release.
const pointer_event_count_max: u32 = 3;
/// Events a click queues first when it releases a held gesture's button: a
/// held move and the release.
const release_event_count: u32 = 2;
const button_count = std.enums.values(input.MouseButton).len;
/// Held moves in one run of a gesture before it releases or plans more.
const drag_move_count_max: u32 = 8;
/// Scale factor of every simulated window, as the goldens use.
const scale_factor: f32 = 2;
/// The NullRenderer's dump capacity, which a stable rebuild copies.
const dump_bytes_max: u32 = gooey.testing.test_backend.null_renderer_dump_bytes_max;

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

/// The apps the VOPR drives, each with its reference model; `--app` names
/// one, and todo is the default.
pub const Workload = enum {
    todo,
    drag_drop,
    virtual_list,

    fn App(comptime workload: Workload) type {
        return switch (workload) {
            .todo => todo.App,
            .drag_drop => drag_drop.App,
            .virtual_list => virtual_list.App,
        };
    }

    fn Model(comptime workload: Workload) type {
        return switch (workload) {
            .todo => TodoModel,
            .drag_drop => DragDropModel,
            .virtual_list => VirtualListModel,
        };
    }
};

/// `zig build vopr -- [--app NAME] [seed] [--verbose]`: run one seed against
/// an app. With no seed, a random one is drawn and printed, so any run can be
/// replayed.
pub fn main(init: std.process.Init) !void {
    const options = parseArgs(init.minimal.args.vector) orelse {
        std.debug.print("usage: vopr [--app todo|drag_drop|virtual_list] [seed] " ++
            "[--verbose] [--skip-scrollbar-second-press]\n", .{});
        return error.InvalidArguments;
    };
    const seed = options.seed orelse seed: {
        var random_seed: u64 = 0;
        init.io.random(std.mem.asBytes(&random_seed));
        break :seed random_seed;
    };
    switch (options.workload) {
        inline else => |workload| try runCli(workload, init.gpa, init.io, seed, &options),
    }
}

fn runCli(
    comptime workload: Workload,
    gpa: std.mem.Allocator,
    io: std.Io,
    seed: u64,
    options: *const CliOptions,
) !void {
    const name = @tagName(workload);
    std.debug.print("vopr: {s} seed {d}, {d} steps\n", .{ name, seed, step_count_cli });

    const bytes = try gpa.alloc(u8, bytes_cli);
    defer gpa.free(bytes);

    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(bytes);
    const Model = workload.Model();
    const result = try runPaired(workload.App(), Model, gpa, io, bytes, .{
        .step_count = step_count_cli,
        .verbose = options.verbose,
        .skip_scrollbar_second_press = options.skip_scrollbar_second_press,
    });
    const summary = result.summary;
    std.debug.print("vopr: {s} seed {d} passed: {d} steps, quiesced in {d} rounds, " ++
        "frame {d}, {d} draws, dump hash {x:0>16}, {d} stable rebuilds\n", .{
        name,
        seed,
        summary.step_count,
        summary.quiescence_round_count,
        summary.frame_number,
        summary.draw_count,
        summary.dump_hash,
        summary.stable_rebuild_count,
    });
    // Todo's model keeps no stats, so its output stays one line.
    if (@sizeOf(Model.Stats) > 0) {
        std.debug.print("vopr: {s} seed {d} stats: {f}\n", .{ name, seed, result.stats });
    }
}

const CliOptions = struct {
    workload: Workload,
    seed: ?u64,
    verbose: bool,
    skip_scrollbar_second_press: bool,
};

/// Null on an argument it does not understand.
fn parseArgs(args: []const [*:0]const u8) ?CliOptions {
    assert(args.len >= 1);
    var options: CliOptions = .{
        .workload = .todo,
        .seed = null,
        .verbose = false,
        .skip_scrollbar_second_press = false,
    };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-scrollbar-second-press")) {
            options.skip_scrollbar_second_press = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--app")) {
            index += 1;
            if (index == args.len) return null;
            const value = std.mem.span(args[index]);
            options.workload = std.meta.stringToEnum(Workload, value) orelse return null;
        } else {
            if (options.seed != null) return null;
            options.seed = std.fmt.parseInt(u64, arg, 0) catch return null;
        }
    }
    assert(index == args.len);
    return options;
}

pub const Summary = struct {
    step_count: u32,
    /// Rounds the last `quiesce` ran before nothing was left to do.
    quiescence_round_count: u32,
    frame_number: u64,
    draw_count: u64,
    dump_hash: u64,
    /// Rebuilds with no input that `checkStableRebuild` compared.
    stable_rebuild_count: u32,
};

/// What a run reports: the frames it drew, and the model's own counts.
pub fn Result(comptime Model: type) type {
    return struct { summary: Summary, stats: Model.Stats };
}

pub const RunOptions = struct {
    step_count: u32,
    /// Print each action before it runs, so a failing seed shows its steps.
    verbose: bool,
    /// Temporary: `Vopr.skip_scrollbar_second_press`, a known finding.
    skip_scrollbar_second_press: bool = false,
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
) !Result(Model) {
    assert(options.step_count > 0);
    const V = Vopr(App, Model);
    var smith_first: Smith = .{ .in = bytes };
    var smith_second: Smith = .{ .in = bytes };
    const first = try gpa.create(V);
    defer gpa.destroy(first);
    try first.initInPlace(gpa, io, &smith_first);
    first.skip_scrollbar_second_press = options.skip_scrollbar_second_press;
    defer first.deinit();

    const second = try gpa.create(V);
    defer gpa.destroy(second);
    try second.initInPlace(gpa, io, &smith_second);
    second.skip_scrollbar_second_press = options.skip_scrollbar_second_press;
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
    return .{ .summary = first.summary(step_index), .stats = first.model.stats() };
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
    /// One step of a held-button gesture: a press, a held move, or the
    /// release. Steps of one gesture interleave with every other action,
    /// so a drag stays open across ticks, presents, and clock gaps. After
    /// the kinds todo has always drawn, so they keep their tag values.
    drag: Gesture,
    /// The platform resized the window: a new logical size and scale, as
    /// `window.resized`. Last, so the other kinds keep their tag values.
    resize: Resize,

    pub const Resize = struct {
        width: f32,
        height: f32,
        scale_factor: f32,
    };

    pub const Gesture = struct {
        kind: enum { press, move, release },
        button: input.MouseButton,
        x: f32,
        y: f32,
        /// A press of a button a `.pointer` press holds releases it first.
        releases_held: bool,
    };

    /// A click (press and release), a move, or one half of a click: a
    /// press that holds the button across other actions, or the release of
    /// a held button. Holding lets buttons overlap in any order, as every
    /// platform delivers them: left down, right down, left up, right up.
    pub const Pointer = struct {
        kind: enum { click, move, press, release },
        button: input.MouseButton,
        x: f32,
        y: f32,
        click_count: u32,
        /// A click of a button that is held (by a gesture or a press)
        /// releases it first, as no platform presses a button that is
        /// already down.
        releases_held: bool,
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
            .pointer => |pointer| try writer.print("{t} {t} ({d:.2}, {d:.2}) clicks={d}{s}", .{
                pointer.kind,
                pointer.button,
                pointer.x,
                pointer.y,
                pointer.click_count,
                if (pointer.releases_held) " (releases held)" else "",
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
            .drag => |gesture| try writer.print("drag {t} {t} ({d:.2}, {d:.2}){s}", .{
                gesture.kind,
                gesture.button,
                gesture.x,
                gesture.y,
                if (gesture.releases_held) " (releases held)" else "",
            }),
            .resize => |size| try writer.print("resize {d}x{d}@{d}", .{
                size.width,
                size.height,
                size.scale_factor,
            }),
        }
    }
};

pub const ActionKind = std.meta.Tag(Action);

const kind_count = std.enums.values(ActionKind).len;

/// One seed's action mix, drawn from its first bytes (swarm testing, as in
/// TigerBeetle's VOPR). A uniform mix keeps every seed near the initial state;
/// a skewed one goes deep in one direction: a seed that mostly types and
/// clicks the first records fills the list, one that rarely presents holds
/// frames in flight, and one that mostly scrolls walks a long list.
pub const Swarm = struct {
    /// Relative weight of each action kind, by tag value; 0 disables it.
    kind_weights: [kind_count]u32,
    /// The kinds the model lists (`Model.action_kinds`), for `format`.
    kinds: []const ActionKind,
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
    /// Actions between stable-rebuild checks (`checkStableRebuild`).
    rebuild_period: u32,
    /// Which mouse buttons pointer and gesture presses use.
    button_mix: ButtonMix,
    /// Percent of pointer actions that press or release a held button
    /// instead of clicking or moving.
    hold_percent: u32,

    /// Left only; mostly left (8 in 10), with right and middle; or each
    /// button a third of the time.
    pub const ButtonMix = enum { left_only, mostly_left, even };

    /// Most weight one action kind can draw.
    const kind_weight_max: u32 = 16;
    const interactive_percent_choices = [_]u32{ 0, 50, 90 };
    const target_prefix_count_choices = [_]u32{ 2, 3, 5, 8, 0 };
    const click_percent_choices = [_]u32{ 25, 50, 90 };
    const rebuild_period_choices = [_]u32{ 7, 31, 127 };
    const hold_percent_choices = [_]u32{ 0, 10, 30 };
    const button_mix_count = std.enums.values(ButtonMix).len;
    /// Most Smith choices `generate` makes: two per kind a model lists.
    const choice_count_max = 2 * kind_count + 6;

    /// Weights for the kinds the model lists, in its order; the rest stay
    /// off, so a model's seeds replay unchanged when another app's kind is
    /// added.
    pub fn generate(smith: *Smith, comptime kinds: []const ActionKind) Swarm {
        comptime {
            assert(kinds.len <= kind_count);
            assert(std.mem.indexOfScalar(ActionKind, kinds, .tick_main) != null);
            assert(std.mem.indexOfScalar(ActionKind, kinds, .present) != null);
        }
        var swarm: Swarm = undefined;
        swarm.kind_weights = @splat(0);
        swarm.kinds = kinds;
        swarm.kind_weight_total = 0;
        inline for (kinds) |kind| {
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
        swarm.rebuild_period = rebuild_period_choices[
            choose(smith, rebuild_period_choices.len, "rebuild period")
        ];
        swarm.button_mix = @fromBackingInt(@intCast(choose(smith, button_mix_count, "button mix")));
        swarm.hold_percent = hold_percent_choices[
            choose(smith, hold_percent_choices.len, "hold percent")
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

    /// A button from the mix; always one choice, so the mix does not shift
    /// the bytes that follow.
    fn chooseButton(self: *const Swarm, smith: *Smith) input.MouseButton {
        const roll = choose(smith, 100, "button");
        const left_percent: u32, const right_percent: u32 = switch (self.button_mix) {
            .left_only => .{ 100, 0 },
            .mostly_left => .{ 80, 10 },
            .even => .{ 34, 33 },
        };
        assert(left_percent + right_percent <= 100);
        if (roll < left_percent) return .left;
        if (roll < left_percent + right_percent) return .right;
        return .middle;
    }

    pub fn format(self: Swarm, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.kinds) |kind| {
            try writer.print("{t}={d} ", .{ kind, self.kind_weights[@backingInt(kind)] });
        }
        try writer.print("interactive={d}% prefix={d} click={d}% rebuild every {d} " ++
            "buttons {t} hold={d}%", .{
            self.interactive_percent, self.target_prefix_count, self.click_percent,
            self.rebuild_period,      self.button_mix,          self.hold_percent,
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
        /// The held-button gesture `.drag` steps continue, if any.
        gesture: GestureState,
        /// The mouse buttons the harness holds down.
        held: Held,
        /// Temporary, off unless asked for: never press a second button
        /// while a scrollbar thumb drag may be active (router.zig's
        /// `pressScrollbar` asserts there is none, a known finding), so a
        /// run can go on to find others. Remove it with that fix.
        skip_scrollbar_second_press: bool,
        /// The rendered frame `invariants.checkFrame` last checked.
        frame_number_checked: u64,
        /// The dump of the rendered frame, copied before a stable rebuild.
        rebuild_dump: [dump_bytes_max]u8,
        stable_rebuild_count: u32,

        const Self = @This();

        /// A gesture in progress: its press point, its last point, how
        /// many more moves it makes, and whether it then releases or plans
        /// more moves with the button still held.
        const GestureState = struct {
            held: bool,
            button: input.MouseButton,
            start: Point,
            last: Point,
            move_count: u32,
            release: bool,

            const idle: GestureState = .{
                .held = false,
                .button = .left,
                .start = .{ .x = 0, .y = 0 },
                .last = .{ .x = 0, .y = 0 },
                .move_count = 0,
                .release = false,
            };
        };
        const Driver = core.CoreDriver(App);

        /// Which buttons are down, so the harness never presses a button
        /// that is down or releases one that is up; and which presses the
        /// router has not drained yet.
        const Held = struct {
            down: [button_count]bool,
            undrained: [button_count]bool,

            const none: Held = .{ .down = @splat(false), .undrained = @splat(false) };

            fn isDown(self: *const Held, button: input.MouseButton) bool {
                return self.down[@backingInt(button)];
            }

            fn any(self: *const Held) bool {
                return std.mem.indexOfScalar(bool, &self.down, true) != null;
            }

            fn press(self: *Held, button: input.MouseButton) void {
                assert(!self.isDown(button));
                self.down[@backingInt(button)] = true;
                self.undrained[@backingInt(button)] = true;
            }

            fn release(self: *Held, button: input.MouseButton) void {
                assert(self.isDown(button));
                self.down[@backingInt(button)] = false;
                self.undrained[@backingInt(button)] = false;
            }

            /// Whether another button is down with a press the router has
            /// not seen yet, which may start a thumb drag.
            fn otherUndrained(self: *const Held, button: input.MouseButton) bool {
                for (self.down, self.undrained, 0..) |down, undrained, index| {
                    if (index == @backingInt(button)) continue;
                    if (down and undrained) return true;
                }
                return false;
            }

            fn otherDown(self: *const Held, button: input.MouseButton) bool {
                for (self.down, 0..) |down, index| {
                    if (index != @backingInt(button) and down) return true;
                }
                return false;
            }
        };

        /// Initialize in place (the app must not move), draw the seed's
        /// action mix from `smith`, then settle the first frame so pointer
        /// actions have hit records to aim at.
        pub noinline fn initInPlace(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            smith: *Smith,
        ) !void {
            // Edit shortcuts use Ctrl and a wheel delta grows toward the end
            // on every host, so a seed replays anywhere. Both are
            // process-global: every instance in this process pins them the
            // same way, before its first frame.
            internals.text_engine.uses_cmd = false;
            internals.window.wheel_delta_inverted = false;
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
            self.swarm = .generate(smith, Model.action_kinds);
            self.action_count = 0;
            self.gesture = .idle;
            self.held = .none;
            self.skip_scrollbar_second_press = false;
            self.frame_number_checked = 0;
            self.stable_rebuild_count = 0;
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
                .pointer, .key, .text, .compose, .scroll, .drag, .resize => {
                    self.model.queue(action);
                },
                .wait_ns, .tick_main, .present => {},
            }
            switch (action) {
                .pointer => |pointer| self.deliverPointer(pointer),
                .drag => |gesture| self.deliverGesture(gesture),
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
                .resize => |size| {
                    assert(self.window().queue.room() > 0);
                    self.driver.app.window.queue.push(.{ .window = .{ .resized = .{
                        .width = size.width,
                        .height = size.height,
                        .scale_factor = size.scale_factor,
                    } } });
                },
                .wait_ns => |gap_ns| self.driver.now_ns += gap_ns,
                .tick_main => self.tickMain(),
                .present => self.present(),
            }
            self.check();
            assert(self.swarm.rebuild_period > 0);
            if (self.action_count % self.swarm.rebuild_period == 0) self.checkStableRebuild();
        }

        /// The next action. Input that would overflow the queue's events or
        /// text bytes before the next drain becomes a `tickMain`, and so does
        /// a present with no frame in flight: both keep the run in budget.
        pub fn generate(self: *Self, smith: *Smith) Action {
            if (self.action_count > 0 and self.action_count % swarm_epoch_step_count == 0) {
                self.swarm = .generate(smith, Model.action_kinds);
            }
            self.action_count += 1;
            const kind = self.swarm.chooseKind(smith);
            const in_flight = self.window().frame_in_flight.load(.acquire);
            return switch (kind) {
                .pointer => if (self.queueHasRoom(self.pointerEventCount(), 0))
                    .{ .pointer = self.generatePointer(smith) }
                else
                    .tick_main,
                .drag => if (self.queueHasRoom(self.pointerEventCount(), 0))
                    self.generateGesture(smith)
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
                .resize => if (self.queueHasRoom(1, 0))
                    .{ .resize = generateResize(smith) }
                else
                    .tick_main,
            };
        }

        /// A seeded window size and scale within the profile's framebuffer
        /// (`limits.window`) and the app's minimums: the configured size, the
        /// minimum, the largest the framebuffer takes, or any between.
        fn generateResize(smith: *Smith) Action.Resize {
            const scale_choices = [_]f32{ 1, 1.25, 1.5, 2 };
            const scale = scale_choices[choose(smith, scale_choices.len, "resize scale")];
            const window_limits = App.limits.window;
            return .{
                .width = resizeExtent(smith, .{
                    .configured = App.width,
                    .minimum = App.min_width,
                    .framebuffer_max = window_limits.framebuffer_width_max,
                    .scale_factor = scale,
                }),
                .height = resizeExtent(smith, .{
                    .configured = App.height,
                    .minimum = App.min_height,
                    .framebuffer_max = window_limits.framebuffer_height_max,
                    .scale_factor = scale,
                }),
                .scale_factor = scale,
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
            self.checkStableRebuild();
        }

        /// Stable rebuild. Exact rule: when the rendered frame is current
        /// (nothing in flight or awaiting a flip, no render requested, and
        /// the queue empty) and the build that made it asked for no timed
        /// render (`Window.renderDeadlineNs` is null), a render requested
        /// with no input and no clock advance must draw a dump identical,
        /// byte for byte, to the rendered frame's. A view that changes with
        /// the clock (an animation, a caret blink, a scroll settling, a
        /// first build after a resize reading old bounds) must ask for a
        /// timed render (`cx.requestRenderAfter`, contract §5) or request a
        /// render itself, so those frames are exactly the exempt ones.
        fn checkStableRebuild(self: *Self) void {
            const win = self.window();
            if (win.frame_in_flight.load(.acquire)) return;
            if (win.awaiting_flip or win.render_requested) return;
            if (win.queue.count > 0) return;
            if (win.renderDeadlineNs() != null) return;
            // The last draw is the rendered frame: it was presented, then
            // flipped, and nothing was drawn since.
            const before = self.driver.renderer.frameDump();
            assert(before.len <= self.rebuild_dump.len);
            @memcpy(self.rebuild_dump[0..before.len], before);
            const frame_number = win.rendered().frame_number;
            win.render_requested = true;
            self.tickMain();
            assert(win.frame_in_flight.load(.acquire));
            self.present();
            self.check();
            const after = self.driver.renderer.frameDump();
            const expected = self.rebuild_dump[0..before.len];
            if (!std.mem.eql(u8, expected, after)) {
                invariants.reportDumpDifference(expected, after);
                std.debug.panic("vopr: a rebuild of frame {d} with no input and no clock " ++
                    "advance drew a different dump (action {d})", .{
                    frame_number,
                    self.action_count,
                });
            }
            self.stable_rebuild_count += 1;
        }

        pub fn summary(self: *Self, step_count: u32) Summary {
            assert(self.window().phase == .idle);
            return .{
                .step_count = step_count,
                .quiescence_round_count = self.quiescence_round_count,
                .frame_number = self.frame_number_rendered,
                .draw_count = self.driver.renderer.draw_count,
                .dump_hash = self.dump_hasher.final(),
                .stable_rebuild_count = self.stable_rebuild_count,
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
            self.held.undrained = @splat(false);
            if (published) assert(win.frame_in_flight.load(.acquire));
            self.model.endDrain(win, published);
            // The apps open no file dialog, so every drain empties the queue.
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
            if (frame_number != self.frame_number_checked) {
                invariants.checkFrame(win, win.rendered());
                self.frame_number_checked = frame_number;
            }
            invariants.checkFocusLive(win);
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
                .button = pointer.button,
                .click_count = 0,
                .modifiers = .{},
            };
            var press = position;
            press.click_count = 1;
            if (pointer.releases_held) {
                assert(pointer.kind == .click);
                self.deliver(.{ .mouse_dragged = position });
                self.deliver(.{ .mouse_up = press });
            }
            switch (pointer.kind) {
                .move => self.deliver(.{ .mouse_moved = position }),
                .press => {
                    self.deliver(.{ .mouse_moved = position });
                    self.deliver(.{ .mouse_down = press });
                },
                .release => {
                    self.deliver(.{ .mouse_dragged = position });
                    self.deliver(.{ .mouse_up = press });
                },
                .click => {
                    press.click_count = pointer.click_count;
                    self.deliver(.{ .mouse_moved = position });
                    self.deliver(.{ .mouse_down = press });
                    self.deliver(.{ .mouse_up = press });
                },
            }
        }

        /// A move, a click, or with `Swarm.hold_percent` the press of a
        /// button that is up or the release of one that is down. Releasing
        /// a gesture's button ends the gesture.
        fn generatePointer(self: *Self, smith: *Smith) Action.Pointer {
            const Kind = @FieldType(Action.Pointer, "kind");
            const point = self.generatePoint(smith);
            const click = choose(smith, 100, "pointer kind") < self.swarm.click_percent;
            const button = self.swarm.chooseButton(smith);
            const hold = choose(smith, 100, "hold") < self.swarm.hold_percent;
            const down = self.held.isDown(button);
            const held_kind: Kind = if (down) .release else .press;
            var pointer: Action.Pointer = .{
                .kind = if (hold) held_kind else (if (click) .click else .move),
                .button = button,
                .x = point.x,
                .y = point.y,
                .click_count = 1 + choose(smith, 2, "click count"),
                .releases_held = false,
            };
            const presses = pointer.kind == .press or pointer.kind == .click;
            if (presses and self.secondPressSkipped(button)) pointer.kind = .move;
            switch (pointer.kind) {
                .move => {},
                .press => self.held.press(button),
                .release => self.releaseHeld(button),
                .click => if (down) {
                    pointer.releases_held = true;
                    self.releaseHeld(button);
                },
            }
            return pointer;
        }

        /// A held button goes up; the gesture holding it, if any, ends.
        fn releaseHeld(self: *Self, button: input.MouseButton) void {
            self.held.release(button);
            if (self.gesture.held and self.gesture.button == button) self.gesture = .idle;
        }

        /// With `skip_scrollbar_second_press`, a press of `button` is
        /// skipped while another button is down and may be dragging a
        /// scrollbar thumb: its press is still queued, or a drag is on.
        fn secondPressSkipped(self: *const Self, button: input.MouseButton) bool {
            if (!self.skip_scrollbar_second_press) return false;
            if (!self.held.otherDown(button)) return false;
            if (self.held.otherUndrained(button)) return true;
            return self.driver.app.window.scroll_drag != .root;
        }

        /// The most events the next pointer or gesture action can queue: a
        /// press may release a held button first.
        fn pointerEventCount(self: *const Self) u32 {
            if (self.held.any()) return pointer_event_count_max + release_event_count;
            return pointer_event_count_max;
        }

        /// A press moves there first, as a platform reports the pointer
        /// before its button; a held move is `mouse_dragged`, which the
        /// queue folds only into another held move of the same button.
        fn deliverGesture(self: *Self, gesture: Action.Gesture) void {
            const position: input.MouseEvent = .{
                .position = .{ .x = gesture.x, .y = gesture.y },
                .button = gesture.button,
                .click_count = 0,
                .modifiers = .{},
            };
            var press = position;
            press.click_count = 1;
            switch (gesture.kind) {
                .press => {
                    if (gesture.releases_held) {
                        self.deliver(.{ .mouse_dragged = position });
                        self.deliver(.{ .mouse_up = press });
                    }
                    self.deliver(.{ .mouse_moved = position });
                    self.deliver(.{ .mouse_down = press });
                },
                .move => self.deliver(.{ .mouse_dragged = position }),
                .release => {
                    assert(!gesture.releases_held);
                    self.deliver(.{ .mouse_dragged = position });
                    self.deliver(.{ .mouse_up = press });
                },
            }
        }

        /// The next step of the held-button gesture: a press (mostly on a
        /// draggable), then a run of up to `drag_move_count_max` moves,
        /// then a release, or with a quarter's chance another run of moves
        /// with the button still held, so a drag can stay open for long.
        /// A press that `secondPressSkipped` skips is a `tickMain`.
        fn generateGesture(self: *Self, smith: *Smith) Action {
            const gesture = &self.gesture;
            if (!gesture.held) return self.generateGesturePress(smith);
            assert(self.held.isDown(gesture.button));
            assert(gesture.move_count <= drag_move_count_max);
            const button = gesture.button;
            if (gesture.move_count == 0) {
                if (gesture.release) {
                    const last = gesture.last;
                    self.releaseHeld(button);
                    assert(!gesture.held);
                    return .{ .drag = .{
                        .kind = .release,
                        .button = button,
                        .x = last.x,
                        .y = last.y,
                        .releases_held = false,
                    } };
                }
                gesture.move_count = 1 + choose(smith, drag_move_count_max, "drag moves");
                gesture.release = choose(smith, 4, "drag release") != 0;
            }
            gesture.move_count -= 1;
            gesture.last = self.generateDragPoint(smith, gesture.start);
            return .{ .drag = .{
                .kind = .move,
                .button = button,
                .x = gesture.last.x,
                .y = gesture.last.y,
                .releases_held = false,
            } };
        }

        fn generateGesturePress(self: *Self, smith: *Smith) Action {
            assert(!self.gesture.held);
            const point = self.generatePressPoint(smith);
            const button = self.swarm.chooseButton(smith);
            const move_count = 1 + choose(smith, drag_move_count_max, "drag moves");
            const release = choose(smith, 4, "drag release") != 0;
            if (self.secondPressSkipped(button)) return .tick_main;
            const releases_held = self.held.isDown(button);
            if (releases_held) self.releaseHeld(button);
            self.held.press(button);
            self.gesture = .{
                .held = true,
                .button = button,
                .start = point,
                .last = point,
                .move_count = move_count,
                .release = release,
            };
            return .{ .drag = .{
                .kind = .press,
                .button = button,
                .x = point.x,
                .y = point.y,
                .releases_held = releases_held,
            } };
        }

        /// A press point: on a draggable nine times in ten when the frame
        /// has one, else anywhere `generatePoint` aims.
        fn generatePressPoint(self: *Self, smith: *Smith) Point {
            const frame = self.window().rendered();
            const hits = frame.hits[0..frame.hit_count];
            const on_draggable = choose(smith, 10, "press on draggable") != 0;
            const count = countKind(hits, .draggable);
            if (!on_draggable or count == 0) return self.generatePoint(smith);
            const index = nthKind(hits, .draggable, choose(smith, count, "draggable"));
            return self.clampToWindow(pointIn(smith, hits[index].bounds));
        }

        /// Where a held move goes: onto a drop target, outside every drop
        /// target (above the first), back to the press point, within a few
        /// pixels of it (either side of the click slop), or onto a draggable.
        fn generateDragPoint(self: *Self, smith: *Smith, start: Point) Point {
            const win = self.window();
            const frame = win.rendered();
            const hits = frame.hits[0..frame.hit_count];
            const target_count = countKind(hits, .drop_target);
            switch (choose(smith, 5, "drag target")) {
                0 => if (target_count > 0) {
                    const rank = choose(smith, target_count, "drop target");
                    const index = nthKind(hits, .drop_target, rank);
                    return self.clampToWindow(pointIn(smith, hits[index].bounds));
                },
                1 => if (target_count > 0) {
                    const top = dropTargetTop(hits);
                    if (top >= 1) return .{
                        .x = fraction(smith) * win.width,
                        .y = fraction(smith) * (top - 1),
                    };
                },
                2 => return start,
                3 => {
                    const offsets = [_]f32{ -3, -2, -1, 1, 2, 3 };
                    const offset = offsets[choose(smith, offsets.len, "slop offset")];
                    return self.clampToWindow(.{ .x = start.x + offset, .y = start.y });
                },
                4 => return self.generatePressPoint(smith),
                else => unreachable,
            }
            return self.generatePoint(smith);
        }

        fn clampToWindow(self: *Self, point: Point) Point {
            const win = self.window();
            assert(win.width >= 0);
            assert(win.height >= 0);
            return .{
                .x = std.math.clamp(point.x, 0, win.width),
                .y = std.math.clamp(point.y, 0, win.height),
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
            // Only a model that declares a target reads this choice, so the
            // other apps' seeds replay unchanged.
            if (comptime @hasDecl(Model, "biasTarget")) {
                if (choose(smith, 2, "biased") == 0) {
                    if (Model.biasTarget(self.window())) |bias| {
                        const on_bar = choose(smith, 3, "on scrollbar") == 0;
                        const area = if (on_bar) bias.scrollbar orelse bias.area else bias.area;
                        return self.clampToWindow(pointIn(smith, area));
                    }
                }
            }
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

/// One axis of a seeded resize, in whole logical pixels: the configured
/// extent, the minimum (at least 1), the largest whose physical size fits
/// the framebuffer at `scale_factor`, or any extent between.
fn resizeExtent(smith: *Smith, options: struct {
    configured: u32,
    minimum: u32,
    framebuffer_max: u32,
    scale_factor: f32,
}) f32 {
    assert(options.scale_factor >= 1);
    const framebuffer_max: f32 = @floatFromInt(options.framebuffer_max);
    const extent_max: u32 = @intFromFloat(@floor(framebuffer_max / options.scale_factor));
    const extent_min: u32 = @max(options.minimum, 1);
    assert(extent_min <= extent_max);
    const extent: u32 = switch (choose(smith, 4, "resize extent")) {
        0 => std.math.clamp(options.configured, extent_min, extent_max),
        1 => extent_min,
        2 => extent_max,
        3 => extent_min + choose(smith, extent_max - extent_min + 1, "resize span"),
        else => unreachable,
    };
    assert(extent >= extent_min);
    assert(extent <= extent_max);
    return @floatFromInt(extent);
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

/// Where a model asks pointer, wheel, and drag actions to aim half the time
/// (`Model.biasTarget`): a scroll box and its vertical scrollbar's track.
pub const Bias = struct {
    area: records.Rect,
    scrollbar: ?records.Rect,
};

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

const RecordKind = enum { draggable, drop_target };

fn isKind(record: *const records.HitRecord, kind: RecordKind) bool {
    if (!record.pointer) return false;
    return switch (kind) {
        .draggable => record.drag_type != 0,
        .drop_target => record.drop_type != 0,
    };
}

fn countKind(hits: []const records.HitRecord, kind: RecordKind) u32 {
    var count: u32 = 0;
    for (hits) |*record| {
        if (isKind(record, kind)) count += 1;
    }
    assert(count <= hits.len);
    return count;
}

/// The index in `hits` of the `rank`th record of `kind`, counting from 0.
fn nthKind(hits: []const records.HitRecord, kind: RecordKind, rank: u32) u32 {
    assert(rank < hits.len);
    var seen: u32 = 0;
    for (hits, 0..) |*record, index| {
        if (!isKind(record, kind)) continue;
        if (seen == rank) return @intCast(index);
        seen += 1;
    }
    unreachable;
}

/// The smallest top edge of any drop target: above it, a point is outside
/// all of them.
fn dropTargetTop(hits: []const records.HitRecord) f32 {
    var top: f32 = std.math.floatMax(f32);
    for (hits) |*record| {
        if (isKind(record, .drop_target)) top = @min(top, record.bounds.y);
    }
    assert(top < std.math.floatMax(f32));
    return top;
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

/// The fuzz target for one app: a few hundred actions from the fuzzer's
/// bytes, then quiescence.
fn FuzzTarget(comptime workload: Workload) type {
    return struct {
        fn run(_: void, smith: *Smith) anyerror!void {
            const V = Vopr(workload.App(), workload.Model());
            const vopr = try std.testing.allocator.create(V);
            defer std.testing.allocator.destroy(vopr);
            try vopr.initInPlace(std.testing.allocator, std.testing.io, smith);
            defer vopr.deinit();

            const step_count = 1 + choose(smith, step_count_fuzz_max, "step count");
            var step_index: u32 = 0;
            while (step_index < step_count) : (step_index += 1) vopr.step(smith);
            vopr.quiesce();
        }
    };
}

/// Outside fuzz mode `std.testing.fuzz` replays only the corpus, so seed it
/// with PRNG inputs long enough for a few hundred actions each.
fn fuzzCorpus(comptime workload: Workload) !void {
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
    try std.testing.fuzz({}, FuzzTarget(workload).run, .{ .corpus = &corpus });
}

test "fuzz: todo vopr" {
    // Goal: the todo fuzz target runs under `zig build test` (`fuzzCorpus`).
    try fuzzCorpus(.todo);
}

test "fuzz: drag_drop vopr" {
    // Goal: the drag_drop fuzz target runs under `zig build test`.
    try fuzzCorpus(.drag_drop);
}

test "fuzz: virtual_list vopr" {
    // Goal: the virtual_list fuzz target runs under `zig build test`.
    try fuzzCorpus(.virtual_list);
}

/// One seed through `runPaired`, which panics on the first differing frame.
fn runPairedSeed(comptime workload: Workload) !Result(workload.Model()) {
    const step_count = 300;
    const byte_count = bytes_swarm + step_count * bytes_per_action_max;
    const bytes = try std.testing.allocator.alloc(u8, byte_count);
    defer std.testing.allocator.free(bytes);

    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(bytes);
    const options: RunOptions = .{ .step_count = step_count, .verbose = false };
    const result = try runPaired(
        workload.App(),
        workload.Model(),
        std.testing.allocator,
        std.testing.io,
        bytes,
        options,
    );
    try std.testing.expectEqual(@as(u32, step_count), result.summary.step_count);
    try std.testing.expect(result.summary.frame_number > 10);
    try std.testing.expect(result.summary.draw_count >= result.summary.frame_number);
    return result;
}

test "two instances fed the same bytes draw the same frames" {
    // Goal: the seed CLI's determinism self-check passes, and a run makes
    // progress. Methodology: run one seed of each app through `runPaired`
    // and require frames beyond the first, and for drag_drop a drop.
    _ = try runPairedSeed(.todo);
    const result = try runPairedSeed(.drag_drop);
    try std.testing.expect(result.stats.drags_completed > 0);
    const list = try runPairedSeed(.virtual_list);
    try std.testing.expect(list.stats.rows_seen > 0);
}
