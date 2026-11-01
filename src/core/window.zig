//! Per-window core state: build storage, the two record frames, the event
//! queue, retained state, text engines, focus and hover, and the pack target.
//!
//! Everything is reserved in `initInPlace` from `ResourceLimits`; after the
//! app crosses the initialization boundary the window only claims and
//! releases slots in this storage (contract rule 4, CLAUDE.md §2).
//!
//! Performance sketch per window at `.small` (todo): 2,048 nodes × ~120 B
//! (0.24 MiB); two frames of 8,192 paint records × 88 B, 2,048 hit records,
//! 2,048 handlers, and 64 KiB of text (≈1.9 MiB); 128 queued events; 16
//! input engines × 4 KiB; a 176 KiB layout arena for text copies and 4,096
//! wrapped lines, resident only as far as a frame writes; 256 KiB of text
//! scratch; and the 0.3.1 scene at `limits.scene`, which pack fills. The layout
//! engine keeps its fixed 16,384-element reservation until phase 4 ports
//! layout, so `build.element_count_frame_max` is checked against it.

const std = @import("std");
const builtin = @import("builtin");
const id_mod = @import("id.zig");
const records = @import("records.zig");
const handler_mod = @import("handler.zig");
const events = @import("events.zig");
const retained_mod = @import("retained.zig");
const text_engine = @import("text_engine.zig");
const clipboard_mod = @import("clipboard.zig");
const element = @import("element.zig");
const limits_mod = @import("limits.zig");
const layout_mod = @import("../layout/layout.zig");
const reservation = @import("reservation.zig");
const scene_mod = @import("../scene/mod.zig");
const text_mod = @import("../text/mod.zig");
const app_resources = @import("../context/app_resources.zig");
const a11y_types = @import("../accessibility/types.zig");
const cx_mod = @import("cx.zig");
const keymap_mod = @import("keymap.zig");
const A11ySystem = @import("../context/a11y_system.zig").A11ySystem;
const screen_reader_mod = @import("screen_reader.zig");

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;
pub const Frame = records.Frame;
pub const ResourceLimits = limits_mod.ResourceLimits;
pub const AppResources = app_resources.AppResources;
pub const LayoutEngine = layout_mod.LayoutEngine;
pub const Scene = scene_mod.Scene;

pub const Phase = enum { idle, drain, build, layout, emit, pack, draw };

/// Deepest box nesting the build tracks. The 0.3.1 layout engine stops at
/// `MAX_OPEN_DEPTH` (64), so the core cannot nest deeper until phase 4.
pub const box_depth_max: u32 = layout_mod.engine.MAX_OPEN_DEPTH;

/// Bytes of text-system scratch per tick for shaped runs on a shape-cache
/// miss: one run of `MAX_GLYPHS_PER_ENTRY` glyphs, several times over for
/// the shaper's own growth, reset at the start of every tick.
pub const text_scratch_bytes: u32 = 256 * 1024;

comptime {
    // A file dialog's platform code allocates its paths and their slices from
    // the text scratch, and `events.Paths.join` copies them once more, so a
    // selection within every profile's limits always fits.
    const dialog = limits_mod.EventLimits.ceiling;
    assert(2 * dialog.dialog_path_bytes_max + 16 * dialog.dialog_path_count_max <=
        text_scratch_bytes);
}

comptime {
    // The longest run every shaper accepts fits the scratch four times over:
    // the web shaper holds codepoints, byte offsets, and a growing glyph list
    // in it at once, and the run's owner frees it before the next run shapes.
    const run_bytes = text_mod.run_codepoint_count_max * @sizeOf(text_mod.ShapedGlyph);
    assert(4 * run_bytes <= text_scratch_bytes);
}

/// Fail fast on text the core cannot shape or measure (CLAUDE.md §2): a run
/// past the shapers' bound is a capacity error and names it.
pub fn textFailed(frame_number: u64, content: []const u8, err: anyerror) noreturn {
    if (err == error.TextRunTooLong) {
        std.debug.panic("text run of {d} codepoints exceeds text.run_codepoint_count_max " ++
            "{d}, the longest run one shaping may hold in the {d}-byte text scratch, in " ++
            "frame {d}. Split the text into shorter runs.", .{
            text_mod.codepointCount(content),
            text_mod.run_codepoint_count_max,
            text_scratch_bytes,
            frame_number,
        });
    }
    std.debug.panic("text shaping failed in frame {d}: {s}", .{ frame_number, @errorName(err) });
}

/// File dialogs awaiting their completion. One opens per tick, and its
/// completion is delivered the next tick, so a handful covers bursts.
pub const dialog_count_max: u32 = 8;

/// `render_deadline_ns` when the last build asked for no timed render.
pub const deadline_none: u64 = std.math.maxInt(u64);

/// The longest `cx.requestRenderAfter` delay, shared with the platforms.
pub const render_delay_ms_max: u32 = @import("../platform/interface.zig").render_delay_ms_max;

pub const NodeKind = enum { box, text, paint };

/// One built element. Index `i` is layout element `i` (both pre-order).
pub const Node = struct {
    kind: NodeKind,
    id: ElementId,
    parent: u32,
    depth: u8,
    /// Unkeyed children seen so far, for `ElementId.auto`.
    child_count: u32,
    // Box.
    focusable: bool,
    hit: bool,
    cursor: ?element.CursorShape,
    on_click: u32,
    on_click_outside: u32,
    on_key: u32,
    key_context: u64,
    actions_start: u32,
    actions_len: u32,
    a11y: ?A11yBuilt,
    background: ?records.Color,
    border: records.Border,
    corners: records.Corners,
    shadow: ?element.Shadow,
    shadow_color: records.Color,
    // Text.
    text: records.TextRange,
    text_color: records.Color,
    font_size: u16,
    family: text_mod.FontFamily,
    variant: text_mod.FontVariant,
    // Paint.
    paint_fn: ?*const fn (data: *const anyopaque, painter: *anyopaque) void,
    paint_data: ?*const anyopaque,
    // Clip and scroll (`Style.clip`, `Style.scroll`).
    clip: bool,
    scroll: ?retained_mod.Handle(ScrollState),
    /// A `.popover` or `.modal` box opens a fragment that emit paints after
    /// the fragment that opened it.
    layer: ?element.Layer,
};

/// A scroll box's offset, retained by its key (contract §1), and what the
/// last emit measured, so the router clamps a wheel step and the next build
/// clamps a shrunk content without waiting for layout. The scrollbar's
/// geometry lives here too, so emit draws the bar the router hit-tests.
pub const ScrollState = struct {
    offset_x: f32,
    offset_y: f32,
    content_width: f32,
    content_height: f32,
    /// The box's bounds at the last emit, unclipped.
    viewport: records.Rect,
    axes: element.Scroll,
    /// The thumb the pointer is dragging, as 0.3.1's scroll containers do,
    /// with the pointer coordinate and offset along that axis at the press.
    dragging: ?ScrollAxis,
    drag_pointer_start: f32,
    drag_offset_start: f32,

    // 0.3.1's scrollbar (`widgets/scroll_container.zig`). Its hover colour
    // shows while the thumb is dragged; 0.3.1 never set its hover flag.
    pub const scrollbar_size: f32 = 8;
    pub const scrollbar_padding: f32 = 2;
    pub const scrollbar_room: f32 = scrollbar_size + scrollbar_padding;
    pub const scrollbar_thumb_min: f32 = 30;

    pub fn init(self: *ScrollState) void {
        self.* = .{
            .offset_x = 0,
            .offset_y = 0,
            .content_width = 0,
            .content_height = 0,
            .viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .axes = .{},
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

    /// Keep the offset inside the last measured content. Returns whether
    /// it moved.
    pub fn clamp(self: *ScrollState) bool {
        const x = std.math.clamp(self.offset_x, 0, self.maxX());
        const y = std.math.clamp(self.offset_y, 0, self.maxY());
        const moved = x != self.offset_x or y != self.offset_y;
        self.offset_x = x;
        self.offset_y = y;
        assert(self.offset_y >= 0);
        return moved;
    }

    /// Scroll by a wheel delta, as 0.3.1's scroll containers do: offsets
    /// follow the delta, inverted on macOS (natural scrolling). Returns
    /// whether the offset moved, so a box that cannot scroll lets the wheel
    /// reach its ancestors.
    pub fn wheel(self: *ScrollState, delta_x: f32, delta_y: f32) bool {
        assert(std.math.isFinite(delta_x));
        assert(std.math.isFinite(delta_y));
        const direction: f32 = if (builtin.os.tag == .macos) -1 else 1;
        const before_x = self.offset_x;
        const before_y = self.offset_y;
        if (self.maxX() > 0) self.offset_x += delta_x * direction;
        if (self.maxY() > 0) self.offset_y += delta_y * direction;
        _ = self.clamp();
        return self.offset_x != before_x or self.offset_y != before_y;
    }

    /// The scrollbar track along `axis`, inset by the padding at the box's
    /// far edge; null when the content does not overflow that axis.
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

    /// The thumb within `bar` (`track(axis)`): proportional to the visible
    /// share of the content, at least `scrollbar_thumb_min`, placed by the
    /// scroll fraction.
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

    /// A press on a scrollbar: on the thumb it starts a drag; elsewhere on
    /// the track it jumps to the pressed fraction, as 0.3.1 does. Returns
    /// whether the point was on a scrollbar.
    pub fn press(self: *ScrollState, x: f32, y: f32) bool {
        assert(self.dragging == null);
        inline for (.{ ScrollAxis.y, ScrollAxis.x }) |axis| {
            if (self.track(axis)) |bar| {
                if (bar.contains(x, y)) {
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
            }
        }
        return false;
    }

    /// Follow a dragged thumb: the pointer's travel along the track, scaled
    /// from the thumb's range to the offset's. Returns whether it moved.
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

/// A family name copied out of a handler's `Effects.setFont`, so the request
/// outlives the handler's slice.
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
    disabled: bool,
    expanded: bool,
    has_popup: bool,
    heading_level: a11y_types.HeadingLevel,
    live: a11y_types.Live,
    pos_in_set: ?u16,
    set_size: ?u16,
};

/// Frame-wide set of keyed ids: duplicate detection during build, and the
/// "was this scope rendered" query for the retained sweep.
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

    /// Insert `id`; false when it was already present this frame.
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

/// Draws a packed frame. TestBackend binds the `NullRenderer`; a platform
/// window binds its renderer. One call per tick (bounded dispatch, §6).
pub const Presenter = struct {
    context: *anyopaque,
    /// Runs on the render side. Reads only its arguments: the main thread
    /// may be draining events into the window meanwhile.
    draw: *const fn (
        context: *anyopaque,
        scene: *const Scene,
        frame: *const Frame,
        clear: records.Color,
    ) void,
};

/// Runs a file dialog on the main thread and returns its outcome. Bound per
/// backend: AppKit's panels on macOS, the XDG portal on Linux, and a
/// scripted service in tests.
pub const FileDialogService = struct {
    context: *anyopaque,
    open: *const fn (
        context: *anyopaque,
        scratch: std.mem.Allocator,
        request: handler_mod.FileDialogRequest,
    ) events.Completion.Outcome,
};

pub const Window = struct {
    gpa: std.mem.Allocator,
    limits: ResourceLimits,
    theme: *const element.Theme,
    /// The app's keymap, parsed at compile time (static storage).
    keymap: []const keymap_mod.Compiled,
    store: *handler_mod.Store,
    resources: *AppResources,
    layout: *LayoutEngine,
    /// From `reservation.zig`, so only the prefix frames write becomes resident.
    layout_arena: []u8,
    /// The arena's high-water mark, zeroed on release (CLAUDE.md §21).
    layout_arena_used_max: usize,
    nodes: []Node,
    node_count: u32,
    keys: KeySet,
    frames: [2]Frame,
    built_index: u1,
    queue: events.EventQueue,
    completions: events.CompletionRing,
    retained: retained_mod.Retained,
    inputs: text_engine.InputPool,
    /// Reserved only when `limits.text.area.count_max > 0`; retaining an
    /// area otherwise fails fast (`areaPool`).
    areas: text_engine.AreaPool,
    areas_reserved: bool,
    /// Reserved only when `limits.text.editor.count_max > 0` (`editorPool`).
    editors: text_engine.EditorPool,
    editors_reserved: bool,
    /// The text engines' clipboard; a host binds its platform service.
    clipboard: clipboard_mod.Clipboard,
    clipboard_bytes: []u8,
    /// A save request's folder and suggested name, copied when its handler
    /// returns so they outlive the handler's frame
    /// (`limits.events.dialog_path_bytes_max` bytes).
    dialog_request_bytes: []u8,
    scene: *Scene,
    text_scratch: []u8,
    text_scratch_allocator: std.heap.FixedBufferAllocator,
    cx: cx_mod.Cx,
    presenter: ?Presenter,
    file_dialog: ?FileDialogService,
    // Interaction state, owned by the router.
    focus: ElementId,
    hover_path: [box_depth_max]ElementId,
    hover_len: u32,
    /// The hovered record's cursor, or the nearest ancestor's that sets one;
    /// `.default` over none. Hosts apply it after a tick when it changed.
    cursor: element.CursorShape,
    /// Ids from the pressed record up to the root, captured on press. A
    /// release fires the click handlers of records in this path only, so a
    /// press that slides off a button does not click it (decision 7).
    press_path: [box_depth_max]ElementId,
    press_len: u32,
    /// The scroll box whose thumb is being dragged, or `.root`. The drag
    /// lives in its `ScrollState` until the release.
    scroll_drag: ElementId,
    pointer: ?struct { x: f32, y: f32 },
    // Tick state.
    phase: Phase,
    /// Set by the main thread when a built frame is complete and cleared by
    /// the render side once it has drawn it (contract rule 1). The only field
    /// both threads touch: its release and acquire order the frame contents,
    /// and while it is set the main thread neither builds nor flips frames.
    frame_in_flight: std.atomic.Value(bool),
    /// The main thread published a frame and has not yet made it `rendered`.
    awaiting_flip: bool,
    /// The render side's phase (idle, pack, draw); only that side touches it.
    render_phase: Phase,
    /// This window's key in the shared atlas upload journal: its platform
    /// window's address once a host registers it as a consumer, else its own.
    atlas_consumer_key: usize,
    /// The atlas frame the last build opened; glyphs used since stay resident
    /// until the consumer has uploaded it, older ones may be evicted.
    atlas_frame: u64,
    frame_number: u64,
    render_requested: bool,
    /// The earliest `cx.requestRenderAfter` of the last build, on the window
    /// clock, or `deadline_none`. Main thread only: wasm32 has no 64-bit
    /// atomics, so a host whose render thread needs it keeps its own copy.
    render_deadline_ns: u64,
    /// The earliest request of the build in progress (main thread only).
    build_deadline_ns: u64,
    quit_requested: bool,
    pending_dialog: ?handler_mod.FileDialogRequest,
    /// A font change from `Effects.setFont`, applied by the next tick that
    /// finds no frame in flight; the latest request wins.
    pending_font: ?PendingFont,
    /// Announcements made since the last build, which hands them to its frame.
    announcements: records.Announcements,
    /// The platform's screen-reader bridge and the tree it diffs.
    screen_reader: *A11ySystem,
    screen_reader_poll: screen_reader_mod.Poll,
    dialog_handlers: [dialog_count_max]?handler_mod.Handler,
    dialogs_opened: u32,
    now_ns: u64,
    width: f32,
    height: f32,
    scale_factor: f32,
    clear_color: records.Color,
    // Build state, owned by `Cx`.
    open_stack: [box_depth_max]u32,
    open_depth: u32,
    component_depth: u32,
    component_depth_peak: u32,
    /// Stack addresses for the depth measurement: the outermost `render`
    /// of the current build, and the outermost and deepest of the peak.
    depth_base_address: usize,
    depth_peak_base_address: usize,
    depth_peak_address: usize,

    pub fn built(self: *Window) *Frame {
        return &self.frames[self.built_index];
    }

    /// When the last build asked to render again, if it did (contract §5).
    pub fn renderDeadlineNs(self: *const Window) ?u64 {
        assert(self.phase == .idle);
        const deadline = self.render_deadline_ns;
        return if (deadline == deadline_none) null else deadline;
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

    /// Record how far this frame's text copies and wrapped lines reached.
    pub fn noteLayoutArenaUse(self: *Window) void {
        self.assertPhase(.layout);
        const used = self.layout.arena.fixedBytesUsed();
        assert(used <= self.layout_arena.len);
        self.layout_arena_used_max = @max(self.layout_arena_used_max, used);
    }

    pub fn assertPhase(self: *const Window, phase: Phase) void {
        if (self.phase != phase) {
            std.debug.panic("core call needs phase {t}, window is in {t}", .{ phase, self.phase });
        }
    }

    pub fn isFocused(self: *const Window, id: ElementId) bool {
        return id != .root and self.focus == id;
    }

    pub fn isHovered(self: *const Window, id: ElementId) bool {
        assert(self.hover_len <= box_depth_max);
        for (self.hover_path[0..self.hover_len]) |hovered| {
            if (hovered == id) return true;
        }
        return false;
    }

    /// Stack bytes per component level at the deepest nesting seen: the
    /// distance between the outermost and the deepest `cx.render` frames,
    /// divided by the levels between them. Zero until a nesting of 2.
    pub fn stackBytesPerLevel(self: *const Window) u64 {
        if (self.component_depth_peak < 2) return 0;
        assert(self.depth_peak_base_address >= self.depth_peak_address);
        const span = self.depth_peak_base_address - self.depth_peak_address;
        return span / (self.component_depth_peak - 1);
    }

    /// Replace the headless bridge with the platform's, during
    /// initialization, once the native window exists. `native_window` and
    /// `native_view` are what `accessibility.createPlatformBridge` takes:
    /// NSWindow and NSView on macOS, null elsewhere.
    pub fn bindScreenReader(self: *Window, native_window: anytype, native_view: anytype) void {
        assert(self.phase == .idle);
        self.screen_reader.deinit();
        self.screen_reader.initInPlace(native_window, native_view);
        self.screen_reader_poll = .{};
        assert(self.screen_reader.bridgeAddressValid());
    }

    /// Return to the headless bridge before the native window goes away.
    pub fn unbindScreenReader(self: *Window) void {
        assert(self.phase == .idle);
        self.screen_reader.deinit();
        self.screen_reader.initHeadlessInPlace();
    }

    /// The area engines, which an app reserves with `limits.text.area`.
    pub fn areaPool(self: *Window) *text_engine.AreaPool {
        if (!self.areas_reserved) {
            std.debug.panic("text pool 'area' has capacity 0: set limits.text.area.count_max " ++
                "to the most TextAreas rendered at once (frame {d})", .{self.frame_number});
        }
        return &self.areas;
    }

    /// The editor engines, which an app reserves with `limits.text.editor`.
    pub fn editorPool(self: *Window) *text_engine.EditorPool {
        if (!self.editors_reserved) {
            std.debug.panic("text pool 'editor' has capacity 0: set " ++
                "limits.text.editor.count_max to the most CodeEditors rendered at once " ++
                "(frame {d})", .{self.frame_number});
        }
        return &self.editors;
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
    keymap: []const keymap_mod.Compiled,
    store: *handler_mod.Store,
    resources: *AppResources,
};

pub noinline fn initInPlace(self: *Window, gpa: std.mem.Allocator, options: *const Options) !void {
    assert(options.width > 0);
    assert(options.scale_factor > 0);
    assert(options.limits.check() == null);
    const limits = options.limits;
    self.gpa = gpa;
    self.limits = limits.*;
    self.theme = options.theme;
    self.keymap = options.keymap;
    self.store = options.store;
    self.resources = options.resources;
    try initBuildStorage(self, gpa, limits);
    errdefer deinitBuildStorage(self, gpa);
    try initRuntimeStorage(self, gpa, limits);
    errdefer deinitRuntimeStorage(self, gpa);

    self.store.registerPool(self.inputs.entityPool());
    if (self.areas_reserved) self.store.registerPool(self.areas.entityPool());
    if (self.editors_reserved) self.store.registerPool(self.editors.entityPool());
    self.resources.text_system.useRunAllocator(self.text_scratch_allocator.allocator());
    self.cx = .{ .window = self };
    self.presenter = null;
    self.file_dialog = null;
    self.focus = .root;
    self.hover_len = 0;
    self.cursor = .default;
    self.press_len = 0;
    self.scroll_drag = .root;
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
    self.dialog_handlers = @splat(null);
    self.now_ns = 0;
    self.width = options.width;
    self.height = options.height;
    self.scale_factor = options.scale_factor;
    self.clear_color = options.theme.bg;
    self.open_depth = 0;
    self.component_depth = 0;
    self.component_depth_peak = 0;
    self.depth_base_address = 0;
    self.depth_peak_base_address = 0;
    self.depth_peak_address = 0;
    assert(self.built_index == 0);
}

/// The layout arena holds the frame's text copies (at most the text budget,
/// doubled as 0.3.1's growing arena allowed) and its wrapped lines (contract
/// decision 9). The core builds no floating elements, so each text wraps once
/// per frame, and the layout engine caps a frame's wrapped lines at the glyph
/// budget: a frame that wraps more lines than it can draw glyphs is almost
/// all blank lines, a capacity-planning error that panics naming the pool.
/// From fresh pages, so only what a frame touches becomes resident.
fn layoutArenaBytes(limits: *const ResourceLimits) u32 {
    const text_bytes: u64 = limits.build.text_bytes_frame_max;
    const line_count: u64 = limits.scene.glyph_count_frame_max;
    assert(text_bytes > 0);
    assert(line_count > 0);
    const line_bytes = @sizeOf(layout_mod.types.WrappedLine);
    comptime assert(line_bytes == 12);
    // Build copies every text before layout wraps any, so the line slices
    // follow the copies with one alignment gap, inside the doubled text bytes.
    const bytes = text_bytes * 2 + line_count * line_bytes;
    assert(bytes <= std.math.maxInt(u32));
    return @intCast(bytes);
}

fn initBuildStorage(self: *Window, gpa: std.mem.Allocator, limits: *const ResourceLimits) !void {
    const element_count = limits.build.element_count_frame_max + 1; // The window root.
    assert(element_count <= layout_mod.engine.MAX_ELEMENTS_PER_FRAME);
    self.layout = try gpa.create(LayoutEngine);
    errdefer gpa.destroy(self.layout);
    self.layout.* = try LayoutEngine.init(gpa);
    errdefer self.layout.deinit();
    self.layout_arena = try reservation.reserve(u8, layoutArenaBytes(limits));
    errdefer reservation.release(u8, self.layout_arena, 0);
    self.layout_arena_used_max = 0;
    self.layout.arena.useFixedBuffer(self.layout_arena);
    self.layout.wrapped_line_count_frame_max = limits.scene.glyph_count_frame_max;
    self.nodes = try gpa.alloc(Node, element_count);
    errdefer gpa.free(self.nodes);
    self.node_count = 0;
    try self.keys.initInPlace(gpa, limits.build.key_count_frame_max);
    errdefer self.keys.deinit(gpa);
    const capacity = records.FrameCapacity{
        .paint_record_count_max = limits.records.paint_record_count_frame_max,
        .hit_record_count_max = limits.records.hit_record_count_frame_max,
        .handler_count_max = limits.records.handler_count_frame_max,
        .a11y_node_count_max = element_count,
        .text_bytes_max = limits.build.text_bytes_frame_max,
    };
    try self.frames[0].initInPlace(gpa, &capacity);
    errdefer self.frames[0].deinit(gpa);
    try self.frames[1].initInPlace(gpa, &capacity);
    self.built_index = 0;
}

fn deinitBuildStorage(self: *Window, gpa: std.mem.Allocator) void {
    self.frames[1].deinit(gpa);
    self.frames[0].deinit(gpa);
    self.keys.deinit(gpa);
    gpa.free(self.nodes);
    reservation.release(u8, self.layout_arena, self.layout_arena_used_max);
    self.layout.deinit();
    gpa.destroy(self.layout);
}

fn initRuntimeStorage(self: *Window, gpa: std.mem.Allocator, limits: *const ResourceLimits) !void {
    try self.queue.initInPlace(gpa, .{
        .event_count_max = limits.events.queue_count_max,
        .text_bytes_max = limits.events.text_bytes_max,
    });
    errdefer self.queue.deinit(gpa);
    try self.completions.initInPlace(
        gpa,
        std.math.ceilPowerOfTwoAssert(u32, limits.events.completion_count_max),
    );
    errdefer self.completions.deinit(gpa);
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
    // A text kind with a count of 0 reserves nothing; an app without inputs
    // still gets a one-slot pool so the store's entity table is uniform.
    const input = limits.text.input;
    try self.inputs.initInPlace(gpa, .{
        .count = @max(input.count_max, 1),
        .bytes_max = input.bytes_max,
        .undo_depth_max = input.undo_depth_max,
    });
    errdefer self.inputs.deinit(gpa);
    const area = limits.text.area;
    self.areas_reserved = area.count_max > 0;
    if (self.areas_reserved) {
        try self.areas.initInPlace(gpa, .{
            .count = area.count_max,
            .bytes_max = area.bytes_max,
            .undo_depth_max = area.undo_depth_max,
        });
    }
    errdefer if (self.areas_reserved) self.areas.deinit(gpa);
    const editor = limits.text.editor;
    self.editors_reserved = editor.count_max > 0;
    if (self.editors_reserved) {
        try self.editors.initInPlace(gpa, .{
            .count = editor.count_max,
            .bytes_max = editor.bytes_max,
            .undo_depth_max = editor.undo_depth_max,
        });
    }
    errdefer if (self.editors_reserved) self.editors.deinit(gpa);
    // One clipboard buffer for copy and paste, as large as the largest kind
    // that has engines (decision 10).
    self.clipboard_bytes = try gpa.alloc(u8, clipboardBytes(&limits.text));
    errdefer gpa.free(self.clipboard_bytes);
    self.clipboard = .init(self.clipboard_bytes);
    self.dialog_request_bytes = try gpa.alloc(u8, limits.events.dialog_path_bytes_max);
    errdefer gpa.free(self.dialog_request_bytes);
    self.scene = try gpa.create(Scene);
    errdefer gpa.destroy(self.scene);
    self.scene.* = try Scene.initCapacity(gpa, &limits.scene);
    errdefer self.scene.deinit();
    self.text_scratch = try gpa.alloc(u8, text_scratch_bytes);
    errdefer gpa.free(self.text_scratch);
    self.text_scratch_allocator = std.heap.FixedBufferAllocator.init(self.text_scratch);
    // Headless until a host binds its platform's bridge (`bindScreenReader`).
    self.screen_reader = try gpa.create(A11ySystem);
    self.screen_reader.initHeadlessInPlace();
    self.screen_reader_poll = .{};
}

/// The largest `bytes_max` among text kinds with engines; at least the
/// input kind's, which always has a pool.
fn clipboardBytes(text: *const limits_mod.TextLimits) u32 {
    var bytes = text.input.bytes_max;
    if (text.area.count_max > 0) bytes = @max(bytes, text.area.bytes_max);
    if (text.editor.count_max > 0) bytes = @max(bytes, text.editor.bytes_max);
    assert(bytes > 0);
    return bytes;
}

fn deinitRuntimeStorage(self: *Window, gpa: std.mem.Allocator) void {
    self.screen_reader.deinit();
    gpa.destroy(self.screen_reader);
    gpa.free(self.text_scratch);
    self.scene.deinit();
    gpa.destroy(self.scene);
    gpa.free(self.dialog_request_bytes);
    gpa.free(self.clipboard_bytes);
    if (self.editors_reserved) self.editors.deinit(gpa);
    if (self.areas_reserved) self.areas.deinit(gpa);
    self.inputs.deinit(gpa);
    self.retained.deinit(gpa);
    self.completions.deinit(gpa);
    self.queue.deinit(gpa);
}

pub fn deinit(self: *Window) void {
    assert(self.phase == .idle);
    const gpa = self.gpa;
    // The text system outlives the window; hand shaped runs back to its own
    // allocator before the scratch goes away.
    self.resources.text_system.run_allocator = self.resources.text_system.allocator;
    deinitRuntimeStorage(self, gpa);
    deinitBuildStorage(self, gpa);
}
