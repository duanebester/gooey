//! One untyped `Cx` serves every app; the build turns each element into one
//! layout element and one node in pre-order, so node `i` is layout element `i`.

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

pub const ElementId = id_mod.ElementId;
pub const Key = id_mod.Key;
pub const Handler = handler_mod.Handler;
pub const Window = window_mod.Window;
const ResourceLimits = window_mod.ResourceLimits;
const Node = window_mod.Node;
const index_none = records.index_none;

/// What `Cx.drag` reports about a drag in progress.
pub fn Drag(comptime T: type) type {
    return struct {
        payload: T,
        /// The drop target of this payload type under the pointer, or
        /// `.root` over none.
        over: ElementId,
        /// The pointer, in window coordinates; it may lie outside the window.
        /// In a keyboard drag, the centre of `over`, or of the source over
        /// none, so a preview placed here follows the keys.
        x: f32,
        y: f32,
        /// Started by `effects.startDrag`, not by the pointer.
        keyboard: bool,
    };
}

/// A `*Cx` is the window's address under an opaque type, so an app or
/// component holding one reaches only `Cx`'s methods.
pub fn windowOf(cx: *const Cx) *Window {
    const window: *Window = @ptrCast(@alignCast(@constCast(cx)));
    assert(window.phase != .idle);
    return window;
}

pub fn of(window: *Window) *Cx {
    return @ptrCast(window);
}

/// Opaque, so the window behind it stays internal: what an app or component
/// reads during a build is these methods.
pub const Cx = opaque {
    pub const ScrollPosition = struct {
        /// How far the content is scrolled, in pixels from its start.
        offset_x: f32,
        offset_y: f32,
        /// The box's bounds at the last emit, unclipped; zero before its first.
        viewport: records.Rect,
        /// An `Effects.scrollTo` this build's layout will resolve, with a
        /// child's key resolved to its id and an index key kept, so a
        /// windowed list builds the row it names.
        target: ?Target,
        /// The offset rests at the content's end; a box anchored `.end`
        /// follows the end while this holds. True before the first emit.
        at_end: bool,

        pub const Target = window_mod.ScrollState.Target;
    };

    /// The app's root state. In Debug and ReleaseSafe a wrong `T` panics on
    /// the first frame.
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

    /// The window controls a transparent title bar draws over the content
    /// (`Config.title_bar`), so the app can keep its own controls clear of
    /// them and line them up with the traffic lights. All zero for a
    /// standard title bar, off macOS, and in full screen.
    pub fn titleBarInset(self: *const Cx) events.TitleBar.Inset {
        const inset = windowOf(self).title_bar_inset;
        assert(inset.top >= 0);
        assert(inset.left >= 0);
        assert(inset.right >= 0);
        return inset;
    }

    /// The text system's base font metrics, for components that size boxes
    /// around a line of text.
    pub fn fontMetrics(self: *const Cx) text_mod.Metrics {
        return windowOf(self).resources.text_system.getMetrics() orelse
            std.debug.panic("cx.fontMetrics: no font is loaded", .{});
    }

    /// The id a child box with `key` gets under the box being built.
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

    /// Render again no later than `delay_ms` from now, for a view that
    /// changes with the clock alone. Call it each build
    /// while the view depends on the clock: the window keeps the earliest
    /// request of the last build, and a build that asks for none clears it.
    pub fn requestRenderAfter(self: *Cx, delay_ms: u32) void {
        const window = windowOf(self);
        window.assertPhase(.build);
        assert(delay_ms <= window_mod.render_delay_ms_max);
        const deadline = window.now_ns + @as(u64, delay_ms) * std.time.ns_per_ms;
        window.build_deadline_ns = @min(window.build_deadline_ns, deadline);
    }

    /// The tick's clock in nanoseconds: the time the host stamped on this
    /// frame. Every read in one build returns the same value, and it never
    /// decreases from frame to frame. Its zero is the host's, so use
    /// differences, and `requestRenderAfter` while a view follows it.
    pub fn now(self: *const Cx) u64 {
        const window = windowOf(self);
        window.assertPhase(.build);
        return window.now_ns;
    }

    /// The app's resource budget (`Config.limits`), for a component that
    /// bounds its own per-frame work by the same fields the core enforces.
    pub fn limits(self: *const Cx) *const ResourceLimits {
        const window = windowOf(self);
        assert(window.limits.build.element_count_frame_max > 0);
        return &window.limits;
    }

    /// Keyed element `target`'s bounds in the last laid-out frame, as
    /// `effects.bounds` reports them to handlers, or null when that frame
    /// did not have it. After a resize the first build still reads the old
    /// layout, so a read then asks for one more render: a view sized from
    /// these bounds settles at the new size in the next build.
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

    /// Keyed scroll box `target`'s offset and last measured viewport, or null
    /// before it first renders. A component reads it before rendering the
    /// box, for example to build only the rows in view (`List`); the offset
    /// is the one the wheel, scrollbar, and last emit left.
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

    /// Whether keyboard focus, drawn with its ring, is on `target` or inside
    /// it in the frame on screen (CSS `:focus-visible` within
    /// `:focus-within`). False after a pointer press moves focus, so a
    /// tooltip shown for keyboard focus does not stay up after a click.
    pub fn focusVisibleWithin(self: *const Cx, target: ElementId) bool {
        windowOf(self).assertPhase(.build);
        return windowOf(self).isFocusVisibleWithin(target);
    }

    /// The drag in progress, once past its threshold, if its payload is a
    /// `T`: for dimming its source, restyling the target it is `over`, and
    /// placing a preview at `x`, `y` on a `.drag` layer.
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

    /// Build a handler for `method`. Its state is the root
    /// state, an entity (`.entity`), or state retained with `cx.retain`
    /// (`.entity` with the retained handle), which lets a component handle
    /// events on state of its own.
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
            // Retained state: `get` panics on a stale handle.
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

    /// Find or create retained `T` for keyed `target`. Text
    /// engines come from their dedicated pool.
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
        // An entity from `Config.entities`: checked in every
        // build mode, since handles outlive the frame they were read in.
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

    /// Render a child: an element, a component, a tuple, an optional, or an
    /// array or slice of components.
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
                // `comptime`: a call result is runtime-known otherwise, so the
                // error below would fire for every slice of components.
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
            .text => self.buildText(child.content, &child.style),
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
        // A layer floats outside its parent's flow, so it is never revealed.
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
        // `on_pointer_drag`, `draggable`, and `drop_target` require a key
        // (`checkKeyed`), so each takes a record.
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
        const parent_index = window.open_stack[window.open_depth - 1];
        const size = style.size orelse window.theme.font_size_base;
        assert(size > 0);
        const variant = text_mod.FontVariant.init(style.weight, style.italic);
        const index = addNode(window, .text, autoId(window, parent_index));
        const node = window.node(index);
        node.text = window.built().copyText(content);
        const color: element.ColorToken = style.color orelse .text;
        node.text_color = color.resolve(window.theme);
        node.font_size = size;
        node.family = style.family;
        node.variant = variant;
        window.layout.text(content, textConfig(window, style)) catch |err| {
            layoutFailed(window, err);
        };
    }

    /// The size `ui.text(content, style)` takes in a parent whose content is
    /// `max_width` wide, measured as layout will size it: wrapped at the same
    /// words when `style.wrap` wraps, one line when it does not. For sizing a
    /// row from its content during render, such as a `List` row's `height`.
    /// Allocates nothing and adds no element; each call measures each word
    /// once through the text system's shaped-run cache.
    pub fn measureText(
        self: *Cx,
        content: []const u8,
        style: element.Text,
        max_width: f32,
    ) TextSize {
        const window = windowOf(self);
        window.assertPhase(.build);
        assert(std.math.isFinite(max_width));
        assert(max_width >= 0);
        assert(content.len <= std.math.maxInt(u32));
        const config = textConfig(window, &style);
        const text_system = window.resources.text_system;
        const key: text_mod.TextSizeKey = .{
            .text_hash = std.hash.Wyhash.hash(0, content),
            .text_len = @intCast(content.len),
            .max_width_bits = @bitCast(max_width),
            .style = @as(u64, config.font_id) | @as(u64, config.font_size) << 16 |
                @as(u64, config.line_height) << 32 | @as(u64, @backingInt(config.wrap_mode)) << 48,
        };
        if (text_system.text_size_cache.get(key)) |size| {
            return .{ .width = size[0], .height = size[1] };
        }
        const measured = window.layout.measureText(content, config, max_width);
        assert(measured.width >= 0);
        assert(measured.height >= 0);
        text_system.text_size_cache.put(key, measured.width, measured.height);
        return .{ .width = measured.width, .height = measured.height };
    }

    pub const TextSize = struct { width: f32, height: f32 };

    /// The layout engine's text configuration for a `ui.text` style.
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
        };
    }

    /// The layout engine's line height is a percent of the font size; the
    /// element's is a percent of the font's line height.
    /// Wrapped boxes and emit both pitch lines by this one value, so they agree.
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

/// Start a frame's build: the window root is node 0, a column the size of
/// the window, so a root box may `grow` or use `percent`.
pub fn beginBuild(window: *Window) void {
    window.assertPhase(.build);
    window.node_count = 0;
    window.open_depth = 0;
    window.component_depth = 0;
    window.keys.clear();
    window.build_deadline_ns = window_mod.deadline_none;
    window.layout.beginFrame(window.width, window.height);
    window.layout.setMeasureTextFn(measureText, window);
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

/// Deepest component nesting seen, and the stack it took.
fn noteDepth(window: *Window) void {
    const address = @frameAddress();
    if (window.component_depth == 1) window.depth_base_address = address;
    if (window.component_depth > window.component_depth_peak) {
        window.component_depth_peak = window.component_depth;
        window.depth_peak_address = address;
        window.depth_peak_base_address = window.depth_base_address;
    }
}

/// Copy a box's accessibility annotation into the frame, strings included.
/// The value keeps at most `value_bytes_max` bytes around its selection
/// (`a11y_value.window`), so a long document cannot exhaust the frame's text.
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

/// A pointer capture finds its box again by id at every step, and a drag
/// names its source and the target it is `over` by id, which only a key
/// keeps stable across frames: an auto id is a sibling position, so it
/// could name another box after the rows above it change. A press arms
/// either a capture or a drag, so one box cannot ask for both.
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

/// What is wrong with a box's gesture fields, or null when nothing is.
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
        .border = .none,
        .corners = .zero,
        .shadow = null,
        .shadow_color = records.Color.transparent,
        .text = .empty,
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
    /// A scroll box's retained state, whose offset the layout applies to its
    /// children; null for every other box.
    scroll: ?*const window_mod.ScrollState,
    /// A layer box floats at its anchor, outside its parent's layout.
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
    window.layout.openElement(decl) catch |err| layoutFailed(window, err);
    return index;
}

/// What the layout resolves a scroll box's offset against this frame: a
/// pending `Effects.scrollTo`, else the end while an `.end` anchor is
/// pinned. A child target waits for its child to open (`revealChild`).
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

/// When the box just opened at `index` is the child a pending
/// `Effects.scrollTo` names in its parent scroll box, hand the parent's
/// layout its element index, so this frame's layout brings it into view.
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

/// A layer's anchor as layout floating: its top-left corner at the offset
/// from the opener's top-left corner, or from the window's.
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

/// A scroll box's offset, retained by its key for as long as it renders.
/// The last emit's measurement clamps it, so content that
/// shrank never shows past its end.
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

/// A box or paint opens a layout element, so its depth is checked before the
/// layout engine's open stack, sized from the same field, takes it: past the
/// bound it fails fast here with the frame number. The window root holds one
/// level, so an app nests `box_depth_max - 1` levels inside it.
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
    // `openNodeWith` checked the depth before opening this box.
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

/// `Style.opacity`, checked: a value outside 0 to 1 is a programmer error in
/// every build mode, since a renderer would draw it as garbage alpha.
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

fn layoutFailed(window: *const Window, err: anyerror) noreturn {
    std.debug.panic("layout failed in frame {d}: {s}", .{ window.frame_number, @errorName(err) });
}

/// Text measurement over the window's text system.
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
    // Each family measures and sizes lines by its own regular face.
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
    const direction: layout_mod.LayoutDirection = switch (style.direction) {
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
            .child_alignment = childAlignment(style.direction, style.alignment),
            .layout_direction = direction,
            .main_axis_distribution = switch (style.alignment.main) {
                inline else => |tag| @field(layout_mod.MainAxisDistribution, @tagName(tag)),
            },
            .aspect_ratio = aspectRatio(style),
            .wrap = wrapsRow(style),
        },
    };
    // A fixed width fixes the height too, so the layout's minimums, which a
    // fit-content parent is sized from, already hold it. Any other width is
    // known only after sizing, which grows such parents to the height.
    if (decl.layout.aspect_ratio) |ratio| {
        if (style.width == .fixed) decl.layout.sizing.height = .fixed(style.width.fixed / ratio);
    }
    return decl;
}

/// The layout derives an aspect box's height from its width, so a height of
/// its own would contradict the ratio rather than bound it.
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

/// Lines stack down the cross axis, whose height the layout derives from
/// them after widths are known; a column's would need its width derived.
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

/// Layout padding and gaps are whole pixels.
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
