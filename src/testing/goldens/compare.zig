//! Compare the core's goldens with the 0.3.1 goldens, step by step.
//!
//! The two runtimes draw the same pixels through different paths, so the
//! dumps are normalized before they are compared. Each rule removes a
//! difference in how a frame is recorded, never in what it shows:
//!
//! 1. The `packed` header is dropped: the clear colour is the window
//!    background behind the root box (the core uses the theme's `bg`, 0.3.1
//!    a fixed grey), and the root box covers it in both.
//! 2. `clip=` is dropped. 0.3.1 inserts the caret and preedit underline
//!    without the input's clip; the core draws them inside it.
//! 3. A quad becomes a fill item (when its fill is visible) and a border item
//!    (when it has one). 0.3.1 draws a box's fill and border as two quads and
//!    draws transparent quads for stacks; the core writes one quad per box
//!    and nothing for a box without a background or border.
//! 4. Paint is compared as a multiset per step: 0.3.1 draws text inputs after
//!    every other command, the core in tree order.
//! 5. Hit records drop the `key` flag: 0.3.1 routes keys to text inputs
//!    outside its listener lists, so it records none.
//! 6. Accessibility drops 0.3.1's `presentation` nodes, which its `Svg`
//!    component adds around the checkbox's checkmark; the core paints it.
//!
//! A remaining difference must be listed in `known_differences` with why.

const std = @import("std");

const assert = std.debug.assert;

pub const KnownDifference = struct {
    step: u32,
    legacy_line: []const u8,
    core_line: []const u8,
    reason: []const u8,
};

/// Paint items, hit lines, and accessibility lines of one step.
const Step = struct {
    label: []const u8,
    paint: std.ArrayList([]const u8) = .empty,
    hits: std.ArrayList([]const u8) = .empty,
    a11y: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Step, gpa: std.mem.Allocator) void {
        for (self.paint.items) |item| gpa.free(item);
        for (self.hits.items) |item| gpa.free(item);
        self.paint.deinit(gpa);
        self.hits.deinit(gpa);
        self.a11y.deinit(gpa);
    }
};

const step_count_max: u32 = 128;

/// Returns the number of differences not covered by `known`, after printing
/// each one.
pub fn compare(
    gpa: std.mem.Allocator,
    legacy: []const u8,
    core: []const u8,
    known: []const KnownDifference,
) !u32 {
    var legacy_steps: [step_count_max]Step = undefined;
    var core_steps: [step_count_max]Step = undefined;
    const legacy_count = try parse(gpa, legacy, &legacy_steps);
    defer for (legacy_steps[0..legacy_count]) |*step| step.deinit(gpa);
    const core_count = try parse(gpa, core, &core_steps);
    defer for (core_steps[0..core_count]) |*step| step.deinit(gpa);
    if (legacy_count != core_count) {
        std.debug.print(
            "step counts differ: legacy {d}, core {d}\n",
            .{ legacy_count, core_count },
        );
        return 1;
    }
    var unexplained: u32 = 0;
    for (legacy_steps[0..legacy_count], core_steps[0..core_count], 0..) |*a, *b, index| {
        unexplained += try diffLists(gpa, @intCast(index), a.paint.items, b.paint.items, known);
        unexplained += try diffLists(gpa, @intCast(index), a.hits.items, b.hits.items, known);
        unexplained += try diffLists(gpa, @intCast(index), a.a11y.items, b.a11y.items, known);
    }
    return unexplained;
}

fn parse(gpa: std.mem.Allocator, dump: []const u8, steps: *[step_count_max]Step) !u32 {
    var count: u32 = 0;
    var section: enum { paint, hits, a11y } = .paint;
    var lines = std.mem.splitScalar(u8, dump, '\n');
    while (lines.next()) |raw| {
        if (std.mem.startsWith(u8, raw, "== step ")) {
            assert(count < step_count_max);
            steps[count] = .{ .label = raw };
            count += 1;
            section = .paint;
            continue;
        }
        if (count == 0) continue;
        const step = &steps[count - 1];
        const line = std.mem.trim(u8, raw, " ");
        if (line.len == 0 or std.mem.startsWith(u8, line, "packed ")) continue;
        if (std.mem.eql(u8, line, "hits")) {
            section = .hits;
        } else if (std.mem.eql(u8, line, "a11y")) {
            section = .a11y;
        } else switch (section) {
            .paint => try addPaint(gpa, step, line),
            .hits => try step.hits.append(gpa, try without(gpa, line, " key")),
            .a11y => if (!std.mem.startsWith(u8, line, "presentation ")) {
                try step.a11y.append(gpa, line);
            },
        }
    }
    return count;
}

fn addPaint(gpa: std.mem.Allocator, step: *Step, line: []const u8) !void {
    const unclipped = if (std.mem.indexOf(u8, line, " clip=(")) |start| line[0..start] else line;
    if (!std.mem.startsWith(u8, unclipped, "quad ")) {
        try step.paint.append(gpa, try gpa.dupe(u8, unclipped));
        return;
    }
    // quad (x y w h) fill=#rrggbbaa[ border=w,w,w,w #rrggbbaa][ radius=...]
    const rect_end = std.mem.indexOfScalar(u8, unclipped, ')').? + 1;
    const rect = unclipped[5..rect_end];
    const fill = field(unclipped, "fill=").?;
    const radius = field(unclipped, "radius=") orelse "-";
    if (!std.mem.endsWith(u8, fill, "00")) {
        try step.paint.append(
            gpa,
            try std.fmt.allocPrint(gpa, "fill {s} {s} {s}", .{ rect, fill, radius }),
        );
    }
    if (field(unclipped, "border=")) |widths| {
        const color_start = std.mem.indexOf(u8, unclipped, widths).? + widths.len + 1;
        const color = unclipped[color_start..][0..9];
        try step.paint.append(gpa, try std.fmt.allocPrint(gpa, "border {s} {s} {s} {s}", .{
            rect, widths, color, radius,
        }));
    }
}

/// The value after `name` up to the next space.
fn field(line: []const u8, name: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, name) orelse return null) + name.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
    return line[start..end];
}

fn without(gpa: std.mem.Allocator, line: []const u8, part: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, line, part, "");
    const result = try gpa.alloc(u8, size);
    _ = std.mem.replace(u8, line, part, "", result);
    return result;
}

/// Multiset difference of two line lists; prints and counts what `known`
/// does not explain.
fn diffLists(
    gpa: std.mem.Allocator,
    step: u32,
    legacy: []const []const u8,
    core: []const []const u8,
    known: []const KnownDifference,
) !u32 {
    const a = try gpa.dupe([]const u8, legacy);
    defer gpa.free(a);
    const b = try gpa.dupe([]const u8, core);
    defer gpa.free(b);
    std.mem.sort([]const u8, a, {}, lessThan);
    std.mem.sort([]const u8, b, {}, lessThan);
    var unexplained: u32 = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        if (i < a.len and j < b.len and std.mem.eql(u8, a[i], b[j])) {
            i += 1;
            j += 1;
        } else if (j == b.len or (i < a.len and lessThan({}, a[i], b[j]))) {
            if (!isKnown(known, step, a[i], true)) {
                std.debug.print("step {d}: legacy only: {s}\n", .{ step, a[i] });
                unexplained += 1;
            }
            i += 1;
        } else {
            if (!isKnown(known, step, b[j], false)) {
                std.debug.print("step {d}: core only:   {s}\n", .{ step, b[j] });
                unexplained += 1;
            }
            j += 1;
        }
    }
    return unexplained;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn isKnown(known: []const KnownDifference, step: u32, line: []const u8, legacy_side: bool) bool {
    for (known) |difference| {
        if (difference.step != step) continue;
        const expected = if (legacy_side) difference.legacy_line else difference.core_line;
        if (std.mem.eql(u8, expected, line)) return true;
    }
    return false;
}
