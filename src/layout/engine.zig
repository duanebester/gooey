//! Core layout engine — Clay-style flexbox layout algorithm.
//!
//! Engine facade: owns the `LayoutEngine` struct, its element/arena
//! storage, the immediate-mode builder API (`openElement`/`closeElement`/
//! `text`/`svg`/`image`), and the `endFrame` orchestrator. The layout phases
//! live in sibling files:
//!
//!   - `sizing_pass.zig`   — min sizes, final sizes, text wrapping.
//!   - `position_pass.zig` — positions, floating positioning.
//!   - `fuzz.zig`          — fuzz targets for the above.

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

// ============================================================================
// Capacity Limits
// ============================================================================

pub const MAX_ELEMENTS_PER_FRAME = 16384;

/// Maximum nesting depth for open elements (e.g., nested containers)
pub const MAX_OPEN_DEPTH = 64;

/// Maximum floating elements (dropdowns, tooltips, modals)
pub const MAX_FLOATING_ROOTS = 256;

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
    text_data: ?TextData = null,
};

/// Element storage: one fixed reservation of `MAX_ELEMENTS_PER_FRAME`
/// elements, never grown.
pub const ElementList = struct {
    elements: std.ArrayList(LayoutElement),
    /// Most elements any frame has held; `deinit` zeroes this prefix (§21).
    element_count_max: u32,

    const Self = @This();

    /// Reserves exactly the per-frame element budget (10.1 MiB at 648 B per
    /// element) through `core/reservation.zig`, so only the elements a frame
    /// writes become resident. It used to round up through `ArrayList` growth
    /// to 24,577 elements, 50% over. A failed reservation is returned rather
    /// than ignored: an engine without it would allocate on the frame path
    /// (CLAUDE.md §2).
    pub fn init() error{OutOfMemory}!Self {
        const list = Self{
            .elements = try reservation.reserveList(LayoutElement, MAX_ELEMENTS_PER_FRAME),
            .element_count_max = 0,
        };
        std.debug.assert(list.elements.capacity == MAX_ELEMENTS_PER_FRAME);
        return list;
    }

    pub fn deinit(self: *Self) void {
        reservation.releaseList(LayoutElement, &self.elements, self.element_count_max);
    }

    pub fn clear(self: *Self) void {
        std.debug.assert(self.elements.items.len <= MAX_ELEMENTS_PER_FRAME);
        self.element_count_max = @max(self.element_count_max, self.len());
        self.elements.clearRetainingCapacity();
    }

    /// Exhaustion is a capacity-planning error (CLAUDE.md §2): it stops with
    /// the pool name and capacity rather than growing a reservation no
    /// allocator owns. `createElement` asserts the same bound before calling.
    pub fn append(self: *Self, elem: LayoutElement) error{}!u32 {
        const index: u32 = @intCast(self.elements.items.len);
        if (index < self.elements.capacity) {
            self.elements.appendAssumeCapacity(elem);
        } else {
            std.debug.panic("layout element list exhausted: capacity {d} " ++
                "(MAX_ELEMENTS_PER_FRAME), {d} in use, 1 requested", .{
                self.elements.capacity,
                index,
            });
        }
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
    /// Stack of open container indices (fixed capacity)
    open_element_stack: FixedCapacityArray(u32, MAX_OPEN_DEPTH) = .{},
    root_index: ?u32 = null,
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    measure_text_fn: ?MeasureTextFn = null,
    measure_text_user_data: ?*anyopaque = null,
    /// Floating elements to position after main layout (fixed capacity)
    floating_roots: FixedCapacityArray(u32, MAX_FLOATING_ROOTS) = .{},
    /// Wrapped lines per frame, across every text. The 0.4.0 core sets it from
    /// its glyph budget and sizes the fixed arena to match; null (the 0.3.1
    /// runtime's growing arena) leaves only the per-text cap.
    wrapped_line_count_frame_max: ?u32 = null,
    wrapped_line_count: u32 = 0,

    const Self = @This();

    /// Reserves every per-frame table at initialization and returns a failed
    /// reservation instead of ignoring it, so the frame path never allocates
    /// to make up for it (CLAUDE.md §2, §17).
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
        const elements = try ElementList.init();
        std.debug.assert(elements.len() == 0);
        return .{
            .allocator = allocator,
            .arena = LayoutArena.init(allocator),
            .elements = elements,
        };
    }

    pub fn deinit(self: *Self) void {
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
        self.open_element_stack.len = 0;
        self.floating_roots.len = 0;
        self.root_index = null;
        self.viewport_width = width;
        self.viewport_height = height;
        self.wrapped_line_count = 0;
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

    /// Create an element and link it into the tree: append it, track it as a
    /// floating root when it floats, and link it to its parent.
    fn createElement(self: *Self, decl: ElementDeclaration, elem_type: ElementType) !u32 {
        std.debug.assert(self.elements.len() < MAX_ELEMENTS_PER_FRAME); // Prevent unbounded growth
        std.debug.assert(elem_type != .container or self.open_element_stack.len < MAX_OPEN_DEPTH); // Depth check for containers

        const parent_index = if (self.open_element_stack.len > 0)
            self.open_element_stack.buffer[self.open_element_stack.len - 1]
        else
            null;

        const index = try self.elements.append(.{
            .config = decl,
            .parent_index = parent_index,
            .element_type = elem_type,
        });

        // Floating elements are positioned after the main layout.
        if (decl.floating != null) {
            self.floating_roots.append(index) catch
                @panic("floating_roots overflow - increase MAX_FLOATING_ROOTS");
        }

        // Link to parent (or set root) and bump the parent's child_count.
        self.linkToParent(index, parent_index);

        return index;
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

    /// End frame and compute every element's bounds. `core/emit.zig` reads
    /// them through `elements` to write the frame's paint records.
    pub fn endFrame(self: *Self) !void {
        const root = self.root_index orelse return;
        std.debug.assert(root < self.elements.len());
        std.debug.assert(self.open_element_stack.len == 0);

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
    }
};
