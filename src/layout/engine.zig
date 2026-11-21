// Facade: element building and `endFrame`; the layout passes live in
// sibling files.

const std = @import("std");

const types = @import("types.zig");
const reservation = @import("../core/reservation.zig");
const arena_mod = @import("arena.zig");
const sizing_pass = @import("sizing_pass.zig");
const position_pass = @import("position_pass.zig");

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

    pub fn fromLimits(limits: *const limits_mod.ResourceLimits) LayoutCapacity {
        std.debug.assert(limits.check() == null);
        const capacity: LayoutCapacity = .{
            .element_count_max = limits.build.element_count_frame_max + 1,
            .box_depth_max = limits.build.box_depth_max,
            .floating_count_max = limits.build.layer_count_frame_max,
            .word_count_text_max = limits_mod.run_codepoint_count_max,
            .wrapped_line_count_frame_max = limits.paint.glyph_count_frame_max,
            .arena_bytes = arenaBytes(limits),
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
    /// A fit-content box that a height derived from a width under it grows:
    /// set by `sizing_pass.markDerivedHeight`, cleared once it has grown.
    height_marked: bool = false,
    text_data: ?TextData = null,
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
    /// Whether the sizing pass derived a height from a width this frame, for
    /// an aspect ratio or a wrapping row, set in the branches that derive
    /// them. Without one, the pass that grows fit-content parents to such
    /// heights skips its test on every element.
    heights_derived: bool = false,
    /// Whether a box is marked to grow to such a height, so the walk that
    /// grows marked boxes has work (`sizing_pass.growMarkedParents`).
    parents_marked: bool = false,

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
        };
        std.debug.assert(engine.elements.len() == 0);
        std.debug.assert(engine.open_element_stack.buffer.len == capacity.box_depth_max);
        return engine;
    }

    /// Zero every prefix any frame wrote before the pages go back (§21). The
    /// open stack and floating roots are zeroed whole: each is at most 1 KiB.
    pub fn deinit(self: *Self) void {
        self.arena_used_max = @max(self.arena_used_max, self.arena.bytesUsed());
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
        self.parents_marked = false;
    }

    pub fn openElement(self: *Self, decl: ElementDeclaration) !void {
        const index = try self.createElement(decl, .container);
        // `createElement` checked the room (`checkOpenDepth`); the core checks
        // the same budget first, in `cx.checkBoxDepth`.
        std.debug.assert(self.open_element_stack.len < self.capacity.box_depth_max);
        self.open_element_stack.append(index) catch unreachable;
    }

    pub fn closeElement(self: *Self) void {
        std.debug.assert(self.open_element_stack.len > 0);
        _ = self.open_element_stack.pop();
    }

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
            // Fallback estimate: 0.6 is an average glyph advance ratio, 1.2 a
            // typical line-height ratio.
            const font_size_f: f32 = @floatFromInt(config.font_size);
            elem.text_data.?.measured_width = @as(f32, @floatFromInt(content.len)) * font_size_f * 0.6;
            elem.text_data.?.measured_height = font_size_f * 1.2;
        }
    }

    /// Appends the element, tracks it as a floating root when it floats, and
    /// links it to its parent.
    fn createElement(self: *Self, decl: ElementDeclaration, elem_type: ElementType) !u32 {
        if (elem_type == .container) self.checkOpenDepth();
        const parent_index = self.open_element_stack.last();

        const index = self.elements.append(.{
            .config = decl,
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

        try sizing_pass.computeTextWrapping(self, root);

        position_pass.computePositions(self, root, 0, 0);

        try position_pass.computeFloatingPositions(self);
    }
};
