//! Paint and hit records: what `emit` writes and `pack` and the router read
//! (contract §8 and §6).
//!
//! A `Frame` holds one tick's records in storage reserved at init. The window
//! keeps two: `emit` fills the built frame, and a completed tick swaps it with
//! the rendered frame, which the router and `Query` read until the next swap.
//! Nothing here grows; every append checks its capacity and fails fast with
//! the pool's name, capacity, and the frame number (contract rule 4).

const std = @import("std");
const id_mod = @import("id.zig");
const geometry = @import("../geometry/geometry.zig");
const handler_mod = @import("handler.zig");
const a11y_types = @import("../accessibility/types.zig");

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;
pub const Color = geometry.Color;
pub const Handler = handler_mod.Handler;

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        assert(self.width >= 0);
        assert(self.height >= 0);
        if (x < self.x or y < self.y) return false;
        return x < self.x + self.width and y < self.y + self.height;
    }
};

pub const Corners = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub const zero: Corners = .{};

    pub fn all(radius: f32) Corners {
        assert(radius >= 0);
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_right = radius,
            .bottom_left = radius,
        };
    }
};

/// A resolved border: one width on every edge, in one colour.
pub const Border = struct {
    width: f32 = 0,
    color: Color = Color.transparent,

    pub const none: Border = .{};
};

pub const Record = union(enum) {
    quad: Quad,
    sprite: Sprite,
    mesh: Mesh,
    clip_push: Rect,
    clip_pop,
};

pub const Quad = struct {
    bounds: Rect,
    fill: Color,
    border: Border,
    corners: Corners,
    /// Shadows are blurred quads; `offset` moves the shadow off its box.
    blur: f32,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub const AtlasKind = enum { glyph, glyph_color, svg, image };

pub const Sprite = struct {
    bounds: Rect,
    atlas: AtlasKind,
    /// Normalized atlas coordinates.
    uv: Rect,
    tint: Color,
    /// SVG stroke colour.
    secondary: Color,
    /// Image rounding.
    corners: Corners,
    grayscale: f32,
    opacity: f32,
};

/// A range in the mesh pool. Milestone 1 emits no meshes; `pack` rejects one
/// until the mesh pool moves behind the pack stage (phase 5).
pub const MeshRange = struct { first: u32, count: u32 };

pub const Mesh = struct {
    range: MeshRange,
    topology: enum { triangles, strip_expanded, point_instanced },
    fill: Color,
    width: f32,
};

/// Sentinel for "no handler" and "no parent" indexes.
pub const index_none: u32 = std.math.maxInt(u32);

/// One interactive or keyed box, in tree order. `parent` is the index of the
/// nearest ancestor hit record, so the router can bubble without the tree.
pub const HitRecord = struct {
    id: ElementId,
    bounds: Rect,
    fragment: u8,
    parent: u32,
    focusable: bool,
    on_click: u32,
    on_click_outside: u32,
    on_key: u32,
};

/// One accessibility node. Strings live in the frame's text bytes.
pub const A11yNode = struct {
    id: ElementId,
    role: a11y_types.Role,
    bounds: Rect,
    depth: u8,
    name: TextRange,
    value: TextRange,
    href: TextRange,
    state: a11y_types.State,
    heading_level: a11y_types.HeadingLevel,
    live: a11y_types.Live,
};

/// Screen-reader announcements (`Effects.announce`) in their own bytes, so a
/// handler's slice need not outlive it. The window collects them between
/// builds; each frame carries the ones made since the previous build.
pub const Announcements = struct {
    bytes: [bytes_max]u8,
    bytes_len: u32,
    items: [count_max]Item,
    count: u32,

    /// 0.3.1's bound (`MAX_A11Y_ANNOUNCEMENTS`); screen readers queue or drop
    /// the rest anyway, so more per frame is a programmer error.
    pub const count_max: u32 = 16;
    pub const bytes_max: u32 = 1024;

    pub const Item = struct { text: TextRange, live: a11y_types.Live };

    pub fn clear(self: *Announcements) void {
        self.count = 0;
        self.bytes_len = 0;
    }

    /// Copy `message`; exceeding either pool fails fast with its name.
    pub fn push(self: *Announcements, message: []const u8, live: a11y_types.Live) void {
        assert(live != .off);
        assert(message.len > 0);
        assert(self.count <= count_max);
        if (self.count == count_max or message.len > bytes_max - self.bytes_len) {
            std.debug.panic("announcement pool exhausted: capacity {d} announcements and " ++
                "{d} bytes, {d} and {d} in use, {d} bytes requested", .{
                count_max,
                bytes_max,
                self.count,
                self.bytes_len,
                message.len,
            });
        }
        const range = TextRange{ .offset = self.bytes_len, .len = @intCast(message.len) };
        @memcpy(self.bytes[range.offset..][0..range.len], message);
        self.bytes_len += range.len;
        self.items[self.count] = .{ .text = range, .live = live };
        self.count += 1;
    }

    pub fn slice(self: *const Announcements) []const Item {
        assert(self.count <= count_max);
        return self.items[0..self.count];
    }

    pub fn text(self: *const Announcements, item: Item) []const u8 {
        assert(item.text.len > 0);
        assert(item.text.offset + item.text.len <= self.bytes_len);
        return self.bytes[item.text.offset..][0..item.text.len];
    }
};

/// A byte range in `Frame.text_bytes`. `len == 0` means absent.
pub const TextRange = struct {
    offset: u32 = 0,
    len: u32 = 0,

    pub const empty: TextRange = .{};
};

/// The text-input state the platform's IME asks about synchronously.
pub const Ime = struct {
    owner: ElementId,
    cursor_rect: Rect,
    /// Selected range in the owner's text, in bytes.
    selected_start: u32,
    selected_end: u32,
};

pub const FrameCapacity = struct {
    paint_record_count_max: u32,
    hit_record_count_max: u32,
    handler_count_max: u32,
    a11y_node_count_max: u32,
    text_bytes_max: u32,
};

/// One tick's records. Storage is borrowed from the window's reservation.
pub const Frame = struct {
    paint: []Record,
    paint_count: u32,
    hits: []HitRecord,
    hit_count: u32,
    handlers: []Handler,
    handler_count: u32,
    a11y: []A11yNode,
    a11y_count: u32,
    announcements: Announcements,
    text_bytes: []u8,
    text_len: u32,
    ime: ?Ime,
    /// The tick number that built this frame.
    frame_number: u64,
    viewport_width: f32,
    viewport_height: f32,
    scale_factor: f32,

    pub fn initInPlace(self: *Frame, gpa: std.mem.Allocator, capacity: *const FrameCapacity) !void {
        assert(capacity.paint_record_count_max > 0);
        assert(capacity.hit_record_count_max > 0);
        self.paint = try gpa.alloc(Record, capacity.paint_record_count_max);
        errdefer gpa.free(self.paint);
        self.hits = try gpa.alloc(HitRecord, capacity.hit_record_count_max);
        errdefer gpa.free(self.hits);
        self.handlers = try gpa.alloc(Handler, capacity.handler_count_max);
        errdefer gpa.free(self.handlers);
        self.a11y = try gpa.alloc(A11yNode, capacity.a11y_node_count_max);
        errdefer gpa.free(self.a11y);
        self.text_bytes = try gpa.alloc(u8, capacity.text_bytes_max);
        self.frame_number = 0;
        self.reset(0, .{ .width = 0, .height = 0, .scale_factor = 1 });
        assert(self.paint_count == 0);
    }

    pub fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        assert(self.paint_count <= self.paint.len);
        gpa.free(self.text_bytes);
        gpa.free(self.a11y);
        gpa.free(self.handlers);
        gpa.free(self.hits);
        gpa.free(self.paint);
        self.* = undefined;
    }

    pub const Viewport = struct { width: f32, height: f32, scale_factor: f32 };

    /// Empty the frame for tick `frame_number`. The previous owner's bytes
    /// stay in place but are unreachable: every reader bounds by the counts.
    pub fn reset(self: *Frame, frame_number: u64, viewport: Viewport) void {
        assert(viewport.scale_factor > 0);
        assert(frame_number >= self.frame_number);
        self.paint_count = 0;
        self.hit_count = 0;
        self.handler_count = 0;
        self.a11y_count = 0;
        self.announcements.clear();
        self.text_len = 0;
        self.ime = null;
        self.frame_number = frame_number;
        self.viewport_width = viewport.width;
        self.viewport_height = viewport.height;
        self.scale_factor = viewport.scale_factor;
    }

    pub fn appendPaint(self: *Frame, record: Record) void {
        assert(self.paint_count <= self.paint.len);
        if (self.paint_count == self.paint.len) {
            self.exhausted("paint records", self.paint.len);
        }
        self.paint[self.paint_count] = record;
        self.paint_count += 1;
    }

    pub fn appendHit(self: *Frame, record: HitRecord) u32 {
        assert(self.hit_count <= self.hits.len);
        assert(record.bounds.width >= 0);
        if (self.hit_count == self.hits.len) self.exhausted("hit records", self.hits.len);
        const index = self.hit_count;
        self.hits[index] = record;
        self.hit_count += 1;
        return index;
    }

    pub fn appendHandler(self: *Frame, handler: Handler) u32 {
        assert(self.handler_count <= self.handlers.len);
        if (self.handler_count == self.handlers.len) {
            self.exhausted("handlers", self.handlers.len);
        }
        const index = self.handler_count;
        self.handlers[index] = handler;
        self.handler_count += 1;
        return index;
    }

    pub fn appendA11y(self: *Frame, node: A11yNode) void {
        assert(self.a11y_count <= self.a11y.len);
        if (self.a11y_count == self.a11y.len) self.exhausted("a11y nodes", self.a11y.len);
        self.a11y[self.a11y_count] = node;
        self.a11y_count += 1;
    }

    /// Copy `bytes` into the frame (contract rule 6) and return their range.
    pub fn copyText(self: *Frame, bytes: []const u8) TextRange {
        assert(self.text_len <= self.text_bytes.len);
        if (bytes.len == 0) return .empty;
        if (bytes.len > self.text_bytes.len - self.text_len) {
            std.debug.panic("record frame pool 'text bytes' exhausted: capacity {d} bytes, " ++
                "{d} in use, {d} requested, frame {d}", .{
                self.text_bytes.len,
                self.text_len,
                bytes.len,
                self.frame_number,
            });
        }
        const range = TextRange{ .offset = self.text_len, .len = @intCast(bytes.len) };
        @memcpy(self.text_bytes[self.text_len..][0..bytes.len], bytes);
        self.text_len += range.len;
        return range;
    }

    pub fn text(self: *const Frame, range: TextRange) ?[]const u8 {
        if (range.len == 0) return null;
        assert(range.offset + range.len <= self.text_len);
        return self.text_bytes[range.offset..][0..range.len];
    }

    pub fn handlerAt(self: *const Frame, index: u32) ?Handler {
        if (index == index_none) return null;
        assert(index < self.handler_count);
        return self.handlers[index];
    }

    fn exhausted(self: *const Frame, pool: []const u8, capacity: usize) noreturn {
        std.debug.panic("record frame pool '{s}' exhausted: capacity {d}, {d} in use, " ++
            "1 requested, frame {d}. Raise the app's ResourceLimits.records.", .{
            pool,
            capacity,
            capacity,
            self.frame_number,
        });
    }
};

test "Frame copies text and bounds every pool" {
    // Goal: text survives the caller's buffer and each pool counts. Method:
    // copy from a stack buffer, overwrite it, and read the copy back.
    var frame: Frame = undefined;
    try frame.initInPlace(std.testing.allocator, &.{
        .paint_record_count_max = 2,
        .hit_record_count_max = 2,
        .handler_count_max = 2,
        .a11y_node_count_max = 2,
        .text_bytes_max = 8,
    });
    defer frame.deinit(std.testing.allocator);
    var source = "label".*;
    const range = frame.copyText(&source);
    source[0] = 'X';
    try std.testing.expectEqualStrings("label", frame.text(range).?);
    try std.testing.expectEqual(@as(?[]const u8, null), frame.text(frame.copyText("")));
    frame.appendPaint(.clip_pop);
    frame.appendPaint(.clip_pop);
    try std.testing.expectEqual(@as(u32, 2), frame.paint_count);
    frame.reset(1, .{ .width = 10, .height = 10, .scale_factor = 2 });
    try std.testing.expectEqual(@as(u32, 0), frame.paint_count);
    try std.testing.expectEqual(@as(u32, 0), frame.text_len);
}
