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
        &.{.{
            .step = null,
            .legacy_line = "fill (0.00 0.00 500.00 350.00) #f2f2f2ff -",
            .core_line = "fill (0.00 0.00 580.00 350.00) #f2f2f2ff -",
            .reason = "the counter window is 580 px wide so its controls row fits " ++
                "DejaVu Sans (#55); every control keeps its 0.3.1 position",
        }},
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

const todo_known_differences = [_]compare.KnownDifference{
    .{
        .step = 18,
        .legacy_line = "fill (83.70 507.20 124.80 28.80) #839496ff 8.00,8.00,8.00,8.00",
        .core_line = "fill (83.70 507.20 124.80 28.80) #839496d9 8.00,8.00,8.00,8.00",
        .reason = "the pointer rests on Clear completed after clicking it; the core keeps " ++
            "the button hovered, 0.3.1 drops its hover once the click empties the list",
    },
    todoInputRow(
        "border (24.00 74.60 360.00 37.20) 1.00,1.00,1.00,1.00 #1e66f5ff 8.00,8.00,8.00,8.00",
        "border (24.00 74.60 349.60 37.20) 1.00,1.00,1.00,1.00 #1e66f5ff 8.00,8.00,8.00,8.00",
    ),
    todoInputRow(
        "border (24.00 74.60 360.00 37.20) 1.00,1.00,1.00,1.00 #9b9eb14d 8.00,8.00,8.00,8.00",
        "border (24.00 74.60 349.60 37.20) 1.00,1.00,1.00,1.00 #9b9eb14d 8.00,8.00,8.00,8.00",
    ),
    todoInputRow(
        "button (392.00 73.60 74.40 39.20) name=\"Add\"",
        "button (381.60 73.60 74.40 39.20) name=\"Add\"",
    ),
    todoInputRow(
        "fill (24.00 74.60 360.00 37.20) #e6e9eeff 8.00,8.00,8.00,8.00",
        "fill (24.00 74.60 349.60 37.20) #e6e9eeff 8.00,8.00,8.00,8.00",
    ),
    todoInputRow(
        "fill (392.00 73.60 74.40 39.20) #1e66f5d9 8.00,8.00,8.00,8.00",
        "fill (381.60 73.60 74.40 39.20) #1e66f5d9 8.00,8.00,8.00,8.00",
    ),
    todoInputRow(
        "fill (392.00 73.60 74.40 39.20) #1e66f5ff 8.00,8.00,8.00,8.00",
        "fill (381.60 73.60 74.40 39.20) #1e66f5ff 8.00,8.00,8.00,8.00",
    ),
    todoInputRow(
        "glyphs n=3 (416.00 84.50 24.50 11.50) color=#ffffffff hash=8973649f",
        "glyphs n=3 (405.50 84.50 25.00 11.50) color=#ffffffff hash=05494605",
    ),
    todoInputRow("hit (24.00 74.60 360.00 37.20) focus", "hit (24.00 74.60 349.60 37.20) focus"),
    todoInputRow("hit (392.00 73.60 74.40 39.20) click", "hit (381.60 73.60 74.40 39.20) click"),
    todoInputRow(
        "textbox (24.00 74.60 360.00 37.20) name=\"What needs doing?\"",
        "textbox (24.00 74.60 349.60 37.20) name=\"What needs doing?\"",
    ),
    todoInputRow(
        "textbox (24.00 74.60 360.00 37.20) name=\"What needs doing?\" focused",
        "textbox (24.00 74.60 349.60 37.20) name=\"What needs doing?\" focused",
    ),
    todoInputRow(
        "textbox (24.00 74.60 360.00 37.20) name=\"What needs doing?\" value=\"buy mil\" focused",
        "textbox (24.00 74.60 349.60 37.20) name=\"What needs doing?\" value=\"buy mil\" focused",
    ),
    todoInputRow(
        "textbox (24.00 74.60 360.00 37.20) name=\"What needs doing?\" value=\"buy milk\" focused",
        "textbox (24.00 74.60 349.60 37.20) name=\"What needs doing?\" value=\"buy milk\" focused",
    ),
    todoInputRow(
        "textbox (24.00 74.60 360.00 37.20) name=\"What needs doing?\" value=\"café\" focused",
        "textbox (24.00 74.60 349.60 37.20) name=\"What needs doing?\" value=\"café\" focused",
    ),
    todoListRow(
        "button (123.20 183.60 64.60 28.80) name=\"Delete\"",
        "button (381.40 183.60 64.60 28.80) name=\"Delete\"",
    ),
    todoListRow(
        "button (123.20 240.40 64.60 28.80) name=\"Delete\"",
        "button (381.40 240.40 64.60 28.80) name=\"Delete\"",
    ),
    todoListRow("button (144.80 183.60 64.60 28.80) name=\"Delete\"", ""),
    todoListRow(
        "fill (123.20 240.40 64.60 28.80) #d13d3dd9 8.00,8.00,8.00,8.00",
        "fill (381.40 240.40 64.60 28.80) #d13d3dd9 8.00,8.00,8.00,8.00",
    ),
    todoListRow(
        "fill (123.20 183.60 64.60 28.80) #d13d3dff 8.00,8.00,8.00,8.00",
        "fill (381.40 183.60 64.60 28.80) #d13d3dff 8.00,8.00,8.00,8.00",
    ),
    todoListRow(
        "fill (123.20 240.40 64.60 28.80) #d13d3dff 8.00,8.00,8.00,8.00",
        "fill (381.40 240.40 64.60 28.80) #d13d3dff 8.00,8.00,8.00,8.00",
    ),
    todoListRow("fill (144.80 183.60 64.60 28.80) #d13d3dff 8.00,8.00,8.00,8.00", ""),
    todoListRow(
        "glyphs n=6 (135.00 190.50 39.50 10.00) color=#ffffffff hash=feb88217",
        "glyphs n=6 (393.00 190.50 39.50 10.00) color=#ffffffff hash=e3b374fc",
    ),
    todoListRow(
        "glyphs n=6 (135.00 247.50 39.50 10.00) color=#ffffffff hash=2d5160b3",
        "glyphs n=6 (393.00 190.50 40.00 10.00) color=#ffffffff hash=c25c3fef",
    ),
    todoListRow(
        "glyphs n=6 (156.50 190.50 39.50 10.00) color=#ffffffff hash=52f33640",
        "glyphs n=6 (393.00 247.50 40.00 10.00) color=#ffffffff hash=5ced9b97",
    ),
    todoListRow("hit (123.20 183.60 64.60 28.80) click", "hit (381.40 183.60 64.60 28.80) click"),
    todoListRow("hit (123.20 240.40 64.60 28.80) click", "hit (381.40 240.40 64.60 28.80) click"),
    todoListRow("hit (144.80 183.60 64.60 28.80) click", ""),
    todoListRow(
        "fill (24.00 173.60 173.80 48.80) #ffffffff 8.00,8.00,8.00,8.00",
        "fill (24.00 173.60 432.00 48.80) #ffffffff 8.00,8.00,8.00,8.00",
    ),
    todoListRow(
        "fill (24.00 173.60 195.40 48.80) #ffffffff 8.00,8.00,8.00,8.00",
        "fill (24.00 230.40 432.00 48.80) #ffffffff 8.00,8.00,8.00,8.00",
    ),
    todoListRow("fill (24.00 230.40 173.80 48.80) #ffffffff 8.00,8.00,8.00,8.00", ""),
};

/// 0.3.1's todo input is a fixed 360 px, which pushes Add 10.4 px past the
/// window's 24 px padding at 480 wide and off screen in narrower windows.
/// The core's input fills the row beside Add, so Add ends at the padding.
fn todoInputRow(legacy_line: []const u8, core_line: []const u8) compare.KnownDifference {
    return .{
        .step = null,
        .legacy_line = legacy_line,
        .core_line = core_line,
        .reason = "the todo input fills its row instead of a fixed 360 px",
    };
}

/// 0.3.1's todo rows fit their content, so Delete follows the text and a
/// long todo pushes it past a narrow window. The core's rows fill the list,
/// so Delete sits at each row's right end.
fn todoListRow(legacy_line: []const u8, core_line: []const u8) compare.KnownDifference {
    return .{
        .step = null,
        .legacy_line = legacy_line,
        .core_line = core_line,
        .reason = "the todo rows fill the list instead of fitting their content",
    };
}

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
