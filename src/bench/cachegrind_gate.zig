const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = std.Io.Dir;

const threshold_percent_default: f64 = 0.5;

const modules = [_][]const u8{ "layout", "core", "text", "accessibility" };

const benchmark_count_max: u32 = 256;

const name_length_max: u32 = 128 + 4;

const path_length_max: u32 = 1024;

const job_count_max: u32 = 64;

const json_bytes_max: u32 = 1024 * 1024;

const Side = enum { base, head };

const BenchmarkList = struct {
    names: [benchmark_count_max][name_length_max]u8,
    name_lengths: [benchmark_count_max]u8,
    ir: [benchmark_count_max]u64,
    count: u32,

    fn name(self: *const BenchmarkList, index: u32) []const u8 {
        std.debug.assert(index < self.count);
        return self.names[index][0..self.name_lengths[index]];
    }

    fn find(self: *const BenchmarkList, key: []const u8) ?u32 {
        std.debug.assert(key.len > 0);
        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            if (std.mem.eql(u8, self.name(index), key)) return index;
        }
        return null;
    }
};

const Gate = struct {
    lists: [modules.len][2]BenchmarkList,
    present: [modules.len][2]bool,
};

const Args = struct {
    base_dir: []const u8 = "",
    head_dir: []const u8 = "",
    work_dir: []const u8 = "bench-ir-work",
    threshold_percent: f64 = threshold_percent_default,
    job_count: u32 = 0,
};

const Totals = struct {
    compared: u32 = 0,
    regressed: u32 = 0,
    improved: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
};

pub fn main(init: std.process.Init) void {
    const io = init.io;
    var args = parseArgs(init.minimal.args.vector) catch |err| {
        std.debug.print("bench-ir-gate: {s}\n{s}", .{ @errorName(err), usage });
        std.process.exit(2);
    };
    if (args.job_count == 0) args.job_count = defaultJobCount();
    std.debug.assert(args.job_count <= job_count_max);

    disableAddressRandomization();
    const start = Io.Clock.awake.now(io);

    const gate = std.heap.page_allocator.create(Gate) catch fail("out of memory", .{});
    defer std.heap.page_allocator.destroy(gate);

    for (modules, 0..) |module, module_index| {
        measureModule(io, &args, gate, @intCast(module_index), module);
    }

    const totals = report(io, gate, args.threshold_percent);
    const elapsed_s = start.durationTo(Io.Clock.awake.now(io)).toSeconds();
    std.debug.print(
        "bench-ir-gate: {d} compared, {d} regressed, {d} improved, {d} new, {d} removed in {d} s\n",
        .{ totals.compared, totals.regressed, totals.improved, totals.added, totals.removed, elapsed_s },
    );
    if (totals.regressed > 0) std.process.exit(1);
}

const usage =
    \\Usage: bench-ir-gate --base <dir> --head <dir> [--work <dir>]
    \\                     [--threshold <percent>] [--jobs <count>]
    \\
    \\  --base, --head  Directories made by `zig build bench-ir-build`.
    \\  --work          Scratch directory for JSON and Cachegrind output.
    \\  --threshold     Fail when a benchmark's Ir grows by more than this
    \\                  percentage (default 0.5). Improvements never fail.
    \\  --jobs          Concurrent Valgrind processes (default: CPU count).
    \\
;

fn parseArgs(argv: []const [*:0]const u8) !Args {
    var args: Args = .{};
    var index: u32 = 1;
    const argc: u32 = @intCast(argv.len);
    while (index < argc) : (index += 2) {
        const flag = std.mem.sliceTo(argv[index], 0);
        if (index + 1 >= argc) return error.missing_flag_value;
        const value = std.mem.sliceTo(argv[index + 1], 0);
        if (value.len == 0) return error.empty_flag_value;
        if (value.len > path_length_max / 2) return error.flag_value_too_long;

        if (std.mem.eql(u8, flag, "--base")) {
            args.base_dir = value;
        } else if (std.mem.eql(u8, flag, "--head")) {
            args.head_dir = value;
        } else if (std.mem.eql(u8, flag, "--work")) {
            args.work_dir = value;
        } else if (std.mem.eql(u8, flag, "--threshold")) {
            args.threshold_percent = std.fmt.parseFloat(f64, value) catch return error.invalid_threshold;
            if (!(args.threshold_percent > 0)) return error.invalid_threshold;
        } else if (std.mem.eql(u8, flag, "--jobs")) {
            args.job_count = std.fmt.parseInt(u32, value, 10) catch return error.invalid_jobs;
            if (args.job_count == 0) return error.invalid_jobs;
            if (args.job_count > job_count_max) return error.invalid_jobs;
        } else {
            return error.unknown_flag;
        }
    }
    if (args.base_dir.len == 0) return error.missing_base;
    if (args.head_dir.len == 0) return error.missing_head;
    return args;
}

fn defaultJobCount() u32 {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const count: u32 = @intCast(@min(cpu_count, job_count_max));
    std.debug.assert(count >= 1);
    return count;
}

fn disableAddressRandomization() void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    const addr_no_randomize: usize = 0x0040000;
    const query_only: usize = 0xffffffff;
    const current = linux.syscall1(.personality, query_only);
    const result = linux.syscall1(.personality, current | addr_no_randomize);
    if (linux.errno(result) != .SUCCESS) {
        std.debug.print("bench-ir-gate: warning: cannot disable ASLR; Ir may vary more\n", .{});
    }
}

fn fail(comptime format: []const u8, values: anytype) noreturn {
    std.debug.print("bench-ir-gate: " ++ format ++ "\n", values);
    std.process.exit(2);
}

fn measureModule(io: Io, args: *const Args, gate: *Gate, module_index: u32, module: []const u8) void {
    std.debug.assert(module_index < modules.len);
    for ([_]Side{ .base, .head }) |side| {
        const side_index = @backingInt(side);
        const list = &gate.lists[module_index][side_index];
        list.count = 0;
        var binary_buffer: [path_length_max]u8 = undefined;
        const binary = binaryPath(&binary_buffer, args, side, module);
        gate.present[module_index][side_index] = fileExists(io, binary);
        if (!gate.present[module_index][side_index]) {
            if (side == .head) fail("missing head harness {s}", .{binary});
            std.debug.print("bench-ir-gate: no base harness {s}; its benchmarks count as new\n", .{binary});
            continue;
        }
        listBenchmarks(io, args, side, module, binary, list);
        std.debug.print("bench-ir-gate: {s} {s}: {d} benchmarks\n", .{ @tagName(side), module, list.count });
    }
    measureLists(io, args, module, &gate.lists[module_index], gate.present[module_index]);
}

fn binaryPath(buffer: []u8, args: *const Args, side: Side, module: []const u8) []const u8 {
    const dir = if (side == .base) args.base_dir else args.head_dir;
    return std.fmt.bufPrint(buffer, "{s}/{s}-bench", .{ dir, module }) catch fail("path too long", .{});
}

fn fileExists(io: Io, path: []const u8) bool {
    std.debug.assert(path.len > 0);
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn listBenchmarks(
    io: Io,
    args: *const Args,
    side: Side,
    module: []const u8,
    binary: []const u8,
    list: *BenchmarkList,
) void {
    var dir_buffer: [path_length_max]u8 = undefined;
    const json_dir = std.fmt.bufPrint(&dir_buffer, "{s}/{s}/{s}", .{
        args.work_dir,
        @tagName(side),
        module,
    }) catch fail("path too long", .{});
    Dir.cwd().deleteTree(io, json_dir) catch {};
    Dir.cwd().createDirPath(io, json_dir) catch |err| fail("cannot create {s}: {s}", .{ json_dir, @errorName(err) });

    const argv = [_][]const u8{ binary, "--json-dir", json_dir };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| fail("cannot run {s}: {s}", .{ binary, @errorName(err) });
    const term = child.wait(io) catch |err| fail("cannot wait for {s}: {s}", .{ binary, @errorName(err) });
    if (!term.success()) fail("{s} --json-dir {s} failed", .{ binary, json_dir });

    const bytes = readReport(io, json_dir);
    defer std.heap.page_allocator.free(bytes);
    parseNames(bytes, list) catch |err| fail("bad JSON in {s}: {s}", .{ json_dir, @errorName(err) });
    if (list.count == 0) fail("{s} recorded no benchmarks", .{binary});
}

fn readReport(io: Io, json_dir: []const u8) []u8 {
    var dir = Dir.cwd().openDir(io, json_dir, .{ .iterate = true }) catch |err| {
        fail("cannot open {s}: {s}", .{ json_dir, @errorName(err) });
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch |err| fail("cannot list {s}: {s}", .{ json_dir, @errorName(err) })) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        return dir.readFileAlloc(io, entry.name, std.heap.page_allocator, .limited(json_bytes_max)) catch |err| {
            fail("cannot read {s}/{s}: {s}", .{ json_dir, entry.name, @errorName(err) });
        };
    }
    fail("no JSON report in {s}", .{json_dir});
}

fn parseNames(bytes: []const u8, list: *BenchmarkList) !void {
    std.debug.assert(bytes.len > 0);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.not_an_object;
    const benchmarks = parsed.value.object.get("benchmarks") orelse return error.missing_benchmarks;
    if (benchmarks != .array) return error.missing_benchmarks;
    if (benchmarks.array.items.len > benchmark_count_max) return error.too_many_benchmarks;

    list.count = 0;
    for (benchmarks.array.items) |item| {
        if (item != .object) return error.bad_entry;
        const value = item.object.get("name") orelse return error.bad_entry;
        if (value != .string) return error.bad_entry;
        try appendName(list, value.string);
    }
    std.debug.assert(list.count == benchmarks.array.items.len);
}

fn appendName(list: *BenchmarkList, raw_name: []const u8) !void {
    std.debug.assert(list.count < benchmark_count_max);
    if (raw_name.len == 0) return error.empty_name;
    if (raw_name.len > name_length_max - 4) return error.name_too_long;

    var occurrence: u32 = 1;
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        const existing = list.name(index);
        const is_same_base = std.mem.startsWith(u8, existing, raw_name) and
            (existing.len == raw_name.len or existing[raw_name.len] == '#');
        if (is_same_base) occurrence += 1;
    }
    if (occurrence > 99) return error.too_many_repeats;

    const slot = &list.names[list.count];
    std.debug.assert(std.fmt.count("{s}#{d}", .{ raw_name, occurrence }) <= slot.len);
    const written = if (occurrence == 1)
        std.fmt.bufPrint(slot, "{s}", .{raw_name}) catch unreachable
    else
        std.fmt.bufPrint(slot, "{s}#{d}", .{ raw_name, occurrence }) catch unreachable;
    list.name_lengths[list.count] = @intCast(written.len);
    list.ir[list.count] = 0;
    list.count += 1;
}

const Job = struct {
    side: Side,
    index: u32,
    child: std.process.Child,
    index_text: [16]u8,
    out_file_flag: [path_length_max]u8,
    out_file_length: u32,
    binary: [path_length_max]u8,
    binary_length: u32,

    fn outFile(self: *const Job) []const u8 {
        const prefix = "--cachegrind-out-file=".len;
        std.debug.assert(self.out_file_length > prefix);
        return self.out_file_flag[prefix..self.out_file_length];
    }
};

fn measureLists(
    io: Io,
    args: *const Args,
    module: []const u8,
    lists: *[2]BenchmarkList,
    present: [2]bool,
) void {
    const base_count: u32 = if (present[0]) lists[0].count else 0;
    const run_count = base_count + lists[1].count;
    std.debug.assert(run_count <= 2 * benchmark_count_max);

    var jobs: [job_count_max]Job = undefined;
    var next_run: u32 = 0;
    while (next_run < run_count) {
        const batch_count = @min(args.job_count, run_count - next_run);
        for (jobs[0..batch_count], 0..) |*job, offset| {
            const run: u32 = next_run + @as(u32, @intCast(offset));
            const side: Side = if (run < base_count) .base else .head;
            const index = if (side == .base) run else run - base_count;
            startJob(io, args, module, side, index, job);
        }
        for (jobs[0..batch_count]) |*job| {
            const list = &lists[@backingInt(job.side)];
            list.ir[job.index] = finishJob(io, job, list.name(job.index));
        }
        next_run += batch_count;
    }
}

fn startJob(io: Io, args: *const Args, module: []const u8, side: Side, index: u32, job: *Job) void {
    std.debug.assert(index < benchmark_count_max);
    job.side = side;
    job.index = index;
    const binary = binaryPath(&job.binary, args, side, module);
    job.binary_length = @intCast(binary.len);
    comptime std.debug.assert(std.fmt.count("{d}", .{
        std.math.maxInt(u32),
    }) <= @sizeOf(@TypeOf(job.index_text)));
    const index_text = std.fmt.bufPrint(&job.index_text, "{d}", .{index}) catch unreachable;
    const out_file_flag = std.fmt.bufPrint(&job.out_file_flag, "--cachegrind-out-file={s}/{s}/{s}/{d}.cg", .{
        args.work_dir,
        @tagName(side),
        module,
        index,
    }) catch fail("path too long", .{});
    job.out_file_length = @intCast(out_file_flag.len);

    const argv = [_][]const u8{
        "valgrind",
        "--tool=cachegrind",
        "--instr-at-start=no",
        "--cache-sim=no",
        "--branch-sim=no",
        out_file_flag,
        binary,
        "--cachegrind-benchmark",
        index_text,
    };
    job.child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| fail("cannot run valgrind: {s}", .{@errorName(err)});
}

fn finishJob(io: Io, job: *Job, name: []const u8) u64 {
    const binary = job.binary[0..job.binary_length];
    const term = job.child.wait(io) catch |err| fail("cannot wait for valgrind: {s}", .{@errorName(err)});
    if (!term.success()) {
        fail("valgrind --tool=cachegrind {s} --cachegrind-benchmark {d} ({s}) failed", .{ binary, job.index, name });
    }
    const out_file = job.outFile();
    const bytes = Dir.cwd().readFileAlloc(io, out_file, std.heap.page_allocator, .limited(json_bytes_max)) catch |err| {
        fail("cannot read {s}: {s}", .{ out_file, @errorName(err) });
    };
    defer std.heap.page_allocator.free(bytes);
    const ir = parseSummaryIr(bytes) orelse fail("no summary line in {s}", .{out_file});
    if (ir == 0) {
        fail("{s} recorded no instructions for {s}: was it built by `zig build bench-ir-build`?", .{ binary, name });
    }
    return ir;
}

fn parseSummaryIr(bytes: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_count: u32 = 0;
    while (lines.next()) |line| : (line_count += 1) {
        std.debug.assert(line_count <= bytes.len);
        if (!std.mem.startsWith(u8, line, "summary:")) continue;
        const value = std.mem.trim(u8, line["summary:".len..], " \r");
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

const Status = enum { ok, regressed, improved, added, removed };

fn classify(base_ir: u64, head_ir: u64, threshold_percent: f64) Status {
    std.debug.assert(base_ir > 0);
    std.debug.assert(head_ir > 0);
    std.debug.assert(threshold_percent > 0);
    const delta = deltaPercent(base_ir, head_ir);
    if (delta > threshold_percent) return .regressed;
    if (delta < -threshold_percent) return .improved;
    return .ok;
}

fn deltaPercent(base_ir: u64, head_ir: u64) f64 {
    std.debug.assert(base_ir > 0);
    const base: f64 = @floatFromInt(base_ir);
    const head: f64 = @floatFromInt(head_ir);
    return (head - base) / base * 100.0;
}

fn report(io: Io, gate: *const Gate, threshold_percent: f64) Totals {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stdout().writerStreaming(io, &buffer);
    const out = &writer.interface;
    var totals: Totals = .{};
    writeReport(out, gate, threshold_percent, &totals) catch |err| fail("cannot write report: {s}", .{@errorName(err)});
    writer.flush() catch |err| fail("cannot write report: {s}", .{@errorName(err)});
    return totals;
}

fn writeReport(out: *Io.Writer, gate: *const Gate, threshold_percent: f64, totals: *Totals) !void {
    try out.print("## Instruction counts (Cachegrind Ir), threshold +{d:.2}%\n\n", .{threshold_percent});
    try out.writeAll("| benchmark | base Ir | head Ir | delta | |\n|---|---:|---:|---:|---|\n");
    for (modules, 0..) |module, module_index| {
        const base = &gate.lists[module_index][0];
        const head = &gate.lists[module_index][1];
        var index: u32 = 0;
        while (index < head.count) : (index += 1) {
            const key = head.name(index);
            const base_index = if (gate.present[module_index][0]) base.find(key) else null;
            if (base_index) |found| {
                const status = classify(base.ir[found], head.ir[index], threshold_percent);
                try writeRow(out, module, key, base.ir[found], head.ir[index], status);
                countStatus(totals, status);
            } else {
                try out.print("| {s}/{s} | | {d} | | new |\n", .{ module, key, head.ir[index] });
                totals.added += 1;
            }
        }
        try writeRemoved(out, module, base, head, totals);
    }
    try out.print("\n{d} regressed above +{d:.2}% of {d} compared.\n", .{
        totals.regressed,
        threshold_percent,
        totals.compared,
    });
}

fn writeRow(out: *Io.Writer, module: []const u8, key: []const u8, base_ir: u64, head_ir: u64, status: Status) !void {
    const label = switch (status) {
        .ok => "",
        .regressed => "**REGRESSED**",
        .improved => "improved",
        .added, .removed => unreachable,
    };
    try out.print("| {s}/{s} | {d} | {d} | {d:.3}% | {s} |\n", .{
        module,
        key,
        base_ir,
        head_ir,
        deltaPercent(base_ir, head_ir),
        label,
    });
}

fn writeRemoved(
    out: *Io.Writer,
    module: []const u8,
    base: *const BenchmarkList,
    head: *const BenchmarkList,
    totals: *Totals,
) !void {
    var index: u32 = 0;
    while (index < base.count) : (index += 1) {
        const key = base.name(index);
        if (head.find(key) != null) continue;
        try out.print("| {s}/{s} | {d} | | | removed |\n", .{ module, key, base.ir[index] });
        totals.removed += 1;
    }
}

fn countStatus(totals: *Totals, status: Status) void {
    totals.compared += 1;
    switch (status) {
        .ok => {},
        .regressed => totals.regressed += 1,
        .improved => totals.improved += 1,
        .added, .removed => unreachable,
    }
}

test "classify: growth past the threshold regresses, a drop never fails" {
    try std.testing.expectEqual(Status.regressed, classify(1_000_000, 1_006_000, 0.5));
    try std.testing.expectEqual(Status.ok, classify(1_000_000, 1_004_000, 0.5));
    try std.testing.expectEqual(Status.ok, classify(1_000_000, 995_000, 0.5));
    try std.testing.expectEqual(Status.improved, classify(1_000_000, 900_000, 0.5));
    try std.testing.expectEqual(Status.ok, classify(1_000_000, 1_005_000, 0.5));
}

test "parseSummaryIr: reads the summary line of a Cachegrind output file" {
    const file =
        \\# callgraph format
        \\version: 1
        \\cmd: ./text-bench --cachegrind-benchmark 3
        \\events: Ir
        \\fl=???
        \\fn=main
        \\0 12
        \\summary: 1714412
        \\
    ;
    try std.testing.expectEqual(@as(?u64, 1_714_412), parseSummaryIr(file));
    try std.testing.expectEqual(@as(?u64, null), parseSummaryIr("events: Ir\n"));
}

test "parseNames: repeated names get distinct keys in call order" {
    const json =
        \\{"benchmarks": [{"name": "convex_8"}, {"name": "zigzag_32_butt_miter"},
        \\ {"name": "zigzag_32_butt_miter"}, {"name": "zigzag_32_butt_miter_x"}]}
    ;
    const list = try std.testing.allocator.create(BenchmarkList);
    defer std.testing.allocator.destroy(list);
    try parseNames(json, list);
    try std.testing.expectEqual(@as(u32, 4), list.count);
    try std.testing.expectEqualStrings("zigzag_32_butt_miter", list.name(1));
    try std.testing.expectEqualStrings("zigzag_32_butt_miter#2", list.name(2));
    try std.testing.expectEqualStrings("zigzag_32_butt_miter_x", list.name(3));
    try std.testing.expectEqual(@as(?u32, 2), list.find("zigzag_32_butt_miter#2"));
}
