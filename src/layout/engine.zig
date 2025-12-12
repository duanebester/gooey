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
};

pub const ElementType = enum {
    container,
    text,
};

pub const TextData = struct {
    text: []const u8,
    config: TextConfig,
    measured_width: f32 = 0,
    measured_height: f32 = 0,
    wrapped_lines: ?[]const types.WrappedLine = null,
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

    /// Create an element and link it into the tree
    fn createElement(self: *Self, decl: ElementDeclaration, elem_type: ElementType) !u32 {
        // Check for ID collisions (skip if ID is none/0)
        // NOTE: Runs in all build modes - ID collisions cause subtle bugs
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

        // Phase 3b: Position floating elements
        self.computeFloatingPositions();

        // Phase 4: Generate render commands
        try self.generateRenderCommands(self.root_index.?);

        // Sort by z-index to handle floating elements properly
        self.commands.sortByZIndex();

        return self.commands.items();
    }

    /// Compute text wrapping now that container sizes are known
    fn computeTextWrapping(self: *Self, index: u32) !void {
        const elem = self.elements.get(index);

        // Handle text wrapping for this element
        if (elem.text_data) |*td| {
            if (td.config.wrap_mode != .none) {
                const max_width = if (elem.parent_index) |pi| blk: {
                    const parent = self.elements.getConst(pi);
                    break :blk parent.computed.sized_width - parent.config.layout.padding.totalX();
                } else self.viewport_width;

                if (max_width > 0) {
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

    fn computeFloatingPositions(self: *Self) void {
        for (self.floating_roots.items) |float_idx| {
            const elem = self.elements.get(float_idx);
            const floating = elem.config.floating orelse continue;

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

            // Final position
            const final_x = parent_x - elem_offset_x + floating.offset.x;
            const final_y = parent_y - elem_offset_y + floating.offset.y;

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

    // =========================================================================
    // Phase 1: Compute minimum sizes (bottom-up)
    // =========================================================================

    fn computeMinSizes(self: *Self, index: u32) void {
        const elem = self.elements.get(index);
        const layout = elem.config.layout;
        const padding = layout.padding;

        var content_width: f32 = 0;
        var content_height: f32 = 0;

        // Process children first (bottom-up)
        if (elem.first_child_index) |first_child| {
            var child_idx: ?u32 = first_child;
            var child_count: u32 = 0;

            while (child_idx) |ci| {
                self.computeMinSizes(ci);
                const child = self.elements.getConst(ci);

                if (layout.layout_direction.isHorizontal()) {
                    content_width += child.computed.min_width;
                    content_height = @max(content_height, child.computed.min_height);
                } else {
                    content_width = @max(content_width, child.computed.min_width);
                    content_height += child.computed.min_height;
                }

                child_idx = child.next_sibling_index;
                child_count += 1;
            }

            // Add gaps between children
            if (child_count > 1) {
                const gap: f32 = @floatFromInt(layout.child_gap);
                if (layout.layout_direction.isHorizontal()) {
                    content_width += gap * @as(f32, @floatFromInt(child_count - 1));
                } else {
                    content_height += gap * @as(f32, @floatFromInt(child_count - 1));
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
        const gap: f32 = @floatFromInt(layout.child_gap);
        const alignment = layout.child_alignment;

        // Apply scroll offset if present
        const offset_x: f32 = if (scroll_offset) |s| -s.x else 0;
        const offset_y: f32 = if (scroll_offset) |s| -s.y else 0;

        // Calculate total children size for alignment
        var total_main: f32 = 0;
        var child_count: u32 = 0;
        var child_idx: ?u32 = first_child;

        while (child_idx) |ci| {
            const child = self.elements.getConst(ci);
            total_main += if (is_horizontal) child.computed.sized_width else child.computed.sized_height;
            child_idx = child.next_sibling_index;
            child_count += 1;
        }

        if (child_count > 1) {
            total_main += gap * @as(f32, @floatFromInt(child_count - 1));
        }

        // Calculate starting position based on alignment
        var cursor_x: f32 = content_box.x + offset_x;
        var cursor_y: f32 = content_box.y + offset_y;

        if (is_horizontal) {
            cursor_x += switch (alignment.x) {
                .left => 0,
                .center => (content_box.width - total_main) / 2,
                .right => content_box.width - total_main,
            };
        } else {
            cursor_y += switch (alignment.y) {
                .top => 0,
                .center => (content_box.height - total_main) / 2,
                .bottom => content_box.height - total_main,
            };
        }

        // Position each child
        child_idx = first_child;
        while (child_idx) |ci| {
            const child = self.elements.get(ci);

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
                cursor_x += child.computed.sized_width + gap;
            } else {
                cursor_y += child.computed.sized_height + gap;
            }

            child_idx = child.next_sibling_index;
        }
    }

    // =========================================================================
    // Phase 4: Generate render commands
    // =========================================================================

    fn generateRenderCommands(self: *Self, index: u32) !void {
        const elem = self.elements.getConst(index);
        const bbox = elem.computed.bounding_box;

        // Shadow (renders BEFORE background rectangle)
        if (elem.config.shadow) |shadow| {
            if (shadow.isVisible()) {
                try self.commands.append(.{
                    .bounding_box = bbox,
                    .command_type = .shadow,
                    .id = elem.id,
                    .data = .{ .shadow = .{
                        .blur_radius = shadow.blur_radius,
                        .color = shadow.color,
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
                .id = elem.id,
                .data = .{ .rectangle = .{
                    .background_color = bg,
                    .corner_radius = elem.config.corner_radius,
                } },
            });
        }

        // Border
        if (elem.config.border) |border| {
            try self.commands.append(.{
                .bounding_box = bbox,
                .command_type = .border,
                .id = elem.id,
                .data = .{ .border = .{
                    .color = border.color,
                    .width = border.width,
                    .corner_radius = elem.config.corner_radius,
                } },
            });
        }

        // Text
        if (elem.text_data) |td| {
            if (td.wrapped_lines) |lines| {
                // Render each wrapped line
                const line_height = td.config.lineHeightPx();
                for (lines, 0..) |line, i| {
                    const line_y = bbox.y + @as(f32, @floatFromInt(i)) * line_height;
                    try self.commands.append(.{
                        .bounding_box = .{
                            .x = bbox.x,
                            .y = line_y,
                            .width = line.width,
                            .height = line_height,
                        },
                        .command_type = .text,
                        .id = elem.id,
                        .data = .{ .text = .{
                            .text = td.text[line.start_offset..][0..line.length],
                            .color = td.config.color,
                            .font_id = td.config.font_id,
                            .font_size = td.config.font_size,
                            .letter_spacing = td.config.letter_spacing,
                        } },
                    });
                }
            } else {
                // Single line (no wrapping)
                try self.commands.append(.{
                    .bounding_box = bbox,
                    .command_type = .text,
                    .id = elem.id,
                    .data = .{ .text = .{
                        .text = td.text,
                        .color = td.config.color,
                        .font_id = td.config.font_id,
                        .font_size = td.config.font_size,
                        .letter_spacing = td.config.letter_spacing,
                    } },
                });
            }
        }

        // Scissor for scroll containers
        if (elem.config.scroll) |_| {
            try self.commands.append(.{
                .bounding_box = bbox,
                .command_type = .scissor_start,
                .id = elem.id,
                .data = .{ .scissor_start = .{ .clip_bounds = bbox } },
            });
        }

        // Recurse to children
        if (elem.first_child_index) |first_child| {
            var child_idx: ?u32 = first_child;
            while (child_idx) |ci| {
                try self.generateRenderCommands(ci);
                child_idx = self.elements.getConst(ci).next_sibling_index;
            }
        }

        // End scissor
        if (elem.config.scroll != null) {
            try self.commands.append(.{
                .bounding_box = bbox,
                .command_type = .scissor_end,
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
