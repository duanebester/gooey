// Fuzz targets generate random valid layout trees (`std.testing.Smith`) and
// run `endFrame()`. After every frame it asserts each bounding box has
// finite coordinates and non-negative size: `core/emit.zig` paints from
// these, so NaN would propagate into the packed frame and every GPU backend.
// Run with `zig build fuzz` (or `-- --infinite`).

const std = @import("std");
const gooey = @import("gooey");

// The fuzz module compiles standalone (separate root from `src/root.zig`),
// so types must come through the public `gooey.internals.layout.*` surface;
// if a name disappears the fuzzer fails to build.
const layout = gooey.internals.layout;
const engine_mod = layout.engine;
const types = layout.types;

const LayoutEngine = engine_mod.LayoutEngine;

/// The engine holds the `standard` profile's capacities, as an app would; the
/// caps below keep every tree well inside them.
const fuzz_capacity = layout.LayoutCapacity.fromLimits(&gooey.ResourceLimits.standard);
const Sizing = types.Sizing;
const SizingAxis = types.SizingAxis;
const Padding = types.Padding;

/// Smith inputs are unbounded but the engine's capacities are fixed; these
/// stay well under them to exercise the algorithm, not the panics.
const MAX_FUZZ_ELEMENTS: u32 = 256;
const MAX_FUZZ_DEPTH: u32 = 8;
const MAX_FUZZ_CHILDREN_PER_NODE: u32 = 8;
const MAX_FUZZ_TEXT_LEN: u32 = 64;

/// Viewport bounds, kept in the regime the renderer sees in production.
/// Stored as integers because `Smith.valueRangeAtMost` rejects `f32` (no
/// continuous range thanks to NaN/Inf); cast at use site.
const FUZZ_VIEWPORT_MIN: u32 = 64;
const FUZZ_VIEWPORT_MAX: u32 = 4096;

/// Asserts the engine's documented post-conditions on the resulting bounds.
pub fn fuzzLayoutTree(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var engine = try LayoutEngine.init(&fuzz_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(fuzzMeasureText, null);

    const viewport_w: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    const viewport_h: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    engine.beginFrame(viewport_w, viewport_h);

    var state: TreeState = .{ .smith = smith, .arena = arena.allocator(), .elements_emitted = 0 };
    try emitContainer(&engine, &state, 0);

    // Drain any unclosed containers: `emitContainer` should pair
    // open/close, and `closeElement` asserts would catch a bug before this.
    while (engine.open_element_stack.len > 0) engine.closeElement();

    try engine.endFrame();
    try assertBoundsFinite(&engine);
}

/// Build a random tree of word + whitespace sequences for the text
/// wrapping pass. Skinny viewport widths force wrapping to engage.
pub fn fuzzTextWrapping(_: void, smith: *std.testing.Smith) anyerror!void {
    var engine = try LayoutEngine.init(&fuzz_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(fuzzMeasureText, null);

    const viewport_w: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    engine.beginFrame(viewport_w, 1024);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(viewport_w, 1024),
            .padding = Padding.all(8),
            .layout_direction = .top_to_bottom,
        },
    });

    var text_buf: [MAX_FUZZ_TEXT_LEN]u8 = undefined;
    const written = smith.slice(&text_buf);
    const text = sanitizeText(text_buf[0..written]);
    try engine.text(text, .{
        .wrap_mode = .words,
        .font_size = 14,
    });
    engine.closeElement();

    try engine.endFrame();
}

const TreeState = struct {
    smith: *std.testing.Smith,
    arena: std.mem.Allocator,
    elements_emitted: u32,
};

/// Emit a container with random sizing + 0..N children, recursing up to
/// `MAX_FUZZ_DEPTH`. Caps total element count via `TreeState` so a
/// pathological Smith input can't exhaust the engine's elements.
fn emitContainer(engine: *LayoutEngine, state: *TreeState, depth: u32) anyerror!void {
    if (state.elements_emitted >= MAX_FUZZ_ELEMENTS) return;
    if (depth >= MAX_FUZZ_DEPTH) return;

    const sizing = randomSizing(state.smith);
    const layout_direction: types.LayoutDirection =
        if (state.smith.boolWeighted(1, 1)) .left_to_right else .top_to_bottom;
    const padding_amt: u16 = @intCast(state.smith.valueRangeAtMost(u16, 0, 16));
    const child_gap: u16 = @intCast(state.smith.valueRangeAtMost(u16, 0, 16));
    // Only rows wrap. Ratios run from 1:4 to 4:1, in quarters.
    const wrap = layout_direction == .left_to_right and state.smith.boolWeighted(1, 3);
    const aspect_ratio: ?f32 = if (state.smith.boolWeighted(1, 7))
        @as(f32, @floatFromInt(state.smith.valueRangeAtMost(u32, 1, 16))) / 4.0
    else
        null;

    try engine.openElement(.{
        .layout = .{
            .sizing = sizing,
            .padding = Padding.all(padding_amt),
            .child_gap = child_gap,
            .layout_direction = layout_direction,
            .aspect_ratio = aspect_ratio,
            .wrap = wrap,
        },
    });
    state.elements_emitted += 1;

    const child_count = state.smith.valueRangeAtMost(u32, 0, MAX_FUZZ_CHILDREN_PER_NODE);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        // Stop before the per-frame cap; `createElement` asserts on overflow.
        if (state.elements_emitted >= MAX_FUZZ_ELEMENTS) break;
        try emitContainer(engine, state, depth + 1);
    }

    engine.closeElement();
}

fn randomSizing(smith: *std.testing.Smith) Sizing {
    return .{
        .width = randomSizingAxis(smith),
        .height = randomSizingAxis(smith),
    };
}

/// Smith doesn't deal with `f32` directly (no continuous range), so a
/// `u32` is drawn and scaled into the target floating range.
fn randomSizingAxis(smith: *std.testing.Smith) SizingAxis {
    const kind = smith.valueRangeLessThan(u8, 0, 4);
    return switch (kind) {
        0 => SizingAxis.fit(),
        1 => SizingAxis.grow(),
        2 => SizingAxis.fixed(@floatFromInt(smith.valueRangeAtMost(u32, 0, 256))),
        3 => SizingAxis.percent(@as(f32, @floatFromInt(smith.valueRangeAtMost(u32, 0, 100))) / 100.0),
        else => unreachable,
    };
}

/// Deterministic mock text measurement — 10 px per byte, full font_size
/// height. Avoids pulling in CoreText so the fuzzer can run anywhere.
fn fuzzMeasureText(
    text: []const u8,
    _: u16,
    font_size: u16,
    _: ?f32,
    _: ?*anyopaque,
) engine_mod.TextMeasurement {
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * 10.0,
        .height = @floatFromInt(font_size),
    };
}

/// Replace non-UTF8 bytes in Smith's slice output with spaces. The text
/// wrapping pass uses `std.unicode.Utf8View.initUnchecked` and would
/// otherwise misinterpret continuation bytes.
fn sanitizeText(buf: []u8) []const u8 {
    std.debug.assert(buf.len <= MAX_FUZZ_TEXT_LEN);
    for (buf) |*b| {
        if (b.* >= 0x80) b.* = ' '; // ASCII-only keeps UTF-8 decoder happy
        if (b.* == 0) b.* = ' '; // No NUL bytes
    }
    return buf;
}

/// NaN or negative bounds would propagate straight into the GPU.
fn assertBoundsFinite(engine: *const LayoutEngine) !void {
    const elements = engine.elements.items();
    try std.testing.expect(elements.len > 0);
    for (elements) |element| {
        const b = element.computed.bounding_box;
        try std.testing.expect(std.math.isFinite(b.x));
        try std.testing.expect(std.math.isFinite(b.y));
        try std.testing.expect(std.math.isFinite(b.width));
        try std.testing.expect(std.math.isFinite(b.height));
        try std.testing.expect(b.width >= 0);
        try std.testing.expect(b.height >= 0);
    }
}

test "fuzz: layout tree" {
    try std.testing.fuzz({}, fuzzLayoutTree, .{});
}

test "fuzz: text wrapping" {
    try std.testing.fuzz({}, fuzzTextWrapping, .{});
}
