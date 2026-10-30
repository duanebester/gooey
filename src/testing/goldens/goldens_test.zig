//! Golden checks: replay each trace and compare with the checked-in text.
//!
//! The `legacy_*.txt` files were captured from the 0.3.1 runtime before the
//! port to the 0.4.0 core. They are the oracle the core's own run is checked
//! against. This binary is built with the synthetic text backend, so the
//! goldens match on every host. Recapture with `zig build goldens`.

const std = @import("std");
const gooey = @import("gooey");
const trace = @import("trace.zig");
const legacy = @import("legacy.zig");

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

test "legacy counter matches its golden" {
    try expectGolden("legacy_counter", @embedFile("legacy_counter.txt"), legacy.captureCounter);
}

test "legacy todo matches its golden" {
    try expectGolden("legacy_todo", @embedFile("legacy_todo.txt"), legacy.captureTodo);
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
    try legacy.captureTodo(std.testing.allocator, std.testing.io, &out_first);
    try legacy.captureTodo(std.testing.allocator, std.testing.io, &out_second);
    try std.testing.expectEqualStrings(out_first.slice(), out_second.slice());
}
