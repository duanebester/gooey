//! Core layout engine — Clay-style flexbox layout algorithm.
//!
//! Engine facade: owns the `LayoutEngine` struct, its element/command/arena
//! storage, the immediate-mode builder API (`openElement`/`closeElement`/
//! `text`/`svg`/`image`), and the `endFrame` orchestrator. The layout phases
//! live in sibling files:
//!
//!   - `sizing_pass.zig`   — min sizes, final sizes, text wrapping.
//!   - `position_pass.zig` — positions, floating positioning.
//!   - `scroll_pass.zig`   — render commands, scissor framing.
//!   - `fuzz.zig`          — fuzz targets for the above.

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
// Capacity Limits
// ============================================================================

pub const MAX_ELEMENTS_PER_FRAME = 16384;

/// Maximum nesting depth for open elements (e.g., nested containers)
pub const MAX_OPEN_DEPTH = 64;

/// Maximum floating elements (dropdowns, tooltips, modals)
pub const MAX_FLOATING_ROOTS = 256;

/// Maximum tracked IDs for collision detection and lookup
pub const MAX_TRACKED_IDS = 4096;

/// Maximum lines per text element when wrapping
pub const MAX_LINES_PER_TEXT = 1024;

/// Maximum words per text element for word-level measurement caching
pub const MAX_WORDS_PER_TEXT = 2048;

/// Maximum recursion depth for layout tree traversal. ~100-200 bytes per
/// frame, so 48 levels ≈ 10KB — safe for a 1MB stack. Real layouts rarely
/// exceed 20 levels; this is a fail-fast cap.
pub const MAX_RECURSION_DEPTH = 48;

/// Threshold for treating a max constraint as effectively unconstrained
/// (detects grow elements without a meaningful upper bound in the fast path).
pub const UNCONSTRAINED_MAX: f32 = 1e10;

/// Word boundary info for text wrapping (measured once per word, not per char)
pub const WordInfo = struct {
    start: u32, // byte offset where word starts
    end: u32, // byte offset where word ends (exclusive)
    width: f32, // measured width of this word
    trailing_space_width: f32, // width of trailing whitespace (space/tab)
    has_newline: bool, // word ends with a forced newline
};

// ============================================================================
// Fixed Capacity Array
// ============================================================================

/// A fixed-capacity array that doesn't allocate after init — used to avoid
/// dynamic allocation during frame rendering.
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

/// Where an element was created (for debugging). Stores compile-time string
/// pointers, so it needs no allocation.
pub const SourceLoc = struct {
    file: ?[*:0]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
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
    /// Cached resolved parent index for floating elements (avoids a hot-path HashMap lookup)
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
        // Pre-allocate at startup to avoid per-frame allocation
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
    /// Stack of open container indices (fixed capacity)
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
    /// Floating elements to position after main layout (fixed capacity)
    floating_roots: FixedCapacityArray(u32, MAX_FLOATING_ROOTS) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var seen_ids = std.AutoHashMap(u32, ?[]const u8).init(allocator);
        var id_to_index = std.AutoHashMap(u32, u32).init(allocator);

        // Pre-allocate hash maps to avoid per-frame allocation
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
        self.open_element_stack.len = 0;
        self.floating_roots.len = 0;
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

    /// Create an element and link it into the tree. The body is a sequence
    /// of named steps (collision check, indexing, floating bookkeeping,
    /// parent linking) so each concern stays isolated.
    fn createElement(self: *Self, decl: ElementDeclaration, elem_type: ElementType) !u32 {
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
    /// an element index up-front, so `computeFloatingPositions` avoids a
    /// hot-path HashMap lookup.
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

    /// End frame and compute layout, returning the render commands.
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

        // Sort by z-index only when floating elements exist (the only source
        // of non-zero z_index). Skips ~O(n log n) on float-free frames.
        if (self.floating_roots.len > 0) {
            self.commands.sortByZIndex();
        }

        return self.commands.items();
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
