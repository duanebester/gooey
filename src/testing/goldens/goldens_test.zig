//! Golden checks: replay each trace and compare with the checked-in text.
//!
//! The `legacy_*.txt` files were captured from the 0.3.1 runtime before the
//! port to the 0.4.0 core, and are kept fixed now that the 0.3.1 examples are
//! gone. They are the oracle the core's own run is checked against. This
//! binary is built with the synthetic text backend, so the goldens match on
//! every host. Recapture the core goldens with `zig build goldens`.

const std = @import("std");
const gooey = @import("gooey");
const trace = @import("trace.zig");
const core = @import("core.zig");
const compare = @import("compare.zig");

test {
    _ = @import("core_checks.zig");
}

const TextBuffer = gooey.testing.record_dump.TextBuffer;

/// Bytes reserved for one trace's dump. The todo trace is the largest.
pub const golden_bytes_max: u32 = 2 * 1024 * 1024;

const Capture = *const fn (std.mem.Allocator, std.Io, *TextBuffer) anyerror!void;

fn expectGolden(name: []const u8, expected: []const u8, capture: Capture) !void {
    const storage = try std.testing.allocator.alloc(u8, golden_bytes_max);
    defer std.testing.allocator.free(storage);
    var out = TextBuffer.init(storage, name);
    try capture(std.testing.allocator, std.testing.io, &out);
    try std.testing.expect(trace.matches(name, expected, out.slice()));
}

test "core counter matches its golden" {
    try expectGolden("core_counter", @embedFile("core_counter.txt"), core.captureCounter);
}

test "core todo matches its golden" {
    try expectGolden("core_todo", @embedFile("core_todo.txt"), core.captureTodo);
}

test "core actions matches its golden" {
    try expectGolden("core_actions", @embedFile("core_actions.txt"), core.captureActions);
}

test "the core actions example dispatches what 0.3.1 does" {
    // Goal: keymaps, key contexts, and action handlers behave as 0.3.1's.
    // Methodology: the same chords, with and without the editor's context
    // on the focus path, must leave identical frames.
    const unexplained = try compare.compare(
        std.testing.allocator,
        @embedFile("legacy_actions.txt"),
        @embedFile("core_actions.txt"),
        &actions_known_differences,
    );
    try std.testing.expectEqual(@as(u32, 0), unexplained);
}

/// 0.3.1's example uses the bare `ui.input` primitive with fixed colours;
/// the core uses the `TextInput` component, themed as in the todo golden,
/// and gives it the textbox node 0.3.1's primitive never had.
const actions_known_differences = [_]compare.KnownDifference{
    actionsInput(
        "fill (24.00 101.60 200.00 37.20) #ffffffff 4.00,4.00,4.00,4.00",
        "fill (24.00 101.60 200.00 37.20) #e6e9eeff 8.00,8.00,8.00,8.00",
    ),
    actionsInput(
        "border (24.00 101.60 200.00 37.20) 1.00,1.00,1.00,1.00 #ccccccff 4.00,4.00,4.00,4.00",
        "border (24.00 101.60 200.00 37.20) 1.00,1.00,1.00,1.00 #9b9eb14d 8.00,8.00,8.00,8.00",
    ),
    actionsInput(
        "border (24.00 101.60 200.00 37.20) 1.00,1.00,1.00,1.00 #4c7fffff 4.00,4.00,4.00,4.00",
        "border (24.00 101.60 200.00 37.20) 1.00,1.00,1.00,1.00 #1e66f5ff 8.00,8.00,8.00,8.00",
    ),
    actionsInput(
        "glyphs n=28 (33.00 113.50 199.50 11.50) color=#999999ff hash=f4f7c7a2",
        "glyphs n=28 (33.00 113.50 199.50 11.50) color=#9b9eb1ff hash=f4f7c7a2",
    ),
    actionsInput(
        "glyphs n=2 (33.00 113.50 11.50 11.50) color=#000000ff hash=cd6c9ee5",
        "glyphs n=2 (33.00 113.50 11.50 11.50) color=#4c4f69ff hash=cd6c9ee5",
    ),
    actionsInput(
        "fill (33.00 110.60 1.50 19.20) #000000ff -",
        "fill (33.00 110.60 1.50 19.20) #4c4f69ff -",
    ),
    actionsInput(
        "fill (45.00 110.60 1.50 19.20) #000000ff -",
        "fill (45.00 110.60 1.50 19.20) #4c4f69ff -",
    ),
    actionsInput("", "textbox (24.00 101.60 200.00 37.20) name=\"Type here... (cmd+s to save)\""),
    actionsInput(
        "",
        "textbox (24.00 101.60 200.00 37.20) name=\"Type here... (cmd+s to save)\" focused",
    ),
    actionsInput(
        "",
        "textbox (24.00 101.60 200.00 37.20) name=\"Type here... (cmd+s to save)\" value=\"hi\"",
    ),
    actionsInput(
        "",
        "textbox (24.00 101.60 200.00 37.20) name=\"Type here... (cmd+s to save)\" " ++
            "value=\"hi\" focused",
    ),
};

fn actionsInput(legacy_line: []const u8, core_line: []const u8) compare.KnownDifference {
    return .{
        .step = null,
        .legacy_line = legacy_line,
        .core_line = core_line,
        .reason = "0.3.1's bare ui.input against the themed core TextInput",
    };
}

test "the core counter draws, hits, and announces what 0.3.1 does" {
    // Goal: the port is checked against the 0.3.1 oracle. Methodology: the
    // normalization in `compare.zig` removes recording differences only;
    // every remaining difference fails the test.
    const unexplained = try compare.compare(
        std.testing.allocator,
        @embedFile("legacy_counter.txt"),
        @embedFile("core_counter.txt"),
        &.{},
    );
    try std.testing.expectEqual(@as(u32, 0), unexplained);
}

test "the core todo draws, hits, and announces what 0.3.1 does" {
    const unexplained = try compare.compare(
        std.testing.allocator,
        @embedFile("legacy_todo.txt"),
        @embedFile("core_todo.txt"),
        &todo_known_differences,
    );
    try std.testing.expectEqual(@as(u32, 0), unexplained);
}

const todo_known_differences = [_]compare.KnownDifference{.{
    .step = 18,
    .legacy_line = "fill (83.70 507.20 124.80 28.80) #839496ff 8.00,8.00,8.00,8.00",
    .core_line = "fill (83.70 507.20 124.80 28.80) #839496d9 8.00,8.00,8.00,8.00",
    .reason = "the pointer rests on Clear completed after clicking it; the core keeps " ++
        "the button hovered, 0.3.1 drops its hover once the click empties the list",
}};

test "a replayed trace is byte-identical" {
    // Goal: goldens are stable. Methodology: run the same trace twice in one
    // process and require identical bytes; any dependence on the clock,
    // allocation addresses, or leftover state shows up as a difference.
    const first = try std.testing.allocator.alloc(u8, golden_bytes_max);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(u8, golden_bytes_max);
    defer std.testing.allocator.free(second);
    var out_first = TextBuffer.init(first, "first");
    var out_second = TextBuffer.init(second, "second");
    try core.captureTodo(std.testing.allocator, std.testing.io, &out_first);
    try core.captureTodo(std.testing.allocator, std.testing.io, &out_second);
    try std.testing.expectEqualStrings(out_first.slice(), out_second.slice());
}
