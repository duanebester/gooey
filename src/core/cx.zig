const std = @import("std");
const id_mod = @import("id.zig");
const records = @import("records.zig");
const handler_mod = @import("handler.zig");
const element = @import("element.zig");
const retained = @import("retained.zig");
const text_engine = @import("text_engine.zig");
const window_mod = @import("window.zig");
const events = @import("events.zig");
const a11y_value = @import("a11y_value.zig");
const debugger = @import("debugger.zig");
const layout_mod = @import("../layout/layout.zig");
const text_mod = @import("../text/mod.zig");

const assert = std.debug.assert;

const text_name_bytes_max: usize = 32;

pub const ElementId = id_mod.ElementId;
pub const Key = id_mod.Key;
pub const Handler = handler_mod.Handler;
pub const Window = window_mod.Window;
const ResourceLimits = window_mod.ResourceLimits;
const Node = window_mod.Node;
const index_none = records.index_none;

pub fn Drag(comptime T: type) type {
    return struct {
        payload: T,
        over: ElementId,
        x: f32,
        y: f32,
        keyboard: bool,
    };
}

pub fn windowOf(cx: *const Cx) *Window {
    const window: *Window = @ptrCast(@alignCast(@constCast(cx)));
    assert(window.phase != .idle);
    return window;
}

pub fn of(window: *Window) *Cx {
    return @ptrCast(window);
}

pub const Cx = opaque {
    pub const ScrollPosition = struct {
        offset_x: f32,
        offset_y: f32,
        viewport: records.Rect,
        target: ?Target,
        at_end: bool,

        pub const Target = window_mod.ScrollState.Target;
    };

    pub fn state(self: *Cx, comptime T: type) *T {
        const store = windowOf(self).store;
        if (comptime std.debug.runtime_safety) {
            if (store.root_type_id != handler_mod.typeId(T)) {
                std.debug.panic("cx.state({s}): the root state is {s}", .{
                    @typeName(T),
                    handler_mod.typeName(store.root_type_id),
                });
            }
        }
        return @ptrCast(@alignCast(store.root_state));
    }

    pub fn theme(self: *const Cx) *const element.Theme {
        return windowOf(self).theme;
    }

    pub fn titleBarInset(self: *const Cx) events.TitleBar.Inset {
        const inset = windowOf(self).title_bar_inset;
        assert(inset.top >= 0);
        assert(inset.left >= 0);
        assert(inset.right >= 0);
        return inset;
    }

    pub fn fontMetrics(self: *const Cx) text_mod.Metrics {
        return windowOf(self).resources.text_system.getMetrics() orelse
            std.debug.panic("cx.fontMetrics: no font is loaded", .{});
    }

    pub fn id(self: *const Cx, key: Key) ElementId {
        const window = windowOf(self);
        window.assertPhase(.build);
        assert(window.open_depth > 0);
        const parent = window.nodes[window.open_stack[window.open_depth - 1]].id;
        return parent.child(key);
    }

    pub fn hovered(self: *const Cx, target: ElementId) bool {
        return windowOf(self).isHovered(target);
    }

    pub fn requestRenderAfter(self: *Cx, delay_ms: u32) void {
        const window = windowOf(self);
        window.assertPhase(.build);
        assert(delay_ms <= window_mod.render_delay_ms_max);
        const deadline = window.now_ns + @as(u64, delay_ms) * std.time.ns_per_ms;
        window.build_deadline_ns = @min(window.build_deadline_ns, deadline);
    }

    pub fn now(self: *const Cx) u64 {
        const window = windowOf(self);
        window.assertPhase(.build);
        return window.now_ns;
    }

    pub fn limits(self: *const Cx) *const ResourceLimits {
        const window = windowOf(self);
        assert(window.limits.build.element_count_frame_max > 0);
        return &window.limits;
    }

    pub fn bounds(self: *Cx, target: ElementId) ?records.Rect {
        assert(target.isKeyed());
        const window = windowOf(self);
        window.assertPhase(.build);
        const frame = window.rendered();
        if (frame.viewport_width != window.width) {
            self.requestRenderAfter(0);
        } else {
            if (frame.viewport_height != window.height) self.requestRenderAfter(0);
        }
        assert(frame.hit_count <= frame.hits.len);
        for (frame.hits[0..frame.hit_count]) |*hit| {
            if (hit.id == target) return hit.bounds;
        }
        return null;
    }

    pub fn scroll(self: *const Cx, target: ElementId) ?ScrollPosition {
        assert(target.isKeyed());
        const window = windowOf(self);
        window.assertPhase(.build);
        const retained_scroll = window.retained.find(window_mod.ScrollState, target) orelse
            return null;
        assert(retained_scroll.axes.x or retained_scroll.axes.y);
        assert(retained_scroll.offset_x >= 0);
        assert(retained_scroll.offset_y >= 0);
        return .{
            .offset_x = retained_scroll.offset_x,
            .offset_y = retained_scroll.offset_y,
            .viewport = retained_scroll.viewport,
            .target = retained_scroll.target,
            .at_end = retained_scroll.at_end,
        };
    }

    pub fn focused(self: *const Cx, target: ElementId) bool {
        return windowOf(self).isFocused(target);
    }

    pub fn focusVisibleWithin(self: *const Cx, target: ElementId) bool {
        windowOf(self).assertPhase(.build);
        return windowOf(self).isFocusVisibleWithin(target);
    }

    pub fn drag(self: *const Cx, comptime T: type) ?Drag(T) {
        const active = &windowOf(self).drag;
        if (active.phase != .active) return null;
        assert(active.type_id != 0);
        if (active.type_id != handler_mod.typeId(T)) return null;
        assert(std.math.isFinite(active.x));
        return .{
            .payload = handler_mod.unpackArg(T, active.payload),
            .over = active.over,
            .x = active.x,
            .y = active.y,
            .keyboard = active.keyboard,
        };
    }

    pub fn on(self: *Cx, comptime method: anytype, options: anytype) Handler {
        const handler = handler_mod.bind(method, options);
        if (comptime std.debug.runtime_safety) {
            const shape = comptime handler_mod.shapeOf(method);
            self.checkTarget(shape.State, handler, shape.name);
        }
        return handler;
    }

    fn checkTarget(self: *Cx, comptime State: type, handler: Handler, name: []const u8) void {
        const store = windowOf(self).store;
        const target = handler.target;
        if (target.isRoot()) {
            if (store.root_type_id == target.type_id) return;
            std.debug.panic("cx.on({s}): {s} is not the root state; the root state is {s}", .{
                name,
                handler_mod.typeName(target.type_id),
                handler_mod.typeName(store.root_type_id),
            });
        }
        const pool = store.findPool(target.type_id) orelse {
            if (comptime !retained.fitsSizeClass(State)) std.debug.panic(
                "cx.on({s}): {s} is neither an entity type nor retained state",
                .{ name, handler_mod.typeName(target.type_id) },
            );
            const handle = retained.Handle(State){
                .slot = target.slot,
                .generation = target.generation,
            };
            _ = windowOf(self).retained.get(State, handle);
            return;
        };
        if (target.slot < pool.generations.len) {
            if (pool.generations[target.slot] == target.generation) return;
        }
        std.debug.panic("cx.on({s}): entity slot {d} is stale", .{ name, target.slot });
    }

    pub fn retain(
        self: *Cx,
        comptime T: type,
        target: ElementId,
        lifetime: retained.Lifetime,
        comptime init: fn (value: *T) void,
    ) retained.Handle(T) {
        const window = windowOf(self);
        assert(window.phase == .build);
        if (T == text_engine.InputEngine) {
            return window.inputs.retain(target, lifetime, window.frame_number, init);
        }
        if (T == text_engine.AreaEngine) {
            return window.areaPool().retain(target, lifetime, window.frame_number, init);
        }
        if (T == text_engine.EditorEngine) {
            return window.editorPool().retain(target, lifetime, window.frame_number, init);
        }
        if (window.store.findPool(handler_mod.typeId(T)) != null) std.debug.panic(
            "cx.retain: {s} is an entity type; create it with effects.create",
            .{@typeName(T)},
        );
        return window.retained.retain(T, target, lifetime, init, window.frame_number);
    }

    pub fn get(self: *Cx, comptime T: type, handle: retained.Handle(T)) *T {
        const window = windowOf(self);
        assert(window.phase != .idle);
        if (T == text_engine.InputEngine) return window.inputs.get(handle);
        if (T == text_engine.AreaEngine) return window.areaPool().get(handle);
        if (T == text_engine.EditorEngine) return window.editorPool().get(handle);
        if (window.store.findPool(handler_mod.typeId(T))) |pool| {
            assert(pool.app_pool != null);
            const value = pool.checkedValue(handle.slot, handle.generation, "cx.get");
            return @ptrCast(@alignCast(value));
        }
        return window.retained.get(T, handle);
    }

    pub fn release(self: *Cx, comptime T: type, handle: retained.Handle(T)) void {
        assert(windowOf(self).phase != .idle);
        comptime assert(T != text_engine.InputEngine);
        comptime assert(T != text_engine.AreaEngine);
        comptime assert(T != text_engine.EditorEngine);
        windowOf(self).retained.release(T, handle);
    }

    pub fn render(self: *Cx, child: anytype) void {
        const window = windowOf(self);
        window.assertPhase(.build);
        window.component_depth += 1;
        defer window.component_depth -= 1;
        const depth_max = window.limits.build.component_depth_max;
        if (window.component_depth > depth_max) {
            std.debug.panic("component depth {d} exceeds build.component_depth_max {d} " ++
                "rendering {s}", .{ window.component_depth, depth_max, @typeName(@TypeOf(child)) });
        }
        noteDepth(window);
        self.renderChild(child);
    }

    fn renderChild(self: *Cx, child: anytype) void {
        const T = @TypeOf(child);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (comptime @hasDecl(T, "core_element")) {
                    self.renderElement(child);
                } else if (info.is_tuple) {
                    inline for (child) |item| self.renderChild(item);
                } else if (comptime @hasDecl(T, "render")) {
                    child.render(self);
                } else {
                    @compileError(nonChildMessage(T));
                }
            },
            .optional => if (child) |value| self.renderChild(value),
            .null => {},
            .array => for (child) |item| self.renderChild(item),
            .pointer => |pointer| {
                if (comptime pointer.child == u8 or isByteArray(pointer.child)) {
                    @compileError("a string is not a child; wrap it in ui.text(\"...\", .{})");
                }
                if (pointer.size != .slice) @compileError(nonChildMessage(T));
                for (child) |item| self.renderChild(item);
            },
            else => @compileError(nonChildMessage(T)),
        }
    }

    fn renderElement(self: *Cx, child: anytype) void {
        const T = @TypeOf(child);
        switch (T.core_element) {
            .box => self.buildBox(&child.box, child.children),
            .text => if (comptime @hasField(T, "spans"))
                self.buildRich(child.spans, &child.style)
            else
                self.buildText(child.content, &child.style),
            .paint => self.buildPaint(T.PaintData, child.data, child.paint_fn, &child.style),
            .when => if (child.condition) child.render_fn(self),
        }
    }

    fn buildBox(self: *Cx, box: *const element.Box, children: anytype) void {
        const window = windowOf(self);
        checkKeyed(window, box);
        const parent_index = window.open_stack[window.open_depth - 1];
        const box_id = resolveId(window, parent_index, box.key);
        const scroll_handle = retainScroll(window, box, box_id);
        const scroll_state: ?*const window_mod.ScrollState = if (scroll_handle) |handle|
            window.retained.get(window_mod.ScrollState, handle)
        else
            null;
        const index = openNodeWith(window, .box, box_id, &box.style, .{
            .scroll = scroll_state,
            .layer = box.layer,
        });
        if (box.key != null and box.layer == null) revealChild(window, parent_index, index, box_id);
        const node = window.node(index);
        const frame = window.built();
        node.scroll = scroll_handle;
        node.clip = box.style.clip == .clip or scroll_handle != null;
        node.layer = box.layer;
        node.focusable = box.focusable;
        node.tab_stop = box.focusable and box.tab_stop;
        node.on_click = handlerIndex(frame, box.on_click);
        node.on_click_outside = handlerIndex(frame, box.on_click_outside);
        node.on_context_menu = handlerIndex(frame, box.on_context_menu);
        node.on_key = handlerIndex(frame, box.on_key);
        node.on_pointer_drag = handlerIndex(frame, box.on_pointer_drag);
        if (box.draggable) |source| {
            assert(source.type_id != 0);
            node.drag_type = source.type_id;
            node.drag_payload = source.payload;
        }
        if (box.drop_target) |target| {
            assert(target.type_id != 0);
            node.drop_type = target.type_id;
            node.on_drop = frame.appendHandler(target.on_drop);
        }
        node.key_context = if (box.key_context) |key_context| key_context.hash else 0;
        node.actions_start = frame.handler_count;
        for (box.actions) |binding| _ = frame.appendAction(binding.action, binding.handler);
        node.actions_len = @intCast(box.actions.len);
        node.cursor = box.style.cursor;
        node.hit = box.key != null or scroll_handle != null or box.focusable or
            box.on_click != null or box.on_click_outside != null or box.on_key != null or
            box.on_context_menu != null or box.key_context != null or box.actions.len > 0 or box.style.cursor != null;
        if (box.a11y) |*a11y| {
            node.a11y = copyA11y(frame, a11y, window.limits.a11y.value_bytes_max);
        }
        resolveAppearance(window, node, &box.style);
        pushOpen(window, index);
        self.renderChild(children);
        popOpen(window, index);
    }

    fn buildText(self: *Cx, content: []const u8, style: *const element.Text) void {
        const window = windowOf(self);
        checkTextStyle(textName(content), style);
        const node = addTextNode(window, style);
        node.text = window.built().copyText(content);
        assert(node.text.len == content.len);
        assert(node.spans.len == 0);
        window.layout.text(content, textConfig(window, style)) catch |err| {
            layoutFailed(window, err);
        };
    }

    fn buildRich(self: *Cx, spans: []const element.Span, style: *const element.Text) void {
        const window = windowOf(self);
        const name = if (spans.len > 0) textName(spans[0].text) else "";
        checkTextStyle(name, style);
        checkSpans(window, spans, name);
        const node = addTextNode(window, style);
        const copied = stageSpans(window, spans, style);
        node.text = copied.text;
        node.spans = copied.spans;
        window.span_count += copied.spans.len;
        assert(node.spans.len <= spans.len);
        assert(node.spans.offset + node.spans.len == window.span_count);
        claimLinks(window, node, spans);
        const joined = window.built().text(node.text) orelse "";
        const runs = window.span_runs[node.spans.offset..][0..node.spans.len];
        const config = textConfig(window, style);
        window.layout.richText(joined, config, runs) catch |err| layoutFailed(window, err);
    }

    /// Adds a text node with its base style; the caller sets its bytes and spans.
    fn addTextNode(window: *Window, style: *const element.Text) *Node {
        const parent_index = window.open_stack[window.open_depth - 1];
        const size = style.size orelse window.theme.font_size_base;
        assert(size > 0);
        const index = addNode(window, .text, autoId(window, parent_index));
        const node = window.node(index);
        const color: element.ColorToken = style.color orelse .text;
        node.text_color = color.resolve(window.theme);
        node.font_size = size;
        node.family = style.family;
        node.variant = text_mod.FontVariant.init(style.weight, style.italic);
        assert(node.kind == .text);
        return node;
    }

    pub fn measureText(
        self: *Cx,
        content: []const u8,
        style: element.Text,
        max_width: f32,
    ) TextSize {
        const window = windowOf(self);
        window.assertPhase(.build);
        assert(content.len <= std.math.maxInt(u32));
        assert(std.math.isFinite(max_width));
        checkTextStyle(textName(content), &style);
        const text_hash = std.hash.Wyhash.hash(0, content);
        return measureCached(window, content, &.{}, &style, .{
            .text_hash = text_hash,
            .max_width = max_width,
        });
    }

    /// Sizes a `ui.rich` text as layout lays it out, for rows sized before they are built.
    /// Its spans pass through the frame's text bytes and span slots, which it gives back,
    /// so it needs the same room as building the text and claims none of it.
    pub fn measureRich(
        self: *Cx,
        spans: []const element.Span,
        style: element.Text,
        max_width: f32,
    ) TextSize {
        assert(std.math.isFinite(max_width));
        assert(max_width >= 0);
        const window = windowOf(self);
        window.assertPhase(.build);
        const name = if (spans.len > 0) textName(spans[0].text) else "";
        checkTextStyle(name, &style);
        checkSpans(window, spans, name);
        const frame = window.built();
        const text_len = frame.text_len;
        const staged = stageSpans(window, spans, &style);
        defer frame.text_len = text_len;
        const joined = frame.text(staged.text) orelse "";
        const runs = window.span_runs[staged.spans.offset..][0..staged.spans.len];
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(joined);
        for (runs) |run| {
            hasher.update(std.mem.asBytes(&run.end));
            hasher.update(std.mem.asBytes(&run.font_id));
        }
        const size = measureCached(window, joined, runs, &style, .{
            .text_hash = hasher.final(),
            .max_width = max_width,
        });
        assert(window.span_count == staged.spans.offset);
        assert(staged.spans.len <= spans.len);
        return size;
    }

    const MeasureKey = struct { text_hash: u64, max_width: f32 };

    /// Looks a text's size up in the text-size cache, measuring and storing it on a miss.
    /// `key.text_hash` covers the bytes and, for a rich text, its runs' fonts, so a restyle
    /// that changes widths misses and one that changes only colors hits.
    fn measureCached(
        window: *Window,
        content: []const u8,
        runs: []const layout_mod.TextRun,
        style: *const element.Text,
        key: MeasureKey,
    ) TextSize {
        assert(std.math.isFinite(key.max_width));
        assert(key.max_width >= 0);
        const config = textConfig(window, style);
        const text_system = window.resources.text_system;
        const cache_key: text_mod.TextSizeKey = .{
            .text_hash = key.text_hash,
            .text_len = @intCast(content.len),
            .max_width_bits = @bitCast(key.max_width),
            .style = @as(u64, config.font_id) | @as(u64, config.font_size) << 16 |
                @as(u64, config.line_height) << 32 |
                @as(u64, @backingInt(config.wrap_mode)) << 48 |
                @as(u64, config.line_count_max) << 50 |
                @as(u64, @backingInt(config.overflow)) << 58,
        };
        if (text_system.text_size_cache.get(cache_key)) |size| {
            return .{ .width = size[0], .height = size[1] };
        }
        const measured = window.layout.measureText(content, config, runs, key.max_width);
        assert(measured.width >= 0);
        assert(measured.height >= 0);
        text_system.text_size_cache.put(cache_key, measured.width, measured.height);
        return .{ .width = measured.width, .height = measured.height };
    }

    pub const TextSize = struct { width: f32, height: f32 };

    fn textConfig(window: *const Window, style: *const element.Text) layout_mod.TextConfig {
        const size = style.size orelse window.theme.font_size_base;
        assert(size > 0);
        const variant = text_mod.FontVariant.init(style.weight, style.italic);
        const metrics = window.resources.text_system.getMetricsFor(style.family);
        return .{
            .font_id = style.family.fontId(variant),
            .font_size = size,
            .line_height = lineHeightPercent(&metrics, style.line_height orelse 100),
            .wrap_mode = switch (style.wrap) {
                .none => .none,
                .words => .words,
                .newlines => .newlines,
            },
            .alignment = switch (style.alignment) {
                .left => .left,
                .center => .center,
                .right => .right,
            },
            .line_count_max = style.line_count_max orelse 0,
            .overflow = switch (style.overflow) {
                .clip => .clip,
                .ellipsis => .ellipsis,
            },
        };
    }

    fn checkTextStyle(name: []const u8, style: *const element.Text) void {
        assert(name.len <= text_name_bytes_max);
        const count = style.line_count_max orelse return;
        if (count == 0) {
            std.debug.panic("Text.line_count_max 0 (\"{s}\"): a text shows 1 to 255 lines", .{
                name,
            });
        }
        if (style.wrap == .none) {
            std.debug.panic("Text.line_count_max (\"{s}\"): a .none text is one line; " ++
                "wrap at .words or .newlines", .{name});
        }
        assert(count > 0);
        assert(style.wrap != .none);
    }

    fn textName(content: []const u8) []const u8 {
        const name = content[0..@min(content.len, text_name_bytes_max)];
        assert(name.len <= text_name_bytes_max);
        assert(name.len <= content.len);
        return name;
    }

    /// Checks a rich text before any of it is written: every span starts on a codepoint
    /// boundary (one byte per span, not a scan), and the frame has a slot for every
    /// non-empty span.
    fn checkSpans(window: *const Window, spans: []const element.Span, name: []const u8) void {
        assert(name.len <= text_name_bytes_max);
        assert(spans.len <= std.math.maxInt(u32));
        // Empty spans take no slot, but the walk over them is still bounded by the budget.
        const capacity: u32 = @intCast(window.span_runs.len);
        if (spans.len > capacity) {
            std.debug.panic("Text \"{s}\" has {d} spans; a text has at most {d}. Raise " ++
                "ResourceLimits.build.span_count_frame_max.", .{ name, spans.len, capacity });
        }
        var count: u32 = 0;
        for (spans, 0..) |span, span_index| {
            if (span.text.len == 0) {
                if (span.link != null) {
                    std.debug.panic("Span {d} of \"{s}\" is a link with no text; a link " ++
                        "needs bytes to click and to read", .{ span_index, name });
                }
                continue;
            }
            if (span.text[0] & 0xC0 == 0x80) {
                std.debug.panic("Span {d} of \"{s}\" starts inside a UTF-8 sequence; " ++
                    "a span starts on a codepoint boundary", .{ span_index, name });
            }
            count += 1;
        }
        assert(count <= spans.len);
        assert(window.span_count <= capacity);
        if (count > capacity - window.span_count) {
            std.debug.panic("build pool 'spans' exhausted: capacity {d}, {d} in use, {d} " ++
                "requested, frame {d}. Raise ResourceLimits.build.span_count_frame_max.", .{
                capacity,
                window.span_count,
                count,
                window.frame_number,
            });
        }
        assert(window.span_count + count <= capacity);
    }

    const CopiedSpans = struct { text: records.TextRange, spans: window_mod.SpanRange };

    /// Copies the spans' bytes back to back into the frame, so the text is one range, and
    /// writes one run and one paint per non-empty span past the claimed ones. The caller
    /// claims them (`buildRich`) or rolls them back (`measureRich`). `checkSpans` proved
    /// the room.
    fn stageSpans(
        window: *Window,
        spans: []const element.Span,
        style: *const element.Text,
    ) CopiedSpans {
        const frame = window.built();
        const start = window.span_count;
        const text_start = frame.text_len;
        var index = start;
        var end: u32 = 0;
        for (spans) |*span| {
            if (span.text.len == 0) continue;
            const range = frame.copyText(span.text);
            assert(range.offset == text_start + end);
            end += range.len;
            assert(index < window.span_runs.len);
            window.span_runs[index] = .{ .end = end, .font_id = spanFontId(span, style) };
            window.span_paints[index] = spanPaint(window.theme, span, style);
            index += 1;
        }
        const copied: CopiedSpans = .{
            .text = if (end == 0) .empty else .{ .offset = text_start, .len = end },
            .spans = .{ .offset = start, .len = index - start },
        };
        // `measureRich` writes these slots without claiming them; count them in the
        // high-water mark so release zeroes them too.
        window.span_count_used_max = @max(window.span_count_used_max, index);
        assert(copied.text.len == end);
        layout_mod.types.assertRuns(window.span_runs[start..index], end);
        return copied;
    }

    /// Gives each link span of a built text its id, handler, and href. Only `buildRich`
    /// calls this: `measureRich` stages spans it never claims, so it registers nothing.
    fn claimLinks(window: *Window, node: *const Node, spans: []const element.Span) void {
        assert(node.kind == .text);
        assert(node.spans.offset + node.spans.len <= window.span_count);
        const frame = window.built();
        var slot = node.spans.offset;
        for (spans, 0..) |*span, span_index| {
            if (span.text.len == 0) continue;
            assert(slot < node.spans.offset + node.spans.len);
            assert(window.span_paints[slot].link == (span.link != null));
            if (span.link) |*link| {
                window.span_links[slot] = .{
                    .id = linkId(window, node.id, link.key, @intCast(span_index)),
                    .on_click = frame.appendHandler(link.on_click),
                    .href = if (link.href) |href| frame.copyText(href) else .empty,
                    .a11y = index_none,
                    .hit = index_none,
                    .visible = false,
                };
            }
            slot += 1;
        }
        assert(slot == node.spans.offset + node.spans.len);
    }

    /// A link's id derives from its text's: a text has no children, so a link id cannot
    /// collide with a node's. A keyed link claims its key as a keyed box does.
    fn linkId(window: *Window, text_id: ElementId, key: ?Key, span_index: u32) ElementId {
        const given = key orelse return text_id.auto(span_index);
        const link_id = text_id.child(given);
        if (!window.keys.insert(link_id, window.frame_number)) {
            switch (given) {
                .name => |name| std.debug.panic("duplicate link key \"{s}\" in text {x}", .{
                    name,
                    @backingInt(text_id),
                }),
                .index => |value| std.debug.panic("duplicate link key {d} in text {x}", .{
                    value,
                    @backingInt(text_id),
                }),
            }
        }
        assert(link_id.isKeyed());
        return link_id;
    }

    fn spanFontId(span: *const element.Span, style: *const element.Text) u16 {
        assert(span.text.len > 0);
        const weight = span.weight orelse style.weight;
        const italic = span.italic orelse style.italic;
        const family = span.family orelse style.family;
        const font_id = family.fontId(text_mod.FontVariant.init(weight, italic));
        assert(font_id < text_mod.FontFamily.font_id_count);
        return font_id;
    }

    fn spanPaint(
        app_theme: *const element.Theme,
        span: *const element.Span,
        style: *const element.Text,
    ) window_mod.SpanPaint {
        assert(span.text.len > 0);
        const linked = span.link != null;
        const text_color: element.ColorToken = style.color orelse .text;
        const color: element.ColorToken = span.color orelse if (linked) .link else text_color;
        const background: ?records.Color = if (span.background) |token|
            token.resolve(app_theme)
        else
            null;
        const underlined = linked and !span.decoration.hasAny();
        const paint: window_mod.SpanPaint = .{
            .color = color.resolve(app_theme),
            .background = background,
            .decoration = if (underlined) .underlined else span.decoration,
            .link = linked,
        };
        assert(paint.color.a >= 0);
        return paint;
    }

    fn lineHeightPercent(metrics: *const text_mod.Metrics, font_percent: u16) u16 {
        assert(font_percent > 0);
        assert(metrics.point_size > 0);
        const ratio = metrics.line_height / metrics.point_size;
        assert(ratio > 0);
        const percent = @round(ratio * @as(f32, @floatFromInt(font_percent)));
        assert(percent >= 1);
        assert(percent <= std.math.maxInt(u16));
        return @intFromFloat(percent);
    }

    fn buildPaint(
        self: *Cx,
        comptime Data: type,
        data: *const Data,
        paint_fn: *const fn (data: *const Data, painter: *element.Painter) void,
        style: *const element.Style,
    ) void {
        const window = windowOf(self);
        const parent_index = window.open_stack[window.open_depth - 1];
        const index = openNode(window, .paint, autoId(window, parent_index), style);
        const node = window.node(index);
        resolveAppearance(window, node, style);
        node.paint_fn = @ptrCast(paint_fn);
        node.paint_data = @ptrCast(data);
        window.layout.closeElement();
    }
};

pub fn beginBuild(window: *Window) void {
    window.assertPhase(.build);
    window.node_count = 0;
    window.span_count_used_max = @max(window.span_count_used_max, window.span_count);
    window.span_count = 0;
    window.open_depth = 0;
    window.component_depth = 0;
    window.keys.clear();
    window.build_deadline_ns = window_mod.deadline_none;
    window.layout.beginFrame(window.width, window.height);
    window.layout.setMeasureTextFn(measureText, window);
    window.layout.setTextRuns(window.span_runs);
    const root_style = element.Style{
        .width = .{ .fixed = window.width },
        .height = .{ .fixed = window.height },
    };
    const index = openNode(window, .box, .root, &root_style);
    assert(index == 0);
    pushOpen(window, index);
}

pub fn endBuild(window: *Window) void {
    window.assertPhase(.build);
    assert(window.open_depth == 1);
    popOpen(window, 0);
    assert(window.component_depth == 0);
    window.render_deadline_ns = window.build_deadline_ns;
}

fn noteDepth(window: *Window) void {
    const address = @frameAddress();
    if (window.component_depth == 1) window.depth_base_address = address;
    if (window.component_depth > window.component_depth_peak) {
        window.component_depth_peak = window.component_depth;
        window.depth_peak_address = address;
        window.depth_peak_base_address = window.depth_base_address;
    }
}

fn copyA11y(
    frame: *records.Frame,
    a11y: *const element.A11y,
    value_bytes_max: u32,
) window_mod.A11yBuilt {
    if (a11y.range) |range| {
        assert(range.min <= range.max);
        assert(range.now >= range.min);
        assert(range.now <= range.max);
    }
    const value = a11y.value orelse "";
    if (a11y.selection) |selection| assert(selection.end <= value.len);
    const kept = a11y_value.window(value, a11y.selection, value_bytes_max);
    assert(kept.end - kept.start <= value_bytes_max);
    return .{
        .role = a11y.role,
        .label = frame.copyText(a11y.label orelse ""),
        .value = frame.copyText(value[kept.start..kept.end]),
        .selection = if (a11y.selection) |selection| a11y_value.relative(selection, kept) else null,
        .href = frame.copyText(a11y.href orelse ""),
        .description = frame.copyText(a11y.description orelse ""),
        .checked = a11y.checked,
        .selected = a11y.selected,
        .disabled = a11y.disabled,
        .expanded = a11y.expanded,
        .has_popup = a11y.has_popup,
        .heading_level = a11y.heading_level,
        .live = a11y.live,
        .pos_in_set = a11y.pos_in_set,
        .set_size = a11y.set_size,
        .range = a11y.range,
    };
}

fn checkKeyed(window: *const Window, box: *const element.Box) void {
    const message = gestureMisuse(box) orelse return;
    assert(message.len > 0);
    if (box.style.source) |source| {
        std.debug.panic("{s}: box at {s}:{d} in frame {d}", .{
            message,
            source.file,
            source.line,
            window.frame_number,
        });
    }
    std.debug.panic("{s}: in frame {d} (set Style.source = @src() to locate the box)", .{
        message,
        window.frame_number,
    });
}

fn gestureMisuse(box: *const element.Box) ?[]const u8 {
    if (box.draggable != null and box.on_pointer_drag != null) {
        return "Box.draggable and Box.on_pointer_drag on one box; a press starts one " ++
            "gesture (contract §5)";
    }
    if (box.key != null) return null;
    if (box.on_pointer_drag != null) return "Box.on_pointer_drag needs a key (contract §5)";
    if (box.draggable != null) return "Box.draggable needs a key (contract §5)";
    if (box.drop_target != null) return "Box.drop_target needs a key (contract §5)";
    return null;
}

fn resolveId(window: *Window, parent_index: u32, key: ?Key) ElementId {
    const parent = window.nodes[parent_index].id;
    const given = key orelse return autoId(window, parent_index);
    const child_id = parent.child(given);
    if (!window.keys.insert(child_id, window.frame_number)) {
        switch (given) {
            .name => |name| std.debug.panic("duplicate key \"{s}\" under element {x}", .{
                name,
                @backingInt(parent),
            }),
            .index => |value| std.debug.panic("duplicate key {d} under element {x}", .{
                value,
                @backingInt(parent),
            }),
        }
    }
    return child_id;
}

fn autoId(window: *Window, parent_index: u32) ElementId {
    const parent = &window.nodes[parent_index];
    const auto_id = parent.id.auto(parent.child_count);
    return auto_id;
}

fn addNode(window: *Window, kind: window_mod.NodeKind, node_id: ElementId) u32 {
    if (window.node_count == window.nodes.len) {
        std.debug.panic("build pool 'elements' exhausted: capacity {d}, {d} in use, 1 " ++
            "requested, frame {d}. Raise ResourceLimits.build.element_count_frame_max.", .{
            window.nodes.len - 1,
            window.node_count - 1,
            window.frame_number,
        });
    }
    const index = window.node_count;
    const parent: u32 =
        if (window.open_depth > 0) window.open_stack[window.open_depth - 1] else index_none;
    if (parent != index_none) window.nodes[parent].child_count += 1;
    const opacity: f32 = if (parent != index_none) window.nodes[parent].opacity else 1;
    assert(opacity >= 0);
    assert(opacity <= 1);
    window.nodes[index] = .{
        .kind = kind,
        .id = node_id,
        .parent = parent,
        .depth = @intCast(window.open_depth),
        .child_count = 0,
        .focusable = false,
        .tab_stop = false,
        .hit = false,
        .pointer = true,
        .opacity = opacity,
        .cursor = null,
        .on_click = index_none,
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
        .a11y = null,
        .background = null,
        .fill = null,
        .border = .none,
        .corners = .zero,
        .shadow = null,
        .shadow_color = records.Color.transparent,
        .text = .empty,
        .spans = .empty,
        .text_color = records.Color.transparent,
        .font_size = 0,
        .family = .app,
        .variant = .regular,
        .paint_fn = null,
        .paint_data = null,
        .clip = false,
        .scroll = null,
        .layer = null,
        .source = debugger.node_source_none,
    };
    window.node_count += 1;
    return index;
}

fn openNode(
    window: *Window,
    kind: window_mod.NodeKind,
    node_id: ElementId,
    style: *const element.Style,
) u32 {
    assert(style.scroll == null);
    return openNodeWith(window, kind, node_id, style, .{ .scroll = null, .layer = null });
}

const OpenOptions = struct {
    scroll: ?*const window_mod.ScrollState,
    layer: ?element.Layer,
};

fn openNodeWith(
    window: *Window,
    kind: window_mod.NodeKind,
    node_id: ElementId,
    style: *const element.Style,
    options: OpenOptions,
) u32 {
    if (style.scroll != null) assert(options.scroll != null);
    checkBoxDepth(window);
    const index = addNode(window, kind, node_id);
    const node = &window.nodes[index];
    node.source = debugger.nodeSource(style.source);
    node.opacity *= styleOpacity(window, style.opacity);
    node.pointer = style.pointer_events == .auto;
    var decl = declaration(style);
    if (style.scroll) |axes| decl.scroll = .{
        .horizontal = axes.x,
        .vertical = axes.y,
        .scroll_offset = .{ .x = options.scroll.?.offset_x, .y = options.scroll.?.offset_y },
        .target = scrollTarget(options.scroll.?),
    };
    if (options.layer) |layer| decl.floating = floating(layer.anchor);
    var tracks: GridTracks = undefined;
    const grid_config = if (style.grid) |*grid| gridConfig(grid, style.gap, &tracks) else null;
    const cell: layout_mod.Cell = .{
        .column = style.cell.column orelse layout_mod.types.cell_column_auto,
        .column_span = style.cell.column_span,
    };
    window.layout.openElementWith(decl, .{
        .grid = if (grid_config) |*config| config else null,
        .cell = cell,
    }) catch |err| layoutFailed(window, err);
    return index;
}

fn scrollTarget(state: *const window_mod.ScrollState) layout_mod.ScrollTarget {
    if (state.target) |target| return switch (target) {
        .start => .start,
        .end => .end,
        .offset => |offset| .{ .offset = .{ .x = offset.x, .y = offset.y } },
        .child => .none,
    };
    if (state.followsEnd()) return .end;
    return .none;
}

fn revealChild(window: *Window, parent_index: u32, index: u32, box_id: ElementId) void {
    assert(parent_index < index);
    const handle = window.nodes[parent_index].scroll orelse return;
    const state = window.retained.get(window_mod.ScrollState, handle);
    const target = state.target orelse return;
    if (target != .child) return;
    if (target.child.id != box_id) return;
    const alignment: layout_mod.ScrollAlignment = switch (target.child.alignment) {
        inline else => |value| @field(layout_mod.ScrollAlignment, @tagName(value)),
    };
    const parent = window.layout.elements.get(parent_index);
    parent.config.scroll.?.target = .{ .child = .{ .index = index, .alignment = alignment } };
}

fn floating(anchor: element.Anchor) layout_mod.FloatingConfig {
    const config: layout_mod.FloatingConfig = switch (anchor) {
        .parent => |offset| .{
            .offset = .{ .x = offset.x, .y = offset.y },
            .attach_to_parent = true,
            .element_attach = .left_top,
            .parent_attach = .left_top,
        },
        .window => |offset| .{
            .offset = .{ .x = offset.x, .y = offset.y },
            .attach_to_parent = false,
            .element_attach = .left_top,
            .parent_attach = .left_top,
        },
    };
    assert(config.element_attach == .left_top);
    return config;
}

fn retainScroll(
    window: *Window,
    box: *const element.Box,
    box_id: ElementId,
) ?retained.Handle(window_mod.ScrollState) {
    const axes = box.style.scroll orelse return null;
    if (box.key == null) {
        std.debug.panic("Style.scroll needs a key: its offset is retained by the box's key " ++
            "(frame {d})", .{window.frame_number});
    }
    assert(axes.x or axes.y);
    const handle = window.retained.retain(
        window_mod.ScrollState,
        box_id,
        .frame,
        window_mod.ScrollState.init,
        window.frame_number,
    );
    const state = window.retained.get(window_mod.ScrollState, handle);
    state.axes = axes;
    _ = state.clamp();
    return handle;
}

fn checkBoxDepth(window: *Window) void {
    const depth_max = window.limits.build.box_depth_max;
    assert(depth_max == window.open_stack.len);
    assert(window.open_depth <= depth_max);
    if (window.open_depth < depth_max) return;
    std.debug.panic("build pool 'box depth' exhausted: capacity {d}, {d} in use, 1 " ++
        "requested, frame {d}. Raise ResourceLimits.build.box_depth_max.", .{
        depth_max,
        window.open_depth,
        window.frame_number,
    });
}

fn pushOpen(window: *Window, index: u32) void {
    assert(window.open_depth < window.open_stack.len);
    assert(index < window.node_count);
    window.open_stack[window.open_depth] = index;
    window.open_depth += 1;
}

fn popOpen(window: *Window, index: u32) void {
    assert(window.open_depth > 0);
    assert(window.open_stack[window.open_depth - 1] == index);
    window.open_depth -= 1;
    window.layout.closeElement();
}

fn handlerIndex(frame: *records.Frame, handler: ?Handler) u32 {
    const value = handler orelse return index_none;
    return frame.appendHandler(value);
}

fn styleOpacity(window: *const Window, opacity: f32) f32 {
    if (opacity >= 0 and opacity <= 1) return opacity;
    std.debug.panic("Style.opacity {d} is outside 0 to 1 (frame {d})", .{
        opacity,
        window.frame_number,
    });
}

fn resolveAppearance(window: *Window, node: *Node, style: *const element.Style) void {
    const theme = window.theme;
    if (style.background) |background| node.background = background.resolve(theme);
    if (style.fill) |*fill| resolveFill(window, node, fill, style.background != null);
    if (style.border) |border| {
        assert(border.width >= 0);
        node.border = .{ .width = border.width, .color = border.color.resolve(theme) };
    }
    node.corners = style.corner_radius;
    if (style.shadow) |shadow| {
        node.shadow = shadow;
        node.shadow_color = shadow.color.resolve(theme);
    }
}

fn resolveFill(window: *Window, node: *Node, fill: *const element.Fill, has_background: bool) void {
    assert(node.fill == null);
    if (has_background) {
        std.debug.panic("Style sets both .background and .fill (shader \"{s}\", frame {d}); " ++
            ".fill replaces .background, so set one.", .{ fill.spec.name, window.frame_number });
    }
    const shader = window.shaderId(fill.spec);
    const slot = window.built().claimParams(fill.paramsBytes());
    node.fill = .{ .shader = shader, .params_slot = slot };
    if (fill.spec.animated) {
        window.build_deadline_ns = @min(window.build_deadline_ns, window.now_ns);
    }
    assert(node.fill.?.shader < window.shaders.len);
}

fn layoutFailed(window: *const Window, err: anyerror) noreturn {
    std.debug.panic("layout failed in frame {d}: {s}", .{ window.frame_number, @errorName(err) });
}

fn measureText(
    content: []const u8,
    font_id: u16,
    font_size: u16,
    max_width: ?f32,
    user_data: ?*anyopaque,
) layout_mod.engine.TextMeasurement {
    _ = max_width;
    const window: *const Window = @ptrCast(@alignCast(user_data.?));
    const text_system = window.resources.text_system;
    if (text_system.getMetrics() == null) std.debug.panic("no font loaded", .{});
    assert(font_size > 0);
    const family = text_mod.FontFamily.fromFontId(font_id);
    const variant = text_mod.FontFamily.variantFromFontId(font_id);
    const metrics = text_system.getMetricsFor(family);
    const scale = @as(f32, @floatFromInt(font_size)) / metrics.point_size;
    const width = text_system.measureText(family, content, variant) catch |err| {
        window_mod.textFailed(window, content, err);
    };
    return .{ .width = width * scale, .height = metrics.line_height * scale };
}

fn declaration(style: *const element.Style) layout_mod.ElementDeclaration {
    const grid_role = gridRole(style);
    const flow_direction: element.Direction = if (grid_role == .none) style.direction else .row;
    const direction: layout_mod.LayoutDirection = switch (flow_direction) {
        .row => .left_to_right,
        .column => .top_to_bottom,
    };
    var decl: layout_mod.ElementDeclaration = .{
        .layout = .{
            .sizing = .{
                .width = sizingAxis(style.width, style.width_min, style.width_max),
                .height = sizingAxis(style.height, style.height_min, style.height_max),
            },
            .padding = .{
                .left = pixels(style.padding.left),
                .right = pixels(style.padding.right),
                .top = pixels(style.padding.top),
                .bottom = pixels(style.padding.bottom),
            },
            .child_gap = pixels(style.gap),
            .child_alignment = childAlignment(flow_direction, style.alignment),
            .layout_direction = direction,
            .main_axis_distribution = switch (style.alignment.main) {
                inline else => |tag| @field(layout_mod.MainAxisDistribution, @tagName(tag)),
            },
            .aspect_ratio = aspectRatio(style),
            .wrap = wrapsRow(style),
            .grid = grid_role,
        },
    };
    if (decl.layout.aspect_ratio) |ratio| {
        if (style.width == .fixed) decl.layout.sizing.height = .fixed(style.width.fixed / ratio);
    }
    return decl;
}

fn gridRole(style: *const element.Style) layout_mod.GridRole {
    if (style.cell.row) {
        if (style.grid != null) {
            std.debug.panic("Cell.row: a row box spans every column and holds only " ++
                "cells; it cannot be a grid of its own", .{});
        }
        return .row;
    }
    return if (style.grid != null) .grid else .none;
}

fn gridTrack(track: element.Track, index: usize) layout_mod.Track {
    if (!(track.min >= 0 and track.min <= track.max) or std.math.isNan(track.max)) {
        std.debug.panic("Grid track {d}: min {d} and max {d} must satisfy 0 <= min <= max", .{
            index,
            track.min,
            track.max,
        });
    }
    const axis: layout_mod.SizingAxis = switch (track.sizing) {
        .fit => layout_mod.SizingAxis.fitMinMax(track.min, track.max),
        .grow => |weight| blk: {
            if (!(weight > 0 and std.math.isFinite(weight))) {
                std.debug.panic("Grid track {d}: a grow weight must be finite and greater " ++
                    "than 0, not {d}", .{ index, weight });
            }
            break :blk layout_mod.SizingAxis.growWeighted(weight, track.min, track.max);
        },
        .fixed => |size| blk: {
            if (!(size >= 0 and std.math.isFinite(size))) {
                std.debug.panic("Grid track {d}: a fixed size must be finite and at least 0, " ++
                    "not {d}", .{ index, size });
            }
            break :blk layout_mod.SizingAxis.fixed(std.math.clamp(size, track.min, track.max));
        },
        .percent => |fraction| blk: {
            if (!(fraction >= 0 and fraction <= 1)) {
                std.debug.panic("Grid track {d}: a percent is between 0 and 1, not {d}", .{
                    index,
                    fraction,
                });
            }
            var percent = layout_mod.SizingAxis.percent(fraction);
            percent.value.percent.min = track.min;
            percent.value.percent.max = track.max;
            break :blk percent;
        },
    };
    const alignment: layout_mod.TrackAlignment = if (track.cell_alignment) |cross| switch (cross) {
        inline else => |tag| @field(layout_mod.TrackAlignment, @tagName(tag)),
    } else .auto;
    return .{ .axis = axis, .alignment = alignment };
}

const GridTracks = struct {
    columns: [element.grid_track_count_max]layout_mod.Track,
    rows: [element.grid_track_count_max]layout_mod.Track,
};

fn gridConfig(
    grid: *const element.Grid,
    gap: f32,
    tracks: *GridTracks,
) layout_mod.GridConfig {
    comptime assert(element.grid_track_count_max == layout_mod.types.grid_track_count_max);
    if (grid.columns.len == 0 or grid.columns.len > element.grid_track_count_max) {
        std.debug.panic("Grid.columns: {d} columns; a grid has 1 to {d}", .{
            grid.columns.len,
            element.grid_track_count_max,
        });
    }
    if (grid.rows.len > element.grid_track_count_max) {
        std.debug.panic("Grid.rows: {d} rows; a grid lists at most {d}", .{
            grid.rows.len,
            element.grid_track_count_max,
        });
    }
    for (grid.columns, 0..) |track, index| tracks.columns[index] = gridTrack(track, index);
    for (grid.rows, 0..) |track, index| tracks.rows[index] = gridTrack(track, index);
    const row_gap = grid.row_gap orelse gap;
    assert(row_gap >= 0);
    return .{
        .columns = tracks.columns[0..grid.columns.len],
        .rows = tracks.rows[0..grid.rows.len],
        .row_implicit = gridTrack(grid.row_implicit, grid.rows.len),
        .row_gap = row_gap,
    };
}

fn aspectRatio(style: *const element.Style) ?f32 {
    const ratio = style.aspect_ratio orelse return null;
    if (!(ratio > 0 and std.math.isFinite(ratio))) {
        std.debug.panic("Style.aspect_ratio {d}: a ratio must be finite and greater than 0", .{
            ratio,
        });
    }
    const height_free = style.height == .fit and style.height_min == null and
        style.height_max == null;
    if (!height_free) {
        std.debug.panic("Style.aspect_ratio: the height follows the width, so `height` " ++
            "must be .fit, with no height_min or height_max", .{});
    }
    return ratio;
}

fn wrapsRow(style: *const element.Style) bool {
    if (!style.wrap) return false;
    if (style.direction != .row) {
        std.debug.panic("Style.wrap: only a .row wraps; a .column cannot", .{});
    }
    return true;
}

fn sizingAxis(sizing: element.Sizing, min: ?f32, max: ?f32) layout_mod.SizingAxis {
    const bounded = min != null or max != null;
    return switch (sizing) {
        .fit => if (bounded)
            layout_mod.SizingAxis.fitMinMax(min orelse 0, max orelse std.math.floatMax(f32))
        else
            layout_mod.SizingAxis.fit(),
        .grow => |weight| blk: {
            if (!(weight > 0 and std.math.isFinite(weight))) {
                std.debug.panic("Sizing.grow weight {d}: a weight must be finite and " ++
                    "greater than 0", .{weight});
            }
            const grow_max = max orelse std.math.floatMax(f32);
            break :blk layout_mod.SizingAxis.growWeighted(weight, min orelse 0, grow_max);
        },
        .fixed => |size| blk: {
            assert(!bounded);
            assert(size >= 0);
            break :blk layout_mod.SizingAxis.fixed(size);
        },
        .percent => |fraction| blk: {
            assert(fraction >= 0);
            assert(fraction <= 1);
            break :blk layout_mod.SizingAxis.percent(fraction);
        },
    };
}

fn childAlignment(
    direction: element.Direction,
    alignment: element.Alignment,
) layout_mod.ChildAlignment {
    const main_x: layout_mod.AlignmentX = switch (alignment.main) {
        .center => .center,
        .end => .right,
        else => .left,
    };
    const main_y: layout_mod.AlignmentY = switch (alignment.main) {
        .center => .center,
        .end => .bottom,
        else => .top,
    };
    const cross_x: layout_mod.AlignmentX = switch (alignment.cross) {
        .start => .left,
        .center => .center,
        .end => .right,
    };
    const cross_y: layout_mod.AlignmentY = switch (alignment.cross) {
        .start => .top,
        .center => .center,
        .end => .bottom,
    };
    return switch (direction) {
        .row => .{ .x = main_x, .y = cross_y },
        .column => .{ .x = cross_x, .y = main_y },
    };
}

fn pixels(value: f32) u16 {
    assert(value >= 0);
    assert(value <= std.math.maxInt(u16));
    return @intFromFloat(value);
}

fn isByteArray(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .array and info.array.child == u8;
}

fn nonChildMessage(comptime T: type) []const u8 {
    return "cannot render " ++ @typeName(T) ++ " as a child: children are ui.box, ui.text, " ++
        "ui.paint, ui.when, components (structs with pub fn render(self, cx: *Cx) void), " ++
        "tuples, optionals, and arrays or slices of components";
}
