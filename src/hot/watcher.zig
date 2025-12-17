//! Hot Reload Watcher
//!
//! Watches the src directory for .zig file changes and automatically
//! rebuilds and restarts the application.
//!
//! Usage: zig build hot
//! Usage: zig build hot -- run-counter  (to run a specific target)

const std = @import("std");

const poll_interval_ms = 300;
const debounce_ms = 100;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <watch_dir> <build_command...>\n", .{args[0]});
        std.debug.print("Example: {s} src zig build run\n", .{args[0]});
        return;
    }

    const watch_path = args[1];
    const build_cmd = args[2..];

    std.debug.print("\n", .{});
    std.debug.print("┌─────────────────────────────────────┐\n", .{});
    std.debug.print("│  🔥 Gooey Hot Reload                │\n", .{});
    std.debug.print("├─────────────────────────────────────┤\n", .{});
    std.debug.print("│  Watching: {s:<24}│\n", .{watch_path});
    std.debug.print("│  Press Ctrl+C to stop               │\n", .{});
    std.debug.print("└─────────────────────────────────────┘\n", .{});
    std.debug.print("\n", .{});

    var watcher = Watcher.init(allocator, watch_path, build_cmd);
    defer watcher.deinit();

    try watcher.run();
}

const Watcher = struct {
    allocator: std.mem.Allocator,
    watch_path: []const u8,
    build_cmd: []const []const u8,
    file_times: std.StringHashMap(i128),
    child: ?std.process.Child,
    last_change: i64,

    fn init(allocator: std.mem.Allocator, watch_path: []const u8, build_cmd: []const []const u8) Watcher {
        return .{
            .allocator = allocator,
            .watch_path = watch_path,
            .build_cmd = build_cmd,
            .file_times = std.StringHashMap(i128).init(allocator),
            .child = null,
            .last_change = 0,
        };
    }

    fn deinit(self: *Watcher) void {
        self.killChild();

        var it = self.file_times.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.file_times.deinit();
    }

    fn run(self: *Watcher) !void {
        // Initial scan to populate file times
        _ = try self.scanForChanges();

        // Initial build and run
        std.debug.print("🔨 Building...\n", .{});
        self.spawnChild();

        // Watch loop
        while (true) {
            std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);

            if (try self.scanForChanges()) {
                const now = std.time.milliTimestamp();

                // Debounce rapid changes (editors often write multiple times)
                if (now - self.last_change < debounce_ms) {
                    continue;
                }
                self.last_change = now;

                std.debug.print("\n🔄 Change detected, rebuilding...\n", .{});

                self.killChild();

                // Small delay to ensure file writes are complete
                std.Thread.sleep(50 * std.time.ns_per_ms);

                self.spawnChild();
            }
        }
    }

    fn scanForChanges(self: *Watcher) !bool {
        var changed = false;
        var dir = std.fs.cwd().openDir(self.watch_path, .{ .iterate = true }) catch |err| {
            std.debug.print("⚠️  Failed to open {s}: {}\n", .{ self.watch_path, err });
            return false;
        };
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.watch_path, entry.path });

            const stat = std.fs.cwd().statFile(full_path) catch |err| {
                std.debug.print("⚠️  Failed to stat {s}: {}\n", .{ full_path, err });
                self.allocator.free(full_path);
                continue;
            };

            const mtime = stat.mtime;

            if (self.file_times.get(full_path)) |old_time| {
                if (mtime != old_time) {
                    self.file_times.put(full_path, mtime) catch {};
                    changed = true;
                    std.debug.print("   📝 {s}\n", .{entry.path});
                }
                self.allocator.free(full_path);
            } else {
                // New file - store it (don't free, hashmap owns it now)
                self.file_times.put(full_path, mtime) catch {
                    self.allocator.free(full_path);
                };
            }
        }

        return changed;
    }

    fn spawnChild(self: *Watcher) void {
        var child = std.process.Child.init(self.build_cmd, self.allocator);
        child.spawn() catch |err| {
            std.debug.print("⚠️  Failed to spawn build: {}\n", .{err});
            return;
        };
        self.child = child;
        std.debug.print("🚀 Running...\n\n", .{});
    }

    fn killChild(self: *Watcher) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.child = null;
        }
    }
};
