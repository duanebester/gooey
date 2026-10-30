//! `zig build goldens`: rewrite every golden file from a fresh run.
//!
//! Run it after an intended change, then review the diff like code. The
//! binary is built with the synthetic text backend, so a capture on any host
//! produces the same bytes.

const std = @import("std");
const gooey = @import("gooey");
const legacy = @import("legacy.zig");
const core = @import("core.zig");
const goldens_test = @import("goldens_test.zig");

const TextBuffer = gooey.testing.record_dump.TextBuffer;
const Dir = std.Io.Dir;

const Capture = *const fn (std.mem.Allocator, std.Io, *TextBuffer) anyerror!void;

const Golden = struct { file_name: []const u8, capture: Capture };

const goldens = [_]Golden{
    .{ .file_name = "legacy_counter.txt", .capture = legacy.captureCounter },
    .{ .file_name = "legacy_todo.txt", .capture = legacy.captureTodo },
    .{ .file_name = "core_counter.txt", .capture = core.captureCounter },
    .{ .file_name = "core_todo.txt", .capture = core.captureTodo },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const storage = try allocator.alloc(u8, goldens_test.golden_bytes_max);
    defer allocator.free(storage);

    for (goldens) |golden| {
        var out = TextBuffer.init(storage, golden.file_name);
        try golden.capture(allocator, init.io, &out);
        try writeGolden(init.io, golden.file_name, out.slice());
    }
}

/// Golden files live beside this source file; the build runs this program
/// from the repository root.
fn writeGolden(io: std.Io, file_name: []const u8, bytes: []const u8) !void {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "src/testing/goldens/{s}", .{file_name});
    const file = try Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.flush();
    std.debug.print("goldens: wrote {s} ({d} bytes)\n", .{ path, bytes.len });
}
