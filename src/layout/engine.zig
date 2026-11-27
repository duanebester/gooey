const std = @import("std");

const types = @import("types.zig");
const reservation = @import("../core/reservation.zig");
const arena_mod = @import("arena.zig");
const sizing_pass = @import("sizing_pass.zig");
const position_pass = @import("position_pass.zig");
const grid_mod = @import("grid.zig");

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

const LayoutArena = arena_mod.LayoutArena;
const limits_mod = @import("../core/limits.zig");

pub const LayoutCapacity = struct {
    element_count_max: u32,
    box_depth_max: u32,
    floating_count_max: u32,
    word_count_text_max: u32,
    wrapped_line_count_frame_max: u32,
    arena_bytes: u32,
    grid_count_max: u32,

    pub fn fromLimits(limits: *const limits_mod.ResourceLimits) LayoutCapacity {
        std.debug.assert(limits.check() == null);
        const capacity: LayoutCapacity = .{
            .element_count_max = limits.build.element_count_frame_max + 1,
            .box_depth_max = limits.build.box_depth_max,
            .floating_count_max = limits.build.layer_count_frame_max,
            .word_count_text_max = limits_mod.run_codepoint_count_max,
            .wrapped_line_count_frame_max = limits.paint.glyph_count_frame_max,
            .arena_bytes = arenaBytes(limits),
            .grid_count_max = limits.build.grid_count_frame_max,
        };
        capacity.assertValid();
        return capacity;
    }

    fn assertValid(self: *const LayoutCapacity) void {
        std.debug.assert(self.element_count_max > 1);
        std.debug.assert(self.element_count_max <= limits_mod.element_count_frame_ceiling + 1);
        std.debug.assert(self.box_depth_max > 0);
        std.debug.assert(self.box_depth_max <= limits_mod.box_depth_ceiling);
        std.debug.assert(self.box_depth_max <= self.element_count_max);
        std.debug.assert(self.floating_count_max > 0);
        std.debug.assert(self.floating_count_max <= self.element_count_max);
        std.debug.assert(self.word_count_text_max > 0);
        std.debug.assert(self.wrapped_line_count_frame_max > 0);
        std.debug.assert(self.arena_bytes > 0);
        std.debug.assert(self.grid_count_max > 0);
        std.debug.assert(self.grid_count_max <= limits_mod.grid_count_ceiling);
        std.debug.assert(self.grid_count_max <= self.element_count_max);
    }

    fn arenaBytes(limits: *const limits_mod.ResourceLimits) u32 {
        const text_bytes: u64 = limits.build.text_bytes_frame_max;
        const line_count: u64 = limits.paint.glyph_count_frame_max;
        std.debug.assert(text_bytes > 0);
        std.debug.assert(line_count > 0);
        comptime std.debug.assert(@sizeOf(types.WrappedLine) == 12);
        comptime std.debug.assert(limits_mod.BuildLimits.ceiling.text_bytes_frame_max <=
            types.line_length_max);
        const bytes = text_bytes * 2 + line_count * @sizeOf(types.WrappedLine);
        std.debug.assert(bytes <= std.math.maxInt(u32));
        return @intCast(bytes);
    }
};

pub const UNCONSTRAINED_MAX: f32 = 1e10;

pub const WordInfo = struct {
    start: u32,
    end: u32,
    space_end: u32,
    width: f32,
    space_width: f32,
    has_newline: bool,
};

/// The advances of a space and a tab in one word unit's font, for a rich text only: a unit
/// never spans a font change inside its spaces, so one pair holds for all of them. Kept
/// beside `WordInfo` (same index) so plain texts neither write nor copy it.
pub const BlankAdvances = struct {
    space: f32,
    tab: f32,
};

pub fn BoundedList(comptime T: type) type {
    return struct {
        buffer: []T,
        len: u32 = 0,

        const Self = @This();

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            std.debug.assert(self.len <= self.buffer.len);
            if (self.len < self.buffer.len) {
                self.buffer[self.len] = item;
                self.len += 1;
            } else {
                return error.Overflow;
            }
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
        }

        pub fn last(self: *const Self) ?T {
            if (self.len == 0) return null;
            return self.buffer[self.len - 1];
        }

        pub fn slice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

pub const ScrollOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const ElementDeclaration = struct {
    layout: LayoutConfig = .{},
    background_color: ?Color = null,
    corner_radius: CornerRadius = .{},
    border: ?BorderConfig = null,
    shadow: ?ShadowConfig = null,
    scroll: ?types.ScrollConfig = null,
    floating: ?types.FloatingConfig = null,
    user_data: ?*anyopaque = null,
    opacity: f32 = 1.0,
    is_canvas: bool = false,
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
    floor_width: f32 = 0,
    ellipsis_width: f32 = 0,
    /// The style runs of a rich text in the engine's run table (`setTextRuns`); a count of
    /// 0 is a plain text. The two `u16`s grow `TextData` from 88 to 96 B; a run table
    /// index keeps them small where a slice would add 16 B.
    runs_start: u16 = 0,
    runs_count: u16 = 0,
    wrapped_lines: ?[]const types.WrappedLine = null,
    container_width: f32 = 0,
    container_x: f32 = 0,
};

pub const ComputedLayout = struct {
    bounding_box: BoundingBox = .{},
    content_box: BoundingBox = .{},
    min_width: f32 = 0,
    min_height: f32 = 0,
    floor_width: f32 = 0,
    sized_width: f32 = 0,
    sized_height: f32 = 0,
};

pub const LayoutElement = struct {
    config: ElementDeclaration,
    parent_index: ?u32 = null,
    first_child_index: ?u32 = null,
    last_child_index: ?u32 = null,
    next_sibling_index: ?u32 = null,
    child_count: u32 = 0,
    computed: ComputedLayout = .{},
    element_type: ElementType = .container,
    line_start: bool = false,
    min_height_dirty: bool = false,
    heights_dirty: bool = false,
    cell_column: u8 = types.cell_column_auto,
    cell_span: u8 = 1,
    grid_slot: u16 = grid_slot_none,
    text_data: ?TextData = null,
};

pub const grid_slot_none: u16 = std.math.maxInt(u16);

pub const OpenOptions = struct {
    grid: ?*const types.GridConfig = null,
    cell: types.Cell = .{},
};

pub const ElementList = struct {
    elements: std.ArrayList(LayoutElement),
    element_count_max: u32,

    const Self = @This();

    pub fn init(count_max: u32) error{OutOfMemory}!Self {
        std.debug.assert(count_max > 0);
        const list = Self{
            .elements = try reservation.reserveList(LayoutElement, count_max),
            .element_count_max = 0,
        };
        std.debug.assert(list.elements.capacity == count_max);
        return list;
    }

    pub fn deinit(self: *Self) void {
        reservation.releaseList(LayoutElement, &self.elements, self.element_count_max);
    }

    pub fn clear(self: *Self) void {
        std.debug.assert(self.elements.items.len <= self.elements.capacity);
        self.element_count_max = @max(self.element_count_max, self.len());
        self.elements.clearRetainingCapacity();
    }

    pub fn append(self: *Self, elem: LayoutElement) u32 {
        const index: u32 = @intCast(self.elements.items.len);
        if (index < self.elements.capacity) {
            self.elements.appendAssumeCapacity(elem);
        } else {
            std.debug.panic("layout pool 'elements' exhausted: capacity {d}, {d} in use, " ++
                "1 requested. Raise ResourceLimits.build.element_count_frame_max.", .{
                self.elements.capacity,
                index,
            });
        }
        std.debug.assert(self.elements.items.len == index + 1);
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

pub const TextMeasurement = struct {
    width: f32,
    height: f32,
};

pub const MeasureTextFn = *const fn (
    text: []const u8,
    font_id: u16,
    font_size: u16,
    max_width: ?f32,
    user_data: ?*anyopaque,
) TextMeasurement;

pub const LayoutEngine = struct {
    capacity: LayoutCapacity,
    arena: LayoutArena,
    arena_buffer: []u8,
    arena_used_max: usize,
    elements: ElementList,
    open_element_stack: BoundedList(u32),
    root_index: ?u32 = null,
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    measure_text_fn: ?MeasureTextFn = null,
    measure_text_user_data: ?*anyopaque = null,
    /// The caller's table of rich-text runs, borrowed until the next `setTextRuns`.
    text_runs: []const types.TextRun = &.{},
    floating_roots: BoundedList(u32),
    grid_slots: []grid_mod.GridSlot,
    grid_count: u32 = 0,
    grid_count_used_max: u32 = 0,
    word_scratch: []WordInfo,
    blank_scratch: []BlankAdvances,
    line_scratch: []types.WrappedLine,
    word_count_used_max: u32 = 0,
    line_count_used_max: u32 = 0,
    wrapped_line_count: u32 = 0,
    heights_derived: bool = false,
    floors_differ: bool = false,

    const Self = @This();

    pub fn init(capacity: *const LayoutCapacity) error{OutOfMemory}!Self {
        capacity.assertValid();

        var elements = try ElementList.init(capacity.element_count_max);
        errdefer elements.deinit();

        const arena_buffer = try reservation.reserve(u8, capacity.arena_bytes);
        errdefer reservation.release(u8, arena_buffer, 0);

        const open_stack = try reservation.reserve(u32, capacity.box_depth_max);
        errdefer reservation.release(u32, open_stack, 0);

        const floating = try reservation.reserve(u32, capacity.floating_count_max);
        errdefer reservation.release(u32, floating, 0);

        const words = try reservation.reserve(WordInfo, capacity.word_count_text_max);
        errdefer reservation.release(WordInfo, words, 0);

        const blanks = try reservation.reserve(BlankAdvances, capacity.word_count_text_max);
        errdefer reservation.release(BlankAdvances, blanks, 0);

        const line_count = capacity.wrapped_line_count_frame_max;
        const lines = try reservation.reserve(types.WrappedLine, line_count);
        errdefer reservation.release(types.WrappedLine, lines, 0);

        const grid_slots = try reservation.reserve(grid_mod.GridSlot, capacity.grid_count_max);

        const engine: Self = .{
            .capacity = capacity.*,
            .arena = LayoutArena.init(arena_buffer),
            .arena_buffer = arena_buffer,
            .arena_used_max = 0,
            .elements = elements,
            .open_element_stack = .{ .buffer = open_stack },
            .floating_roots = .{ .buffer = floating },
            .word_scratch = words,
            .blank_scratch = blanks,
            .line_scratch = lines,
            .grid_slots = grid_slots,
        };
        std.debug.assert(engine.elements.len() == 0);
        std.debug.assert(engine.open_element_stack.buffer.len == capacity.box_depth_max);
        return engine;
    }

    pub fn deinit(self: *Self) void {
        self.arena_used_max = @max(self.arena_used_max, self.arena.bytesUsed());
        reservation.release(grid_mod.GridSlot, self.grid_slots, self.grid_count_used_max);
        reservation.release(types.WrappedLine, self.line_scratch, self.line_count_used_max);
        reservation.release(WordInfo, self.word_scratch, self.word_count_used_max);
        reservation.release(BlankAdvances, self.blank_scratch, self.word_count_used_max);
        const floating = self.floating_roots.buffer;
        reservation.release(u32, floating, floating.len);
        const open_stack = self.open_element_stack.buffer;
        reservation.release(u32, open_stack, open_stack.len);
        reservation.release(u8, self.arena_buffer, self.arena_used_max);
        self.elements.deinit();
    }

    /// Lends the engine the table that `richText` runs are slices of.
    pub fn setTextRuns(self: *Self, table: []const types.TextRun) void {
        std.debug.assert(table.len <= std.math.maxInt(u16));
        self.text_runs = table;
        std.debug.assert(self.text_runs.len == table.len);
    }

    /// The runs of a text, empty for a plain one.
    pub fn runsOf(self: *const Self, data: *const TextData) []const types.TextRun {
        std.debug.assert(data.runs_count <= data.text.len);
        std.debug.assert(@as(u32, data.runs_start) + data.runs_count <= self.text_runs.len);
        const runs = self.text_runs[data.runs_start..][0..data.runs_count];
        types.assertRuns(runs, data.text.len);
        return runs;
    }

    pub fn setMeasureTextFn(self: *Self, func: MeasureTextFn, user_data: ?*anyopaque) void {
        self.measure_text_fn = func;
        self.measure_text_user_data = user_data;
    }

    pub fn measureText(
        self: *Self,
        content: []const u8,
        config: types.TextConfig,
        runs: []const types.TextRun,
        max_width: f32,
    ) TextMeasurement {
        std.debug.assert(self.measure_text_fn != null);
        std.debug.assert(config.font_size > 0);
        types.assertRuns(runs, content.len);
        return sizing_pass.measureWrapped(self, content, config, runs, max_width);
    }

    pub fn beginFrame(self: *Self, width: f32, height: f32) void {
        self.arena_used_max = @max(self.arena_used_max, self.arena.bytesUsed());
        std.debug.assert(self.arena_used_max <= self.arena_buffer.len);
        self.arena.reset();
        self.elements.clear();
        self.open_element_stack.len = 0;
        self.floating_roots.len = 0;
        self.root_index = null;
        self.viewport_width = width;
        self.viewport_height = height;
        self.wrapped_line_count = 0;
        self.heights_derived = false;
        self.floors_differ = false;
        self.grid_count = 0;
    }

    pub inline fn openElement(self: *Self, decl: ElementDeclaration) !void {
        std.debug.assert(decl.layout.grid != .grid);
        if (decl.layout.grid == .row) return self.openElementWith(decl, .{});
        const index = try self.createElement(&decl, .container);
        std.debug.assert(self.open_element_stack.len < self.capacity.box_depth_max);
        self.open_element_stack.append(index) catch unreachable;
    }

    pub fn openElementWith(self: *Self, decl: ElementDeclaration, options: OpenOptions) !void {
        std.debug.assert((decl.layout.grid == .grid) == (options.grid != null));
        if (decl.layout.grid != .none) {
            std.debug.assert(decl.layout.layout_direction == .left_to_right);
        }
        self.checkCell(&decl, options.cell);
        if (options.grid) |config| checkGrid(&decl, config);
        const index = try self.createElement(&decl, .container);
        std.debug.assert(self.open_element_stack.len < self.capacity.box_depth_max);
        self.open_element_stack.append(index) catch unreachable;
        const elem = self.elements.get(index);
        elem.cell_column = options.cell.column;
        elem.cell_span = options.cell.column_span;
        if (options.grid) |config| self.claimGrid(elem, config);
    }

    fn checkCell(self: *const Self, decl: *const ElementDeclaration, cell: types.Cell) void {
        const parent_index = self.open_element_stack.last();
        const parent_role: types.GridRole = if (parent_index) |pi|
            self.elements.getConst(pi).config.layout.grid
        else
            .none;
        const is_default = cell.column == types.cell_column_auto and cell.column_span == 1;
        if (decl.layout.grid == .row) {
            const padding = decl.layout.padding;
            const misplaced = parent_role != .grid or !is_default or decl.layout.wrap;
            if (misplaced or padding.left != 0 or padding.right != 0) {
                std.debug.panic("Cell.row: a row box spans every column and holds only " ++
                    "cells; it sits directly in a grid, with no column, span, wrap, or " ++
                    "horizontal padding", .{});
            }
        }
        if (parent_role == .none) {
            if (!is_default) {
                std.debug.panic("Style.cell: only a child of a grid box sits in a cell", .{});
            }
            return;
        }
        const parent = self.elements.getConst(parent_index.?);
        const grid = if (parent_role == .grid)
            parent
        else
            self.elements.getConst(parent.parent_index.?);
        const column_count = grid_mod.slotOf(self, grid).column_count;
        if (cell.column_span == 0 or cell.column_span > column_count) {
            std.debug.panic("Cell.column_span {d}: the grid has {d} columns", .{
                cell.column_span,
                column_count,
            });
        }
        if (cell.column != types.cell_column_auto) {
            if (@as(u32, cell.column) + cell.column_span > column_count) {
                std.debug.panic("Cell.column {d} with span {d}: the grid has {d} columns", .{
                    cell.column,
                    cell.column_span,
                    column_count,
                });
            }
        }
    }

    fn checkGrid(decl: *const ElementDeclaration, config: *const types.GridConfig) void {
        const column_count = config.columns.len;
        if (column_count == 0 or column_count > types.grid_track_count_max) {
            std.debug.panic("Grid.columns: {d} columns; a grid has 1 to {d}", .{
                column_count,
                types.grid_track_count_max,
            });
        }
        if (config.rows.len > types.grid_track_count_max) {
            std.debug.panic("Grid.rows: {d} rows; a grid lists at most {d}", .{
                config.rows.len,
                types.grid_track_count_max,
            });
        }
        if (decl.layout.wrap) std.debug.panic("Style.grid: a grid box does not also wrap", .{});
        switch (decl.layout.main_axis_distribution) {
            .start, .center, .end => {},
            else => |main| std.debug.panic("Style.alignment.main .{s}: a grid places a child " ++
                "in its cell with start, center, or end", .{@tagName(main)}),
        }
        if (!(config.row_gap >= 0 and std.math.isFinite(config.row_gap))) {
            std.debug.panic("Grid.row_gap {d}: a gap is finite and at least 0", .{config.row_gap});
        }
        for (config.columns, 0..) |track, index| checkTrack(track, index);
        for (config.rows, 0..) |track, index| checkTrack(track, index);
        checkTrack(config.row_implicit, config.rows.len);
    }

    fn checkTrack(track: types.Track, index: usize) void {
        const min = track.axis.getMin();
        const max = track.axis.getMax();
        if (!(min >= 0 and min <= max)) {
            std.debug.panic("Grid track {d}: min {d} and max {d} must satisfy 0 <= min <= max", .{
                index,
                min,
                max,
            });
        }
    }

    fn claimGrid(self: *Self, elem: *LayoutElement, config: *const types.GridConfig) void {
        std.debug.assert(elem.grid_slot == grid_slot_none);
        if (self.grid_count == self.capacity.grid_count_max) {
            std.debug.panic("layout pool 'grids' exhausted: capacity {d}, {d} in use, " ++
                "1 requested. Raise ResourceLimits.build.grid_count_frame_max.", .{
                self.capacity.grid_count_max,
                self.grid_count,
            });
        }
        self.grid_slots[self.grid_count].claim(config);
        elem.grid_slot = @intCast(self.grid_count);
        self.grid_count += 1;
        self.grid_count_used_max = @max(self.grid_count_used_max, self.grid_count);
        std.debug.assert(self.grid_count <= self.capacity.grid_count_max);
    }

    pub fn closeElement(self: *Self) void {
        std.debug.assert(self.open_element_stack.len > 0);
        _ = self.open_element_stack.pop();
    }

    pub fn text(self: *Self, content: []const u8, config: types.TextConfig) !void {
        return self.richText(content, config, &.{});
    }

    /// Adds a text whose `runs` (see `types.TextRun`) give each byte range its own font;
    /// with no runs it is a plain text in `config.font_id`. The runs are a slice of the
    /// engine's run table (`setTextRuns`). Inline so `text`'s empty, comptime-known runs
    /// fold the run checks away: a plain text pays nothing for rich text.
    pub inline fn richText(
        self: *Self,
        content: []const u8,
        config: types.TextConfig,
        runs: []const types.TextRun,
    ) !void {
        std.debug.assert(self.open_element_stack.len > 0);
        std.debug.assert(content.len <= types.line_length_max);
        if (config.line_count_max > 0) std.debug.assert(config.wrap_mode != .none);
        types.assertRuns(runs, content.len);

        var decl = ElementDeclaration{};
        decl.layout.sizing = Sizing.fitContent();

        const index = try self.createElement(&decl, .text);
        const elem = self.elements.get(index);
        const text_copy = try self.arena.dupe(content);
        elem.text_data = TextData{
            .text = text_copy,
            .config = config,
            .runs_start = self.runsStart(runs),
            .runs_count = @intCast(runs.len),
        };
        const data = &elem.text_data.?;
        if (self.measure_text_fn) |measure_fn| {
            const measured = sizing_pass.measureLine(self, content, config, runs);
            data.measured_width = measured.width;
            data.measured_height = measured.height;
            data.floor_width = measured.width;
            if (config.overflow == .ellipsis) {
                const mark = measure_fn(
                    types.ellipsis,
                    config.font_id,
                    config.font_size,
                    null,
                    self.measure_text_user_data,
                );
                std.debug.assert(mark.width >= 0);
                data.ellipsis_width = mark.width;
                data.floor_width = @min(measured.width, mark.width);
            } else if (config.wrap_mode == .words and content.len > 0) {
                const widest = sizing_pass.widestWord(self, content, config, runs);
                data.floor_width = @min(measured.width, widest);
            }
        } else {
            const font_size_f: f32 = @floatFromInt(config.font_size);
            data.measured_width = @as(f32, @floatFromInt(content.len)) * font_size_f * 0.6;
            data.measured_height = font_size_f * 1.2;
            data.floor_width = data.measured_width;
        }
        std.debug.assert(data.floor_width <= data.measured_width);
        if (data.floor_width < data.measured_width) self.floors_differ = true;
    }

    fn runsStart(self: *const Self, runs: []const types.TextRun) u16 {
        if (runs.len == 0) return 0;
        std.debug.assert(self.text_runs.len > 0);
        const base = @intFromPtr(self.text_runs.ptr);
        const first = @intFromPtr(runs.ptr);
        std.debug.assert(first >= base);
        const start = @divExact(first - base, @sizeOf(types.TextRun));
        std.debug.assert(start + runs.len <= self.text_runs.len);
        return @intCast(start);
    }

    inline fn createElement(
        self: *Self,
        decl: *const ElementDeclaration,
        elem_type: ElementType,
    ) !u32 {
        if (elem_type == .container) self.checkOpenDepth();
        const parent_index = self.open_element_stack.last();

        const index = self.elements.append(.{
            .config = decl.*,
            .parent_index = parent_index,
            .element_type = elem_type,
        });

        if (decl.floating != null) {
            self.floating_roots.append(index) catch self.floatingRootsFailed();
        }

        self.linkToParent(index, parent_index);

        return index;
    }

    fn checkOpenDepth(self: *const Self) void {
        const depth = self.open_element_stack.len;
        std.debug.assert(depth <= self.capacity.box_depth_max);
        if (depth < self.capacity.box_depth_max) return;
        std.debug.panic("layout pool 'box depth' exhausted: capacity {d}, {d} in use, " ++
            "1 requested. Raise ResourceLimits.build.box_depth_max.", .{
            self.capacity.box_depth_max,
            depth,
        });
    }

    fn floatingRootsFailed(self: *const Self) noreturn {
        std.debug.assert(self.floating_roots.len == self.capacity.floating_count_max);
        std.debug.panic("layout pool 'floating roots' exhausted: capacity {d}, {d} in use, " ++
            "1 requested. Raise ResourceLimits.build.layer_count_frame_max.", .{
            self.capacity.floating_count_max,
            self.floating_roots.len,
        });
    }

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

    pub fn endFrame(self: *Self) !void {
        const root = self.root_index orelse return;
        std.debug.assert(root < self.elements.len());
        std.debug.assert(self.open_element_stack.len == 0);

        sizing_pass.computeMinSizes(self, root);

        sizing_pass.computeFinalSizes(self, root, self.viewport_width, self.viewport_height);

        try sizing_pass.computeTextWrapping(self, root);
        if (self.heights_derived) sizing_pass.computeHeights(self, root, self.viewport_height);

        position_pass.computePositions(self, root, 0, 0);

        try position_pass.computeFloatingPositions(self);
    }
};
