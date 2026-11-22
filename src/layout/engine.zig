// Facade: element building and `endFrame`; the layout passes live in
// sibling files.

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

/// Every capacity one layout engine reserves at initialization. All of them
/// come from the app's `ResourceLimits` (`fromLimits`); tests, fuzzers and
/// benchmarks build one from a named profile, so no layout path holds a
/// capacity the budget does not name (CLAUDE.md §2).
///
/// Memory per engine: `element_count_max` × 384 B of elements, `arena_bytes`,
/// `word_count_text_max` × 24 B of word scratch and
/// `wrapped_line_count_frame_max` × 12 B of line scratch, all from fresh
/// pages and resident only as far as frames write. At `nano` that is 0.19 MiB
/// of elements, a 72 KiB arena and 32 KiB of scratch.
pub const LayoutCapacity = struct {
    /// `build.element_count_frame_max` plus the window root.
    element_count_max: u32,
    /// `build.box_depth_max`: the open stack, and the depth every pass's
    /// explicit stack walks.
    box_depth_max: u32,
    /// `build.layer_count_frame_max`: every floating element is a layer box.
    floating_count_max: u32,
    /// Words one wrap batch measures before packing them onto lines
    /// (`sizing_pass.wrapText`); a longer text wraps in several batches, so
    /// this bounds the scratch, not a text. `run_codepoint_count_max`, a
    /// batch as long as one shaping run of one-codepoint words.
    word_count_text_max: u32,
    /// `paint.glyph_count_frame_max`: a frame that wraps more lines than it
    /// can draw glyphs is almost all blank lines. One text's lines may take
    /// all of them, so the line scratch holds this many.
    wrapped_line_count_frame_max: u32,
    /// The per-frame arena (`arenaBytes`).
    arena_bytes: u32,
    /// `build.grid_count_frame_max`: one `grid.GridSlot` per grid box.
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
        std.debug.assert(self.element_count_max > 1); // The root and one element.
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

    /// The arena holds the frame's text copies (at most the text budget,
    /// doubled for alignment gaps between them and the line slices) and its
    /// wrapped lines, capped at the glyph budget by
    /// `wrapped_line_count_frame_max`.
    fn arenaBytes(limits: *const limits_mod.ResourceLimits) u32 {
        const text_bytes: u64 = limits.build.text_bytes_frame_max;
        const line_count: u64 = limits.paint.glyph_count_frame_max;
        std.debug.assert(text_bytes > 0);
        std.debug.assert(line_count > 0);
        comptime std.debug.assert(@sizeOf(types.WrappedLine) == 12);
        const bytes = text_bytes * 2 + line_count * @sizeOf(types.WrappedLine);
        std.debug.assert(bytes <= std.math.maxInt(u32));
        return @intCast(bytes);
    }
};

/// Threshold for treating a max constraint as effectively unconstrained
/// (detects grow elements without a meaningful upper bound in the fast path).
pub const UNCONSTRAINED_MAX: f32 = 1e10;

/// One unit of text wrapping: a word, measured once, and the run of spaces
/// and tabs after it, each at its own advance. A paragraph's leading
/// whitespace is a unit with an empty word.
pub const WordInfo = struct {
    start: u32, // byte offset where word starts
    end: u32, // byte offset where word ends (exclusive); its whitespace starts here
    space_end: u32, // byte offset where its whitespace ends (exclusive)
    width: f32, // measured width of this word
    space_width: f32, // advance of its whitespace, every space and tab counted
    has_newline: bool, // a newline at `space_end` ends the unit's line
};

/// A list over storage the engine reserved at initialization: it never
/// allocates, and a full list reports `error.Overflow` for its owner to fail
/// fast with the budget field that sized it.
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
    /// Opacity for the entire element subtree (0.0 = transparent, 1.0 = opaque)
    opacity: f32 = 1.0,
    /// Whether this element is a canvas (for deferred paint callbacks)
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
    /// The narrowest it can wrap without cutting a word: its widest word
    /// when it wraps at words, else `measured_width`.
    floor_width: f32 = 0,
    wrapped_lines: ?[]const types.WrappedLine = null,
    /// Container width for text alignment (set during wrapping)
    container_width: f32 = 0,
    /// The container's content left edge, scrolled, that `.center` and
    /// `.right` lines align from (set during positioning). Not the text's
    /// own x: the parent's alignment has already moved that.
    container_x: f32 = 0,
};

pub const ComputedLayout = struct {
    bounding_box: BoundingBox = .{},
    content_box: BoundingBox = .{},
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// The narrowest the element can be without cutting its content, at most
    /// `min_width`: an overflowing parent shrinks it no further, and a grow
    /// element takes at least this much. Wrapping text makes it smaller than
    /// `min_width`, which is the content's one-line width. Heights have no
    /// such field: before text wraps, `min_height` is already the floor.
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
    /// Whether this child starts a line of its wrapping parent. The sizing
    /// pass breaks the lines once and sets it; positions and fit-content
    /// heights read it, so they never break the lines differently.
    line_start: bool = false,
    /// Whether this element's minimum height may differ from the one the
    /// minimum pass took from one-line text: it is a text that wrapped
    /// taller, an aspect ratio, a wrapping row, or the parent of one whose
    /// minimum changed. `sizing_pass.computeHeights` reads and clears it.
    min_height_dirty: bool = false,
    /// Whether this element's children need their heights sized again: its
    /// own height changed, or a child's minimum did. Read and cleared by
    /// `sizing_pass.computeHeights`.
    heights_dirty: bool = false,
    /// A cell's column: as declared (`types.cell_column_auto` for the next
    /// free) until its grid places it, then the column it took
    /// (`grid.placeCells`).
    cell_column: u8 = types.cell_column_auto,
    /// The columns a cell spans; a row box spans them all once placed.
    cell_span: u8 = 1,
    /// A grid box's slot in `LayoutEngine.grid_slots`; `grid_slot_none` for
    /// every other box.
    grid_slot: u16 = grid_slot_none,
    text_data: ?TextData = null,
};

pub const grid_slot_none: u16 = std.math.maxInt(u16);

/// What `LayoutEngine.openElementWith` adds to an element's declaration: a
/// grid box's tracks, and where a child of a grid or a row box sits.
pub const OpenOptions = struct {
    grid: ?*const types.GridConfig = null,
    cell: types.Cell = .{},
};

/// Element storage: one reservation of `LayoutCapacity.element_count_max`
/// elements, never grown.
pub const ElementList = struct {
    elements: std.ArrayList(LayoutElement),
    /// Most elements any frame has held; `deinit` zeroes this prefix (§21).
    element_count_max: u32,

    const Self = @This();

    /// Reserves exactly the per-frame element budget through
    /// `core/reservation.zig`, so only the elements a frame writes become
    /// resident. A failed reservation is returned rather than ignored: an
    /// engine without it would allocate on the frame path (CLAUDE.md §2).
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

    /// Exhaustion is a capacity-planning error (CLAUDE.md §2): it stops with
    /// the pool name and the budget field rather than growing a reservation no
    /// allocator owns. The core fails first, in `cx.addNode`, at the same
    /// budget; direct layout callers reach this one.
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
    /// The arena's reservation and its high-water mark, zeroed on release (§21).
    arena_buffer: []u8,
    arena_used_max: usize,
    elements: ElementList,
    /// Open container indices, `box_depth_max` deep.
    open_element_stack: BoundedList(u32),
    root_index: ?u32 = null,
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    measure_text_fn: ?MeasureTextFn = null,
    measure_text_user_data: ?*anyopaque = null,
    /// Floating elements to position after main layout, `floating_count_max`.
    floating_roots: BoundedList(u32),
    /// One slot per grid box this frame, claimed in declaration order,
    /// `capacity.grid_count_max` of them; `grid_count_used_max` is the
    /// high-water mark zeroed on release (§21).
    grid_slots: []grid_mod.GridSlot,
    grid_count: u32 = 0,
    grid_count_used_max: u32 = 0,
    /// One wrap batch's words and one text's wrapped lines while it wraps,
    /// reserved once so a wrap needs no stack buffer (`sizing_pass.wrapText`).
    word_scratch: []WordInfo,
    line_scratch: []types.WrappedLine,
    /// The scratch tables' high-water marks, zeroed on release (§21).
    word_count_used_max: u32 = 0,
    line_count_used_max: u32 = 0,
    /// Wrapped lines this frame, across every text, against
    /// `capacity.wrapped_line_count_frame_max`.
    wrapped_line_count: u32 = 0,
    /// Whether a height followed from a width this frame: an aspect ratio, a
    /// wrapping row's lines, or a text that wrapped to other than one line,
    /// set where each is found. Only then are the heights the sizing pass
    /// took from one-line text wrong, so only then does the frame size its
    /// heights again (`sizing_pass.computeHeights`).
    heights_derived: bool = false,
    /// Whether a text this frame wraps at words with its widest word narrower
    /// than its line, set by `text`. Only then does any element's floor
    /// differ from its minimum, so without one the minimum pass copies the
    /// minimum instead of summing floors (`sizing_pass.computeMinSizes`).
    floors_differ: bool = false,

    const Self = @This();

    /// Reserves every per-frame table from `capacity` at initialization and
    /// returns a failed reservation instead of ignoring it, so the frame path
    /// never allocates to make up for it (CLAUDE.md §2, §17). Every table comes
    /// from fresh pages (`core/reservation.zig`): resident only where written.
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
            .line_scratch = lines,
            .grid_slots = grid_slots,
        };
        std.debug.assert(engine.elements.len() == 0);
        std.debug.assert(engine.open_element_stack.buffer.len == capacity.box_depth_max);
        return engine;
    }

    /// Zero every prefix any frame wrote before the pages go back (§21). The
    /// open stack and floating roots are zeroed whole: each is at most 1 KiB.
    pub fn deinit(self: *Self) void {
        self.arena_used_max = @max(self.arena_used_max, self.arena.bytesUsed());
        reservation.release(grid_mod.GridSlot, self.grid_slots, self.grid_count_used_max);
        reservation.release(types.WrappedLine, self.line_scratch, self.line_count_used_max);
        reservation.release(WordInfo, self.word_scratch, self.word_count_used_max);
        const floating = self.floating_roots.buffer;
        reservation.release(u32, floating, floating.len);
        const open_stack = self.open_element_stack.buffer;
        reservation.release(u32, open_stack, open_stack.len);
        reservation.release(u8, self.arena_buffer, self.arena_used_max);
        self.elements.deinit();
    }

    pub fn setMeasureTextFn(self: *Self, func: MeasureTextFn, user_data: ?*anyopaque) void {
        self.measure_text_fn = func;
        self.measure_text_user_data = user_data;
    }

    /// `content` as a text element with `config` sizes in a parent whose
    /// content is `max_width` wide, without adding an element: wrapped by
    /// layout's own word breaking, one measured line when it does not wrap.
    pub fn measureText(
        self: *Self,
        content: []const u8,
        config: types.TextConfig,
        max_width: f32,
    ) TextMeasurement {
        std.debug.assert(self.measure_text_fn != null);
        std.debug.assert(config.font_size > 0);
        return sizing_pass.measureWrapped(self, content, config, max_width);
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

    /// Open a container with the default cell. Only a row box needs the
    /// checks of `openElementWith`; every other box takes the path it took
    /// before grids, inlined into the caller with no copy of `decl`. A call
    /// through `openElementWith` copied it twice, which the Cachegrind gate
    /// measured at +9 to +90 % on layouts without a grid.
    pub inline fn openElement(self: *Self, decl: ElementDeclaration) !void {
        std.debug.assert(decl.layout.grid != .grid); // A grid opens with its tracks.
        if (decl.layout.grid == .row) return self.openElementWith(decl, .{});
        const index = try self.createElement(&decl, .container);
        // `createElement` checked the room (`checkOpenDepth`); the core checks
        // the same budget first, in `cx.checkBoxDepth`.
        std.debug.assert(self.open_element_stack.len < self.capacity.box_depth_max);
        self.open_element_stack.append(index) catch unreachable;
    }

    /// Open a container with a grid's tracks, a cell, or both: a grid box
    /// claims a grid slot and copies `options.grid` into it, and a child of a
    /// grid or a row box takes `options.cell`. Misuse panics, naming the
    /// field, as the core's other style checks do.
    pub fn openElementWith(self: *Self, decl: ElementDeclaration, options: OpenOptions) !void {
        std.debug.assert((decl.layout.grid == .grid) == (options.grid != null));
        // Rows run across a grid and its row boxes; the core sets `.row`.
        if (decl.layout.grid != .none) {
            std.debug.assert(decl.layout.layout_direction == .left_to_right);
        }
        self.checkCell(&decl, options.cell);
        if (options.grid) |config| checkGrid(&decl, config);
        const index = try self.createElement(&decl, .container);
        // `createElement` checked the room (`checkOpenDepth`); the core checks
        // the same budget first, in `cx.checkBoxDepth`.
        std.debug.assert(self.open_element_stack.len < self.capacity.box_depth_max);
        self.open_element_stack.append(index) catch unreachable;
        const elem = self.elements.get(index);
        elem.cell_column = options.cell.column;
        elem.cell_span = options.cell.column_span;
        if (options.grid) |config| self.claimGrid(elem, config);
    }

    /// A cell's span and column against its grid's columns, and a row box's
    /// place: directly in a grid, with no column, padding across, or wrap.
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

    /// A grid's track counts and bounds, and the fields a grid cannot have.
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

    /// Claim the frame's next grid slot for `elem` and copy its tracks. A
    /// frame past the pool is a capacity-planning error naming its budget.
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
        std.debug.assert(self.open_element_stack.len > 0);

        var decl = ElementDeclaration{};
        decl.layout.sizing = Sizing.fitContent();

        const index = try self.createElement(&decl, .text);
        const elem = self.elements.get(index);
        const text_copy = try self.arena.dupe(content);
        elem.text_data = TextData{
            .text = text_copy,
            .config = config,
        };

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
            elem.text_data.?.floor_width = if (config.wrap_mode == .words and content.len > 0)
                @min(measured.width, sizing_pass.widestWord(self, content, config))
            else
                measured.width;
        } else {
            // Fallback estimate: 0.6 is an average glyph advance ratio, 1.2 a
            // typical line-height ratio.
            const font_size_f: f32 = @floatFromInt(config.font_size);
            elem.text_data.?.measured_width = @as(f32, @floatFromInt(content.len)) * font_size_f * 0.6;
            elem.text_data.?.measured_height = font_size_f * 1.2;
            elem.text_data.?.floor_width = elem.text_data.?.measured_width;
        }
        std.debug.assert(elem.text_data.?.floor_width <= elem.text_data.?.measured_width);
        if (elem.text_data.?.floor_width < elem.text_data.?.measured_width) self.floors_differ = true;
    }

    /// Appends the element, tracks it as a floating root when it floats, and
    /// links it to its parent.
    /// Inline into its three callers, as it was into two before grids: a
    /// call of its own copied every whole declaration once more.
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

        // Floating elements are positioned after the main layout.
        if (decl.floating != null) {
            self.floating_roots.append(index) catch self.floatingRootsFailed();
        }

        self.linkToParent(index, parent_index);

        return index;
    }

    /// A container past the open stack is a capacity-planning error that names
    /// the budget field sizing it.
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

    /// The core opens one floating element per layer box, so a frame past
    /// this pool has more layers than `build.layer_count_frame_max` allows.
    fn floatingRootsFailed(self: *const Self) noreturn {
        std.debug.assert(self.floating_roots.len == self.capacity.floating_count_max);
        std.debug.panic("layout pool 'floating roots' exhausted: capacity {d}, {d} in use, " ++
            "1 requested. Raise ResourceLimits.build.layer_count_frame_max.", .{
            self.capacity.floating_count_max,
            self.floating_roots.len,
        });
    }

    /// Links the element into its parent's child list; `last_child_index`
    /// keeps the append O(1). Promotes the element to root when no parent is
    /// open.
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

    /// End frame and compute every element's bounds. `core/emit.zig` reads
    /// them through `elements` to write the frame's paint records.
    pub fn endFrame(self: *Self) !void {
        const root = self.root_index orelse return;
        std.debug.assert(root < self.elements.len());
        std.debug.assert(self.open_element_stack.len == 0);

        sizing_pass.computeMinSizes(self, root);

        sizing_pass.computeFinalSizes(self, root, self.viewport_width, self.viewport_height);

        // Widths are final: wrap text at them, then size heights from the
        // wrapped text, as Clay orders its passes.
        try sizing_pass.computeTextWrapping(self, root);
        if (self.heights_derived) sizing_pass.computeHeights(self, root, self.viewport_height);

        position_pass.computePositions(self, root, 0, 0);

        try position_pass.computeFloatingPositions(self);
    }
};
