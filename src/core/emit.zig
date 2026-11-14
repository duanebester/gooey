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
            window_mod.textFailed(self.window.frame_number, content, err);
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

    /// Fill a triangle list, three points per triangle, in window
    /// coordinates. A fill directly after another of the same colour joins
    /// its mesh, so a pie of many slivers packs as one path.
    pub fn triangles(self: *Painter, points: []const [2]f32, color: Color) void {
        assert(points.len > 0);
        assert(points.len % 3 == 0);
        emitTriangles(self.window, points, color);
    }

    /// A line `width` wide: an axis-aligned line is a quad, any other two
    /// triangles, as 0.3.1's canvas drew them.
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

    /// A filled circle of as many sides as its size on screen needs, as
    /// 0.3.1's `fillCircleAdaptive`: 4 below 2 px of radius, up to 32.
    pub fn circle(self: *Painter, center: [2]f32, radius: f32, color: Color) void {
        assert(radius >= 0);
        assert(!std.math.isNan(center[0]) and !std.math.isNan(center[1]));
        var points: [3 * (circle_sides_max - 2)][2]f32 = undefined;
        const count = circlePoints(&points, center, radius, self.window.scale_factor);
        self.triangles(points[0..count], color);
    }

    /// A polyline the GPU widens to `width`, one draw for every segment.
    pub fn polyline(self: *Painter, points: []const [2]f32, width: f32, color: Color) void {
        assert(points.len >= 2);
        assert(width > 0);
        emitPointMesh(self.window, points, .{
            .topology = .strip_expanded,
            .width = width,
            .color = color,
        });
    }

    /// Circles of one radius and colour at `centers`, drawn as instances.
    pub fn pointCloud(self: *Painter, centers: []const [2]f32, radius: f32, color: Color) void {
        assert(centers.len >= 1);
        assert(radius > 0);
        emitPointMesh(self.window, centers, .{
            .topology = .point_instanced,
            .width = radius,
            .color = color,
        });
    }

    /// Draw the image file at `path` into `bounds`, placed by `options.fit`.
    /// The first frame that draws a path queues its decode on the image
    /// worker and draws nothing, so the box's own background shows; the
    /// decoded image lands a few frames later and requests a render.
    pub fn image(self: *Painter, path: []const u8, bounds: Rect, options: ImageStyle) void {
        emitImage(self.window, path, bounds, options);
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

pub const ImageStyle = struct {
    fit: ObjectFit,
    corners: records.Corners = .zero,
    /// Multiplied with every pixel; null draws the image's own colours.
    tint: ?Color = null,
    /// 0 keeps colour, 1 is fully gray.
    grayscale: f32 = 0,
    opacity: f32 = 1,
};

/// The paint clip stack's ceiling; `limits.paint.clip_depth_max` bounds box
/// clips and paint-function clips together below it.
const clip_depth_max: u32 = limits_mod.MAX_CLIP_STACK_DEPTH;

pub fn emit(window: *Window) void {
    window.assertPhase(.emit);
    window.resources.svg_atlas.resetFrameBudget();
    // A decode that this frame's upload staging cannot take lands next frame.
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
    // A focus move this frame did not render reveals nothing later.
    window.focus_reveal = false;
}

/// Accessibility nodes in tree order, whatever fragment paints them, so a
/// popover's options sit under their combobox for the screen reader.
fn emitAccessibility(window: *Window) void {
    const elements = window.layout.elements.items();
    var a11y_level: [window_mod.box_depth_max + 1]u8 = undefined;
    for (window.nodes[0..window.node_count], 0..) |*node, index| {
        if (node.kind == .text) continue;
        const depth = node.depth;
        assert(depth <= window_mod.box_depth_max);
        const box = elements[index].computed.bounding_box;
        const bounds = Rect{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        const parent_level: u8 = if (depth == 0) 0 else a11y_level[depth - 1];
        a11y_level[depth] = parent_level + emitA11y(window, node, bounds, parent_level);
    }
}

/// Paint and hit records for one fragment: content from the root node, or a
/// layer's subtree from its box. A layer box met on the way opens a later
/// fragment, and its subtree is skipped here.
fn emitFragment(window: *Window, layers_open: *LayerQueue, root: *const LayerRoot) void {
    const elements = window.layout.elements.items();
    const nodes = window.nodes[0..window.node_count];
    const root_depth = nodes[root.node_index].depth;
    var hit_scope: [window_mod.box_depth_max + 1]u32 = undefined;
    var clips = Clips{ .entries = undefined, .len = 0, .base = root.clip };
    if (root.clip) |rect| window.built().appendPaint(.{ .clip_push = rect });
    if (root.fragment != layers.content_fragment) {
        if (nodes[root.node_index].layer.?.kind == .modal) blockEarlierHits(window.built());
    }
    var ring: ?FocusRing = null;
    var index = root.node_index;
    while (index < nodes.len) {
        const node = &nodes[index];
        const depth = node.depth;
        assert(depth <= window_mod.box_depth_max);
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
        switch (node.kind) {
            .box, .paint => {
                emitAppearance(window, node, bounds);
                const hit_bounds = clips.clipped(bounds);
                hit_scope[depth] = emitHit(window, node, hit_bounds, .{
                    .parent = parent_hit,
                    .fragment = root.fragment,
                });
                if (window.focus_visible and node.focusable and window.isFocused(node.id)) {
                    ring = focusRing(window, &clips, node, bounds);
                }
                if (node.kind == .paint) emitPaint(window, node, bounds, clips.paintDepth());
                if (node.clip) clips.open(window, node, index, bounds);
            },
            .text => emitText(window, node, bounds, &elements[index].text_data.?),
        }
        index += 1;
    }
    clips.close(window, 0);
    assert(clips.len == 0);
    // The focus ring is a keyboard affordance and draws at full strength
    // inside a faded subtree.
    window.built().paint_opacity = 1;
    if (ring) |focused| {
        if (window.focus_reveal or focusShifted(window, &focused)) revealFocus(window, &focused);
        window.focus_place = .{
            .id = window.focus,
            .frame_number = window.frame_number,
            .content = focused.content,
        };
        emitFocusRing(window, &focused, clips.paintDepth());
    }
    if (root.clip != null) window.built().appendPaint(.clip_pop);
}

/// The keyboard focus ring: `focus_ring_width` px wide and
/// `focus_ring_offset` px outside the focused box, in the theme's
/// `border_focus`, so it shows on any theme and on a box filled with
/// `primary`. Only keyboard focus draws it (`Window.focus_visible`).
const focus_ring_width: f32 = 2;
const focus_ring_offset: f32 = 2;
/// Room a revealed box keeps from its scroll box's edge, past its ring.
const focus_reveal_margin: f32 = 8;

/// The focused box, recorded as the fragment passes it, and the innermost
/// scroll box around it.
const FocusRing = struct {
    bounds: Rect,
    corners: records.Corners,
    clip: ?Rect,
    scroll: ?ScrollHandle,
    /// `Window.FocusPlace.content`: `bounds` in the scroll box's content.
    content: Rect,
};

const ScrollHandle = retained_mod.Handle(window_mod.ScrollState);

/// Read while the scroll box is open, so its offset is the one this
/// frame's layout applied; the emit may clamp it when the box closes.
fn focusRing(window: *Window, clips: *const Clips, node: *const Node, bounds: Rect) FocusRing {
    assert(window.isFocused(node.id));
    assert(window.focus_visible);
    var ring = FocusRing{
        .bounds = bounds,
        .corners = node.corners,
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

/// Whether the last build drew this ring elsewhere in its scroll box's
/// content: a layout change above or around the focused box, such as an
/// error message appearing, moved or resized it. A scroll does not.
fn focusShifted(window: *const Window, ring: *const FocusRing) bool {
    const place = &window.focus_place;
    assert(place.frame_number < window.frame_number);
    if (ring.scroll == null) return false;
    if (place.id != window.focus) return false;
    if (place.frame_number + 1 != window.frame_number) return false;
    return !std.meta.eql(place.content, ring.content);
}

/// Scroll the innermost scroll box around keyboard focus so the box and its
/// ring are in view: once per focus move, and again when a layout change
/// moves the box, but not after a wheel scrolled it away. The next frame
/// draws the new offset; outer scroll boxes stay put.
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

/// How far to scroll along one axis so `[start, start + size)` lies in the
/// view: to its start when above it or larger than it, else to its end.
fn revealDelta(view_start: f32, view_size: f32, start: f32, size: f32) f32 {
    assert(view_size >= 0);
    assert(size >= 0);
    if (start < view_start or size > view_size) return start - view_start;
    const overshoot = (start + size) - (view_start + view_size);
    return @max(0, overshoot);
}

/// Drawn after the rest of its fragment, so later siblings do not cover
/// it, inside the clip that encloses the box, so a scrolled-away box draws
/// none outside its viewport. One quad and at most one clip per frame.
fn emitFocusRing(window: *Window, ring: *const FocusRing, paint_depth: u32) void {
    assert(ring.bounds.width >= 0);
    assert(ring.bounds.height >= 0);
    const spread = focus_ring_offset + focus_ring_width;
    const corners = ring.corners;
    const frame = window.built();
    if (ring.clip) |clip| {
        checkClipDepth(window, paint_depth);
        frame.appendPaint(.{ .clip_push = clip });
    }
    frame.appendPaint(.{ .quad = .{
        .bounds = .{
            .x = ring.bounds.x - spread,
            .y = ring.bounds.y - spread,
            .width = ring.bounds.width + spread * 2,
            .height = ring.bounds.height + spread * 2,
        },
        .fill = Color.transparent,
        .border = .{ .width = focus_ring_width, .color = window.theme.border_focus },
        .corners = .{
            .top_left = corners.top_left + spread,
            .top_right = corners.top_right + spread,
            .bottom_right = corners.bottom_right + spread,
            .bottom_left = corners.bottom_left + spread,
        },
        .blur = 0,
    } });
    if (ring.clip != null) frame.appendPaint(.clip_pop);
}

/// A modal fragment starts here: hit tests stop at its first record, so
/// nothing emitted before it receives the pointer (contract §6).
fn blockEarlierHits(frame: *records.Frame) void {
    assert(frame.modal_hit_start <= frame.hit_count);
    frame.modal_hit_start = frame.hit_count;
    assert(frame.hit_count <= frame.hits.len);
}

/// The index after `index`'s subtree: in pre-order, the first later node no
/// deeper than it.
fn subtreeEnd(nodes: []const Node, index: u32) u32 {
    assert(index < nodes.len);
    const depth = nodes[index].depth;
    var end = index + 1;
    while (end < nodes.len and nodes[end].depth > depth) end += 1;
    assert(end > index);
    return end;
}

const layer_count_ceiling = limits_mod.layer_count_ceiling;

comptime {
    // Each layer box is a layout float.
    assert(layer_count_ceiling <= layout_mod.engine.MAX_FLOATING_ROOTS);
}

/// Where a fragment starts: its box, the hit record its hits bubble to, and
/// the clip it inherits (`Layer.clip = .inherit`), if any.
const LayerRoot = struct {
    node_index: u32,
    fragment: u8,
    parent_hit: u32,
    clip: ?Rect,
};

/// Layers opened and not yet emitted. Fragments follow in layer kind order,
/// then open order (contract §6), which is pre-order: the next fragment is
/// the lowest kind rank, then the lowest node index.
const LayerQueue = struct {
    roots: [layer_count_ceiling]LayerRoot,
    len: u32,
    /// Layers opened this frame, for `build.layer_count_frame_max`.
    opened: u32,

    fn open(self: *LayerQueue, window: *Window, index: u32, parent_hit: u32, clip: ?Rect) void {
        const layer = window.nodes[index].layer.?;
        assert(self.len <= self.opened);
        const opened_max = window.limits.build.layer_count_frame_max;
        assert(opened_max <= layer_count_ceiling);
        if (self.opened == opened_max) {
            std.debug.panic("layers exhausted: capacity {d}, frame {d}. Raise " ++
                "ResourceLimits.build.layer_count_frame_max.", .{
                opened_max,
                window.frame_number,
            });
        }
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

/// The open `Style.clip` and scroll boxes, innermost last. A box's clip
/// closes at the first later node no deeper than it, which in pre-order is
/// where its subtree ends. A scroll box also gathers its children's extent,
/// so the emit that draws it measures the content the router clamps to.
const Clips = struct {
    entries: [clip_depth_max]Entry,
    len: u32,
    /// The clip a layer fragment inherits, pushed before its entries.
    base: ?Rect,

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

    const Scroll = struct { handle: ScrollHandle, bounds: Rect };

    /// The innermost open scroll box's state and bounds, if any.
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

    /// Clips open on the paint clip stack, the inherited one included.
    fn paintDepth(self: *const Clips) u32 {
        assert(self.len <= clip_depth_max);
        return self.len + @intFromBool(self.base != null);
    }

    fn open(self: *Clips, window: *Window, node: *const Node, index: u32, bounds: Rect) void {
        assert(node.clip);
        assert(self.len <= clip_depth_max);
        checkClipDepth(window, self.paintDepth());
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
    const depth_max = window.limits.paint.clip_depth_max;
    assert(depth_max <= clip_depth_max);
    if (depth < depth_max) return;
    std.debug.panic("clip depth {d}: capacity {d} (frame {d}). Raise " ++
        "ResourceLimits.paint.clip_depth_max.", .{ depth + 1, depth_max, window.frame_number });
}

// 0.3.1's scroll container scrollbar colours (`widgets/scroll_container.zig`).
const scrollbar_room = window_mod.ScrollState.scrollbar_room;
const scrollbar_radius: f32 = 4;
const scrollbar_track_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.05 };
const scrollbar_thumb_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.3 };
const scrollbar_thumb_drag_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0.5 };

/// Record what this emit measured, clamp the offset to it, and draw the
/// scrollbars after the clipped content, as 0.3.1 does at `scissor_end`.
/// A clamp or an overflow change makes this frame's layout or clip stale,
/// and a resized viewport changes which rows a `List` builds, so each
/// requests one more render; steady content requests none.
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
    // The scrollbars fade with their scroll box, whatever node came last.
    window.built().paint_opacity = window.nodes[entry.node_index].opacity;
    inline for (.{ window_mod.ScrollAxis.y, window_mod.ScrollAxis.x }) |axis| {
        if (state.track(axis)) |bar| {
            const dragged = state.dragging == axis;
            emitScrollbar(window, bar, state.thumb(axis, bar), dragged);
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

/// `parent` is the nearest enclosing hit record: for a layer's box, the
/// opener's, so clicks inside a popover count as inside its opener.
const HitPlace = struct { parent: u32, fragment: u8 };

fn emitHit(window: *Window, node: *const Node, bounds: Rect, place: HitPlace) u32 {
    if (!node.hit) return place.parent;
    assert(node.id.isKeyed() or node.on_click != index_none or node.focusable or
        node.on_key != index_none or node.on_click_outside != index_none or
        node.key_context != 0 or node.actions_len > 0 or node.scroll != null or
        node.cursor != null);
    return window.built().appendHit(.{
        .id = node.id,
        .bounds = bounds,
        .fragment = place.fragment,
        .parent = place.parent,
        .pointer = node.pointer,
        .focusable = node.focusable,
        .tab_stop = node.tab_stop,
        .scroll = node.scroll != null,
        .cursor = node.cursor,
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
    });
    return 1;
}

/// `box_clip_depth` is the box clips already open around the element, which
/// share the paint clip stack with the paint function's own.
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
    ) catch |err| window_mod.textFailed(window.frame_number, content, err);
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

/// The most sides a circle gets, as 0.3.1's `Path.circleAdaptive`.
const circle_sides_max: u32 = 32;

/// Fan the circle's polygon from its first corner; returns the points used.
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

/// 0.3.1's thresholds: tiny circles are squares, then hexagons, then 12,
/// 24, and 32 sides as the radius on screen passes 8, 32, and 128 px.
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

/// The most points one triangle mesh holds: one path's vertex ceiling,
/// rounded down to whole triangles.
pub const triangle_points_max: u32 = limits_mod.MAX_PATH_VERTICES / 3 * 3;

fn emitTriangles(window: *Window, points: []const [2]f32, color: Color) void {
    if (points.len > triangle_points_max) {
        std.debug.panic("Painter.triangles of {d} points: capacity {d} per mesh, frame {d}. " ++
            "Split the fill.", .{ points.len, triangle_points_max, window.frame_number });
    }
    const frame = window.built();
    const count: u32 = @intCast(points.len);
    checkMeshPoints(window, .triangles, count);
    // Join the previous record when it is a triangle mesh of this colour
    // that ends where the pool ends and has room for these points.
    if (frame.paint_count > 0) {
        const last = &frame.paint[frame.paint_count - 1];
        if (last.* == .mesh) {
            const mesh = &last.mesh;
            // The record holds its colour faded (`records.fade`).
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
    // The width sanity bound (`limits.zig`); `checkMeshPoints` bounds the count.
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

/// The frame's points of one kind stay within that kind's paint limit, so
/// the renderer's geometry budget holds; one pool serves all three kinds.
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

/// Draw a cached image, or queue its decode and draw nothing. Placement
/// matches 0.3.1: fit inside `bounds`, then snap to the device pixel grid.
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
