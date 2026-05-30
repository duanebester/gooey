//! Core layout engine — Clay-style flexbox layout algorithm.
//!
//! Post-PR-10, this file is the engine **facade**: it owns the
//! `LayoutEngine` struct, its element/command/arena storage, the
//! immediate-mode builder API (`openElement`/`closeElement`/`text`/`svg`/
//! `image`), and the `endFrame` / `endFrameTimed` orchestrators. The four
//! layout phases live in dedicated files alongside this one:
//!
//!   - `sizing_pass.zig`   — Phases 1 and 2 (min sizes, final sizes,
//!                           text wrapping, grow/shrink distribution).
//!   - `position_pass.zig` — Phase 3 (positions, floating positioning).
//!   - `scroll_pass.zig`   — Phase 4 (render commands, scissor framing).
//!   - `fuzz.zig`          — `std.testing.Smith` targets for the above.
//!
//! See [docs/cleanup-implementation-plan.md PR 10](../../docs/cleanup-implementation-plan.md#pr-10--layout-engine-split--fuzz-targets)
//! for the rationale and the disjoint write-scope contract.

const std = @import("std");
const builtin = @import("builtin");

const types = @import("types.zig");
const layout_id = @import("layout_id.zig");
const arena_mod = @import("arena.zig");
const render_commands = @import("render_commands.zig");
const sizing_pass = @import("sizing_pass.zig");
const position_pass = @import("position_pass.zig");
const scroll_pass = @import("scroll_pass.zig");

const Sizing = types.Sizing;
const SizingAxis = types.SizingAxis;
const SizingType = types.SizingType;
const LayoutConfig = types.LayoutConfig;
const LayoutDirection = types.LayoutDirection;
const Padding = types.Padding;
const BoundingBox = types.BoundingBox;
const Color = types.Color;
const ChildAlignment = types.ChildAlignment;
const AlignmentX = types.AlignmentX;
const AlignmentY = types.AlignmentY;
const CornerRadius = types.CornerRadius;
const BorderConfig = types.BorderConfig;
const ShadowConfig = types.ShadowConfig;
const TextConfig = types.TextConfig;

const LayoutId = layout_id.LayoutId;
const LayoutArena = arena_mod.LayoutArena;
const RenderCommand = render_commands.RenderCommand;
const RenderCommandList = render_commands.RenderCommandList;
const RenderCommandType = render_commands.RenderCommandType;

// ============================================================================
// Capacity Limits (per CLAUDE.md: put a limit on everything)
// ============================================================================

/// Maximum elements per frame - prevents unbounded growth
pub const MAX_ELEMENTS_PER_FRAME = 16384;

/// Per-phase timing breakdown for layout benchmarking and profiling.
/// All values in nanoseconds. Zero-cost in production — `endFrame()` skips timing entirely;
/// only `endFrameTimed()` pays the cost of 7 `std.Io.Timestamp.now(..., .awake)` calls (~350ns).
pub const PhaseTimings = struct {
    min_sizes_ns: u64 = 0,
    final_sizes_ns: u64 = 0,
    text_wrapping_ns: u64 = 0,
    positions_ns: u64 = 0,
    floating_ns: u64 = 0,
    render_commands_ns: u64 = 0,
    z_sort_ns: u64 = 0,
    total_ns: u64 = 0,

    pub fn printHeader() void {
        std.debug.print("| {s:<40} | {s:>8} | {s:>9} | {s:>9} | {s:>9} | {s:>9} | {s:>9} | {s:>9} | {s:>9} |\n", .{
            "Test", "Nodes", "MinSizes", "FinalSz", "TextWrap", "Position", "Float", "RenderCmd", "ZSort",
        });
    }

    pub fn print(self: *const PhaseTimings, name: []const u8, node_count: u32, iterations: u32) void {
        const iters: u64 = @intCast(iterations);
        std.debug.assert(iters > 0);
        std.debug.assert(node_count > 0);
        std.debug.print("| {s:<40} | {d:>8} | {d:>7.3} ms | {d:>7.3} ms | {d:>7.3} ms | {d:>7.3} ms | {d:>7.3} ms | {d:>7.3} ms | {d:>7.3} ms |\n", .{
            name,
            node_count,
            @as(f64, @floatFromInt(self.min_sizes_ns / iters)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.final_sizes_ns / iters)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.text_wrapping_ns / iters)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.positions_ns / iters)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.floating_ns / iters)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.render_commands_ns / iters)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.z_sort_ns / iters)) / 1_000_000.0,
        });
    }
};

/// Result type for `endFrameTimed()` — named to avoid Zig anonymous-struct identity issues.
pub const TimedResult = struct {
    commands: []const RenderCommand,
    timings: PhaseTimings,
};

/// Maximum nesting depth for open elements (e.g., nested containers)
pub const MAX_OPEN_DEPTH = 64;

/// Maximum floating elements (dropdowns, tooltips, modals)
pub const MAX_FLOATING_ROOTS = 256;

/// Maximum tracked IDs for collision detection and lookup
pub const MAX_TRACKED_IDS = 4096;

/// Maximum lines per text element when wrapping
pub const MAX_LINES_PER_TEXT = 1024;

/// Maximum words per text element for word-level measurement caching (Phase 2.1)
pub const MAX_WORDS_PER_TEXT = 2048;

/// Maximum recursion depth for layout tree traversal (per CLAUDE.md: put a limit on everything)
/// Safe for typical 1MB stack - each frame is ~100-200 bytes, so 48 levels ≈ 10KB
/// Real UI layouts rarely exceed 20 levels; this limit ensures fail-fast behavior
pub const MAX_RECURSION_DEPTH = 48;

/// Threshold for treating a max constraint as effectively unconstrained
/// Used in fast path to detect grow elements without meaningful upper bounds
pub const UNCONSTRAINED_MAX: f32 = 1e10;

/// Word boundary info for efficient text wrapping (measured once per word, not per char)
pub const WordInfo = struct {
    start: u32, // byte offset where word starts
    end: u32, // byte offset where word ends (exclusive)
    width: f32, // measured width of this word
    trailing_space_width: f32, // width of trailing whitespace (space/tab)
    has_newline: bool, // word ends with a forced newline
};

// ============================================================================
// Fixed Capacity Array (since std.BoundedArray doesn't exist in Zig 0.15)
// ============================================================================

/// A fixed-capacity array that doesn't allocate after initialization.
/// Used to avoid dynamic allocation during frame rendering per CLAUDE.md.
pub fn FixedCapacityArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
        }

        pub fn slice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

// ============================================================================
// Element Types (defined inline)
// ============================================================================

/// Scroll offset for positioning children
pub const ScrollOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Source location for debugging - captures where an element was created
/// Uses fixed-size storage to avoid allocations (zero allocation after init)
pub const SourceLoc = struct {
    /// File name (pointer to compile-time string, no allocation needed)
    file: ?[*:0]const u8 = null,
    /// Line number
    line: u32 = 0,
    /// Column number
    column: u32 = 0,
    /// Function name (pointer to compile-time string)
    fn_name: ?[*:0]const u8 = null,

    pub const none: SourceLoc = .{};

    /// Create from Zig's builtin SourceLocation
    pub fn from(src: std.builtin.SourceLocation) SourceLoc {
        return .{
            .file = src.file.ptr,
            .line = src.line,
            .column = src.column,
            .fn_name = src.fn_name.ptr,
        };
    }

    /// Check if this has valid source information
    pub fn isValid(self: SourceLoc) bool {
        return self.file != null and self.line > 0;
    }

    /// Get file name as a slice (for display)
    pub fn getFile(self: SourceLoc) ?[]const u8 {
        if (self.file) |f| {
            return std.mem.span(f);
        }
        return null;
    }

    /// Get function name as a slice (for display)
    pub fn getFnName(self: SourceLoc) ?[]const u8 {
        if (self.fn_name) |f| {
            return std.mem.span(f);
        }
        return null;
    }

    /// Get just the filename without path (for compact display)
    pub fn getBasename(self: SourceLoc) ?[]const u8 {
        return std.fs.path.basename(self.getFile() orelse return null);
    }
};

pub const ElementDeclaration = struct {
    id: LayoutId = LayoutId.none,
    layout: LayoutConfig = .{},
    background_color: ?Color = null,
    corner_radius: CornerRadius = .{},
    border: ?BorderConfig = null,
    shadow: ?ShadowConfig = null,
    scroll: ?types.ScrollConfig = null,
    floating: ?types.FloatingConfig = null,
    user_data: ?*anyopaque = null,
    /// Opacity for the entire element subtree (0.0 = transparent, 1.0 = opaque)
    opacity: f32 = 1.0,
    /// Source location where this element was created (for debugging)
    source_location: SourceLoc = .{},
    /// Whether this element is a canvas (for deferred paint callbacks)
    is_canvas: bool = false,
};

pub const ElementType = enum {
    container,
    text,
    svg,
    image,
};

pub const TextData = struct {
    text: []const u8,
    config: TextConfig,
    measured_width: f32 = 0,
    measured_height: f32 = 0,
    wrapped_lines: ?[]const types.WrappedLine = null,
    /// Container width for text alignment (set during wrapping)
    container_width: f32 = 0,
};

pub const SvgData = struct {
    path: []const u8,
    color: Color,
    stroke_color: ?Color = null,
    stroke_width: f32 = 1.0,
    has_fill: bool = true,
    viewbox: f32 = 24,
};

pub const ImageData = struct {
    source: []const u8,
    width: ?f32 = null,
    height: ?f32 = null,
    fit: u8 = 0, // 0=contain, 1=cover, 2=fill, 3=none, 4=scale_down
    corner_radius: ?CornerRadius = null,
    tint: ?Color = null,
    grayscale: f32 = 0,
    opacity: f32 = 1,
    /// Placeholder color for WASM async loading (null = default gray)
    placeholder_color: ?Color = null,
};

pub const ComputedLayout = struct {
    bounding_box: BoundingBox = .{},
    content_box: BoundingBox = .{},
    min_width: f32 = 0,
    min_height: f32 = 0,
    sized_width: f32 = 0,
    sized_height: f32 = 0,
    /// Cached resolved parent index for floating elements (Phase 2.3 - eliminates hot-path HashMap lookup)
    resolved_floating_parent: ?u32 = null,
};

pub const LayoutElement = struct {
    id: u32,
    config: ElementDeclaration,
    parent_index: ?u32 = null,
    first_child_index: ?u32 = null,
    last_child_index: ?u32 = null,
    next_sibling_index: ?u32 = null,
    child_count: u32 = 0,
    computed: ComputedLayout = .{},
    element_type: ElementType = .container,
    text_data: ?TextData = null,
    svg_data: ?SvgData = null,
    image_data: ?ImageData = null,
    /// Cached z_index (set during generateRenderCommands for O(1) lookup)
    cached_z_index: i16 = 0,
};

/// Element storage (unmanaged ArrayList pattern)
pub const ElementList = struct {
    allocator: std.mem.Allocator,
    elements: std.ArrayList(LayoutElement),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var list = Self{
            .allocator = allocator,
            .elements = .empty,
        };
        // Pre-allocate per CLAUDE.md: static memory allocation at startup
        list.elements.ensureTotalCapacity(allocator, MAX_ELEMENTS_PER_FRAME) catch {};
        return list;
    }

    pub fn deinit(self: *Self) void {
        self.elements.deinit(self.allocator);
    }

    pub fn clear(self: *Self) void {
        self.elements.clearRetainingCapacity();
    }

    pub fn append(self: *Self, elem: LayoutElement) !u32 {
        const index: u32 = @intCast(self.elements.items.len);
        try self.elements.append(self.allocator, elem);
        return index;
    }

    pub fn get(self: *Self, index: u32) *LayoutElement {
        return &self.elements.items[index];
    }

    pub fn getConst(self: *const Self, index: u32) *const LayoutElement {
        return &self.elements.items[index];
    }

    pub fn len(self: *const Self) u32 {
        return @intCast(self.elements.items.len);
    }

    pub fn items(self: *const Self) []const LayoutElement {
        return self.elements.items;
    }
};

// ============================================================================
// Text Measurement
// ============================================================================

/// Result of text measurement
pub const TextMeasurement = struct {
    width: f32,
    height: f32,
};

/// Text measurement function type
pub const MeasureTextFn = *const fn (
    text: []const u8,
    font_id: u16,
    font_size: u16,
    max_width: ?f32,
    user_data: ?*anyopaque,
) TextMeasurement;

// ============================================================================
// Layout Engine
// ============================================================================

pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    arena: LayoutArena,
    elements: ElementList,
    commands: RenderCommandList,
    /// Stack of open container indices (fixed capacity per CLAUDE.md)
    open_element_stack: FixedCapacityArray(u32, MAX_OPEN_DEPTH) = .{},
    root_index: ?u32 = null,
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    measure_text_fn: ?MeasureTextFn = null,
    measure_text_user_data: ?*anyopaque = null,
    /// Debug: maps ID hash -> string for collision detection
    seen_ids: std.AutoHashMap(u32, ?[]const u8),
    /// Maps element ID -> element index for O(1) lookups
    id_to_index: std.AutoHashMap(u32, u32),
    /// Floating elements to position after main layout (fixed capacity per CLAUDE.md)
    floating_roots: FixedCapacityArray(u32, MAX_FLOATING_ROOTS) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var seen_ids = std.AutoHashMap(u32, ?[]const u8).init(allocator);
        var id_to_index = std.AutoHashMap(u32, u32).init(allocator);

        // Pre-allocate hash maps to avoid allocation during frame (per CLAUDE.md)
        seen_ids.ensureTotalCapacity(MAX_TRACKED_IDS) catch {};
        id_to_index.ensureTotalCapacity(MAX_TRACKED_IDS) catch {};

        return .{
            .allocator = allocator,
            .arena = LayoutArena.init(allocator),
            .elements = ElementList.init(allocator),
            .commands = RenderCommandList.init(allocator),
            .seen_ids = seen_ids,
            .id_to_index = id_to_index,
        };
    }

    pub fn deinit(self: *Self) void {
        self.id_to_index.deinit();
        self.seen_ids.deinit();
        // BoundedArrays don't need deinit (stack-allocated)
        self.commands.deinit();
        self.elements.deinit();
        self.arena.deinit();
    }

    pub fn setMeasureTextFn(self: *Self, func: MeasureTextFn, user_data: ?*anyopaque) void {
        self.measure_text_fn = func;
        self.measure_text_user_data = user_data;
    }

    pub fn beginFrame(self: *Self, width: f32, height: f32) void {
        self.arena.reset();
        self.elements.clear();
        self.commands.clear();
        self.open_element_stack.len = 0; // BoundedArray: just reset length
        self.floating_roots.len = 0; // BoundedArray: just reset length
        if (comptime builtin.mode == .Debug) {
            self.seen_ids.clearRetainingCapacity();
        }
        self.id_to_index.clearRetainingCapacity();
        self.root_index = null;
        self.viewport_width = width;
        self.viewport_height = height;
    }

    pub fn openElement(self: *Self, decl: ElementDeclaration) !void {
        const index = try self.createElement(decl, .container);
        self.open_element_stack.append(index) catch @panic("open_element_stack overflow - increase MAX_OPEN_DEPTH");
    }

    pub fn closeElement(self: *Self) void {
        std.debug.assert(self.open_element_stack.len > 0); // Underflow: more closeElement() calls than openElement()
        _ = self.open_element_stack.pop();
    }

    /// Add a text element (leaf node)
    pub fn text(self: *Self, content: []const u8, config: types.TextConfig) !void {
        std.debug.assert(self.open_element_stack.len > 0);

        var decl = ElementDeclaration{};
        decl.layout.sizing = Sizing.fitContent();

        const index = try self.createElement(decl, .text);
        const elem = self.elements.get(index);
        const text_copy = try self.arena.dupe(content);
        elem.text_data = TextData{
            .text = text_copy,
            .config = config,
        };

        // Measure text if callback available
        if (self.measure_text_fn) |measure_fn| {
            const measured = measure_fn(
                content,
                config.font_id,
                config.font_size,
                null,
                self.measure_text_user_data,
            );
            elem.text_data.?.measured_width = measured.width;
            elem.text_data.?.measured_height = measured.height;
        } else {
            // Fallback: estimate based on font size
            const font_size_f: f32 = @floatFromInt(config.font_size);
            elem.text_data.?.measured_width = @as(f32, @floatFromInt(content.len)) * font_size_f * 0.6;
            elem.text_data.?.measured_height = font_size_f * 1.2;
        }
    }

    /// Add an SVG element (leaf node) - renders inline with correct z-order
    pub fn svg(self: *Self, id: LayoutId, width: f32, height: f32, data: SvgData) !void {
        std.debug.assert(self.open_element_stack.len > 0);

        var decl = ElementDeclaration{};
        decl.id = id;
        decl.layout.sizing = .{
            .width = .{ .value = .{ .fixed = .{ .min = width, .max = width } } },
            .height = .{ .value = .{ .fixed = .{ .min = height, .max = height } } },
        };

        const index = try self.createElement(decl, .svg);
        const elem = self.elements.get(index);
        const path_copy = try self.arena.dupe(data.path);
        elem.svg_data = SvgData{
            .path = path_copy,
            .color = data.color,
            .stroke_color = data.stroke_color,
            .stroke_width = data.stroke_width,
            .has_fill = data.has_fill,
            .viewbox = data.viewbox,
        };
    }

    /// Add an image element (leaf node) - renders inline with correct z-order
    pub fn image(self: *Self, id: LayoutId, width: ?f32, height: ?f32, data: ImageData) !void {
        std.debug.assert(self.open_element_stack.len > 0);

        var decl = ElementDeclaration{};
        decl.id = id;

        // Determine sizing - use fixed if specified, otherwise grow
        decl.layout.sizing = .{
            .width = if (width) |w|
                .{ .value = .{ .fixed = .{ .min = w, .max = w } } }
            else
                .{ .value = .{ .grow = .{} } },
            .height = if (height) |h|
                .{ .value = .{ .fixed = .{ .min = h, .max = h } } }
            else
                .{ .value = .{ .grow = .{} } },
        };

        const index = try self.createElement(decl, .image);
        const elem = self.elements.get(index);
        const source_copy = try self.arena.dupe(data.source);
        elem.image_data = ImageData{
            .source = source_copy,
            .width = data.width,
            .height = data.height,
            .fit = data.fit,
            .corner_radius = data.corner_radius,
            .tint = data.tint,
            .grayscale = data.grayscale,
            .opacity = data.opacity,
            .placeholder_color = data.placeholder_color,
        };
    }

    /// Create an element and link it into the tree.
    ///
    /// Pre-PR-10 this function inlined ID-collision detection, the parent
    /// linking walk, and floating-root bookkeeping. The body now reads as
    /// a sequence of named steps so each concern can be reviewed in
    /// isolation while keeping the function under the 70-line ceiling.
    fn createElement(self: *Self, decl: ElementDeclaration, elem_type: ElementType) !u32 {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(self.elements.len() < MAX_ELEMENTS_PER_FRAME); // Prevent unbounded growth
        std.debug.assert(elem_type != .container or self.open_element_stack.len < MAX_OPEN_DEPTH); // Depth check for containers

        if (comptime builtin.mode == .Debug) self.checkIdCollision(decl.id);

        const parent_index = if (self.open_element_stack.len > 0)
            self.open_element_stack.buffer[self.open_element_stack.len - 1]
        else
            null;

        const index = try self.elements.append(.{
            .id = decl.id.id,
            .config = decl,
            .parent_index = parent_index,
            .element_type = elem_type,
        });

        // Index non-zero IDs for O(1) lookup.
        if (decl.id.id != 0) self.indexElementId(decl.id.id, index);

        // Track floating elements separately + cache resolved parent index.
        if (decl.floating) |floating| self.trackFloatingElement(index, floating);

        // Link to parent (or set root) and bump the parent's child_count.
        self.linkToParent(index, parent_index);

        return index;
    }

    /// Debug-only ID collision detection. Probing a HashMap per element
    /// is measurable overhead in release builds, so this is gated to Debug.
    fn checkIdCollision(self: *Self, id: LayoutId) void {
        if (id.id == 0) return;
        const result = self.seen_ids.getOrPut(id.id) catch unreachable;
        if (result.found_existing) {
            std.log.warn("Layout ID collision detected! ID hash {d} used by both \"{?s}\" and \"{?s}\"", .{
                id.id,
                result.value_ptr.*,
                id.string_id,
            });
        } else {
            result.value_ptr.* = id.string_id;
        }
    }

    /// Insert into `id_to_index` and fail fast on capacity overflow —
    /// silent failures here cause hard-to-debug lookup misses downstream.
    fn indexElementId(self: *Self, id_hash: u32, index: u32) void {
        std.debug.assert(id_hash != 0);
        self.id_to_index.put(id_hash, index) catch |err| {
            std.debug.panic("id_to_index.put failed for ID {d}: {} - increase MAX_TRACKED_IDS", .{ id_hash, err });
        };
    }

    /// Record the index in `floating_roots` and resolve the parent ID into
    /// an element index up-front. Phase 2.3 eliminated a hot-path HashMap
    /// lookup in `computeFloatingPositions` by caching this here.
    fn trackFloatingElement(self: *Self, index: u32, floating: types.FloatingConfig) void {
        self.floating_roots.append(index) catch @panic("floating_roots overflow - increase MAX_FLOATING_ROOTS");
        if (floating.parent_id) |pid| {
            self.elements.get(index).computed.resolved_floating_parent = self.id_to_index.get(pid);
        }
    }

    /// Link a newly-created element into its parent's child list. Uses
    /// `last_child_index` for O(1) append, avoiding the O(n) sibling walk.
    /// Promotes the element to root when no parent is open.
    fn linkToParent(self: *Self, index: u32, parent_index: ?u32) void {
        if (parent_index) |pi| {
            const parent = self.elements.get(pi);
            if (parent.first_child_index == null) {
                parent.first_child_index = index;
            } else {
                self.elements.get(parent.last_child_index.?).next_sibling_index = index;
            }
            parent.last_child_index = index;
            parent.child_count += 1;
        } else {
            self.root_index = index;
        }
    }

    /// End frame and compute layout (zero-cost — no timing instrumentation).
    /// Phase ordering matches `endFrameTimed`; keep the two in lockstep.
    pub fn endFrame(self: *Self) ![]const RenderCommand {
        if (self.root_index == null) return self.commands.items();

        const root = self.root_index.?;

        // Phase 1: Compute minimum sizes (bottom-up).
        sizing_pass.computeMinSizes(self, root, 0);

        // Phase 2: Compute final sizes (top-down).
        sizing_pass.computeFinalSizes(self, root, self.viewport_width, self.viewport_height, 0);

        // Phase 2b: Wrap text now that we know container widths.
        try sizing_pass.computeTextWrapping(self, root);

        // Phase 3: Compute positions (top-down).
        position_pass.computePositions(self, root, 0, 0, 0);

        // Phase 3b: Position floating elements (includes text wrapping for floats).
        try position_pass.computeFloatingPositions(self);

        // Phase 4: Generate render commands.
        try scroll_pass.generateRenderCommands(self, root, 0, 1.0, 0);

        // Sort by z-index only when floating elements exist (they're the only source of non-zero z_index).
        // Skipping the sort saves ~O(n log n) work on frames with no dropdowns/tooltips/modals.
        if (self.floating_roots.len > 0) {
            self.commands.sortByZIndex();
        }

        return self.commands.items();
    }

    /// End frame with per-phase timing breakdown (for benchmarks and profiling).
    /// Returns both the render commands and nanosecond timings for each layout phase.
    /// Pays ~350ns overhead from 7 `std.Io.Timestamp.now(io, .awake)` calls.
    ///
    /// `io` is threaded in so the caller chooses which `std.Io` backend
    /// to sample the clock on — benchmarks use the global single-threaded
    /// instance; production callers pass `cx.io()` / `gooey.io`.
    pub fn endFrameTimed(self: *Self, io: std.Io) !TimedResult {
        var timings = PhaseTimings{};

        if (self.root_index == null) return TimedResult{ .commands = self.commands.items(), .timings = timings };

        const root = self.root_index.?;
        // Monotonic `awake` clock — phase deltas can never go negative
        // even if NTP or the sysadmin adjusts the wall clock mid-frame.
        var t0 = std.Io.Timestamp.now(io, .awake);

        // Phase 1: Compute minimum sizes (bottom-up).
        sizing_pass.computeMinSizes(self, root, 0);
        var t1 = std.Io.Timestamp.now(io, .awake);
        timings.min_sizes_ns = durationNs(t0, t1);

        // Phase 2: Compute final sizes (top-down).
        sizing_pass.computeFinalSizes(self, root, self.viewport_width, self.viewport_height, 0);
        t0 = std.Io.Timestamp.now(io, .awake);
        timings.final_sizes_ns = durationNs(t1, t0);

        // Phase 2b: Wrap text now that we know container widths.
        try sizing_pass.computeTextWrapping(self, root);
        t1 = std.Io.Timestamp.now(io, .awake);
        timings.text_wrapping_ns = durationNs(t0, t1);

        // Phase 3: Compute positions (top-down).
        position_pass.computePositions(self, root, 0, 0, 0);
        t0 = std.Io.Timestamp.now(io, .awake);
        timings.positions_ns = durationNs(t1, t0);

        // Phase 3b: Position floating elements (includes text wrapping for floats).
        try position_pass.computeFloatingPositions(self);
        t1 = std.Io.Timestamp.now(io, .awake);
        timings.floating_ns = durationNs(t0, t1);

        // Phase 4: Generate render commands.
        try scroll_pass.generateRenderCommands(self, root, 0, 1.0, 0);
        t0 = std.Io.Timestamp.now(io, .awake);
        timings.render_commands_ns = durationNs(t1, t0);

        // Sort by z-index only when floating elements exist (they're the only source of non-zero z_index).
        // Skipping the sort saves ~O(n log n) work on frames with no dropdowns/tooltips/modals.
        if (self.floating_roots.len > 0) {
            self.commands.sortByZIndex();
        }
        t1 = std.Io.Timestamp.now(io, .awake);
        timings.z_sort_ns = durationNs(t0, t1);

        timings.total_ns = timings.min_sizes_ns + timings.final_sizes_ns +
            timings.text_wrapping_ns + timings.positions_ns +
            timings.floating_ns + timings.render_commands_ns + timings.z_sort_ns;

        return TimedResult{ .commands = self.commands.items(), .timings = timings };
    }

    /// Convert a monotonic `(from, to)` timestamp pair into elapsed nanoseconds.
    /// Extracted so the hot `endFrameTimed` body reads as data flow, not casts.
    /// Monotonic clock guarantees the delta is non-negative — asserted.
    inline fn durationNs(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
        const ns = from.durationTo(to).toNanoseconds();
        std.debug.assert(ns >= 0);
        return @intCast(ns);
    }

    /// Get computed bounding box for an element by ID (O(1) lookup)
    pub fn getBoundingBox(self: *const Self, id: u32) ?BoundingBox {
        const index = self.id_to_index.get(id) orelse return null;
        return self.elements.getConst(index).computed.bounding_box;
    }

    /// Get computed content box (inside padding) for an element by ID (O(1) lookup)
    pub fn getContentBox(self: *const Self, id: u32) ?BoundingBox {
        const index = self.id_to_index.get(id) orelse return null;
        return self.elements.getConst(index).computed.content_box;
    }

    /// Get z-index for an element by ID (O(1) lookup using cached value)
    /// Returns the z_index from the nearest floating ancestor, or 0 for non-floating subtrees.
    /// The z_index is cached during generateRenderCommands.
    pub fn getZIndex(self: *const Self, id: u32) i16 {
        const index = self.id_to_index.get(id) orelse return 0;
        return self.elements.getConst(index).cached_z_index;
    }
};
