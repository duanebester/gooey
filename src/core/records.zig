const std = @import("std");
const id_mod = @import("id.zig");
const geometry = @import("../geometry/geometry.zig");
const handler_mod = @import("handler.zig");
const a11y_types = @import("../accessibility/types.zig");
const TextSelection = @import("../accessibility/element.zig").TextSelection;
const CursorShape = @import("../platform/interface.zig").CursorShape;
const debugger = @import("debugger.zig");

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

    pub fn overlaps(self: Rect, other: Rect) bool {
        assert(self.width >= 0);
        assert(other.width >= 0);
        if (self.x + self.width <= other.x or other.x + other.width <= self.x) return false;
        return self.y + self.height > other.y and other.y + other.height > self.y;
    }

    pub fn intersect(self: Rect, other: Rect) Rect {
        assert(self.width >= 0);
        assert(other.width >= 0);
        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right = @min(self.x + self.width, other.x + other.width);
        const bottom = @min(self.y + self.height, other.y + other.height);
        if (right <= left or bottom <= top) {
            return .{ .x = self.x, .y = self.y, .width = 0, .height = 0 };
        }
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
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
    blur: f32,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub const AtlasKind = enum { glyph, glyph_color, svg, image };

pub const Sprite = struct {
    bounds: Rect,
    atlas: AtlasKind,
    uv: Rect,
    tint: Color,
    secondary: Color,
    corners: Corners,
    grayscale: f32,
    opacity: f32,
};

pub const MeshRange = struct { first: u32, count: u32 };

pub const MeshPoint = geometry.GpuPoint;

pub const Mesh = struct {
    range: MeshRange,
    topology: Topology,
    fill: Color,
    width: f32,

    pub const Topology = enum { triangles, strip_expanded, point_instanced };
};

pub fn fade(record: Record, opacity: f32) Record {
    assert(opacity >= 0);
    assert(opacity <= 1);
    if (opacity == 1) return record;
    var faded = record;
    switch (faded) {
        .quad => |*quad| {
            quad.fill = fadeColor(quad.fill, opacity);
            quad.border.color = fadeColor(quad.border.color, opacity);
        },
        .sprite => |*sprite| switch (sprite.atlas) {
            .image => sprite.opacity *= opacity,
            .glyph, .glyph_color, .svg => {
                sprite.tint = fadeColor(sprite.tint, opacity);
                sprite.secondary = fadeColor(sprite.secondary, opacity);
            },
        },
        .mesh => |*mesh| mesh.fill = fadeColor(mesh.fill, opacity),
        .clip_push, .clip_pop => {},
    }
    return faded;
}

pub fn fadeColor(color: Color, opacity: f32) Color {
    assert(opacity >= 0);
    assert(opacity <= 1);
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * opacity };
}

pub const index_none: u32 = std.math.maxInt(u32);

pub const HitRecord = struct {
    id: ElementId,
    bounds: Rect,
    fragment: u8,
    parent: u32,
    pointer: bool,
    focusable: bool,
    tab_stop: bool,
    scroll: bool,
    cursor: ?CursorShape,
    on_click: u32,
    on_click_outside: u32,
    on_context_menu: u32,
    on_key: u32,
    on_pointer_drag: u32,
    drag_type: usize,
    drag_payload: u64,
    drop_type: usize,
    on_drop: u32,
    key_context: u64,
    actions_start: u32,
    actions_len: u32,
};

pub const A11yNode = struct {
    id: ElementId,
    role: a11y_types.Role,
    bounds: Rect,
    depth: u8,
    name: TextRange,
    value: TextRange,
    href: TextRange,
    description: TextRange,
    state: a11y_types.State,
    heading_level: a11y_types.HeadingLevel,
    live: a11y_types.Live,
    pos_in_set: ?u16,
    set_size: ?u16,
    range: ?Range,
    selection: ?TextSelection,

    pub const Range = struct {
        min: f32,
        max: f32,
        now: f32,
        orientation: a11y_types.Orientation,
    };
};

pub const Announcements = struct {
    bytes: []u8,
    items: []Item,
    count: u32,
    polite_pending_max: u32,
    message_bytes_max: u32,

    pub const Item = struct { text: TextRange, live: a11y_types.Live };

    pub const Capacity = struct {
        polite_pending_max: u32,
        message_bytes_max: u32,

        fn slotCount(self: Capacity) u32 {
            assert(self.polite_pending_max > 0);
            return self.polite_pending_max + 1;
        }
    };

    pub fn initInPlace(
        self: *Announcements,
        gpa: std.mem.Allocator,
        capacity: Capacity,
    ) !void {
        assert(capacity.polite_pending_max > 0);
        assert(capacity.message_bytes_max > 0);
        const slot_count = capacity.slotCount();

        self.items = try gpa.alloc(Item, slot_count);
        errdefer gpa.free(self.items);

        self.bytes = try gpa.alloc(u8, slot_count * capacity.message_bytes_max);
        self.polite_pending_max = capacity.polite_pending_max;
        self.message_bytes_max = capacity.message_bytes_max;
        self.count = 0;
        assert(self.items.len == slot_count);
        assert(self.bytes.len == self.items.len * self.message_bytes_max);
    }

    pub fn deinit(self: *Announcements, gpa: std.mem.Allocator) void {
        assert(self.count <= self.items.len);
        self.clear();
        gpa.free(self.bytes);
        gpa.free(self.items);
        self.* = undefined;
    }

    pub fn clear(self: *Announcements) void {
        assert(self.count <= self.items.len);
        @memset(self.bytes[0 .. self.count * self.message_bytes_max], 0);
        self.count = 0;
    }

    pub fn push(
        self: *Announcements,
        message: []const u8,
        live: a11y_types.Live,
        frame_number: u64,
    ) void {
        assert(live != .off);
        assert(message.len > 0);
        self.assertInvariants();
        if (message.len > self.message_bytes_max) {
            std.debug.panic("a11y announcement of {d} bytes is longer than its slot: " ++
                "capacity {d} bytes, frame {d}. Raise ResourceLimits.a11y." ++
                "announcement_message_bytes_max.", .{
                message.len,
                self.message_bytes_max,
                frame_number,
            });
        }
        if (live == .assertive) {
            if (self.find(.assertive, 0)) |index| self.remove(index);
        } else {
            if (self.countOf(.polite) == self.polite_pending_max) {
                self.remove(self.find(.polite, 0).?);
            }
        }
        assert(self.count < self.items.len);
        const slot = self.slotOf(self.count);
        @memcpy(slot[0..message.len], message);
        @memset(slot[message.len..], 0);
        const offset = self.count * self.message_bytes_max;
        self.items[self.count] = .{
            .text = .{ .offset = offset, .len = @intCast(message.len) },
            .live = live,
        };
        self.count += 1;
        self.assertInvariants();
    }

    pub fn copyFrom(self: *Announcements, source: *const Announcements) void {
        assert(self.count == 0);
        assert(self.items.len == source.items.len);
        assert(self.message_bytes_max == source.message_bytes_max);
        source.assertInvariants();
        const used_bytes = source.count * source.message_bytes_max;
        @memcpy(self.items[0..source.count], source.items[0..source.count]);
        @memcpy(self.bytes[0..used_bytes], source.bytes[0..used_bytes]);
        self.count = source.count;
        self.assertInvariants();
    }

    pub fn slice(self: *const Announcements) []const Item {
        assert(self.count <= self.items.len);
        return self.items[0..self.count];
    }

    pub fn text(self: *const Announcements, item: Item) []const u8 {
        assert(item.text.len > 0);
        assert(item.text.len <= self.message_bytes_max);
        assert(item.text.offset % self.message_bytes_max == 0);
        assert(item.text.offset < self.count * self.message_bytes_max);
        return self.bytes[item.text.offset..][0..item.text.len];
    }

    fn remove(self: *Announcements, index: u32) void {
        assert(index < self.count);
        assert(self.count <= self.items.len);
        const slot_bytes = self.message_bytes_max;
        const tail_start = (index + 1) * slot_bytes;
        const tail_end = self.count * slot_bytes;
        std.mem.copyForwards(
            u8,
            self.bytes[index * slot_bytes .. tail_end - slot_bytes],
            self.bytes[tail_start..tail_end],
        );
        @memset(self.bytes[tail_end - slot_bytes .. tail_end], 0);
        var moved = index;
        while (moved + 1 < self.count) : (moved += 1) {
            self.items[moved] = self.items[moved + 1];
            self.items[moved].text.offset = moved * slot_bytes;
        }
        self.count -= 1;
        assert(moved == self.count);
    }

    fn find(self: *const Announcements, live: a11y_types.Live, start: u32) ?u32 {
        assert(start <= self.count);
        var index = start;
        while (index < self.count) : (index += 1) {
            if (self.items[index].live == live) return index;
        }
        return null;
    }

    fn countOf(self: *const Announcements, live: a11y_types.Live) u32 {
        assert(self.count <= self.items.len);
        var count: u32 = 0;
        for (self.items[0..self.count]) |item| {
            if (item.live == live) count += 1;
        }
        return count;
    }

    fn slotOf(self: *Announcements, index: u32) []u8 {
        assert(index < self.items.len);
        return self.bytes[index * self.message_bytes_max ..][0..self.message_bytes_max];
    }

    fn assertInvariants(self: *const Announcements) void {
        assert(self.count <= self.items.len);
        assert(self.items.len == self.polite_pending_max + 1);
        assert(self.bytes.len == self.items.len * self.message_bytes_max);
        assert(self.countOf(.assertive) <= 1);
        assert(self.countOf(.polite) <= self.polite_pending_max);
        assert(self.countOf(.off) == 0);
    }
};

pub const TextRange = struct {
    offset: u32 = 0,
    len: u32 = 0,

    pub const empty: TextRange = .{};
};

pub const Ime = struct {
    owner: ElementId,
    cursor_rect: Rect,
    selected_start: u32,
    selected_end: u32,
};

pub const FrameCapacity = struct {
    paint_record_count_max: u32,
    hit_record_count_max: u32,
    handler_count_max: u32,
    a11y_node_count_max: u32,
    announcements: Announcements.Capacity,
    text_bytes_max: u32,
    mesh_point_count_max: u32,
};

pub const Frame = struct {
    paint: []Record,
    paint_count: u32,
    hits: []HitRecord,
    hit_count: u32,
    handlers: []Handler,
    action_ids: []u64,
    handler_count: u32,
    a11y: []A11yNode,
    a11y_count: u32,
    announcements: Announcements,
    text_bytes: []u8,
    text_len: u32,
    mesh_points: []MeshPoint,
    mesh_point_count: u32,
    mesh_point_counts: [3]u32,
    triangle_mesh_count: u32,
    ime: ?Ime,
    paint_opacity: f32,
    modal_hit_start: u32,
    overlay_start: debugger.PaintMark,
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
        self.action_ids = try gpa.alloc(u64, capacity.handler_count_max);
        errdefer gpa.free(self.action_ids);
        self.a11y = try gpa.alloc(A11yNode, capacity.a11y_node_count_max);
        errdefer gpa.free(self.a11y);
        try self.announcements.initInPlace(gpa, capacity.announcements);
        errdefer self.announcements.deinit(gpa);
        self.text_bytes = try gpa.alloc(u8, capacity.text_bytes_max);
        errdefer gpa.free(self.text_bytes);
        self.mesh_points = try gpa.alloc(MeshPoint, capacity.mesh_point_count_max);
        self.frame_number = 0;
        self.reset(0, .{ .width = 0, .height = 0, .scale_factor = 1 });
        assert(self.paint_count == 0);
    }

    pub fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        assert(self.paint_count <= self.paint.len);
        gpa.free(self.mesh_points);
        gpa.free(self.text_bytes);
        self.announcements.deinit(gpa);
        gpa.free(self.a11y);
        gpa.free(self.action_ids);
        gpa.free(self.handlers);
        gpa.free(self.hits);
        gpa.free(self.paint);
        self.* = undefined;
    }

    pub const Viewport = struct { width: f32, height: f32, scale_factor: f32 };

    pub fn reset(self: *Frame, frame_number: u64, viewport: Viewport) void {
        assert(viewport.scale_factor > 0);
        assert(frame_number >= self.frame_number);
        self.paint_count = 0;
        self.hit_count = 0;
        self.handler_count = 0;
        self.a11y_count = 0;
        self.announcements.clear();
        self.text_len = 0;
        self.mesh_point_count = 0;
        self.mesh_point_counts = @splat(0);
        self.triangle_mesh_count = 0;
        self.ime = null;
        self.modal_hit_start = 0;
        self.paint_opacity = 1;
        self.overlay_start = debugger.paint_mark_none;
        self.frame_number = frame_number;
        self.viewport_width = viewport.width;
        self.viewport_height = viewport.height;
        self.scale_factor = viewport.scale_factor;
    }

    pub fn appendPaint(self: *Frame, record: Record) void {
        assert(self.paint_count <= self.paint.len);
        assert(self.paint_opacity >= 0);
        assert(self.paint_opacity <= 1);
        if (self.paint_count == self.paint.len) {
            self.exhausted("paint records", self.paint.len);
        }
        self.paint[self.paint_count] = fade(record, self.paint_opacity);
        self.paint_count += 1;
    }

    pub fn appendHit(self: *Frame, record: HitRecord) u32 {
        assert(self.hit_count <= self.hits.len);
        assert(record.bounds.width >= 0);
        if (record.tab_stop) assert(record.focusable);
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

    pub fn appendAction(self: *Frame, action: u64, handler: Handler) u32 {
        assert(action != 0);
        const index = self.appendHandler(handler);
        self.action_ids[index] = action;
        return index;
    }

    pub fn actionHandler(self: *const Frame, record: *const HitRecord, action: u64) ?Handler {
        assert(record.actions_start + record.actions_len <= self.handler_count);
        const start = record.actions_start;
        for (self.action_ids[start..][0..record.actions_len], start..) |id, index| {
            if (id == action) return self.handlers[index];
        }
        return null;
    }

    pub fn appendA11y(self: *Frame, node: A11yNode) void {
        assert(self.a11y_count <= self.a11y.len);
        if (self.a11y_count == self.a11y.len) {
            std.debug.panic("a11y pool 'elements' exhausted: capacity {d}, {d} in use, " ++
                "1 requested, frame {d}. Raise ResourceLimits.a11y.element_count_max.", .{
                self.a11y.len,
                self.a11y_count,
                self.frame_number,
            });
        }
        self.a11y[self.a11y_count] = node;
        self.a11y_count += 1;
    }

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

    pub fn claimMeshPoints(self: *Frame, count: u32) MeshRange {
        assert(count > 0);
        assert(self.mesh_point_count <= self.mesh_points.len);
        if (count > self.mesh_points.len - self.mesh_point_count) {
            std.debug.panic("record frame pool 'mesh points' exhausted: capacity {d}, " ++
                "{d} in use, {d} requested, frame {d}. Raise the app's ResourceLimits.paint " ++
                "geometry counts.", .{
                self.mesh_points.len,
                self.mesh_point_count,
                count,
                self.frame_number,
            });
        }
        const range = MeshRange{ .first = self.mesh_point_count, .count = count };
        self.mesh_point_count += count;
        return range;
    }

    pub fn meshPoints(self: *const Frame, range: MeshRange) []MeshPoint {
        assert(range.count > 0);
        assert(range.first + range.count <= self.mesh_point_count);
        return self.mesh_points[range.first..][0..range.count];
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
    var frame: Frame = undefined;
    try frame.initInPlace(std.testing.allocator, &.{
        .paint_record_count_max = 2,
        .hit_record_count_max = 2,
        .handler_count_max = 2,
        .a11y_node_count_max = 2,
        .announcements = .{ .polite_pending_max = 1, .message_bytes_max = 8 },
        .text_bytes_max = 8,
        .mesh_point_count_max = 0,
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

test "fade halves an image sprite's opacity and a glyph or SVG sprite's colours" {
    const sprite = Sprite{
        .bounds = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .atlas = .image,
        .uv = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .tint = Color.white,
        .secondary = .{ .r = 0, .g = 0, .b = 0, .a = 0.8 },
        .corners = .zero,
        .grayscale = 0,
        .opacity = 0.6,
    };
    const image = fade(.{ .sprite = sprite }, 0.5).sprite;
    try std.testing.expectEqual(@as(f32, 0.3), image.opacity);
    try std.testing.expectEqual(@as(f32, 1), image.tint.a);
    var svg = sprite;
    svg.atlas = .svg;
    svg.opacity = 1;
    const faded = fade(.{ .sprite = svg }, 0.5).sprite;
    try std.testing.expectEqual(@as(f32, 1), faded.opacity);
    try std.testing.expectEqual(@as(f32, 0.5), faded.tint.a);
    try std.testing.expectEqual(@as(f32, 0.4), faded.secondary.a);
}

fn pendingTexts(pending: *const Announcements, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (pending.slice(), 0..) |item, index| {
        const separator: []const u8 = if (index == 0) "" else "|";
        const piece = pending.text(item);
        assert(len + separator.len + piece.len <= buffer.len);
        @memcpy(buffer[len..][0..separator.len], separator);
        len += separator.len;
        @memcpy(buffer[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buffer[0..len];
}

test "polite announcements fill to their count, then the newest replaces the oldest" {
    var pending: Announcements = undefined;
    try pending.initInPlace(std.testing.allocator, .{
        .polite_pending_max = 3,
        .message_bytes_max = 8,
    });
    defer pending.deinit(std.testing.allocator);
    var buffer: [64]u8 = undefined;

    for ([_][]const u8{ "a", "b", "c" }) |message| pending.push(message, .polite, 1);
    try std.testing.expectEqual(@as(u32, 3), pending.count);
    try std.testing.expectEqualStrings("a|b|c", pendingTexts(&pending, &buffer));
    pending.push("d", .polite, 1);
    try std.testing.expectEqualStrings("b|c|d", pendingTexts(&pending, &buffer));
    pending.push("e", .polite, 1);
    try std.testing.expectEqualStrings("c|d|e", pendingTexts(&pending, &buffer));
    try std.testing.expectEqual(@as(u32, 3), pending.count);
}

test "a newer assertive announcement replaces the pending one and goes after the survivors" {
    var pending: Announcements = undefined;
    try pending.initInPlace(std.testing.allocator, .{
        .polite_pending_max = 2,
        .message_bytes_max = 8,
    });
    defer pending.deinit(std.testing.allocator);
    var buffer: [64]u8 = undefined;

    pending.push("p1", .polite, 1);
    pending.push("A1", .assertive, 1);
    pending.push("p2", .polite, 1);
    try std.testing.expectEqualStrings("p1|A1|p2", pendingTexts(&pending, &buffer));
    pending.push("A2", .assertive, 1);
    try std.testing.expectEqualStrings("p1|p2|A2", pendingTexts(&pending, &buffer));
    pending.push("p3", .polite, 1);
    try std.testing.expectEqualStrings("p2|A2|p3", pendingTexts(&pending, &buffer));
    try std.testing.expectEqual(Announcements.Item{
        .text = .{ .offset = 8, .len = 2 },
        .live = .assertive,
    }, pending.slice()[1]);

    var frame_pending: Announcements = undefined;
    try frame_pending.initInPlace(std.testing.allocator, .{
        .polite_pending_max = 2,
        .message_bytes_max = 8,
    });
    defer frame_pending.deinit(std.testing.allocator);
    frame_pending.copyFrom(&pending);
    pending.clear();
    try std.testing.expectEqualStrings("p2|A2|p3", pendingTexts(&frame_pending, &buffer));
    try std.testing.expectEqual(@as(u32, 0), pending.count);
}

test "replaced announcements reuse their slots and leave no stale bytes" {
    var pending: Announcements = undefined;
    try pending.initInPlace(std.testing.allocator, .{
        .polite_pending_max = 2,
        .message_bytes_max = 16,
    });
    defer pending.deinit(std.testing.allocator);
    const source = "abcdefghijklmnop";
    var round: u32 = 0;
    while (round < 1_000) : (round += 1) {
        const len = 16 - round % 16;
        const live: a11y_types.Live = if (round % 3 == 0) .assertive else .polite;
        pending.push(source[0..len], live, round);
        assert(pending.count <= 3);
        for (pending.slice(), 0..) |item, index| {
            const slot = pending.bytes[index * 16 ..][0..16];
            try std.testing.expectEqual(@as(u32, @intCast(index * 16)), item.text.offset);
            try std.testing.expectEqualStrings(source[0..item.text.len], slot[0..item.text.len]);
            try std.testing.expect(std.mem.allEqual(u8, slot[item.text.len..], 0));
        }
        if (round >= 3) {
            const unused = pending.bytes[pending.count * 16 ..];
            try std.testing.expect(std.mem.allEqual(u8, unused, 0));
        }
        if (round == 500) {
            pending.clear();
            try std.testing.expect(std.mem.allEqual(u8, pending.bytes, 0));
        }
    }
    try std.testing.expectEqual(@as(u32, 3), pending.count);
    pending.clear();
    try std.testing.expect(std.mem.allEqual(u8, pending.bytes, 0));
}
