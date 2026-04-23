//! Hot Reload Watcher
//!
//! Watches the src directory for .zig file changes and automatically
//! rebuilds and restarts the application.
//!
//! Usage: zig build hot
//! Usage: zig build hot -- run-counter  (to run a specific target)
//!
//! ## Implementation Notes
//!
//! **File Time Tracking**: The watcher maintains a hashmap of file paths to
//! modification times. Key ownership follows this pattern:
//! - When a NEW file is detected: the allocated path string is transferred to
//!   the hashmap (hashmap owns the memory)
//! - When an EXISTING file changes: the path is freed immediately after lookup
//!   since the hashmap already owns a copy
//! - On put() failure: the path is freed to prevent leaks
//!
//! **Process Group Handling**: Child processes are spawned as process group
//! leaders (pgid=0). This allows killing the entire process tree on reload,
//! including grandchild processes spawned by `zig build run`.

const std = @import("std");
const posix = std.posix;
const Dir = std.Io.Dir;
const Io = std.Io;

// =============================================================================
// Inline Time Helpers (watcher is a standalone exe — cannot import platform/)
// =============================================================================

/// Wall-clock milliseconds since Unix epoch via gettimeofday.
fn milliTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    const rc = std.c.gettimeofday(&tv, null);
    std.debug.assert(rc == 0);
    const sec_ms: i64 = tv.sec * std.time.ms_per_s;
    const usec_ms: i64 = @divTrunc(tv.usec, std.time.us_per_ms);
    return sec_ms + usec_ms;
}

/// Sleep for `ns` nanoseconds using C nanosleep, restarting on EINTR.
fn sleep(ns: u64) void {
    const sec: std.c.time_t = @intCast(ns / std.time.ns_per_s);
    const nsec: c_long = @intCast(ns % std.time.ns_per_s);
    var ts = std.c.timespec{ .sec = sec, .nsec = nsec };
    while (true) {
        const rc = std.c.nanosleep(&ts, &ts);
        if (rc == 0) break;
        // Interrupted by signal — remaining time written back to ts.
    }
}

// =============================================================================
// Configuration
// =============================================================================

const poll_interval_ms = 300;
const debounce_ms = 100;

/// Maximum number of files to track (per CLAUDE.md: "put a limit on everything")
/// Prevents unbounded memory growth if pointed at a large directory tree.
const MAX_WATCHED_FILES: usize = 10_000;

// =============================================================================
// Global State for Signal Handling
// =============================================================================

var should_quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var global_watcher: ?*Watcher = null;

// =============================================================================
// Entry Point
// =============================================================================

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

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
    std.debug.print("│  Max files: {d:<22}│\n", .{MAX_WATCHED_FILES});
    std.debug.print("│  Press Ctrl+C to stop               │\n", .{});
    std.debug.print("└─────────────────────────────────────┘\n", .{});
    std.debug.print("\n", .{});

    var watcher = Watcher.init(allocator, init.io, watch_path, build_cmd);
    defer watcher.deinit();

    // Set up global pointer for signal handler
    global_watcher = &watcher;
    defer {
        global_watcher = null;
    }

    // Install signal handlers for clean shutdown
    const handler = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = 0,
        .flags = 0,
    };
    _ = posix.sigaction(posix.SIG.INT, &handler, null);
    _ = posix.sigaction(posix.SIG.TERM, &handler, null);

    watcher.run();

    std.debug.print("\n👋 Goodbye!\n", .{});
}

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    should_quit.store(true, .release);

    // Also kill the child immediately from the signal handler.
    if (global_watcher) |w| {
        if (w.child) |*child| {
            const pid = child.id orelse return;
            _ = posix.kill(-pid, posix.SIG.TERM) catch {};
        }
    }
}

// =============================================================================
// Watcher Implementation
// =============================================================================

const Watcher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    watch_path: []const u8,
    build_cmd: []const []const u8,
    file_times: std.StringHashMap(i96),
    child: ?std.process.Child,
    last_change: i64,
    max_files_warning_shown: bool,

    fn init(allocator: std.mem.Allocator, io: Io, watch_path: []const u8, build_cmd: []const []const u8) Watcher {
        return .{
            .allocator = allocator,
            .io = io,
            .watch_path = watch_path,
            .build_cmd = build_cmd,
            .file_times = std.StringHashMap(i96).init(allocator),
            .child = null,
            .last_change = 0,
            .max_files_warning_shown = false,
        };
    }

    fn deinit(self: *Watcher) void {
        self.killChild();

        // Free all owned path strings in the hashmap
        var it = self.file_times.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.file_times.deinit();
    }

    fn run(self: *Watcher) void {
        // Initial scan to populate file times
        _ = self.scanForChanges() catch return;

        // Initial build and run
        std.debug.print("🔨 Building...\n", .{});
        self.spawnChild();

        // Watch loop
        while (!should_quit.load(.acquire)) {
            sleep(poll_interval_ms * std.time.ns_per_ms);

            if (should_quit.load(.acquire)) break;

            if (self.scanForChanges() catch false) {
                const now = milliTimestamp();

                // Debounce rapid changes (editors often write multiple times)
                if (now - self.last_change < debounce_ms) {
                    continue;
                }
                self.last_change = now;

                std.debug.print("\n🔄 Change detected, rebuilding...\n", .{});

                self.killChild();

                // Small delay to ensure file writes are complete
                sleep(50 * std.time.ns_per_ms);

                self.spawnChild();
            }
        }
    }

    fn scanForChanges(self: *Watcher) !bool {
        var changed = false;
        var dir = Dir.cwd().openDir(self.io, self.watch_path, .{ .iterate = true }) catch |err| {
            std.debug.print("⚠️  Failed to open {s}: {}\n", .{ self.watch_path, err });
            return false;
        };
        defer dir.close(self.io);

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

            // Check file limit before adding new files
            if (self.file_times.count() >= MAX_WATCHED_FILES) {
                if (!self.max_files_warning_shown) {
                    std.debug.print("⚠️  Maximum watched files limit reached ({d}). Some files may not be monitored.\n", .{MAX_WATCHED_FILES});
                    self.max_files_warning_shown = true;
                }
                break;
            }

            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.watch_path, entry.path });

            const stat = Dir.cwd().statFile(self.io, full_path, .{}) catch |err| {
                std.debug.print("⚠️  Failed to stat {s}: {}\n", .{ full_path, err });
                self.allocator.free(full_path);
                continue;
            };

            const mtime = stat.mtime.nanoseconds;

            if (self.file_times.get(full_path)) |old_time| {
                // File already tracked - check if modified
                if (mtime != old_time) {
                    self.file_times.put(full_path, mtime) catch {};
                    changed = true;
                    std.debug.print("   📝 {s}\n", .{entry.path});
                }
                // Free the newly allocated path - hashmap already owns a copy of the key
                self.allocator.free(full_path);
            } else {
                // New file - transfer ownership of full_path to hashmap
                // DO NOT free full_path here; the hashmap now owns it
                self.file_times.put(full_path, mtime) catch {
                    // On failure, we must free since hashmap didn't take ownership
                    self.allocator.free(full_path);
                };
            }
        }

        return changed;
    }

    fn spawnChild(self: *Watcher) void {
        // Spawn as process group leader (pgid = 0 means use child's pid).
        // This allows us to kill the entire process tree on reload, including
        // any grandchild processes (like the actual app spawned by `zig build run`).
        const child = std.process.spawn(self.io, .{
            .argv = self.build_cmd,
            .pgid = 0,
        }) catch |err| {
            std.debug.print("⚠️  Failed to spawn build: {}\n", .{err});
            return;
        };
        self.child = child;
        std.debug.print("🚀 Running...\n\n", .{});
    }

    fn killChild(self: *Watcher) void {
        if (self.child) |*child| {
            // Kill the entire process group (negative pid = process group).
            // Since we set pgid=0 when spawning, the child's pid IS the pgid.
            // This ensures we kill both zig AND the spawned application.
            const pid = child.id orelse {
                self.child = null;
                return;
            };

            // Send SIGTERM to entire process group.
            _ = posix.kill(-pid, posix.SIG.TERM) catch {};

            // Give processes a moment to clean up.
            sleep(100 * std.time.ns_per_ms);

            // Force kill if still running.
            _ = posix.kill(-pid, posix.SIG.KILL) catch {};

            _ = child.wait(self.io) catch {};
            self.child = null;
        }
    }
};
