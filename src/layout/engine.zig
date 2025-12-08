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
const TextConfig = types.TextConfig;

const LayoutId = layout_id.LayoutId;
const LayoutArena = arena_mod.LayoutArena;
const RenderCommand = render_commands.RenderCommand;
const RenderCommandList = render_commands.RenderCommandList;
const RenderCommandType = render_commands.RenderCommandType;

// ============================================================================
// Element Types (defined inline)
// ============================================================================

pub const ElementDeclaration = struct {
    id: LayoutId = LayoutId.none,
    layout: LayoutConfig = .{},
    background_color: ?Color = null,
    corner_radius: CornerRadius = .{},
    border: ?BorderConfig = null,
    scroll: ?types.ScrollConfig = null,
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
    debug_seen_ids: std.AutoHashMap(u32, ?[]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .arena = LayoutArena.init(allocator),
            .elements = ElementList.init(allocator),
            .commands = RenderCommandList.init(allocator),
            .open_element_stack = .{},
            .debug_seen_ids = std.AutoHashMap(u32, ?[]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.debug_seen_ids.deinit();
        self.open_element_stack.deinit(self.allocator);
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
        self.debug_seen_ids.clearRetainingCapacity();
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
        std.debug.assert(self.open_element_stack.items.len > 0); // Text requires a parent

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
        // Debug: check for ID collisions (skip if ID is none/0)
        if (std.debug.runtime_safety and decl.id.id != 0) {
            const result = self.debug_seen_ids.getOrPut(decl.id.id) catch unreachable;
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

        // Link to parent
        if (parent_index) |pi| {
            const parent = self.elements.get(pi);
            if (parent.first_child_index == null) {
                parent.first_child_index = index;
            } else {
                // Find last sibling
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
        if (self.root_index == null) return &.{};

        // Phase 1: Compute minimum sizes (bottom-up)
        self.computeMinSizes(self.root_index.?);

        // Phase 2: Compute final sizes (top-down)
        self.computeFinalSizes(self.root_index.?, self.viewport_width, self.viewport_height);

        // Phase 3: Compute positions (top-down)
        self.computePositions(self.root_index.?, 0, 0);

        // Phase 4: Generate render commands
        try self.generateRenderCommands(self.root_index.?);

        return self.commands.items();
    }

    /// Get computed bounding box for an element by ID
    pub fn getBoundingBox(self: *const Self, id: u32) ?BoundingBox {
        for (self.elements.items()) |elem| {
            if (elem.id == id) {
                return elem.computed.bounding_box;
            }
        }
        return null;
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

        // Compute this element's final size based on sizing type
        elem.computed.sized_width = computeAxisSize(sizing.width, elem.computed.min_width, available_width);
        elem.computed.sized_height = computeAxisSize(sizing.height, elem.computed.min_height, available_height);

        // Content area for children (after padding)
        const content_width = elem.computed.sized_width - layout.padding.totalX();
        const content_height = elem.computed.sized_height - layout.padding.totalY();

        // Distribute space to children
        if (elem.first_child_index) |first_child| {
            self.distributeSpace(first_child, layout, content_width, content_height);
        }
    }

    /// Distribute available space among children (handles grow elements)
    fn distributeSpace(self: *Self, first_child: u32, layout: LayoutConfig, width: f32, height: f32) void {
        const is_horizontal = layout.layout_direction.isHorizontal();
        const gap: f32 = @floatFromInt(layout.child_gap);

        // First pass: count grow elements and calculate fixed size
        var grow_count: u32 = 0;
        var fixed_size: f32 = 0;
        var child_count: u32 = 0;

        var child_idx: ?u32 = first_child;
        while (child_idx) |ci| {
            const child = self.elements.getConst(ci);
            const child_sizing = if (is_horizontal)
                child.config.layout.sizing.width
            else
                child.config.layout.sizing.height;

            if (child_sizing.value == .grow) {
                grow_count += 1;
            } else {
                fixed_size += if (is_horizontal) child.computed.min_width else child.computed.min_height;
            }

            child_idx = child.next_sibling_index;
            child_count += 1;
        }

        // Calculate space available for grow elements
        const total_gap = if (child_count > 1) gap * @as(f32, @floatFromInt(child_count - 1)) else 0;
        const available = if (is_horizontal) width else height;
        const grow_space = @max(0, available - fixed_size - total_gap);
        const per_grow = if (grow_count > 0) grow_space / @as(f32, @floatFromInt(grow_count)) else 0;

        // Second pass: assign sizes and recurse
        child_idx = first_child;
        while (child_idx) |ci| {
            const child = self.elements.get(ci);
            const child_sizing_main = if (is_horizontal)
                child.config.layout.sizing.width
            else
                child.config.layout.sizing.height;

            var child_width: f32 = undefined;
            var child_height: f32 = undefined;

            if (is_horizontal) {
                child_width = if (child_sizing_main.value == .grow)
                    @max(child.computed.min_width, per_grow)
                else
                    child.computed.min_width;
                child_height = height;
            } else {
                child_width = width;
                child_height = if (child_sizing_main.value == .grow)
                    @max(child.computed.min_height, per_grow)
                else
                    child.computed.min_height;
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

        // Position children
        if (elem.first_child_index) |first_child| {
            self.positionChildren(first_child, layout, elem.computed.content_box);
        }
    }

    fn positionChildren(self: *Self, first_child: u32, layout: LayoutConfig, content_box: BoundingBox) void {
        const is_horizontal = layout.layout_direction.isHorizontal();
        const gap: f32 = @floatFromInt(layout.child_gap);
        const alignment = layout.child_alignment;

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
        var cursor_x: f32 = content_box.x;
        var cursor_y: f32 = content_box.y;

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
        .fit => applyMinMax(min_size, axis),
        .grow => applyMinMax(available, axis),
        .fixed => |mm| mm.min,
        .percent => |p| applyMinMax(available * p, axis),
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
