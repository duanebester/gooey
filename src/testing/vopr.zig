//! VOPR: deterministic simulation testing of the core, after TigerBeetle's.
//!
//! One generator, driven by `std.testing.Smith`, turns bytes into a stream of
//! actions against a headless app on the goldens' `CoreDriver`: pointer
//! clicks and moves aimed at the rendered frame's hit records, keys, committed
//! and composed text, clock gaps, and the two sides of a tick (`tickMain` and
//! `presentBuilt`) driven separately, so a frame stays in flight while input
//! keeps arriving. The same generator serves `zig build vopr -- [seed]`, whose
//! bytes come from a seeded PRNG, and a `std.testing.fuzz` target, whose bytes
//! come from the fuzzer.
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
//! `bytes_per_action_max` Smith bytes per step for the CLI.

const std = @import("std");
const gooey = @import("gooey");
const todo = @import("todo_example");
const core = @import("goldens/core.zig");
const trace_mod = @import("goldens/trace.zig");

const assert = std.debug.assert;

const Smith = std.testing.Smith;
const input = gooey.input;
const internals = gooey.internals;
const tick = internals.tick;
const records = internals.records;
const Window = internals.window.Window;

/// Steps one `zig build vopr` run takes before its quiescence loop.
pub const step_count_cli: u32 = 2_000;
/// Most steps one fuzz input may ask for, so one input is bounded work.
const step_count_fuzz_max: u32 = 256;
/// Most Smith choices one action makes, a text action's: its kind, its
/// length, and one per unit. Each choice reads one `u64`.
const choice_count_action_max: u32 = 2 + text_unit_count_max;
/// Smith bytes the CLI reserves per step, so its PRNG input never runs dry.
const bytes_per_action_max: u32 = choice_count_action_max * @sizeOf(u64);
/// Rounds of `tickMain` plus `presentBuilt` a run gets to settle at its end.
const quiescence_round_max: u32 = 8;
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
const text_alphabet = [_][]const u8{ "a", "b", "Z", "1", " ", "é" };

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

    const bytes = try gpa.alloc(u8, step_count_cli * bytes_per_action_max);
    defer gpa.free(bytes);

    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(bytes);
    const summary = try runPaired(todo.App, gpa, init.io, bytes, .{
        .step_count = step_count_cli,
        .verbose = options.verbose,
    });
    std.debug.print("vopr: todo seed {d} passed: {d} steps, frame {d}, {d} draws, " ++
        "dump hash {x:0>16}\n", .{
        seed,
        summary.step_count,
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
    gpa: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    options: RunOptions,
) !Summary {
    assert(options.step_count > 0);
    const V = Vopr(App);
    const first = try gpa.create(V);
    defer gpa.destroy(first);
    try first.initInPlace(gpa, io);
    defer first.deinit();

    const second = try gpa.create(V);
    defer gpa.destroy(second);
    try second.initInPlace(gpa, io);
    defer second.deinit();

    checkSame(V, first, second, 0);
    var smith_first: Smith = .{ .in = bytes };
    var smith_second: Smith = .{ .in = bytes };
    var step_index: u32 = 0;
    while (step_index < options.step_count) : (step_index += 1) {
        const action = first.generate(&smith_first);
        if (options.verbose) std.debug.print("step {d}: {f}\n", .{ step_index, action });
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
            .wait_ns => |gap_ns| try writer.print("wait {d} ns", .{gap_ns}),
            .tick_main => try writer.writeAll("tickMain"),
            .present => try writer.writeAll("presentBuilt"),
        }
    }
};

const ActionKind = std.meta.Tag(Action);

/// Relative weights of each action kind; ticks are common so frames move.
const kind_weights = [_]struct { kind: ActionKind, weight: u32 }{
    .{ .kind = .pointer, .weight = 24 },
    .{ .kind = .key, .weight = 16 },
    .{ .kind = .text, .weight = 10 },
    .{ .kind = .compose, .weight = 6 },
    .{ .kind = .wait_ns, .weight = 8 },
    .{ .kind = .tick_main, .weight = 24 },
    .{ .kind = .present, .weight = 12 },
};

const kind_weight_total: u32 = total: {
    var total: u32 = 0;
    for (kind_weights) |entry| total += entry.weight;
    break :total total;
};

pub fn Vopr(comptime App: type) type {
    return struct {
        driver: Driver,
        /// The highest `rendered().frame_number` seen; it must never drop.
        frame_number_rendered: u64,
        /// Rolling hash of every frame dump the renderer was asked to draw.
        dump_hasher: std.hash.Wyhash,
        /// Backing for the action being generated; the queue copies it.
        text_bytes: [text_bytes_action_max]u8,

        const Self = @This();
        const Driver = core.CoreDriver(App);

        /// Initialize in place (the app must not move), then settle the first
        /// frame so pointer actions have hit records to aim at.
        pub noinline fn initInPlace(self: *Self, gpa: std.mem.Allocator, io: std.Io) !void {
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
            self.dump_hasher = .init(0);
            self.text_bytes = @splat(0);
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
            const kind = chooseKind(smith);
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
            const in_flight = win.frame_in_flight.load(.acquire);
            if (win.render_requested or in_flight or win.awaiting_flip) {
                std.debug.panic("vopr: no quiescence after {d} rounds: render_requested " ++
                    "{}, frame_in_flight {}, awaiting_flip {}", .{
                    quiescence_round_max,
                    win.render_requested,
                    in_flight,
                    win.awaiting_flip,
                });
            }
            assert(win.phase == .idle);
            assert(win.render_phase == .idle);
        }

        pub fn summary(self: *Self, step_count: u32) Summary {
            assert(self.window().phase == .idle);
            return .{
                .step_count = step_count,
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
        /// text fit before the next drain.
        fn queueHasRoom(self: *Self, event_count: u32, text_bytes: u32) bool {
            const queue = &self.window().queue;
            assert(queue.text_len <= queue.text_bytes.len);
            const text_room: u64 = queue.text_bytes.len - queue.text_len;
            return queue.room() >= event_count and text_room >= text_bytes;
        }

        fn tickMain(self: *Self) void {
            const win = self.window();
            const published = tick.tickMain(&self.driver.app, win, self.driver.now_ns);
            if (published) assert(win.frame_in_flight.load(.acquire));
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

        /// Aim at a hit record of the rendered frame (its centre, an edge,
        /// or any point inside), or anywhere when the frame has none.
        fn generatePointer(self: *Self, smith: *Smith) Action.Pointer {
            const win = self.window();
            const frame = win.rendered();
            const viewport: records.Rect = .{
                .x = 0,
                .y = 0,
                .width = win.width,
                .height = win.height,
            };
            const target = if (frame.hit_count == 0)
                viewport
            else
                frame.hits[choose(smith, frame.hit_count, "hit")].bounds;
            const point = pointIn(smith, target);
            return .{
                .kind = if (choose(smith, 2, "pointer kind") == 0) .click else .move,
                .x = std.math.clamp(point.x, 0, win.width),
                .y = std.math.clamp(point.y, 0, win.height),
                .click_count = 1 + choose(smith, 2, "click count"),
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

fn chooseKind(smith: *Smith) ActionKind {
    var remaining = choose(smith, kind_weight_total, "kind");
    for (kind_weights) |entry| {
        if (remaining < entry.weight) return entry.kind;
        remaining -= entry.weight;
    }
    unreachable;
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
    const V = Vopr(todo.App);
    const vopr = try std.testing.allocator.create(V);
    defer std.testing.allocator.destroy(vopr);
    try vopr.initInPlace(std.testing.allocator, std.testing.io);
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
    const bytes = try std.testing.allocator.alloc(u8, step_count * bytes_per_action_max);
    defer std.testing.allocator.free(bytes);

    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(bytes);
    const summary = try runPaired(todo.App, std.testing.allocator, std.testing.io, bytes, .{
        .step_count = step_count,
        .verbose = false,
    });
    try std.testing.expectEqual(@as(u32, step_count), summary.step_count);
    try std.testing.expect(summary.frame_number > 10);
    try std.testing.expect(summary.draw_count >= summary.frame_number);
}
