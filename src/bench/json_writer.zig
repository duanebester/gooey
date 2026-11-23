const std = @import("std");
const builtin = @import("builtin");
const Dir = std.Io.Dir;
const Io = std.Io;
const cachegrind = std.valgrind.cachegrind;
const options = @import("bench_options");

pub const sample_time_ns_min: u64 = if (options.fixed_iterations) 0 else 50 * std.time.ns_per_ms;

const MAX_ENTRIES: u32 = 256;

const MAX_NAME_LENGTH: u32 = 128;

const MAX_PATH_LENGTH: u32 = 512;

const MAX_MODULE_NAME_LENGTH: u32 = 64;

const MAX_FILENAME_LENGTH: u32 = 128;

const os_name: []const u8 = @tagName(builtin.os.tag);

const arch_name: []const u8 = @tagName(builtin.cpu.arch);

pub const Sampler = @import("sampler.zig").Sampler;

pub const Entry = struct {
    name: [MAX_NAME_LENGTH]u8 = @splat(0),
    name_length: u32 = 0,

    operation_count: u32 = 0,

    total_time_ns: u64 = 0,

    iterations: u32 = 0,

    has_min: bool = false,

    min_per_op_ns: f64 = 0.0,

    has_percentiles: bool = false,

    p50_per_op_ns: f64 = 0.0,

    p99_per_op_ns: f64 = 0.0,

    pub fn nameSlice(self: *const Entry) []const u8 {
        std.debug.assert(self.name_length <= MAX_NAME_LENGTH);
        return self.name[0..self.name_length];
    }

    pub fn avgTimeMs(self: *const Entry) f64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.total_time_ns > 0);
        const avg_ns: f64 = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        return avg_ns / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }

    pub fn timePerOpNs(self: *const Entry) f64 {
        std.debug.assert(self.iterations > 0);
        std.debug.assert(self.operation_count > 0);
        const avg_ns: f64 = @as(f64, @floatFromInt(self.total_time_ns)) /
            @as(f64, @floatFromInt(self.iterations));
        return avg_ns / @as(f64, @floatFromInt(self.operation_count));
    }
};

pub fn entry(
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    min_per_op_ns: f64,
) Entry {
    std.debug.assert(name.len > 0);
    std.debug.assert(iterations > 0);
    std.debug.assert(min_per_op_ns >= 0.0);

    var e: Entry = .{
        .operation_count = operation_count,
        .total_time_ns = total_time_ns,
        .iterations = iterations,
        .has_min = true,
        .min_per_op_ns = min_per_op_ns,
    };
    const copy_length: u32 = @intCast(@min(name.len, MAX_NAME_LENGTH));
    @memcpy(e.name[0..copy_length], name[0..copy_length]);
    e.name_length = copy_length;
    return e;
}

pub fn entryWithPercentiles(
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    min_per_op_ns: f64,
    p50_per_op_ns: f64,
    p99_per_op_ns: f64,
) Entry {
    std.debug.assert(min_per_op_ns >= 0.0);
    std.debug.assert(p50_per_op_ns >= min_per_op_ns);
    std.debug.assert(p99_per_op_ns >= p50_per_op_ns);

    var e = entry(name, operation_count, total_time_ns, iterations, min_per_op_ns);
    e.has_percentiles = true;
    e.p50_per_op_ns = p50_per_op_ns;
    e.p99_per_op_ns = p99_per_op_ns;
    return e;
}

const CalendarDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

fn getCurrentDate(io: Io) CalendarDate {
    const timestamp_seconds: u64 = @intCast(@max(0, Io.Clock.real.now(io).toSeconds()));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = timestamp_seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const month_numeric: u8 = @intCast(month_day.month.numeric());
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

const JsonMetadata = struct {
    module: []const u8,
    os: []const u8,
    arch: []const u8,
    date: []const u8,
    timestamp_unix: u64,
    entry_count: u32,
};

const JsonBenchmarkEntry = struct {
    name: []const u8,
    operation_count: u32,
    total_time_ns: u64,
    iterations: u32,
    avg_time_ms: f64,
    time_per_op_ns: f64,
    min_per_op_ns: ?f64,
    p50_per_op_ns: ?f64,
    p99_per_op_ns: ?f64,

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
            .min_per_op_ns = if (e.has_min) e.min_per_op_ns else null,
            .p50_per_op_ns = if (e.has_percentiles) e.p50_per_op_ns else null,
            .p99_per_op_ns = if (e.has_percentiles) e.p99_per_op_ns else null,
        };
    }
};

const JsonPayload = struct {
    metadata: JsonMetadata,
    benchmarks: []const JsonBenchmarkEntry,
};

pub const Reporter = struct {
    entries: [MAX_ENTRIES]Entry = undefined,
    count: u32 = 0,

    module_name: [MAX_MODULE_NAME_LENGTH]u8 = @splat(0),
    module_name_length: u32 = 0,

    json_dir: [MAX_PATH_LENGTH]u8 = @splat(0),
    json_dir_length: u32 = 0,

    json_enabled: bool = false,

    cachegrind_index: ?u32 = null,

    benchmark_seen_count: u32 = 0,

    io: Io = Io.failing,

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
        if (self.cachegrind_index == 0) cachegrind.startInstrumentation();
        return self;
    }

    pub fn addEntry(self: *Reporter, e: Entry) void {
        std.debug.assert(e.name_length > 0);
        if (self.cachegrind_index) |index| self.cachegrindEnd(index);
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

    pub fn finish(self: *const Reporter) void {
        if (!self.json_enabled) return;

        self.writeJsonFile() catch |err| {
            std.debug.print(
                "bench: failed to write JSON: {s}\n",
                .{@errorName(err)},
            );
        };
    }

    pub fn beginBenchmark(self: *const Reporter) void {
        const index = self.cachegrind_index orelse return;
        std.debug.assert(self.benchmark_seen_count <= index);
        if (self.benchmark_seen_count == index) cachegrind.startInstrumentation();
    }

    pub fn pauseBenchmark(self: *const Reporter) void {
        const index = self.cachegrind_index orelse return;
        std.debug.assert(self.benchmark_seen_count <= index);
        if (self.benchmark_seen_count == index) cachegrind.stopInstrumentation();
    }

    fn cachegrindEnd(self: *Reporter, index: u32) void {
        std.debug.assert(self.benchmark_seen_count <= index);
        if (self.benchmark_seen_count == index) {
            cachegrind.stopInstrumentation();
            std.process.exit(0);
        }
        self.benchmark_seen_count += 1;
        std.debug.assert(self.benchmark_seen_count <= index);
    }

    fn parseArgs(self: *Reporter, argv: []const [*:0]const u8) void {
        var i: u32 = if (argv.len >= 1) 1 else 0;
        const argc: u32 = @intCast(argv.len);
        while (i < argc) : (i += 1) {
            const arg = std.mem.sliceTo(argv[i], 0);
            if (std.mem.eql(u8, arg, "--cachegrind-benchmark")) {
                self.cachegrind_index = parseCachegrindIndex(argv, i);
                i += 1;
                continue;
            }
            if (!std.mem.eql(u8, arg, "--json-dir")) continue;

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
            i += 1;
        }
    }

    const FilenameBuffer = struct {
        buf: [MAX_PATH_LENGTH + MAX_FILENAME_LENGTH + 1]u8 = undefined,
        len: u32 = 0,
    };

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
            std.debug.print("bench: output path too long\n", .{});
            return result;
        };

        result.len = @intCast(written.len);
        return result;
    }

    fn writeJsonFile(self: *const Reporter) !void {
        std.debug.assert(self.json_enabled);
        std.debug.assert(self.json_dir_length > 0);

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

        const json_bytes = try self.serializePayload();
        defer std.heap.page_allocator.free(json_bytes);

        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(self.io, &write_buf);
        try writer.interface.writeAll(json_bytes);
        try writer.interface.writeAll("\n");
        try writer.flush();

        std.debug.print("\nbench: wrote {d} entries to {s}\n", .{ self.count, path_slice });
    }

    fn serializePayload(self: *const Reporter) ![]u8 {
        std.debug.assert(self.count <= MAX_ENTRIES);
        std.debug.assert(self.module_name_length > 0);

        var date_buf: [16]u8 = undefined;
        const date = getCurrentDate(self.io);
        comptime std.debug.assert(std.fmt.count("{d:0>2}-{d:0>2}-{d}", .{
            std.math.maxInt(u8),
            std.math.maxInt(u8),
            std.math.maxInt(u16),
        }) <= date_buf.len);
        const date_str = std.fmt.bufPrint(&date_buf, "{d:0>2}-{d:0>2}-{d}", .{
            date.month,
            date.day,
            date.year,
        }) catch unreachable;

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

fn parseCachegrindIndex(argv: []const [*:0]const u8, flag_index: u32) u32 {
    std.debug.assert(flag_index < argv.len);
    std.debug.assert(std.mem.eql(u8, std.mem.sliceTo(argv[flag_index], 0), "--cachegrind-benchmark"));
    if (flag_index + 1 < argv.len) {
        const value = std.mem.sliceTo(argv[flag_index + 1], 0);
        if (std.fmt.parseInt(u32, value, 10)) |index| {
            if (index < MAX_ENTRIES) return index;
        } else |_| {}
    }
    std.debug.print("bench: --cachegrind-benchmark requires an index below {d}\n", .{MAX_ENTRIES});
    std.process.exit(2);
}

test {
    _ = @import("sampler.zig");
}

test "entry: name is copied and truncated correctly" {
    const e = entry("convex_128", 128, 5000, 10, 4.0);
    std.debug.assert(e.name_length == 10);
    std.debug.assert(std.mem.eql(u8, e.nameSlice(), "convex_128"));
    std.debug.assert(e.operation_count == 128);
    std.debug.assert(e.iterations == 10);
    std.debug.assert(!e.has_percentiles);
    std.debug.assert(e.has_min);
    std.debug.assert(e.min_per_op_ns == 4.0);
}

test "entry: avgTimeMs and timePerOpNs compute correctly" {
    const e = entry("test", 100, 1_000_000, 10, 950.0);
    const avg_ms = e.avgTimeMs();
    const per_op_ns = e.timePerOpNs();

    std.debug.assert(avg_ms > 0.099);
    std.debug.assert(avg_ms < 0.101);

    std.debug.assert(per_op_ns > 999.0);
    std.debug.assert(per_op_ns < 1001.0);
}

test "entryWithPercentiles: percentile fields are set" {
    const e = entryWithPercentiles("shaped_warm", 50, 2_000_000, 20, 30.0, 42.5, 128.7);
    std.debug.assert(e.has_percentiles);
    std.debug.assert(e.has_min);
    std.debug.assert(e.min_per_op_ns == 30.0);
    std.debug.assert(e.p50_per_op_ns == 42.5);
    std.debug.assert(e.p99_per_op_ns == 128.7);
}

test "reporter: addEntry collects entries" {
    var reporter = Reporter.init("test_module", Io.failing, &.{});
    std.debug.assert(reporter.count == 0);
    std.debug.assert(!reporter.json_enabled);

    reporter.addEntry(entry("bench_a", 10, 500, 5, 40.0));
    reporter.addEntry(entry("bench_b", 20, 1000, 10, 40.0));
    std.debug.assert(reporter.count == 2);
    std.debug.assert(std.mem.eql(u8, reporter.entries[0].nameSlice(), "bench_a"));
    std.debug.assert(std.mem.eql(u8, reporter.entries[1].nameSlice(), "bench_b"));
}

test "reporter: finish is no-op when json is disabled" {
    var reporter = Reporter.init("noop", Io.failing, &.{});
    reporter.addEntry(entry("x", 1, 100, 1, 100.0));
    reporter.finish();
}

test "getCurrentDate: returns plausible values" {
    const date = getCurrentDate(std.testing.io);
    std.debug.assert(date.year >= 2025);
    std.debug.assert(date.month >= 1);
    std.debug.assert(date.month <= 12);
    std.debug.assert(date.day >= 1);
    std.debug.assert(date.day <= 31);
}

test "reporter: buildFilePath produces expected format" {
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

    std.debug.assert(std.mem.startsWith(u8, path, "bench-results/"));
    std.debug.assert(std.mem.indexOf(u8, path, os_name) != null);
    std.debug.assert(std.mem.indexOf(u8, path, arch_name) != null);
    std.debug.assert(std.mem.endsWith(u8, path, ".json"));
    std.debug.assert(std.mem.indexOf(u8, path, "-core-benchmarks-") != null);
}

test "JsonBenchmarkEntry.fromEntry: converts without percentiles" {
    const e = entry("test_bench", 64, 1_000_000, 10, 1200.0);
    const json_entry = JsonBenchmarkEntry.fromEntry(&e);

    std.debug.assert(std.mem.eql(u8, json_entry.name, "test_bench"));
    std.debug.assert(json_entry.operation_count == 64);
    std.debug.assert(json_entry.total_time_ns == 1_000_000);
    std.debug.assert(json_entry.iterations == 10);
    std.debug.assert(json_entry.min_per_op_ns.? == 1200.0);
    std.debug.assert(json_entry.p50_per_op_ns == null);
    std.debug.assert(json_entry.p99_per_op_ns == null);
}

test "JsonBenchmarkEntry.fromEntry: converts with percentiles" {
    const e = entryWithPercentiles("shaped_warm", 50, 2_000_000, 20, 30.0, 42.5, 128.7);
    const json_entry = JsonBenchmarkEntry.fromEntry(&e);

    std.debug.assert(std.mem.eql(u8, json_entry.name, "shaped_warm"));
    std.debug.assert(json_entry.min_per_op_ns.? == 30.0);
    std.debug.assert(json_entry.p50_per_op_ns.? == 42.5);
    std.debug.assert(json_entry.p99_per_op_ns.? == 128.7);
}

fn jsonNumberAsF64(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
}

test "reporter: serializePayload produces valid JSON" {
    var reporter = Reporter.init("test_mod", std.testing.io, &.{});
    reporter.addEntry(entry("alpha", 10, 500_000, 50, 900.0));
    reporter.addEntry(entryWithPercentiles("beta", 20, 1_000_000, 100, 4.0, 5.0, 15.0));

    const json_bytes = try reporter.serializePayload();
    defer std.heap.page_allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    std.debug.assert(root.contains("metadata"));
    std.debug.assert(root.contains("benchmarks"));

    const metadata = root.get("metadata").?.object;
    std.debug.assert(std.mem.eql(u8, metadata.get("module").?.string, "test_mod"));
    std.debug.assert(std.mem.eql(u8, metadata.get("os").?.string, os_name));
    std.debug.assert(std.mem.eql(u8, metadata.get("arch").?.string, arch_name));
    std.debug.assert(metadata.get("entry_count").?.integer == 2);

    const benchmarks = root.get("benchmarks").?.array;
    std.debug.assert(benchmarks.items.len == 2);
    std.debug.assert(std.mem.eql(u8, benchmarks.items[0].object.get("name").?.string, "alpha"));
    std.debug.assert(benchmarks.items[0].object.get("p50_per_op_ns").? == .null);
    std.debug.assert(jsonNumberAsF64(benchmarks.items[1].object.get("p50_per_op_ns").?) == 5.0);
    std.debug.assert(jsonNumberAsF64(benchmarks.items[1].object.get("p99_per_op_ns").?) == 15.0);
    std.debug.assert(benchmarks.items[0].object.get("min_per_op_ns").? != .null);
    std.debug.assert(jsonNumberAsF64(benchmarks.items[1].object.get("min_per_op_ns").?) == 4.0);
}
