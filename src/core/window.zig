const std = @import("std");
const builtin = @import("builtin");
const id_mod = @import("id.zig");
const records = @import("records.zig");
const handler_mod = @import("handler.zig");
const events = @import("events.zig");
const images_mod = @import("images.zig");
const jobs_mod = @import("jobs.zig");
const retained_mod = @import("retained.zig");
const text_engine = @import("text_engine.zig");
const clipboard_mod = @import("clipboard.zig");
const element = @import("element.zig");
const limits_mod = @import("limits.zig");
const layout_mod = @import("../layout/layout.zig");
const text_mod = @import("../text/mod.zig");
const app_resources = @import("app_resources.zig");
const a11y_types = @import("../accessibility/types.zig");
const keymap_mod = @import("keymap.zig");
const A11ySystem = @import("a11y_system.zig").A11ySystem;
const screen_reader_mod = @import("screen_reader.zig");
const debugger_mod = @import("debugger.zig");
const frame_trace = @import("frame_trace.zig");
const shader_mod = @import("shader.zig");
const input_mod = @import("../input/mod.zig");

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;
pub const Frame = records.Frame;
pub const ResourceLimits = limits_mod.ResourceLimits;
pub const AppResources = app_resources.AppResources;
pub const LayoutEngine = layout_mod.LayoutEngine;

pub const PackedFrame = @import("packed_frame.zig").PackedFrame;

pub const Phase = enum { idle, drain, build, layout, emit, pack, draw };

pub fn wheelOffset(delta: f32) f32 {
    assert(std.math.isFinite(delta));
    const offset = if (wheel_delta_inverted) -delta else delta;
    assert(@abs(offset) == @abs(delta));
    return offset;
}

pub var wheel_delta_inverted: bool = builtin.os.tag == .macos;

pub const box_depth_ceiling = limits_mod.box_depth_ceiling;

pub fn textFailed(window: *const Window, content: []const u8, err: anyerror) noreturn {
    if (err == error.TextRunTooLong) {
        std.debug.panic("a shaping run of {d} codepoints passed " ++
            "text.run_codepoint_count_max {d} in frame {d}: the text was not split into " ++
            "runs (text_system.runLength)", .{
            text_mod.codepointCount(content),
            text_mod.run_codepoint_count_max,
            window.frame_number,
        });
    }
    std.debug.panic("text shaping failed in frame {d}: {s}", .{
        window.frame_number,
        @errorName(err),
    });
}

pub const deadline_none: u64 = std.math.maxInt(u64);

pub const render_delay_ms_max: u32 = @import("../platform/interface.zig").render_delay_ms_max;

pub const NodeKind = enum { box, text, paint };

pub const Node = struct {
    kind: NodeKind,
    id: ElementId,
    parent: u32,
    depth: u8,
    child_count: u32,
    focusable: bool,
    tab_stop: bool,
    hit: bool,
    pointer: bool,
    opacity: f32,
    cursor: ?element.CursorShape,
    on_click: u32,
    on_click_outside: u32,
    on_context_menu: u32,
    on_key: u32,
    on_pointer_drag: u32,
    drag_type: usize,
    drag_payload: u64,
    drop_type: usize,
    on_drop: u32,
    key_context: u64,
    actions_start: u32,
    actions_len: u32,
    a11y: ?A11yBuilt,
    background: ?records.Color,
    fill: ?NodeFill,
    border: records.Border,
    corners: records.Corners,
    shadow: ?element.Shadow,
    shadow_color: records.Color,
    text: records.TextRange,
    text_color: records.Color,
    font_size: u16,
    family: text_mod.FontFamily,
    variant: text_mod.FontVariant,
    paint_fn: ?*const fn (data: *const anyopaque, painter: *anyopaque) void,
    paint_data: ?*const anyopaque,
    clip: bool,
    scroll: ?retained_mod.Handle(ScrollState),
    layer: ?element.Layer,
    source: debugger_mod.NodeSource,
};

/// A resolved `Style.fill`: the ShaderId and the frame params slot holding its Params.
pub const NodeFill = struct { shader: u8, params_slot: u32 };

pub const FocusPlace = struct {
    id: ElementId,
    frame_number: u64,
    content: records.Rect,
};

pub const ScrollState = struct {
    offset_x: f32,
    offset_y: f32,
    content_width: f32,
    content_height: f32,
    viewport: records.Rect,
    axes: element.Scroll,
    target: ?Target,
    at_end: bool,
    dragging: ?ScrollAxis,
    drag_pointer_start: f32,
    drag_offset_start: f32,

    pub const scrollbar_size: f32 = 8;
    pub const scrollbar_padding: f32 = 2;
    pub const scrollbar_room: f32 = scrollbar_size + scrollbar_padding;
    pub const scrollbar_thumb_min: f32 = 30;
    pub const end_slop_px: f32 = 0.5;

    pub const Target = union(enum) {
        start,
        end,
        offset: element.ScrollOffset,
        child: Child,

        pub const Child = struct {
            id: ElementId,
            index: ?u64,
            alignment: element.ScrollAlignment,
        };
    };

    pub fn init(self: *ScrollState) void {
        self.* = .{
            .offset_x = 0,
            .offset_y = 0,
            .content_width = 0,
            .content_height = 0,
            .viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .axes = .{},
            .target = null,
            .at_end = true,
            .dragging = null,
            .drag_pointer_start = 0,
            .drag_offset_start = 0,
        };
    }

    pub fn maxX(self: *const ScrollState) f32 {
        if (!self.axes.x) return 0;
        return @max(0, self.content_width - self.viewport.width);
    }

    pub fn maxY(self: *const ScrollState) f32 {
        if (!self.axes.y) return 0;
        return @max(0, self.content_height - self.viewport.height);
    }

    fn max(self: *const ScrollState, axis: ScrollAxis) f32 {
        return switch (axis) {
            .x => self.maxX(),
            .y => self.maxY(),
        };
    }

    fn offset(self: *ScrollState, axis: ScrollAxis) *f32 {
        return switch (axis) {
            .x => &self.offset_x,
            .y => &self.offset_y,
        };
    }

    pub fn clamp(self: *ScrollState) bool {
        const x = std.math.clamp(self.offset_x, 0, self.maxX());
        const y = std.math.clamp(self.offset_y, 0, self.maxY());
        const moved = x != self.offset_x or y != self.offset_y;
        self.offset_x = x;
        self.offset_y = y;
        const end_x = x >= self.maxX() - end_slop_px;
        const end_y = y >= self.maxY() - end_slop_px;
        self.at_end = end_x and end_y;
        assert(self.offset_y >= 0);
        return moved;
    }

    pub fn followsEnd(self: *const ScrollState) bool {
        if (self.target) |target| return target == .end;
        return self.axes.anchor == .end and self.at_end;
    }

    pub fn wheel(self: *ScrollState, delta_x: f32, delta_y: f32) bool {
        assert(std.math.isFinite(delta_x));
        assert(std.math.isFinite(delta_y));
        const before_x = self.offset_x;
        const before_y = self.offset_y;
        self.target = null;
        if (self.maxX() > 0) self.offset_x += wheelOffset(delta_x);
        if (self.maxY() > 0) self.offset_y += wheelOffset(delta_y);
        _ = self.clamp();
        return self.offset_x != before_x or self.offset_y != before_y;
    }

    pub fn track(self: *const ScrollState, axis: ScrollAxis) ?records.Rect {
        if (self.max(axis) == 0) return null;
        const box = self.viewport;
        return switch (axis) {
            .y => .{
                .x = box.x + box.width - scrollbar_room,
                .y = box.y + scrollbar_padding,
                .width = scrollbar_size,
                .height = @max(0, box.height - scrollbar_padding * 2),
            },
            .x => .{
                .x = box.x + scrollbar_padding,
                .y = box.y + box.height - scrollbar_room,
                .width = @max(0, box.width - scrollbar_padding * 2),
                .height = scrollbar_size,
            },
        };
    }

    pub fn thumb(self: *const ScrollState, axis: ScrollAxis, bar: records.Rect) records.Rect {
        const span = self.thumbSpan(axis, bar);
        var rect = bar;
        switch (axis) {
            .y => {
                rect.y += span.start;
                rect.height = span.length;
            },
            .x => {
                rect.x += span.start;
                rect.width = span.length;
            },
        }
        assert(rect.width <= bar.width);
        assert(rect.height <= bar.height);
        return rect;
    }

    const Span = struct { start: f32, length: f32, range: f32 };

    fn thumbSpan(self: *const ScrollState, axis: ScrollAxis, bar: records.Rect) Span {
        const offset_max = self.max(axis);
        assert(offset_max > 0);
        const track_length = if (axis == .y) bar.height else bar.width;
        const viewport_length = if (axis == .y) self.viewport.height else self.viewport.width;
        const content_length = if (axis == .y) self.content_height else self.content_width;
        const proportional = track_length * viewport_length / content_length;
        const length = @min(track_length, @max(scrollbar_thumb_min, proportional));
        const offset_value = if (axis == .y) self.offset_y else self.offset_x;
        const fraction = offset_value / offset_max;
        assert(fraction >= 0);
        assert(fraction <= 1);
        const range = track_length - length;
        return .{ .start = range * fraction, .length = length, .range = range };
    }

    pub fn press(self: *ScrollState, x: f32, y: f32) bool {
        assert(self.dragging == null);
        const axis = self.scrollbarAt(x, y) orelse return false;
        self.target = null;
        const bar = self.track(axis).?;
        const along = if (axis == .y) y else x;
        if (self.thumb(axis, bar).contains(x, y)) {
            self.dragging = axis;
            self.drag_pointer_start = along;
            self.drag_offset_start = self.offset(axis).*;
        } else {
            const start = if (axis == .y) bar.y else bar.x;
            const length = if (axis == .y) bar.height else bar.width;
            self.offset(axis).* = (along - start) / length * self.max(axis);
            _ = self.clamp();
        }
        return true;
    }

    pub fn scrollbarAt(self: *const ScrollState, x: f32, y: f32) ?ScrollAxis {
        assert(std.math.isFinite(x));
        assert(std.math.isFinite(y));
        inline for (.{ ScrollAxis.y, ScrollAxis.x }) |axis| {
            if (self.track(axis)) |bar| {
                if (bar.contains(x, y)) return axis;
            }
        }
        return null;
    }

    pub fn drag(self: *ScrollState, x: f32, y: f32) bool {
        const axis = self.dragging.?;
        const bar = self.track(axis) orelse return false;
        const span = self.thumbSpan(axis, bar);
        if (span.range <= 0) return false;
        const along = if (axis == .y) y else x;
        const target = self.offset(axis);
        const before = target.*;
        const travel = along - self.drag_pointer_start;
        target.* = self.drag_offset_start + travel / span.range * self.max(axis);
        _ = self.clamp();
        return target.* != before;
    }
};

pub const ScrollAxis = enum { x, y };

pub const PendingFont = struct {
    name_buffer: [name_bytes_max]u8,
    name_len: u8,
    size: f32,

    pub const name_bytes_max = text_mod.TextSystem.family_name_bytes_max;

    pub fn name(self: *const PendingFont) []const u8 {
        assert(self.name_len > 0);
        return self.name_buffer[0..self.name_len];
    }
};

pub const A11yBuilt = struct {
    role: a11y_types.Role,
    label: records.TextRange,
    value: records.TextRange,
    href: records.TextRange,
    description: records.TextRange,
    checked: bool,
    selected: bool,
    disabled: bool,
    expanded: bool,
    has_popup: bool,
    heading_level: a11y_types.HeadingLevel,
    live: a11y_types.Live,
    pos_in_set: ?u16,
    set_size: ?u16,
    range: ?element.A11y.Range,
    selection: ?element.TextSelection,
};

pub const Capture = struct {
    id: ElementId,
    button: input_mod.MouseButton,
    start_x: f32,
    start_y: f32,
    moved: bool,
    cursor: element.CursorShape,
    click_count: u32,

    pub const click_slop_px: f32 = 2;

    pub const none: Capture = .{
        .id = .root,
        .button = .left,
        .start_x = 0,
        .start_y = 0,
        .moved = false,
        .cursor = .default,
        .click_count = 0,
    };
};

pub const Drag = struct {
    phase: enum { idle, armed, active },
    keyboard: bool,
    source: ElementId,
    button: input_mod.MouseButton,
    type_id: usize,
    payload: u64,
    start_x: f32,
    start_y: f32,
    x: f32,
    y: f32,
    over: ElementId,

    pub const idle: Drag = .{
        .phase = .idle,
        .keyboard = false,
        .source = .root,
        .button = .left,
        .type_id = 0,
        .payload = 0,
        .start_x = 0,
        .start_y = 0,
        .x = 0,
        .y = 0,
        .over = .root,
    };
};

pub const KeySet = struct {
    slots: []ElementId,
    count: u32,

    pub fn initInPlace(self: *KeySet, gpa: std.mem.Allocator, count_max: u32) !void {
        assert(count_max > 0);
        self.slots = try gpa.alloc(ElementId, std.math.ceilPowerOfTwoAssert(u32, count_max * 2));
        @memset(self.slots, .root);
        self.count = 0;
    }

    pub fn deinit(self: *KeySet, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
    }

    pub fn clear(self: *KeySet) void {
        @memset(self.slots, .root);
        self.count = 0;
    }

    pub fn insert(self: *KeySet, id: ElementId, frame: u64) bool {
        assert(id != .root);
        if (self.count * 2 >= self.slots.len) {
            std.debug.panic("key set exhausted: capacity {d} keys, {d} in use, 1 requested, " ++
                "frame {d}. Raise ResourceLimits.build.key_count_frame_max.", .{
                self.slots.len / 2,
                self.count,
                frame,
            });
        }
        const mask = self.slots.len - 1;
        var position: usize = @truncate(@backingInt(id) & mask);
        while (self.slots[position] != .root) : (position = (position + 1) & mask) {
            if (self.slots[position] == id) return false;
        }
        self.slots[position] = id;
        self.count += 1;
        return true;
    }

    pub fn contains(self: *const KeySet, id: ElementId) bool {
        if (id == .root) return true;
        const mask = self.slots.len - 1;
        var position: usize = @truncate(@backingInt(id) & mask);
        var probes: usize = 0;
        while (probes < self.slots.len) : (probes += 1) {
            const slot = self.slots[position];
            if (slot == .root) return false;
            if (slot == id) return true;
            position = (position + 1) & mask;
        }
        return false;
    }
};

pub const Presenter = struct {
    context: *anyopaque,
    draw: *const fn (
        context: *anyopaque,
        packed_frame: *const PackedFrame,
        frame: *const Frame,
        clear: records.Color,
    ) void,
};

pub const FileDialogService = struct {
    context: *anyopaque,
    open: *const fn (
        context: *anyopaque,
        scratch: std.mem.Allocator,
        request_id: u32,
        request: handler_mod.FileDialogRequest,
    ) ?events.Completion.Outcome,
};

pub const WakeService = images_mod.WakeService;

pub const Window = struct {
    gpa: std.mem.Allocator,
    limits: ResourceLimits,
    /// `App.shaders` in declaration order; a spec's index is its ShaderId.
    shaders: []const *const shader_mod.Spec,
    theme: *const element.Theme,
    keymap: []const keymap_mod.Compiled,
    keymap_tables: keymap_mod.Tables,
    store: *handler_mod.Store,
    resources: *AppResources,
    layout: *LayoutEngine,
    nodes: []Node,
    node_count: u32,
    keys: KeySet,
    frames: [2]Frame,
    built_index: u1,
    queue: events.EventQueue,
    completions: events.CompletionRing,
    images: images_mod.Loader,
    jobs: jobs_mod.Pool,
    job_inbox: events.JobInbox,
    retained: retained_mod.Retained,
    inputs: text_engine.InputPool,
    areas: text_engine.AreaPool,
    areas_reserved: bool,
    editors: text_engine.EditorPool,
    editors_reserved: bool,
    clipboard: clipboard_mod.Clipboard,
    clipboard_bytes: []u8,
    dialog_request_bytes: []u8,
    packed_frame: PackedFrame,
    text_scratch: []u8,
    text_scratch_allocator: std.heap.FixedBufferAllocator,
    presenter: ?Presenter,
    file_dialog: ?FileDialogService,
    focus: ElementId,
    focus_visible: bool,
    focus_reveal: bool,
    focus_place: FocusPlace,
    hover_path: []ElementId,
    hover_len: u32,
    focus_path: []ElementId,
    focus_len: u32,
    cursor: element.CursorShape,
    press_path: []ElementId,
    press_len: u32,
    scroll_drag: ElementId,
    capture: Capture,
    drag: Drag,
    pointer: ?struct { x: f32, y: f32 },
    phase: Phase,
    frame_in_flight: std.atomic.Value(bool),
    awaiting_flip: bool,
    render_phase: Phase,
    atlas_consumer_key: usize,
    atlas_frame: u64,
    frame_number: u64,
    render_requested: bool,
    render_deadline_ns: u64,
    build_deadline_ns: u64,
    quit_requested: bool,
    pending_dialog: ?handler_mod.FileDialogRequest,
    pending_font: ?PendingFont,
    announcements: records.Announcements,
    screen_reader: *A11ySystem,
    screen_reader_poll: screen_reader_mod.Poll,
    debugger: debugger_mod.State,
    trace: frame_trace.State,
    dialog_handlers: []?handler_mod.Handler,
    dialogs_opened: u32,
    now_ns: u64,
    width: f32,
    height: f32,
    scale_factor: f32,
    title_bar_inset: events.TitleBar.Inset,
    clear_color: records.Color,
    open_stack: []u32,
    open_depth: u32,
    component_depth: u32,
    component_depth_peak: u32,
    depth_base_address: usize,
    depth_peak_base_address: usize,
    depth_peak_address: usize,

    pub fn built(self: *Window) *Frame {
        return &self.frames[self.built_index];
    }

    pub fn renderDeadlineNs(self: *const Window) ?u64 {
        assert(self.phase == .idle);
        const deadline = self.render_deadline_ns;
        return if (deadline == deadline_none) null else deadline;
    }

    pub fn bindViewport(self: *Window, viewport: Frame.Viewport) void {
        assert(self.phase == .idle);
        assert(self.frame_number == 0);
        assert(viewport.width > 0);
        assert(viewport.height > 0);
        assert(viewport.scale_factor > 0);
        const same_size = viewport.width == self.width and viewport.height == self.height;
        if (same_size and viewport.scale_factor == self.scale_factor) return;
        self.queue.push(.{ .window = .{ .resized = .{
            .width = viewport.width,
            .height = viewport.height,
            .scale_factor = viewport.scale_factor,
        } } });
        assert(self.queue.count > 0);
    }

    pub fn rendered(self: *const Window) *const Frame {
        return &self.frames[self.built_index ^ 1];
    }

    pub fn setPhase(self: *Window, from: Phase, to: Phase) void {
        if (self.phase != from) {
            std.debug.panic("core phase transition {t} -> {t} from {t}", .{ from, to, self.phase });
        }
        self.phase = to;
    }

    pub fn assertPhase(self: *const Window, phase: Phase) void {
        if (self.phase != phase) {
            std.debug.panic("core call needs phase {t}, window is in {t}", .{ phase, self.phase });
        }
    }

    pub fn isFocused(self: *const Window, id: ElementId) bool {
        return id != .root and self.focus == id;
    }

    pub fn isKeyboardDropTarget(self: *const Window, id: ElementId) bool {
        if (id == .root) return false;
        if (!self.drag.keyboard) return false;
        assert(self.drag.phase == .active);
        return self.drag.over == id;
    }

    pub fn isHovered(self: *const Window, id: ElementId) bool {
        assert(self.hover_len <= self.hover_path.len);
        for (self.hover_path[0..self.hover_len]) |hovered| {
            if (hovered == id) return true;
        }
        return false;
    }

    pub fn isFocusVisibleWithin(self: *const Window, id: ElementId) bool {
        assert(self.focus_len <= self.focus_path.len);
        if (self.focus_len > 0) assert(self.focus_visible);
        for (self.focus_path[0..self.focus_len]) |focused| {
            if (focused == id) return true;
        }
        return false;
    }

    pub fn stackBytesPerLevel(self: *const Window) u64 {
        if (self.component_depth_peak < 2) return 0;
        assert(self.depth_peak_base_address >= self.depth_peak_address);
        const span = self.depth_peak_base_address - self.depth_peak_address;
        return span / (self.component_depth_peak - 1);
    }

    pub fn bindScreenReader(self: *Window, native_window: anytype, native_view: anytype) void {
        assert(self.phase == .idle);
        self.screen_reader.bindPlatform(native_window, native_view);
        self.screen_reader_poll = .{};
        assert(self.screen_reader.bridgeAddressValid());
    }

    pub fn bindWake(self: *Window, service: ?images_mod.WakeService) void {
        self.images.bindWake(service);
        self.jobs.bindWake(service);
        if (service == null) assert(self.jobs.wake == null);
    }

    pub fn unbindScreenReader(self: *Window) void {
        assert(self.phase == .idle);
        self.screen_reader.bindHeadless();
    }

    pub fn areaPool(self: *Window) *text_engine.AreaPool {
        if (!self.areas_reserved) {
            std.debug.panic("text pool 'area' has capacity 0: set limits.text.area.count_max " ++
                "to the most TextAreas rendered at once (frame {d})", .{self.frame_number});
        }
        return &self.areas;
    }

    pub fn editorPool(self: *Window) *text_engine.EditorPool {
        if (!self.editors_reserved) {
            std.debug.panic("text pool 'editor' has capacity 0: set " ++
                "limits.text.editor.count_max to the most CodeEditors rendered at once " ++
                "(frame {d})", .{self.frame_number});
        }
        return &self.editors;
    }

    /// The ShaderId of a fill's shader. A shader missing from `App.shaders` has no
    /// pipeline, so drawing it is a programmer error.
    pub fn shaderId(self: *const Window, spec: *const shader_mod.Spec) u8 {
        assert(self.shaders.len <= limits_mod.MAX_SHADERS);
        for (self.shaders, 0..) |declared, index| {
            if (declared == spec) return @intCast(index);
        }
        std.debug.panic("Style.fill uses shader \"{s}\", which is not in App.shaders " ++
            "(frame {d}). Add it to the app's .shaders list.", .{ spec.name, self.frame_number });
    }

    pub fn node(self: *Window, index: u32) *Node {
        assert(index < self.node_count);
        return &self.nodes[index];
    }
};

pub const Options = struct {
    width: f32,
    height: f32,
    scale_factor: f32,
    limits: *const ResourceLimits,
    theme: *const element.Theme,
    keymap: keymap_mod.Tables,
    store: *handler_mod.Store,
    resources: *AppResources,
    job_types: []const usize = &.{},
    shaders: []const *const shader_mod.Spec,
    image_decodes: images_mod.Mode,
    job_runs: jobs_mod.Mode,
};

pub fn useKeymapConvention(self: *Window, convention: keymap_mod.Convention) void {
    assert(self.phase == .idle);
    self.keymap = self.keymap_tables.of(convention);
    assert(self.keymap.len == self.keymap_tables.of(convention).len);
}

pub noinline fn initInPlace(self: *Window, gpa: std.mem.Allocator, options: *const Options) !void {
    assert(options.width > 0);
    assert(options.scale_factor > 0);
    assert(options.limits.check() == null);
    assert(debugger_mod.reservedLimits(options.limits).check() == null);
    const limits = options.limits;
    self.gpa = gpa;
    self.limits = limits.*;
    self.theme = options.theme;
    self.keymap_tables = options.keymap;
    self.keymap = options.keymap.of(keymap_mod.native);
    self.store = options.store;
    self.resources = options.resources;
    assert(options.shaders.len <= limits.paint.shader_count_max);
    self.shaders = options.shaders;
    try initBuildStorage(self, gpa, limits);
    errdefer deinitBuildStorage(self, gpa);
    try initRuntimeStorage(self, gpa, options);
    errdefer deinitRuntimeStorage(self, gpa);

    self.store.registerPool(self.inputs.entityPool());
    if (self.areas_reserved) self.store.registerPool(self.areas.entityPool());
    if (self.editors_reserved) self.store.registerPool(self.editors.entityPool());
    assert(self.store.retained == null);
    self.store.retained = &self.retained;
    self.resources.text_system.useRunAllocator(self.text_scratch_allocator.allocator());
    self.presenter = null;
    self.file_dialog = null;
    self.focus = .root;
    self.focus_visible = false;
    self.focus_reveal = false;
    self.focus_place = .{
        .id = .root,
        .frame_number = 0,
        .content = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    self.hover_len = 0;
    self.focus_len = 0;
    self.cursor = .default;
    self.press_len = 0;
    self.scroll_drag = .root;
    self.capture = Capture.none;
    self.drag = Drag.idle;
    self.pointer = null;
    self.phase = .idle;
    self.frame_in_flight = .init(false);
    self.awaiting_flip = false;
    self.render_phase = .idle;
    self.atlas_consumer_key = @intFromPtr(self);
    self.atlas_frame = 0;
    self.frame_number = 0;
    self.render_requested = true;
    self.render_deadline_ns = deadline_none;
    self.build_deadline_ns = deadline_none;
    self.quit_requested = false;
    self.pending_dialog = null;
    self.pending_font = null;
    self.announcements.clear();
    self.dialogs_opened = 0;
    self.now_ns = 0;
    self.width = options.width;
    self.height = options.height;
    self.scale_factor = options.scale_factor;
    self.title_bar_inset = .{};
    self.clear_color = options.theme.bg;
    self.open_depth = 0;
    self.component_depth = 0;
    self.component_depth_peak = 0;
    self.depth_base_address = 0;
    self.depth_peak_base_address = 0;
    self.depth_peak_address = 0;
    debugger_mod.initState(&self.debugger);
    assert(self.built_index == 0);
}

comptime {
    if (!debugger_mod.enabled) {
        assert(@sizeOf(@FieldType(Window, "debugger")) == 0);
        assert(@sizeOf(@FieldType(Node, "source")) == 0);
        assert(@sizeOf(@FieldType(records.Frame, "overlay_start")) == 0);
    }
}

fn initBuildStorage(self: *Window, gpa: std.mem.Allocator, limits: *const ResourceLimits) !void {
    const element_count = limits.build.element_count_frame_max + 1;
    const capacity = layout_mod.LayoutCapacity.fromLimits(limits);
    assert(capacity.element_count_max == element_count);
    self.layout = try gpa.create(LayoutEngine);
    errdefer gpa.destroy(self.layout);
    self.layout.* = try LayoutEngine.init(&capacity);
    errdefer self.layout.deinit();
    try initPaths(self, gpa, limits.build.box_depth_max);
    errdefer deinitPaths(self, gpa);
    self.nodes = try gpa.alloc(Node, element_count);
    errdefer gpa.free(self.nodes);
    self.node_count = 0;
    try self.keys.initInPlace(gpa, limits.build.key_count_frame_max);
    errdefer self.keys.deinit(gpa);
    const reserved = debugger_mod.reservedLimits(limits);
    const announcements = records.Announcements.Capacity{
        .polite_pending_max = limits.a11y.announcement_polite_pending_max,
        .message_bytes_max = limits.a11y.announcement_message_bytes_max,
    };
    const frame_capacity = records.FrameCapacity{
        .paint_record_count_max = reserved.records.paint_record_count_frame_max,
        .hit_record_count_max = limits.records.hit_record_count_frame_max,
        .handler_count_max = limits.records.handler_count_frame_max,
        .a11y_node_count_max = limits.a11y.element_count_max,
        .announcements = announcements,
        .text_bytes_max = limits.build.text_bytes_frame_max,
        .mesh_point_count_max = limits.paint.path_vertex_count_frame_max +
            limits.paint.polyline_point_count_frame_max + limits.paint.point_count_frame_max,
        .params_slot_count_max = limits.paint.custom_draw_count_frame_max,
        .params_stride = limits.paint.shader_params_bytes_max,
    };
    try self.frames[0].initInPlace(gpa, &frame_capacity);
    errdefer self.frames[0].deinit(gpa);
    try self.frames[1].initInPlace(gpa, &frame_capacity);
    errdefer self.frames[1].deinit(gpa);
    try self.announcements.initInPlace(gpa, announcements);
    self.built_index = 0;
}

fn deinitBuildStorage(self: *Window, gpa: std.mem.Allocator) void {
    self.announcements.deinit(gpa);
    self.frames[1].deinit(gpa);
    self.frames[0].deinit(gpa);
    self.keys.deinit(gpa);
    gpa.free(self.nodes);
    deinitPaths(self, gpa);
    self.layout.deinit();
    gpa.destroy(self.layout);
}

fn initPaths(self: *Window, gpa: std.mem.Allocator, depth_max: u32) !void {
    assert(depth_max > 0);
    assert(depth_max <= box_depth_ceiling);

    self.open_stack = try gpa.alloc(u32, depth_max);
    errdefer gpa.free(self.open_stack);

    self.hover_path = try gpa.alloc(ElementId, depth_max);
    errdefer gpa.free(self.hover_path);

    self.focus_path = try gpa.alloc(ElementId, depth_max);
    errdefer gpa.free(self.focus_path);

    self.press_path = try gpa.alloc(ElementId, depth_max);
}

fn deinitPaths(self: *Window, gpa: std.mem.Allocator) void {
    assert(self.press_path.len == self.open_stack.len);
    assert(self.focus_path.len == self.open_stack.len);
    @memset(std.mem.sliceAsBytes(self.press_path), 0);
    @memset(std.mem.sliceAsBytes(self.focus_path), 0);
    @memset(std.mem.sliceAsBytes(self.hover_path), 0);
    @memset(self.open_stack, 0);
    gpa.free(self.press_path);
    gpa.free(self.focus_path);
    gpa.free(self.hover_path);
    gpa.free(self.open_stack);
}

fn initRuntimeStorage(self: *Window, gpa: std.mem.Allocator, options: *const Options) !void {
    const limits = options.limits;
    try self.queue.initInPlace(gpa, .{
        .event_count_max = limits.events.queue_count_max,
        .text_bytes_max = limits.events.text_bytes_max,
        .dialog_count_max = limits.events.dialog_count_max,
        .dialog_path_bytes_max = limits.events.dialog_path_bytes_max,
    });
    errdefer self.queue.deinit(gpa);
    try self.completions.initInPlace(gpa, .{
        .count_max = std.math.ceilPowerOfTwoAssert(u32, limits.events.completion_count_max),
        .dialog_count_max = limits.events.dialog_count_max,
        .dialog_path_bytes_max = limits.events.dialog_path_bytes_max,
        .io = self.resources.io,
    });
    errdefer self.completions.deinit(gpa);
    self.job_inbox = .{
        .entries = try gpa.alloc(events.JobEntry, self.completions.slots.len),
        .count = 0,
    };
    errdefer gpa.free(self.job_inbox.entries);
    self.dialog_handlers = try gpa.alloc(?handler_mod.Handler, limits.events.dialog_count_max);
    errdefer gpa.free(self.dialog_handlers);
    @memset(self.dialog_handlers, null);
    try initWorkers(self, gpa, options);
    errdefer deinitWorkers(self, gpa);
    try self.retained.initInPlace(gpa, &.{
        .slot_counts = .{
            limits.retained.slot_count_64,
            limits.retained.slot_count_256,
            limits.retained.slot_count_1024,
            limits.retained.slot_count_4096,
        },
        .sweep_delay_frames = limits.retained.sweep_delay_frames,
    });
    errdefer self.retained.deinit(gpa);
    try self.inputs.initInPlace(gpa, poolCapacity(.input, &limits.text));
    errdefer self.inputs.deinit(gpa);
    self.areas_reserved = limits.text.area.count_max > 0;
    if (self.areas_reserved) try self.areas.initInPlace(gpa, poolCapacity(.area, &limits.text));
    errdefer if (self.areas_reserved) self.areas.deinit(gpa);
    self.editors_reserved = limits.text.editor.count_max > 0;
    if (self.editors_reserved) {
        try self.editors.initInPlace(gpa, poolCapacity(.editor, &limits.text));
    }
    errdefer if (self.editors_reserved) self.editors.deinit(gpa);
    self.clipboard_bytes = try gpa.alloc(u8, clipboardBytes(&limits.text));
    errdefer gpa.free(self.clipboard_bytes);
    self.clipboard = .init(self.clipboard_bytes);
    self.dialog_request_bytes = try gpa.alloc(u8, limits.events.dialog_path_bytes_max);
    errdefer gpa.free(self.dialog_request_bytes);
    try initRenderTargets(self, limits);
    errdefer deinitRenderTargets(self);
    self.text_scratch = try gpa.alloc(u8, limits_mod.textScratchBytes(&limits.events));
    errdefer gpa.free(self.text_scratch);
    self.text_scratch_allocator = std.heap.FixedBufferAllocator.init(self.text_scratch);
    self.screen_reader = try gpa.create(A11ySystem);
    errdefer gpa.destroy(self.screen_reader);
    try self.screen_reader.initInPlace(&.fromLimits(limits));
    errdefer self.screen_reader.deinit();
    self.screen_reader_poll = .{};
    try frame_trace.init(&self.trace, gpa, self.resources.io);
}

fn initWorkers(self: *Window, gpa: std.mem.Allocator, options: *const Options) !void {
    const io = self.resources.io;
    const limits = options.limits;
    assert(self.completions.slots.len > 0);
    try self.images.initInPlace(gpa, io, &self.completions, &limits.atlas, options.image_decodes);
    errdefer self.images.deinit(gpa);
    try self.jobs.initInPlace(
        gpa,
        io,
        &self.completions,
        &limits.events,
        options.job_types,
        options.job_runs,
    );
    assert(self.images.mode == options.image_decodes);
    assert(self.jobs.mode == options.job_runs);
}

fn deinitWorkers(self: *Window, gpa: std.mem.Allocator) void {
    self.jobs.deinit(gpa);
    self.images.deinit(gpa);
}

fn poolCapacity(
    comptime kind: text_engine.Kind,
    text: *const limits_mod.TextLimits,
) text_engine.Pool(kind).Capacity {
    const kind_limits: limits_mod.TextKindLimits = @field(text, @tagName(kind));
    const count = if (kind == .input) @max(kind_limits.count_max, 1) else kind_limits.count_max;
    assert(count > 0);
    assert(text.preedit_bytes_max > 0);
    return .{
        .count = count,
        .bytes_max = kind_limits.bytes_max,
        .undo_depth_max = kind_limits.undo_depth_max,
        .preedit_bytes_max = text.preedit_bytes_max,
    };
}

fn clipboardBytes(text: *const limits_mod.TextLimits) u32 {
    var bytes = text.input.bytes_max;
    if (text.area.count_max > 0) bytes = @max(bytes, text.area.bytes_max);
    if (text.editor.count_max > 0) bytes = @max(bytes, text.editor.bytes_max);
    assert(bytes > 0);
    return bytes;
}

fn initRenderTargets(self: *Window, limits: *const ResourceLimits) !void {
    const reserved = debugger_mod.reservedLimits(limits);
    assert(reserved.check() == null);
    try self.packed_frame.initInPlace(&.{
        .paint = reserved.paint,
        .paint_record_count_max = reserved.records.paint_record_count_frame_max,
    });
    assert(self.packed_frame.draw_count == 0);
    assert(self.packed_frame.clip_count == 1);
}

fn deinitRenderTargets(self: *Window) void {
    assert(self.packed_frame.clip_count >= 1);
    self.packed_frame.deinit();
}

fn deinitRuntimeStorage(self: *Window, gpa: std.mem.Allocator) void {
    frame_trace.deinit(&self.trace, gpa);
    self.screen_reader.deinit();
    gpa.destroy(self.screen_reader);
    gpa.free(self.text_scratch);
    deinitRenderTargets(self);
    gpa.free(self.dialog_request_bytes);
    gpa.free(self.clipboard_bytes);
    if (self.editors_reserved) self.editors.deinit(gpa);
    if (self.areas_reserved) self.areas.deinit(gpa);
    self.inputs.deinit(gpa);
    self.retained.deinit(gpa);
    deinitWorkers(self, gpa);
    gpa.free(self.dialog_handlers);
    gpa.free(self.job_inbox.entries);
    self.completions.deinit(gpa);
    self.queue.deinit(gpa);
}

pub fn deinit(self: *Window) void {
    assert(self.phase == .idle);
    const gpa = self.gpa;
    self.resources.text_system.run_allocator = self.resources.text_system.allocator;
    deinitRuntimeStorage(self, gpa);
    deinitBuildStorage(self, gpa);
}
