//! Scripted input traces and the loop that turns one into a golden.
//!
//! A trace is a window size and a list of labelled steps. The runner renders
//! an initial frame, then for each step delivers its input events, renders
//! one frame, and records it: the packed frame the renderer received, the hit
//! records, and the accessibility tree. The same trace runs against the 0.3.1
//! runtime (`legacy.zig`) and the 0.4.0 core, so the two goldens are directly
//! comparable.
//!
//! Drivers are duck-typed with three methods, checked at comptime:
//! - `deliver(event: gooey.input.InputEvent) void`
//! - `frame() void`
//! - `writeRecord(out: *TextBuffer) void`, writing the three sections.

const std = @import("std");
const gooey = @import("gooey");

const assert = std.debug.assert;

const input = gooey.input;
const TextBuffer = gooey.testing.record_dump.TextBuffer;

pub const Point = struct { x: f32, y: f32 };

pub const Step = union(enum) {
    /// A primary-button press and release at one point.
    click: Point,
    /// A pointer move with no button down.
    move: Point,
    /// A key press and release with no modifiers and no characters.
    key: input.KeyCode,
    /// Committed text, as an IME or a plain key press delivers it.
    text: []const u8,
    /// IME preedit text; an empty string ends the composition.
    compose: []const u8,
};

pub const LabeledStep = struct {
    label: []const u8,
    step: Step,
};

pub const Trace = struct {
    name: []const u8,
    width: f32,
    height: f32,
    scale_factor: f32,
    steps: []const LabeledStep,
};

/// Most steps a trace may hold, so a golden's size is bounded.
pub const step_count_max: u32 = 64;

/// Run `trace` against `driver`, appending every recorded frame to `out`.
pub fn run(driver: anytype, trace: *const Trace, out: *TextBuffer) void {
    comptime verifyDriver(@TypeOf(driver));
    assert(trace.steps.len <= step_count_max);
    assert(trace.width > 0);

    out.print("trace {s} {d}x{d}@{d:.2}\n", .{
        trace.name,
        trace.width,
        trace.height,
        trace.scale_factor,
    });
    driver.frame();
    out.print("\n== step 0: initial frame\n", .{});
    driver.writeRecord(out);

    for (trace.steps, 1..) |*labeled, index| {
        deliverStep(driver, labeled.step);
        driver.frame();
        out.print("\n== step {d}: {s}\n", .{ index, labeled.label });
        driver.writeRecord(out);
    }
}

fn deliverStep(driver: anytype, step: Step) void {
    switch (step) {
        .click => |point| {
            driver.deliver(.{ .mouse_down = mouseEvent(point, 1) });
            driver.deliver(.{ .mouse_up = mouseEvent(point, 1) });
        },
        .move => |point| driver.deliver(.{ .mouse_moved = mouseEvent(point, 0) }),
        .key => |key| {
            driver.deliver(.{ .key_down = keyEvent(key) });
            driver.deliver(.{ .key_up = keyEvent(key) });
        },
        .text => |text| {
            assert(text.len > 0);
            driver.deliver(.{ .text_input = .{ .text = text } });
        },
        .compose => |text| driver.deliver(.{ .composition = .{ .text = text } }),
    }
}

fn mouseEvent(point: Point, click_count: u32) input.MouseEvent {
    assert(point.x >= 0);
    assert(point.y >= 0);
    return .{
        .position = .{ .x = point.x, .y = point.y },
        .button = .left,
        .click_count = click_count,
        .modifiers = .{},
    };
}

fn keyEvent(key: input.KeyCode) input.KeyEvent {
    return .{
        .key = key,
        .modifiers = .{},
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = false,
    };
}

fn verifyDriver(comptime Pointer: type) void {
    const Driver = switch (@typeInfo(Pointer)) {
        .pointer => |pointer| pointer.child,
        else => @compileError("trace.run takes a pointer to a driver, found " ++
            @typeName(Pointer)),
    };
    inline for (.{ "deliver", "frame", "writeRecord" }) |name| {
        if (!@hasDecl(Driver, name)) {
            @compileError(@typeName(Driver) ++ " is not a trace driver: missing " ++ name);
        }
    }
}

/// Compare `actual` with `expected` and describe the first differing line.
/// Returns true when they match. Goldens are long, so the report shows the
/// line number and both lines rather than the whole text.
pub fn matches(name: []const u8, expected: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, expected, actual)) return true;
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    var line_number: u32 = 1;
    while (line_number < 1_000_000) : (line_number += 1) {
        const want = expected_lines.next();
        const got = actual_lines.next();
        if (want == null and got == null) break;
        const same = want != null and got != null and std.mem.eql(u8, want.?, got.?);
        if (same) continue;
        std.debug.print(
            "golden '{s}' differs at line {d}\n  expected: {s}\n  actual:   {s}\n" ++
                "Run `zig build goldens` to recapture after an intended change.\n",
            .{ name, line_number, want orelse "<end>", got orelse "<end>" },
        );
        return false;
    }
    return false;
}
