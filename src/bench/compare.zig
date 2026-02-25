//! Benchmark Comparison Tool
//!
//! Reads two benchmark JSON files (baseline and current), compares
//! `time_per_op_ns` for each named benchmark, and flags regressions
//! above a configurable threshold.  When percentile data is present,
//! p99 tail latency is checked independently — a p99 regression is
//! flagged even when the average looks fine.
//!
//! Usage:
//!   zig build bench-compare -- baseline.json current.json [--threshold 15]
//!
//! Exit code 0: no regressions detected.
//! Exit code 1: one or more regressions above the threshold.
//!
//! All comparison storage is fixed-capacity and stack-resident.  Heap
//! allocation occurs only for file I/O and JSON parsing (via page_allocator),
//! freed immediately after copying into fixed buffers.

const std = @import("std");

// =============================================================================
// Limits
// =============================================================================

/// Maximum benchmark entries per file.  Matches json_writer.zig.
const MAX_ENTRIES: u32 = 256;

/// Maximum benchmark name length in bytes.  Matches json_writer.zig.
const MAX_NAME_LENGTH: u32 = 128;

/// Maximum file path length for CLI arguments.
const MAX_PATH_LENGTH: u32 = 1024;

/// Maximum module name length (e.g. "context", "layout").
const MAX_MODULE_NAME_LENGTH: u32 = 64;

/// Maximum metadata string length (os, arch, date fields).
const MAX_META_STRING_LENGTH: u32 = 32;

/// Default regression threshold in percent.  A benchmark whose
/// time_per_op_ns increases by more than this percentage is flagged.
const DEFAULT_THRESHOLD_PERCENT: f64 = 15.0;

/// Maximum JSON file size we will attempt to read (4 MB).
/// 256 entries with full names and percentiles serializes to ~100 KB;
/// 4 MB provides 40x headroom for unexpected verbosity.
const MAX_JSON_FILE_BYTES: u32 = 4 * 1024 * 1024;

/// Comparison table column widths, in characters.
const COLUMN_WIDTH_NAME: u32 = 38;
const COLUMN_WIDTH_VALUE: u32 = 16;
const COLUMN_WIDTH_DELTA: u32 = 10;
const COLUMN_WIDTH_STATUS: u32 = 14;

/// Total table width: name + 2 values + delta + status + padding.
const TABLE_WIDTH: u32 = COLUMN_WIDTH_NAME + COLUMN_WIDTH_VALUE * 2 +
    COLUMN_WIDTH_DELTA + COLUMN_WIDTH_STATUS + 4;

// =============================================================================
// Parsed Benchmark Entry
// =============================================================================

/// A single benchmark result extracted from a JSON report file.
/// All strings are copied into fixed-size buffers so the JSON parse
/// tree can be freed immediately.
const ParsedEntry = struct {
    name: [MAX_NAME_LENGTH]u8 = [_]u8{0} ** MAX_NAME_LENGTH,
    name_length: u32 = 0,

    operation_count: u32 = 0,
    total_time_ns: u64 = 0,
    iterations: u32 = 0,
    avg_time_ms: f64 = 0.0,
    time_per_op_ns: f64 = 0.0,

    has_percentiles: bool = false,
    p50_per_op_ns: f64 = 0.0,
    p99_per_op_ns: f64 = 0.0,

    fn nameSlice(self: *const ParsedEntry) []const u8 {
        std.debug.assert(self.name_length > 0);
        std.debug.assert(self.name_length <= MAX_NAME_LENGTH);
        return self.name[0..self.name_length];
    }
};

// =============================================================================
// Parsed Report — all entries from one JSON file
// =============================================================================

const ParsedReport = struct {
    module: [MAX_MODULE_NAME_LENGTH]u8 = [_]u8{0} ** MAX_MODULE_NAME_LENGTH,
    module_length: u32 = 0,

    os: [MAX_META_STRING_LENGTH]u8 = [_]u8{0} ** MAX_META_STRING_LENGTH,
    os_length: u32 = 0,

    arch: [MAX_META_STRING_LENGTH]u8 = [_]u8{0} ** MAX_META_STRING_LENGTH,
    arch_length: u32 = 0,

    date: [MAX_META_STRING_LENGTH]u8 = [_]u8{0} ** MAX_META_STRING_LENGTH,
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

    /// Linear scan by name.  With ≤256 entries this is faster than
    /// building a hash map, and avoids heap allocation.
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

// =============================================================================
// Comparison Types
// =============================================================================

const ComparisonStatus = enum(u8) {
    ok = 0,
    regression = 1,
    improvement = 2,
    new_entry = 3,
    removed_entry = 4,
};

/// One row in the comparison table.
const ComparisonEntry = struct {
    name: [MAX_NAME_LENGTH]u8 = [_]u8{0} ** MAX_NAME_LENGTH,
    name_length: u32 = 0,

    baseline_ns_per_op: f64 = 0.0,
    current_ns_per_op: f64 = 0.0,
    delta_percent: f64 = 0.0,

    /// Whether both entries have percentile data.
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

/// Aggregate comparison results across all entries.
/// Capacity is 2 × MAX_ENTRIES to handle the worst case where
/// every entry in baseline and current is unique (no overlap).
const ComparisonResult = struct {
    /// 2 × 256 entries × ~200 bytes each ≈ 100 KB on the stack.
    entries: [MAX_ENTRIES * 2]ComparisonEntry = undefined,
    count: u32 = 0,

    count_compared: u32 = 0,
    count_regressions: u32 = 0,
    count_improvements: u32 = 0,
    count_new: u32 = 0,
    count_removed: u32 = 0,

    fn addEntry(self: *ComparisonResult, e: ComparisonEntry) void {
        std.debug.assert(self.count < MAX_ENTRIES * 2);
        std.debug.assert(e.name_length > 0);
        self.entries[self.count] = e;
        self.count += 1;
    }
};

// =============================================================================
// CLI Argument Parsing
// =============================================================================

const Args = struct {
    baseline_path: [MAX_PATH_LENGTH]u8 = [_]u8{0} ** MAX_PATH_LENGTH,
    baseline_path_length: u32 = 0,

    current_path: [MAX_PATH_LENGTH]u8 = [_]u8{0} ** MAX_PATH_LENGTH,
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

/// Parse CLI arguments: <baseline.json> <current.json> [--threshold N].
/// Positional args come first; --threshold is optional.
fn parseArgs() ArgsError!Args {
    const argv = std.os.argv;
    std.debug.assert(argv.len >= 1); // argv[0] is always the program name.

    var args: Args = .{};
    var positional_count: u32 = 0;

    var i: u32 = 1;
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

        // Positional argument: first is baseline, second is current.
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
        // Extra positional args are silently ignored.
    }

    if (args.baseline_path_length == 0) return error.missing_baseline;
    if (args.current_path_length == 0) return error.missing_current;
    return args;
}

// =============================================================================
// JSON Parsing Helpers
// =============================================================================

/// Extract an f64 from a JSON value that may be encoded as integer or float.
/// JSON serializers sometimes emit `17` instead of `17.0` for round floats.
fn jsonAsFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

/// Extract a u32 from a JSON integer value.
fn jsonAsU32(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @as(u32, @intCast(i)) else null,
        else => null,
    };
}

/// Extract a u64 from a JSON integer value.
fn jsonAsU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
        else => null,
    };
}

/// Copy a JSON string into a fixed-size buffer.  Returns the number
/// of bytes copied, or 0 if the value is not a string or exceeds capacity.
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

// =============================================================================
// Report Loading
// =============================================================================

const LoadError = error{
    file_open_failed,
    file_read_failed,
    json_parse_failed,
    missing_metadata,
    missing_benchmarks,
    entry_limit_exceeded,
};

/// Read a JSON benchmark file and parse it into a fixed-capacity report.
/// Heap allocation for file I/O and JSON parsing is freed before return.
fn loadReport(path: []const u8) LoadError!ParsedReport {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= MAX_PATH_LENGTH);

    const allocator = std.heap.page_allocator;

    // Read the entire file into memory.
    const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
        return error.file_open_failed;
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, MAX_JSON_FILE_BYTES) catch {
        return error.file_read_failed;
    };
    defer allocator.free(contents);

    // Parse JSON.  The parsed tree references `contents`, so both must
    // stay alive until we finish copying into the fixed-capacity report.
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

/// Extract metadata and benchmark entries from a parsed JSON value
/// into a stack-resident ParsedReport.
fn extractReport(root_value: std.json.Value) LoadError!ParsedReport {
    const root = switch (root_value) {
        .object => |obj| obj,
        else => return error.json_parse_failed,
    };

    var report: ParsedReport = .{};

    // -- Metadata --
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

    // -- Benchmark entries --
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

/// Parse one benchmark entry from a JSON object into a ParsedEntry.
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

    // Percentile fields: present as float or null in the JSON.
    if (obj.get("p50_per_op_ns")) |v| {
        if (jsonAsFloat(v)) |p50| {
            e.p50_per_op_ns = p50;
            // Mark percentiles present only if p99 also has a value.
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

// =============================================================================
// Comparison Logic
// =============================================================================

/// Compute percentage change from baseline to current.
/// Positive result means current is slower (regression).
/// Returns 0.0 when baseline is zero to avoid division by zero.
fn deltaPercent(baseline: f64, current: f64) f64 {
    std.debug.assert(baseline >= 0.0);
    std.debug.assert(current >= 0.0);
    if (baseline == 0.0) return 0.0;
    return ((current - baseline) / baseline) * 100.0;
}

/// Compare two reports and populate a ComparisonResult.
/// Iterates current entries first (to detect matches and new entries),
/// then scans baseline for removed entries.
fn compareReports(
    baseline: *const ParsedReport,
    current: *const ParsedReport,
    threshold_percent: f64,
) ComparisonResult {
    std.debug.assert(baseline.count <= MAX_ENTRIES);
    std.debug.assert(current.count <= MAX_ENTRIES);
    std.debug.assert(threshold_percent > 0.0);

    var result: ComparisonResult = .{};

    // Track which baseline entries have been matched, so we can
    // detect removed entries in the second pass.
    var baseline_matched: [MAX_ENTRIES]bool = [_]bool{false} ** MAX_ENTRIES;

    // First pass: iterate current entries.
    for (0..current.count) |ci| {
        const current_entry = &current.entries[ci];
        var comp = makeComparisonEntry(current_entry);

        if (baseline.findByName(current_entry.nameSlice())) |bi| {
            // Matched — compute deltas.
            baseline_matched[bi] = true;
            const baseline_entry = &baseline.entries[bi];
            populateMatchedComparison(&comp, baseline_entry, current_entry, threshold_percent);
            result.count_compared += 1;
        } else {
            // New entry — not present in baseline.
            comp.status = .new_entry;
            comp.current_ns_per_op = current_entry.time_per_op_ns;
            result.count_new += 1;
        }

        updateResultCounters(&result, comp.status);
        result.addEntry(comp);
    }

    // Second pass: find baseline entries not present in current.
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

/// Initialize a ComparisonEntry with the name from a ParsedEntry.
fn makeComparisonEntry(source: *const ParsedEntry) ComparisonEntry {
    std.debug.assert(source.name_length > 0);
    var comp: ComparisonEntry = .{};
    @memcpy(comp.name[0..source.name_length], source.name[0..source.name_length]);
    comp.name_length = source.name_length;
    return comp;
}

/// Fill in delta fields for a matched (baseline + current) comparison entry.
/// Determines status based on whether avg or p99 exceeds the threshold.
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

    // Percentile comparison when both sides have data.
    if (baseline_entry.has_percentiles and current_entry.has_percentiles) {
        comp.has_percentiles = true;
        comp.baseline_p99 = baseline_entry.p99_per_op_ns;
        comp.current_p99 = current_entry.p99_per_op_ns;
        comp.delta_p99_percent = deltaPercent(baseline_entry.p99_per_op_ns, current_entry.p99_per_op_ns);
    }

    // A regression is flagged if EITHER the average or the p99 tail
    // latency exceeds the threshold.  Tail latency regressions matter
    // even when the average looks fine (rule 7: back-of-envelope).
    const avg_regressed = comp.delta_percent > threshold_percent;
    const p99_regressed = comp.has_percentiles and comp.delta_p99_percent > threshold_percent;
    const avg_improved = comp.delta_percent < -threshold_percent;

    if (avg_regressed or p99_regressed) {
        comp.status = .regression;
    } else if (avg_improved) {
        comp.status = .improvement;
    } else {
        comp.status = .ok;
    }
}

/// Increment the regression/improvement counters on the result.
/// Called once per entry, only for matched entries (new/removed
/// are counted separately in compareReports).
fn updateResultCounters(result: *ComparisonResult, status: ComparisonStatus) void {
    switch (status) {
        .regression => result.count_regressions += 1,
        .improvement => result.count_improvements += 1,
        .ok, .new_entry, .removed_entry => {},
    }
}

// =============================================================================
// Output Formatting
// =============================================================================

/// Write a character repeated `count` times to stderr.
/// Replaces `writer.writeByteNTimes()` which is unavailable in Zig 0.15.
fn printRepeat(char: u8, count: u32) void {
    var buf: [TABLE_WIDTH]u8 = undefined;
    const len = @min(count, TABLE_WIDTH);
    @memset(buf[0..len], char);
    std.debug.print("{s}", .{buf[0..len]});
}

/// Print the full comparison report to stderr.
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

/// Print the report header with file paths and metadata.
fn printHeader(
    args: *const Args,
    baseline: *const ParsedReport,
    current: *const ParsedReport,
) void {
    printRepeat('=', TABLE_WIDTH);
    std.debug.print("\n", .{});

    // Title line: module name and platform if available.
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

    // File paths with dates.
    printPathLine("  Baseline", args.baselineSlice(), baseline.dateSlice());
    printPathLine("  Current ", args.currentSlice(), current.dateSlice());

    // Threshold.
    std.debug.print("  Threshold: {d:.1}%\n", .{args.threshold_percent});
}

/// Print one "Baseline: path (date)" line.
fn printPathLine(label: []const u8, path: []const u8, date: []const u8) void {
    std.debug.assert(label.len > 0);
    std.debug.assert(path.len > 0);
    if (date.len > 0) {
        std.debug.print("{s}: {s} ({s})\n", .{ label, path, date });
    } else {
        std.debug.print("{s}: {s}\n", .{ label, path });
    }
}

/// Print the column header row.
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

/// Format and print one comparison row.
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

    // Sub-line for p99 tail latency when percentile data exists.
    if (entry.has_percentiles) {
        printPercentileLine(entry);
    }
}

/// Print a sub-line showing p99 comparison, indented under the main row.
fn printPercentileLine(entry: *const ComparisonEntry) void {
    std.debug.assert(entry.has_percentiles);

    const sign: []const u8 = if (entry.delta_p99_percent >= 0) "+" else "";
    std.debug.print("  {s:>" ++ widthStr(COLUMN_WIDTH_NAME) ++ "}" ++
        "  p99: {d:.2} -> {d:.2} ns/op ({s}{d:.1}%)\n", .{
        "",
        entry.baseline_p99,
        entry.current_p99,
        sign,
        entry.delta_p99_percent,
    });
}

/// Print the summary footer.
fn printSummary(result: *const ComparisonResult, threshold_percent: f64) void {
    std.debug.assert(threshold_percent > 0.0);

    printRepeat('-', TABLE_WIDTH);
    std.debug.print("\n", .{});

    std.debug.print("  {d} compared | {d} regressed | {d} improved | {d} new | {d} removed\n", .{
        result.count_compared,
        result.count_regressions,
        result.count_improvements,
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

// =============================================================================
// Formatting Helpers
// =============================================================================

/// Format a ns/op value for display, or "--" for missing entries.
fn formatNsPerOp(value: f64, status: ComparisonStatus, is_baseline: bool, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 16);
    // Show "--" for the side that doesn't exist.
    if (is_baseline and status == .new_entry) return "--";
    if (!is_baseline and status == .removed_entry) return "--";
    return std.fmt.bufPrint(buf, "{d:.2} ns/op", .{value}) catch "--";
}

/// Format a delta percentage, with sign prefix.
fn formatDelta(delta_percent: f64, status: ComparisonStatus, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 16);
    if (status == .new_entry) return "NEW";
    if (status == .removed_entry) return "REMOVED";
    const sign: []const u8 = if (delta_percent >= 0) "+" else "";
    return std.fmt.bufPrint(buf, "{s}{d:.1}%", .{ sign, delta_percent }) catch "?";
}

/// Human-readable status label.
fn statusLabel(status: ComparisonStatus) []const u8 {
    return switch (status) {
        .ok => "",
        .regression => "<< REGRESSED",
        .improvement => ">> improved",
        .new_entry => "(new)",
        .removed_entry => "(removed)",
    };
}

/// Convert a comptime u32 to a decimal string for use in format specifiers.
/// Zig's `std.fmt` requires comptime-known width strings.
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

/// Count the number of decimal digits in a comptime u32.
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

// =============================================================================
// Usage Message
// =============================================================================

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

// =============================================================================
// Entry Point
// =============================================================================

pub fn main() void {
    const args = parseArgs() catch |err| {
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

    const baseline = loadReport(args.baselineSlice()) catch |err| {
        std.debug.print("bench-compare: failed to load baseline \"{s}\": {s}\n", .{
            args.baselineSlice(),
            @errorName(err),
        });
        std.process.exit(2);
    };

    const current = loadReport(args.currentSlice()) catch |err| {
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

// =============================================================================
// Tests
// =============================================================================

test "deltaPercent: basic cases" {
    // No change.
    const zero = deltaPercent(100.0, 100.0);
    std.debug.assert(zero == 0.0);

    // 20% regression (slower).
    const regression = deltaPercent(100.0, 120.0);
    std.debug.assert(regression > 19.9);
    std.debug.assert(regression < 20.1);

    // 20% improvement (faster).
    const improvement = deltaPercent(100.0, 80.0);
    std.debug.assert(improvement > -20.1);
    std.debug.assert(improvement < -19.9);

    // Zero baseline returns 0 (no division by zero).
    const zero_baseline = deltaPercent(0.0, 42.0);
    std.debug.assert(zero_baseline == 0.0);
}

test "parseArgs: rejects missing arguments" {
    // In the test runner, argv contains the test binary plus runner-specific
    // flags.  The exact error depends on how many args the runner passes,
    // but parseArgs must always fail — it never sees two valid JSON paths.
    if (parseArgs()) |_| {
        // parseArgs should never succeed in the test runner context.
        unreachable;
    } else |err| {
        std.debug.assert(err == error.missing_baseline or err == error.missing_current);
    }
}

test "jsonAsFloat: handles integer and float values" {
    // Float value.
    const float_val = std.json.Value{ .float = 42.5 };
    const f = jsonAsFloat(float_val);
    std.debug.assert(f != null);
    std.debug.assert(f.? == 42.5);

    // Integer value promoted to float.
    const int_val = std.json.Value{ .integer = 100 };
    const i = jsonAsFloat(int_val);
    std.debug.assert(i != null);
    std.debug.assert(i.? == 100.0);

    // Null value.
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
    var dest: [32]u8 = [_]u8{0} ** 32;
    const str_val = std.json.Value{ .string = "hello" };
    const len = copyJsonString(str_val, &dest);
    std.debug.assert(len == 5);
    std.debug.assert(std.mem.eql(u8, dest[0..5], "hello"));

    // Non-string returns 0.
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

    // First entry: no percentiles.
    std.debug.assert(std.mem.eql(u8, report.entries[0].nameSlice(), "alpha"));
    std.debug.assert(report.entries[0].operation_count == 8);
    std.debug.assert(report.entries[0].time_per_op_ns == 17.02);
    std.debug.assert(!report.entries[0].has_percentiles);

    // Second entry: with percentiles.
    std.debug.assert(std.mem.eql(u8, report.entries[1].nameSlice(), "beta"));
    std.debug.assert(report.entries[1].has_percentiles);
    std.debug.assert(report.entries[1].p50_per_op_ns == 55.0);
    std.debug.assert(report.entries[1].p99_per_op_ns == 120.0);
}

test "compareReports: detects regressions and improvements" {
    // Build two minimal reports by hand.
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    // Entry "fast" — 10% slower (below 15% threshold).
    baseline.entries[0] = makeTestEntry("fast", 100.0);
    current.entries[0] = makeTestEntry("fast", 110.0);

    // Entry "slow" — 25% slower (above threshold).
    baseline.entries[1] = makeTestEntry("slow", 100.0);
    current.entries[1] = makeTestEntry("slow", 125.0);

    // Entry "better" — 20% faster (improvement).
    baseline.entries[2] = makeTestEntry("better", 100.0);
    current.entries[2] = makeTestEntry("better", 80.0);

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

test "compareReports: detects new and removed entries" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    // "kept" exists in both.
    baseline.entries[0] = makeTestEntry("kept", 50.0);
    current.entries[0] = makeTestEntry("kept", 50.0);

    // "old" only in baseline (removed).
    baseline.entries[1] = makeTestEntry("old", 75.0);

    // "fresh" only in current (new).
    current.entries[1] = makeTestEntry("fresh", 30.0);

    baseline.count = 2;
    current.count = 2;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count == 3); // kept + fresh + old
    std.debug.assert(result.count_compared == 1);
    std.debug.assert(result.count_new == 1);
    std.debug.assert(result.count_removed == 1);
}

test "compareReports: p99 regression flags even when avg is ok" {
    var baseline: ParsedReport = .{};
    var current: ParsedReport = .{};

    // Average is only 5% slower (below threshold), but p99 is 30% worse.
    baseline.entries[0] = makeTestEntryWithPercentiles("tail_bad", 100.0, 200.0);
    current.entries[0] = makeTestEntryWithPercentiles("tail_bad", 105.0, 260.0);

    baseline.count = 1;
    current.count = 1;

    const result = compareReports(&baseline, &current, 15.0);

    std.debug.assert(result.count_regressions == 1);
    std.debug.assert(result.entries[0].status == .regression);
    std.debug.assert(result.entries[0].has_percentiles);
}

test "widthStr: produces correct digit strings" {
    // Single digit.
    const s10 = widthStr(5);
    std.debug.assert(std.mem.eql(u8, s10, "5"));

    // Two digits.
    const s38 = widthStr(38);
    std.debug.assert(std.mem.eql(u8, s38, "38"));

    // Three digits.
    const s256 = widthStr(256);
    std.debug.assert(std.mem.eql(u8, s256, "256"));
}

test "formatDelta: formats sign and special statuses" {
    var buf: [32]u8 = undefined;

    // Positive delta shows "+".
    const pos = formatDelta(12.3, .ok, &buf);
    std.debug.assert(std.mem.eql(u8, pos, "+12.3%"));

    // New entry shows "NEW".
    var buf2: [32]u8 = undefined;
    const new = formatDelta(0.0, .new_entry, &buf2);
    std.debug.assert(std.mem.eql(u8, new, "NEW"));
}

// =============================================================================
// Test Helpers
// =============================================================================

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
    e.p50_per_op_ns = time_per_op_ns; // Use avg as p50 for simplicity.
    e.p99_per_op_ns = p99;
    return e;
}
