//! Core layout engine - implements Clay-style flexbox layout algorithm

const std = @import("std");
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
        const file = self.getFile() orelse return null;
        // Find last '/' or '\\'
        var last_sep: usize = 0;
        for (file, 0..) |c, i| {
            if (c == '/' or c == '\\') {
                last_sep = i + 1;
            }
        }
        return file[last_sep..];
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
};

pub const ComputedLayout = struct {
    bounding_box: BoundingBox = .{},
    content_box: BoundingBox = .{},
    min_width: f32 = 0,
    min_height: f32 = 0,
    sized_width: f32 = 0,
    sized_height: f32 = 0,
};

pub const LayoutElement = struct {
    id: u32,
    config: ElementDeclaration,
    parent_index: ?u32 = null,
    first_child_index: ?u32 = null,
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
        return .{
            .allocator = allocator,
            .elements = .{},
        };
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
    open_element_stack: std.ArrayList(u32),
    root_index: ?u32 = null,
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    measure_text_fn: ?MeasureTextFn = null,
    measure_text_user_data: ?*anyopaque = null,
    /// Debug: maps ID hash -> string for collision detection
    seen_ids: std.AutoHashMap(u32, ?[]const u8),
    /// Maps element ID -> element index for O(1) lookups
    id_to_index: std.AutoHashMap(u32, u32),
    /// Floating elements to position after main layout
    floating_roots: std.ArrayList(u32),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .arena = LayoutArena.init(allocator),
            .elements = ElementList.init(allocator),
            .commands = RenderCommandList.init(allocator),
            .open_element_stack = .{},
            .floating_roots = .{},
            .seen_ids = std.AutoHashMap(u32, ?[]const u8).init(allocator),
            .id_to_index = std.AutoHashMap(u32, u32).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.id_to_index.deinit();
        self.seen_ids.deinit();
        self.open_element_stack.deinit(self.allocator);
        self.floating_roots.deinit(self.allocator);
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
        self.open_element_stack.clearRetainingCapacity();
        self.floating_roots.clearRetainingCapacity();
        self.seen_ids.clearRetainingCapacity();
        self.id_to_index.clearRetainingCapacity();
        self.root_index = null;
        self.viewport_width = width;
        self.viewport_height = height;
    }

    pub fn openElement(self: *Self, decl: ElementDeclaration) !void {
        const index = try self.createElement(decl, .container);
        try self.open_element_stack.append(self.allocator, index);
    }

    pub fn closeElement(self: *Self) void {
        if (self.open_element_stack.items.len > 0) {
            _ = self.open_element_stack.pop();
        }
    }

    /// Add a text element (leaf node)
    pub fn text(self: *Self, content: []const u8, config: types.TextConfig) !void {
        std.debug.assert(self.open_element_stack.items.len > 0);

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
        std.debug.assert(self.open_element_stack.items.len > 0);

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
        std.debug.assert(self.open_element_stack.items.len > 0);

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
        };
    }

    /// Create an element and link it into the tree
    fn createElement(self: *Self, decl: ElementDeclaration, elem_type: ElementType) !u32 {
        // Check for ID collisions (skip if ID is none/0)
        // NOTE: Runs in all build modes - ID collisions cause subtle bugs
        if (decl.id.id != 0) {
            const result = self.seen_ids.getOrPut(decl.id.id) catch unreachable;
            if (result.found_existing) {
                // std.log.warn("Layout ID collision detected! ID hash {d} used by both \"{?s}\" and \"{?s}\"", .{
                //     decl.id.id,
                //     result.value_ptr.*,
                //     decl.id.string_id,
                // });
            } else {
                result.value_ptr.* = decl.id.string_id;
            }
        }

        const parent_index = if (self.open_element_stack.items.len > 0)
            self.open_element_stack.items[self.open_element_stack.items.len - 1]
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
            self.id_to_index.put(decl.id.id, index) catch {};
        }

        // Track floating elements separately
        if (decl.floating != null) {
            try self.floating_roots.append(self.allocator, index);
        }

        // Link to parent (floating elements still have a parent for reference)
        if (parent_index) |pi| {
            const parent = self.elements.get(pi);
            if (parent.first_child_index == null) {
                parent.first_child_index = index;
            } else {
                var sibling_idx = parent.first_child_index.?;
                while (self.elements.get(sibling_idx).next_sibling_index) |next| {
                    sibling_idx = next;
                }
                self.elements.get(sibling_idx).next_sibling_index = index;
            }
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
        self.computeMinSizes(self.root_index.?);

        // Phase 2: Compute final sizes (top-down)
        self.computeFinalSizes(self.root_index.?, self.viewport_width, self.viewport_height);

        // Phase 2b: Wrap text now that we know container widths
        try self.computeTextWrapping(self.root_index.?);

        // Phase 3: Compute positions (top-down)
        self.computePositions(self.root_index.?, 0, 0);

        // Phase 3b: Position floating elements (includes text wrapping for floats)
        try self.computeFloatingPositions();

        // Phase 4: Generate render commands
        try self.generateRenderCommands(self.root_index.?, 0, 1.0);

        // Sort by z-index to handle floating elements properly
        self.commands.sortByZIndex();

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
                break :blk parent.computed.sized_width - parent.config.layout.padding.totalX();
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

    fn computeFloatingPositions(self: *Self) !void {
        for (self.floating_roots.items) |float_idx| {
            const elem = self.elements.get(float_idx);
            const floating = elem.config.floating orelse continue;

            // Compute sizes for floating element and its children
            // Floating elements size themselves based on their content (min sizes),
            // not constrained by parent layout flow
            self.computeFinalSizes(float_idx, self.viewport_width, self.viewport_height);

            // Wrap text for floating elements now that they're sized
            // (main text wrapping pass happens before floating elements are sized)
            try self.computeTextWrapping(float_idx);

            // Recompute min sizes after text wrapping changed text dimensions
            // This propagates the new text height up to parent containers
            self.computeMinSizes(float_idx);

            // Recompute final sizes with updated min sizes
            self.computeFinalSizes(float_idx, self.viewport_width, self.viewport_height);

            // Find parent bounding box
            var parent_bbox: BoundingBox = .{
                .width = self.viewport_width,
                .height = self.viewport_height,
            };

            if (floating.attach_to_parent) {
                if (elem.parent_index) |pi| {
                    parent_bbox = self.elements.getConst(pi).computed.bounding_box;
                }
            } else if (floating.parent_id) |pid| {
                if (self.id_to_index.get(pid)) |pi| {
                    parent_bbox = self.elements.getConst(pi).computed.bounding_box;
                }
            }

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
            // Only clamp if actually going off-screen, don't add margin otherwise
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
                .width = elem.computed.sized_width - padding.totalX(),
                .height = elem.computed.sized_height - padding.totalY(),
            };

            // Recursively position children of floating element
            if (elem.first_child_index) |first_child| {
                const scroll_offset: ?ScrollOffset = if (elem.config.scroll) |s|
                    ScrollOffset{ .x = s.scroll_offset.x, .y = s.scroll_offset.y }
                else
                    null;
                self.positionChildren(first_child, elem.config.layout, elem.computed.content_box, scroll_offset);
            }
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

    fn computeMinSizes(self: *Self, index: u32) void {
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
                self.computeMinSizes(ci);
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

    fn computeFinalSizes(self: *Self, index: u32, available_width: f32, available_height: f32) void {
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
        const content_width = final_width - layout.padding.totalX();
        const content_height = final_height - layout.padding.totalY();

        if (elem.first_child_index) |first_child| {
            self.distributeSpace(first_child, layout, content_width, content_height);
        }
    }

    /// Distribute available space among children (handles grow and shrink)
    fn distributeSpace(self: *Self, first_child: u32, layout: LayoutConfig, width: f32, height: f32) void {
        const is_horizontal = layout.layout_direction.isHorizontal();
        const gap: f32 = @floatFromInt(layout.child_gap);
        const available = if (is_horizontal) width else height;

        // First pass: calculate totals using DESIRED sizes, not min sizes
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

        // SHRINK LOGIC: When content exceeds available space
        if (size_to_distribute < 0 and total_desired > 0) {
            const overflow = -size_to_distribute;
            const shrink_ratio = @max(0, 1.0 - overflow / total_desired);

            child_idx = first_child;
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

                var new_size: f32 = undefined;
                if (child_sizing.value == .grow) {
                    new_size = child_min_constraint;
                } else {
                    // Shrink proportionally but respect minimum constraint
                    new_size = @max(child_min_constraint, child_desired * shrink_ratio);
                }

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
                const content_width = child.computed.sized_width - child_layout.padding.totalX();
                const content_height = child.computed.sized_height - child_layout.padding.totalY();
                if (child.first_child_index) |grandchild| {
                    self.distributeSpace(grandchild, child_layout, content_width, content_height);
                }

                child_idx = child.next_sibling_index;
            }
            return;
        }

        // GROW LOGIC: distribute remaining space
        const per_grow = if (grow_count > 0) @max(0, size_to_distribute) / @as(f32, @floatFromInt(grow_count)) else 0;

        child_idx = first_child;
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

            self.computeFinalSizes(ci, child_width, child_height);
            child_idx = child.next_sibling_index;
        }
    }

    // =========================================================================
    // Phase 3: Compute positions (top-down)
    // =========================================================================

    fn computePositions(self: *Self, index: u32, parent_x: f32, parent_y: f32) void {
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
            .width = elem.computed.sized_width - padding.totalX(),
            .height = elem.computed.sized_height - padding.totalY(),
        };

        // Position children (pass scroll offset if this is a scroll container)
        if (elem.first_child_index) |first_child| {
            const scroll_offset: ?ScrollOffset = if (elem.config.scroll) |s|
                ScrollOffset{ .x = s.scroll_offset.x, .y = s.scroll_offset.y }
            else
                null;
            self.positionChildren(first_child, layout, elem.computed.content_box, scroll_offset);
        }
    }

    fn positionChildren(self: *Self, first_child: u32, layout: LayoutConfig, content_box: BoundingBox, scroll_offset: ?ScrollOffset) void {
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

            self.computePositions(ci, child_x, child_y);

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
    // =========================================================================

    fn generateRenderCommands(self: *Self, index: u32, inherited_z_index: i16, inherited_opacity: f32) !void {
        const elem = self.elements.get(index);
        const bbox = elem.computed.bounding_box;

        // Floating elements override z_index for themselves and their children
        const z_index: i16 = if (elem.config.floating) |f| f.z_index else inherited_z_index;

        // Combine element opacity with inherited opacity (multiplicative)
        const opacity = elem.config.opacity * inherited_opacity;

        // Cache z_index for O(1) lookup via getZIndex()
        elem.cached_z_index = z_index;

        // Shadow (renders BEFORE background rectangle)
        if (elem.config.shadow) |shadow| {
            if (shadow.isVisible()) {
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
        }

        // Background rectangle
        if (elem.config.background_color) |bg| {
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

        // Border
        if (elem.config.border) |border| {
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

        // Text
        if (elem.text_data) |td| {
            const text_color = td.config.color.withAlpha(td.config.color.a * opacity);
            if (td.wrapped_lines) |lines| {
                // Render each wrapped line
                const line_height = td.config.lineHeightPx();
                // Use container width for alignment if available (from wrapping), otherwise use bbox
                const align_width = if (td.container_width > 0) td.container_width else bbox.width;
                for (lines, 0..) |line, i| {
                    const line_y = bbox.y + @as(f32, @floatFromInt(i)) * line_height;
                    // Calculate x offset based on text alignment within container
                    const line_x = bbox.x + switch (td.config.alignment) {
                        .left => 0,
                        .center => (align_width - line.width) / 2,
                        .right => align_width - line.width,
                    };
                    try self.commands.append(.{
                        .bounding_box = .{
                            .x = line_x,
                            .y = line_y,
                            .width = line.width,
                            .height = line_height,
                        },
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
                // Use container width for alignment if available, otherwise use bbox
                const align_width = if (td.container_width > 0) td.container_width else bbox.width;
                // Calculate x offset based on text alignment
                const text_x = bbox.x + switch (td.config.alignment) {
                    .left => 0,
                    .center => (align_width - td.measured_width) / 2,
                    .right => align_width - td.measured_width,
                };
                try self.commands.append(.{
                    .bounding_box = .{
                        .x = text_x,
                        .y = bbox.y,
                        .width = td.measured_width,
                        .height = bbox.height,
                    },
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

        // SVG
        if (elem.svg_data) |sd| {
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

        // Image
        if (elem.image_data) |id| {
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
                } },
            });
        }

        // Scissor for scroll containers
        if (elem.config.scroll) |_| {
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
                try self.generateRenderCommands(ci, z_index, opacity);
                child_idx = self.elements.getConst(ci).next_sibling_index;
            }
        }

        // End scissor
        if (elem.config.scroll != null) {
            try self.commands.append(.{
                .bounding_box = bbox,
                .command_type = .scissor_end,
                .z_index = z_index,
                .id = elem.id,
                .data = .{ .scissor_end = {} },
            });
        }
    }

    /// Wrap text into lines based on available width
    fn wrapText(
        self: *Self,
        text_str: []const u8,
        config: TextConfig,
        max_width: f32,
    ) !struct { lines: []types.WrappedLine, total_height: f32, max_line_width: f32 } {
        if (config.wrap_mode == .none or max_width <= 0) {
            return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
        }

        const measure_fn = self.measure_text_fn orelse {
            return .{ .lines = &.{}, .total_height = 0, .max_line_width = 0 };
        };

        var lines: std.ArrayListUnmanaged(types.WrappedLine) = .{};
        defer lines.deinit(self.allocator);

        const line_height = config.lineHeightPx();
        var max_line_width: f32 = 0;

        var line_start: u32 = 0;
        var line_width: f32 = 0; // Width of text from line_start up to (but not including) current word
        var word_start: u32 = 0;
        var word_width: f32 = 0; // Width of current word being accumulated
        var i: u32 = 0;

        while (i < text_str.len) : (i += 1) {
            const c = text_str[i];
            const is_space = c == ' ' or c == '\t';
            const is_newline = c == '\n';

            if (is_newline) {
                // Finalize current word and emit line
                const total_width = line_width + word_width;
                try lines.append(self.allocator, .{
                    .start_offset = line_start,
                    .length = i - line_start,
                    .width = total_width,
                });
                max_line_width = @max(max_line_width, total_width);
                line_start = i + 1;
                word_start = i + 1;
                line_width = 0;
                word_width = 0;
                continue;
            }

            // Measure character width
            const char_width = measure_fn(
                text_str[i .. i + 1],
                config.font_id,
                config.font_size,
                null,
                self.measure_text_user_data,
            ).width;

            if (is_space) {
                // Space ends a word - add word to line width
                line_width += word_width + char_width;
                word_width = 0;
                word_start = i + 1;
                continue;
            }

            // Regular character - check if we need to wrap BEFORE adding it
            if (config.wrap_mode == .words and line_width + word_width + char_width > max_width) {
                // Need to wrap
                if (word_start > line_start and line_width > 0) {
                    // Wrap at last word boundary (emit line without current word)
                    // Trim trailing space from line_width by re-measuring
                    const line_text = text_str[line_start..word_start];
                    const trimmed_len = std.mem.trimRight(u8, line_text, " \t").len;
                    const trimmed_width = if (trimmed_len > 0)
                        measure_fn(
                            text_str[line_start..][0..trimmed_len],
                            config.font_id,
                            config.font_size,
                            null,
                            self.measure_text_user_data,
                        ).width
                    else
                        0;

                    try lines.append(self.allocator, .{
                        .start_offset = line_start,
                        .length = @intCast(word_start - line_start),
                        .width = trimmed_width,
                    });
                    max_line_width = @max(max_line_width, trimmed_width);

                    // New line starts at current word
                    line_start = word_start;
                    line_width = 0;
                    // word_width already has accumulated chars, keep it
                } else if (word_width > 0) {
                    // No word break available but we have content - force break
                    try lines.append(self.allocator, .{
                        .start_offset = line_start,
                        .length = i - line_start,
                        .width = line_width + word_width,
                    });
                    max_line_width = @max(max_line_width, line_width + word_width);
                    line_start = i;
                    word_start = i;
                    line_width = 0;
                    word_width = 0;
                }
            }

            word_width += char_width;
        }

        // Emit final line
        if (line_start < text_str.len) {
            const total_width = line_width + word_width;
            try lines.append(self.allocator, .{
                .start_offset = line_start,
                .length = @intCast(text_str.len - line_start),
                .width = total_width,
            });
            max_line_width = @max(max_line_width, total_width);
        }

        const result_lines = try self.arena.allocator().dupe(types.WrappedLine, lines.items);
        const total_height = line_height * @as(f32, @floatFromInt(@max(1, result_lines.len)));

        return .{
            .lines = result_lines,
            .total_height = total_height,
            .max_line_width = max_line_width,
        };
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
