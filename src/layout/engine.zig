//! Core layout engine - implements Clay-style flexbox layout algorithm

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const layout_id = @import("layout_id.zig");
const arena_mod = @import("arena.zig");
const render_commands = @import("render_commands.zig");

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
            .elements = .{},
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

    /// Create an element and link it into the tree
    fn createElement(self: *Self, decl: ElementDeclaration, elem_type: ElementType) !u32 {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(self.elements.len() < MAX_ELEMENTS_PER_FRAME); // Prevent unbounded growth
        std.debug.assert(elem_type != .container or self.open_element_stack.len < MAX_OPEN_DEPTH); // Depth check for containers

        // Check for ID collisions in debug builds only — the HashMap probe per element
        // is measurable overhead in release and the warning is only logged in debug anyway.
        if (comptime builtin.mode == .Debug) {
            if (decl.id.id != 0) {
                const result = self.seen_ids.getOrPut(decl.id.id) catch unreachable;
                if (result.found_existing) {
                    std.log.warn("Layout ID collision detected! ID hash {d} used by both \"{?s}\" and \"{?s}\"", .{
                        decl.id.id,
                        result.value_ptr.*,
                        decl.id.string_id,
                    });
                } else {
                    result.value_ptr.* = decl.id.string_id;
                }
            }
        }

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

        // Index non-zero IDs for O(1) lookup
        if (decl.id.id != 0) {
            self.id_to_index.put(decl.id.id, index) catch |err| {
                // Fail fast per CLAUDE.md - silent failures cause hard-to-debug issues
                std.debug.panic("id_to_index.put failed for ID {d}: {} - increase MAX_TRACKED_IDS", .{ decl.id.id, err });
            };
        }

        // Track floating elements separately (BoundedArray - fixed capacity)
        if (decl.floating) |floating| {
            self.floating_roots.append(index) catch @panic("floating_roots overflow - increase MAX_FLOATING_ROOTS");

            // Phase 2.3: Resolve parent_id at creation time to eliminate hot-path HashMap lookup
            // in computeFloatingPositions. The parent must already exist when floating element is created.
            if (floating.parent_id) |pid| {
                self.elements.get(index).computed.resolved_floating_parent = self.id_to_index.get(pid);
            }
        }

        // Link to parent (floating elements still have a parent for reference)
        // O(1) append using last_child_index (avoids O(n) sibling walk)
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

        return index;
    }

    /// End frame and compute layout
    pub fn endFrame(self: *Self) ![]const RenderCommand {
        if (self.root_index == null) return self.commands.items();

        // Phase 1: Compute minimum sizes (bottom-up)
        self.computeMinSizes(self.root_index.?, 0);

        // Phase 2: Compute final sizes (top-down)
        self.computeFinalSizes(self.root_index.?, self.viewport_width, self.viewport_height, 0);

        // Phase 2b: Wrap text now that we know container widths
        try self.computeTextWrapping(self.root_index.?);

        // Phase 3: Compute positions (top-down)
        self.computePositions(self.root_index.?, 0, 0, 0);

        // Phase 3b: Position floating elements (includes text wrapping for floats)
        try self.computeFloatingPositions();

        // Phase 4: Generate render commands
        try self.generateRenderCommands(self.root_index.?, 0, 1.0, 0);

        // Sort by z-index only when floating elements exist (they're the only source of non-zero z_index).
        // Skipping the sort saves ~O(n log n) work on frames with no dropdowns/tooltips/modals.
        if (self.floating_roots.len > 0) {
            self.commands.sortByZIndex();
        }

        return self.commands.items();
    }

    /// Compute text wrapping now that container sizes are known
    fn computeTextWrapping(self: *Self, index: u32) !void {
        const elem = self.elements.get(index);

        // Handle text wrapping and alignment for this element
        if (elem.text_data) |*td| {
            // Calculate container width for alignment (used for all text, not just wrapped)
            const max_width = if (elem.parent_index) |pi| blk: {
                const parent = self.elements.getConst(pi);
                // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
                break :blk @max(0, parent.computed.sized_width - parent.config.layout.padding.totalX());
            } else self.viewport_width;

            // Always store container width for alignment calculations
            td.container_width = max_width;

            // Handle actual text wrapping if enabled
            if (td.config.wrap_mode != .none and max_width > 0) {
                const wrap_result = try self.wrapText(td.text, td.config, max_width);
                td.wrapped_lines = wrap_result.lines;

                if (wrap_result.lines.len > 0) {
                    td.measured_width = wrap_result.max_line_width;
                    td.measured_height = wrap_result.total_height;

                    elem.computed.sized_width = wrap_result.max_line_width;
                    elem.computed.sized_height = wrap_result.total_height;

                    // Propagate height change up to fit-content parents
                    self.propagateHeightChange(elem.parent_index);
                }
            }
        }

        // Recurse to children
        if (elem.first_child_index) |first_child| {
            var child_idx: ?u32 = first_child;
            while (child_idx) |ci| {
                try self.computeTextWrapping(ci);
                child_idx = self.elements.getConst(ci).next_sibling_index;
            }
        }
    }

    /// Propagate child height changes up to fit-content parents
    fn propagateHeightChange(self: *Self, parent_idx: ?u32) void {
        var idx = parent_idx;
        while (idx) |pi| {
            const parent = self.elements.get(pi);
            const sizing = parent.config.layout.sizing.height;

            // Only update fit-content parents (not fixed, grow, or percent)
            if (sizing.value != .fit) break;

            // Recalculate height based on children
            const padding = parent.config.layout.padding;
            var total_height: f32 = 0;
            const gap: f32 = @floatFromInt(parent.config.layout.child_gap);
            const is_vertical = !parent.config.layout.layout_direction.isHorizontal();

            var child_idx = parent.first_child_index;
            var child_count: u32 = 0;
            while (child_idx) |ci| {
                const child = self.elements.getConst(ci);
                if (is_vertical) {
                    total_height += child.computed.sized_height;
                } else {
                    total_height = @max(total_height, child.computed.sized_height);
                }
                child_idx = child.next_sibling_index;
                child_count += 1;
            }

            if (is_vertical and child_count > 1) {
                total_height += gap * @as(f32, @floatFromInt(child_count - 1));
            }

            const new_height = total_height + padding.totalY();
            parent.computed.sized_height = @max(sizing.getMin(), @min(sizing.getMax(), new_height));

            idx = parent.parent_index;
        }
    }

    /// Phase 2.2: Reduced from 4 passes to 2 passes per floating element
    /// Pass 1: Compute sizes with integrated text wrapping
    /// Pass 2: Position element and children
    fn computeFloatingPositions(self: *Self) !void {
        // Assertions per CLAUDE.md
        std.debug.assert(self.floating_roots.len <= MAX_FLOATING_ROOTS);

        for (self.floating_roots.slice()) |float_idx| {
            const elem = self.elements.get(float_idx);
            const floating = elem.config.floating orelse continue;

            // Find parent bounding box FIRST (needed for expand and positioning)
            var parent_bbox: BoundingBox = .{
                .width = self.viewport_width,
                .height = self.viewport_height,
            };

            if (floating.attach_to_parent) {
                if (elem.parent_index) |pi| {
                    parent_bbox = self.elements.getConst(pi).computed.bounding_box;
                }
            } else if (elem.computed.resolved_floating_parent) |pi| {
                // Phase 2.3: Use cached parent index instead of HashMap lookup
                parent_bbox = self.elements.getConst(pi).computed.bounding_box;
            }

            // Phase 3.5: Implement FloatingConfig.expand
            // If expand is set, use parent dimensions as constraints
            const constraint_width = if (floating.expand.width) parent_bbox.width else self.viewport_width;
            const constraint_height = if (floating.expand.height) parent_bbox.height else self.viewport_height;

            // =========================================================================
            // PASS 1: Compute sizes with integrated text wrapping
            // =========================================================================
            // This combines: computeFinalSizes + computeTextWrapping + recompute
            try self.computeFloatingSizesWithText(float_idx, constraint_width, constraint_height);

            // Apply expand after sizing (override computed sizes if expand is set)
            if (floating.expand.width) {
                elem.computed.sized_width = parent_bbox.width;
            }
            if (floating.expand.height) {
                elem.computed.sized_height = parent_bbox.height;
            }

            // =========================================================================
            // PASS 2: Position element and children
            // =========================================================================
            self.positionFloatingElement(float_idx, floating, parent_bbox);
        }
    }

    /// Phase 2.2 Helper: Compute sizes for floating element with text wrapping integrated
    /// Combines what was previously 4 separate passes into 2 internal operations
    fn computeFloatingSizesWithText(self: *Self, index: u32, max_width: f32, max_height: f32) !void {
        std.debug.assert(max_width >= 0);
        std.debug.assert(max_height >= 0);

        // First compute initial sizes (top-down)
        self.computeFinalSizes(index, max_width, max_height, 0);

        // Now wrap text with known container widths - this may change element dimensions
        const elem = self.elements.get(index);
        var needs_resize = false;

        if (elem.text_data) |*td| {
            const text_max_width = if (elem.parent_index) |pi| blk: {
                const parent = self.elements.getConst(pi);
                // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
                break :blk @max(0, parent.computed.sized_width - parent.config.layout.padding.totalX());
            } else max_width;

            td.container_width = text_max_width;

            if (td.config.wrap_mode != .none and text_max_width > 0) {
                const wrap_result = try self.wrapText(td.text, td.config, text_max_width);
                td.wrapped_lines = wrap_result.lines;

                if (wrap_result.lines.len > 0) {
                    td.measured_width = wrap_result.max_line_width;
                    td.measured_height = wrap_result.total_height;
                    elem.computed.sized_width = wrap_result.max_line_width;
                    elem.computed.sized_height = wrap_result.total_height;
                    needs_resize = true;
                }
            }
        }

        // Recurse to children
        if (elem.first_child_index) |first_child| {
            var child_idx: ?u32 = first_child;
            while (child_idx) |ci| {
                const child = self.elements.get(ci);
                // Skip nested floating elements - they're processed separately
                if (child.config.floating == null) {
                    const child_max_w = child.computed.sized_width;
                    const child_max_h = child.computed.sized_height;
                    try self.computeFloatingSizesWithText(ci, child_max_w, child_max_h);
                }
                child_idx = child.next_sibling_index;
            }
        }

        // If text wrapping changed dimensions, propagate up and recompute
        if (needs_resize) {
            self.computeMinSizes(index, 0);
            self.computeFinalSizes(index, max_width, max_height, 0);
        }
    }

    /// Phase 2.2 Helper: Position a floating element and its children
    fn positionFloatingElement(self: *Self, float_idx: u32, floating: types.FloatingConfig, parent_bbox: BoundingBox) void {
        const elem = self.elements.get(float_idx);

        // Calculate attach point on parent
        const parent_x = parent_bbox.x + parent_bbox.width * floating.parent_attach.normalizedX();
        const parent_y = parent_bbox.y + parent_bbox.height * floating.parent_attach.normalizedY();

        // Calculate element anchor offset
        const elem_offset_x = elem.computed.sized_width * floating.element_attach.normalizedX();
        const elem_offset_y = elem.computed.sized_height * floating.element_attach.normalizedY();

        // Final position (before clamping)
        var final_x = parent_x - elem_offset_x + floating.offset.x;
        var final_y = parent_y - elem_offset_y + floating.offset.y;

        // Clamp to viewport bounds (keep floating elements on-screen)
        if (final_x < 0) final_x = 0;
        if (final_y < 0) final_y = 0;
        const max_x = self.viewport_width - elem.computed.sized_width;
        const max_y = self.viewport_height - elem.computed.sized_height;
        if (final_x > max_x) final_x = @max(0, max_x);
        if (final_y > max_y) final_y = @max(0, max_y);

        // Update bounding boxes
        elem.computed.bounding_box = .{
            .x = final_x,
            .y = final_y,
            .width = elem.computed.sized_width,
            .height = elem.computed.sized_height,
        };

        const padding = elem.config.layout.padding;
        elem.computed.content_box = .{
            .x = final_x + @as(f32, @floatFromInt(padding.left)),
            .y = final_y + @as(f32, @floatFromInt(padding.top)),
            // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
            .width = @max(0, elem.computed.sized_width - padding.totalX()),
            .height = @max(0, elem.computed.sized_height - padding.totalY()),
        };

        // Recursively position children of floating element
        if (elem.first_child_index) |first_child| {
            const scroll_offset: ?ScrollOffset = if (elem.config.scroll) |s|
                ScrollOffset{ .x = s.scroll_offset.x, .y = s.scroll_offset.y }
            else
                null;
            self.positionChildren(first_child, elem.config.layout, elem.computed.content_box, scroll_offset, 0);
        }
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

    // =========================================================================
    // Phase 1: Compute minimum sizes (bottom-up)
    // =========================================================================

    fn computeMinSizes(self: *Self, index: u32, depth: u32) void {
        // Assertions per CLAUDE.md: minimum 2 per function, put a limit on everything
        std.debug.assert(index < self.elements.len()); // Valid element index
        std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md

        const elem = self.elements.get(index);
        const layout = elem.config.layout;
        const padding = layout.padding;

        // Check if this is a scroll container - scroll containers don't use
        // children's sizes for min_height/min_width in the scrollable direction
        const is_vertical_scroll = if (elem.config.scroll) |s| s.vertical else false;
        const is_horizontal_scroll = if (elem.config.scroll) |s| s.horizontal else false;

        var content_width: f32 = 0;
        var content_height: f32 = 0;

        // Process children first (bottom-up)
        if (elem.first_child_index) |first_child| {
            var child_idx: ?u32 = first_child;
            var child_count: u32 = 0;

            while (child_idx) |ci| {
                self.computeMinSizes(ci, depth + 1);
                const child = self.elements.getConst(ci);

                // Skip floating elements - they don't affect parent's min size
                if (child.config.floating == null) {
                    if (layout.layout_direction.isHorizontal()) {
                        // For horizontal scroll, don't accumulate children widths
                        if (!is_horizontal_scroll) {
                            content_width += child.computed.min_width;
                        }
                        // For vertical scroll, don't include children heights at all
                        if (!is_vertical_scroll) {
                            content_height = @max(content_height, child.computed.min_height);
                        }
                    } else {
                        // For horizontal scroll, don't include children widths at all
                        if (!is_horizontal_scroll) {
                            content_width = @max(content_width, child.computed.min_width);
                        }
                        // For vertical scroll, don't accumulate children heights
                        if (!is_vertical_scroll) {
                            content_height += child.computed.min_height;
                        }
                    }
                    child_count += 1;
                }

                child_idx = child.next_sibling_index;
            }

            // Add gaps between children (but not for scroll containers in scrollable direction)
            if (child_count > 1) {
                const gap: f32 = @floatFromInt(layout.child_gap);
                if (layout.layout_direction.isHorizontal()) {
                    if (!is_horizontal_scroll) {
                        content_width += gap * @as(f32, @floatFromInt(child_count - 1));
                    }
                } else {
                    if (!is_vertical_scroll) {
                        content_height += gap * @as(f32, @floatFromInt(child_count - 1));
                    }
                }
            }
        }

        // Text content measurement
        if (elem.text_data) |td| {
            content_width = @max(content_width, td.measured_width);
            content_height = @max(content_height, td.measured_height);
        }

        // Add padding to get total minimum size
        const min_width = content_width + padding.totalX();
        const min_height = content_height + padding.totalY();

        // Apply sizing constraints from declaration
        elem.computed.min_width = applyMinMax(min_width, layout.sizing.width);
        elem.computed.min_height = applyMinMax(min_height, layout.sizing.height);
    }

    // =========================================================================
    // Phase 2: Compute final sizes (top-down)
    // =========================================================================

    fn computeFinalSizes(self: *Self, index: u32, available_width: f32, available_height: f32, depth: u32) void {
        // Assertions per CLAUDE.md: minimum 2 per function, put a limit on everything
        std.debug.assert(index < self.elements.len()); // Valid element index
        std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md
        std.debug.assert(available_width >= 0 or available_width == std.math.floatMax(f32)); // Valid width

        const elem = self.elements.get(index);
        const layout = elem.config.layout;
        const sizing = layout.sizing;

        // Compute base sizes
        const final_width = computeAxisSize(sizing.width, elem.computed.min_width, available_width);
        var final_height = computeAxisSize(sizing.height, elem.computed.min_height, available_height);

        // ASPECT RATIO (Phase 1): Derive height from width
        if (layout.aspect_ratio) |ratio| {
            // aspect_ratio = width / height, so height = width / ratio
            final_height = final_width / ratio;
        }

        elem.computed.sized_width = final_width;
        elem.computed.sized_height = final_height;

        // Content area for children (after padding)
        // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
        const content_width = @max(0, final_width - layout.padding.totalX());
        const content_height = @max(0, final_height - layout.padding.totalY());

        if (elem.first_child_index) |first_child| {
            // For scroll containers, allow children to overflow in scrollable directions
            // by passing a very large available size (prevents shrinking)
            var child_available_width = content_width;
            var child_available_height = content_height;

            if (elem.config.scroll) |scroll| {
                if (scroll.horizontal) {
                    child_available_width = std.math.floatMax(f32);
                }
                if (scroll.vertical) {
                    child_available_height = std.math.floatMax(f32);
                }
            }

            self.distributeSpace(first_child, layout, child_available_width, child_available_height, depth);
        }
    }

    /// Distribute available space among children (handles grow and shrink)
    /// Phase 3.1: Coordinator function - delegates to distributeShrink/distributeGrow
    fn distributeSpace(self: *Self, first_child: u32, layout: LayoutConfig, width: f32, height: f32, depth: u32) void {
        // Assertions per CLAUDE.md
        std.debug.assert(width >= 0 or width == std.math.floatMax(f32));
        std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md

        const is_horizontal = layout.layout_direction.isHorizontal();
        const gap: f32 = @floatFromInt(layout.child_gap);
        const available = if (is_horizontal) width else height;

        // Fast path: Check if all children are uniform grow elements (very common case)
        // This avoids the two-pass algorithm for flat layouts with many grow children
        if (self.tryUniformGrowFastPath(first_child, is_horizontal, width, height, available, gap, depth)) {
            return;
        }

        // Slow path: Mixed sizing types require two passes
        var grow_count: u32 = 0;
        var total_desired: f32 = 0;
        var child_count: u32 = 0;

        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            const child = self.elements.getConst(ci);

            // Skip floating elements - they don't participate in space distribution
            if (child.config.floating != null) {
                child_idx = child.next_sibling_index;
                continue;
            }

            const child_sizing = if (is_horizontal)
                child.config.layout.sizing.width
            else
                child.config.layout.sizing.height;

            const child_min = if (is_horizontal) child.computed.min_width else child.computed.min_height;

            // Calculate desired size based on sizing type
            const child_desired: f32 = switch (child_sizing.value) {
                .grow => blk: {
                    grow_count += 1;
                    break :blk child_min; // grow elements only contribute their min
                },
                .fit => |mm| blk: {
                    // If max is unbounded (floatMax), use min_width as desired
                    // Otherwise use the max constraint as desired size
                    const effective_max = if (mm.max >= 1e10) child_min else mm.max;
                    break :blk @max(child_min, effective_max);
                },
                .fixed => |mm| mm.min, // fixed wants exactly this size
                .percent => |p| available * p.value, // percent of available
            };

            // Only non-grow elements contribute to total_desired for shrink calc
            if (child_sizing.value != .grow) {
                total_desired += child_desired;
            }

            child_idx = child.next_sibling_index;
            child_count += 1;
        }

        const total_gap = if (child_count > 1) gap * @as(f32, @floatFromInt(child_count - 1)) else 0;
        const size_to_distribute = available - total_desired - total_gap;

        // Delegate to appropriate helper based on space situation
        if (size_to_distribute < 0 and total_desired > 0) {
            self.distributeShrink(first_child, is_horizontal, available, width, height, total_desired, size_to_distribute, depth);
        } else {
            self.distributeGrow(first_child, is_horizontal, width, height, grow_count, size_to_distribute, depth);
        }
    }

    /// Fast path for uniform grow children - speculative single pass with early bailout
    /// Returns true if fast path was used, false if caller should use slow path
    /// Key optimization: combines eligibility check and size assignment in ONE pass
    fn tryUniformGrowFastPath(
        self: *Self,
        first_child: u32,
        is_horizontal: bool,
        width: f32,
        height: f32,
        available: f32,
        gap: f32,
        depth: u32,
    ) bool {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(first_child < self.elements.len()); // Valid child index
        std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit

        // Get parent's child_count to pre-compute sizes (avoids counting pass)
        const first = self.elements.getConst(first_child);
        const parent_idx = first.parent_index orelse return false;
        const parent = self.elements.getConst(parent_idx);
        const total_children = parent.child_count;

        // Bail early if no children
        if (total_children == 0) return false;

        // Pre-compute uniform size assuming no floating elements
        const total_gap = if (total_children > 1) gap * @as(f32, @floatFromInt(total_children - 1)) else 0;
        var per_child = @max(0, (available - total_gap) / @as(f32, @floatFromInt(total_children)));
        const cross_size = if (is_horizontal) height else width;

        // Speculative single pass: check eligibility AND assign simultaneously
        const result = self.speculativeUniformAssign(first_child, is_horizontal, per_child, cross_size);
        if (!result.eligible) return false;

        // If we had floating elements, recalculate and re-assign
        if (result.floating_count > 0) {
            const actual_children = total_children - result.floating_count;
            if (actual_children == 0) return false;

            const actual_gap = if (actual_children > 1) gap * @as(f32, @floatFromInt(actual_children - 1)) else 0;
            per_child = @max(0, (available - actual_gap) / @as(f32, @floatFromInt(actual_children)));
            self.reassignUniformSizes(first_child, is_horizontal, per_child, cross_size);
        }

        // Handle grandchildren recursion in a separate pass (only if needed)
        if (result.has_grandchildren) {
            self.distributeToGrandchildren(first_child, is_horizontal, depth);
        }

        return true;
    }

    /// Result of speculative uniform assignment pass
    const SpeculativeResult = struct {
        eligible: bool,
        floating_count: u32,
        has_grandchildren: bool,
    };

    /// Speculative pass: checks eligibility and assigns sizes in one traversal
    /// Returns eligibility status and metadata for follow-up passes
    fn speculativeUniformAssign(
        self: *Self,
        first_child: u32,
        is_horizontal: bool,
        per_child: f32,
        cross_size: f32,
    ) SpeculativeResult {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(first_child < self.elements.len());
        std.debug.assert(per_child >= 0);

        var floating_count: u32 = 0;
        var has_grandchildren: bool = false;
        var child_idx: ?u32 = first_child;

        while (child_idx) |ci| {
            const child = self.elements.get(ci);

            // Skip floating elements but count them
            if (child.config.floating != null) {
                floating_count += 1;
                child_idx = child.next_sibling_index;
                continue;
            }

            // Check if child qualifies for fast path
            if (!isUnconstrainedGrow(child, is_horizontal)) {
                return .{ .eligible = false, .floating_count = 0, .has_grandchildren = false };
            }

            // Track grandchildren
            if (child.first_child_index != null) has_grandchildren = true;

            // Assign sizes speculatively
            if (is_horizontal) {
                child.computed.sized_width = per_child;
                child.computed.sized_height = cross_size;
            } else {
                child.computed.sized_width = cross_size;
                child.computed.sized_height = per_child;
            }

            child_idx = child.next_sibling_index;
        }

        return .{ .eligible = true, .floating_count = floating_count, .has_grandchildren = has_grandchildren };
    }

    /// Check if element has unconstrained grow on both axes (fast path eligible)
    fn isUnconstrainedGrow(child: *const LayoutElement, is_horizontal: bool) bool {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(child.config.layout.aspect_ratio == null or child.config.layout.aspect_ratio.? > 0);
        std.debug.assert(UNCONSTRAINED_MAX > 0);

        // Aspect ratio requires special handling - bail to slow path
        if (child.config.layout.aspect_ratio != null) return false;

        const main_sizing = if (is_horizontal)
            child.config.layout.sizing.width
        else
            child.config.layout.sizing.height;

        const main_ok = switch (main_sizing.value) {
            .grow => |mm| mm.min == 0 and mm.max >= UNCONSTRAINED_MAX,
            else => false,
        };
        if (!main_ok) return false;

        const cross_sizing = if (is_horizontal)
            child.config.layout.sizing.height
        else
            child.config.layout.sizing.width;

        return switch (cross_sizing.value) {
            .grow => |mm| mm.min == 0 and mm.max >= UNCONSTRAINED_MAX,
            else => false,
        };
    }

    /// Re-assign uniform sizes after adjusting for floating elements
    fn reassignUniformSizes(self: *Self, first_child: u32, is_horizontal: bool, per_child: f32, cross_size: f32) void {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(first_child < self.elements.len());
        std.debug.assert(per_child >= 0);

        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            const child = self.elements.get(ci);
            if (child.config.floating == null) {
                if (is_horizontal) {
                    child.computed.sized_width = per_child;
                    child.computed.sized_height = cross_size;
                } else {
                    child.computed.sized_width = cross_size;
                    child.computed.sized_height = per_child;
                }
            }
            child_idx = child.next_sibling_index;
        }
    }

    /// Distribute space to grandchildren after uniform assignment
    fn distributeToGrandchildren(self: *Self, first_child: u32, is_horizontal: bool, depth: u32) void {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(first_child < self.elements.len());
        std.debug.assert(depth < MAX_RECURSION_DEPTH);

        _ = is_horizontal;
        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            const child = self.elements.get(ci);
            if (child.config.floating == null) {
                if (child.first_child_index) |grandchild| {
                    const child_layout = child.config.layout;
                    const content_width = @max(0, child.computed.sized_width - child_layout.padding.totalX());
                    const content_height = @max(0, child.computed.sized_height - child_layout.padding.totalY());
                    self.distributeSpace(grandchild, child_layout, content_width, content_height, depth + 1);
                }
            }
            child_idx = child.next_sibling_index;
        }
    }

    /// Phase 3.1 Helper: Shrink children when content exceeds available space
    fn distributeShrink(
        self: *Self,
        first_child: u32,
        is_horizontal: bool,
        available: f32,
        width: f32,
        height: f32,
        total_desired: f32,
        size_to_distribute: f32,
        depth: u32,
    ) void {
        std.debug.assert(size_to_distribute < 0);
        std.debug.assert(total_desired > 0);

        const overflow = -size_to_distribute;
        const shrink_ratio = @max(0, 1.0 - overflow / total_desired);

        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            const child = self.elements.get(ci);

            // Skip floating elements
            if (child.config.floating != null) {
                child_idx = child.next_sibling_index;
                continue;
            }

            const child_sizing = if (is_horizontal)
                child.config.layout.sizing.width
            else
                child.config.layout.sizing.height;

            const child_min_constraint = child_sizing.getMin();
            const child_min_content = if (is_horizontal) child.computed.min_width else child.computed.min_height;

            // Calculate desired size for this child
            const child_desired: f32 = switch (child_sizing.value) {
                .grow => child_min_content,
                .fit => |mm| @max(child_min_content, if (mm.max >= 1e10) child_min_content else mm.max),
                .fixed => |mm| mm.min,
                .percent => |p| available * p.value,
            };

            const new_size: f32 = if (child_sizing.value == .grow)
                child_min_constraint
            else
                // Shrink proportionally but respect minimum constraint
                @max(child_min_constraint, child_desired * shrink_ratio);

            if (is_horizontal) {
                child.computed.sized_width = new_size;
                child.computed.sized_height = computeAxisSize(
                    child.config.layout.sizing.height,
                    child.computed.min_height,
                    height,
                );
            } else {
                child.computed.sized_width = computeAxisSize(
                    child.config.layout.sizing.width,
                    child.computed.min_width,
                    width,
                );
                child.computed.sized_height = new_size;
            }

            // Handle aspect ratio for shrunk elements
            if (child.config.layout.aspect_ratio) |ratio| {
                if (is_horizontal) {
                    child.computed.sized_height = child.computed.sized_width / ratio;
                } else {
                    child.computed.sized_width = child.computed.sized_height * ratio;
                }
            }

            // Recurse for children of this child
            const child_layout = child.config.layout;
            // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
            var content_width = @max(0, child.computed.sized_width - child_layout.padding.totalX());
            var content_height = @max(0, child.computed.sized_height - child_layout.padding.totalY());

            // For scroll containers, allow children to overflow in scrollable directions
            if (child.config.scroll) |scroll| {
                if (scroll.horizontal) {
                    content_width = std.math.floatMax(f32);
                }
                if (scroll.vertical) {
                    content_height = std.math.floatMax(f32);
                }
            }

            if (child.first_child_index) |grandchild| {
                self.distributeSpace(grandchild, child_layout, content_width, content_height, depth + 1);
            }

            child_idx = child.next_sibling_index;
        }
    }

    /// Phase 3.1 Helper: Distribute extra space to grow elements
    fn distributeGrow(
        self: *Self,
        first_child: u32,
        is_horizontal: bool,
        width: f32,
        height: f32,
        grow_count: u32,
        size_to_distribute: f32,
        depth: u32,
    ) void {
        std.debug.assert(size_to_distribute >= 0 or grow_count == 0);

        const per_grow = if (grow_count > 0) @max(0, size_to_distribute) / @as(f32, @floatFromInt(grow_count)) else 0;

        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            const child = self.elements.get(ci);

            // Skip floating elements
            if (child.config.floating != null) {
                child_idx = child.next_sibling_index;
                continue;
            }

            const child_sizing_main = if (is_horizontal)
                child.config.layout.sizing.width
            else
                child.config.layout.sizing.height;

            // Calculate desired size for non-grow elements
            const child_desired: f32 = switch (child_sizing_main.value) {
                .grow => 0, // handled separately
                .fit => |mm| @max(if (is_horizontal) child.computed.min_width else child.computed.min_height, mm.max),
                .fixed => |mm| mm.min,
                .percent => |p| (if (is_horizontal) width else height) * p.value,
            };

            var child_width: f32 = undefined;
            var child_height: f32 = undefined;

            if (is_horizontal) {
                child_width = if (child_sizing_main.value == .grow)
                    @max(child.computed.min_width, per_grow)
                else
                    child_desired;
                child_height = height;
            } else {
                child_width = width;
                child_height = if (child_sizing_main.value == .grow)
                    @max(child.computed.min_height, per_grow)
                else
                    child_desired;
            }

            self.computeFinalSizes(ci, child_width, child_height, depth + 1);
            child_idx = child.next_sibling_index;
        }
    }

    // =========================================================================
    // Phase 3: Compute positions (top-down)
    // =========================================================================

    fn computePositions(self: *Self, index: u32, parent_x: f32, parent_y: f32, depth: u32) void {
        // Assertions per CLAUDE.md: minimum 2 per function, put a limit on everything
        std.debug.assert(index < self.elements.len()); // Valid element index
        std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md

        const elem = self.elements.get(index);
        const layout = elem.config.layout;
        const padding = layout.padding;

        // Set this element's bounding box
        elem.computed.bounding_box = BoundingBox{
            .x = parent_x,
            .y = parent_y,
            .width = elem.computed.sized_width,
            .height = elem.computed.sized_height,
        };

        // Content box (inside padding)
        elem.computed.content_box = BoundingBox{
            .x = parent_x + @as(f32, @floatFromInt(padding.left)),
            .y = parent_y + @as(f32, @floatFromInt(padding.top)),
            // Use @max(0, ...) to prevent negative dimensions when element shrinks below padding
            .width = @max(0, elem.computed.sized_width - padding.totalX()),
            .height = @max(0, elem.computed.sized_height - padding.totalY()),
        };

        // Position children (pass scroll offset if this is a scroll container)
        if (elem.first_child_index) |first_child| {
            const scroll_offset: ?ScrollOffset = if (elem.config.scroll) |s|
                ScrollOffset{ .x = s.scroll_offset.x, .y = s.scroll_offset.y }
            else
                null;
            self.positionChildren(first_child, layout, elem.computed.content_box, scroll_offset, depth);
        }
    }

    fn positionChildren(self: *Self, first_child: u32, layout: LayoutConfig, content_box: BoundingBox, scroll_offset: ?ScrollOffset, depth: u32) void {
        // Assertions per CLAUDE.md: minimum 2 per function, put a limit on everything
        std.debug.assert(first_child < self.elements.len()); // Valid child index
        std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md

        const is_horizontal = layout.layout_direction.isHorizontal();
        const base_gap: f32 = @floatFromInt(layout.child_gap);
        const alignment = layout.child_alignment;
        const distribution = layout.main_axis_distribution;

        // Apply scroll offset if present
        const offset_x: f32 = if (scroll_offset) |s| -s.x else 0;
        const offset_y: f32 = if (scroll_offset) |s| -s.y else 0;

        // Calculate total children size (without gaps) and count (skip floating elements)
        var total_children_size: f32 = 0;
        var child_count: u32 = 0;
        var child_idx: ?u32 = first_child;

        while (child_idx) |ci| {
            const child = self.elements.getConst(ci);
            // Skip floating elements - they don't participate in normal flow
            if (child.config.floating == null) {
                total_children_size += if (is_horizontal) child.computed.sized_width else child.computed.sized_height;
                child_count += 1;
            }
            child_idx = child.next_sibling_index;
        }

        // Early exit if no children
        if (child_count == 0) return;

        // Calculate available space and distribution parameters
        const container_main_size = if (is_horizontal) content_box.width else content_box.height;
        const remaining_space = container_main_size - total_children_size;

        // Calculate effective gap and starting offset based on distribution mode
        var effective_gap: f32 = base_gap;
        var start_offset: f32 = 0;

        switch (distribution) {
            .start => {
                // Children packed at start with base gap
                effective_gap = base_gap;
                start_offset = 0;
            },
            .center => {
                // Children centered with base gap
                effective_gap = base_gap;
                const total_with_gaps = total_children_size + base_gap * @as(f32, @floatFromInt(@max(1, child_count) - 1));
                start_offset = (container_main_size - total_with_gaps) / 2;
            },
            .end => {
                // Children packed at end with base gap
                effective_gap = base_gap;
                const total_with_gaps = total_children_size + base_gap * @as(f32, @floatFromInt(@max(1, child_count) - 1));
                start_offset = container_main_size - total_with_gaps;
            },
            .space_between => {
                // Equal space between children, no space at edges
                // gap = remaining_space / (child_count - 1)
                if (child_count > 1) {
                    effective_gap = remaining_space / @as(f32, @floatFromInt(child_count - 1));
                } else {
                    effective_gap = 0;
                }
                start_offset = 0;
            },
            .space_around => {
                // Equal space around each child (half space at edges)
                // Each child gets equal "padding" on both sides
                // gap = remaining_space / child_count
                // start_offset = gap / 2
                if (child_count > 0) {
                    const space_per_child = remaining_space / @as(f32, @floatFromInt(child_count));
                    effective_gap = space_per_child;
                    start_offset = space_per_child / 2;
                }
            },
            .space_evenly => {
                // Equal space between and around children
                // gap = remaining_space / (child_count + 1)
                // start_offset = gap
                if (child_count > 0) {
                    effective_gap = remaining_space / @as(f32, @floatFromInt(child_count + 1));
                    start_offset = effective_gap;
                }
            },
        }

        // Ensure gap is non-negative (can happen if children overflow container)
        effective_gap = @max(0, effective_gap);
        start_offset = @max(0, start_offset);

        // Calculate starting position
        var cursor_x: f32 = content_box.x + offset_x + if (is_horizontal) start_offset else 0;
        var cursor_y: f32 = content_box.y + offset_y + if (!is_horizontal) start_offset else 0;

        // Position each child
        child_idx = first_child;
        while (child_idx) |ci| {
            const child = self.elements.get(ci);

            // Skip floating elements - they are positioned separately in computeFloatingPositions
            if (child.config.floating != null) {
                child_idx = child.next_sibling_index;
                continue;
            }

            // Cross-axis alignment
            var child_x = cursor_x;
            var child_y = cursor_y;

            if (is_horizontal) {
                child_y += switch (alignment.y) {
                    .top => 0,
                    .center => (content_box.height - child.computed.sized_height) / 2,
                    .bottom => content_box.height - child.computed.sized_height,
                };
            } else {
                child_x += switch (alignment.x) {
                    .left => 0,
                    .center => (content_box.width - child.computed.sized_width) / 2,
                    .right => content_box.width - child.computed.sized_width,
                };
            }

            self.computePositions(ci, child_x, child_y, depth + 1);

            // Advance cursor
            if (is_horizontal) {
                cursor_x += child.computed.sized_width + effective_gap;
            } else {
                cursor_y += child.computed.sized_height + effective_gap;
            }

            child_idx = child.next_sibling_index;
        }
    }

    // =========================================================================
    // Phase 4: Generate render commands
    // Phase 3.1: Split into per-command-type helpers for readability
    // =========================================================================

    fn generateRenderCommands(self: *Self, index: u32, inherited_z_index: i16, inherited_opacity: f32, depth: u32) !void {
        // Assertions per CLAUDE.md: minimum 2 per function, put a limit on everything
        std.debug.assert(inherited_opacity >= 0 and inherited_opacity <= 1.0);
        std.debug.assert(depth < MAX_RECURSION_DEPTH); // Depth limit per CLAUDE.md

        const elem = self.elements.get(index);
        const bbox = elem.computed.bounding_box;

        // Floating elements override z_index for themselves and their children
        const z_index: i16 = if (elem.config.floating) |f| f.z_index else inherited_z_index;

        // Combine element opacity with inherited opacity (multiplicative)
        const opacity = elem.config.opacity * inherited_opacity;

        // Cache z_index for O(1) lookup via getZIndex()
        elem.cached_z_index = z_index;

        // Generate commands for each visual component
        try self.emitShadowCommand(elem, bbox, z_index, opacity);
        try self.emitRectangleCommand(elem, bbox, z_index, opacity);
        try self.emitBorderCommand(elem, bbox, z_index, opacity);
        try self.emitTextCommands(elem, bbox, z_index, opacity);
        try self.emitSvgCommand(elem, bbox, z_index, opacity);
        try self.emitImageCommand(elem, bbox, z_index, opacity);
        try self.emitCanvasCommand(elem, bbox, z_index);

        // Scissor for scroll containers (before children)
        const has_scroll = elem.config.scroll != null;
        if (has_scroll) {
            try self.commands.append(.{
                .bounding_box = bbox,
                .command_type = .scissor_start,
                .z_index = z_index,
                .id = elem.id,
                .data = .{ .scissor_start = .{ .clip_bounds = bbox } },
            });
        }

        // Recurse to children (passing inherited opacity)
        if (elem.first_child_index) |first_child| {
            var child_idx: ?u32 = first_child;
            while (child_idx) |ci| {
                try self.generateRenderCommands(ci, z_index, opacity, depth + 1);
                child_idx = self.elements.getConst(ci).next_sibling_index;
            }
        }

        // End scissor (after children)
        if (has_scroll) {
            try self.commands.append(.{
                .bounding_box = bbox,
                .command_type = .scissor_end,
                .z_index = z_index,
                .id = elem.id,
                .data = .{ .scissor_end = {} },
            });
        }
    }

    /// Phase 3.1 Helper: Emit shadow render command
    fn emitShadowCommand(self: *Self, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
        const shadow = elem.config.shadow orelse return;
        if (!shadow.isVisible()) return;

        try self.commands.append(.{
            .bounding_box = bbox,
            .command_type = .shadow,
            .z_index = z_index,
            .id = elem.id,
            .data = .{ .shadow = .{
                .blur_radius = shadow.blur_radius,
                .color = shadow.color.withAlpha(shadow.color.a * opacity),
                .offset_x = shadow.offset_x,
                .offset_y = shadow.offset_y,
                .corner_radius = elem.config.corner_radius,
            } },
        });
    }

    /// Phase 3.1 Helper: Emit background rectangle render command
    fn emitRectangleCommand(self: *Self, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
        const bg = elem.config.background_color orelse return;

        try self.commands.append(.{
            .bounding_box = bbox,
            .command_type = .rectangle,
            .z_index = z_index,
            .id = elem.id,
            .data = .{ .rectangle = .{
                .background_color = bg.withAlpha(bg.a * opacity),
                .corner_radius = elem.config.corner_radius,
            } },
        });
    }

    /// Phase 3.1 Helper: Emit border render command
    fn emitBorderCommand(self: *Self, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
        const border = elem.config.border orelse return;

        try self.commands.append(.{
            .bounding_box = bbox,
            .command_type = .border,
            .z_index = z_index,
            .id = elem.id,
            .data = .{ .border = .{
                .color = border.color.withAlpha(border.color.a * opacity),
                .width = border.width,
                .corner_radius = elem.config.corner_radius,
            } },
        });
    }

    /// Phase 3.1 Helper: Emit text render commands (handles wrapped and single-line)
    fn emitTextCommands(self: *Self, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
        const td = elem.text_data orelse return;
        const text_color = td.config.color.withAlpha(td.config.color.a * opacity);
        const align_width = if (td.container_width > 0) td.container_width else bbox.width;

        if (td.wrapped_lines) |lines| {
            // Render each wrapped line
            const line_height = td.config.lineHeightPx();
            for (lines, 0..) |line, i| {
                const line_y = bbox.y + @as(f32, @floatFromInt(i)) * line_height;
                const line_x = bbox.x + switch (td.config.alignment) {
                    .left => 0,
                    .center => (align_width - line.width) / 2,
                    .right => align_width - line.width,
                };
                try self.commands.append(.{
                    .bounding_box = .{ .x = line_x, .y = line_y, .width = line.width, .height = line_height },
                    .command_type = .text,
                    .z_index = z_index,
                    .id = elem.id,
                    .data = .{ .text = .{
                        .text = td.text[line.start_offset..][0..line.length],
                        .color = text_color,
                        .font_id = td.config.font_id,
                        .font_size = td.config.font_size,
                        .letter_spacing = td.config.letter_spacing,
                        .underline = td.config.decoration.underline,
                        .strikethrough = td.config.decoration.strikethrough,
                    } },
                });
            }
        } else {
            // Single line (no wrapping)
            const text_x = bbox.x + switch (td.config.alignment) {
                .left => 0,
                .center => (align_width - td.measured_width) / 2,
                .right => align_width - td.measured_width,
            };
            try self.commands.append(.{
                .bounding_box = .{ .x = text_x, .y = bbox.y, .width = td.measured_width, .height = bbox.height },
                .command_type = .text,
                .z_index = z_index,
                .id = elem.id,
                .data = .{ .text = .{
                    .text = td.text,
                    .color = text_color,
                    .font_id = td.config.font_id,
                    .font_size = td.config.font_size,
                    .letter_spacing = td.config.letter_spacing,
                    .underline = td.config.decoration.underline,
                    .strikethrough = td.config.decoration.strikethrough,
                } },
            });
        }
    }

    /// Phase 3.1 Helper: Emit SVG render command
    fn emitSvgCommand(self: *Self, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
        const sd = elem.svg_data orelse return;

        try self.commands.append(.{
            .bounding_box = bbox,
            .command_type = .svg,
            .z_index = z_index,
            .id = elem.id,
            .data = .{ .svg = .{
                .path = sd.path,
                .color = sd.color.withAlpha(sd.color.a * opacity),
                .stroke_color = if (sd.stroke_color) |sc| sc.withAlpha(sc.a * opacity) else null,
                .stroke_width = sd.stroke_width,
                .has_fill = sd.has_fill,
                .viewbox = sd.viewbox,
            } },
        });
    }

    /// Phase 3.1 Helper: Emit image render command
    fn emitImageCommand(self: *Self, elem: *LayoutElement, bbox: BoundingBox, z_index: i16, opacity: f32) !void {
        const id = elem.image_data orelse return;

        try self.commands.append(.{
            .bounding_box = bbox,
            .command_type = .image,
            .z_index = z_index,
            .id = elem.id,
            .data = .{ .image = .{
                .source = id.source,
                .width = id.width,
                .height = id.height,
                .fit = id.fit,
                .corner_radius = id.corner_radius,
                .tint = id.tint,
                .grayscale = id.grayscale,
                .opacity = id.opacity * opacity,
                .placeholder_color = id.placeholder_color,
            } },
        });
    }

    /// Phase 3.1 Helper: Emit canvas render command
    /// Canvas commands reserve draw orders for deferred paint callbacks
    fn emitCanvasCommand(self: *Self, elem: *LayoutElement, bbox: BoundingBox, z_index: i16) !void {
        if (!elem.config.is_canvas) return;

        try self.commands.append(.{
            .bounding_box = bbox,
            .command_type = .canvas,
            .z_index = z_index,
            .id = elem.id,
            .data = .{ .canvas = .{ .layout_id = elem.id } },
        });
    }

    /// Wrap text into lines based on available width
    /// Phase 2.1: Uses word-level measurement for ~5x fewer measure_fn calls
    /// Instead of measuring each character, we:
    /// 1. First pass: Find word boundaries and measure each word ONCE
    /// 2. Second pass: Accumulate words onto lines until overflow
    fn wrapText(
        self: *Self,
        text_str: []const u8,
        config: TextConfig,
        max_width: f32,
    ) !struct { lines: []types.WrappedLine, total_height: f32, max_line_width: f32 } {
        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(max_width >= 0 or config.wrap_mode == .none);
        std.debug.assert(text_str.len <= std.math.maxInt(u32)); // Ensure offsets fit in u32

        if (config.wrap_mode == .none or max_width <= 0) {
            return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
        }

        const measure_fn = self.measure_text_fn orelse {
            return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
        };

        // =========================================================================
        // PASS 1: Find word boundaries and measure each word once
        // =========================================================================
        var words: FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT) = .{};

        _ = findWordBoundaries(text_str, measure_fn, config, self.measure_text_user_data, &words);

        // =========================================================================
        // PASS 2: Accumulate words onto lines until overflow
        // =========================================================================
        var lines: FixedCapacityArray(types.WrappedLine, MAX_LINES_PER_TEXT) = .{};

        const line_height = config.lineHeightPx();
        var max_line_width: f32 = 0;

        var line_start: u32 = 0; // byte offset where current line starts
        var line_width: f32 = 0; // accumulated width of current line (without trailing space)
        var line_width_with_space: f32 = 0; // line width including trailing space

        for (words.slice()) |word| {
            // Handle forced newlines - emit current line and start fresh
            if (word.has_newline) {
                // Add this word's content (if any) to line, then emit
                const total_width = line_width + word.width;
                lines.append(.{
                    .start_offset = line_start,
                    .length = word.end - line_start,
                    .width = total_width,
                }) catch break; // Hit MAX_LINES_PER_TEXT
                max_line_width = @max(max_line_width, total_width);

                // Start new line after the newline character
                line_start = word.end + 1; // +1 to skip the newline
                line_width = 0;
                line_width_with_space = 0;
                continue;
            }

            // Check if adding this word would overflow the line
            const potential_width = line_width_with_space + word.width;

            if (config.wrap_mode == .words and potential_width > max_width and line_width > 0) {
                // Overflow - emit current line WITHOUT this word
                lines.append(.{
                    .start_offset = line_start,
                    .length = word.start - line_start,
                    .width = line_width, // Use width without trailing space
                }) catch break;
                max_line_width = @max(max_line_width, line_width);

                // Start new line at this word
                line_start = word.start;
                line_width = word.width;
                line_width_with_space = word.width + word.trailing_space_width;
            } else if (config.wrap_mode == .words and word.width > max_width and line_width == 0) {
                // Single word is wider than max_width - force it onto its own line
                lines.append(.{
                    .start_offset = word.start,
                    .length = word.end - word.start,
                    .width = word.width,
                }) catch break;
                max_line_width = @max(max_line_width, word.width);

                // Start new line after this word
                line_start = word.end;
                // Skip trailing space
                if (word.trailing_space_width > 0) {
                    line_start += 1; // Assume single-byte space
                }
                line_width = 0;
                line_width_with_space = 0;
            } else {
                // Word fits - add it to current line
                line_width = line_width_with_space + word.width;
                line_width_with_space = line_width + word.trailing_space_width;
            }
        }

        // Emit final line if there's remaining content
        if (line_start < text_str.len) {
            // Trim trailing whitespace from final line
            const remaining = text_str[line_start..];
            const trimmed = std.mem.trimRight(u8, remaining, " \t\n");
            if (trimmed.len > 0) {
                lines.append(.{
                    .start_offset = line_start,
                    .length = @intCast(trimmed.len),
                    .width = line_width,
                }) catch {}; // Best effort for final line
                max_line_width = @max(max_line_width, line_width);
            }
        }

        // Copy to arena for return (arena memory persists until frame end)
        const result_lines = try self.arena.allocator().dupe(types.WrappedLine, lines.slice());
        const total_height = line_height * @as(f32, @floatFromInt(@max(1, result_lines.len)));

        return .{
            .lines = result_lines,
            .total_height = total_height,
            .max_line_width = max_line_width,
        };
    }

    /// Phase 2.1 Helper: Find word boundaries in text and measure each word once
    /// Returns number of words found. Words array is populated with boundary info.
    fn findWordBoundaries(
        text_str: []const u8,
        measure_fn: MeasureTextFn,
        config: TextConfig,
        user_data: ?*anyopaque,
        words: *FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT),
    ) u32 {
        std.debug.assert(text_str.len > 0);
        std.debug.assert(words.len == 0); // Should start empty

        var word_start: u32 = 0;
        var byte_pos: u32 = 0;
        var in_word = false;

        // Cache space width — constant for a given font_id/font_size, avoids redundant
        // measure calls per word boundary (typically 100s of calls per text block).
        const cached_space_width = measure_fn(" ", config.font_id, config.font_size, null, user_data).width;

        // Use UTF-8 view for proper multi-byte character handling
        const utf8_view = std.unicode.Utf8View.initUnchecked(text_str);
        var iter = utf8_view.iterator();

        while (iter.nextCodepointSlice()) |codepoint_slice| {
            const codepoint_len: u32 = @intCast(codepoint_slice.len);
            const c = codepoint_slice[0]; // First byte for ASCII checks
            const is_ascii = codepoint_len == 1;
            const is_space = is_ascii and (c == ' ' or c == '\t');
            const is_newline = is_ascii and c == '\n';

            if (is_newline) {
                // Emit word ending at newline (word content up to but not including newline)
                if (in_word) {
                    const word_text = text_str[word_start..byte_pos];
                    const word_width = measure_fn(word_text, config.font_id, config.font_size, null, user_data).width;
                    words.append(.{
                        .start = word_start,
                        .end = byte_pos,
                        .width = word_width,
                        .trailing_space_width = 0,
                        .has_newline = true,
                    }) catch return @intCast(words.len);
                } else {
                    // Empty line (newline with no preceding word content)
                    words.append(.{
                        .start = byte_pos,
                        .end = byte_pos,
                        .width = 0,
                        .trailing_space_width = 0,
                        .has_newline = true,
                    }) catch return @intCast(words.len);
                }
                in_word = false;
                word_start = byte_pos + codepoint_len;
            } else if (is_space) {
                if (in_word) {
                    // End of word - measure it
                    const word_text = text_str[word_start..byte_pos];
                    const word_width = measure_fn(word_text, config.font_id, config.font_size, null, user_data).width;
                    const space_width = cached_space_width;
                    words.append(.{
                        .start = word_start,
                        .end = byte_pos,
                        .width = word_width,
                        .trailing_space_width = space_width,
                        .has_newline = false,
                    }) catch return @intCast(words.len);
                    in_word = false;
                }
                // Skip leading/consecutive spaces - next word starts after this space
                word_start = byte_pos + codepoint_len;
            } else {
                // Regular character - start or continue word
                if (!in_word) {
                    word_start = byte_pos;
                    in_word = true;
                }
            }

            byte_pos += codepoint_len;
        }

        // Final word (no trailing space/newline)
        if (in_word and word_start < text_str.len) {
            const word_text = text_str[word_start..];
            const word_width = measure_fn(word_text, config.font_id, config.font_size, null, user_data).width;
            words.append(.{
                .start = word_start,
                .end = @intCast(text_str.len),
                .width = word_width,
                .trailing_space_width = 0,
                .has_newline = false,
            }) catch {};
        }

        return @intCast(words.len);
    }
};

// ============================================================================
// Helper functions
// ============================================================================

/// Apply min/max constraints to a size
fn applyMinMax(size: f32, axis: SizingAxis) f32 {
    const min_val = axis.getMin();
    const max_val = axis.getMax();
    return @max(min_val, @min(max_val, size));
}

/// Compute final size based on sizing type
fn computeAxisSize(axis: SizingAxis, min_size: f32, available: f32) f32 {
    return switch (axis.value) {
        .fit => |mm| blk: {
            // If max is bounded, use it as preferred size (allows shrinking from max to min)
            // If max is unbounded, use content size
            const preferred = if (mm.max < 1e10) mm.max else min_size;
            break :blk @max(mm.min, @min(mm.max, preferred));
        },
        .grow => applyMinMax(available, axis),
        .fixed => |mm| mm.min,
        .percent => |p| blk: {
            const computed = available * p.value;
            break :blk @max(p.min, @min(p.max, computed));
        },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "basic layout" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{ .sizing = Sizing.fill() },
        .background_color = Color.white,
    });
    engine.closeElement();

    const commands = try engine.endFrame();
    try std.testing.expect(commands.len > 0);
}

test "nested layout" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .top_to_bottom },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(100) } },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();
}

test "shrink behavior" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(200, 100); // Small viewport

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        // Two children that WANT 150px but CAN shrink (min=0)
        // Use fitMax(150) which means "fit content up to 150px, min is 0"
        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMax(150), // min=0, max=150
                    .height = SizingAxis.fixed(50),
                },
            },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = .{ .width = SizingAxis.fitMax(150), .height = SizingAxis.fixed(50) } },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Children should have shrunk to fit
    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    try std.testing.expect(child1.computed.sized_width <= 100); // 200/2
    try std.testing.expect(child2.computed.sized_width <= 100);
}

test "aspect ratio" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(160), .height = SizingAxis.fit() },
            .aspect_ratio = 16.0 / 9.0, // 16:9 ratio
        },
        .background_color = Color.white,
    });
    engine.closeElement();

    _ = try engine.endFrame();

    const elem = engine.elements.getConst(0);
    // Width 160, aspect 16:9, so height should be 90
    try std.testing.expectApproxEqAbs(@as(f32, 90), elem.computed.sized_height, 0.1);
}

test "percent with min/max" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = .{
                .width = SizingAxis.percentMinMax(0.5, 100, 300), // 50% clamped to 100-300
                .height = SizingAxis.fixed(50),
            },
        },
        .background_color = Color.white,
    });
    engine.closeElement();

    _ = try engine.endFrame();

    const elem = engine.elements.getConst(0);
    // 50% of 800 = 400, but max is 300
    try std.testing.expectEqual(@as(f32, 300), elem.computed.sized_width);
}

test "floating positioning" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Parent element
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(200, 100) },
        .background_color = Color.white,
    });
    {
        // Floating child (dropdown style)
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(150, 80) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Floating element should be positioned below parent
    const parent = engine.elements.getConst(0);
    const floating = engine.elements.getConst(1);

    try std.testing.expectEqual(parent.computed.bounding_box.x, floating.computed.bounding_box.x);
    try std.testing.expectEqual(parent.computed.bounding_box.y + parent.computed.bounding_box.height, floating.computed.bounding_box.y);
}

test "floating elements don't affect parent sizing or sibling layout" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Parent with fit-content sizing
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{
            .sizing = Sizing.fitContent(),
            .layout_direction = .top_to_bottom,
            .child_gap = 10,
        },
        .background_color = Color.white,
    });
    {
        // Regular child - should determine parent size
        try engine.openElement(.{
            .id = LayoutId.init("regular-child"),
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.red,
        });
        engine.closeElement();

        // Floating child - should NOT affect parent size
        try engine.openElement(.{
            .id = LayoutId.init("floating-child"),
            .layout = .{ .sizing = Sizing.fixed(200, 300) }, // Much larger than regular child
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();

        // Another regular child - should be positioned ignoring floating sibling
        try engine.openElement(.{
            .id = LayoutId.init("second-child"),
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.green,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const parent = engine.elements.getConst(0);
    const regular_child = engine.elements.getConst(1);
    const second_child = engine.elements.getConst(3);

    // Parent should only be sized by regular children (100x50 + gap + 100x50 = 100x110)
    // NOT affected by floating child's 200x300
    try std.testing.expectEqual(@as(f32, 100), parent.computed.sized_width);
    try std.testing.expectEqual(@as(f32, 110), parent.computed.sized_height); // 50 + 10 gap + 50

    // Second child should be positioned right after first child (ignoring floating)
    // First child at y=0, height=50, gap=10, so second child at y=60
    try std.testing.expectEqual(regular_child.computed.bounding_box.y + 50 + 10, second_child.computed.bounding_box.y);
}

test "text wrapping creates multiple lines" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Mock text measurement: each character is 10px wide, height is font_size
    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    // Container with 100px content width (120 - 20 padding)
    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(120, 200),
            .padding = Padding.all(10),
            .layout_direction = .top_to_bottom,
        },
    });
    {
        // Text that needs to wrap: "hello world" = 11 chars = 110px, but container is 100px
        try engine.text("hello world", .{
            .wrap_mode = .words,
            .font_size = 14,
        });
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Check that text element has wrapped lines
    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);

    const td = text_elem.text_data.?;
    try std.testing.expect(td.wrapped_lines != null);

    const lines = td.wrapped_lines.?;
    try std.testing.expect(lines.len >= 2); // Should have wrapped into at least 2 lines
}

test "text wrapping with newlines" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(400, 200) },
    });
    {
        try engine.text("line one\nline two\nline three", .{
            .wrap_mode = .newlines,
            .font_size = 14,
        });
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const text_elem = engine.elements.getConst(1);
    const td = text_elem.text_data.?;
    try std.testing.expect(td.wrapped_lines != null);

    const lines = td.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, 3), lines.len); // 3 lines from newlines
}

test "propagateHeightChange updates fit-content parent" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    // Parent with fit-content height
    try engine.openElement(.{
        .layout = .{
            .sizing = .{
                .width = SizingAxis.fixed(100), // 100px wide content area
                .height = SizingAxis.fit(), // Fit to content height
            },
            .layout_direction = .top_to_bottom,
        },
    });
    {
        // Long text that will wrap into multiple lines
        // "abcdefghij abcdefghij" = 21 chars = 210px wide, needs to wrap at 100px
        try engine.text("abcdefghij abcdefghij", .{
            .wrap_mode = .words,
            .font_size = 20,
            .line_height = 100, // 100% = 20px per line
        });
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Parent should have grown to fit wrapped text
    const parent = engine.elements.getConst(0);
    const text_elem = engine.elements.getConst(1);

    // Text wraps to 2+ lines, each 20px tall
    try std.testing.expect(text_elem.computed.sized_height >= 40.0);

    // Parent height should match or exceed text height
    try std.testing.expect(parent.computed.sized_height >= text_elem.computed.sized_height);
}

test "propagateHeightChange stops at fixed-height parent" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    // Outer container with FIXED height - should NOT grow
    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(100, 50), // Fixed 50px height
            .layout_direction = .top_to_bottom,
        },
    });
    {
        // Inner container with fit height
        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(100),
                    .height = SizingAxis.fit(),
                },
                .layout_direction = .top_to_bottom,
            },
        });
        {
            // Text that wraps to multiple lines
            try engine.text("abcdefghij abcdefghij", .{
                .wrap_mode = .words,
                .font_size = 20,
                .line_height = 100,
            });
        }
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const outer = engine.elements.getConst(0);
    const inner = engine.elements.getConst(1);

    // Outer should stay at fixed height
    try std.testing.expectEqual(@as(f32, 50.0), outer.computed.sized_height);

    // Inner (fit-content) should have grown
    try std.testing.expect(inner.computed.sized_height >= 40.0);
}

test "z-index propagates to render commands" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Parent element (z_index = 0)
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(200, 100) },
        .background_color = Color.white,
    });
    {
        // Floating child with z_index = 100
        try engine.openElement(.{
            .id = LayoutId.init("dropdown"),
            .layout = .{ .sizing = Sizing.fixed(150, 80) },
            .floating = .{ .z_index = 100, .element_attach = .left_top, .parent_attach = .left_bottom },
            .background_color = Color.blue,
        });
        {
            // Nested child inside floating - should inherit z_index
            try engine.openElement(.{
                .id = LayoutId.init("dropdown-item"),
                .layout = .{ .sizing = Sizing.fixed(140, 30) },
                .background_color = Color.red,
            });
            engine.closeElement();
        }
        engine.closeElement();
    }
    engine.closeElement();

    const commands = try engine.endFrame();

    // Find commands by element ID
    var parent_z: ?i16 = null;
    var dropdown_z: ?i16 = null;
    var dropdown_item_z: ?i16 = null;

    for (commands) |cmd| {
        if (cmd.id == LayoutId.init("parent").id) parent_z = cmd.z_index;
        if (cmd.id == LayoutId.init("dropdown").id) dropdown_z = cmd.z_index;
        if (cmd.id == LayoutId.init("dropdown-item").id) dropdown_item_z = cmd.z_index;
    }

    // Parent should have z_index = 0
    try std.testing.expectEqual(@as(i16, 0), parent_z.?);
    // Floating dropdown should have z_index = 100
    try std.testing.expectEqual(@as(i16, 100), dropdown_z.?);
    // Nested item inside dropdown should inherit z_index = 100
    try std.testing.expectEqual(@as(i16, 100), dropdown_item_z.?);
}

test "getZIndex returns inherited z-index" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{ .sizing = Sizing.fixed(400, 300) },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("floating"),
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
            .floating = .{ .z_index = 50 },
        });
        {
            try engine.openElement(.{
                .id = LayoutId.init("nested"),
                .layout = .{ .sizing = Sizing.fixed(50, 50) },
            });
            engine.closeElement();
        }
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Root has no floating ancestor
    try std.testing.expectEqual(@as(i16, 0), engine.getZIndex(LayoutId.init("root").id));
    // Floating element itself
    try std.testing.expectEqual(@as(i16, 50), engine.getZIndex(LayoutId.init("floating").id));
    // Nested element inherits from floating ancestor
    try std.testing.expectEqual(@as(i16, 50), engine.getZIndex(LayoutId.init("nested").id));
}

test "text alignment positions wrapped lines correctly" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Mock: each char is 10px wide
    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    // Container is 200px wide, text lines are shorter
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(200, 100) },
    });
    {
        // "AA\nBBBB" - line 1 is 20px, line 2 is 40px
        try engine.text("AA\nBBBB", .{
            .wrap_mode = .newlines,
            .alignment = .center,
            .font_size = 20,
            .line_height = 100, // 100% = 20px per line
        });
    }
    engine.closeElement();

    const commands = try engine.endFrame();

    // Find text commands
    var text_commands: [2]?types.BoundingBox = .{ null, null };
    var text_cmd_idx: usize = 0;
    for (commands) |cmd| {
        if (cmd.command_type == .text and text_cmd_idx < 2) {
            text_commands[text_cmd_idx] = cmd.bounding_box;
            text_cmd_idx += 1;
        }
    }

    // Both lines should exist
    try std.testing.expect(text_commands[0] != null);
    try std.testing.expect(text_commands[1] != null);

    const line1 = text_commands[0].?;
    const line2 = text_commands[1].?;

    // Line 1 "AA" = 20px wide, centered in 200px container
    // Expected x = (200 - 20) / 2 = 90
    try std.testing.expectEqual(@as(f32, 90.0), line1.x);
    try std.testing.expectEqual(@as(f32, 20.0), line1.width);

    // Line 2 "BBBB" = 40px wide, centered in 200px container
    // Expected x = (200 - 40) / 2 = 80
    try std.testing.expectEqual(@as(f32, 80.0), line2.x);
    try std.testing.expectEqual(@as(f32, 40.0), line2.width);
}

test "text alignment right aligns text" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(200, 50) },
    });
    {
        // Single line "test" = 40px, right aligned in 200px
        try engine.text("test", .{
            .alignment = .right,
            .font_size = 20,
        });
    }
    engine.closeElement();

    const commands = try engine.endFrame();

    // Find the text command
    var text_box: ?types.BoundingBox = null;
    for (commands) |cmd| {
        if (cmd.command_type == .text) {
            text_box = cmd.bounding_box;
            break;
        }
    }

    try std.testing.expect(text_box != null);
    const bbox = text_box.?;

    // "test" = 40px wide, right aligned in 200px container
    // Expected x = 200 - 40 = 160
    try std.testing.expectEqual(@as(f32, 160.0), bbox.x);
    try std.testing.expectEqual(@as(f32, 40.0), bbox.width);
}

test "space_between distributes children evenly" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_between
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_between: gap = 150 / (3-1) = 75px between children
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child1"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child2"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child3"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Get child positions
    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    const child3 = engine.elements.getConst(3);

    // Child 1: starts at x=0
    try std.testing.expectEqual(@as(f32, 0.0), child1.computed.bounding_box.x);
    // Child 2: starts at x=0 + 50 + 75 = 125
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    // Child 3: starts at x=125 + 50 + 75 = 250
    try std.testing.expectEqual(@as(f32, 250.0), child3.computed.bounding_box.x);
}

test "space_around distributes space around children" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_around
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_around: space_per_child = 150 / 3 = 50px
    // start_offset = 50 / 2 = 25px, gap = 50px
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_around,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child1"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child2"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child3"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    const child3 = engine.elements.getConst(3);

    // Child 1: starts at x=25 (start_offset)
    try std.testing.expectEqual(@as(f32, 25.0), child1.computed.bounding_box.x);
    // Child 2: starts at x=25 + 50 + 50 = 125
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    // Child 3: starts at x=125 + 50 + 50 = 225
    try std.testing.expectEqual(@as(f32, 225.0), child3.computed.bounding_box.x);
}

test "space_evenly distributes space evenly" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_evenly
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_evenly: gap = 150 / (3+1) = 37.5px
    // start_offset = gap = 37.5px
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_evenly,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child1"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child2"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child3"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    const child3 = engine.elements.getConst(3);

    // Child 1: starts at x=37.5
    try std.testing.expectEqual(@as(f32, 37.5), child1.computed.bounding_box.x);
    // Child 2: starts at x=37.5 + 50 + 37.5 = 125
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    // Child 3: starts at x=125 + 50 + 37.5 = 212.5
    try std.testing.expectEqual(@as(f32, 212.5), child3.computed.bounding_box.x);
}

test "space_between with vertical layout" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 200px tall, vertical layout with space_between
    // 2 children: 40px each = 80px total
    // Remaining space: 200 - 80 = 120px
    // space_between with 2 children: gap = 120 / 1 = 120px
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(100, 200),
            .layout_direction = .top_to_bottom,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child1"),
            .layout = .{ .sizing = Sizing.fixed(50, 40) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child2"),
            .layout = .{ .sizing = Sizing.fixed(50, 40) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);

    // Child 1: starts at y=0
    try std.testing.expectEqual(@as(f32, 0.0), child1.computed.bounding_box.y);
    // Child 2: starts at y=0 + 40 + 120 = 160
    try std.testing.expectEqual(@as(f32, 160.0), child2.computed.bounding_box.y);
}

test "space_between with single child stays at start" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // With a single child, space_between should position it at the start
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const child = engine.elements.getConst(1);

    // Single child should be at start (x=0)
    try std.testing.expectEqual(@as(f32, 0.0), child.computed.bounding_box.x);
}

// =============================================================================
// SourceLoc Tests (Phase 5)
// =============================================================================

test "SourceLoc.none is invalid" {
    const loc = SourceLoc.none;
    try std.testing.expect(!loc.isValid());
    try std.testing.expectEqual(@as(?[*:0]const u8, null), loc.file);
    try std.testing.expectEqual(@as(u32, 0), loc.line);
}

test "SourceLoc.from captures builtin source location" {
    const src = @src();
    const loc = SourceLoc.from(src);

    try std.testing.expect(loc.isValid());
    try std.testing.expect(loc.line > 0);
    try std.testing.expect(loc.file != null);
}

test "SourceLoc.getFile returns file name" {
    const src = @src();
    const loc = SourceLoc.from(src);

    const file = loc.getFile();
    try std.testing.expect(file != null);
    try std.testing.expect(file.?.len > 0);
}

test "SourceLoc.getBasename extracts filename" {
    const src = @src();
    const loc = SourceLoc.from(src);

    const basename = loc.getBasename();
    try std.testing.expect(basename != null);
    // Should be "engine.zig"
    try std.testing.expectEqualStrings("engine.zig", basename.?);
}

test "SourceLoc.getFnName returns function name" {
    const src = @src();
    const loc = SourceLoc.from(src);

    const fn_name = loc.getFnName();
    try std.testing.expect(fn_name != null);
    // Function name should contain "test" since this is a test block
    try std.testing.expect(std.mem.indexOf(u8, fn_name.?, "test") != null);
}

test "SourceLoc stored in ElementDeclaration" {
    const src = @src();
    const loc = SourceLoc.from(src);

    const decl = ElementDeclaration{
        .source_location = loc,
    };

    try std.testing.expect(decl.source_location.isValid());
    try std.testing.expectEqual(loc.line, decl.source_location.line);
}

test "SourceLoc propagates through createElement" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    const src = @src();
    const loc = SourceLoc.from(src);

    try engine.openElement(.{
        .id = LayoutId.init("test-element"),
        .layout = .{ .sizing = Sizing.fixed(100, 100) },
        .source_location = loc,
    });
    engine.closeElement();

    _ = try engine.endFrame();

    // Verify the element stored the source location
    const elem = engine.elements.getConst(0);
    try std.testing.expect(elem.config.source_location.isValid());
    try std.testing.expectEqual(loc.line, elem.config.source_location.line);
}

// =============================================================================
// Phase 1 Tests: Fixed Capacity Arrays, UTF-8, Capacity Limits
// =============================================================================

test "FixedCapacityArray basic operations" {
    var arr: FixedCapacityArray(u32, 4) = .{};

    // Test append
    try arr.append(10);
    try arr.append(20);
    try arr.append(30);
    try std.testing.expectEqual(@as(usize, 3), arr.len);

    // Test slice
    const slice = arr.slice();
    try std.testing.expectEqual(@as(usize, 3), slice.len);
    try std.testing.expectEqual(@as(u32, 10), slice[0]);
    try std.testing.expectEqual(@as(u32, 20), slice[1]);
    try std.testing.expectEqual(@as(u32, 30), slice[2]);

    // Test pop
    const popped = arr.pop();
    try std.testing.expectEqual(@as(?u32, 30), popped);
    try std.testing.expectEqual(@as(usize, 2), arr.len);

    // Test clear
    arr.clear();
    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "FixedCapacityArray overflow returns error" {
    var arr: FixedCapacityArray(u32, 2) = .{};

    try arr.append(1);
    try arr.append(2);

    // Third append should fail
    const result = arr.append(3);
    try std.testing.expectError(error.Overflow, result);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
}

test "FixedCapacityArray pop on empty returns null" {
    var arr: FixedCapacityArray(u32, 4) = .{};
    const result = arr.pop();
    try std.testing.expectEqual(@as(?u32, null), result);
}

test "open_element_stack uses fixed capacity" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Open several nested elements
    for (0..10) |_| {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
        });
    }

    // Verify stack has correct depth
    try std.testing.expectEqual(@as(usize, 10), engine.open_element_stack.len);

    // Close all
    for (0..10) |_| {
        engine.closeElement();
    }

    try std.testing.expectEqual(@as(usize, 0), engine.open_element_stack.len);
}

test "floating_roots uses fixed capacity" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create a parent element
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(400, 300) },
    });

    // Add several floating elements (no IDs needed for this test)
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 0 },
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 1 },
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 2 },
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 3 },
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 4 },
    });
    engine.closeElement();

    engine.closeElement();

    // Verify floating roots tracked
    try std.testing.expectEqual(@as(usize, 5), engine.floating_roots.len);
}

test "UTF-8 text wrapping handles multi-byte characters" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Mock text measurement: each codepoint is 10px wide
    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            // Count UTF-8 codepoints, not bytes
            var codepoint_count: usize = 0;
            const view = std.unicode.Utf8View.initUnchecked(text);
            var iter = view.iterator();
            while (iter.nextCodepointSlice()) |_| {
                codepoint_count += 1;
            }
            return .{
                .width = @as(f32, @floatFromInt(codepoint_count)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    // Container that forces wrapping
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(100, 200) }, // 100px wide = 10 codepoints max
    });

    // Text with UTF-8 characters (each emoji is multi-byte but should be 1 codepoint = 10px)
    // "Hello 世界" = 8 codepoints (H,e,l,l,o, ,世,界) = 80px, fits in 100px
    try engine.text("Hello 世界", .{
        .font_size = 16,
        .wrap_mode = .words,
    });

    engine.closeElement();

    _ = try engine.endFrame();

    // Should render without crashing - UTF-8 handling works
    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);
}

test "UTF-8 text wrapping with emoji" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            var codepoint_count: usize = 0;
            const view = std.unicode.Utf8View.initUnchecked(text);
            var iter = view.iterator();
            while (iter.nextCodepointSlice()) |_| {
                codepoint_count += 1;
            }
            return .{
                .width = @as(f32, @floatFromInt(codepoint_count)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 200) }, // Very narrow - 5 codepoints
    });

    // Emoji characters (4 bytes each in UTF-8, but 1 codepoint each)
    try engine.text("🎉🎊🎁", .{
        .font_size = 16,
        .wrap_mode = .words,
    });

    engine.closeElement();

    _ = try engine.endFrame();

    // Should complete without panic
    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);
}

test "capacity constants are reasonable" {
    // Verify our limits are sensible
    try std.testing.expect(MAX_ELEMENTS_PER_FRAME >= 1000);
    try std.testing.expect(MAX_OPEN_DEPTH >= 32);
    try std.testing.expect(MAX_FLOATING_ROOTS >= 64);
    try std.testing.expect(MAX_TRACKED_IDS >= 1000);
    try std.testing.expect(MAX_LINES_PER_TEXT >= 100);
}

test "id_to_index is pre-allocated" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // After init, hashmaps should have capacity (pre-allocated)
    // We can't directly check capacity, but we can verify lookups work
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{ .sizing = Sizing.fill() },
    });

    // Create several elements with comptime IDs
    try engine.openElement(.{
        .id = LayoutId.init("elem-a"),
        .layout = .{ .sizing = Sizing.fixed(10, 10) },
    });
    engine.closeElement();

    try engine.openElement(.{
        .id = LayoutId.init("elem-b"),
        .layout = .{ .sizing = Sizing.fixed(10, 10) },
    });
    engine.closeElement();

    try engine.openElement(.{
        .id = LayoutId.init("elem-c"),
        .layout = .{ .sizing = Sizing.fixed(10, 10) },
    });
    engine.closeElement();

    engine.closeElement();
    _ = try engine.endFrame();

    // All IDs should be trackable via getBoundingBox
    const root_bbox = engine.getBoundingBox(LayoutId.init("root").id);
    try std.testing.expect(root_bbox != null);

    const elem_a_bbox = engine.getBoundingBox(LayoutId.init("elem-a").id);
    try std.testing.expect(elem_a_bbox != null);

    const elem_b_bbox = engine.getBoundingBox(LayoutId.init("elem-b").id);
    try std.testing.expect(elem_b_bbox != null);

    const elem_c_bbox = engine.getBoundingBox(LayoutId.init("elem-c").id);
    try std.testing.expect(elem_c_bbox != null);
}

test "beginFrame clears fixed capacity arrays" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // First frame
    engine.beginFrame(800, 600);
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill() },
        .floating = .{},
    });
    engine.closeElement();
    _ = try engine.endFrame();

    // Verify state after first frame
    try std.testing.expect(engine.floating_roots.len > 0 or engine.open_element_stack.len == 0);

    // Second frame should start clean
    engine.beginFrame(800, 600);
    try std.testing.expectEqual(@as(usize, 0), engine.open_element_stack.len);
    try std.testing.expectEqual(@as(usize, 0), engine.floating_roots.len);
}

// ============================================================================
// Phase 2 Tests: Performance Improvements
// ============================================================================

test "word-level measurement measures words not characters" {
    // This test verifies that findWordBoundaries correctly identifies word boundaries
    var words: FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT) = .{};

    // Mock measure function that returns width = length * 10
    const measure = struct {
        fn measure(text: []const u8, _: u16, _: u16, _: ?f32, _: ?*anyopaque) TextMeasurement {
            return .{ .width = @floatFromInt(text.len * 10), .height = 20 };
        }
    }.measure;

    const config = TextConfig{ .font_size = 16 };
    const text = "hello world test";

    const word_count = LayoutEngine.findWordBoundaries(text, measure, config, null, &words);

    // Should find 3 words: "hello", "world", "test"
    try std.testing.expectEqual(@as(u32, 3), word_count);
    try std.testing.expectEqual(@as(usize, 3), words.len);

    // First word: "hello" (5 chars * 10 = 50)
    try std.testing.expectEqual(@as(u32, 0), words.buffer[0].start);
    try std.testing.expectEqual(@as(u32, 5), words.buffer[0].end);
    try std.testing.expectEqual(@as(f32, 50), words.buffer[0].width);
    try std.testing.expect(!words.buffer[0].has_newline);

    // Second word: "world" (5 chars * 10 = 50)
    try std.testing.expectEqual(@as(u32, 6), words.buffer[1].start);
    try std.testing.expectEqual(@as(u32, 11), words.buffer[1].end);
    try std.testing.expectEqual(@as(f32, 50), words.buffer[1].width);

    // Third word: "test" (4 chars * 10 = 40)
    try std.testing.expectEqual(@as(u32, 12), words.buffer[2].start);
    try std.testing.expectEqual(@as(u32, 16), words.buffer[2].end);
    try std.testing.expectEqual(@as(f32, 40), words.buffer[2].width);
}

test "word-level measurement handles newlines" {
    var words: FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT) = .{};

    const measure = struct {
        fn measure(text: []const u8, _: u16, _: u16, _: ?f32, _: ?*anyopaque) TextMeasurement {
            return .{ .width = @floatFromInt(text.len * 10), .height = 20 };
        }
    }.measure;

    const config = TextConfig{ .font_size = 16 };
    const text = "hello\nworld";

    const word_count = LayoutEngine.findWordBoundaries(text, measure, config, null, &words);

    // Should find 2 words with newline marker on first
    try std.testing.expectEqual(@as(u32, 2), word_count);
    try std.testing.expect(words.buffer[0].has_newline);
    try std.testing.expect(!words.buffer[1].has_newline);
}

test "floating element resolved_floating_parent is cached at creation" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create parent with ID
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(200, 200) },
        .background_color = Color.white,
    });

    // Create floating child that references parent by ID
    try engine.openElement(.{
        .id = LayoutId.init("float"),
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{
            .attach_to_parent = false,
            .parent_id = LayoutId.init("parent").id,
        },
        .background_color = Color.red,
    });
    engine.closeElement();

    engine.closeElement();

    // Before endFrame, check that resolved_floating_parent was set
    const float_idx = engine.id_to_index.get(LayoutId.init("float").id).?;
    const float_elem = engine.elements.getConst(float_idx);

    // The resolved parent should be cached
    try std.testing.expect(float_elem.computed.resolved_floating_parent != null);

    const parent_idx = engine.id_to_index.get(LayoutId.init("parent").id).?;
    try std.testing.expectEqual(parent_idx, float_elem.computed.resolved_floating_parent.?);

    _ = try engine.endFrame();
}

test "floating expand.width makes element match parent width" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create parent container
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(300, 200) },
        .background_color = Color.white,
    });

    // Create floating child with expand.width = true
    try engine.openElement(.{
        .id = LayoutId.init("expand-float"),
        .layout = .{ .sizing = Sizing.fitContent() }, // Would normally fit content
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = true, .height = false },
        },
        .background_color = Color.blue,
    });
    engine.closeElement();

    engine.closeElement();

    _ = try engine.endFrame();

    // The floating element should have expanded to parent width
    const float_bbox = engine.getBoundingBox(LayoutId.init("expand-float").id).?;
    try std.testing.expectEqual(@as(f32, 300), float_bbox.width);
}

test "floating expand.height makes element match parent height" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create parent container
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(300, 250) },
        .background_color = Color.white,
    });

    // Create floating child with expand.height = true
    try engine.openElement(.{
        .id = LayoutId.init("expand-float"),
        .layout = .{ .sizing = Sizing.fitContent() },
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = false, .height = true },
        },
        .background_color = Color.green,
    });
    engine.closeElement();

    engine.closeElement();

    _ = try engine.endFrame();

    // The floating element should have expanded to parent height
    const float_bbox = engine.getBoundingBox(LayoutId.init("expand-float").id).?;
    try std.testing.expectEqual(@as(f32, 250), float_bbox.height);
}

test "floating expand both dimensions" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create parent container
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(400, 300) },
        .background_color = Color.white,
    });

    // Create floating child with both expand flags
    try engine.openElement(.{
        .id = LayoutId.init("modal"),
        .layout = .{ .sizing = Sizing.fitContent() },
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = true, .height = true },
        },
        .background_color = Color.red,
    });
    engine.closeElement();

    engine.closeElement();

    _ = try engine.endFrame();

    // The floating element should match parent in both dimensions
    const modal_bbox = engine.getBoundingBox(LayoutId.init("modal").id).?;
    try std.testing.expectEqual(@as(f32, 400), modal_bbox.width);
    try std.testing.expectEqual(@as(f32, 300), modal_bbox.height);
}

// ============================================================================
// Phase 3 Tests: Code Quality
// ============================================================================

test "Offset2D shared type works in FloatingConfig" {
    const float_config = types.FloatingConfig{
        .offset = types.Offset2D.init(10, 20),
        .z_index = 5,
    };

    try std.testing.expectEqual(@as(f32, 10), float_config.offset.x);
    try std.testing.expectEqual(@as(f32, 20), float_config.offset.y);
}

test "Offset2D shared type works in ScrollConfig" {
    const scroll_config = types.ScrollConfig{
        .horizontal = true,
        .vertical = true,
        .scroll_offset = types.Offset2D.init(100, 200),
    };

    try std.testing.expectEqual(@as(f32, 100), scroll_config.scroll_offset.x);
    try std.testing.expectEqual(@as(f32, 200), scroll_config.scroll_offset.y);
}

test "Offset2D zero constructor" {
    const offset = types.Offset2D.zero();
    try std.testing.expectEqual(@as(f32, 0), offset.x);
    try std.testing.expectEqual(@as(f32, 0), offset.y);
}

test "WordInfo struct has expected fields" {
    const word = WordInfo{
        .start = 0,
        .end = 5,
        .width = 50.0,
        .trailing_space_width = 8.0,
        .has_newline = false,
    };

    try std.testing.expectEqual(@as(u32, 0), word.start);
    try std.testing.expectEqual(@as(u32, 5), word.end);
    try std.testing.expectEqual(@as(f32, 50.0), word.width);
    try std.testing.expectEqual(@as(f32, 8.0), word.trailing_space_width);
    try std.testing.expect(!word.has_newline);
}

test "MAX_WORDS_PER_TEXT constant is reasonable" {
    // Ensure we have enough capacity for typical text content
    try std.testing.expect(MAX_WORDS_PER_TEXT >= 1000);
    try std.testing.expect(MAX_WORDS_PER_TEXT <= 10000); // But not excessive
}

test "distributeGrow gives equal space to grow elements" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(300, 100);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        // Three grow elements should each get 100px (300/3)
        try engine.openElement(.{
            .id = LayoutId.init("grow1"),
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("grow2"),
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.green,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("grow3"),
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const grow1 = engine.getBoundingBox(LayoutId.init("grow1").id).?;
    const grow2 = engine.getBoundingBox(LayoutId.init("grow2").id).?;
    const grow3 = engine.getBoundingBox(LayoutId.init("grow3").id).?;

    try std.testing.expectEqual(@as(f32, 100), grow1.width);
    try std.testing.expectEqual(@as(f32, 100), grow2.width);
    try std.testing.expectEqual(@as(f32, 100), grow3.width);
}

test "distributeShrink respects minimum constraints" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(100, 100); // Very small viewport

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        // Child with min constraint of 60 should not shrink below that
        try engine.openElement(.{
            .id = LayoutId.init("minchild"),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMinMax(60, 200), // min=60, max=200
                    .height = SizingAxis.fixed(50),
                },
            },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("shrinkable"),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMax(200), // min=0, can shrink fully
                    .height = SizingAxis.fixed(50),
                },
            },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const minchild = engine.getBoundingBox(LayoutId.init("minchild").id).?;

    // minchild should not shrink below its minimum of 60
    try std.testing.expect(minchild.width >= 60);
}

// =============================================================================
// Fast Path Edge Case Tests (tryUniformGrowFastPath)
// =============================================================================

test "fast path: single grow child gets full available space" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(400, 300);

    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{ .sizing = Sizing.fixed(400, 300), .layout_direction = .left_to_right },
    });
    {
        // Single grow child should get full width (fast path with total_children == 1)
        try engine.openElement(.{
            .id = LayoutId.init("only-child"),
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.red,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const child = engine.getBoundingBox(LayoutId.init("only-child").id).?;

    // Single grow child should fill entire container
    try std.testing.expectEqual(@as(f32, 400), child.width);
    try std.testing.expectEqual(@as(f32, 300), child.height);
}

test "fast path: all floating children falls back to slow path" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(400, 300);

    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(400, 300),
            .layout_direction = .left_to_right,
        },
    });
    {
        // All children are floating - fast path should return false (actual_children == 0)
        try engine.openElement(.{
            .id = LayoutId.init("floating1"),
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("floating2"),
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Both floating elements should be positioned (not crash)
    const f1 = engine.getBoundingBox(LayoutId.init("floating1").id).?;
    const f2 = engine.getBoundingBox(LayoutId.init("floating2").id).?;

    try std.testing.expectEqual(@as(f32, 100), f1.width);
    try std.testing.expectEqual(@as(f32, 100), f2.width);
}

test "fast path: mixed sizing children falls back to slow path" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(400, 100);

    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{ .sizing = Sizing.fixed(400, 100), .layout_direction = .left_to_right },
    });
    {
        // Mixed sizing: fixed + grow + fit - should use slow path
        try engine.openElement(.{
            .id = LayoutId.init("fixed-child"),
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("grow-child"),
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.green,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("fit-child"),
            .layout = .{ .sizing = Sizing.fitContent() },
            .background_color = Color.blue,
        });
        {
            try engine.openElement(.{
                .layout = .{ .sizing = Sizing.fixed(50, 30) },
            });
            engine.closeElement();
        }
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const fixed = engine.getBoundingBox(LayoutId.init("fixed-child").id).?;
    const grow = engine.getBoundingBox(LayoutId.init("grow-child").id).?;
    const fit = engine.getBoundingBox(LayoutId.init("fit-child").id).?;

    // Fixed child keeps its size
    try std.testing.expectEqual(@as(f32, 100), fixed.width);

    // Fit child wraps its content
    try std.testing.expectEqual(@as(f32, 50), fit.width);

    // Grow child gets remaining space: 400 - 100 - 50 = 250
    try std.testing.expectEqual(@as(f32, 250), grow.width);
}

test "fast path: grow with min constraint falls back to slow path" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(300, 100);

    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{ .sizing = Sizing.fixed(300, 100), .layout_direction = .left_to_right },
    });
    {
        // Grow with min constraint - fast path should bail (mm.min != 0)
        try engine.openElement(.{
            .id = LayoutId.init("constrained-grow"),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.growMinMax(80, std.math.floatMax(f32)),
                    .height = SizingAxis.grow(),
                },
            },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("normal-grow"),
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.green,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const constrained = engine.getBoundingBox(LayoutId.init("constrained-grow").id).?;
    const normal = engine.getBoundingBox(LayoutId.init("normal-grow").id).?;

    // Both should share space equally (150 each) since slow path handles this
    // The min constraint of 80 is satisfied by the equal split
    try std.testing.expectEqual(@as(f32, 150), constrained.width);
    try std.testing.expectEqual(@as(f32, 150), normal.width);
}
