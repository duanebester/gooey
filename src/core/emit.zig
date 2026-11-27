const std = @import("std");
const records = @import("records.zig");
const element = @import("element.zig");
const window_mod = @import("window.zig");
const layers = @import("layers.zig");
const limits_mod = @import("limits.zig");
const retained_mod = @import("retained.zig");
const text_mod = @import("../text/mod.zig");
const text_render = @import("../text/render.zig");
const a11y_types = @import("../accessibility/types.zig");
const layout_mod = @import("../layout/layout.zig");
const image_mod = @import("../image/mod.zig");
const images_mod = @import("images.zig");

const assert = std.debug.assert;

const Window = window_mod.Window;
const Node = window_mod.Node;
const Rect = records.Rect;
const Color = records.Color;
const index_none = records.index_none;
const TextData = layout_mod.engine.TextData;
const TextAlignment = layout_mod.TextConfig.TextAlignment;
const ObjectFit = image_mod.ObjectFit;
const ImageAtlas = image_mod.ImageAtlas;

pub const Painter = struct {
    bounds: Rect,

    pub fn theme(self: *const Painter) *const element.Theme {
        return targetOf(self).window.theme;
    }

    pub fn quad(self: *Painter, value: records.Quad) void {
        assert(value.bounds.width >= 0);
        assert(value.bounds.height >= 0);
        const paint_target = targetOf(self);
        if (paint_target.culled) return;
        paint_target.window.built().appendPaint(.{ .quad = value });
    }

    pub fn fill(self: *Painter, bounds: Rect, color: Color) void {
        self.quad(
            .{ .bounds = bounds, .fill = color, .border = .none, .corners = .zero, .blur = 0 },
        );
    }

    pub fn pushClip(self: *Painter, bounds: Rect) void {
        const paint_target = targetOf(self);
        assert(paint_target.clip_depth < clip_depth_max);
        checkClipDepth(paint_target.window, paint_target.clip_depth);
        paint_target.clip_depth += 1;
        if (paint_target.culled) return;
        paint_target.window.built().appendPaint(.{ .clip_push = bounds });
    }

    pub fn popClip(self: *Painter) void {
        const paint_target = targetOf(self);
        assert(paint_target.clip_depth > 0);
        paint_target.clip_depth -= 1;
        if (paint_target.culled) return;
        paint_target.window.built().appendPaint(.clip_pop);
    }

    pub fn text(self: *Painter, content: []const u8, x: f32, y: f32, style: TextStyle) f32 {
        const paint_target = targetOf(self);
        if (paint_target.culled) return self.measureText(content, style);
        return emitTextLine(paint_target.window, content, x, y, style);
    }

    pub fn textOnBaseline(
        self: *Painter,
        content: []const u8,
        x: f32,
        baseline: f32,
        style: TextStyle,
    ) f32 {
        const paint_target = targetOf(self);
        if (paint_target.culled) return self.measureText(content, style);
        return emitTextBaseline(paint_target.window, content, x, baseline, style);
    }

    pub fn measureText(self: *const Painter, content: []const u8, style: TextStyle) f32 {
        if (content.len == 0) return 0;
        const window = targetOf(self).window;
        const text_system = window.resources.text_system;
        const metrics = text_system.getMetricsFor(style.family);
        const width = text_system.measureText(style.family, content, style.variant) catch |err| {
            window_mod.textFailed(window, content, err);
        };
        return width * @as(f32, @floatFromInt(style.size)) / metrics.point_size;
    }

    pub fn fontMetrics(self: *const Painter) text_mod.Metrics {
        return targetOf(self).window.resources.text_system.getMetrics().?;
    }

    pub fn svg(self: *Painter, path: []const u8, bounds: Rect, options: SvgStyle) void {
        const paint_target = targetOf(self);
        if (paint_target.culled) return;
        emitSvg(paint_target.window, path, bounds, options);
    }

    pub fn triangles(self: *Painter, points: []const [2]f32, color: Color) void {
        assert(points.len > 0);
        assert(points.len % 3 == 0);
        const paint_target = targetOf(self);
        if (paint_target.culled) return;
        emitTriangles(paint_target.window, points, color);
    }

    pub fn line(self: *Painter, from: [2]f32, to: [2]f32, width: f32, color: Color) void {
        assert(width > 0);
        assert(!std.math.isNan(from[0]) and !std.math.isNan(to[0]));
        const dx = to[0] - from[0];
        const dy = to[1] - from[1];
        if (@abs(dy) < 0.001) {
            const left = @min(from[0], to[0]);
            const top = from[1] - width * 0.5;
            self.fill(.{ .x = left, .y = top, .width = @abs(dx), .height = width }, color);
            return;
        }
        if (@abs(dx) < 0.001) {
            const top = @min(from[1], to[1]);
            const left = from[0] - width * 0.5;
            self.fill(.{ .x = left, .y = top, .width = width, .height = @abs(dy) }, color);
            return;
        }
        const length = @sqrt(dx * dx + dy * dy);
        const px = -dy / length * width * 0.5;
        const py = dx / length * width * 0.5;
        const c0 = [2]f32{ from[0] + px, from[1] + py };
        const c1 = [2]f32{ to[0] + px, to[1] + py };
        const c2 = [2]f32{ to[0] - px, to[1] - py };
        const c3 = [2]f32{ from[0] - px, from[1] - py };
        self.triangles(&.{ c0, c1, c2, c0, c2, c3 }, color);
    }

    pub fn circle(self: *Painter, center: [2]f32, radius: f32, color: Color) void {
        assert(radius >= 0);
        assert(!std.math.isNan(center[0]) and !std.math.isNan(center[1]));
        var points: [3 * (circle_sides_max - 2)][2]f32 = undefined;
        const count = circlePoints(&points, center, radius, targetOf(self).window.scale_factor);
        self.triangles(points[0..count], color);
    }

    pub fn polyline(self: *Painter, points: []const [2]f32, width: f32, color: Color) void {
        assert(points.len >= 2);
        assert(width > 0);
        const paint_target = targetOf(self);
        if (paint_target.culled) return;
        emitPointMesh(paint_target.window, points, .{
            .topology = .strip_expanded,
            .width = width,
            .color = color,
        });
    }

    pub fn pointCloud(self: *Painter, centers: []const [2]f32, radius: f32, color: Color) void {
        assert(centers.len >= 1);
        assert(radius > 0);
        const paint_target = targetOf(self);
        if (paint_target.culled) return;
        emitPointMesh(paint_target.window, centers, .{
            .topology = .point_instanced,
            .width = radius,
            .color = color,
        });
    }

    pub fn image(self: *Painter, path: []const u8, bounds: Rect, options: ImageStyle) void {
        const paint_target = targetOf(self);
        if (paint_target.culled) return;
        emitImage(paint_target.window, path, bounds, options);
    }

    pub fn imeCursor(self: *Painter, ime: records.Ime) void {
        assert(ime.owner.isKeyed());
        assert(ime.selected_start <= ime.selected_end);
        targetOf(self).window.built().ime = ime;
    }
};

pub const PaintTarget = struct {
    window: *Window,
    clip_depth: u32,
    culled: bool,
    painter: Painter,
};

pub fn targetOf(painter: *const Painter) *PaintTarget {
    const paint_target: *const PaintTarget = @alignCast(@fieldParentPtr("painter", painter));
    assert(paint_target.clip_depth <= clip_depth_max);
    assert(paint_target.window.phase != .idle);
    return @constCast(paint_target);
}

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

pub const ImageStyle = struct {
    fit: ObjectFit,
    corners: records.Corners = .zero,
    tint: ?Color = null,
    grayscale: f32 = 0,
    opacity: f32 = 1,
};

const clip_depth_max: u32 = limits_mod.MAX_CLIP_STACK_DEPTH;

pub fn emit(window: *Window) void {
    window.assertPhase(.emit);
    window.resources.svg_atlas.resetFrameBudget();
    if (window.images.land(window.resources.image_atlas) == .deferred) {
        window.render_requested = true;
    }
    assert(window.layout.elements.items().len == window.node_count);
    emitAccessibility(window);
    var layers_open = LayerQueue{ .roots = undefined, .len = 0, .opened = 0 };
    emitFragment(window, &layers_open, &.{
        .node_index = 0,
        .fragment = layers.content_fragment,
        .parent_hit = index_none,
        .clip = null,
    });
    var fragment: u8 = layers.content_fragment;
    while (layers_open.next(window)) |opened| {
        assert(fragment < layer_count_ceiling);
        fragment += 1;
        var root = opened;
        root.fragment = fragment;
        emitFragment(window, &layers_open, &root);
    }
    assert(layers_open.len == 0);
    assert(window.built().paint_opacity == 1);
    window.focus_reveal = false;
}

fn emitAccessibility(window: *Window) void {
    const elements = window.layout.elements.items();
    const nodes = window.nodes[0..window.node_count];
    var a11y_level: [window_mod.box_depth_ceiling + 1]u8 = undefined;
    var index: u32 = 0;
    while (index < nodes.len) : (index += 1) {
        const node = &nodes[index];
        if (node.layer) |layer| {
            if (layer.kind == .drag) {
                const end = subtreeEnd(nodes, index);
                assert(end > index);
                index = end - 1;
                continue;
            }
        }
        const depth = node.depth;
        assert(depth <= window.limits.build.box_depth_max);
        const box = elements[index].computed.bounding_box;
        const bounds = Rect{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        const parent_level: u8 = if (depth == 0) 0 else a11y_level[depth - 1];
        if (node.kind == .text) {
            const data = &elements[index].text_data.?;
            if (node.spans.len > 0) emitLinkA11y(window, node, data, bounds, parent_level);
            continue;
        }
        a11y_level[depth] = parent_level + emitA11y(window, node, bounds, parent_level);
    }
}

/// Appends one `.link` node per shown link span of a text, in byte order, nested under the
/// nearest accessible ancestor as a box is. A text itself adds no node: a box's
/// `a11y.label` reads it. A link wholly hidden by a cut adds none (`linkLine`). The
/// fragment pass, where segment positions are known, sets each node's bounds.
fn emitLinkA11y(
    window: *Window,
    node: *const Node,
    data: *const TextData,
    bounds: Rect,
    level: u8,
) void {
    assert(node.kind == .text);
    assert(node.spans.len > 0);
    assert(node.spans.offset + node.spans.len <= window.span_count);
    var links: LinkEmit = .{ .hit = undefined, .clip = null };
    var plain: PlainRun = undefined;
    const text = textRuns(window, node, data, &plain, &links);
    var whole: [1]WrappedLine = undefined;
    const view = textView(data, bounds, &whole);
    const frame = window.built();
    var start: u32 = 0;
    for (text.runs, 0..) |run, run_index| {
        assert(run.end > start);
        defer start = run.end;
        if (!text.paints[run_index].link) continue;
        const link = text.link(window, @intCast(run_index));
        assert(link.a11y == index_none);
        if (linkLine(window, &text, &view, @intCast(run_index)) == null) continue;
        link.a11y = frame.a11y_count;
        frame.appendA11y(.{
            .id = link.id,
            .role = .link,
            .bounds = .{ .x = bounds.x, .y = bounds.y, .width = 0, .height = 0 },
            .depth = level,
            .name = .{ .offset = node.text.offset + start, .len = run.end - start },
            .value = .empty,
            .href = link.href,
            .description = .empty,
            .state = .{ .focused = window.isFocused(link.id) },
            .heading_level = .none,
            .live = .off,
            .pos_in_set = null,
            .set_size = null,
            .range = null,
            .selection = null,
        });
    }
    assert(start == node.text.len);
}

fn emitFragment(window: *Window, layers_open: *LayerQueue, root: *const LayerRoot) void {
    const elements = window.layout.elements.items();
    const nodes = window.nodes[0..window.node_count];
    const root_depth = nodes[root.node_index].depth;
    var hit_scope: [window_mod.box_depth_ceiling + 1]u32 = undefined;
    var clips = Clips{ .entries = undefined, .len = 0, .base = root.clip };
    if (root.clip) |rect| window.built().appendPaint(.{ .clip_push = rect });
    var takes_pointer = true;
    if (root.fragment != layers.content_fragment) {
        const kind = nodes[root.node_index].layer.?.kind;
        if (kind == .modal) blockEarlierHits(window.built());
        takes_pointer = kind != .drag and kind != .tooltip;
    }
    var ring: ?FocusRing = null;
    var index = root.node_index;
    while (index < nodes.len) {
        const node = &nodes[index];
        const depth = node.depth;
        assert(depth <= window.limits.build.box_depth_max);
        if (index != root.node_index and depth <= root_depth) break;
        const box = elements[index].computed.bounding_box;
        const bounds = Rect{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        clips.close(window, depth);
        window.built().paint_opacity = node.opacity;
        const parent_hit = if (depth == root_depth) root.parent_hit else hit_scope[depth - 1];
        if (index != root.node_index and node.layer != null) {
            layers_open.open(window, index, parent_hit, clips.current());
            index = subtreeEnd(nodes, index);
            continue;
        }
        clips.extend(depth, bounds);
        const clip = clips.current();
        const hit: HitPlace = .{
            .parent = parent_hit,
            .fragment = root.fragment,
            .takes_pointer = takes_pointer,
        };
        switch (node.kind) {
            .box, .paint => {
                emitAppearance(window, node, bounds, clip);
                hit_scope[depth] = emitHit(window, node, clips.clipped(bounds), hit);
                const takes_focus = node.focusable or window.isKeyboardDropTarget(node.id);
                if (window.focus_visible and takes_focus and window.isFocused(node.id)) {
                    ring = focusRing(window, &clips, bounds, node.corners);
                }
                if (node.kind == .paint) {
                    const culled = if (clip) |rect| !bounds.overlaps(rect) else false;
                    emitPaint(window, node, bounds, .{
                        .clip_depth = clips.paintDepth(),
                        .culled = culled,
                    });
                }
                if (node.clip) clips.open(window, node, index, bounds);
            },
            .text => {
                const data = &elements[index].text_data.?;
                const place: TextPlace = .{ .data = data, .clip = clip, .hit = hit };
                const focus = emitText(window, node, bounds, place);
                if (focus.count > 0) ring = linkFocusRing(window, &clips, &focus);
            },
        }
        index += 1;
    }
    clips.close(window, 0);
    assert(clips.len == 0);
    window.built().paint_opacity = 1;
    if (ring) |*focused| placeFocus(window, focused, clips.paintDepth());
    if (root.clip != null) window.built().appendPaint(.clip_pop);
}

/// Reveals and records the fragment's focused element, then draws its ring above the
/// fragment's content.
fn placeFocus(window: *Window, ring: *const FocusRing, paint_depth: u32) void {
    assert(window.focus != .root);
    assert(window.focus_visible);
    const shifted = focusShifted(window, ring);
    if (window.focus_reveal or shifted) revealFocus(window, ring);
    const content = focusPlaceContent(window, ring, shifted);
    window.focus_place = .{
        .id = window.focus,
        .frame_number = window.frame_number,
        .content = content,
    };
    emitFocusRing(window, ring, paint_depth);
}

fn linkFocusRing(window: *Window, clips: *const Clips, focus: *const LinkFocus) FocusRing {
    assert(focus.count > 0);
    assert(focus.count <= link_ring_count_max);
    var ring = focusRing(window, clips, focus.bounds, .zero);
    ring.segments = focus.segments;
    ring.segment_count = focus.count;
    return ring;
}

const focus_ring_width: f32 = 2;
const focus_ring_offset: f32 = 2;
const focus_reveal_margin: f32 = 8;
const focus_shift_slop_px: f32 = 0.5;

const FocusRing = struct {
    bounds: Rect,
    corners: records.Corners,
    clip: ?Rect,
    scroll: ?ScrollHandle,
    content: Rect,
    /// A focused link's drawn segments, one ring each; 0 rings `bounds` as one box.
    segments: [link_ring_count_max]Rect = undefined,
    segment_count: u8 = 0,
};

/// A focused link wrapping more lines than this rings its last lines as one box: bounded
/// ring storage, and a link that long is rare in running text.
const link_ring_count_max: u8 = 8;

const ScrollHandle = retained_mod.Handle(window_mod.ScrollState);

fn focusRing(
    window: *Window,
    clips: *const Clips,
    bounds: Rect,
    corners: records.Corners,
) FocusRing {
    assert(window.focus != .root);
    assert(window.focus_visible);
    var ring = FocusRing{
        .bounds = bounds,
        .corners = corners,
        .clip = clips.current(),
        .scroll = null,
        .content = bounds,
    };
    if (clips.innermostScroll(window)) |scroll| {
        const state = window.retained.get(window_mod.ScrollState, scroll.handle);
        ring.scroll = scroll.handle;
        ring.content.x = bounds.x - scroll.bounds.x + state.offset_x;
        ring.content.y = bounds.y - scroll.bounds.y + state.offset_y;
    }
    assert(ring.content.width == bounds.width);
    return ring;
}

fn focusShifted(window: *const Window, ring: *const FocusRing) bool {
    const place = &window.focus_place;
    assert(place.frame_number < window.frame_number);
    if (ring.scroll == null) return false;
    if (!focusPlaceFollows(window)) return false;
    const before = place.content;
    const after = ring.content;
    assert(before.width >= 0);
    assert(after.width >= 0);
    if (@abs(after.x - before.x) > focus_shift_slop_px) return true;
    if (@abs(after.y - before.y) > focus_shift_slop_px) return true;
    if (@abs(after.width - before.width) > focus_shift_slop_px) return true;
    return @abs(after.height - before.height) > focus_shift_slop_px;
}

fn focusPlaceFollows(window: *const Window) bool {
    const place = &window.focus_place;
    assert(place.frame_number < window.frame_number);
    return place.id == window.focus and place.frame_number + 1 == window.frame_number;
}

fn focusPlaceContent(window: *const Window, ring: *const FocusRing, shifted: bool) Rect {
    assert(ring.content.width >= 0);
    if (shifted) return ring.content;
    if (!focusPlaceFollows(window)) return ring.content;
    return window.focus_place.content;
}

fn revealFocus(window: *Window, ring: *const FocusRing) void {
    assert(window.focus_visible);
    assert(ring.bounds.width >= 0);
    window.focus_reveal = false;
    const handle = ring.scroll orelse return;
    const state = window.retained.get(window_mod.ScrollState, handle);
    const view = state.viewport;
    const spread = focus_ring_offset + focus_ring_width + focus_reveal_margin;
    const before_x = state.offset_x;
    const before_y = state.offset_y;
    const box = ring.bounds;
    state.offset_x += revealDelta(view.x, view.width, box.x - spread, box.width + spread * 2);
    state.offset_y += revealDelta(view.y, view.height, box.y - spread, box.height + spread * 2);
    _ = state.clamp();
    if (state.offset_x != before_x or state.offset_y != before_y) window.render_requested = true;
}

fn revealDelta(view_start: f32, view_size: f32, start: f32, size: f32) f32 {
    assert(view_size >= 0);
    assert(size >= 0);
    if (start < view_start or size > view_size) return start - view_start;
    const overshoot = (start + size) - (view_start + view_size);
    return @max(0, overshoot);
}

fn emitFocusRing(window: *Window, ring: *const FocusRing, paint_depth: u32) void {
    assert(ring.bounds.width >= 0);
    assert(ring.bounds.height >= 0);
    assert(ring.segment_count <= link_ring_count_max);
    const frame = window.built();
    if (ring.clip) |clip| {
        checkClipDepth(window, paint_depth);
        frame.appendPaint(.{ .clip_push = clip });
    }
    const color = window.theme.border_focus;
    if (ring.segment_count == 0) {
        appendRing(frame, ring.bounds, ring.corners, color);
    } else {
        for (ring.segments[0..ring.segment_count]) |segment| {
            appendRing(frame, segment, .zero, color);
        }
    }
    if (ring.clip != null) frame.appendPaint(.clip_pop);
}

fn appendRing(frame: *records.Frame, bounds: Rect, corners: records.Corners, color: Color) void {
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    const spread = focus_ring_offset + focus_ring_width;
    frame.appendPaint(.{ .quad = .{
        .bounds = .{
            .x = bounds.x - spread,
            .y = bounds.y - spread,
            .width = bounds.width + spread * 2,
            .height = bounds.height + spread * 2,
        },
        .fill = Color.transparent,
        .border = .{ .width = focus_ring_width, .color = color },
        .corners = .{
            .top_left = corners.top_left + spread,
            .top_right = corners.top_right + spread,
            .bottom_right = corners.bottom_right + spread,
            .bottom_left = corners.bottom_left + spread,
        },
        .blur = 0,
    } });
}

fn blockEarlierHits(frame: *records.Frame) void {
    assert(frame.modal_hit_start <= frame.hit_count);
    frame.modal_hit_start = frame.hit_count;
    assert(frame.hit_count <= frame.hits.len);
}

fn subtreeEnd(nodes: []const Node, index: u32) u32 {
    assert(index < nodes.len);
    const depth = nodes[index].depth;
    var end = index + 1;
    while (end < nodes.len and nodes[end].depth > depth) end += 1;
    assert(end > index);
    return end;
}

const layer_count_ceiling = limits_mod.layer_count_ceiling;

const LayerRoot = struct {
    node_index: u32,
    fragment: u8,
    parent_hit: u32,
    clip: ?Rect,
};

const LayerQueue = struct {
    roots: [layer_count_ceiling]LayerRoot,
    len: u32,
    opened: u32,

    fn open(self: *LayerQueue, window: *Window, index: u32, parent_hit: u32, clip: ?Rect) void {
        const layer = window.nodes[index].layer.?;
        assert(self.len <= self.opened);
        const opened_max = window.limits.build.layer_count_frame_max;
        assert(opened_max <= layer_count_ceiling);
        assert(self.opened < opened_max);
        assert(self.opened < window.layout.floating_roots.len);
        self.roots[self.len] = .{
            .node_index = index,
            .fragment = layers.content_fragment,
            .parent_hit = parent_hit,
            .clip = if (layer.clip == .inherit) clip else null,
        };
        self.len += 1;
        self.opened += 1;
    }

    fn next(self: *LayerQueue, window: *const Window) ?LayerRoot {
        assert(self.len <= self.opened);
        if (self.len == 0) return null;
        var best: u32 = 0;
        for (self.roots[1..self.len], 1..) |*root, position| {
            const candidate = order(window, root);
            const current = order(window, &self.roots[best]);
            if (candidate < current) best = @intCast(position);
        }
        const root = self.roots[best];
        self.len -= 1;
        self.roots[best] = self.roots[self.len];
        return root;
    }

    fn order(window: *const Window, root: *const LayerRoot) u64 {
        const rank: u64 = layers.kindRank(window.nodes[root.node_index].layer.?.kind);
        return (rank << 32) | root.node_index;
    }
};

const Clips = struct {
    entries: [clip_depth_max]Entry,
    len: u32,
    base: ?Rect,

    const Entry = struct {
        depth: u8,
        node_index: u32,
        bounds: Rect,
        rect: Rect,
        drawn: bool,
        extent_right: f32,
        extent_bottom: f32,
    };

    const Scroll = struct { handle: ScrollHandle, bounds: Rect };

    fn innermostScroll(self: *const Clips, window: *const Window) ?Scroll {
        assert(self.len <= clip_depth_max);
        var index = self.len;
        while (index > 0) {
            index -= 1;
            const entry = &self.entries[index];
            if (window.nodes[entry.node_index].scroll) |handle| {
                return .{ .handle = handle, .bounds = entry.bounds };
            }
        }
        return null;
    }

    fn current(self: *const Clips) ?Rect {
        assert(self.len <= clip_depth_max);
        if (self.len == 0) return self.base;
        return self.entries[self.len - 1].rect;
    }

    fn clipped(self: *const Clips, bounds: Rect) Rect {
        assert(bounds.width >= 0);
        const rect = self.current() orelse return bounds;
        return bounds.intersect(rect);
    }

    fn paintDepth(self: *const Clips) u32 {
        assert(self.len <= clip_depth_max);
        return self.len + @intFromBool(self.base != null);
    }

    fn open(self: *Clips, window: *Window, node: *const Node, index: u32, bounds: Rect) void {
        assert(node.clip);
        assert(self.len <= clip_depth_max);
        checkClipDepth(window, self.paintDepth());
        var rect = bounds;
        var origin_x = bounds.x;
        var origin_y = bounds.y;
        if (node.scroll) |handle| {
            const state = window.retained.get(window_mod.ScrollState, handle);
            const applied = window.layout.elements.items()[index].config.scroll.?.scroll_offset;
            state.offset_x = applied.x;
            state.offset_y = applied.y;
            state.target = null;
            assert(applied.x >= 0);
            assert(applied.y >= 0);
            origin_x = bounds.x - applied.x;
            origin_y = bounds.y - applied.y;
            if (state.maxY() > 0) rect.width = @max(0, rect.width - scrollbar_room);
            if (state.maxX() > 0) rect.height = @max(0, rect.height - scrollbar_room);
        }
        rect = self.clipped(rect);
        const drawn = rect.width > 0 and rect.height > 0;
        if (drawn) window.built().appendPaint(.{ .clip_push = rect });
        self.entries[self.len] = .{
            .depth = node.depth,
            .node_index = index,
            .bounds = bounds,
            .rect = rect,
            .drawn = drawn,
            .extent_right = origin_x,
            .extent_bottom = origin_y,
        };
        self.len += 1;
    }

    fn close(self: *Clips, window: *Window, depth: u8) void {
        assert(self.len <= clip_depth_max);
        while (self.len > 0) {
            const entry = &self.entries[self.len - 1];
            if (entry.depth < depth) break;
            if (entry.drawn) window.built().appendPaint(.clip_pop);
            const outer = if (self.len > 1) self.entries[self.len - 2].rect else self.base;
            if (window.nodes[entry.node_index].scroll) |handle| {
                finishScroll(window, entry, handle, outer);
            }
            self.len -= 1;
        }
        if (self.len > 0) assert(self.entries[self.len - 1].depth < depth);
    }

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
    const depth_max = window.limits.paint.clip_depth_max;
    assert(depth_max <= clip_depth_max);
    if (depth < depth_max) return;
    std.debug.panic("clip depth {d}: capacity {d} (frame {d}). Raise " ++
        "ResourceLimits.paint.clip_depth_max.", .{ depth + 1, depth_max, window.frame_number });
}

const scrollbar_room = window_mod.ScrollState.scrollbar_room;
const scrollbar_radius: f32 = 4;
const scrollbar_track_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.05 };
const scrollbar_thumb_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.3 };
const scrollbar_thumb_drag_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.5 };

fn finishScroll(
    window: *Window,
    entry: *const Clips.Entry,
    handle: retained_mod.Handle(window_mod.ScrollState),
    outer: ?Rect,
) void {
    const state = window.retained.get(window_mod.ScrollState, handle);
    const padding = window.layout.elements.items()[entry.node_index].config.layout.padding;
    const bounds = entry.bounds;
    const overflow_x = state.maxX() > 0;
    const overflow_y = state.maxY() > 0;
    const resized = state.viewport.width != bounds.width or
        state.viewport.height != bounds.height;
    state.content_width = @max(0, entry.extent_right + state.offset_x - bounds.x +
        @as(f32, @floatFromInt(padding.right)));
    state.content_height = @max(0, entry.extent_bottom + state.offset_y - bounds.y +
        @as(f32, @floatFromInt(padding.bottom)));
    state.viewport = bounds;
    const moved = state.clamp();
    if (moved or resized or overflow_x != (state.maxX() > 0) or
        overflow_y != (state.maxY() > 0))
    {
        window.render_requested = true;
    }
    window.built().paint_opacity = window.nodes[entry.node_index].opacity;
    inline for (.{ window_mod.ScrollAxis.y, window_mod.ScrollAxis.x }) |axis| {
        if (state.track(axis)) |bar| {
            const shown = if (outer) |rect| bar.overlaps(rect) else true;
            const dragged = state.dragging == axis;
            if (shown) emitScrollbar(window, bar, state.thumb(axis, bar), dragged);
        }
    }
}

fn emitScrollbar(window: *Window, track: Rect, thumb: Rect, dragged: bool) void {
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
        .fill = if (dragged) scrollbar_thumb_drag_color else scrollbar_thumb_color,
        .border = .none,
        .corners = corners,
        .blur = 0,
    } });
}

fn emitAppearance(window: *Window, node: *const Node, bounds: Rect, clip: ?Rect) void {
    const frame = window.built();
    if (node.shadow) |shadow| {
        const shown = if (clip) |rect| shadowBounds(bounds, shadow).overlaps(rect) else true;
        if (shadow.blur > 0 and shown) frame.appendPaint(.{ .quad = .{
            .bounds = bounds,
            .fill = node.shadow_color,
            .border = .none,
            .corners = node.corners,
            .blur = shadow.blur,
            .offset_x = shadow.offset_x,
            .offset_y = shadow.offset_y,
        } });
    }
    if (node.background == null and node.fill == null and node.border.width == 0) return;
    if (clip) |rect| {
        if (!bounds.overlaps(rect)) return;
    }
    if (node.fill) |fill| {
        assert(node.background == null);
        frame.appendPaint(.{ .custom = .{
            .bounds = bounds,
            .corners = node.corners,
            .opacity = 1,
            .shader = fill.shader,
            .params_slot = fill.params_slot,
        } });
        if (node.border.width == 0) return;
    }
    frame.appendPaint(.{ .quad = .{
        .bounds = bounds,
        .fill = node.background orelse Color.transparent,
        .border = node.border,
        .corners = node.corners,
        .blur = 0,
    } });
}

fn shadowBounds(bounds: Rect, shadow: element.Shadow) Rect {
    assert(shadow.blur >= 0);
    assert(bounds.width >= 0);
    const spread = shadow.blur * 2;
    return .{
        .x = bounds.x + shadow.offset_x - spread,
        .y = bounds.y + shadow.offset_y - spread,
        .width = bounds.width + spread * 2,
        .height = bounds.height + spread * 2,
    };
}

const HitPlace = struct { parent: u32, fragment: u8, takes_pointer: bool };

fn emitHit(window: *Window, node: *const Node, bounds: Rect, place: HitPlace) u32 {
    if (!node.hit) return place.parent;
    assert(node.id.isKeyed() or node.on_click != index_none or node.focusable or
        node.on_key != index_none or node.on_click_outside != index_none or
        node.on_context_menu != index_none or
        node.key_context != 0 or node.actions_len > 0 or node.scroll != null or
        node.cursor != null);
    if (node.on_pointer_drag != index_none) assert(node.id.isKeyed());
    if (node.drag_type != 0) assert(node.id.isKeyed());
    if (node.drop_type != 0) assert(node.id.isKeyed());
    if (node.drop_type != 0) assert(node.on_drop != index_none);
    return window.built().appendHit(.{
        .id = node.id,
        .bounds = bounds,
        .fragment = place.fragment,
        .parent = place.parent,
        .pointer = node.pointer and place.takes_pointer,
        .focusable = node.focusable,
        .tab_stop = node.tab_stop,
        .scroll = node.scroll != null,
        .cursor = node.cursor,
        .on_click = node.on_click,
        .on_click_outside = node.on_click_outside,
        .on_context_menu = node.on_context_menu,
        .on_key = node.on_key,
        .on_pointer_drag = node.on_pointer_drag,
        .drag_type = node.drag_type,
        .drag_payload = node.drag_payload,
        .drop_type = node.drop_type,
        .on_drop = node.on_drop,
        .key_context = node.key_context,
        .actions_start = node.actions_start,
        .actions_len = node.actions_len,
    });
}

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
        .description = a11y.description,
        .state = .{
            .focused = focused,
            .checked = a11y.checked,
            .selected = a11y.selected,
            .disabled = a11y.disabled,
            .expanded = a11y.expanded,
            .has_popup = a11y.has_popup,
        },
        .heading_level = a11y.heading_level,
        .live = a11y.live,
        .pos_in_set = a11y.pos_in_set,
        .set_size = a11y.set_size,
        .range = if (a11y.range) |range| .{
            .min = range.min,
            .max = range.max,
            .now = range.now,
            .orientation = range.orientation,
        } else null,
        .selection = a11y.selection,
    });
    return 1;
}

const PaintPlace = struct { clip_depth: u32, culled: bool };

fn emitPaint(window: *Window, node: *const Node, bounds: Rect, place: PaintPlace) void {
    const paint_fn = node.paint_fn.?;
    const box_clip_depth = place.clip_depth;
    assert(box_clip_depth < clip_depth_max);
    var paint_target = PaintTarget{
        .window = window,
        .clip_depth = box_clip_depth,
        .culled = place.culled,
        .painter = .{ .bounds = bounds },
    };
    paint_fn(node.paint_data.?, @ptrCast(&paint_target.painter));
    if (paint_target.clip_depth != box_clip_depth) {
        std.debug.panic("a paint function returned with {d} clips pushed", .{
            paint_target.clip_depth - box_clip_depth,
        });
    }
}

const TextPlace = struct { data: *const TextData, clip: ?Rect, hit: HitPlace };

const WrappedLine = layout_mod.types.WrappedLine;

/// Draws a text's lines in view. Each line is split at its runs' boundaries into segments,
/// shaped in their run's font and painted in their run's color, on the base font's baseline
/// so every line keeps the text's pitch. A plain text is one run (`textRuns`), so plain and
/// rich texts share every path here. Returns the rings of the text's focused link, if any.
fn emitText(window: *Window, node: *const Node, bounds: Rect, place: TextPlace) LinkFocus {
    const data = place.data;
    var links: LinkEmit = .{ .hit = place.hit, .clip = place.clip };
    const content = window.built().text(node.text) orelse return links.focus;
    assert(content.len == data.text.len);
    var plain: PlainRun = undefined;
    const text = textRuns(window, node, data, &plain, &links);
    var whole: [1]WrappedLine = undefined;
    const view = textView(data, bounds, &whole);
    if (data.wrapped_lines == null) {
        const x = view.lineX(&text, &whole[0]);
        const box = lineBox(x, bounds.y, data.measured_width, @max(text.pitch, bounds.height));
        const culled = if (place.clip) |rect| !box.overlaps(rect) else false;
        if (!culled) emitLine(window, &text, content, whole[0], .{ .x = x, .y = bounds.y });
    } else {
        emitWrappedLines(window, &text, content, &view);
    }
    if (node.spans.len > 0) {
        recordCulledLinks(window, &text, &view, @intCast(view.lines.len));
        placeOffscreenLinks(window, &text, &view);
    }
    assert(links.next_run <= text.runs.len);
    return links.focus;
}

/// A text's laid-out lines; a text that does not wrap is one whole line in `whole`.
fn textView(data: *const TextData, bounds: Rect, whole: *[1]WrappedLine) TextView {
    assert(data.measured_width >= 0);
    whole.* = .{.{
        .start_offset = 0,
        .extent = .{ .length = @intCast(data.text.len) },
        .width = data.measured_width,
    }};
    const view: TextView = .{
        .lines = data.wrapped_lines orelse whole,
        .span = lineSpan(data, bounds),
        .top = bounds.y,
    };
    assert(view.lines.len > 0);
    return view;
}

fn emitWrappedLines(
    window: *Window,
    text: *const TextRuns,
    content: []const u8,
    view: *const TextView,
) void {
    const lines = view.lines;
    assert(lines.len <= window.layout.line_scratch.len);
    const clip = text.links.clip;
    const shown = linesInView(view.top, text.pitch, @intCast(lines.len), clip);
    assert(shown.start <= shown.end);
    assert(shown.end <= lines.len);
    for (lines[shown.start..shown.end], shown.start..) |*line, line_index| {
        assert(line.start_offset <= content.len);
        assert(line.extent.length <= content.len - line.start_offset);
        // An empty line draws nothing unless it was cut: a line count that ends on a
        // blank line still draws its "…".
        if (line.extent.length == 0 and line.extent.end == .whole) continue;
        const x = view.lineX(text, line);
        const y = view.lineY(text, @intCast(line_index));
        if (clip) |rect| {
            if (!lineBox(x, y, line.width, text.pitch).overlaps(rect)) continue;
        }
        if (text.node.spans.len > 0) recordCulledLinks(window, text, view, @intCast(line_index));
        if (line.extent.end == .whole) {
            emitLine(window, text, content, line.*, .{ .x = x, .y = y });
        } else {
            emitCutLine(window, text, content, line.*, .{ .span = view.span, .y = y });
        }
    }
}

/// Where a text's lines sit: its laid-out lines (one whole line for a text that does not
/// wrap) and their span and top.
const TextView = struct {
    lines: []const WrappedLine,
    span: LineSpan,
    top: f32,

    fn lineX(self: *const TextView, text: *const TextRuns, line: *const WrappedLine) f32 {
        assert(line.width >= 0);
        const alignment = text.data.config.alignment;
        return self.span.x + alignOffset(alignment, self.span.width, line.width);
    }

    fn lineY(self: *const TextView, text: *const TextRuns, line_index: u32) f32 {
        assert(line_index < self.lines.len);
        return self.top + @as(f32, @floatFromInt(line_index)) * text.pitch;
    }

    /// The whole box of line `line_index`: where a link with no drawn segment is placed.
    fn lineRect(self: *const TextView, text: *const TextRuns, line_index: u32) Rect {
        const line = &self.lines[line_index];
        const box: Rect = .{
            .x = self.lineX(text, line),
            .y = self.lineY(text, line_index),
            .width = line.width,
            .height = text.pitch,
        };
        assert(box.height > 0);
        return box;
    }
};

/// The bytes of a line that are shown: all of a whole line, the kept prefix of a cut one.
/// A cut is measured as `emitCutLine` draws it, so the two agree byte for byte.
fn keptLength(window: *Window, text: *const TextRuns, line: *const WrappedLine) u32 {
    if (line.extent.end == .whole) return line.extent.length;
    const cut = measureLineCut(window, text, line);
    if (cut.cut.whole) return line.extent.length;
    if (cut.widths.kept_max < 0) return 0;
    assert(cut.cut.length <= line.extent.length);
    return cut.cut.length;
}

/// The first line that shows any byte of `[start, end)`, or null when every byte is
/// hidden: past the last laid-out line, or in the cut part of a line. Both the
/// accessibility and the hit passes classify links with it, so they agree on which exist.
fn linkLine(window: *Window, text: *const TextRuns, view: *const TextView, run_index: u32) ?u32 {
    assert(run_index < text.runs.len);
    const start: u32 = if (run_index == 0) 0 else text.runs[run_index - 1].end;
    const end = text.runs[run_index].end;
    assert(start < end);
    const lines = view.lines;
    var index = lineAt(lines, start);
    while (index < lines.len) : (index += 1) {
        const line = &lines[index];
        if (line.start_offset >= end) break;
        const kept = keptLength(window, text, line);
        if (@max(start, line.start_offset) < @min(end, line.start_offset + kept)) return index;
    }
    assert(index <= lines.len);
    return null;
}

/// Records, in byte order, each link before line `upto` with no record yet whose first
/// shown line was culled: a pointerless Tab stop on that line's box, so focusing it
/// reveals the line and the next frame draws its exact segments. A link wholly hidden
/// by a cut gets nothing. A link first shown at or after `upto` stops the walk: it is
/// drawn there, or recorded by a later walk, and every later link starts after it.
fn recordCulledLinks(
    window: *Window,
    text: *const TextRuns,
    view: *const TextView,
    upto: u32,
) void {
    assert(text.node.spans.len > 0);
    assert(upto <= view.lines.len);
    const links = text.links;
    if (!links.hit.takes_pointer) return;
    const text_end: u32 = @intCast(text.data.text.len);
    const upto_byte = if (upto < view.lines.len) view.lines[upto].start_offset else text_end;
    var index = links.next_run;
    while (index < text.runs.len) : (index += 1) {
        const start: u32 = if (index == 0) 0 else text.runs[index - 1].end;
        if (start >= upto_byte) break;
        if (!text.paints[index].link) continue;
        if (text.link(window, index).hit != index_none) continue;
        const first = linkLine(window, text, view, index) orelse continue;
        if (first >= upto) break;
        recordLink(window, text, index, view.lineRect(text, first), .culled);
    }
    assert(index <= text.runs.len);
    links.next_run = index;
}

/// Gives each shown link with no visible segment its offscreen box: the whole first line
/// that shows it. Accessibility then reads every link at a real place, in view or not.
fn placeOffscreenLinks(window: *Window, text: *const TextRuns, view: *const TextView) void {
    assert(text.node.spans.len > 0);
    const frame = window.built();
    for (text.paints, 0..) |*paint, run_index| {
        if (!paint.link) continue;
        const link = text.link(window, @intCast(run_index));
        if (link.a11y == index_none or link.visible) continue;
        assert(link.a11y < frame.a11y_count);
        const first = linkLine(window, text, view, @intCast(run_index)).?;
        frame.a11y[link.a11y].bounds = view.lineRect(text, first);
    }
}

/// The line holding byte `offset`: the last line starting at or before it.
fn lineAt(lines: []const WrappedLine, offset: u32) u32 {
    assert(lines.len > 0);
    assert(lines[0].start_offset <= offset);
    var low: u32 = 0;
    var high: u32 = @intCast(lines.len - 1);
    var step_count: u32 = 0;
    while (low < high) : (step_count += 1) {
        assert(step_count < 32);
        const middle = low + @divFloor(high - low + 1, 2);
        if (lines[middle].start_offset <= offset) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    assert(lines[low].start_offset <= offset);
    return low;
}

/// The link state of one text's emit: where its records go, how far the culled-link walk
/// has reached, and the rings of its focused link.
const LinkEmit = struct {
    hit: HitPlace,
    clip: ?Rect,
    /// The first run `recordCulledLinks` has not yet passed.
    next_run: u32 = 0,
    focus: LinkFocus = .{},
};

/// The focused link's boxes in one text: one ring per drawn line, the union for reveal.
const LinkFocus = struct {
    bounds: Rect = undefined,
    segments: [link_ring_count_max]Rect = undefined,
    count: u8 = 0,

    fn add(self: *LinkFocus, box: Rect) void {
        assert(self.count <= link_ring_count_max);
        assert(box.width >= 0);
        self.bounds = if (self.count == 0) box else rectUnion(self.bounds, box);
        if (self.count < link_ring_count_max) {
            self.segments[self.count] = box;
            self.count += 1;
        } else {
            const last = link_ring_count_max - 1;
            self.segments[last] = rectUnion(self.segments[last], box);
        }
        assert(self.count > 0);
    }
};

fn rectUnion(a: Rect, b: Rect) Rect {
    assert(a.width >= 0);
    assert(b.width >= 0);
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(a.x + a.width, b.x + b.width);
    const bottom = @max(a.y + a.height, b.y + b.height);
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

const LinkPlace = enum { drawn, culled };

/// Records one box of a link. A drawn segment grows the link's accessibility bounds by its
/// part inside the clip. In a fragment that takes the pointer, the box is also a hit
/// record: `on_click` runs on a click, or on Return, Enter, or Space while focused. A drag
/// preview or tooltip gets no records, so its links cannot be clicked or focused.
fn recordLink(
    window: *Window,
    text: *const TextRuns,
    run_index: u32,
    box: Rect,
    place: LinkPlace,
) void {
    assert(text.paints[run_index].link);
    assert(box.width >= 0);
    const links = text.links;
    const link = text.link(window, run_index);
    const frame = window.built();
    const shown = if (links.clip) |rect| box.intersect(rect) else box;
    if (place == .drawn and shown.width > 0 and shown.height > 0 and link.a11y != index_none) {
        assert(link.a11y < frame.a11y_count);
        const node = &frame.a11y[link.a11y];
        assert(node.id == link.id);
        node.bounds = if (link.visible) rectUnion(node.bounds, shown) else shown;
        link.visible = true;
    }
    if (!links.hit.takes_pointer) return;
    assert(link.on_click < frame.handler_count);
    const hit = frame.appendHit(.{
        .id = link.id,
        .bounds = shown,
        .fragment = links.hit.fragment,
        .parent = links.hit.parent,
        .pointer = place == .drawn,
        .focusable = true,
        .tab_stop = link.hit == index_none,
        .scroll = false,
        .cursor = .pointer,
        .on_click = link.on_click,
        .on_click_outside = index_none,
        .on_context_menu = index_none,
        .on_key = index_none,
        .on_pointer_drag = index_none,
        .drag_type = 0,
        .drag_payload = 0,
        .drop_type = 0,
        .on_drop = index_none,
        .key_context = 0,
        .actions_start = 0,
        .actions_len = 0,
    });
    if (link.hit == index_none) link.hit = hit;
    if (window.focus_visible and window.isFocused(link.id)) links.focus.add(box);
}

/// The one implicit run of a plain text, held on `emitText`'s stack.
const PlainRun = struct {
    runs: [1]layout_mod.TextRun,
    paints: [1]window_mod.SpanPaint,
};

fn textRuns(
    window: *const Window,
    node: *const Node,
    data: *const TextData,
    plain: *PlainRun,
    links: *LinkEmit,
) TextRuns {
    const pitch = data.config.lineHeightPx();
    assert(pitch > 0);
    assert(data.text.len > 0);
    if (node.spans.len > 0) {
        assert(node.spans.len == data.runs_count);
        const runs = window.span_runs[node.spans.offset..][0..node.spans.len];
        layout_mod.types.assertRuns(runs, data.text.len);
        return .{
            .node = node,
            .data = data,
            .runs = runs,
            .paints = window.span_paints[node.spans.offset..][0..node.spans.len],
            .pitch = pitch,
            .links = links,
        };
    }
    assert(data.runs_count == 0);
    plain.* = .{
        .runs = .{.{
            .end = @intCast(data.text.len),
            .font_id = node.family.fontId(node.variant),
        }},
        .paints = .{.{
            .color = node.text_color,
            .background = null,
            .decoration = .none,
            .link = false,
        }},
    };
    return .{
        .node = node,
        .data = data,
        .runs = &plain.runs,
        .paints = &plain.paints,
        .pitch = pitch,
        .links = links,
    };
}

const TextRuns = struct {
    node: *const Node,
    data: *const TextData,
    runs: []const layout_mod.TextRun,
    paints: []const window_mod.SpanPaint,
    pitch: f32,
    links: *LinkEmit,

    /// The link of run `run_index`, a link span of this rich text.
    fn link(self: *const TextRuns, window: *Window, run_index: u32) *window_mod.SpanLink {
        assert(run_index < self.runs.len);
        assert(self.paints[run_index].link);
        const slot = self.node.spans.offset + run_index;
        assert(slot < window.span_count);
        return &window.span_links[slot];
    }

    fn fontsAt(self: *const TextRuns, start: u32) text_render.LineFonts {
        assert(start < self.data.text.len);
        const first = text_render.runAt(self.runs, start);
        assert(first < self.paints.len);
        return .{ .runs = self.runs, .start = start, .first = first };
    }

    fn baseline(self: *const TextRuns, window: *const Window, top: f32) f32 {
        const metrics = window.resources.text_system.getMetricsFor(self.node.family);
        const size: f32 = @floatFromInt(self.node.font_size);
        assert(size > 0);
        assert(metrics.point_size > 0);
        return top + metrics.ascender * size / metrics.point_size;
    }
};

const LineOrigin = struct { x: f32, y: f32 };

fn emitLine(
    window: *Window,
    text: *const TextRuns,
    content: []const u8,
    line: layout_mod.types.WrappedLine,
    origin: LineOrigin,
) void {
    assert(line.extent.length > 0);
    assert(line.start_offset <= content.len);
    assert(line.extent.length <= content.len - line.start_offset);
    const run = content[line.start_offset..][0..line.extent.length];
    _ = emitSegments(window, text, run, text.fontsAt(line.start_offset), .{
        .x = origin.x,
        .top = origin.y,
        .baseline = text.baseline(window, origin.y),
        .kept = @intCast(run.len),
    });
}

const CutPlace = struct { span: LineSpan, y: f32 };

/// Draws a line layout marked as cut: the cut is found by walking the line's segments in
/// their fonts, the kept segments are drawn, and the "…" takes the text's own style.
fn emitCutLine(
    window: *Window,
    text: *const TextRuns,
    content: []const u8,
    line: layout_mod.types.WrappedLine,
    place: CutPlace,
) void {
    assert(line.extent.end != .whole);
    assert(line.width >= 0);
    const node = text.node;
    const data = text.data;
    const run = content[line.start_offset..][0..line.extent.length];
    const fonts = text.fontsAt(line.start_offset);
    const measured = measureLineCut(window, text, &line);
    const cut = measured.cut;
    const widths = measured.widths;
    const marked = data.config.overflow == .ellipsis;
    const mark_width = measured.mark_width;
    const alignment = data.config.alignment;
    const baseline = text.baseline(window, place.y);
    const drawn = if (cut.whole) cut.width else cut.width + mark_width;
    const x = place.span.x + alignOffset(alignment, place.span.width, drawn);
    if (cut.whole) {
        const origin: SegmentOrigin = .{
            .x = x,
            .top = place.y,
            .baseline = baseline,
            .kept = @intCast(run.len),
        };
        _ = emitSegments(window, text, run, fonts, origin);
        return;
    }
    if (widths.kept_max < 0) return;
    assert(marked or line.extent.end == .cut_if_wide);
    assert(cut.length <= run.len);
    if (cut.length > 0) {
        const origin: SegmentOrigin = .{
            .x = x,
            .top = place.y,
            .baseline = baseline,
            .kept = cut.length,
        };
        const kept_width = emitSegments(window, text, run, fonts, origin);
        assert(@abs(kept_width - cut.width) <= 0.01 * @max(1, cut.width));
    }
    if (marked) {
        const style: TextStyle = .{
            .size = node.font_size,
            .color = node.text_color,
            .family = node.family,
            .variant = node.variant,
        };
        _ = emitTextBaseline(window, layout_mod.types.ellipsis, x + cut.width, baseline, style);
    }
}

const LineCut = struct { cut: text_render.Cut, widths: text_render.CutWidths, mark_width: f32 };

/// Where a line laid out as cut is cut: by walking its segments in their fonts, leaving
/// room for the "…" of an ellipsis text.
fn measureLineCut(window: *Window, text: *const TextRuns, line: *const WrappedLine) LineCut {
    assert(line.extent.end != .whole);
    assert(line.width >= 0);
    const data = text.data;
    const content = data.text;
    assert(line.start_offset <= content.len);
    assert(line.extent.length <= content.len - line.start_offset);
    const run = content[line.start_offset..][0..line.extent.length];
    const size: f32 = @floatFromInt(text.node.font_size);
    const marked = data.config.overflow == .ellipsis;
    if (marked) assert(data.ellipsis_width > 0);
    const mark_width = if (marked) data.ellipsis_width else 0;
    const widths: text_render.CutWidths = .{
        .kept_max = line.width - mark_width,
        .whole_max = if (line.extent.end == .cut_if_wide) line.width else -1,
    };
    const fonts = text.fontsAt(line.start_offset);
    const text_system = window.resources.text_system;
    const cut = text_render.measureCut(text_system, run, fonts, size, widths) catch |err|
        window_mod.textFailed(window, run, err);
    assert(cut.length <= run.len);
    return .{ .cut = cut, .widths = widths, .mark_width = mark_width };
}

const SegmentOrigin = struct { x: f32, top: f32, baseline: f32, kept: u32 };

/// Draws the first `origin.kept` bytes of a line, one segment per span it crosses, and
/// returns their advance. Each segment's glyphs are placed as `placeTextPrefix` places a
/// cut line, so a kept prefix lands exactly where `measureCut` measured it.
fn emitSegments(
    window: *Window,
    text: *const TextRuns,
    line_text: []const u8,
    fonts: text_render.LineFonts,
    origin: SegmentOrigin,
) f32 {
    assert(origin.kept > 0);
    assert(origin.kept <= line_text.len);
    var pen = origin.x;
    var offset: u32 = 0;
    var index = fonts.first;
    while (offset < origin.kept) : (index += 1) {
        assert(index < text.runs.len);
        const run = text.runs[index];
        assert(run.end > fonts.start + offset);
        const end: u32 = @intCast(@min(run.end - fonts.start, line_text.len));
        const kept = @min(end, origin.kept) - offset;
        const segment: Segment = .{
            .text = line_text[offset..end],
            .kept = kept,
            .font_id = run.font_id,
            .paint = &text.paints[index],
        };
        const width = emitSegment(window, text, &segment, .{
            .x = pen,
            .top = origin.top,
            .baseline = origin.baseline,
            .kept = kept,
        });
        if (segment.paint.link) {
            const box: Rect = .{ .x = pen, .y = origin.top, .width = width, .height = text.pitch };
            recordLink(window, text, index, box, .drawn);
        }
        pen += width;
        offset = end;
    }
    assert(offset >= origin.kept);
    assert(pen >= origin.x);
    return pen - origin.x;
}

const Segment = struct {
    text: []const u8,
    kept: u32,
    font_id: u16,
    paint: *const window_mod.SpanPaint,
};

fn emitSegment(
    window: *Window,
    text: *const TextRuns,
    segment: *const Segment,
    origin: SegmentOrigin,
) f32 {
    assert(segment.kept > 0);
    assert(segment.kept <= segment.text.len);
    const frame = window.built();
    const family = text_mod.FontFamily.fromFontId(segment.font_id);
    const variant = text_mod.FontFamily.variantFromFontId(segment.font_id);
    const size: f32 = @floatFromInt(text.node.font_size);
    assert(size > 0);
    // The background sits behind the glyphs, but its width is known only once they are
    // placed: append it first, then write the width the glyphs advanced.
    const background_index = frame.paint_count;
    if (segment.paint.background) |color| {
        const box: Rect = .{ .x = origin.x, .y = origin.top, .width = 0, .height = text.pitch };
        appendRect(frame, box, color);
    }
    var sink = GlyphSink{ .frame = frame, .color = segment.paint.color };
    const text_system = window.resources.text_system;
    const width = text_render.placeTextPrefix(
        text_system,
        segment.text,
        segment.kept,
        origin.x,
        origin.baseline,
        window.scale_factor,
        size,
        family,
        variant,
        &sink,
    ) catch |err| window_mod.textFailed(window, segment.text, err);
    assert(width >= 0);
    if (segment.paint.background != null) {
        assert(frame.paint[background_index] == .quad);
        frame.paint[background_index].quad.bounds.width = width;
    }
    const decoration = segment.paint.decoration;
    if (decoration.hasAny()) {
        // The base font's metrics, so every segment's line on a text line sits at one
        // height: a `.mono` word inside an underlined link does not step.
        const metrics = text_system.getMetricsFor(text.node.family);
        const scale = size / metrics.point_size;
        // At least 1 px: the font's thickness is clamped at its loaded size, and scaling
        // it to a smaller text would draw a line too faint to read.
        const thickness = @max(1, metrics.underline_thickness * scale);
        assert(thickness >= 1);
        const color = segment.paint.color;
        if (decoration.underline) {
            // Font metrics give the underline's position above the baseline, so it is
            // negative for an underline below it.
            const y = origin.baseline - metrics.underline_position * scale;
            appendRect(frame, decorationBox(origin.x, y, width, thickness), color);
        }
        if (decoration.strikethrough) {
            const y = origin.baseline - metrics.x_height * scale * 0.5 - thickness * 0.5;
            appendRect(frame, decorationBox(origin.x, y, width, thickness), color);
        }
    }
    return width;
}

fn decorationBox(x: f32, y: f32, width: f32, thickness: f32) Rect {
    assert(width >= 0);
    assert(thickness > 0);
    return .{ .x = x, .y = y, .width = width, .height = thickness };
}

fn appendRect(frame: *records.Frame, bounds: Rect, color: Color) void {
    assert(bounds.width >= 0);
    assert(bounds.height > 0);
    frame.appendPaint(.{ .quad = .{
        .bounds = bounds,
        .fill = color,
        .border = .none,
        .corners = .zero,
        .blur = 0,
    } });
}

fn lineBox(x: f32, y: f32, width: f32, height: f32) Rect {
    assert(width >= 0);
    assert(height > 0);
    const margin = height;
    return .{ .x = x - margin, .y = y - margin, .width = width + margin * 2, .height = height * 3 };
}

const LineRange = struct { start: u32, end: u32 };

fn linesInView(top: f32, pitch: f32, count: u32, clip: ?Rect) LineRange {
    assert(pitch > 0);
    const rect = clip orelse return .{ .start = 0, .end = count };
    const count_f: f32 = @floatFromInt(count);
    const first = std.math.clamp(@floor((rect.y - top) / pitch) - 1, 0, count_f);
    const last = std.math.clamp(@ceil((rect.y + rect.height - top) / pitch) + 1, first, count_f);
    const range = LineRange{ .start = @intFromFloat(first), .end = @intFromFloat(last) };
    assert(range.start <= range.end);
    assert(range.end <= count);
    return range;
}

const LineSpan = struct { x: f32, width: f32 };

fn lineSpan(data: *const TextData, bounds: Rect) LineSpan {
    assert(bounds.width >= 0);
    assert(data.container_width >= 0);
    if (data.config.alignment == .left) return .{ .x = bounds.x, .width = bounds.width };
    if (data.container_width > 0) {
        return .{ .x = data.container_x, .width = data.container_width };
    }
    return .{ .x = bounds.x, .width = bounds.width };
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

    pub fn glyph(self: *GlyphSink, placed: text_render.PlacedGlyph) void {
        assert(placed.width > 0);
        self.frame.appendPaint(.{ .sprite = .{
            .bounds = .{
                .x = placed.x,
                .y = placed.y,
                .width = placed.width,
                .height = placed.height,
            },
            .atlas = .glyph,
            .uv = .{
                .x = placed.uv_left,
                .y = placed.uv_top,
                .width = placed.uv_right - placed.uv_left,
                .height = placed.uv_bottom - placed.uv_top,
            },
            .tint = self.color,
            .secondary = Color.transparent,
            .corners = .zero,
            .grayscale = 0,
            .opacity = 1,
        } });
    }
};

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
    ) catch |err| window_mod.textFailed(window, content, err);
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

const circle_sides_max: u32 = 32;

fn circlePoints(
    points: *[3 * (circle_sides_max - 2)][2]f32,
    center: [2]f32,
    radius: f32,
    scale: f32,
) usize {
    assert(scale > 0);
    const sides = circleSides(radius * scale);
    const delta = std.math.tau / @as(f32, @floatFromInt(sides));
    var corner: u32 = 1;
    var count: usize = 0;
    while (corner + 1 < sides) : (corner += 1) {
        points[count] = .{ center[0] + radius, center[1] };
        points[count + 1] = circleCorner(center, radius, delta, corner);
        points[count + 2] = circleCorner(center, radius, delta, corner + 1);
        count += 3;
    }
    assert(count == 3 * (sides - 2));
    return count;
}

fn circleSides(screen_radius: f32) u32 {
    assert(screen_radius >= 0);
    const radius_below = [_]f32{ 2, 8, 32, 128 };
    const sides = [_]u32{ 4, 6, 12, 24 };
    for (radius_below, sides) |limit, count| {
        if (screen_radius < limit) return count;
    }
    return circle_sides_max;
}

fn circleCorner(center: [2]f32, radius: f32, delta: f32, corner: u32) [2]f32 {
    const angle = delta * @as(f32, @floatFromInt(corner));
    return .{ center[0] + radius * @cos(angle), center[1] + radius * @sin(angle) };
}

pub const triangle_points_max: u32 = limits_mod.MAX_PATH_VERTICES / 3 * 3;

fn emitTriangles(window: *Window, points: []const [2]f32, color: Color) void {
    if (points.len > triangle_points_max) {
        std.debug.panic("Painter.triangles of {d} points: capacity {d} per mesh, frame {d}. " ++
            "Split the fill.", .{ points.len, triangle_points_max, window.frame_number });
    }
    const frame = window.built();
    const count: u32 = @intCast(points.len);
    checkMeshPoints(window, .triangles, count);
    if (frame.paint_count > 0) {
        const last = &frame.paint[frame.paint_count - 1];
        if (last.* == .mesh) {
            const mesh = &last.mesh;
            const fill = records.fadeColor(color, frame.paint_opacity);
            const joins = mesh.topology == .triangles and colorEql(mesh.fill, fill) and
                mesh.range.first + mesh.range.count == frame.mesh_point_count and
                mesh.range.count + count <= triangle_points_max;
            if (joins) {
                const range = frame.claimMeshPoints(count);
                copyMeshPoints(frame.meshPoints(range), points);
                mesh.range.count += count;
                return;
            }
        }
    }
    const mesh_max = window.limits.paint.path_count_frame_max;
    assert(frame.triangle_mesh_count <= mesh_max);
    if (frame.triangle_mesh_count == mesh_max) {
        std.debug.panic("paint pool 'triangle meshes' exhausted: capacity {d}, {d} in use, " ++
            "1 requested, frame {d}. Raise ResourceLimits.paint.path_count_frame_max.", .{
            mesh_max, mesh_max, window.frame_number,
        });
    }
    frame.triangle_mesh_count += 1;
    const range = frame.claimMeshPoints(count);
    copyMeshPoints(frame.meshPoints(range), points);
    frame.appendPaint(.{ .mesh = .{
        .range = range,
        .topology = .triangles,
        .fill = color,
        .width = 0,
    } });
}

const PointMesh = struct { topology: records.Mesh.Topology, width: f32, color: Color };

fn emitPointMesh(window: *Window, points: []const [2]f32, mesh: PointMesh) void {
    assert(mesh.topology != .triangles);
    const count: u32 = @intCast(points.len);
    const width_max: f32 = switch (mesh.topology) {
        .strip_expanded => limits_mod.MAX_LINE_WIDTH,
        .point_instanced => limits_mod.MAX_POINT_RADIUS,
        .triangles => unreachable,
    };
    if (mesh.width > width_max) {
        std.debug.panic("Painter.{t} width {d} exceeds {d}, frame {d}", .{
            mesh.topology,
            mesh.width,
            width_max,
            window.frame_number,
        });
    }
    checkMeshPoints(window, mesh.topology, count);
    const frame = window.built();
    const range = frame.claimMeshPoints(count);
    copyMeshPoints(frame.meshPoints(range), points);
    frame.appendPaint(.{ .mesh = .{
        .range = range,
        .topology = mesh.topology,
        .fill = mesh.color,
        .width = mesh.width,
    } });
}

fn checkMeshPoints(window: *Window, topology: records.Mesh.Topology, count: u32) void {
    const paint_limits = &window.limits.paint;
    const capacity = switch (topology) {
        .triangles => paint_limits.path_vertex_count_frame_max,
        .strip_expanded => paint_limits.polyline_point_count_frame_max,
        .point_instanced => paint_limits.point_count_frame_max,
    };
    const name = switch (topology) {
        .triangles => "path_vertex_count_frame_max",
        .strip_expanded => "polyline_point_count_frame_max",
        .point_instanced => "point_count_frame_max",
    };
    const used = &window.built().mesh_point_counts[@backingInt(topology)];
    assert(used.* <= capacity);
    if (count > capacity - used.*) {
        std.debug.panic("mesh points exhausted: capacity {d} (paint.{s}), {d} in use, " ++
            "{d} requested, frame {d}. Raise the app's ResourceLimits.paint.{s}.", .{
            capacity, name, used.*, count, window.frame_number, name,
        });
    }
    used.* += count;
}

fn copyMeshPoints(target: []records.MeshPoint, source: []const [2]f32) void {
    assert(target.len == source.len);
    for (target, source) |*point, value| {
        assert(!std.math.isNan(value[0]) and !std.math.isNan(value[1]));
        point.* = .{ .x = value[0], .y = value[1] };
    }
}

fn colorEql(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn emitImage(window: *Window, path: []const u8, bounds: Rect, options: ImageStyle) void {
    assert(options.grayscale >= 0);
    assert(options.grayscale <= 1);
    assert(options.opacity >= 0);
    assert(options.opacity <= 1);
    if (bounds.width <= 0 or bounds.height <= 0) return;
    const key = images_mod.keyFor(path);
    const cached = window.resources.image_atlas.get(key) orelse {
        window.images.request(path, key, window.frame_number);
        return;
    };
    assert(cached.region.width > 0);
    const fit = ImageAtlas.calculateFitResult(
        @floatFromInt(cached.source_width),
        @floatFromInt(cached.source_height),
        bounds.width,
        bounds.height,
        options.fit,
    );
    const base = cached.uv();
    const uv_width = base.u1 - base.u0;
    const uv_height = base.v1 - base.v0;
    const scale = window.scale_factor;
    window.built().appendPaint(.{ .sprite = .{
        .bounds = .{
            .x = @floor((bounds.x + fit.offset_x) * scale) / scale,
            .y = @floor((bounds.y + fit.offset_y) * scale) / scale,
            .width = fit.width,
            .height = fit.height,
        },
        .atlas = .image,
        .uv = .{
            .x = base.u0 + fit.uv_left * uv_width,
            .y = base.v0 + fit.uv_top * uv_height,
            .width = (fit.uv_right - fit.uv_left) * uv_width,
            .height = (fit.uv_bottom - fit.uv_top) * uv_height,
        },
        .tint = options.tint orelse Color.white,
        .secondary = Color.transparent,
        .corners = options.corners,
        .grayscale = options.grayscale,
        .opacity = options.opacity,
    } });
}

comptime {
    assert(@sizeOf(a11y_types.State) == 2);
}
