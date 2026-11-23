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

pub const step_count_cli: u32 = 12_000;
const swarm_epoch_step_count: u32 = 3_000;
const step_count_fuzz_max: u32 = 256;
const choice_count_action_max: u32 = 2 + text_unit_count_max;
const bytes_per_action_max: u32 = choice_count_action_max * @sizeOf(u64);
const bytes_swarm: u32 = Swarm.choice_count_max * @sizeOf(u64);
const bytes_cli: u32 = bytes_swarm * (1 + @divFloor(step_count_cli, swarm_epoch_step_count)) +
    step_count_cli * bytes_per_action_max;
const quiescence_round_max: u32 = 32;
const text_unit_count_max: u32 = 8;
const text_bytes_action_max: u32 = text_unit_count_max * 2;
const pointer_event_count_max: u32 = 3;
const release_event_count: u32 = 2;
const button_count = std.enums.values(input.MouseButton).len;
const drag_move_count_max: u32 = 8;
const scale_factor: f32 = 2;
const dump_bytes_max: u32 = gooey.testing.test_backend.null_renderer_dump_bytes_max;

pub const text_alphabet = [_][]const u8{ "a", "b", "Z", "1", " ", "é" };

const key_choices = [_]input.KeyCode{
    .@"return", .tab,   .delete, .forward_delete, .escape, .space,
    .left,      .right, .up,     .down,           .home,   .end,
    .a,         .c,     .v,      .x,              .z,
};

const modifier_choices = [_]input.Modifiers{
    .{},
    .{ .shift = true },
    .{ .ctrl = true },
    .{ .ctrl = true, .shift = true },
    .{ .alt = true },
};

const gap_ns_choices = [_]u64{ 0, 16_666_667, 1_000_000_000, 10_000_000_000 };

comptime {
    for (key_choices) |key| assert(key != .i);
    for (text_alphabet) |unit| assert(unit.len <= 2);
    assert(text_bytes_action_max <= internals.limits.EventLimits.nano.text_bytes_max);
}

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
            .actions => actions_model.App,
            .nested_overlay => nested_overlay.App,
            .text_area => text_area.App,
            .images => images_model.App,
            .file_dialog => file_dialog_model.App,
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
    if (@sizeOf(Model.Stats) > 0) {
        std.debug.print("vopr: {s} seed {d} stats: {f}\n", .{ name, seed, result.stats });
    }
}

const CliOptions = struct {
    workload: Workload,
    seed: ?u64,
    verbose: bool,
};

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
    quiescence_round_count: u32,
    frame_number: u64,
    draw_count: u64,
    dump_hash: u64,
    stable_rebuild_count: u32,
};

pub fn Result(comptime Model: type) type {
    return struct { summary: Summary, stats: Model.Stats };
}

pub const RunOptions = struct {
    step_count: u32,
    verbose: bool,
};

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
    text: []const u8,
    compose: []const u8,
    scroll: Scroll,
    wait_ns: u64,
    tick_main,
    present,
    drag: Gesture,
    resize: Resize,
    cancel: Cancel,
    image: ImageDecode,
    dialog: vopr_dialogs.Answer,
    job: JobStep,

    pub const JobStep = struct {
        slot: u32,
        kind: Kind,
        value: u32,
        cancel_row: u32,
        outcome: Outcome,

        pub const Kind = enum { start, post, end };
        pub const Outcome = enum { finished, failed, canceled };
    };

    pub const ImageDecode = struct {
        entry: u32,
        failure: ?ImageFailure,
        width: u32,
        height: u32,
    };

    pub const ImageFailure = enum { file_not_found, access_denied, end_of_stream, invalid_data };

    pub const Cancel = struct {
        kind: enum { pointer_cancelled, focus_lost, focus_lost_with_pointer },
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
        releases_held: bool,
    };

    pub const Pointer = struct {
        kind: enum { click, move, press, release },
        button: input.MouseButton,
        x: f32,
        y: f32,
        click_count: u32,
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

pub const Swarm = struct {
    kind_weights: [kind_count]u32,
    kinds: []const ActionKind,
    kind_weight_total: u32,
    interactive_percent: u32,
    target_prefix_count: u32,
    click_percent: u32,
    rebuild_period: u32,
    button_mix: ButtonMix,
    hold_percent: u32,
    image_failure_percent: u32,

    pub const ButtonMix = enum { left_only, mostly_left, even };

    const kind_weight_max: u32 = 16;
    const interactive_percent_choices = [_]u32{ 0, 50, 90 };
    const target_prefix_count_choices = [_]u32{ 2, 3, 5, 8, 0 };
    const click_percent_choices = [_]u32{ 25, 50, 90 };
    const rebuild_period_choices = [_]u32{ 7, 31, 127 };
    const hold_percent_choices = [_]u32{ 0, 10, 30 };
    const image_failure_percent_choices = [_]u32{ 0, 2, 10, 40 };
    const button_mix_count = std.enums.values(ButtonMix).len;
    const choice_count_max = 2 * kind_count + 7;

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

pub fn Vopr(comptime App: type, comptime Model: type) type {
    return struct {
        driver: Driver,
        model: Model,
        frame_number_rendered: u64,
        quiescence_round_count: u32,
        dump_hasher: std.hash.Wyhash,
        text_bytes: [text_bytes_action_max_model]u8,
        swarm: Swarm,
        action_count: u32,
        gesture: GestureState,
        held: Held,
        frame_number_checked: u64,
        rebuild_dump: [dump_bytes_max]u8,
        stable_rebuild_count: u32,
        dialogs: Dialogs,
        answer_bytes: [App.limits.events.dialog_path_bytes_max]u8,
        ring_answer_count: u32,

        const Self = @This();
        const Dialogs = vopr_dialogs.Dialogs(App.limits.events);
        const lists_dialog = std.mem.indexOfScalar(ActionKind, Model.action_kinds, .dialog) != null;
        const lists_image = std.mem.indexOfScalar(ActionKind, Model.action_kinds, .image) != null;
        const lists_job = std.mem.indexOfScalar(ActionKind, Model.action_kinds, .job) != null;
        const job_runs: internals.jobs.Mode = if (@hasDecl(Model, "job_runs"))
            Model.job_runs
        else
            .stepped;

        const path_count_choices = [_]u32{ 1, 2, 3, App.limits.events.dialog_path_count_max };

        comptime {
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
            if (lists_job) {
                assert(job_runs == .stepped);
                assert(@sizeOf(Model.JobResult) <= App.limits.events.job_result_bytes_max);
                assert(Model.job_row_count > 0);
            }
        }

        const keys: []const input.KeyCode = if (@hasDecl(Model, "key_choices"))
            Model.key_choices
        else
            &key_choices;

        const alphabet: []const []const u8 = if (@hasDecl(Model, "text_alphabet"))
            Model.text_alphabet
        else
            &text_alphabet;

        const text_bytes_action_max_model: u32 = blk: {
            var unit_len_max: u32 = 0;
            for (alphabet) |unit| unit_len_max = @max(unit_len_max, unit.len);
            break :blk text_unit_count_max * unit_len_max;
        };

        comptime {
            for (keys) |key| assert(key != .i);
            for (alphabet) |unit| assert(std.unicode.utf8ValidateSlice(unit));
            assert(text_bytes_action_max_model <= App.limits.events.text_bytes_max);
            assert(text_bytes_action_max_model <= App.limits.text.preedit_bytes_max);
            if (!@hasDecl(Model, "text_alphabet")) {
                assert(text_bytes_action_max_model == text_bytes_action_max);
            }
        }

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

        pub noinline fn initInPlace(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            smith: *Smith,
        ) !void {
            internals.text_engine.uses_cmd = false;
            internals.window.wheel_delta_inverted = false;
            const trace = trace_mod.Trace{
                .name = "vopr",
                .width = @floatFromInt(App.width),
                .height = @floatFromInt(App.height),
                .scale_factor = scale_factor,
                .steps = &.{},
            };
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
                .image => if (!lists_image) unreachable else if (self.imageRequestOldest()) |entry|
                    .{ .image = self.generateImage(smith, entry) }
                else
                    .tick_main,
                .dialog => if (!lists_dialog) unreachable else self.generateDialog(smith),
                .job => if (!lists_job) unreachable else self.generateJob(smith),
            };
        }

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
            if (route != .at_open and !self.queueHasRoom(1, 0)) {
                return .tick_main;
            }
            return .{ .dialog = answer };
        }

        fn performDialog(self: *Self, answer: *const vopr_dialogs.Answer) void {
            if (answer.route == .at_open) return self.dialogs.arm(answer);
            const win = self.window();
            const open = self.dialogs.close(answer.target);
            if (answer.outcome == .selected) {
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

        fn generateCancel(smith: *Smith) Action.Cancel {
            const Kind = @FieldType(Action.Cancel, "kind");
            const kind_count_cancel = std.enums.values(Kind).len;
            const kind_index = choose(smith, kind_count_cancel, "cancel kind");
            const kind: Kind = @fromBackingInt(@intCast(kind_index));
            const holds = choose(smith, 2, "cancel holds key") == 0;
            const key = keys[choose(smith, keys.len, "cancel key")];
            return .{ .kind = kind, .key_held = if (holds) key else null };
        }

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

        pub fn quiesce(self: *Self) void {
            const win = self.window();
            var round: u32 = 0;
            while (round < quiescence_round_max) : (round += 1) {
                if (win.frame_in_flight.load(.acquire)) self.present();
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

        fn checkStableRebuild(self: *Self) void {
            const win = self.window();
            if (win.frame_in_flight.load(.acquire)) return;
            if (win.awaiting_flip or win.render_requested) return;
            if (win.queue.count > 0) return;
            if (ringPending(win)) return;
            if (win.renderDeadlineNs() != null) return;
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

        fn queueHasRoom(self: *Self, event_count: u32, text_bytes: u32) bool {
            assert(event_count > 0);
            const queue = &self.window().queue;
            assert(queue.text_len <= queue.text_bytes.len);
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
            if (job_runs != .main_thread) assert(!ringPending(win));
            self.ring_answer_count = 0;
            self.model.endDrain(win, published);
            self.checkDrained(published, opened_count_before);
        }

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

        fn releaseHeld(self: *Self, button: input.MouseButton) void {
            self.held.release(button);
            if (self.gesture.held and self.gesture.button == button) self.gesture = .idle;
        }

        fn pointerEventCount(self: *const Self) u32 {
            if (self.held.any()) return pointer_event_count_max + release_event_count;
            return pointer_event_count_max;
        }

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

        fn generatePressPoint(self: *Self, smith: *Smith) Point {
            const frame = self.window().rendered();
            const hits = frame.hits[0..frame.hit_count];
            const on_draggable = choose(smith, 10, "press on draggable") != 0;
            const count = countKind(hits, .draggable);
            if (!on_draggable or count == 0) return self.generatePoint(smith);
            const index = nthKind(hits, .draggable, choose(smith, count, "draggable"));
            return self.clampToWindow(pointIn(smith, hits[index].bounds));
        }

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

        fn generateScroll(self: *Self, smith: *Smith) Action.Scroll {
            const delta_choices = [_]f32{ -400, -40, -1, 1, 40, 400 };
            const point = self.generatePoint(smith);
            return .{
                .x = point.x,
                .y = point.y,
                .delta_y = delta_choices[choose(smith, delta_choices.len, "scroll delta")],
            };
        }

        fn generatePoint(self: *Self, smith: *Smith) Point {
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

fn ringPending(win: *Window) bool {
    const ring = &win.completions;
    const head = ring.head.load(.acquire);
    const tail = ring.tail.load(.monotonic);
    assert(head -% tail <= ring.slots.len);
    return head != tail;
}

fn jobTurn(phase: internals.jobs.Phase, options: struct {
    posts: bool,
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
        .interrupting => return if (options.posts) .post else .end,
    }
}

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

fn fillPixels(pixels: []u8, decode: *const Action.ImageDecode) void {
    assert(decode.failure == null);
    assert(pixels.len == @as(usize, decode.width) * decode.height * 4);
    for (pixels, 0..) |*byte, index| {
        byte.* = @truncate(index *% 31 +% decode.entry *% 7 +% decode.width);
    }
}

pub const Bias = struct {
    area: records.Rect,
    alternate: ?records.Rect,
};

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

fn dropTargetTop(hits: []const records.HitRecord) f32 {
    var top: f32 = std.math.floatMax(f32);
    for (hits) |*record| {
        if (isKind(record, .drop_target)) top = @min(top, record.bounds.y);
    }
    assert(top < std.math.floatMax(f32));
    return top;
}

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

fn fraction(smith: *Smith) f32 {
    const thousandths = choose(smith, 1001, "fraction");
    assert(thousandths <= 1000);
    return @as(f32, @floatFromInt(thousandths)) / 1000;
}

fn choose(smith: *Smith, count: u64, comptime site: []const u8) u32 {
    assert(count > 0);
    assert(count <= std.math.maxInt(u32));
    const hash = comptime std.hash.Fnv1a_32.hash(site);
    const choice: u32 = @intCast(smith.valueWithHash(u64, hash) % count);
    assert(choice < count);
    return choice;
}

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
    const result = try runPairedSeed(.drag_drop, 4);
    try std.testing.expect(result.stats.drags_completed > 0);
    const list = try runPairedSeed(.virtual_list, 1);
    try std.testing.expect(list.stats.rows_seen > 0);
    const panes = try runPairedSeed(.splitter, 6);
    try std.testing.expect(panes.stats.drags_moved > 0);
    const fired = try runPairedSeed(.actions, 1);
    var fire_count: u32 = 0;
    for (fired.stats.fired) |count| fire_count += count;
    try std.testing.expect(fire_count > 0);
    const overlay = try runPairedSeed(.nested_overlay, 4);
    try std.testing.expect(overlay.stats.menu_frames > 0);
    const area = try runPairedSeed(.text_area, 1);
    try std.testing.expect(area.stats.checks.frames > 0);
    const images = try runPairedSeed(.images, 1);
    try std.testing.expect(images.stats.landed > 0);
    try std.testing.expect(images.stats.drawn > 0);
    const dialogs = try runPairedSeed(.file_dialog, 9);
    try std.testing.expect(dialogs.stats.completions > 0);
    try std.testing.expect(dialogs.stats.refused_waiting > 0);
    const dialogs_full = try runPairedSeed(.file_dialog, 2);
    try std.testing.expect(dialogs_full.stats.refused_full > 0);
    const interrupted = try runPairedSeed(.jobs, 7);
    try std.testing.expect(interrupted.stats.cancels_interrupting > 0);
    try std.testing.expect(interrupted.stats.posts_refused > 0);
    try std.testing.expect(interrupted.stats.results_dropped > 0);
    const busy = try runPairedSeed(.jobs, 2);
    try std.testing.expect(busy.stats.refused > 0);
    try std.testing.expect(busy.stats.cancels_stale_reused > 0);
    const chained = try runPairedSeed(.jobs, 5);
    try std.testing.expect(chained.stats.chained_full > 0);
    const main_thread = try runPairedSeed(.jobs_main_thread, 1);
    try std.testing.expect(main_thread.stats.runs_batched > 0);
    try std.testing.expect(main_thread.stats.runs_deferred > 0);
    try std.testing.expect(main_thread.stats.chained_full > 0);
}

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
    unreachable;
}

test "a List scrolled by a target rebuilds the same rows" {
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
            vopr_instance.quiesce();
            try std.testing.expect(vopr_instance.stable_rebuild_count > rebuilds);
        }
    }
}
