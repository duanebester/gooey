//! Golden checks: replay each trace and compare with the checked-in text.
//! Built with the synthetic text backend, so the goldens match on every
//! host; recapture with `zig build goldens` after an intended change.

const std = @import("std");
const gooey = @import("gooey");
const trace = @import("trace.zig");
const core = @import("core.zig");

test {
    _ = @import("core_checks.zig");
    _ = @import("jobs_checks.zig");
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

test "core grid matches its golden" {
    try expectGolden("core_grid", @embedFile("core_grid.txt"), core.captureGrid);
}

test "core truncation matches its golden" {
    const golden = @embedFile("core_truncation.txt");
    try expectGolden("core_truncation", golden, core.captureTruncation);
}

test "a replayed trace is byte-identical" {
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
