//! The debugger: a UI inspector and a profiler overlay on the core, toggled
//! with Cmd/Ctrl+Shift+I (contract decision 16). It ports 0.3.1's
//! `debug/debugger.zig` with the same modes, panels, and colours.
//!
//! - **Inspector:** outlines the element under the pointer and its ancestors;
//!   a press selects the element under it (the press still reaches the app),
//!   and the panel describes the selection, including the `Style.source`
//!   the element was built with.
//! - **Profiler:** FPS, the stage times of the last frame (build, layout,
//!   emit on the main thread; pack and draw on the render side), its quads,
//!   glyphs, and shaping, and a graph of the last 60 frames. While it is open
//!   every frame requests the next, so it stays live; closed, the app idles.
//!
//! The overlay is a final paint-only fragment: emit appends it after every
//! layer's paint, and it writes no hit records, so it never takes input.
//!
//! Compiled out of ReleaseFast and ReleaseSmall: `State` and `NodeSource`
//! are `void` there, every entry point returns at comptime, and the shortcut
//! reaches the app's keymap like any other key.
//!
//! Budget: the overlay never spends the app's budget. A safe build reserves
//! the overlay's worst case on top of the app's limits (`reservedLimits`),
//! and still holds the app to the limits it declared: past them, the frame
//! fails fast naming the pool exactly as a release build would.

const std = @import("std");
const builtin = @import("builtin");
const records = @import("records.zig");
const window_mod = @import("window.zig");
const emit_mod = @import("emit.zig");
const limits_mod = @import("limits.zig");
const input = @import("../input/mod.zig");
const render_stats = @import("render_stats.zig");
const layout_types = @import("../layout/types.zig");
const packed_mod = @import("packed_frame.zig");

const assert = std.debug.assert;

const Window = window_mod.Window;
const ElementId = records.ElementId;
const Rect = records.Rect;
const Color = records.Color;
const Painter = emit_mod.Painter;
const ResourceLimits = limits_mod.ResourceLimits;

/// The one switch for the whole debugger (contract decision 16).
pub const enabled = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// The overlay's headroom, reserved on top of the app's limits in safe
/// builds. The overlay writes only quads and glyph sprites, one paint record
/// each, so its records are its quads plus its glyphs.
pub const overlay_quad_count_max: u32 = 193;
pub const overlay_glyph_count_max: u32 = 300;
pub const overlay_paint_record_count_max: u32 = 493;

/// The limits a window reserves storage for: the app's, plus the overlay's
/// headroom when the debugger is compiled in. The window still holds the app
/// to `limits`; only the overlay paints into the headroom.
pub fn reservedLimits(limits: *const ResourceLimits) ResourceLimits {
    if (comptime !enabled) return limits.*;
    return withHeadroom(limits);
}

/// `limits` plus the overlay's headroom, in any build mode. `App` checks it
/// is valid in every mode, so a budget that builds in one mode builds in all.
pub fn withHeadroom(limits: *const ResourceLimits) ResourceLimits {
    var reserved = limits.*;
    reserved.paint.quad_count_frame_max += overlay_quad_count_max;
    reserved.paint.glyph_count_frame_max += overlay_glyph_count_max;
    reserved.records.paint_record_count_frame_max += overlay_paint_record_count_max;
    assert(reserved.paint.quad_count_frame_max > limits.paint.quad_count_frame_max);
    assert(reserved.paint.glyph_count_frame_max > limits.paint.glyph_count_frame_max);
    return reserved;
}

/// Where a frame's overlay starts, or `paint_mark_none` for a frame without
/// one: nothing in release builds.
pub const PaintMark = if (enabled) u32 else void;
pub const paint_mark_none: PaintMark = if (enabled) std.math.maxInt(u32) else {};

/// The paint records before the overlay: the app's. Every record of a frame
/// without an overlay, and of every frame in a release build.
pub fn appPaintCount(frame: *const records.Frame) u32 {
    assert(frame.paint_count <= frame.paint.len);
    if (comptime !enabled) return frame.paint_count;
    if (frame.overlay_start == paint_mark_none) return frame.paint_count;
    assert(frame.overlay_start <= frame.paint_count);
    return frame.overlay_start;
}

/// After pack has packed the app's records, before the overlay's: the app
/// stays within the paint limits it declared, which the packed frame's
/// reserved headroom would otherwise hide. The panic matches pack's own.
pub fn checkAppPacked(target: *const packed_mod.PackedFrame) void {
    if (comptime !enabled) return;
    assert(target.limits.quad_count_frame_max > overlay_quad_count_max);
    assert(target.limits.glyph_count_frame_max > overlay_glyph_count_max);
    const quads_declared = target.limits.quad_count_frame_max - overlay_quad_count_max;
    const glyphs_declared = target.limits.glyph_count_frame_max - overlay_glyph_count_max;
    const quads_used = target.counts[@backingInt(packed_mod.Pool.quads)];
    const glyphs_used = target.counts[@backingInt(packed_mod.Pool.glyphs)];
    if (quads_used > quads_declared) {
        const frame = target.frame_number;
        appExhausted("Packed pool 'quads'", "paint", quads_declared, quads_used, frame);
    }
    if (glyphs_used > glyphs_declared) {
        const frame = target.frame_number;
        appExhausted("Packed pool 'glyphs'", "paint", glyphs_declared, glyphs_used, frame);
    }
}

/// An app past a limit it declared, found once its frame is complete.
fn appExhausted(
    pool: []const u8,
    budget: []const u8,
    capacity: u32,
    used: u32,
    frame_number: u64,
) noreturn {
    @branchHint(.cold);
    assert(used > capacity);
    std.debug.panic("{s} exhausted: capacity {d} (ResourceLimits.{s}), {d} used, " ++
        "frame {d}. Raise the app's ResourceLimits.", .{
        pool,
        capacity,
        budget,
        used,
        frame_number,
    });
}

/// Where an element was built: `Style.source`, kept as a pointer and a line.
pub const Source = struct {
    file: [*:0]const u8,
    line: u32,

    pub fn basename(self: Source) []const u8 {
        return std.fs.path.basename(std.mem.span(self.file));
    }
};

/// What a node stores of `Style.source`: nothing in release builds.
pub const NodeSource = if (enabled) ?Source else void;
pub const node_source_none: NodeSource = if (enabled) null else {};

/// The window's debugger state: nothing in release builds.
pub const State = if (enabled) Debugger else void;

pub fn nodeSource(source: ?std.builtin.SourceLocation) NodeSource {
    if (comptime !enabled) return {};
    const location = source orelse return null;
    assert(location.line > 0);
    assert(location.file.len > 0);
    return .{ .file = location.file.ptr, .line = location.line };
}

pub const Mode = enum { disabled, inspector, profiler };

/// The selected element, as the last overlay saw it.
pub const ElementInfo = struct {
    kind: window_mod.NodeKind,
    id: ElementId,
    bounds: Rect,
    width: layout_types.SizingAxis,
    height: layout_types.SizingAxis,
    direction: layout_types.LayoutDirection,
    child_count: u32,
    source: ?Source,
};

pub const Debugger = struct {
    mode: Mode,
    /// `.root` when nothing is selected.
    selected: ElementId,
    /// The selection at the last overlay, or null when it did not render.
    info: ?ElementInfo,
    // Main-thread stage times of the last build.
    build_ns: u64,
    layout_ns: u64,
    emit_ns: u64,
    // Render-side stage times of the last presented frame. Only the render
    // side writes them, while the frame is in flight; the main thread reads
    // them once `frame_in_flight` is clear, ordered by its release and
    // acquire exactly as the frame's contents are.
    pack_ns: u64,
    draw_ns: u64,
    history_ns: [history_count]u64,
    history_next: u32,
    history_len: u32,
    fps_window_start_ns: u64,
    fps_frames: u32,
    fps: f32,
    quad_count: u32,
    glyph_count: u32,
    shape_misses: u32,
    shape_hits: u32,
    shape_ns: u64,

    pub const history_count: u32 = 60;

    pub const init: Debugger = .{
        .mode = .disabled,
        .selected = .root,
        .info = null,
        .build_ns = 0,
        .layout_ns = 0,
        .emit_ns = 0,
        .pack_ns = 0,
        .draw_ns = 0,
        .history_ns = @splat(0),
        .history_next = 0,
        .history_len = 0,
        .fps_window_start_ns = 0,
        .fps_frames = 0,
        .fps = 0,
        .quad_count = 0,
        .glyph_count = 0,
        .shape_misses = 0,
        .shape_hits = 0,
        .shape_ns = 0,
    };
};

pub fn initState(state: *State) void {
    if (comptime !enabled) return;
    state.* = .init;
    assert(state.mode == .disabled);
}

pub fn isToggle(key: *const input.KeyEvent) bool {
    if (comptime !enabled) return false;
    if (key.key != .i) return false;
    if (!key.modifiers.shift) return false;
    return key.modifiers.cmd or key.modifiers.ctrl;
}

/// Cmd/Ctrl+Shift+I cycles off → inspector → profiler → off. Returns
/// whether it consumed the key, before focus and keymap see it.
pub fn routeKey(window: *Window, event: *const input.InputEvent) bool {
    if (comptime !enabled) return false;
    if (event.* != .key_down) return false;
    if (!isToggle(&event.key_down)) return false;
    const state = &window.debugger;
    state.mode = switch (state.mode) {
        .disabled => .inspector,
        .inspector => .profiler,
        .profiler => .disabled,
    };
    if (state.mode == .disabled) {
        state.selected = .root;
        state.info = null;
    }
    window.render_requested = true;
    return true;
}

/// A press selects the element under it, or clears a repeated selection,
/// as 0.3.1's `handleClick`. The router still routes the press.
pub fn press(window: *Window, x: f32, y: f32) void {
    if (comptime !enabled) return;
    const state = &window.debugger;
    if (state.mode == .disabled) return;
    const index = nodeAt(window, x, y) orelse return;
    const id = window.nodes[index].id;
    state.selected = if (state.selected == id) .root else id;
    state.info = null;
    window.render_requested = true;
}

/// The hover outline follows the pointer.
pub fn pointerMoved(window: *Window) void {
    if (comptime !enabled) return;
    if (window.debugger.mode == .disabled) return;
    window.render_requested = true;
}

/// A monotonic stamp for stage timing; 0 in release builds.
pub fn stamp(window: *const Window) u64 {
    if (comptime !enabled) return 0;
    const ns = std.Io.Timestamp.now(window.resources.io, .awake).toNanoseconds();
    assert(ns >= 0);
    return @intCast(ns);
}

/// Shaping statistics count from the start of each build.
pub fn beginBuild() void {
    if (comptime !enabled) return;
    render_stats.beginFrame();
}

pub const BuildStamps = struct { build: u64, layout: u64, emit: u64 };

/// After emit: record the build's stage times and append the overlay.
pub fn finishBuild(window: *Window, stamps: BuildStamps) void {
    if (comptime !enabled) return;
    window.assertPhase(.emit);
    const state = &window.debugger;
    const now_ns = stamp(window);
    assert(stamps.build <= stamps.layout);
    assert(stamps.layout <= stamps.emit);
    state.build_ns = stamps.layout - stamps.build;
    state.layout_ns = stamps.emit - stamps.layout;
    state.emit_ns = now_ns -| stamps.emit;
    const frame = window.built();
    assert(frame.overlay_start == paint_mark_none);
    const app_paint_count = frame.paint_count;
    const declared = window.limits.records.paint_record_count_frame_max;
    if (app_paint_count > declared) {
        const pool = "record frame pool 'paint records'";
        appExhausted(pool, "records", declared, app_paint_count, window.frame_number);
    }
    if (state.mode == .disabled) return;
    frame.overlay_start = app_paint_count;
    recordFrame(window, state);
    paintOverlay(window, state);
    assert(frame.paint_count - app_paint_count <= overlay_paint_record_count_max);
    if (state.mode == .profiler) window.render_requested = true;
}

/// On the render side, after draw: the presented frame's pack and draw.
pub fn notePresent(window: *Window, pack_start_ns: u64, draw_start_ns: u64) void {
    if (comptime !enabled) return;
    assert(pack_start_ns <= draw_start_ns);
    const now_ns = stamp(window);
    window.debugger.pack_ns = draw_start_ns - pack_start_ns;
    window.debugger.draw_ns = now_ns -| draw_start_ns;
}

fn recordFrame(window: *Window, state: *Debugger) void {
    const frame_ns = state.build_ns + state.layout_ns + state.emit_ns +
        state.pack_ns + state.draw_ns;
    state.history_ns[state.history_next] = frame_ns;
    state.history_next = (state.history_next + 1) % Debugger.history_count;
    state.history_len = @min(state.history_len + 1, Debugger.history_count);
    const fps_window_ns: u64 = 500 * std.time.ns_per_ms;
    state.fps_frames += 1;
    if (state.fps_window_start_ns == 0 or window.now_ns < state.fps_window_start_ns) {
        state.fps_window_start_ns = window.now_ns;
        state.fps_frames = 0;
    } else {
        const elapsed_ns = window.now_ns - state.fps_window_start_ns;
        if (elapsed_ns >= fps_window_ns) {
            const seconds = @as(f32, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
            state.fps = @as(f32, @floatFromInt(state.fps_frames)) / seconds;
            state.fps_window_start_ns = window.now_ns;
            state.fps_frames = 0;
        }
    }
    const stats = &render_stats.frame_stats;
    state.shape_misses = stats.shape_misses;
    state.shape_hits = stats.shape_cache_hits;
    state.shape_ns = stats.shape_time_ns;
    countPaint(window.built(), state);
    assert(state.history_len <= Debugger.history_count);
}

/// The app's quads and glyph sprites, counted before the overlay is added.
fn countPaint(frame: *const records.Frame, state: *Debugger) void {
    assert(frame.paint_count <= frame.paint.len);
    var quads: u32 = 0;
    var glyphs: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |record| {
        switch (record) {
            .quad => quads += 1,
            .sprite => |sprite| switch (sprite.atlas) {
                .glyph, .glyph_color => glyphs += 1,
                .svg, .image => {},
            },
            .mesh, .clip_push, .clip_pop => {},
        }
    }
    state.quad_count = quads;
    state.glyph_count = glyphs;
}

// =============================================================================
// Selection
// =============================================================================

/// The element under a point in the last build: the latest in pre-order
/// whose bounds contain it, preferring elements inside more layers, since a
/// layer paints over the content it was opened from.
fn nodeAt(window: *const Window, x: f32, y: f32) ?u32 {
    if (window.node_count == 0) return null;
    const elements = window.layout.elements.items();
    assert(elements.len == window.node_count);
    var layer_level: [window_mod.box_depth_ceiling + 1]u8 = undefined;
    var best: ?u32 = null;
    var best_level: u8 = 0;
    for (window.nodes[0..window.node_count], 0..) |*node, index| {
        const depth = node.depth;
        assert(depth <= window.limits.build.box_depth_max);
        const parent_level: u8 = if (depth == 0) 0 else layer_level[depth - 1];
        const level = parent_level + @intFromBool(node.layer != null);
        layer_level[depth] = level;
        if (!boundsOf(elements[index]).contains(x, y)) continue;
        if (best != null and level < best_level) continue;
        best = @intCast(index);
        best_level = level;
    }
    return best;
}

fn boundsOf(element: anytype) Rect {
    const box = element.computed.bounding_box;
    assert(box.width >= 0);
    assert(box.height >= 0);
    return .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
}

fn findNode(window: *const Window, id: ElementId) ?u32 {
    if (id == .root) return null;
    for (window.nodes[0..window.node_count], 0..) |*node, index| {
        if (node.id == id) return @intCast(index);
    }
    return null;
}

fn elementInfo(window: *const Window, index: u32) ElementInfo {
    assert(index < window.node_count);
    const node = &window.nodes[index];
    const element = window.layout.elements.items()[index];
    const layout = element.config.layout;
    return .{
        .kind = node.kind,
        .id = node.id,
        .bounds = boundsOf(element),
        .width = layout.sizing.width,
        .height = layout.sizing.height,
        .direction = layout.layout_direction,
        .child_count = node.child_count,
        .source = node.source,
    };
}

// =============================================================================
// Overlay
// =============================================================================

/// Wide enough for a 64-bit id at the app's font size; 0.3.1's ids were
/// 32-bit and its panel 280 px.
const panel_width: f32 = 320;
const panel_padding: f32 = 12;
const panel_margin: f32 = 16;
const profiler_width: f32 = 320;
const profiler_height: f32 = 296;
const graph_height: f32 = 80;
const outline_width: f32 = 2;
/// Panel text size, whatever the app's font size: a 64-bit id fits the
/// value column at 14 px.
const text_size: u16 = 14;
/// 30 FPS fills the graph; the line marks 60 FPS.
const graph_frame_ms_max: f32 = 33.33;
const graph_target_ms: f32 = 16.67;

const color_hover = Color.hsla(0.55, 0.9, 0.5, 0.25);
const color_hover_border = Color.hsla(0.55, 1.0, 0.5, 0.8);
const color_selected = Color.hsla(0.0, 0.9, 0.5, 0.15);
const color_selected_border = Color.hsla(0.0, 1.0, 0.5, 1.0);
const color_ancestor = Color.hsla(0.3, 0.6, 0.5, 0.1);
const color_ancestor_border = Color.hsla(0.3, 0.8, 0.5, 0.4);
const panel_background = Color.hsla(0.0, 0.0, 0.12, 0.92);
const panel_border = Color.hsla(0.0, 0.0, 0.3, 0.8);
const text_primary = Color.hsla(0.0, 0.0, 0.95, 1.0);
const text_secondary = Color.hsla(0.0, 0.0, 0.6, 1.0);
const text_value = Color.hsla(0.55, 0.7, 0.7, 1.0);
const text_label = Color.hsla(0.3, 0.5, 0.6, 1.0);
const color_frame_time = Color.hsla(0.55, 0.8, 0.6, 0.9);
const color_build = Color.hsla(0.45, 0.7, 0.55, 0.9);
const color_layout = Color.hsla(0.3, 0.8, 0.5, 0.9);
const color_emit = Color.hsla(0.08, 0.8, 0.5, 0.9);
const color_pack = Color.hsla(0.75, 0.6, 0.55, 0.9);
const color_draw = Color.hsla(0.6, 0.8, 0.45, 0.9);
const color_target_line = Color.hsla(0.0, 0.0, 0.5, 0.5);
const color_graph = Color.hsla(0.0, 0.0, 0.05, 0.8);
const color_good = Color.hsla(0.3, 0.8, 0.6, 1.0);
const color_ok = Color.hsla(0.15, 0.8, 0.5, 1.0);
const color_bad = Color.hsla(0.0, 0.8, 0.5, 1.0);

fn paintOverlay(window: *Window, state: *Debugger) void {
    assert(state.mode != .disabled);
    if (window.resources.text_system.getMetrics() == null) return;
    var painter = Painter{
        .window = window,
        .bounds = .{ .x = 0, .y = 0, .width = window.width, .height = window.height },
        .clip_depth = 0,
    };
    const selected = findNode(window, state.selected);
    state.info = if (selected) |index| elementInfo(window, index) else null;
    const hovered = if (window.pointer) |point| nodeAt(window, point.x, point.y) else null;
    paintOutlines(window, &painter, hovered, selected);
    const text = Text{ .painter = &painter, .size = text_size };
    switch (state.mode) {
        .inspector => paintInspector(text, window.width, state.info),
        .profiler => paintProfiler(text, window.width, state),
        .disabled => unreachable,
    }
}

/// Ancestors of the hovered element faintly, the hovered element, then the
/// selection on top, as 0.3.1 drew them.
fn paintOutlines(window: *Window, painter: *Painter, hovered: ?u32, selected: ?u32) void {
    const elements = window.layout.elements.items();
    if (hovered) |hovered_index| {
        var index = window.nodes[hovered_index].parent;
        var steps: u32 = 0;
        while (index != records.index_none and index != 0) : (steps += 1) {
            // The root is at depth 0, so a node has fewer non-root
            // ancestors than the deepest depth (`outline_count_max`).
            assert(steps < window.limits.build.box_depth_max);
            if (index != selected) {
                outline(painter, boundsOf(elements[index]), color_ancestor, color_ancestor_border);
            }
            index = window.nodes[index].parent;
        }
        if (hovered_index != selected) {
            outline(painter, boundsOf(elements[hovered_index]), color_hover, color_hover_border);
        }
    }
    if (selected) |index| {
        outline(painter, boundsOf(elements[index]), color_selected, color_selected_border);
    }
}

fn outline(painter: *Painter, bounds: Rect, fill: Color, border: Color) void {
    painter.quad(.{
        .bounds = bounds,
        .fill = fill,
        .border = .{ .width = outline_width, .color = border },
        .corners = .zero,
        .blur = 0,
    });
}

fn panel(painter: *Painter, bounds: Rect) void {
    painter.quad(.{
        .bounds = bounds,
        .fill = panel_background,
        .border = .{ .width = 1, .color = panel_border },
        .corners = .all(8),
        .blur = 0,
    });
}

/// Panel text, one line per call.
const Text = struct {
    painter: *Painter,
    size: u16,

    fn line(self: Text, content: []const u8, x: f32, y: f32, color: Color) void {
        if (content.len == 0) return;
        _ = self.painter.text(content, x, y, .{ .size = self.size, .color = color });
    }
};

/// Formatted inspector values, each in a buffer sized for its widest form.
const InspectorText = struct {
    id: [18]u8,
    /// Four values clamped to ±1e9, whole pixels: 4 × 11 bytes and separators.
    bounds: [48]u8,
    /// "percent (" with two clamped values: at most 32 bytes.
    width: [40]u8,
    height: [40]u8,
    children: [10]u8,
    /// The basename, cut to leave room for ':' and a u32.
    source: [64]u8,
};

fn paintInspector(text: Text, window_width: f32, info: ?ElementInfo) void {
    const row_height: f32 = 24;
    const x = window_width - panel_width - panel_margin;
    const y = panel_margin;
    const rows: f32 = 9;
    panel(text.painter, .{
        .x = x,
        .y = y,
        .width = panel_width,
        .height = panel_padding * 2 + row_height * rows,
    });
    const left = x + panel_padding;
    const top = y + panel_padding;
    text.line(inspector_title, left, top, text_primary);
    const selection = info orelse {
        text.line("No element selected", left, top + row_height, text_secondary);
        text.line("Click to inspect", left, top + row_height * 2, text_secondary);
        return;
    };
    var scratch: InspectorText = undefined;
    const value_x = left + 96;
    for (inspectorRows(&selection, &scratch), 1..) |row, index| {
        const row_y = top + row_height * @as(f32, @floatFromInt(index));
        text.line(row.label, left, row_y, text_secondary);
        text.line(row.value, value_x, row_y, row.color);
    }
}

const Row = struct { label: []const u8, value: []const u8, color: Color };

/// The eight rows under the title, as 0.3.1's inspector listed them.
fn inspectorRows(info: *const ElementInfo, scratch: *InspectorText) [8]Row {
    const id: u64 = @backingInt(info.id);
    const id_text = std.fmt.bufPrint(&scratch.id, "0x{X:0>16}", .{id}) catch
        unreachable; // Exactly 18 bytes.
    const children = std.fmt.bufPrint(&scratch.children, "{d}", .{info.child_count}) catch
        unreachable; // A u32 has at most 10 digits.
    const source = sourceText(&scratch.source, info.source);
    const labels = inspector_labels;
    return .{
        valueRow(labels[0], kindName(info.kind)),
        valueRow(labels[1], id_text),
        valueRow(labels[2], boundsText(&scratch.bounds, info.bounds)),
        valueRow(labels[3], sizingText(&scratch.width, info.width)),
        valueRow(labels[4], sizingText(&scratch.height, info.height)),
        valueRow(labels[5], directionName(info.direction)),
        valueRow(labels[6], children),
        .{ .label = labels[7], .value = source, .color = text_label },
    };
}

const inspector_title = "Inspector";
const inspector_labels = [8][]const u8{
    "Type:", "ID:", "Pos:", "Width:", "Height:", "Dir:", "Children:", "Source:",
};

fn valueRow(label: []const u8, value: []const u8) Row {
    assert(label.len > 0);
    return .{ .label = label, .value = value, .color = text_value };
}

fn kindName(kind: window_mod.NodeKind) []const u8 {
    return switch (kind) {
        .box => "Container",
        .text => "Text",
        .paint => "Paint",
    };
}

fn directionName(direction: layout_types.LayoutDirection) []const u8 {
    return switch (direction) {
        .left_to_right => "Row",
        .top_to_bottom => "Column",
    };
}

/// Values past ±1e9 are clamped so each formats in at most 11 bytes.
const value_limit: f32 = 1e9;

fn boundsText(buffer: *[48]u8, bounds: Rect) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:.0},{d:.0} {d:.0}x{d:.0}", .{
        std.math.clamp(bounds.x, -value_limit, value_limit),
        std.math.clamp(bounds.y, -value_limit, value_limit),
        @min(bounds.width, value_limit),
        @min(bounds.height, value_limit),
    }) catch unreachable; // 4 × 11 bytes and 3 separators.
}

fn sizingText(buffer: *[40]u8, axis: layout_types.SizingAxis) []const u8 {
    const kind = switch (std.meta.activeTag(axis.value)) {
        .fit => "fit",
        .grow => "grow",
        .fixed => "fixed",
        .percent => "percent",
    };
    const min = @min(axis.getMin(), value_limit);
    const max = axis.getMax();
    const shown_max = @min(max, value_limit);
    const has_min = min > 0;
    const has_max = max < std.math.floatMax(f32);
    // At most "percent (" + 10 + "-" + 10 + ")": 31 bytes.
    if (has_min and has_max) {
        return std.fmt.bufPrint(buffer, "{s} ({d:.0}-{d:.0})", .{ kind, min, shown_max }) catch
            unreachable;
    }
    if (has_min) {
        return std.fmt.bufPrint(buffer, "{s} (>={d:.0})", .{ kind, min }) catch unreachable;
    }
    if (has_max) {
        return std.fmt.bufPrint(buffer, "{s} (<={d:.0})", .{ kind, shown_max }) catch
            unreachable;
    }
    return kind;
}

fn sourceText(buffer: *[64]u8, source: ?Source) []const u8 {
    const value = source orelse return "(not tracked)";
    const name = value.basename();
    const name_len = @min(name.len, buffer.len - 11);
    return std.fmt.bufPrint(buffer, "{s}:{d}", .{ name[0..name_len], value.line }) catch
        unreachable; // The name leaves 11 bytes for ':' and a u32.
}

// =============================================================================
// Profiler
// =============================================================================

/// One number formatted as milliseconds with one decimal: a frame time
/// clamped to 1e6 ms is at most 9 bytes.
fn msText(buffer: *[16]u8, ns: u64) []const u8 {
    const ms = @min(@as(f32, @floatFromInt(ns)) / std.time.ns_per_ms, 1e6);
    return std.fmt.bufPrint(buffer, "{d:.1}", .{ms}) catch unreachable;
}

fn countText(buffer: *[16]u8, count: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{count}) catch unreachable; // 10 digits.
}

fn fpsColor(fps: f32) Color {
    if (fps >= 55) return color_good;
    if (fps >= 30) return color_ok;
    return color_bad;
}

fn shapeColor(ms: f32) Color {
    if (ms > 5) return color_bad;
    if (ms > 2) return color_ok;
    return text_value;
}

fn rateColor(ms: f32) Color {
    if (ms <= graph_target_ms) return color_good;
    if (ms <= graph_frame_ms_max) return color_ok;
    return color_bad;
}

fn paintProfiler(text: Text, window_width: f32, state: *const Debugger) void {
    const row_height: f32 = 20;
    const x = window_width - profiler_width - panel_margin;
    const y = panel_margin;
    panel(text.painter, .{ .x = x, .y = y, .width = profiler_width, .height = profiler_height });
    const left = x + panel_padding;
    const top = y + panel_padding;
    var buffer: [16]u8 = undefined;
    const fps = std.fmt.bufPrint(&buffer, "{d:.1}", .{@min(state.fps, 1e6)}) catch
        unreachable; // At most 9 bytes.
    text.line(fps, left, top, fpsColor(state.fps));
    text.line(" FPS", left + 50, top, text_secondary);
    const frame_ns = state.build_ns + state.layout_ns + state.emit_ns + state.pack_ns +
        state.draw_ns;
    const labels = profiler_stage_labels;
    const stages = [_]struct { label: []const u8, ns: u64, color: Color }{
        .{ .label = labels[0], .ns = frame_ns, .color = color_frame_time },
        .{ .label = labels[1], .ns = state.build_ns, .color = color_build },
        .{ .label = labels[2], .ns = state.layout_ns, .color = color_layout },
        .{ .label = labels[3], .ns = state.emit_ns, .color = color_emit },
        .{ .label = labels[4], .ns = state.pack_ns, .color = color_pack },
        .{ .label = labels[5], .ns = state.draw_ns, .color = color_draw },
    };
    for (stages, 1..) |stage, index| {
        const row_y = top + row_height * @as(f32, @floatFromInt(index));
        text.line(stage.label, left, row_y, text_secondary);
        text.line(msText(&buffer, stage.ns), left + 76, row_y, stage.color);
        text.line("ms", left + 126, row_y, text_secondary);
    }
    const counts_y = top + row_height * (stages.len + 1);
    paintCounts(text, left, counts_y, state);
    paintShaping(text, left, counts_y + row_height, state);
    paintGraph(text.painter, left, counts_y + row_height * 2.5, state);
}

fn paintCounts(text: Text, left: f32, y: f32, state: *const Debugger) void {
    var buffer: [16]u8 = undefined;
    text.line("Quads:", left, y, text_secondary);
    text.line(countText(&buffer, state.quad_count), left + 70, y, text_value);
    text.line("Glyphs:", left + 130, y, text_secondary);
    text.line(countText(&buffer, state.glyph_count), left + 206, y, text_value);
}

/// Shape misses, cache hits, and shaping time, which dominate text cost.
fn paintShaping(text: Text, left: f32, y: f32, state: *const Debugger) void {
    var buffer: [16]u8 = undefined;
    const shape_ms = @as(f32, @floatFromInt(state.shape_ns)) / std.time.ns_per_ms;
    const shape_color = shapeColor(shape_ms);
    const hit_color = if (state.shape_hits > 0) color_good else text_value;
    text.line("Shape:", left, y, text_secondary);
    text.line(countText(&buffer, state.shape_misses), left + 70, y, shape_color);
    text.line("/", left + 100, y, text_secondary);
    text.line(countText(&buffer, state.shape_hits), left + 112, y, hit_color);
    text.line("hit", left + 147, y, text_secondary);
    text.line(msText(&buffer, state.shape_ns), left + 180, y, shape_color);
    text.line("ms", left + 230, y, text_secondary);
}

/// The last 60 frame times, oldest on the left, against the 60 FPS line.
fn paintGraph(painter: *Painter, left: f32, top: f32, state: *const Debugger) void {
    const width = profiler_width - panel_padding * 2;
    painter.fill(.{ .x = left, .y = top, .width = width, .height = graph_height }, color_graph);
    const target_y = top + graph_height - graph_target_ms / graph_frame_ms_max * graph_height;
    painter.fill(.{ .x = left, .y = target_y, .width = width, .height = 1 }, color_target_line);
    const count = Debugger.history_count;
    assert(state.history_len <= count);
    const spacing = width / @as(f32, @floatFromInt(count));
    var bar: u32 = 0;
    while (bar < state.history_len) : (bar += 1) {
        const index = (state.history_next + count - state.history_len + bar) % count;
        const ms = @as(f32, @floatFromInt(state.history_ns[index])) / std.time.ns_per_ms;
        const height = @min(ms / graph_frame_ms_max * graph_height, graph_height);
        painter.fill(.{
            .x = left + @as(f32, @floatFromInt(bar)) * spacing,
            .y = top + graph_height - height,
            .width = @max(spacing - 1, 2),
            .height = height,
        }, rateColor(ms));
    }
}

const profiler_stage_labels = [6][]const u8{
    "Frame:", "Build:", "Layout:", "Emit:", "Pack:", "Draw:",
};

// =============================================================================
// Overlay worst case
// =============================================================================

/// Outlines: the hovered element's non-root ancestors, it, and the selection.
const outline_count_max: u32 = window_mod.box_depth_ceiling + 2;
/// The panel, the graph's background and target line, and one bar per frame.
const profiler_quad_count_max: u32 = 3 + Debugger.history_count;
const inspector_quad_count_max: u32 = 1;

/// A line places at most one glyph sprite per byte (the text is ASCII but
/// for a file name, whose multi-byte characters place fewer glyphs).
fn byteCount(lines: []const []const u8) u32 {
    var count: u32 = 0;
    for (lines) |line| count += @intCast(line.len);
    return count;
}

/// The title, the labels, and each value at its buffer's size or its longest
/// name. Wider than the "No element selected" panel.
fn inspectorGlyphCountMax() u32 {
    var kind_len_max: u32 = 0;
    for (std.enums.values(window_mod.NodeKind)) |kind| {
        kind_len_max = @max(kind_len_max, @as(u32, @intCast(kindName(kind).len)));
    }
    var direction_len_max: u32 = 0;
    for (std.enums.values(layout_types.LayoutDirection)) |direction| {
        const len: u32 = @intCast(directionName(direction).len);
        direction_len_max = @max(direction_len_max, len);
    }
    comptime assert(std.meta.hasUniqueRepresentation(InspectorText)); // All bytes, no padding.
    return inspector_title.len + byteCount(&inspector_labels) + @sizeOf(InspectorText) +
        kind_len_max + direction_len_max;
}

/// The FPS line, six stage lines, the counts, and the shaping line, with every
/// number at its widest: 9 bytes for a clamped float, 10 for a u32.
fn profilerGlyphCountMax() u32 {
    const float_len_max = 9;
    const count_len_max = 10;
    const fps_line = float_len_max + " FPS".len;
    const stage_lines = byteCount(&profiler_stage_labels) +
        profiler_stage_labels.len * (float_len_max + "ms".len);
    const counts_line = "Quads:".len + "Glyphs:".len + 2 * count_len_max;
    const shaping_line = "Shape:".len + "/".len + "hit".len + "ms".len +
        2 * count_len_max + float_len_max;
    return fps_line + stage_lines + counts_line + shaping_line;
}

comptime {
    const quad_count = outline_count_max + @max(profiler_quad_count_max, inspector_quad_count_max);
    const glyph_count = @max(inspectorGlyphCountMax(), profilerGlyphCountMax());
    assert(quad_count <= overlay_quad_count_max);
    assert(glyph_count <= overlay_glyph_count_max);
    assert(quad_count + glyph_count <= overlay_paint_record_count_max);
    assert(overlay_quad_count_max + overlay_glyph_count_max <= overlay_paint_record_count_max);
}
