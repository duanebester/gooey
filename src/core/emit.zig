//! Emit: turn the laid-out nodes into paint, hit, and accessibility records
//! (contract §8, §6).
//!
//! One pass over the nodes in pre-order, which is draw order. A box writes
//! its shadow, then one quad with its fill and border; text writes one glyph
//! sprite per visible glyph, placed exactly as the 0.3.1 runtime places them
//! (`text/render.zig`); a paint element runs its paint function with a
//! `Painter`. Interactive and keyed boxes write hit records whose `parent`
//! is the nearest ancestor hit record, so the router bubbles without the
//! tree. A `Style.clip` or scroll box wraps its subtree in a clip pair and
//! bounds its hits by the clip; a scroll box then measures its content and
//! draws its scrollbar, adding two quads.
//!
//! Work per tick: one visit per node plus one per glyph, each appending a
//! fixed-size record; at `.standard` that is at most ~28,000 records.

const std = @import("std");
const records = @import("records.zig");
const element = @import("element.zig");
const window_mod = @import("window.zig");
const layers = @import("layers.zig");
const limits_mod = @import("limits.zig");
const retained_mod = @import("retained.zig");
const text_mod = @import("../text/mod.zig");
const text_render = @import("../text/render.zig");
const scene_mod = @import("../scene/mod.zig");
const a11y_types = @import("../accessibility/types.zig");
const layout_mod = @import("../layout/layout.zig");

const assert = std.debug.assert;

const Window = window_mod.Window;
const Node = window_mod.Node;
const Rect = records.Rect;
const Color = records.Color;
const index_none = records.index_none;
const TextData = layout_mod.engine.TextData;
const TextAlignment = layout_mod.TextConfig.TextAlignment;

/// Drawing access for `ui.paint` functions, valid during emit only.
pub const Painter = struct {
    window: *Window,
    /// The paint element's laid-out bounds.
    bounds: Rect,
    clip_depth: u32,

    pub fn theme(self: *const Painter) *const element.Theme {
        return self.window.theme;
    }

    pub fn quad(self: *Painter, value: records.Quad) void {
        assert(value.bounds.width >= 0);
        assert(value.bounds.height >= 0);
        self.window.built().appendPaint(.{ .quad = value });
    }

    pub fn fill(self: *Painter, bounds: Rect, color: Color) void {
        self.quad(
            .{ .bounds = bounds, .fill = color, .border = .none, .corners = .zero, .blur = 0 },
        );
    }

    pub fn pushClip(self: *Painter, bounds: Rect) void {
        assert(self.clip_depth < clip_depth_max);
        checkClipDepth(self.window, self.clip_depth);
        self.clip_depth += 1;
        self.window.built().appendPaint(.{ .clip_push = bounds });
    }

    pub fn popClip(self: *Painter) void {
        assert(self.clip_depth > 0);
        self.clip_depth -= 1;
        self.window.built().appendPaint(.clip_pop);
    }

    /// Draw one line of text with its top at `y`; returns its width.
    pub fn text(self: *Painter, content: []const u8, x: f32, y: f32, style: TextStyle) f32 {
        return emitTextLine(self.window, content, x, y, style);
    }

    /// Draw one line of text on `baseline`; returns its width.
    pub fn textOnBaseline(
        self: *Painter,
        content: []const u8,
        x: f32,
        baseline: f32,
        style: TextStyle,
    ) f32 {
        return emitTextBaseline(self.window, content, x, baseline, style);
    }

    pub fn measureText(self: *const Painter, content: []const u8, style: TextStyle) f32 {
        if (content.len == 0) return 0;
        const text_system = self.window.resources.text_system;
        const metrics = text_system.getMetricsFor(style.family);
        const width = text_system.measureText(style.family, content, style.variant) catch |err| {
            std.debug.panic("text measurement failed: {s}", .{@errorName(err)});
        };
        return width * @as(f32, @floatFromInt(style.size)) / metrics.point_size;
    }

    pub fn fontMetrics(self: *const Painter) text_mod.Metrics {
        return self.window.resources.text_system.getMetrics().?;
    }

    /// Draw an SVG path from the SVG atlas.
    pub fn svg(self: *Painter, path: []const u8, bounds: Rect, options: SvgStyle) void {
        emitSvg(self.window, path, bounds, options);
    }

    /// Answer the platform's IME questions for this frame (`Query`).
    pub fn imeCursor(self: *Painter, ime: records.Ime) void {
        assert(ime.owner.isKeyed());
        assert(ime.selected_start <= ime.selected_end);
        self.window.built().ime = ime;
    }
};

pub const TextStyle = struct {
    size: u16,
    color: Color,
    family: text_mod.FontFamily = .app,
    variant: text_mod.FontVariant = .regular,
};

pub const SvgStyle = struct {
    fill: ?Color,
    stroke: ?Color = null,
    stroke_width: f32 = 1,
    viewbox: f32 = 24,
};

/// The scene's clip stack ceiling; `limits.scene.clip_depth_max` bounds box
/// clips and paint-function clips together below it.
const clip_depth_max: u32 = limits_mod.MAX_CLIP_STACK_DEPTH;

pub fn emit(window: *Window) void {
    window.assertPhase(.emit);
    window.resources.svg_atlas.resetFrameBudget();
    const elements = window.layout.elements.items();
    assert(elements.len == window.node_count);
    var hit_scope: [window_mod.box_depth_max + 1]u32 = undefined;
    var a11y_level: [window_mod.box_depth_max + 1]u8 = undefined;
    var clips = Clips{ .entries = undefined, .len = 0 };
    for (window.nodes[0..window.node_count], 0..) |*node, index| {
        const box = elements[index].computed.bounding_box;
        const bounds = Rect{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        const depth = node.depth;
        assert(depth <= window_mod.box_depth_max);
        clips.close(window, depth);
        clips.extend(depth, bounds);
        const parent_hit = if (depth == 0) index_none else hit_scope[depth - 1];
        const parent_level: u8 = if (depth == 0) 0 else a11y_level[depth - 1];
        switch (node.kind) {
            .box, .paint => {
                emitAppearance(window, node, bounds);
                const hit_bounds = clips.clipped(bounds);
                hit_scope[depth] = emitHit(window, node, hit_bounds, parent_hit);
                a11y_level[depth] = parent_level + emitA11y(window, node, bounds, parent_level);
                if (node.kind == .paint) emitPaint(window, node, bounds, clips.len);
                if (node.clip) clips.open(window, node, @intCast(index), bounds);
            },
            .text => emitText(window, node, bounds, &elements[index].text_data.?),
        }
    }
    clips.close(window, 0);
    assert(clips.len == 0);
}

/// The open `Style.clip` and scroll boxes, innermost last. A box's clip
/// closes at the first later node no deeper than it, which in pre-order is
/// where its subtree ends. A scroll box also gathers its children's extent,
/// so the emit that draws it measures the content the router clamps to.
const Clips = struct {
    entries: [clip_depth_max]Entry,
    len: u32,

    const Entry = struct {
        depth: u8,
        node_index: u32,
        bounds: Rect,
        /// The intersected clip rect, which bounds the subtree's hits.
        rect: Rect,
        /// The children's right and bottom edges, as laid out (offset applied).
        extent_right: f32,
        extent_bottom: f32,
    };

    fn clipped(self: *const Clips, bounds: Rect) Rect {
        assert(self.len <= clip_depth_max);
        assert(bounds.width >= 0);
        if (self.len == 0) return bounds;
        return bounds.intersect(self.entries[self.len - 1].rect);
    }

    fn open(self: *Clips, window: *Window, node: *const Node, index: u32, bounds: Rect) void {
        assert(node.clip);
        assert(self.len <= clip_depth_max);
        checkClipDepth(window, self.len);
        var rect = bounds;
        if (node.scroll) |handle| {
            // Keep the scrollbar outside the clip, using the overflow the last
            // emit measured; `finishScroll` re-renders when it changes.
            const state = window.retained.get(window_mod.ScrollState, handle);
            if (state.maxY() > 0) rect.width = @max(0, rect.width - scrollbar_room);
            if (state.maxX() > 0) rect.height = @max(0, rect.height - scrollbar_room);
        }
        rect = self.clipped(rect);
        window.built().appendPaint(.{ .clip_push = rect });
        self.entries[self.len] = .{
            .depth = node.depth,
            .node_index = index,
            .bounds = bounds,
            .rect = rect,
            .extent_right = bounds.x,
            .extent_bottom = bounds.y,
        };
        self.len += 1;
    }

    /// Close every clip whose subtree ended before a node at `depth`.
    fn close(self: *Clips, window: *Window, depth: u8) void {
        assert(self.len <= clip_depth_max);
        while (self.len > 0) {
            const entry = &self.entries[self.len - 1];
            if (entry.depth < depth) break;
            window.built().appendPaint(.clip_pop);
            if (window.nodes[entry.node_index].scroll) |handle| finishScroll(window, entry, handle);
            self.len -= 1;
        }
        if (self.len > 0) assert(self.entries[self.len - 1].depth < depth);
    }

    /// Grow the enclosing scroll box's extent by a direct child's bounds.
    fn extend(self: *Clips, depth: u8, bounds: Rect) void {
        if (self.len == 0) return;
        const entry = &self.entries[self.len - 1];
        assert(entry.depth < depth);
        if (entry.depth + 1 != depth) return;
        entry.extent_right = @max(entry.extent_right, bounds.x + bounds.width);
        entry.extent_bottom = @max(entry.extent_bottom, bounds.y + bounds.height);
    }
};

fn checkClipDepth(window: *const Window, depth: u32) void {
    const depth_max = window.limits.scene.clip_depth_max;
    assert(depth_max <= clip_depth_max);
    if (depth < depth_max) return;
    std.debug.panic("clip depth {d}: capacity {d} (frame {d}). Raise " ++
        "ResourceLimits.scene.clip_depth_max.", .{ depth + 1, depth_max, window.frame_number });
}

// 0.3.1's scroll container scrollbar (`widgets/scroll_container.zig`).
const scrollbar_size: f32 = 8;
const scrollbar_padding: f32 = 2;
const scrollbar_room: f32 = scrollbar_size + scrollbar_padding;
const scrollbar_thumb_min: f32 = 30;
const scrollbar_radius: f32 = 4;
const scrollbar_track_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.05 };
const scrollbar_thumb_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.3 };

/// Record what this emit measured, clamp the offset to it, and draw the
/// scrollbars after the clipped content, as 0.3.1 does at `scissor_end`.
/// A clamp or an overflow change makes this frame's layout or clip stale,
/// so it requests one more render; steady content requests none.
fn finishScroll(
    window: *Window,
    entry: *const Clips.Entry,
    handle: retained_mod.Handle(window_mod.ScrollState),
) void {
    const state = window.retained.get(window_mod.ScrollState, handle);
    const padding = window.layout.elements.items()[entry.node_index].config.layout.padding;
    const bounds = entry.bounds;
    const overflow_x = state.maxX() > 0;
    const overflow_y = state.maxY() > 0;
    state.content_width = @max(0, entry.extent_right + state.offset_x - bounds.x +
        @as(f32, @floatFromInt(padding.right)));
    state.content_height = @max(0, entry.extent_bottom + state.offset_y - bounds.y +
        @as(f32, @floatFromInt(padding.bottom)));
    state.viewport_width = bounds.width;
    state.viewport_height = bounds.height;
    const moved = state.clamp();
    if (moved or overflow_x != (state.maxX() > 0) or overflow_y != (state.maxY() > 0)) {
        window.render_requested = true;
    }
    emitScrollbars(window, bounds, state);
}

fn emitScrollbars(window: *Window, bounds: Rect, state: *const window_mod.ScrollState) void {
    assert(state.offset_y <= state.maxY());
    assert(state.offset_x <= state.maxX());
    if (state.maxY() > 0) {
        const track = Rect{
            .x = bounds.x + bounds.width - scrollbar_room,
            .y = bounds.y + scrollbar_padding,
            .width = scrollbar_size,
            .height = @max(0, bounds.height - scrollbar_padding * 2),
        };
        const thumb = scrollbarThumb(track.height, bounds.height, state.content_height, .{
            .offset = state.offset_y,
            .offset_max = state.maxY(),
        });
        var thumb_rect = track;
        thumb_rect.y += thumb.start;
        thumb_rect.height = thumb.length;
        emitScrollbar(window, track, thumb_rect);
    }
    if (state.maxX() > 0) {
        const track = Rect{
            .x = bounds.x + scrollbar_padding,
            .y = bounds.y + bounds.height - scrollbar_room,
            .width = @max(0, bounds.width - scrollbar_padding * 2),
            .height = scrollbar_size,
        };
        const thumb = scrollbarThumb(track.width, bounds.width, state.content_width, .{
            .offset = state.offset_x,
            .offset_max = state.maxX(),
        });
        var thumb_rect = track;
        thumb_rect.x += thumb.start;
        thumb_rect.width = thumb.length;
        emitScrollbar(window, track, thumb_rect);
    }
}

const Thumb = struct { start: f32, length: f32 };

/// The thumb along a track: proportional to the visible share of the
/// content, at least `scrollbar_thumb_min`, placed by the scroll fraction.
fn scrollbarThumb(
    track_length: f32,
    viewport_length: f32,
    content_length: f32,
    position: struct { offset: f32, offset_max: f32 },
) Thumb {
    assert(content_length > viewport_length);
    assert(position.offset_max > 0);
    const proportional = track_length * viewport_length / content_length;
    const length = @min(track_length, @max(scrollbar_thumb_min, proportional));
    const fraction = position.offset / position.offset_max;
    assert(fraction >= 0);
    assert(fraction <= 1);
    return .{ .start = (track_length - length) * fraction, .length = length };
}

fn emitScrollbar(window: *Window, track: Rect, thumb: Rect) void {
    assert(thumb.width <= track.width);
    assert(thumb.height <= track.height);
    const corners = records.Corners.all(scrollbar_radius);
    const frame = window.built();
    frame.appendPaint(.{ .quad = .{
        .bounds = track,
        .fill = scrollbar_track_color,
        .border = .none,
        .corners = corners,
        .blur = 0,
    } });
    frame.appendPaint(.{ .quad = .{
        .bounds = thumb,
        .fill = scrollbar_thumb_color,
        .border = .none,
        .corners = corners,
        .blur = 0,
    } });
}

fn emitAppearance(window: *Window, node: *const Node, bounds: Rect) void {
    const frame = window.built();
    if (node.shadow) |shadow| {
        if (shadow.blur > 0) frame.appendPaint(.{ .quad = .{
            .bounds = bounds,
            .fill = node.shadow_color,
            .border = .none,
            .corners = node.corners,
            .blur = shadow.blur,
            .offset_x = shadow.offset_x,
            .offset_y = shadow.offset_y,
        } });
    }
    if (node.background == null and node.border.width == 0) return;
    frame.appendPaint(.{ .quad = .{
        .bounds = bounds,
        .fill = node.background orelse Color.transparent,
        .border = node.border,
        .corners = node.corners,
        .blur = 0,
    } });
}

fn emitHit(window: *Window, node: *const Node, bounds: Rect, parent_hit: u32) u32 {
    if (!node.hit) return parent_hit;
    assert(node.id.isKeyed() or node.on_click != index_none or node.focusable or
        node.on_key != index_none or node.on_click_outside != index_none or
        node.key_context != 0 or node.actions_len > 0 or node.scroll != null);
    return window.built().appendHit(.{
        .id = node.id,
        .bounds = bounds,
        .fragment = layers.content_fragment,
        .parent = parent_hit,
        .focusable = node.focusable,
        .scroll = node.scroll != null,
        .on_click = node.on_click,
        .on_click_outside = node.on_click_outside,
        .on_key = node.on_key,
        .key_context = node.key_context,
        .actions_start = node.actions_start,
        .actions_len = node.actions_len,
    });
}

/// Returns 1 when the node adds an accessibility level.
fn emitA11y(window: *Window, node: *const Node, bounds: Rect, level: u8) u8 {
    const a11y = node.a11y orelse return 0;
    const focused = window.isFocused(node.id);
    window.built().appendA11y(.{
        .id = node.id,
        .role = a11y.role,
        .bounds = bounds,
        .depth = level,
        .name = a11y.label,
        .value = a11y.value,
        .href = a11y.href,
        .state = .{ .focused = focused, .checked = a11y.checked, .disabled = a11y.disabled },
        .heading_level = a11y.heading_level,
        .live = a11y.live,
    });
    return 1;
}

/// `box_clip_depth` is the box clips already open around the element, which
/// share the scene's clip stack with the paint function's own.
fn emitPaint(window: *Window, node: *const Node, bounds: Rect, box_clip_depth: u32) void {
    const paint_fn = node.paint_fn.?;
    assert(box_clip_depth < clip_depth_max);
    var painter = Painter{ .window = window, .bounds = bounds, .clip_depth = box_clip_depth };
    paint_fn(node.paint_data.?, @ptrCast(&painter));
    if (painter.clip_depth != box_clip_depth) {
        std.debug.panic("a paint function returned with {d} clips pushed", .{
            painter.clip_depth - box_clip_depth,
        });
    }
}

/// One glyph run per wrapped line (contract decision 9), pitched by the layout's
/// line height and aligned within the parent's content width, as 0.3.1's
/// `emitTextCommands` places them.
fn emitText(window: *Window, node: *const Node, bounds: Rect, data: *const TextData) void {
    const content = window.built().text(node.text) orelse return;
    assert(content.len == data.text.len);
    const style: TextStyle = .{
        .size = node.font_size,
        .color = node.text_color,
        .family = node.family,
        .variant = node.variant,
    };
    const align_width = if (data.container_width > 0) data.container_width else bounds.width;
    const alignment = data.config.alignment;
    const lines = data.wrapped_lines orelse {
        const x = bounds.x + alignOffset(alignment, align_width, data.measured_width);
        _ = emitTextLine(window, content, x, bounds.y, style);
        return;
    };
    assert(lines.len <= layout_mod.engine.MAX_LINES_PER_TEXT);
    const pitch = data.config.lineHeightPx();
    assert(pitch > 0);
    for (lines, 0..) |line, line_index| {
        assert(line.start_offset <= content.len);
        assert(line.length <= content.len - line.start_offset);
        const x = bounds.x + alignOffset(alignment, align_width, line.width);
        const y = bounds.y + @as(f32, @floatFromInt(line_index)) * pitch;
        const run = content[line.start_offset..][0..line.length];
        _ = emitTextLine(window, run, x, y, style);
    }
}

fn alignOffset(alignment: TextAlignment, align_width: f32, line_width: f32) f32 {
    assert(align_width >= 0);
    assert(line_width >= 0);
    return switch (alignment) {
        .left => 0,
        .center => (align_width - line_width) / 2,
        .right => align_width - line_width,
    };
}

const GlyphSink = struct {
    frame: *records.Frame,
    color: Color,

    pub fn glyph(self: *GlyphSink, instance: scene_mod.GlyphInstance) void {
        assert(instance.size_x > 0);
        self.frame.appendPaint(.{ .sprite = .{
            .bounds = .{
                .x = instance.pos_x,
                .y = instance.pos_y,
                .width = instance.size_x,
                .height = instance.size_y,
            },
            .atlas = .glyph,
            .uv = .{
                .x = instance.uv_left,
                .y = instance.uv_top,
                .width = instance.uv_right - instance.uv_left,
                .height = instance.uv_bottom - instance.uv_top,
            },
            .tint = self.color,
            .secondary = Color.transparent,
            .corners = .zero,
            .grayscale = 0,
            .opacity = 1,
        } });
    }
};

/// One line of text with its top at `y`, baseline from the face's ascender.
fn emitTextLine(window: *Window, content: []const u8, x: f32, y: f32, style: TextStyle) f32 {
    assert(style.size > 0);
    const metrics = window.resources.text_system.getMetricsFor(style.family);
    const size: f32 = @floatFromInt(style.size);
    return emitTextBaseline(
        window,
        content,
        x,
        y + metrics.ascender * size / metrics.point_size,
        style,
    );
}

fn emitTextBaseline(
    window: *Window,
    content: []const u8,
    x: f32,
    baseline: f32,
    style: TextStyle,
) f32 {
    assert(style.size > 0);
    if (content.len == 0) return 0;
    const text_system = window.resources.text_system;
    const size: f32 = @floatFromInt(style.size);
    var sink = GlyphSink{ .frame = window.built(), .color = style.color };
    return text_render.placeText(
        text_system,
        content,
        x,
        baseline,
        window.scale_factor,
        size,
        style.family,
        style.variant,
        &sink,
    ) catch |err| std.debug.panic("text emit failed in frame {d}: {s}", .{
        window.frame_number,
        @errorName(err),
    });
}

fn emitSvg(window: *Window, path: []const u8, bounds: Rect, options: SvgStyle) void {
    const stroke_width: ?f32 = if (options.stroke != null) options.stroke_width else null;
    const cached = window.resources.svg_atlas.getOrRasterize(
        path,
        options.viewbox,
        @max(bounds.width, bounds.height),
        options.fill != null,
        stroke_width,
    ) catch |err| switch (err) {
        // The per-frame rasterization budget is spent; draw it next tick.
        error.RasterizationDeferred => {
            window.render_requested = true;
            return;
        },
        else => std.debug.panic("svg rasterization failed: {s}", .{@errorName(err)}),
    };
    if (cached.region.width == 0) return;
    const uv = cached.uv();
    const scale = window.scale_factor;
    window.built().appendPaint(.{ .sprite = .{
        .bounds = .{
            .x = @floor(bounds.x * scale) / scale,
            .y = @floor(bounds.y * scale) / scale,
            .width = bounds.width,
            .height = bounds.height,
        },
        .atlas = .svg,
        .uv = .{ .x = uv.u0, .y = uv.v0, .width = uv.u1 - uv.u0, .height = uv.v1 - uv.v0 },
        .tint = options.fill orelse Color.transparent,
        .secondary = options.stroke orelse Color.transparent,
        .corners = .zero,
        .grayscale = 0,
        .opacity = 1,
    } });
}

comptime {
    assert(@sizeOf(a11y_types.State) == 2);
}
