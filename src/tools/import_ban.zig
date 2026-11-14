//! `zig build import-ban`: fails when code reaches a 0.3.1 path that phase 6
//! deleted (plan §26, phase 6 exit).
//!
//! The old middle is gone, so an import of one of its paths only compiles if
//! someone recreates the file. This check catches both halves of that: a
//! `.zig` file that exists at a banned path, and an `@import` whose path
//! resolves to one. It runs from the repository root over `src`,
//! `components`, and `charts`, and the `test` step depends on it, so CI fails
//! on the first reintroduced path with its file and line.
//!
//! Bounds: at most `file_count_max` source files, each smaller than
//! `file_bytes_max` bytes; a tree past either fails fast and names the limit.

const std = @import("std");
const Dir = std.Io.Dir;

const assert = std.debug.assert;

/// The deleted 0.3.1 middle. An entry ending in `/` bans the directory.
pub const banned_paths = [_][]const u8{
    "src/app.zig",
    "src/cx.zig",
    "src/cx_tests.zig",
    "src/cx/",
    "src/runtime/",
    "src/context/",
    "src/ui/",
    "src/widgets/",
    "src/animation/",
    "src/debug/",
    "src/scene/",
    "src/file_dialog.zig",
    "src/validation.zig",
    "src/input/event.zig",
    "src/core/mod.zig",
    "src/testing/legacy_harness.zig",
    "src/testing/mock_clipboard.zig",
    "src/platform/mutex.zig",
    "src/platform/unified.zig",
    "src/platform/macos/display_link.zig",
    "src/platform/web/file_dialog.zig",
    "src/platform/web/image_loader.zig",
    "src/platform/linux/tests/",
    "components/src/core/",
};

const roots = [_][]const u8{ "src", "components", "charts" };

const file_count_max: u32 = 4_096;
const file_bytes_max: u32 = 1 << 20;
const path_bytes_max: u32 = 512;
const violation_count_max: u32 = 64;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const content = try arena.alloc(u8, file_bytes_max);
    var file_count: u32 = 0;
    var violation_count: u32 = 0;
    for (roots) |root| {
        var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            file_count += 1;
            if (file_count > file_count_max) {
                std.debug.panic("import-ban: more than file_count_max {d} source files", .{
                    file_count_max,
                });
            }
            var path_buffer: [path_bytes_max]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, entry.path });
            const bytes = Dir.cwd().readFile(io, path, content) catch |err| switch (err) {
                error.FileTooBig => fileTooBig(path),
                else => return err,
            };
            // A read that fills the buffer may have been cut short.
            if (bytes.len == content.len) fileTooBig(path);
            violation_count += checkFile(path, bytes);
            if (violation_count >= violation_count_max) break;
        }
    }
    assert(file_count > 0);
    if (violation_count > 0) {
        std.debug.print("import-ban: {d} reference(s) to deleted 0.3.1 paths\n", .{
            violation_count,
        });
        std.process.exit(1);
    }
}

fn fileTooBig(path: []const u8) noreturn {
    std.debug.panic("import-ban: {s} is not smaller than file_bytes_max {d}", .{
        path,
        file_bytes_max,
    });
}

/// Reports each banned reference in one file and returns how many it found.
fn checkFile(path: []const u8, bytes: []const u8) u32 {
    assert(path.len > 0);
    assert(bytes.len <= file_bytes_max);
    var count: u32 = 0;
    if (bannedPath(path)) |banned| {
        std.debug.print("{s}: file is at deleted 0.3.1 path {s}\n", .{ path, banned });
        count += 1;
    }
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        var rest = line;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |start| {
            rest = rest[start + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const target = rest[0..end];
            rest = rest[end..];
            var resolved_buffer: [path_bytes_max]u8 = undefined;
            const resolved = resolveImport(&resolved_buffer, path, target) orelse continue;
            if (bannedPath(resolved)) |banned| {
                std.debug.print("{s}:{d}: imports deleted 0.3.1 path {s} ({s})\n", .{
                    path, line_number, banned, target,
                });
                count += 1;
            }
        }
    }
    return count;
}

/// The repository-relative path an `@import` of a `.zig` file names, or null
/// for a module import (`"std"`, `"gooey"`) or a path outside the repository.
pub fn resolveImport(
    buffer: *[path_bytes_max]u8,
    importer: []const u8,
    target: []const u8,
) ?[]const u8 {
    assert(importer.len > 0);
    assert(target.len > 0);
    if (!std.mem.endsWith(u8, target, ".zig")) return null;
    const directory = std.fs.path.dirnamePosix(importer) orelse "";
    var parts: [64][]const u8 = undefined;
    var part_count: u32 = 0;
    var iterators = [_]std.mem.SplitIterator(u8, .scalar){
        std.mem.splitScalar(u8, directory, '/'),
        std.mem.splitScalar(u8, target, '/'),
    };
    for (&iterators) |*iterator| {
        while (iterator.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (part_count == 0) return null;
                part_count -= 1;
                continue;
            }
            if (part_count == parts.len) return null;
            parts[part_count] = part;
            part_count += 1;
        }
    }
    var length: usize = 0;
    for (parts[0..part_count], 0..) |part, index| {
        const separator: usize = if (index == 0) 0 else 1;
        if (length + separator + part.len > buffer.len) return null;
        if (separator == 1) buffer[length] = '/';
        length += separator;
        @memcpy(buffer[length..][0..part.len], part);
        length += part.len;
    }
    return buffer[0..length];
}

/// The banned entry `path` falls under, or null.
pub fn bannedPath(path: []const u8) ?[]const u8 {
    assert(path.len > 0);
    for (banned_paths) |banned| {
        assert(banned.len > 0);
        if (banned[banned.len - 1] == '/') {
            if (std.mem.startsWith(u8, path, banned)) return banned;
        } else {
            if (std.mem.eql(u8, path, banned)) return banned;
        }
    }
    return null;
}

test "bannedPath matches deleted files and directories, not their neighbours" {
    // Goal: each banned shape matches, and a name that only shares a prefix
    // with a banned directory or file does not. Method: one case per side.
    try std.testing.expectEqualStrings("src/ui/", bannedPath("src/ui/mod.zig").?);
    try std.testing.expectEqualStrings("src/cx.zig", bannedPath("src/cx.zig").?);
    try std.testing.expectEqualStrings(
        "components/src/core/",
        bannedPath("components/src/core/root.zig").?,
    );
    try std.testing.expect(bannedPath("src/uix/mod.zig") == null);
    try std.testing.expect(bannedPath("src/core/cx.zig") == null);
    try std.testing.expect(bannedPath("src/cx.zig.bak") == null);
    try std.testing.expect(bannedPath("src/core/root.zig") == null);
    // Phase 6: the scene directory and the old unified GPU structs.
    try std.testing.expectEqualStrings("src/scene/", bannedPath("src/scene/scene.zig").?);
    try std.testing.expectEqualStrings(
        "src/platform/unified.zig",
        bannedPath("src/platform/unified.zig").?,
    );
    try std.testing.expect(bannedPath("src/core/scene.zig") == null);
}

test "resolveImport follows relative paths from the importer" {
    // Goal: imports resolve to the repository path the compiler would open,
    // so `../context/x.zig` from `src/core/` is caught. Method: resolve
    // relative, sibling, and module imports and compare.
    var buffer: [path_bytes_max]u8 = undefined;
    const up = resolveImport(&buffer, "src/core/window.zig", "../context/a11y.zig").?;
    try std.testing.expectEqualStrings("src/context/a11y.zig", up);
    const sibling = resolveImport(&buffer, "src/root.zig", "cx.zig").?;
    try std.testing.expectEqualStrings("src/cx.zig", sibling);
    try std.testing.expect(resolveImport(&buffer, "src/root.zig", "std") == null);
    try std.testing.expect(resolveImport(&buffer, "src/root.zig", "../../x.zig") == null);
}

test "checkFile counts banned imports only" {
    // Goal: a file with one banned and one allowed import counts one
    // violation. Method: check a two-line source in memory.
    // Split so this file's own scan does not report the fixture.
    const source = "const theme = @import(\"theme.zig\");\n" ++
        "const cx = @" ++ "import(\"../cx.zig\");\n";
    try std.testing.expectEqual(@as(u32, 1), checkFile("src/core/element.zig", source));
    try std.testing.expectEqual(@as(u32, 0), checkFile("src/core/element.zig", "const a = 1;"));
}
