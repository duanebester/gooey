//! VOPR: deterministic simulation testing of the core, after TigerBeetle's.
//! One generator, driven by `std.testing.Smith`, turns bytes into actions
//! against a headless app on the goldens' `CoreDriver`, and each app
//! (`Workload`) has a reference model. Every action keeps the core inside its
//! declared budget (`limits.events`) and away from wall-clock paths, so any
//! panic or failed assertion is a finding: a core bug, or a harness bug to
//! fix here. The harness checks the queue, the rendered frame number, and
//! the render side after every action, the model-free invariants of
//! `vopr_invariants.zig` on every new rendered frame, and every
//! `Swarm.rebuild_period` actions that a current frame rebuilt with no input
//! and no clock advance draws the same dump (`checkStableRebuild`); the seed
//! CLI also runs two instances on the same bytes and requires identical
//! frame dumps after every action (determinism).

const std = @import("std");
const gooey = @import("gooey");
const todo = @import("todo_example");
const drag_drop = @import("drag_drop_example");
const virtual_list = @import("virtual_list_example");
const splitter = @import("splitter_example");
const actions_model = @import("vopr_actions_model.zig");
const nested_overlay = @import("nested_overlay_example");
const text_area = @import("text_area_example");
const core = @import("goldens/core.zig");
const TodoModel = @import("vopr_todo_model.zig").TodoModel;
const DragDropModel = @import("vopr_drag_drop_model.zig").DragDropModel;
const VirtualListModel = @import("vopr_virtual_list_model.zig").VirtualListModel;
const SplitterModel = @import("vopr_splitter_model.zig").SplitterModel;
const ActionsModel = actions_model.ActionsModel;
const NestedOverlayModel = @import("vopr_nested_overlay_model.zig").NestedOverlayModel;
const TextAreaModel = @import("vopr_text_area_model.zig").TextAreaModel;
const images_model = @import("vopr_images_model.zig");
const file_dialog_model = @import("vopr_file_dialog_model.zig");
const jobs_model = @import("vopr_jobs_model.zig");
const vopr_dialogs = @import("vopr_dialogs.zig");
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
/// Bytes in one text or composition action from `text_alphabet`: its
/// longest unit is 2 bytes. A model's own alphabet sets its own bound
/// (`Vopr.text_bytes_action_max_model`).
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
    splitter,
    actions,
    nested_overlay,
    text_area,
    images,
    file_dialog,
    jobs,
    jobs_main_thread,

    fn App(comptime workload: Workload) type {
        return switch (workload) {
            .todo => todo.App,
            .drag_drop => drag_drop.App,
            .virtual_list => virtual_list.App,
            .splitter => splitter.App,
            // Ctrl on every host, as `text_engine.uses_cmd` is pinned.
            .actions => actions_model.App,
            .nested_overlay => nested_overlay.App,
            .text_area => text_area.App,
            // A VOPR-only app: eight image paths, four on screen at a time.
            .images => images_model.App,
            .file_dialog => file_dialog_model.App,
            // A VOPR-only app that spawns and cancels background jobs.
            .jobs, .jobs_main_thread => jobs_model.App,
        };
    }

    fn Model(comptime workload: Workload) type {
        return switch (workload) {
            .todo => TodoModel,
            .drag_drop => DragDropModel,
            .virtual_list => VirtualListModel,
            .splitter => SplitterModel,
            .actions => ActionsModel,
            .nested_overlay => NestedOverlayModel,
            .text_area => TextAreaModel,
            .images => images_model.ImagesModel,
            .file_dialog => file_dialog_model.FileDialogModel,
            .jobs => jobs_model.JobsModel(.stepped),
            .jobs_main_thread => jobs_model.JobsModel(.main_thread),
        };
    }
};

/// `zig build vopr -- [--app NAME] [seed] [--verbose]`: run one seed against
/// an app. With no seed, a random one is drawn and printed, so any run can be
/// replayed.
pub fn main(init: std.process.Init) !void {
    const options = parseArgs(init.minimal.args.vector) orelse {
        std.debug.print("usage: vopr [--app todo|drag_drop|virtual_list|splitter|" ++
            "actions|nested_overlay|text_area|images|file_dialog|jobs|jobs_main_thread] " ++
            "[seed] [--verbose]\n", .{});
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
};

/// Null on an argument it does not understand.
fn parseArgs(args: []const [*:0]const u8) ?CliOptions {
    assert(args.len >= 1);
    var options: CliOptions = .{
        .workload = .todo,
        .seed = null,
        .verbose = false,
    };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
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
    /// `window.resized`. After the kinds before it, so they keep their tag
    /// values.
    resize: Resize,
    /// The platform took the pointer gesture away (`pointer_cancelled`), or
    /// the window lost focus (`focus_lost`). After the kinds before it, so
    /// they keep their tag values; only models that list it draw it.
    cancel: Cancel,
    /// The image decode worker's turn, played by the harness
    /// (`images.Mode.stepped`): take the oldest request and push a decode
    /// made up for it onto the completion ring. Generated only while a
    /// request waits and the last decode has landed. After the kinds before
    /// it, so they keep their tag values; only models that list it draw it.
    image: ImageDecode,
    /// The platform answers an open file dialog through the event queue or
    /// the completion ring, or arms the answer the next dialog returns at
    /// once (`vopr_dialogs`). After the kinds before it, so they keep
    /// their tag values; only models that list it draw it.
    dialog: vopr_dialogs.Answer,
    /// One turn of a job slot's runner or interrupter, played by the
    /// harness (`jobs.Mode.stepped`). Last, so the other kinds keep their
    /// tag values; only models that list it draw it.
    job: JobStep,

    /// A worker's turn for one slot: the runner takes its spawn (`start`),
    /// the running job posts a result (`post`, refused once cancelled), or
    /// its `run` returns (`end`), which for a cancelled job its interrupter
    /// then ends as `.cancelled`.
    pub const JobStep = struct {
        slot: u32,
        kind: Kind,
        /// `.post`: the result's value.
        value: u32,
        /// `.post`: the row the app's `on_result` cancels, plus one; 0 for none.
        cancel_row: u32,
        /// `.end`: how `run` returned.
        outcome: Outcome,

        pub const Kind = enum { start, post, end };
        /// `.canceled` is a run that returned `error.Canceled` on its own,
        /// with no cancel: it reports `.cancelled` all the same.
        pub const Outcome = enum { finished, failed, canceled };
    };

    pub const ImageDecode = struct {
        /// The request's loader entry, which `takeStepped` must return.
        entry: u32,
        /// Null for synthetic RGBA pixels of `width` × `height`.
        failure: ?ImageFailure,
        width: u32,
        height: u32,
    };

    /// Operating errors a file read or a decoder returns. Never
    /// `StagingExhausted`, a capacity-planning error that fails fast.
    pub const ImageFailure = enum { file_not_found, access_denied, end_of_stream, invalid_data };

    pub const Cancel = struct {
        kind: enum { pointer_cancelled, focus_lost, focus_lost_with_pointer },
        /// A key `focus_lost` reports held, which the core releases as a
        /// `key_up`; null for none. Ignored by `pointer_cancelled`.
        key_held: ?input.KeyCode,
    };

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
            .cancel => |cancel| try writer.print("cancel {t}{s}{s}", .{
                cancel.kind,
                if (cancel.key_held != null) " holding " else "",
                if (cancel.key_held) |key| @tagName(key) else "",
            }),
            .image => |decode| if (decode.failure) |failure| {
                try writer.print("image entry {d} fails: {t}", .{ decode.entry, failure });
            } else {
                try writer.print("image entry {d} decodes {d}x{d}", .{
                    decode.entry,
                    decode.width,
                    decode.height,
                });
            },
            .dialog => |answer| try writer.print("dialog {t} {d} {t} paths={d} ({d} bytes)", .{
                answer.route,
                answer.target,
                answer.outcome,
                answer.path_count,
                answer.paths.len,
            }),
            .job => |step| switch (step.kind) {
                .start => try writer.print("job slot {d} starts", .{step.slot}),
                .post => try writer.print("job slot {d} posts {d} (cancel row {d})", .{
                    step.slot,
                    step.value,
                    step.cancel_row,
                }),
                .end => try writer.print("job slot {d} ends {t}", .{ step.slot, step.outcome }),
            },
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
    /// Percent of image decodes that fail. A failure stays for the
    /// session, so a high rate soon fails every path and a low one keeps
    /// them landing; 0 for a model that draws no decodes.
    image_failure_percent: u32,

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
    const image_failure_percent_choices = [_]u32{ 0, 2, 10, 40 };
    const button_mix_count = std.enums.values(ButtonMix).len;
    /// Most Smith choices `generate` makes: two per kind a model lists, and
    /// one per scalar it draws.
    const choice_count_max = 2 * kind_count + 7;

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
        // Only a model that draws decodes reads this choice, so the other
        // apps' seeds replay unchanged.
        swarm.image_failure_percent = 0;
        if (comptime std.mem.indexOfScalar(ActionKind, kinds, .image) != null) {
            swarm.image_failure_percent = image_failure_percent_choices[
                choose(smith, image_failure_percent_choices.len, "image failure percent")
            ];
        }
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
        if (std.mem.indexOfScalar(ActionKind, self.kinds, .image) != null) {
            try writer.print(" image failures={d}%", .{self.image_failure_percent});
        }
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
        text_bytes: [text_bytes_action_max_model]u8,
        /// The current epoch's action mix.
        swarm: Swarm,
        /// Actions generated so far, which sets the epochs.
        action_count: u32,
        /// The held-button gesture `.drag` steps continue, if any.
        gesture: GestureState,
        /// The mouse buttons the harness holds down.
        held: Held,
        /// The rendered frame `invariants.checkFrame` last checked.
        frame_number_checked: u64,
        /// The dump of the rendered frame, copied before a stable rebuild.
        rebuild_dump: [dump_bytes_max]u8,
        stable_rebuild_count: u32,
        /// The platform's file dialogs, bound when the model lists `.dialog`.
        dialogs: Dialogs,
        /// Backing for the paths of the dialog answer being generated.
        answer_bytes: [App.limits.events.dialog_path_bytes_max]u8,
        /// Completions pushed onto the ring since the last drain, which the
        /// next drain moves into the queue. Their paths take no text bytes.
        ring_answer_count: u32,

        const Self = @This();
        const Dialogs = vopr_dialogs.Dialogs(App.limits.events);
        const lists_dialog = std.mem.indexOfScalar(ActionKind, Model.action_kinds, .dialog) != null;
        const lists_image = std.mem.indexOfScalar(ActionKind, Model.action_kinds, .image) != null;
        const lists_job = std.mem.indexOfScalar(ActionKind, Model.action_kinds, .job) != null;
        /// Who runs the app's jobs: the harness steps the workers, unless
        /// the model runs them on the main thread (`runQueued`).
        const job_runs: internals.jobs.Mode = if (@hasDecl(Model, "job_runs"))
            Model.job_runs
        else
            .stepped;

        /// Paths one selection answer may hold, before the byte budget cuts it.
        const path_count_choices = [_]u32{ 1, 2, 3, App.limits.events.dialog_path_count_max };

        comptime {
            // A model that draws decodes names the sides they may have, and
            // a model that answers dialogs the path lengths they may have.
            if (lists_image) {
                for (Model.image_sides) |side| {
                    assert(side > 0);
                    assert(side <= App.limits.atlas.image_size - 2);
                    assert(side * side * 4 <= App.limits.atlas.image_decode_bytes_max);
                }
            }
            if (lists_dialog) {
                for (Model.dialog_path_lengths) |length| assert(length > 0);
            }
            for (path_count_choices) |count| assert(count > 0);
            // Only stepped jobs have turns to play, and the model names
            // the result the harness posts and the rows it may cancel.
            if (lists_job) {
                assert(job_runs == .stepped);
                assert(@sizeOf(Model.JobResult) <= App.limits.events.job_result_bytes_max);
                assert(Model.job_row_count > 0);
            }
        }

        /// The keys the generator presses: the model's own list when it
        /// declares one (`Model.key_choices`), so the other apps' seeds
        /// replay unchanged.
        const keys: []const input.KeyCode = if (@hasDecl(Model, "key_choices"))
            Model.key_choices
        else
            &key_choices;

        /// The units text and compositions are made of: the model's own
        /// when it declares them (`Model.text_alphabet`), so the other apps'
        /// seeds replay unchanged. A unit may be any length; each is one
        /// choice, so the bytes a seed reads per action do not change.
        const alphabet: []const []const u8 = if (@hasDecl(Model, "text_alphabet"))
            Model.text_alphabet
        else
            &text_alphabet;

        /// Bytes one text or composition action can hold.
        const text_bytes_action_max_model: u32 = blk: {
            var unit_len_max: u32 = 0;
            for (alphabet) |unit| unit_len_max = @max(unit_len_max, unit.len);
            break :blk text_unit_count_max * unit_len_max;
        };

        comptime {
            // Never the debugger toggle, Cmd/Ctrl+Shift+I, which reads the
            // real clock.
            for (keys) |key| assert(key != .i);
            for (alphabet) |unit| assert(std.unicode.utf8ValidateSlice(unit));
            assert(text_bytes_action_max_model <= App.limits.events.text_bytes_max);
            assert(text_bytes_action_max_model <= App.limits.text.preedit_bytes_max);
            if (!@hasDecl(Model, "text_alphabet")) {
                assert(text_bytes_action_max_model == text_bytes_action_max);
            }
        }

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
        /// that is down or releases one that is up.
        const Held = struct {
            down: [button_count]bool,

            const none: Held = .{ .down = @splat(false) };

            fn isDown(self: *const Held, button: input.MouseButton) bool {
                return self.down[@backingInt(button)];
            }

            fn any(self: *const Held) bool {
                return std.mem.indexOfScalar(bool, &self.down, true) != null;
            }

            fn press(self: *Held, button: input.MouseButton) void {
                assert(!self.isDown(button));
                self.down[@backingInt(button)] = true;
            }

            fn release(self: *Held, button: input.MouseButton) void {
                assert(self.isDown(button));
                self.down[@backingInt(button)] = false;
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
            // The harness plays the image decode worker, so no thread reads
            // files, and the job workers unless the model runs jobs on the
            // main thread (`Model.job_runs`).
            try self.driver.initInPlaceWorkers(gpa, io, &trace, .{
                .image_decodes = .stepped,
                .job_runs = job_runs,
            });
            self.frame_number_rendered = 0;
            self.quiescence_round_count = 0;
            self.dump_hasher = .init(0);
            self.text_bytes = @splat(0);
            self.swarm = .generate(smith, Model.action_kinds);
            self.action_count = 0;
            self.gesture = .idle;
            self.held = .none;
            self.frame_number_checked = 0;
            self.stable_rebuild_count = 0;
            self.dialogs.init();
            if (lists_dialog) self.dialogs.bind(self.window());
            self.answer_bytes = @splat(0);
            self.ring_answer_count = 0;
            self.model.init();
            // A model that stands in for a platform service (the text
            // clipboard) binds it before the first frame.
            if (@hasDecl(Model, "attach")) self.model.attach(self.window());
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

        pub fn perform(self: *Self, action: Action) void {
            switch (action) {
                .pointer, .key, .text, .compose, .scroll, .drag, .resize, .cancel => {
                    self.model.queue(action);
                },
                .image, .dialog, .job => self.model.queue(action),
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
                .cancel => |cancel| self.deliver(cancelEvent(cancel)),
                .image => |decode| self.performImage(&decode),
                .dialog => |answer| self.performDialog(&answer),
                .job => |turn| if (!lists_job) unreachable else self.performJob(&turn),
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
                    .key = keys[choose(smith, keys.len, "key")],
                    .modifiers = modifier_choices[
                        choose(smith, modifier_choices.len, "modifiers")
                    ],
                } } else .tick_main,
                .text => if (self.queueHasRoom(1, text_bytes_action_max_model))
                    .{ .text = self.generateText(smith, 1) }
                else
                    .tick_main,
                .compose => if (self.queueHasRoom(1, text_bytes_action_max_model))
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
                .cancel => if (self.queueHasRoom(1, 0))
                    .{ .cancel = generateCancel(smith) }
                else
                    .tick_main,
                // Only a model that lists these kinds draws them, and only
                // it names their sizes and lengths.
                .image => if (!lists_image) unreachable else if (self.imageRequestOldest()) |entry|
                    .{ .image = self.generateImage(smith, entry) }
                else
                    .tick_main,
                .dialog => if (!lists_dialog) unreachable else self.generateDialog(smith),
                .job => if (!lists_job) unreachable else self.generateJob(smith),
            };
        }

        /// A turn for the first slot from a seeded one that has a turn to
        /// take: a pending or skipped spawn starts; a running job posts
        /// (only while a result slot is free, as a worker would wait for a
        /// drain) or ends; a cancelled one posts, refused, or ends. Always
        /// the same choices, so the slots' phases do not shift the bytes
        /// that follow. With no turn to take, a `tickMain`.
        fn generateJob(self: *Self, smith: *Smith) Action {
            const pool = &self.window().jobs;
            assert(pool.mode == .stepped);
            const slot_count: u32 = @intCast(pool.slots.len);
            assert(slot_count > 0);
            const slot_first = choose(smith, slot_count, "job slot");
            const posts = choose(smith, 4, "job step") < 3;
            const value = choose(smith, 1000, "job value");
            const cancels = choose(smith, 100, "job cancels") < 10;
            const row = choose(smith, Model.job_row_count, "job cancel row");
            const outcome_index = choose(smith, 4, "job outcome");
            var turn: Action.JobStep = .{
                .slot = 0,
                .kind = .start,
                .value = value,
                .cancel_row = if (cancels) row + 1 else 0,
                // Finished twice as often as failed or cancelled by `run`.
                .outcome = switch (outcome_index) {
                    0, 1 => .finished,
                    2 => .failed,
                    3 => .canceled,
                    else => unreachable,
                },
            };
            const room = pool.result_free_count > 0;
            var offset: u32 = 0;
            while (offset < slot_count) : (offset += 1) {
                turn.slot = (slot_first + offset) % slot_count;
                turn.kind = jobTurn(pool.phaseOf(turn.slot), .{
                    .posts = posts,
                    .room = room,
                }) orelse continue;
                return .{ .job = turn };
            }
            assert(offset == slot_count);
            return .tick_main;
        }

        /// A worker's turn: the runner's `beginRun` or `endRun`, a post,
        /// or, after a cancelled run returned, the interrupter's end. Each
        /// returns what the slot's phase before it says it must.
        fn performJob(self: *Self, turn: *const Action.JobStep) void {
            const pool = &self.window().jobs;
            assert(pool.mode == .stepped);
            const phase = pool.phaseOf(turn.slot);
            switch (turn.kind) {
                .start => {
                    const began = pool.beginRun(turn.slot);
                    assert(began == (phase == .pending));
                    if (!began) assert(phase == .skipped);
                },
                .post => {
                    const result: Model.JobResult = .{
                        .value = turn.value,
                        .cancel_row = turn.cancel_row,
                    };
                    const posted = pool.post(turn.slot, std.mem.asBytes(&result));
                    assert(posted == (phase == .running));
                },
                .end => {
                    const ended = pool.endRun(turn.slot, jobReturned(turn.outcome));
                    assert(ended == (phase == .running));
                    if (!ended) pool.finishInterrupt(turn.slot);
                },
            }
            assert(pool.phaseOf(turn.slot) != .pending);
        }

        /// The entry of the oldest image request, when the stepped worker
        /// may take it: one waits, and the last decode has landed.
        fn imageRequestOldest(self: *Self) ?u32 {
            const loader = &self.window().images;
            assert(loader.mode == .stepped);
            if (loader.stepped_staging_held) return null;
            const tail = loader.request_tail.load(.monotonic);
            if (tail == loader.request_head.load(.monotonic)) return null;
            assert(std.math.isPowerOfTwo(loader.requests.len));
            const mask: u32 = @intCast(loader.requests.len - 1);
            const entry = loader.requests[tail & mask];
            assert(entry < loader.entries.len);
            return entry;
        }

        /// A failure at the swarm's rate, else pixels with sides from the
        /// model's list. Always the same choices, so the outcome does not
        /// shift the bytes that follow.
        fn generateImage(self: *const Self, smith: *Smith, entry: u32) Action.ImageDecode {
            const failure_count = std.enums.values(Action.ImageFailure).len;
            const fails = choose(smith, 100, "image fails") < self.swarm.image_failure_percent;
            const failure_index = choose(smith, failure_count, "image failure");
            const sides = Model.image_sides;
            const width = sides[choose(smith, sides.len, "image width")];
            const height = sides[choose(smith, sides.len, "image height")];
            assert(width > 0);
            assert(height > 0);
            return .{
                .entry = entry,
                .failure = if (fails) @fromBackingInt(@intCast(failure_index)) else null,
                .width = width,
                .height = height,
            };
        }

        /// The worker's turn: take the request and push its made-up decode.
        fn performImage(self: *Self, decode: *const Action.ImageDecode) void {
            const win = self.window();
            const taken = win.images.takeStepped() orelse unreachable;
            assert(taken == decode.entry);
            if (decode.failure) |failure| {
                win.completions.pushImage(.{
                    .entry = taken,
                    .width = 0,
                    .height = 0,
                    .pixel_offset = 0,
                    .failure = imageError(failure),
                });
                return;
            }
            const pixel_bytes = decode.width * decode.height * 4;
            fillPixels(win.images.stagingStepped(pixel_bytes), decode);
            win.completions.pushImage(.{
                .entry = taken,
                .width = decode.width,
                .height = decode.height,
                .pixel_offset = 0,
                .failure = null,
            });
        }

        /// An answer to an open dialog, or one armed for the next dialog to
        /// return at once, always when none is open. One through the queue
        /// or the ring that the queue cannot take before the next drain
        /// becomes a `tickMain`.
        fn generateDialog(self: *Self, smith: *Smith) Action {
            const Answer = vopr_dialogs.Answer;
            const route_index = choose(smith, 3, "dialog route");
            const target_index = choose(smith, self.dialogs.open.len, "dialog target");
            const outcome_index = choose(smith, 4, "dialog outcome");
            const count_index = choose(smith, path_count_choices.len, "dialog path count");
            const seed = choose(smith, std.math.maxInt(u32), "dialog seed");
            if (self.model.pendingRoom() == 0) return .tick_main;
            const open_count = self.dialogs.open_count;
            const route: Answer.Route = if (open_count == 0)
                .at_open
            else
                @fromBackingInt(@intCast(route_index));
            const target = if (route == .at_open) 0 else target_index % open_count;
            // Selections twice as often as cancels or failures.
            const outcome: Answer.Outcome = switch (outcome_index) {
                0, 1 => .selected,
                2 => .cancelled,
                3 => .failed,
                else => unreachable,
            };
            var answer: Answer = .{
                .route = route,
                .target = target,
                .outcome = outcome,
                .paths = "",
                .path_count = 0,
            };
            if (outcome == .selected) {
                const many = route == .at_open or self.dialogs.open[target].many;
                const written = vopr_dialogs.writePaths(&self.answer_bytes, .{
                    .seed = seed,
                    .count_max = if (many) path_count_choices[count_index] else 1,
                    .lengths = Model.dialog_path_lengths,
                });
                answer.paths = self.answer_bytes[0..written.len];
                answer.path_count = written.count;
            }
            // A platform holds an answer the queue has no event slot for
            // yet, as it holds input. Its paths take their request's own
            // room (`EventQueue.dialog_paths`), never the text bytes.
            if (route != .at_open and !self.queueHasRoom(1, 0)) {
                return .tick_main;
            }
            return .{ .dialog = answer };
        }

        /// The platform answers: arm it, or close the dialog and queue its
        /// completion on the route's path.
        fn performDialog(self: *Self, answer: *const vopr_dialogs.Answer) void {
            if (answer.route == .at_open) return self.dialogs.arm(answer);
            const win = self.window();
            const open = self.dialogs.close(answer.target);
            if (answer.outcome == .selected) {
                // A backend that completes a dialog later checks the
                // selection here before it queues it, as `openDialog` does.
                tick.checkSelection(win, open.many, answer.path_count, answer.paths.len);
            }
            const completion = answer.completion(open.request_id);
            switch (answer.route) {
                .queue => {
                    assert(win.queue.room() > 0);
                    win.queue.push(.{ .completion = completion });
                },
                .ring => {
                    win.completions.push(completion);
                    self.ring_answer_count += 1;
                },
                .at_open => unreachable,
            }
        }

        /// A gesture cancel or a focus loss, which may report one key held.
        fn generateCancel(smith: *Smith) Action.Cancel {
            const Kind = @FieldType(Action.Cancel, "kind");
            const kind_count_cancel = std.enums.values(Kind).len;
            const kind_index = choose(smith, kind_count_cancel, "cancel kind");
            const kind: Kind = @fromBackingInt(@intCast(kind_index));
            const holds = choose(smith, 2, "cancel holds key") == 0;
            const key = keys[choose(smith, keys.len, "cancel key")];
            return .{ .kind = kind, .key_held = if (holds) key else null };
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
                // A completion on the ring wakes the host as input does.
                const busy = win.render_requested or win.awaiting_flip or ringPending(win);
                if (!busy) break;
                self.tickMain();
                self.check();
            }
            assert(round <= quiescence_round_max);
            self.quiescence_round_count = round;
            const in_flight = win.frame_in_flight.load(.acquire);
            if (win.render_requested or in_flight or win.awaiting_flip or ringPending(win)) {
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
        /// timed render (`cx.requestRenderAfter`) or request a render
        /// itself, so those frames are exactly the exempt ones.
        fn checkStableRebuild(self: *Self) void {
            const win = self.window();
            if (win.frame_in_flight.load(.acquire)) return;
            if (win.awaiting_flip or win.render_requested) return;
            // Queued input and a completion on the ring are input.
            if (win.queue.count > 0) return;
            if (ringPending(win)) return;
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
            // Completions on the ring take their slots at the drain.
            const text_room: u64 = queue.text_bytes.len - queue.text_len;
            if (self.model.pendingRoom() == 0) return false;
            if (queue.room() < self.ring_answer_count) return false;
            return queue.room() - self.ring_answer_count >= event_count and
                text_room >= text_bytes;
        }

        fn tickMain(self: *Self) void {
            const win = self.window();
            self.model.beginDrain(win);
            const opened_count_before = self.dialogs.opened_count;
            const published = tick.tickMain(&self.driver.app, win, self.driver.now_ns);
            if (published) assert(win.frame_in_flight.load(.acquire));
            // A drain takes the whole ring; only jobs it ran on the main
            // thread push onto it again, for the next drain.
            if (job_runs != .main_thread) assert(!ringPending(win));
            self.ring_answer_count = 0;
            self.model.endDrain(win, published);
            self.checkDrained(published, opened_count_before);
        }

        /// Every drain empties the queue, except one whose file dialog
        /// returned its outcome from `open`, as a modal one does: the tick
        /// queues that one completion for the next drain and builds nothing.
        fn checkDrained(self: *Self, published: bool, opened_count_before: u32) void {
            const win = self.window();
            const delivered = self.dialogs.delivered_at_open;
            self.dialogs.delivered_at_open = null;
            if (delivered) |answer| {
                assert(self.dialogs.opened_count == opened_count_before + 1);
                assert(!published);
                assert(win.render_requested);
                assert(win.dialog_handlers[answer.request_id] != null);
                assert(win.queue.count == 1);
                const pending = win.queue.pending();
                assert(pending[0] == .completion);
                assert(pending[0].completion.request_id == answer.request_id);
                return;
            }
            if (win.queue.count == 0) return;
            std.debug.panic("vopr: {d} events left queued after a tickMain whose file " ++
                "dialog returned no outcome from open", .{win.queue.count});
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
                        const area = if (on_bar) bias.alternate orelse bias.area else bias.area;
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

        /// `unit_count_min` or more units of `alphabet`, written into
        /// `text_bytes`; the slice lives until the next generated action.
        fn generateText(self: *Self, smith: *Smith, unit_count_min: u32) []const u8 {
            assert(unit_count_min <= 1);
            const unit_count = unit_count_min +
                choose(smith, text_unit_count_max + 1 - unit_count_min, "text length");
            assert(unit_count <= text_unit_count_max);
            var len: u32 = 0;
            var unit_index: u32 = 0;
            while (unit_index < unit_count) : (unit_index += 1) {
                const unit = alphabet[choose(smith, alphabet.len, "text unit")];
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

/// The platform event for `cancel`: a focus loss reports the gesture it
/// cancelled, if any, and the one key held, if any.
fn cancelEvent(cancel: Action.Cancel) input.InputEvent {
    if (cancel.kind == .pointer_cancelled) return .pointer_cancelled;
    var keys_held: input.HeldKeys = .empty;
    if (cancel.key_held) |key| {
        assert(key != .unknown);
        keys_held.set(@backingInt(key));
    }
    assert(keys_held.count() <= 1);
    return .{ .focus_lost = .{
        .pointer_cancelled = cancel.kind == .focus_lost_with_pointer,
        .keys_held = keys_held,
    } };
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

/// Whether a worker's completion waits on the ring for the next drain.
fn ringPending(win: *Window) bool {
    const ring = &win.completions;
    const head = ring.head.load(.acquire);
    const tail = ring.tail.load(.monotonic);
    assert(head -% tail <= ring.slots.len);
    return head != tail;
}

/// The turn a job slot in `phase` can take, or null for none: a slot
/// without a job, or whose end waits for a drain, has none, and neither has
/// a running job asked to post while every result slot is held.
fn jobTurn(phase: internals.jobs.Phase, options: struct {
    /// The seed asks for a post rather than an end.
    posts: bool,
    /// A result slot is free.
    room: bool,
}) ?Action.JobStep.Kind {
    switch (phase) {
        .idle => return null,
        .pending, .skipped => return .start,
        .running => {
            if (!options.posts) return .end;
            if (options.room) return .post;
            return null;
        },
        // A cancelled job's post is refused before any wait, room or not.
        .interrupting => return if (options.posts) .post else .end,
    }
}

/// What the harness's `run` returned: `.canceled` is a run that returned
/// `error.Canceled` on its own, which reports `.cancelled`.
fn jobReturned(outcome: Action.JobStep.Outcome) anyerror!void {
    return switch (outcome) {
        .finished => {},
        .failed => error.WorkFailed,
        .canceled => error.Canceled,
    };
}

fn imageError(failure: Action.ImageFailure) anyerror {
    return switch (failure) {
        .file_not_found => error.FileNotFound,
        .access_denied => error.AccessDenied,
        .end_of_stream => error.EndOfStream,
        .invalid_data => error.InvalidData,
    };
}

/// Synthetic RGBA pixels: any bytes do, so long as both instances agree.
fn fillPixels(pixels: []u8, decode: *const Action.ImageDecode) void {
    assert(decode.failure == null);
    assert(pixels.len == @as(usize, decode.width) * decode.height * 4);
    for (pixels, 0..) |*byte, index| {
        byte.* = @truncate(index *% 31 +% decode.entry *% 7 +% decode.width);
    }
}

/// Where a model asks pointer, wheel, and drag actions to aim half the time
/// (`Model.biasTarget`): an area, and a third of those times an alternate
/// one when it has one, such as a scroll box and its scrollbar's track.
pub const Bias = struct {
    area: records.Rect,
    alternate: ?records.Rect,
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

/// A `.draggable` is a box a press starts a gesture on: a drag source, or
/// a box that captures the pointer (`on_pointer_drag`), such as a splitter.
fn isKind(record: *const records.HitRecord, kind: RecordKind) bool {
    if (!record.pointer) return false;
    return switch (kind) {
        .draggable => record.drag_type != 0 or record.on_pointer_drag != records.index_none,
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
    try fuzzCorpus(.todo);
}

test "fuzz: drag_drop vopr" {
    try fuzzCorpus(.drag_drop);
}

test "fuzz: virtual_list vopr" {
    try fuzzCorpus(.virtual_list);
}

test "fuzz: splitter vopr" {
    try fuzzCorpus(.splitter);
}

test "fuzz: actions vopr" {
    try fuzzCorpus(.actions);
}

test "fuzz: nested_overlay vopr" {
    try fuzzCorpus(.nested_overlay);
}

test "fuzz: text_area vopr" {
    try fuzzCorpus(.text_area);
}

test "fuzz: images vopr" {
    try fuzzCorpus(.images);
}

test "fuzz: file_dialog vopr" {
    try fuzzCorpus(.file_dialog);
}

test "fuzz: jobs vopr" {
    try fuzzCorpus(.jobs);
}

test "fuzz: jobs_main_thread vopr" {
    try fuzzCorpus(.jobs_main_thread);
}

/// One seed through `runPaired`, which panics on the first differing frame.
fn runPairedSeed(comptime workload: Workload, prng_seed: u64) !Result(workload.Model()) {
    const step_count = 300;
    const byte_count = bytes_swarm + step_count * bytes_per_action_max;
    const bytes = try std.testing.allocator.alloc(u8, byte_count);
    defer std.testing.allocator.free(bytes);

    var prng = std.Random.DefaultPrng.init(prng_seed);
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
    _ = try runPairedSeed(.todo, 1);
    // Seed 4 starts nine drags in 300 steps; seed 1 starts one, so whether it
    // drops depended on where layout happened to put the lists.
    const result = try runPairedSeed(.drag_drop, 4);
    try std.testing.expect(result.stats.drags_completed > 0);
    const list = try runPairedSeed(.virtual_list, 1);
    try std.testing.expect(list.stats.rows_seen > 0);
    // Seed 1's resizes include a 1 px window where the panes overflow at
    // their content floors, so its few presses miss the splitters; seed 6
    // drags them 27 times.
    const panes = try runPairedSeed(.splitter, 6);
    try std.testing.expect(panes.stats.drags_moved > 0);
    const fired = try runPairedSeed(.actions, 1);
    var fire_count: u32 = 0;
    for (fired.stats.fired) |count| fire_count += count;
    try std.testing.expect(fire_count > 0);
    // The Select's menu starts closed, so a seed shows it only once the
    // swarm opens it; seed 1's swarm draws 19 frames and never does, while
    // seed 4's opens it three times and the dialog once.
    const overlay = try runPairedSeed(.nested_overlay, 4);
    try std.testing.expect(overlay.stats.menu_frames > 0);
    const area = try runPairedSeed(.text_area, 1);
    try std.testing.expect(area.stats.checks.frames > 0);
    const images = try runPairedSeed(.images, 1);
    try std.testing.expect(images.stats.landed > 0);
    try std.testing.expect(images.stats.drawn > 0);
    // file_dialog seed 9's clicks ask twice in one drain; seed 2's fill the
    // dialog table and ask again.
    const dialogs = try runPairedSeed(.file_dialog, 9);
    try std.testing.expect(dialogs.stats.completions > 0);
    try std.testing.expect(dialogs.stats.refused_waiting > 0);
    const dialogs_full = try runPairedSeed(.file_dialog, 2);
    try std.testing.expect(dialogs_full.stats.refused_full > 0);
    // jobs seed 7 cancels a running job, whose posts are then refused and
    // whose undelivered result is dropped; seed 2's clicks fill the job
    // table, are refused, and cancel a reused slot's stale id.
    const interrupted = try runPairedSeed(.jobs, 7);
    try std.testing.expect(interrupted.stats.cancels_interrupting > 0);
    try std.testing.expect(interrupted.stats.posts_refused > 0);
    try std.testing.expect(interrupted.stats.results_dropped > 0);
    const busy = try runPairedSeed(.jobs, 2);
    try std.testing.expect(busy.stats.refused > 0);
    try std.testing.expect(busy.stats.cancels_stale_reused > 0);
    // jobs_main_thread seed 1 defers runs behind held results, and refuses
    // a chained job's successor inside on_done.
    const main_thread = try runPairedSeed(.jobs_main_thread, 1);
    try std.testing.expect(main_thread.stats.runs_deferred > 0);
    try std.testing.expect(main_thread.stats.refused_chain > 0);
}

/// The centre of the `rank`-th hit record with a click handler, in tree order.
fn clickTarget(frame: *const records.Frame, rank: u32) Point {
    var seen: u32 = 0;
    for (frame.hits[0..frame.hit_count]) |*record| {
        if (record.on_click == records.index_none) continue;
        if (seen == rank) {
            const bounds = record.bounds;
            return .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
        }
        seen += 1;
    }
    unreachable; // The example draws its three buttons in every frame.
}

test "a List scrolled by a target rebuilds the same rows" {
    // List predicts the offset layout resolves for a `.child` and an `.end`
    // target to the bit: Jump built one row off at 1006x216 and 1.25x
    // (virtual_list seed 284) and at 475x1732 and 1.25x (soak seed
    // 6858813265271003337). Before the fix the first Jump failed "dumps
    // differ".
    const V = Vopr(virtual_list.App, VirtualListModel);
    const vopr_instance = try std.testing.allocator.create(V);
    defer std.testing.allocator.destroy(vopr_instance);
    const swarm_bytes: [64]u8 = @splat(0);
    var smith: Smith = .{ .in = &swarm_bytes };
    try vopr_instance.initInPlace(std.testing.allocator, std.testing.io, &smith);
    defer vopr_instance.deinit();
    const sizes = [_]Action.Resize{
        .{ .width = 1006, .height = 216, .scale_factor = 1.25 },
        .{ .width = 800, .height = 600, .scale_factor = 1 },
        .{ .width = 777, .height = 333, .scale_factor = 1.5 },
        .{ .width = 641, .height = 251, .scale_factor = 1.75 },
        .{ .width = 475, .height = 1732, .scale_factor = 1.25 },
    };
    const top_button = 0;
    const bottom_button = 1;
    const jump_button = 2;
    for (sizes) |size| {
        vopr_instance.perform(.{ .resize = size });
        vopr_instance.quiesce();
        for ([_]u32{ jump_button, top_button, bottom_button, jump_button }) |rank| {
            const rebuilds = vopr_instance.stable_rebuild_count;
            const target = clickTarget(vopr_instance.window().rendered(), rank);
            vopr_instance.perform(.{ .pointer = .{
                .kind = .click,
                .button = .left,
                .x = target.x,
                .y = target.y,
                .click_count = 1,
                .releases_held = false,
            } });
            // Quiescence ends in the stable-rebuild check; it must not skip.
            vopr_instance.quiesce();
            try std.testing.expect(vopr_instance.stable_rebuild_count > rebuilds);
        }
    }
}
