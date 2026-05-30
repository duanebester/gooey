//! Layout-engine fuzz targets.
//!
//! These targets generate random *valid* layout trees using
//! `std.testing.Smith` and run a full `endFrame()` over each one. The goal
//! is to catch crashes, assertion violations, and depth/capacity overruns
//! when the tree exercises corners the integration tests don't cover.
//!
//! What the fuzzer asserts after every successful frame:
//!   - The render command list is non-decreasing on `z_index` once sorted
//!     (engine invariant — floating subtrees override z, descendants
//!     inherit, and `sortByZIndex()` is the contract).
//!   - Every `(scissor_start, scissor_end)` pair is balanced in stack
//!     order. A leaked scissor would clip subsequent siblings; an extra
//!     end would underflow the renderer's clip stack.
//!   - Every emitted bounding box has finite, non-NaN coordinates and
//!     non-negative width/height. NaN would propagate into the GPU pipeline
//!     and produce undefined behaviour on the Metal/wgpu side.
//!
//! Run with `zig build fuzz` (single-shot, time-bounded smoke) or
//! `zig build fuzz -- --infinite` for the 0.16 infinite-mode runner.

const std = @import("std");
const gooey = @import("gooey");

// The fuzz module compiles standalone (separate root from `src/root.zig`)
// so it can't peer-import `engine.zig`; types must come through the public
// `gooey.layout.*` surface. This also pins us to the supported public API —
// if a name disappears the fuzzer is forced to stay in sync.
const layout = gooey.layout;
const engine_mod = layout.engine;
const types = layout.types;
const layout_id_mod = layout.layout_id;
const render_commands = layout.render_commands;

const LayoutEngine = engine_mod.LayoutEngine;
const Sizing = types.Sizing;
const SizingAxis = types.SizingAxis;
const Padding = types.Padding;
const LayoutId = layout_id_mod.LayoutId;
const RenderCommand = render_commands.RenderCommand;

// ============================================================================
// Capacity caps (CLAUDE.md §4)
// ============================================================================

/// Smith inputs are unbounded, but the engine has fixed capacities. Pick
/// limits well under those so we exercise the algorithm, not the panics.
const MAX_FUZZ_ELEMENTS: u32 = 256;
const MAX_FUZZ_DEPTH: u32 = 8;
const MAX_FUZZ_CHILDREN_PER_NODE: u32 = 8;
const MAX_FUZZ_TEXT_LEN: u32 = 64;

/// Viewport bounds — kept moderate so coordinate math stays in a regime
/// the renderer would actually see in production. Stored as integers
/// because `Smith.valueRangeAtMost` rejects `f32` (no continuous range
/// thanks to NaN/Inf); we cast at use site.
const FUZZ_VIEWPORT_MIN: u32 = 64;
const FUZZ_VIEWPORT_MAX: u32 = 4096;

// ============================================================================
// Entry points
// ============================================================================

/// Build a random layout tree and run the full pipeline. Asserts the
/// engine's documented post-conditions on the resulting command list.
pub fn fuzzLayoutTree(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = std.testing.allocator;

    var engine = LayoutEngine.init(gpa);
    defer engine.deinit();
    engine.setMeasureTextFn(fuzzMeasureText, null);

    const viewport_w: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    const viewport_h: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    engine.beginFrame(viewport_w, viewport_h);

    var state: TreeState = .{ .smith = smith, .arena = arena.allocator(), .elements_emitted = 0 };
    try emitContainer(&engine, &state, 0);

    // Drain any unclosed containers (defensive — emitContainer should
    // always pair open/close itself, but we don't want a malformed tree
    // to halt the fuzzer; the engine's `closeElement` assertion would
    // catch the bug long before we got here).
    while (engine.open_element_stack.len > 0) engine.closeElement();

    const commands = try engine.endFrame();
    try assertCommandListInvariants(commands);
}

/// Build a random tree of word + whitespace sequences for the text
/// wrapping pass. Skinny viewport widths force wrapping to engage.
pub fn fuzzTextWrapping(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;

    var engine = LayoutEngine.init(gpa);
    defer engine.deinit();
    engine.setMeasureTextFn(fuzzMeasureText, null);

    const viewport_w: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    engine.beginFrame(viewport_w, 1024);

    try engine.openElement(.{
        .id = LayoutId.init("root"),
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

    _ = try engine.endFrame();
}

// ============================================================================
// Tree builder
// ============================================================================

const TreeState = struct {
    smith: *std.testing.Smith,
    arena: std.mem.Allocator,
    elements_emitted: u32,
};

/// Emit a container with random sizing + 0..N children, recursing up to
/// `MAX_FUZZ_DEPTH`. Caps total element count via `TreeState` so a
/// pathological Smith input can't blow `MAX_ELEMENTS_PER_FRAME`.
fn emitContainer(engine: *LayoutEngine, state: *TreeState, depth: u32) anyerror!void {
    if (state.elements_emitted >= MAX_FUZZ_ELEMENTS) return;
    if (depth >= MAX_FUZZ_DEPTH) return;

    const sizing = randomSizing(state.smith);
    const layout_direction: types.LayoutDirection =
        if (state.smith.boolWeighted(1, 1)) .left_to_right else .top_to_bottom;
    const padding_amt: u16 = @intCast(state.smith.valueRangeAtMost(u16, 0, 16));
    const child_gap: u16 = @intCast(state.smith.valueRangeAtMost(u16, 0, 16));

    try engine.openElement(.{
        .id = .none,
        .layout = .{
            .sizing = sizing,
            .padding = Padding.all(padding_amt),
            .child_gap = child_gap,
            .layout_direction = layout_direction,
        },
    });
    state.elements_emitted += 1;

    const child_count = state.smith.valueRangeAtMost(u32, 0, MAX_FUZZ_CHILDREN_PER_NODE);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        // Stop spawning if we'd blow the per-frame cap; the engine's
        // assert in `createElement` would fire on overflow.
        if (state.elements_emitted >= MAX_FUZZ_ELEMENTS) break;
        try emitContainer(engine, state, depth + 1);
    }

    engine.closeElement();
}

/// Pick a random Sizing pair across all four sizing types. Returns
/// `Sizing` (both axes); fuzzed independently per axis.
fn randomSizing(smith: *std.testing.Smith) Sizing {
    return .{
        .width = randomSizingAxis(smith),
        .height = randomSizingAxis(smith),
    };
}

/// Pick a random single-axis sizing constraint. Bounded so the
/// generated tree fits in a sane coordinate space. Smith doesn't deal
/// with `f32` directly (no continuous range), so we draw a `u32` and
/// scale it into the target floating range.
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

// ============================================================================
// Helpers
// ============================================================================

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

/// Engine post-conditions enforced after every successful frame. Each
/// check is independently fatal — `try` is intentional so the fuzzer
/// surfaces the first violation, not a cascade.
fn assertCommandListInvariants(commands: []const RenderCommand) !void {
    try assertZIndexNonDecreasing(commands);
    try assertScissorBalanced(commands);
    try assertBoundsFinite(commands);
}

/// After `sortByZIndex()` the command list must be ordered by `z_index`
/// ascending. A regression here would mean `getZIndex` lies and the
/// renderer paints in the wrong order.
fn assertZIndexNonDecreasing(commands: []const RenderCommand) !void {
    if (commands.len <= 1) return;
    var i: usize = 1;
    while (i < commands.len) : (i += 1) {
        try std.testing.expect(commands[i - 1].z_index <= commands[i].z_index);
    }
}

/// Every `scissor_start` must have a matching `scissor_end`, and they
/// must nest properly. Track depth and assert non-negative throughout.
fn assertScissorBalanced(commands: []const RenderCommand) !void {
    var depth: i32 = 0;
    for (commands) |cmd| {
        switch (cmd.command_type) {
            .scissor_start => depth += 1,
            .scissor_end => {
                depth -= 1;
                try std.testing.expect(depth >= 0);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(i32, 0), depth);
}

/// No NaN, no infinity, no negative width/height in the emitted command
/// list. These would propagate straight into the GPU and produce UB.
fn assertBoundsFinite(commands: []const RenderCommand) !void {
    for (commands) |cmd| {
        const b = cmd.bounding_box;
        try std.testing.expect(std.math.isFinite(b.x));
        try std.testing.expect(std.math.isFinite(b.y));
        try std.testing.expect(std.math.isFinite(b.width));
        try std.testing.expect(std.math.isFinite(b.height));
        try std.testing.expect(b.width >= 0);
        try std.testing.expect(b.height >= 0);
    }
}

// ============================================================================
// Tests — `std.testing.fuzz` entry points
// ============================================================================

test "fuzz: layout tree" {
    try std.testing.fuzz({}, fuzzLayoutTree, .{});
}

test "fuzz: text wrapping" {
    try std.testing.fuzz({}, fuzzTextWrapping, .{});
}
