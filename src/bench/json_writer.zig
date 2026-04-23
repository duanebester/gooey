//! Benchmark JSON Reporter
//!
//! Collects benchmark results during a run and writes them to a JSON file
//! for CI artifact storage and cross-run comparison.  All collection storage
//! is fixed-capacity and stack-resident.  A single heap allocation occurs in
//! finish() via `std.json.Stringify.valueAlloc` to serialize the JSON payload;
//! this happens once at process exit.
//!
//! Usage:
//!   var reporter = Reporter.init("core");
//!   reporter.addEntry(entry("convex_8", 8, total_ns, iters));
//!   reporter.finish();
//!
//! When the process receives `--json-dir <path>`, the reporter writes:
//!   <path>/<os>-<arch>-<module>-benchmarks-<mm-dd-yyyy>.json

const std = @import("std");
const builtin = @import("builtin");
const Dir = std.Io.Dir;
const Io = std.Io;

// =============================================================================
// Limits
// =============================================================================

/// Maximum benchmark entries per module.  The largest module (core) has ~59
/// entries today; 256 provides generous headroom without blowing the stack.
const MAX_ENTRIES: u32 = 256;

/// Maximum benchmark name length in bytes.  Names like
/// "zigzag_128_tri_butt_miter" are well under this.
const MAX_NAME_LENGTH: u32 = 128;

/// Maximum file-system path length for the output directory.
const MAX_PATH_LENGTH: u32 = 512;

/// Maximum module name length (e.g. "context", "layout").
const MAX_MODULE_NAME_LENGTH: u32 = 64;

/// Maximum length of the generated filename (without directory).
/// Format: <os>-<arch>-<module>-benchmarks-<mm-dd-yyyy>.json
/// Worst case: "freestanding-powerpc64le-context-benchmarks-12-31-2099.json" = ~62 chars.
const MAX_FILENAME_LENGTH: u32 = 128;

// =============================================================================
// Platform Detection (comptime)
// =============================================================================

/// Operating system name for the JSON metadata and filename.
const os_name: []const u8 = @tagName(builtin.os.tag);

/// CPU architecture name for the JSON metadata and filename.
const arch_name: []const u8 = @tagName(builtin.cpu.arch);

// =============================================================================
// Entry — one benchmark result
// =============================================================================

/// A single benchmark measurement, stored in a fixed-size record.
/// All fields use explicitly-sized types for cross-platform consistency.
pub const Entry = struct {
    /// Benchmark name, null-padded to fixed length.
    name: [MAX_NAME_LENGTH]u8 = [_]u8{0} ** MAX_NAME_LENGTH,
    name_length: u32 = 0,

    /// Number of operations per iteration (vertex count, node count, etc.).
    operation_count: u32 = 0,

    /// Total wall-clock nanoseconds across all timed iterations.
    total_time_ns: u64 = 0,

    /// Number of timed iterations completed.
    iterations: u32 = 0,

    /// Whether percentile fields contain meaningful data.
    /// True only for text benchmarks that collect per-iteration samples.
    has_percentiles: bool = false,

    /// Median per-operation nanoseconds (text benchmarks only).
    p50_per_op_ns: f64 = 0.0,

    /// 99th-percentile per-operation nanoseconds (text benchmarks only).
    p99_per_op_ns: f64 = 0.0,

    /// Returns the populated slice of the name buffer.
    pub fn nameSlice(self: *const Entry) []const u8 {
        std.debug.assert(self.name_length <= MAX_NAME_LENGTH);
        return self.name[0..self.name_length];
    }

    /// Average time per iteration in milliseconds.
    pub fn avgTimeMs(self: *const Entry) f64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.total_time_ns > 0);
        const avg_ns: f64 = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        return avg_ns / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }

    /// Average nanoseconds per operation.
    pub fn timePerOpNs(self: *const Entry) f64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.operation_count > 0);
        const avg_ns: f64 = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        return avg_ns / @as(f64, @floatFromInt(self.operation_count));
    }
};

// =============================================================================
// Entry Constructors
// =============================================================================

/// Create an entry from the common benchmark result fields.
pub fn entry(
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
) Entry {
    std.debug.assert(name.len > 0);
    std.debug.assert(iterations > 0);

    var e: Entry = .{
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
    };
    const copy_length: u32 = @intCast(@min(name.len, MAX_NAME_LENGTH));
    @memcpy(e.name[0..copy_length], name[0..copy_length]);
    e.name_length = copy_length;
    return e;
}

/// Create an entry that includes p50/p99 percentile data (text benchmarks).
pub fn entryWithPercentiles(
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    p50_per_op_ns: f64,
    p99_per_op_ns: f64,
) Entry {
    std.debug.assert(p50_per_op_ns >= 0.0);
    std.debug.assert(p99_per_op_ns >= p50_per_op_ns);

    var e = entry(name, operation_count, total_time_ns, iterations);
    e.has_percentiles = true;
    e.p50_per_op_ns = p50_per_op_ns;
    e.p99_per_op_ns = p99_per_op_ns;
    return e;
}

// =============================================================================
// Calendar Date
// =============================================================================

const CalendarDate = struct {
    year: u16,
    month: u8, // 1–12
    day: u8, // 1–31
};

/// Derive the current UTC calendar date from the system clock.
///
/// Uses `std.Io.Clock.real` — wall-clock seconds since the Unix epoch — and
/// then reuses the existing `std.time.epoch` calendar arithmetic.  Only the
/// *source* of the seconds changes vs. Zig 0.15; the Y/M/D decomposition is
/// unchanged.
fn getCurrentDate(io: Io) CalendarDate {
    const timestamp_seconds: u64 = @intCast(@max(0, Io.Clock.real.now(io).toSeconds()));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = timestamp_seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const month_numeric: u8 = @intCast(month_day.month.numeric());
    // day_index is 0-based; calendar days are 1-based.
    const day_numeric: u8 = @intCast(month_day.day_index + 1);

    std.debug.assert(month_numeric >= 1);
    if (month_numeric > 12) unreachable;
    std.debug.assert(day_numeric >= 1);
    if (day_numeric > 31) unreachable;

    return .{
        .year = year_day.year,
        .month = month_numeric,
        .day = day_numeric,
    };
}

// =============================================================================
// JSON Serialization Types
// =============================================================================

/// Metadata block written at the top of every JSON report.
/// Field order here determines field order in the JSON output.
const JsonMetadata = struct {
    module: []const u8,
    os: []const u8,
    arch: []const u8,
    date: []const u8,
    timestamp_unix: u64,
    entry_count: u32,
};

/// One benchmark result in the JSON output.  Mirrors the Entry struct but
/// uses JSON-friendly types: `[]const u8` for name (not a fixed buffer),
/// `?f64` for nullable percentiles, and pre-computed derived fields.
const JsonBenchmarkEntry = struct {
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    avg_time_ms: f64,
    time_per_op_ns: f64,
    p50_per_op_ns: ?f64,
    p99_per_op_ns: ?f64,

    /// Convert from the fixed-capacity Entry to a JSON-serializable form.
    fn fromEntry(e: *const Entry) JsonBenchmarkEntry {
        std.debug.assert(e.name_length > 0);
        std.debug.assert(e.iterations > 0);

        return .{
            .name = e.nameSlice(),
            .operation_count = e.operation_count,
            .total_time_ns = e.total_time_ns,
            .iterations = e.iterations,
            .avg_time_ms = e.avgTimeMs(),
            .time_per_op_ns = e.timePerOpNs(),
            .p50_per_op_ns = if (e.has_percentiles) e.p50_per_op_ns else null,
            .p99_per_op_ns = if (e.has_percentiles) e.p99_per_op_ns else null,
        };
    }
};

/// Top-level JSON document structure.
const JsonPayload = struct {
    metadata: JsonMetadata,
    benchmarks: []const JsonBenchmarkEntry,
};

// =============================================================================
// Reporter
// =============================================================================

/// Collects benchmark entries and writes a JSON report file on finish().
///
/// All collection storage is inline — no heap allocation during benchmarking.
/// The reporter parses process argv at init time to detect `--json-dir <path>`.
/// If the flag is absent, finish() is a no-op and the reporter acts as a
/// silent sink.
pub const Reporter = struct {
    entries: [MAX_ENTRIES]Entry = undefined,
    count: u32 = 0,

    module_name: [MAX_MODULE_NAME_LENGTH]u8 = [_]u8{0} ** MAX_MODULE_NAME_LENGTH,
    module_name_length: u32 = 0,

    json_dir: [MAX_PATH_LENGTH]u8 = [_]u8{0} ** MAX_PATH_LENGTH,
    json_dir_length: u32 = 0,

    json_enabled: bool = false,

    /// I/O interface for file system operations (directory creation, file writing).
    /// Passed from the process entry point; defaults to `Io.failing` so that
    /// struct-literal initialisation (`.{}`) still compiles in tests where
    /// file I/O is never exercised.
    io: Io = Io.failing,

    /// Create a reporter for the given module.  Scans `argv` for
    /// `--json-dir <path>`.
    ///
    /// `argv` is passed explicitly (rather than reaching for a global) so
    /// callers can unit-test arg parsing with a fixed slice, and so the
    /// reporter never depends on platform-specific globals.  Benchmark
    /// `main` functions receive `std.process.Init` and forward
    /// `init.args.vector` here.
    pub fn init(
        module_name: []const u8,
        io: Io,
        argv: []const [*:0]const u8,
    ) Reporter {
        std.debug.assert(module_name.len > 0);
        std.debug.assert(module_name.len <= MAX_MODULE_NAME_LENGTH);

        var self: Reporter = .{};
        self.io = io;

        @memcpy(self.module_name[0..module_name.len], module_name);
        self.module_name_length = @intCast(module_name.len);

        self.parseArgs(argv);
        return self;
    }

    /// Append a benchmark entry to the collection.
    pub fn addEntry(self: *Reporter, e: Entry) void {
        std.debug.assert(e.name_length > 0);
        if (self.count >= MAX_ENTRIES) {
            std.debug.print(
                "bench: WARNING — entry limit ({d}) reached, dropping \"{s}\"\n",
                .{ MAX_ENTRIES, e.name[0..e.name_length] },
            );
            return;
        }
        self.entries[self.count] = e;
        self.count += 1;
    }

    /// Write the JSON file if `--json-dir` was provided.  Otherwise no-op.
    /// Call this once at the end of main().
    pub fn finish(self: *const Reporter) void {
        if (!self.json_enabled) return;

        self.writeJsonFile() catch |err| {
            std.debug.print(
                "bench: failed to write JSON: {s}\n",
                .{@errorName(err)},
            );
        };
    }

    // =========================================================================
    // Arg Parsing (private)
    // =========================================================================

    /// Scan `argv` for `--json-dir <path>`.  Zero allocation — the argv
    /// slice is borrowed from `std.process.Init.args.vector`.
    fn parseArgs(self: *Reporter, argv: []const [*:0]const u8) void {
        // argv may be empty under test runners; only assert non-negative.
        var i: u32 = if (argv.len >= 1) 1 else 0;
        const argc: u32 = @intCast(argv.len);
        while (i < argc) : (i += 1) {
            const arg = std.mem.sliceTo(argv[i], 0);
            if (!std.mem.eql(u8, arg, "--json-dir")) continue;

            // The directory path is the next argument.
            if (i + 1 >= argc) {
                std.debug.print("bench: --json-dir requires a path argument\n", .{});
                return;
            }
            const dir = std.mem.sliceTo(argv[i + 1], 0);
            if (dir.len == 0) {
                std.debug.print("bench: --json-dir path is empty\n", .{});
                return;
            }
            if (dir.len > MAX_PATH_LENGTH) {
                std.debug.print("bench: --json-dir path exceeds {d} bytes\n", .{MAX_PATH_LENGTH});
                return;
            }

            @memcpy(self.json_dir[0..dir.len], dir);
            self.json_dir_length = @intCast(dir.len);
            self.json_enabled = true;
            return;
        }
    }

    // =========================================================================
    // Filename Construction (private)
    // =========================================================================

    const FilenameBuffer = struct {
        buf: [MAX_PATH_LENGTH + MAX_FILENAME_LENGTH + 1]u8 = undefined, // +1 for path separator
        len: u32 = 0,
    };

    /// Build the full output path:
    ///   <json_dir>/<os>-<arch>-<module>-benchmarks-<mm-dd-yyyy>.json
    fn buildFilePath(self: *const Reporter) FilenameBuffer {
        std.debug.assert(self.json_dir_length > 0);
        std.debug.assert(self.module_name_length > 0);

        const date = getCurrentDate(self.io);
        var result: FilenameBuffer = .{};

        const written = std.fmt.bufPrint(&result.buf, "{s}" ++ "/" ++ "{s}-{s}-{s}-benchmarks-{d:0>2}-{d:0>2}-{d}.json", .{
            self.json_dir[0..self.json_dir_length],
            os_name,
            arch_name,
            self.module_name[0..self.module_name_length],
            date.month,
            date.day,
            date.year,
        }) catch {
            // Buffer overflow — path + filename exceeds capacity.
            std.debug.print("bench: output path too long\n", .{});
            return result;
        };

        result.len = @intCast(written.len);
        return result;
    }

    // =========================================================================
    // JSON Writing (private)
    // =========================================================================

    /// Write the complete JSON report to disk using `std.json` for serialization.
    /// Performs a single heap allocation via page_allocator to serialize the
    /// payload; this runs once at process exit so the allocation cost is
    /// irrelevant to benchmark timing.
    fn writeJsonFile(self: *const Reporter) !void {
        std.debug.assert(self.json_enabled);
        std.debug.assert(self.json_dir_length > 0);

        // Ensure output directory exists.
        const dir_path = self.json_dir[0..self.json_dir_length];
        Dir.cwd().createDirPath(self.io, dir_path) catch |err| {
            std.debug.print("bench: cannot create directory \"{s}\": {s}\n", .{ dir_path, @errorName(err) });
            return err;
        };

        const file_path = self.buildFilePath();
        if (file_path.len == 0) return error.PathTooLong;

        const path_slice = file_path.buf[0..file_path.len];

        const file = try Dir.cwd().createFile(self.io, path_slice, .{});
        defer file.close(self.io);

        // Build the JSON payload from collected entries.
        const json_bytes = try self.serializePayload();
        defer std.heap.page_allocator.free(json_bytes);

        // `file.writerStreaming` returns an `Io.File.Writer`; the actual
        // byte-sink methods live on its `.interface` (`std.Io.Writer`).
        // `File.Writer.flush` forwards to the interface flush and then
        // surfaces any latched error — use it at the end.
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(self.io, &write_buf);
        try writer.interface.writeAll(json_bytes);
        try writer.interface.writeAll("\n"); // Trailing newline for POSIX friendliness.
        try writer.flush();

        std.debug.print("\nbench: wrote {d} entries to {s}\n", .{ self.count, path_slice });
    }

    /// Convert collected entries to a JSON byte string via `std.json`.
    /// Caller owns the returned slice (allocated with page_allocator).
    fn serializePayload(self: *const Reporter) ![]u8 {
        std.debug.assert(self.count <= MAX_ENTRIES);
        std.debug.assert(self.module_name_length > 0);

        // Format the date string into a stack buffer.
        var date_buf: [16]u8 = undefined;
        const date = getCurrentDate(self.io);
        const date_str = std.fmt.bufPrint(&date_buf, "{d:0>2}-{d:0>2}-{d}", .{
            date.month,
            date.day,
            date.year,
        }) catch unreachable; // 16 bytes is always sufficient for "mm-dd-yyyy".

        // Convert fixed-capacity entries to JSON-serializable form.
        // 256 entries × ~72 bytes each ≈ 18 KB on the stack — well within budget.
        var json_entries: [MAX_ENTRIES]JsonBenchmarkEntry = undefined;
        for (0..self.count) |i| {
            json_entries[i] = JsonBenchmarkEntry.fromEntry(&self.entries[i]);
        }

        const timestamp_seconds: u64 = @intCast(@max(0, Io.Clock.real.now(self.io).toSeconds()));

        const payload: JsonPayload = .{
            .metadata = .{
                .module = self.module_name[0..self.module_name_length],
                .os = os_name,
                .arch = arch_name,
                .date = date_str,
                .timestamp_unix = timestamp_seconds,
                .entry_count = self.count,
            },
            .benchmarks = json_entries[0..self.count],
        };

        return std.json.Stringify.valueAlloc(
            std.heap.page_allocator,
            payload,
            .{ .whitespace = .indent_2 },
        );
    }
};

// =============================================================================
// Tests
// =============================================================================

test "entry: name is copied and truncated correctly" {
    const e = entry("convex_128", 128, 5000, 10);
    std.debug.assert(e.name_length == 10);
    std.debug.assert(std.mem.eql(u8, e.nameSlice(), "convex_128"));
    std.debug.assert(e.operation_count == 128);
    std.debug.assert(e.iterations == 10);
    std.debug.assert(!e.has_percentiles);
}

test "entry: avgTimeMs and timePerOpNs compute correctly" {
    // 1_000_000 ns total, 10 iterations → 100_000 ns avg → 0.1 ms.
    const e = entry("test", 100, 1_000_000, 10);
    const avg_ms = e.avgTimeMs();
    const per_op_ns = e.timePerOpNs();

    // 0.1 ms average.
    std.debug.assert(avg_ms > 0.099);
    std.debug.assert(avg_ms < 0.101);

    // 100_000 ns avg / 100 ops = 1000 ns/op.
    std.debug.assert(per_op_ns > 999.0);
    std.debug.assert(per_op_ns < 1001.0);
}

test "entryWithPercentiles: percentile fields are set" {
    const e = entryWithPercentiles("shaped_warm", 50, 2_000_000, 20, 42.5, 128.7);
    std.debug.assert(e.has_percentiles);
    std.debug.assert(e.p50_per_op_ns == 42.5);
    std.debug.assert(e.p99_per_op_ns == 128.7);
}

test "reporter: addEntry collects entries" {
    var reporter = Reporter.init("test_module", Io.failing, &.{});
    std.debug.assert(reporter.count == 0);
    std.debug.assert(!reporter.json_enabled); // No --json-dir in empty argv.

    reporter.addEntry(entry("bench_a", 10, 500, 5));
    reporter.addEntry(entry("bench_b", 20, 1000, 10));
    std.debug.assert(reporter.count == 2);
    std.debug.assert(std.mem.eql(u8, reporter.entries[0].nameSlice(), "bench_a"));
    std.debug.assert(std.mem.eql(u8, reporter.entries[1].nameSlice(), "bench_b"));
}

test "reporter: finish is no-op when json is disabled" {
    var reporter = Reporter.init("noop", Io.failing, &.{});
    reporter.addEntry(entry("x", 1, 100, 1));
    // Must not crash or attempt file I/O.
    reporter.finish();
}

test "getCurrentDate: returns plausible values" {
    // `std.testing.io` is the blessed per-test `Io` instance — backed by
    // `Io.Threaded` and initialised by the test runner for the lifetime
    // of each test.  It routes wall-clock reads through the real system
    // clock, unlike `Io.failing` which would return `Timestamp.zero`.
    const date = getCurrentDate(std.testing.io);
    std.debug.assert(date.year >= 2025);
    std.debug.assert(date.month >= 1);
    std.debug.assert(date.month <= 12);
    std.debug.assert(date.day >= 1);
    std.debug.assert(date.day <= 31);
}

test "reporter: buildFilePath produces expected format" {
    // Manually construct a reporter with a known dir and module.
    var reporter: Reporter = .{};
    const dir = "bench-results";
    @memcpy(reporter.json_dir[0..dir.len], dir);
    reporter.json_dir_length = dir.len;
    const mod = "core";
    @memcpy(reporter.module_name[0..mod.len], mod);
    reporter.module_name_length = mod.len;

    const result = reporter.buildFilePath();
    std.debug.assert(result.len > 0);
    const path = result.buf[0..result.len];

    // Path must start with the directory.
    std.debug.assert(std.mem.startsWith(u8, path, "bench-results/"));
    // Path must contain os and arch.
    std.debug.assert(std.mem.indexOf(u8, path, os_name) != null);
    std.debug.assert(std.mem.indexOf(u8, path, arch_name) != null);
    // Path must end with .json.
    std.debug.assert(std.mem.endsWith(u8, path, ".json"));
    // Path must contain the module name.
    std.debug.assert(std.mem.indexOf(u8, path, "-core-benchmarks-") != null);
}

test "JsonBenchmarkEntry.fromEntry: converts without percentiles" {
    const e = entry("test_bench", 64, 1_000_000, 10);
    const json_entry = JsonBenchmarkEntry.fromEntry(&e);

    std.debug.assert(std.mem.eql(u8, json_entry.name, "test_bench"));
    std.debug.assert(json_entry.operation_count == 64);
    std.debug.assert(json_entry.total_time_ns == 1_000_000);
    std.debug.assert(json_entry.iterations == 10);
    // Percentiles must be null when not collected.
    std.debug.assert(json_entry.p50_per_op_ns == null);
    std.debug.assert(json_entry.p99_per_op_ns == null);
}

test "JsonBenchmarkEntry.fromEntry: converts with percentiles" {
    const e = entryWithPercentiles("shaped_warm", 50, 2_000_000, 20, 42.5, 128.7);
    const json_entry = JsonBenchmarkEntry.fromEntry(&e);

    std.debug.assert(std.mem.eql(u8, json_entry.name, "shaped_warm"));
    std.debug.assert(json_entry.p50_per_op_ns.? == 42.5);
    std.debug.assert(json_entry.p99_per_op_ns.? == 128.7);
}

test "reporter: serializePayload produces valid JSON" {
    // `serializePayload` reads the wall clock (real-time) for the
    // `timestamp_unix` metadata field; route that through the
    // per-test `std.testing.io` instance (backed by `Io.Threaded`)
    // instead of `Io.failing`, which would return `Timestamp.zero`.
    var reporter = Reporter.init("test_mod", std.testing.io, &.{});
    reporter.addEntry(entry("alpha", 10, 500_000, 50));
    reporter.addEntry(entryWithPercentiles("beta", 20, 1_000_000, 100, 5.0, 15.0));

    const json_bytes = try reporter.serializePayload();
    defer std.heap.page_allocator.free(json_bytes);

    // Must parse without error.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_bytes, .{});
    defer parsed.deinit();

    // Verify top-level structure.
    const root = parsed.value.object;
    std.debug.assert(root.contains("metadata"));
    std.debug.assert(root.contains("benchmarks"));

    // Verify metadata fields.
    const metadata = root.get("metadata").?.object;
    std.debug.assert(std.mem.eql(u8, metadata.get("module").?.string, "test_mod"));
    std.debug.assert(std.mem.eql(u8, metadata.get("os").?.string, os_name));
    std.debug.assert(std.mem.eql(u8, metadata.get("arch").?.string, arch_name));
    std.debug.assert(metadata.get("entry_count").?.integer == 2);

    // Verify benchmark entries.
    const benchmarks = root.get("benchmarks").?.array;
    std.debug.assert(benchmarks.items.len == 2);
    std.debug.assert(std.mem.eql(u8, benchmarks.items[0].object.get("name").?.string, "alpha"));
    std.debug.assert(benchmarks.items[0].object.get("p50_per_op_ns").? == .null);
    std.debug.assert(benchmarks.items[1].object.get("p50_per_op_ns").?.float == 5.0);
}
