const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;

/// Matches json_writer.zig.
const MAX_ENTRIES: u32 = 256;

/// Matches json_writer.zig.
const MAX_NAME_LENGTH: u32 = 128;

const MAX_PATH_LENGTH: u32 = 1024;

const MAX_MODULE_NAME_LENGTH: u32 = 64;

const MAX_META_STRING_LENGTH: u32 = 32;

const DEFAULT_THRESHOLD_PERCENT: f64 = 15.0;

/// Below ~10 ns/op, timer resolution and scheduler jitter dominate:
/// identical code swings far past any percentage threshold (observed
/// 0.40 -> 0.58 ns/op = +46%). Sub-floor entries are `.noisy`, unless
/// the absolute growth itself clears this floor.
const MIN_NS_FOR_THRESHOLD: f64 = 10.0;

/// Near the floor, jitter alone doubles a measurement (observed
/// 9.49 -> 19.84 ns/op on identical code), so a sub-floor entry must
/// grow 4x and clear the floor to count as a real regression.
const CATASTROPHIC_JUMP_MULTIPLIER: f64 = 4.0;

/// Below ~1 us the p99 reflects scheduler preemptions, not the code
/// (identical code swings +138%); it is reported but informational.
const P99_MIN_NS_FOR_THRESHOLD: f64 = 1000.0;

/// FFI-bound tails (CoreText/HarfBuzz) swing up to +31% run-to-run on
/// identical code; 3x clears that noise while failing genuine blowups.
const P99_THRESHOLD_MULTIPLIER: f64 = 3.0;

const SMALL_BENCH_NS_CEILING: f64 = 100.0;
const MEDIUM_BENCH_NS_CEILING: f64 = 1000.0;

const SMALL_BENCH_THRESHOLD_MULTIPLIER: f64 = 2.5;
const MEDIUM_BENCH_THRESHOLD_MULTIPLIER: f64 = 1.5;

/// 256 entries serialize to ~100 KB; 4 MB gives 40x headroom.
const MAX_JSON_FILE_BYTES: u32 = 4 * 1024 * 1024;

const COLUMN_WIDTH_NAME: u32 = 38;
const COLUMN_WIDTH_VALUE: u32 = 16;
const COLUMN_WIDTH_DELTA: u32 = 10;
const COLUMN_WIDTH_STATUS: u32 = 14;

const TABLE_WIDTH: u32 = COLUMN_WIDTH_NAME + COLUMN_WIDTH_VALUE * 2 +
    COLUMN_WIDTH_DELTA + COLUMN_WIDTH_STATUS + 4;

/// Strings are copied into fixed buffers so the JSON parse tree can
/// be freed immediately.
const ParsedEntry = struct {
    name: [MAX_NAME_LENGTH]u8 = @splat(0),
    name_length: u32 = 0,

    operation_count: u32 = 0,
    total_time_ns: u64 = 0,
    iterations: u32 = 0,
    avg_time_ms: f64 = 0.0,
    time_per_op_ns: f64 = 0.0,

    // `has_min` is false on baselines written before the schema
    // carried it; the gate then classifies on the mean.
    has_min: bool = false,
    min_per_op_ns: f64 = 0.0,

    has_percentiles: bool = false,
    p50_per_op_ns: f64 = 0.0,
    p99_per_op_ns: f64 = 0.0,

    fn nameSlice(self: *const ParsedEntry) []const u8 {
        std.debug.assert(self.name_length > 0);
        std.debug.assert(self.name_length <= MAX_NAME_LENGTH);
        return self.name[0..self.name_length];
    }
};

const ParsedReport = struct {
    module: [MAX_MODULE_NAME_LENGTH]u8 = @splat(0),
    module_length: u32 = 0,

    os: [MAX_META_STRING_LENGTH]u8 = @splat(0),
    os_length: u32 = 0,

    arch: [MAX_META_STRING_LENGTH]u8 = @splat(0),
    arch_length: u32 = 0,

    date: [MAX_META_STRING_LENGTH]u8 = @splat(0),
    date_length: u32 = 0,

    entries: [MAX_ENTRIES]ParsedEntry = undefined,
    count: u32 = 0,

    fn moduleSlice(self: *const ParsedReport) []const u8 {
        std.debug.assert(self.module_length <= MAX_MODULE_NAME_LENGTH);
        return self.module[0..self.module_length];
    }

    fn osSlice(self: *const ParsedReport) []const u8 {
        std.debug.assert(self.os_length <= MAX_META_STRING_LENGTH);
        return self.os[0..self.os_length];
    }

    fn archSlice(self: *const ParsedReport) []const u8 {
        std.debug.assert(self.arch_length <= MAX_META_STRING_LENGTH);
        return self.arch[0..self.arch_length];
    }

    fn dateSlice(self: *const ParsedReport) []const u8 {
        std.debug.assert(self.date_length <= MAX_META_STRING_LENGTH);
        return self.date[0..self.date_length];
    }

    /// With <=256 entries a linear scan beats a hash map and avoids
    /// heap allocation.
    fn findByName(self: *const ParsedReport, name: []const u8) ?u32 {
        std.debug.assert(name.len > 0);
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.entries[i].nameSlice(), name)) {
                return @intCast(i);
            }
        }
        return null;
    }
};

const ComparisonStatus = enum(u8) {
    ok = 0,
    regression = 1,
    improvement = 2,
    new_entry = 3,
    removed_entry = 4,
    /// Too fast for a percentage delta to mean anything; shown but
    /// never fails the build.
    noisy = 5,
};

const ComparisonEntry = struct {
    name: [MAX_NAME_LENGTH]u8 = @splat(0),
    name_length: u32 = 0,

    baseline_ns_per_op: f64 = 0.0,
    current_ns_per_op: f64 = 0.0,
    delta_percent: f64 = 0.0,

    gated_on_min: bool = false,
    baseline_min: f64 = 0.0,
    current_min: f64 = 0.0,
    delta_min_percent: f64 = 0.0,

    has_percentiles: bool = false,
    baseline_p99: f64 = 0.0,
    current_p99: f64 = 0.0,
    delta_p99_percent: f64 = 0.0,

    status: ComparisonStatus = .ok,

    fn nameSlice(self: *const ComparisonEntry) []const u8 {
        std.debug.assert(self.name_length <= MAX_NAME_LENGTH);
        return self.name[0..self.name_length];
    }
};

/// Capacity 2 x MAX_ENTRIES: the worst case is no overlap between the
/// baseline and current entry sets.
const ComparisonResult = struct {
    /// 2 × 256 entries × ~200 bytes each ≈ 100 KB on the stack.
    entries: [MAX_ENTRIES * 2]ComparisonEntry = undefined,
    count: u32 = 0,

    count_compared: u32 = 0,
    count_regressions: u32 = 0,
    count_improvements: u32 = 0,
    count_new: u32 = 0,
    count_removed: u32 = 0,
    count_noisy: u32 = 0,

    fn addEntry(self: *ComparisonResult, e: ComparisonEntry) void {
        std.debug.assert(self.count < MAX_ENTRIES * 2);
        std.debug.assert(e.name_length > 0);
        self.entries[self.count] = e;
        self.count += 1;
    }
};

const Args = struct {
    baseline_path: [MAX_PATH_LENGTH]u8 = @splat(0),
    baseline_path_length: u32 = 0,

    current_path: [MAX_PATH_LENGTH]u8 = @splat(0),
    current_path_length: u32 = 0,

    threshold_percent: f64 = DEFAULT_THRESHOLD_PERCENT,

    fn baselineSlice(self: *const Args) []const u8 {
        std.debug.assert(self.baseline_path_length > 0);
        return self.baseline_path[0..self.baseline_path_length];
    }

    fn currentSlice(self: *const Args) []const u8 {
        std.debug.assert(self.current_path_length > 0);
        return self.current_path[0..self.current_path_length];
    }
};

const ArgsError = error{
    missing_baseline,
    missing_current,
    missing_threshold_value,
    path_too_long,
    invalid_threshold,
    help_requested,
};

fn parseArgs(argv: []const [*:0]const u8) ArgsError!Args {
    var args: Args = .{};
    var positional_count: u32 = 0;

    // Test runners may pass empty argv; skip the program name only
    // when one is present.
    var i: u32 = if (argv.len >= 1) 1 else 0;
    const argc: u32 = @intCast(argv.len);
    while (i < argc) : (i += 1) {
        const arg = std.mem.sliceTo(argv[i], 0);

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.help_requested;
        }

        if (std.mem.eql(u8, arg, "--threshold")) {
            if (i + 1 >= argc) return error.missing_threshold_value;
            i += 1;
            const value_str = std.mem.sliceTo(argv[i], 0);
            args.threshold_percent = std.fmt.parseFloat(f64, value_str) catch {
                return error.invalid_threshold;
            };
            continue;
        }

        if (positional_count == 0) {
            if (arg.len > MAX_PATH_LENGTH) return error.path_too_long;
            @memcpy(args.baseline_path[0..arg.len], arg);
            args.baseline_path_length = @intCast(arg.len);
            positional_count += 1;
        } else if (positional_count == 1) {
            if (arg.len > MAX_PATH_LENGTH) return error.path_too_long;
            @memcpy(args.current_path[0..arg.len], arg);
            args.current_path_length = @intCast(arg.len);
            positional_count += 1;
        }
    }

    if (args.baseline_path_length == 0) return error.missing_baseline;
    if (args.current_path_length == 0) return error.missing_current;
    return args;
}

/// JSON serializers sometimes emit `17` instead of `17.0` for round
/// floats.
fn jsonAsFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

fn jsonAsU32(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @as(u32, @intCast(i)) else null,
        else => null,
    };
}

fn jsonAsU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
        else => null,
    };
}

fn copyJsonString(value: std.json.Value, dest: []u8) u32 {
    std.debug.assert(dest.len > 0);
    switch (value) {
        .string => |s| {
            if (s.len > dest.len) return 0;
            @memcpy(dest[0..s.len], s);
            return @intCast(s.len);
        },
        else => return 0,
    }
}

const LoadError = error{
    file_open_failed,
    file_read_failed,
    json_parse_failed,
    missing_metadata,
    missing_benchmarks,
    entry_limit_exceeded,
};

fn loadReport(io: Io, path: []const u8) LoadError!ParsedReport {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= MAX_PATH_LENGTH);

    const allocator = std.heap.page_allocator;

    const file = Dir.cwd().openFile(io, path, .{}) catch {
        return error.file_open_failed;
    };
    defer file.close(io);

    const stat = file.stat(io) catch {
        return error.file_read_failed;
    };
    if (stat.size > MAX_JSON_FILE_BYTES) {
        return error.file_read_failed;
    }
    // Byte-source methods (`readAlloc` and friends) live on the
    // reader's `.interface`; `stat.size` is bounded by
    // MAX_JSON_FILE_BYTES above.
    var stream_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &stream_buf);
    const contents = reader.interface.readAlloc(allocator, @intCast(stat.size)) catch {
        return error.file_read_failed;
    };
    defer allocator.free(contents);

    // The parsed tree references `contents`; both must outlive the
    // copy into the fixed-capacity report.
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        contents,
        .{},
    ) catch {
        return error.json_parse_failed;
    };
    defer parsed.deinit();

    return extractReport(parsed.value);
}

fn extractReport(root_value: std.json.Value) LoadError!ParsedReport {
    const root = switch (root_value) {
        .object => |obj| obj,
        else => return error.json_parse_failed,
    };

    var report: ParsedReport = .{};

    const metadata_value = root.get("metadata") orelse return error.missing_metadata;
    const metadata = switch (metadata_value) {
        .object => |obj| obj,
        else => return error.missing_metadata,
    };

    if (metadata.get("module")) |v| {
        report.module_length = copyJsonString(v, &report.module);
    }
    if (metadata.get("os")) |v| {
        report.os_length = copyJsonString(v, &report.os);
    }
    if (metadata.get("arch")) |v| {
        report.arch_length = copyJsonString(v, &report.arch);
    }
    if (metadata.get("date")) |v| {
        report.date_length = copyJsonString(v, &report.date);
    }

    const benchmarks_value = root.get("benchmarks") orelse return error.missing_benchmarks;
    const benchmarks = switch (benchmarks_value) {
        .array => |arr| arr,
        else => return error.missing_benchmarks,
    };

    for (benchmarks.items) |item| {
        if (report.count >= MAX_ENTRIES) return error.entry_limit_exceeded;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        report.entries[report.count] = extractEntry(obj);
        if (report.entries[report.count].name_length > 0) {
            report.count += 1;
        }
    }

    return report;
}

fn extractEntry(obj: std.json.ObjectMap) ParsedEntry {
    var e: ParsedEntry = .{};

    if (obj.get("name")) |v| {
        e.name_length = copyJsonString(v, &e.name);
    }
    if (obj.get("operation_count")) |v| {
        e.operation_count = jsonAsU32(v) orelse 0;
    }
    if (obj.get("total_time_ns")) |v| {
        e.total_time_ns = jsonAsU64(v) orelse 0;
    }
    if (obj.get("iterations")) |v| {
        e.iterations = jsonAsU32(v) orelse 0;
    }
    if (obj.get("avg_time_ms")) |v| {
        e.avg_time_ms = jsonAsFloat(v) orelse 0.0;
    }
    if (obj.get("time_per_op_ns")) |v| {
        e.time_per_op_ns = jsonAsFloat(v) orelse 0.0;
    }

    // A null/absent min leaves `has_min` false so the gate falls back
    // to the mean for this entry.
    if (obj.get("min_per_op_ns")) |v| {
        if (jsonAsFloat(v)) |min_per_op| {
            e.has_min = true;
            e.min_per_op_ns = min_per_op;
        }
    }

    if (obj.get("p50_per_op_ns")) |v| {
        if (jsonAsFloat(v)) |p50| {
            e.p50_per_op_ns = p50;
            if (obj.get("p99_per_op_ns")) |v99| {
                if (jsonAsFloat(v99)) |p99| {
                    e.has_percentiles = true;
                    e.p99_per_op_ns = p99;
                }
            }
        }
    }

    return e;
}

fn deltaPercent(baseline: f64, current: f64) f64 {
    std.debug.assert(baseline >= 0.0);
    std.debug.assert(current >= 0.0);
    if (baseline == 0.0) return 0.0;
    return ((current - baseline) / baseline) * 100.0;
}

fn effectiveThreshold(reference_ns: f64, base_threshold: f64) f64 {
    std.debug.assert(reference_ns >= 0.0);
    std.debug.assert(base_threshold > 0.0);

    if (reference_ns < SMALL_BENCH_NS_CEILING) {
        return base_threshold * SMALL_BENCH_THRESHOLD_MULTIPLIER;
    }
    if (reference_ns < MEDIUM_BENCH_NS_CEILING) {
        return base_threshold * MEDIUM_BENCH_THRESHOLD_MULTIPLIER;
    }
    return base_threshold;
}

fn classifyAvgStatus(baseline_ns: f64, current_ns: f64, base_threshold: f64) ComparisonStatus {
    std.debug.assert(baseline_ns >= 0.0);
    std.debug.assert(current_ns >= 0.0);
    std.debug.assert(base_threshold > 0.0);

    if (baseline_ns < MIN_NS_FOR_THRESHOLD) {
        // Near the floor, noise alone doubles a benchmark (observed
        // 9.49 -> 19.84 ns on identical code), so only an
        // order-of-magnitude blowup that also clears the floor counts
        // as a regression.
        const catastrophic = current_ns >= MIN_NS_FOR_THRESHOLD and
            current_ns >= baseline_ns * CATASTROPHIC_JUMP_MULTIPLIER;
        if (catastrophic) return .regression;
        return .noisy;
    }

    const eff = effectiveThreshold(baseline_ns, base_threshold);
    const delta = deltaPercent(baseline_ns, current_ns);
    if (delta > eff) return .regression;
    if (delta < -eff) return .improvement;
    return .ok;
}

fn compareReports(
    baseline: *const ParsedReport,
    current: *const ParsedReport,
    threshold_percent: f64,
) ComparisonResult {
    std.debug.assert(baseline.count <= MAX_ENTRIES);
    std.debug.assert(current.count <= MAX_ENTRIES);
    std.debug.assert(threshold_percent > 0.0);

    var result: ComparisonResult = .{};

    var baseline_matched: [MAX_ENTRIES]bool = @splat(false);

    for (0..current.count) |ci| {
        const current_entry = &current.entries[ci];
        var comp = makeComparisonEntry(current_entry);

        if (baseline.findByName(current_entry.nameSlice())) |bi| {
            baseline_matched[bi] = true;
            const baseline_entry = &baseline.entries[bi];
            populateMatchedComparison(&comp, baseline_entry, current_entry, threshold_percent);
            result.count_compared += 1;
        } else {
            comp.status = .new_entry;
            comp.current_ns_per_op = current_entry.time_per_op_ns;
            result.count_new += 1;
        }

        updateResultCounters(&result, comp.status);
        result.addEntry(comp);
    }

    for (0..baseline.count) |bi| {
        if (baseline_matched[bi]) continue;

        const baseline_entry = &baseline.entries[bi];
        var comp = makeComparisonEntry(baseline_entry);
        comp.status = .removed_entry;
        comp.baseline_ns_per_op = baseline_entry.time_per_op_ns;
        result.count_removed += 1;
        result.addEntry(comp);
    }

    return result;
}

fn makeComparisonEntry(source: *const ParsedEntry) ComparisonEntry {
    std.debug.assert(source.name_length > 0);
    var comp: ComparisonEntry = .{};
    @memcpy(comp.name[0..source.name_length], source.name[0..source.name_length]);
    comp.name_length = source.name_length;
    return comp;
}

fn populateMatchedComparison(
    comp: *ComparisonEntry,
    baseline_entry: *const ParsedEntry,
    current_entry: *const ParsedEntry,
    threshold_percent: f64,
) void {
    std.debug.assert(comp.name_length > 0);
    std.debug.assert(threshold_percent > 0.0);

    comp.baseline_ns_per_op = baseline_entry.time_per_op_ns;
    comp.current_ns_per_op = current_entry.time_per_op_ns;
    comp.delta_percent = deltaPercent(baseline_entry.time_per_op_ns, current_entry.time_per_op_ns);

    const both_have_min = baseline_entry.has_min and current_entry.has_min;
    if (both_have_min) {
        comp.gated_on_min = true;
        comp.baseline_min = baseline_entry.min_per_op_ns;
        comp.current_min = current_entry.min_per_op_ns;
        comp.delta_min_percent = deltaPercent(baseline_entry.min_per_op_ns, current_entry.min_per_op_ns);
    }

    if (baseline_entry.has_percentiles and current_entry.has_percentiles) {
        comp.has_percentiles = true;
        comp.baseline_p99 = baseline_entry.p99_per_op_ns;
        comp.current_p99 = current_entry.p99_per_op_ns;
        comp.delta_p99_percent = deltaPercent(baseline_entry.p99_per_op_ns, current_entry.p99_per_op_ns);
    }

    const central_baseline = if (both_have_min) baseline_entry.min_per_op_ns else baseline_entry.time_per_op_ns;
    const central_current = if (both_have_min) current_entry.min_per_op_ns else current_entry.time_per_op_ns;
    var status = classifyAvgStatus(
        central_baseline,
        central_current,
        threshold_percent,
    );

    const p99_gated = comp.has_percentiles and
        comp.baseline_p99 >= P99_MIN_NS_FOR_THRESHOLD;
    if (p99_gated) {
        const p99_threshold = effectiveThreshold(comp.baseline_p99, threshold_percent) *
            P99_THRESHOLD_MULTIPLIER;
        if (comp.delta_p99_percent > p99_threshold) status = .regression;
    }

    comp.status = status;
}

fn updateResultCounters(result: *ComparisonResult, status: ComparisonStatus) void {
    switch (status) {
        .regression => result.count_regressions += 1,
        .improvement => result.count_improvements += 1,
        .noisy => result.count_noisy += 1,
        .ok, .new_entry, .removed_entry => {},
    }
}

/// `writer.writeByteNTimes()` is unavailable in Zig 0.15.
fn printRepeat(char: u8, count: u32) void {
    var buf: [TABLE_WIDTH]u8 = undefined;
    const len = @min(count, TABLE_WIDTH);
    @memset(buf[0..len], char);
    std.debug.print("{s}", .{buf[0..len]});
}

fn printResults(
    args: *const Args,
    baseline: *const ParsedReport,
    current: *const ParsedReport,
    result: *const ComparisonResult,
) void {
    printHeader(args, baseline, current);
    printTableHeader();

    for (0..result.count) |i| {
        printEntryRow(&result.entries[i]);
    }

    printSummary(result, args.threshold_percent);
}

fn printHeader(
    args: *const Args,
    baseline: *const ParsedReport,
    current: *const ParsedReport,
) void {
    printRepeat('=', TABLE_WIDTH);
    std.debug.print("\n", .{});

    if (current.module_length > 0) {
        std.debug.print("  Benchmark Comparison -- {s} ({s}-{s})", .{
            current.moduleSlice(),
            current.osSlice(),
            current.archSlice(),
        });
    } else {
        std.debug.print("  Benchmark Comparison", .{});
    }
    std.debug.print("\n", .{});

    printRepeat('=', TABLE_WIDTH);
    std.debug.print("\n", .{});

    printPathLine("  Baseline", args.baselineSlice(), baseline.dateSlice());
    printPathLine("  Current ", args.currentSlice(), current.dateSlice());

    std.debug.print("  Threshold: {d:.1}%\n", .{args.threshold_percent});
}

fn printPathLine(label: []const u8, path: []const u8, date: []const u8) void {
    std.debug.assert(label.len > 0);
    std.debug.assert(path.len > 0);
    if (date.len > 0) {
        std.debug.print("{s}: {s} ({s})\n", .{ label, path, date });
    } else {
        std.debug.print("{s}: {s}\n", .{ label, path });
    }
}

fn printTableHeader() void {
    printRepeat('-', TABLE_WIDTH);
    std.debug.print("\n", .{});

    std.debug.print("  {s:<" ++ widthStr(COLUMN_WIDTH_NAME) ++ "}" ++
        "{s:>" ++ widthStr(COLUMN_WIDTH_VALUE) ++ "}" ++
        "{s:>" ++ widthStr(COLUMN_WIDTH_VALUE) ++ "}" ++
        "{s:>" ++ widthStr(COLUMN_WIDTH_DELTA) ++ "}" ++
        "  {s}\n", .{
        "Name",
        "Baseline",
        "Current",
        "Delta",
        "Status",
    });

    printRepeat('-', TABLE_WIDTH);
    std.debug.print("\n", .{});
}

fn printEntryRow(entry: *const ComparisonEntry) void {
    std.debug.assert(entry.name_length > 0);

    var baseline_buf: [32]u8 = undefined;
    var current_buf: [32]u8 = undefined;
    var delta_buf: [32]u8 = undefined;

    const baseline_str = formatNsPerOp(entry.baseline_ns_per_op, entry.status, true, &baseline_buf);
    const current_str = formatNsPerOp(entry.current_ns_per_op, entry.status, false, &current_buf);
    const delta_str = formatDelta(entry.delta_percent, entry.status, &delta_buf);
    const status_str = statusLabel(entry.status);

    std.debug.print("  {s:<" ++ widthStr(COLUMN_WIDTH_NAME) ++ "}" ++
        "{s:>" ++ widthStr(COLUMN_WIDTH_VALUE) ++ "}" ++
        "{s:>" ++ widthStr(COLUMN_WIDTH_VALUE) ++ "}" ++
        "{s:>" ++ widthStr(COLUMN_WIDTH_DELTA) ++ "}" ++
        "  {s}\n", .{
        entry.nameSlice(),
        baseline_str,
        current_str,
        delta_str,
        status_str,
    });

    if (entry.gated_on_min) {
        printMinLine(entry);
    }

    if (entry.has_percentiles) {
        printPercentileLine(entry);
    }
}

fn printMinLine(entry: *const ComparisonEntry) void {
    std.debug.assert(entry.gated_on_min);

    const sign: []const u8 = if (entry.delta_min_percent >= 0) "+" else "";
    std.debug.print("  {s:>" ++ widthStr(COLUMN_WIDTH_NAME) ++ "}" ++
        "  min: {d:.2} -> {d:.2} ns/op ({s}{d:.1}%)  [gated]\n", .{
        "",
        entry.baseline_min,
        entry.current_min,
        sign,
        entry.delta_min_percent,
    });
}

fn printPercentileLine(entry: *const ComparisonEntry) void {
    std.debug.assert(entry.has_percentiles);

    const sign: []const u8 = if (entry.delta_p99_percent >= 0) "+" else "";
    const note: []const u8 = if (entry.baseline_p99 < P99_MIN_NS_FOR_THRESHOLD)
        "  [informational]"
    else
        "";
    std.debug.print("  {s:>" ++ widthStr(COLUMN_WIDTH_NAME) ++ "}" ++
        "  p99: {d:.2} -> {d:.2} ns/op ({s}{d:.1}%){s}\n", .{
        "",
        entry.baseline_p99,
        entry.current_p99,
        sign,
        entry.delta_p99_percent,
        note,
    });
}

fn printSummary(result: *const ComparisonResult, threshold_percent: f64) void {
    std.debug.assert(threshold_percent > 0.0);

    printRepeat('-', TABLE_WIDTH);
    std.debug.print("\n", .{});

    std.debug.print("  {d} compared | {d} regressed | {d} improved | {d} noisy | {d} new | {d} removed\n", .{
        result.count_compared,
        result.count_regressions,
        result.count_improvements,
        result.count_noisy,
        result.count_new,
        result.count_removed,
    });

    const pass_or_fail: []const u8 = if (result.count_regressions > 0) "FAIL" else "PASS";
    std.debug.print("  Result: {s} (threshold: {d:.1}%)\n", .{
        pass_or_fail,
        threshold_percent,
    });

    printRepeat('=', TABLE_WIDTH);
    std.debug.print("\n", .{});
}

fn formatNsPerOp(value: f64, status: ComparisonStatus, is_baseline: bool, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 16);
    if (is_baseline and status == .new_entry) return "--";
    if (!is_baseline and status == .removed_entry) return "--";
    return std.fmt.bufPrint(buf, "{d:.2} ns/op", .{value}) catch "--";
}

fn formatDelta(delta_percent: f64, status: ComparisonStatus, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 16);
    if (status == .new_entry) return "NEW";
    if (status == .removed_entry) return "REMOVED";
    const sign: []const u8 = if (delta_percent >= 0) "+" else "";
    return std.fmt.bufPrint(buf, "{s}{d:.1}%", .{ sign, delta_percent }) catch "?";
}

fn statusLabel(status: ComparisonStatus) []const u8 {
    return switch (status) {
        .ok => "",
        .regression => "<< REGRESSED",
        .improvement => ">> improved",
        .new_entry => "(new)",
        .removed_entry => "(removed)",
        .noisy => "-- noisy (sub-floor)",
    };
}

fn widthStr(comptime width: u32) *const [countDigits(width)]u8 {
    const buf = comptime blk: {
        var b: [countDigits(width)]u8 = undefined;
        var val = width;
        var i: u32 = countDigits(width);
        while (i > 0) {
            i -= 1;
            b[i] = '0' + @as(u8, @intCast(val % 10));
            val = val / 10;
        }
        break :blk b;
    };
    return &buf;
}

fn countDigits(comptime value: u32) u32 {
    if (value == 0) return 1;
    var count: u32 = 0;
    var remaining = value;
    while (remaining > 0) {
        remaining /= 10;
        count += 1;
    }
    return count;
}

fn printUsage() void {
    std.debug.print(
        \\
        \\Usage: bench-compare <baseline.json> <current.json> [--threshold N]
        \\
        \\Arguments:
        \\  baseline.json    Path to the baseline benchmark JSON report.
        \\  current.json     Path to the current benchmark JSON report.
        \\  --threshold N    Regression threshold in percent (default: 15.0).
        \\
        \\Noise handling:
        \\  Benchmarks below 10 ns/op are reported as noisy and never
        \\  fail the build (a percentage delta is meaningless at timer/
        \\  cache/scheduler scale), unless they grow by >= 10 ns/op in
        \\  absolute terms.  The threshold is scaled up for fast
        \\  benchmarks (2.5x under 100 ns/op, 1.5x under 1 us/op).  p99
        \\  tail latency only gates at or above 1 us/op; below that it is
        \\  printed for insight but is informational only.
        \\
        \\Exit codes:
        \\  0    No regressions detected.
        \\  1    One or more regressions exceed the threshold.
        \\
        \\Examples:
        \\  zig build bench-compare -- old.json new.json
        \\  zig build bench-compare -- old.json new.json --threshold 10
        \\
    , .{});
}

pub fn main(init: std.process.Init) void {
    const args = parseArgs(init.minimal.args.vector) catch |err| {
        if (err == error.help_requested) {
            printUsage();
            std.process.exit(0);
        }
        std.debug.print("bench-compare: {s}", .{switch (err) {
            error.missing_baseline => "missing baseline file path.\n",
            error.missing_current => "missing current file path.\n",
            error.missing_threshold_value => "--threshold requires a numeric value.\n",
            error.path_too_long => "file path exceeds maximum length.\n",
            error.invalid_threshold => "--threshold value is not a valid number.\n",
            error.help_requested => unreachable,
        }});
        printUsage();
        std.process.exit(2);
    };

    const baseline = loadReport(init.io, args.baselineSlice()) catch |err| {
        std.debug.print("bench-compare: failed to load baseline \"{s}\": {s}\n", .{
            args.baselineSlice(),
            @errorName(err),
        });
        std.process.exit(2);
    };

    const current = loadReport(init.io, args.currentSlice()) catch |err| {
        std.debug.print("bench-compare: failed to load current \"{s}\": {s}\n", .{
            args.currentSlice(),
            @errorName(err),
        });
        std.process.exit(2);
    };

    const result = compareReports(&baseline, &current, args.threshold_percent);

    std.debug.print("\n", .{});
    printResults(&args, &baseline, &current, &result);

    if (result.count_regressions > 0) {
        std.process.exit(1);
    }
}

test "deltaPercent: basic cases" {
    const zero = deltaPercent(100.0, 100.0);
    std.debug.assert(zero == 0.0);

    const regression = deltaPercent(100.0, 120.0);
    std.debug.assert(regression > 19.9);
    std.debug.assert(regression < 20.1);

    const improvement = deltaPercent(100.0, 80.0);
    std.debug.assert(improvement > -20.1);
    std.debug.assert(improvement < -19.9);

    const zero_baseline = deltaPercent(0.0, 42.0);
    std.debug.assert(zero_baseline == 0.0);
}

test "parseArgs: rejects missing arguments" {
    if (parseArgs(&.{})) |_| {
        unreachable;
    } else |err| {
        std.debug.assert(err == error.missing_baseline or err == error.missing_current);
    }
}

test "jsonAsFloat: handles integer and float values" {
    const float_val = std.json.Value{ .float = 42.5 };
    const f = jsonAsFloat(float_val);
    std.debug.assert(f != null);
    std.debug.assert(f.? == 42.5);

    const int_val = std.json.Value{ .integer = 100 };
    const i = jsonAsFloat(int_val);
    std.debug.assert(i != null);
    std.debug.assert(i.? == 100.0);

    const null_val = std.json.Value.null;
    std.debug.assert(jsonAsFloat(null_val) == null);
}

test "jsonAsU32: validates range" {
    const valid = std.json.Value{ .integer = 42 };
    std.debug.assert(jsonAsU32(valid).? == 42);

    const negative = std.json.Value{ .integer = -1 };
    std.debug.assert(jsonAsU32(negative) == null);

    const too_large = std.json.Value{ .integer = @as(i64, std.math.maxInt(u32)) + 1 };
    std.debug.assert(jsonAsU32(too_large) == null);
}

test "copyJsonString: copies string values" {
    var dest: [32]u8 = @splat(0);
    const str_val = std.json.Value{ .string = "hello" };
    const len = copyJsonString(str_val, &dest);
    std.debug.assert(len == 5);
    std.debug.assert(std.mem.eql(u8, dest[0..5], "hello"));

    const int_val = std.json.Value{ .integer = 42 };
    std.debug.assert(copyJsonString(int_val, &dest) == 0);
}

test "extractReport: parses well-formed JSON" {
    const json_text =
        \\{
        \\  "metadata": {
        \\    "module": "core",
        \\    "os": "macos",
        \\    "arch": "aarch64",
        \\    "date": "02-24-2026",
        \\    "timestamp_unix": 1771959017,
        \\    "entry_count": 2
        \\  },
        \\  "benchmarks": [
        \\    {
        \\      "name": "alpha",
        \\      "operation_count": 8,
        \\      "total_time_ns": 50000041,
        \\      "iterations": 367169,
        \\      "avg_time_ms": 0.000136,
        \\      "time_per_op_ns": 17.02,
        \\      "p50_per_op_ns": null,
        \\      "p99_per_op_ns": null
        \\    },
        \\    {
        \\      "name": "beta",
        \\      "operation_count": 16,
        \\      "total_time_ns": 100000000,
        \\      "iterations": 100000,
        \\      "avg_time_ms": 1.0,
        \\      "time_per_op_ns": 62.5,
        \\      "p50_per_op_ns": 55.0,
        \\      "p99_per_op_ns": 120.0
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json_text,
        .{},
    );
    defer parsed.deinit();

    const report = try extractReport(parsed.value);

    std.debug.assert(std.mem.eql(u8, report.moduleSlice(), "core"));
    std.debug.assert(std.mem.eql(u8, report.osSlice(), "macos"));
    std.debug.assert(std.mem.eql(u8, report.archSlice(), "aarch64"));
    std.debug.assert(report.count == 2);

    std.debug.assert(std.mem.eql(u8, report.entries[0].nameSlice(), "alpha"));
    std.debug.assert(report.entries[0].operation_count == 8);
    std.debug.assert(report.entries[0].time_per_op_ns == 17.02);
    std.debug.assert(!report.entries[0].has_percentiles);

    std.debug.assert(std.mem.eql(u8, report.entries[1].nameSlice(), "beta"));
    std.debug.assert(report.entries[1].has_percentiles);
    std.debug.assert(report.entries[1].p50_per_op_ns == 55.0);
    std.debug.assert(report.entries[1].p99_per_op_ns == 120.0);
}

test "compareReports: detects regressions and improvements" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntry("fast", 1000.0);
    current.entries[0] = makeTestEntry("fast", 1100.0);

    baseline.entries[1] = makeTestEntry("slow", 1000.0);
    current.entries[1] = makeTestEntry("slow", 1250.0);

    baseline.entries[2] = makeTestEntry("better", 1000.0);
    current.entries[2] = makeTestEntry("better", 800.0);

    baseline.count = 3;
    current.count = 3;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count == 3);
    std.debug.assert(result.count_compared == 3);
    std.debug.assert(result.count_regressions == 1);
    std.debug.assert(result.count_improvements == 1);
    std.debug.assert(result.count_new == 0);
    std.debug.assert(result.count_removed == 0);
}

test "compareReports: gates on min, so a noisy mean swing alone is not a regression" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntryWithMin("noisy_mean", 1000.0, 1000.0);
    current.entries[0] = makeTestEntryWithMin("noisy_mean", 1300.0, 1030.0);
    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.entries[0].gated_on_min);
    std.debug.assert(result.entries[0].status == .ok);
    std.debug.assert(result.count_regressions == 0);
}

test "compareReports: a genuine min regression still flags even when the mean looks flat" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntryWithMin("min_regressed", 1000.0, 1000.0);
    current.entries[0] = makeTestEntryWithMin("min_regressed", 1010.0, 1300.0);
    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.entries[0].gated_on_min);
    std.debug.assert(result.entries[0].status == .regression);
    std.debug.assert(result.count_regressions == 1);
}

test "compareReports: falls back to mean gating when min is absent (old baseline)" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntry("legacy", 1000.0);
    current.entries[0] = makeTestEntry("legacy", 1250.0);
    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(!result.entries[0].gated_on_min);
    std.debug.assert(result.entries[0].status == .regression);
    std.debug.assert(result.count_regressions == 1);
}

test "compareReports: detects new and removed entries" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntry("kept", 50.0);
    current.entries[0] = makeTestEntry("kept", 50.0);

    baseline.entries[1] = makeTestEntry("old", 75.0);

    current.entries[1] = makeTestEntry("fresh", 30.0);

    baseline.count = 2;
    current.count = 2;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count == 3);
    std.debug.assert(result.count_compared == 1);
    std.debug.assert(result.count_new == 1);
    std.debug.assert(result.count_removed == 1);
}

test "compareReports: p99 regression flags even when avg is ok (tail >= 1us)" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntryWithPercentiles("tail_bad", 2000.0, 5000.0);
    current.entries[0] = makeTestEntryWithPercentiles("tail_bad", 2100.0, 8000.0);

    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count_regressions == 1);
    std.debug.assert(result.entries[0].status == .regression);
    std.debug.assert(result.entries[0].has_percentiles);
}

test "compareReports: sub-floor entries are noisy, never regressions" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntry("tiny", 0.40);
    current.entries[0] = makeTestEntry("tiny", 0.58);

    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count_regressions == 0);
    std.debug.assert(result.count_noisy == 1);
    std.debug.assert(result.entries[0].status == .noisy);
}

test "compareReports: sub-floor catastrophic absolute jump still flags" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntry("blowup", 2.0);
    current.entries[0] = makeTestEntry("blowup", 50.0);

    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count_regressions == 1);
    std.debug.assert(result.entries[0].status == .regression);
}

test "compareReports: sub-floor noise-doubling stays noisy, not regression" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntry("near_floor", 9.49);
    current.entries[0] = makeTestEntry("near_floor", 19.84);

    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count_regressions == 0);
    std.debug.assert(result.entries[0].status == .noisy);
}

test "compareReports: scaled threshold absorbs small-bench variance" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntry("jittery", 30.0);
    current.entries[0] = makeTestEntry("jittery", 39.0);

    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count_regressions == 0);
    std.debug.assert(result.entries[0].status == .ok);
}

test "compareReports: p99 below 1us is informational, not gated" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntryWithPercentiles("arena_short", 36.85, 37.92);
    current.entries[0] = makeTestEntryWithPercentiles("arena_short", 37.50, 90.42);

    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count_regressions == 0);
    std.debug.assert(result.entries[0].status != .regression);
}

test "compareReports: moderate us-scale p99 swing is tolerated" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    baseline.entries[0] = makeTestEntryWithPercentiles("cold_shape", 39607.0, 50042.0);
    current.entries[0] = makeTestEntryWithPercentiles("cold_shape", 40854.0, 65666.0);

    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count_regressions == 0);
    std.debug.assert(result.entries[0].status != .regression);
}

test "widthStr: produces correct digit strings" {
    const s10 = widthStr(5);
    std.debug.assert(std.mem.eql(u8, s10, "5"));

    const s38 = widthStr(38);
    std.debug.assert(std.mem.eql(u8, s38, "38"));

    const s256 = widthStr(256);
    std.debug.assert(std.mem.eql(u8, s256, "256"));
}

test "formatDelta: formats sign and special statuses" {
    var buf: [32]u8 = undefined;

    const pos = formatDelta(12.3, .ok, &buf);
    std.debug.assert(std.mem.eql(u8, pos, "+12.3%"));

    var buf2: [32]u8 = undefined;
    const new = formatDelta(0.0, .new_entry, &buf2);
    std.debug.assert(std.mem.eql(u8, new, "NEW"));
}

fn makeTestEntry(name: []const u8, time_per_op_ns: f64) ParsedEntry {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= MAX_NAME_LENGTH);
    var e: ParsedEntry = .{};
    @memcpy(e.name[0..name.len], name);
    e.name_length = @intCast(name.len);
    e.time_per_op_ns = time_per_op_ns;
    return e;
}

fn makeTestEntryWithPercentiles(name: []const u8, time_per_op_ns: f64, p99: f64) ParsedEntry {
    var e = makeTestEntry(name, time_per_op_ns);
    e.has_percentiles = true;
    e.p50_per_op_ns = time_per_op_ns;
    e.p99_per_op_ns = p99;
    return e;
}

fn makeTestEntryWithMin(name: []const u8, time_per_op_ns: f64, min_per_op_ns: f64) ParsedEntry {
    var e = makeTestEntry(name, time_per_op_ns);
    e.has_min = true;
    e.min_per_op_ns = min_per_op_ns;
    return e;
}
