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
const id_mod = @import("id.zig");
const records = @import("records.zig");
const handler_mod = @import("handler.zig");
const events = @import("events.zig");
const retained_mod = @import("retained.zig");
const text_engine = @import("text_engine.zig");
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
};

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
    checked: bool,
    disabled: bool,
    heading_level: a11y_types.HeadingLevel,
    live: a11y_types.Live,
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
/// backend: `MockFileDialog` on TestBackend, AppKit's open panel on macOS.
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
    /// Ids from the pressed record up to the root, captured on press. A
    /// release fires the click handlers of records in this path only, so a
    /// press that slides off a button does not click it (decision 7).
    press_path: [box_depth_max]ElementId,
    press_len: u32,
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
    self.resources.text_system.useRunAllocator(self.text_scratch_allocator.allocator());
    self.cx = .{ .window = self };
    self.presenter = null;
    self.file_dialog = null;
    self.focus = .root;
    self.hover_len = 0;
    self.press_len = 0;
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
    try self.inputs.initInPlace(gpa, @max(input.count_max, 1), input.bytes_max);
    errdefer self.inputs.deinit(gpa);
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

fn deinitRuntimeStorage(self: *Window, gpa: std.mem.Allocator) void {
    self.screen_reader.deinit();
    gpa.destroy(self.screen_reader);
    gpa.free(self.text_scratch);
    self.scene.deinit();
    gpa.destroy(self.scene);
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
