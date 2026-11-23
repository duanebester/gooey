const std = @import("std");
const backend = @import("../core/backend.zig");
const packed_mod = @import("../core/packed_frame.zig");

const assert = std.debug.assert;

pub fn clipRect(
    clip: packed_mod.Rect,
    scale_x: f32,
    scale_y: f32,
    size_px: backend.SizePx,
) ?backend.RectPx {
    assert(scale_x > 0);
    assert(scale_y > 0);
    const columns = centreSpan(clip[0], clip[2], scale_x, size_px.width) orelse return null;
    const rows = centreSpan(clip[1], clip[3], scale_y, size_px.height) orelse return null;
    const rect = backend.RectPx{
        .x = columns.first,
        .y = rows.first,
        .width = columns.count,
        .height = rows.count,
    };
    assert(rect.x + rect.width <= size_px.width);
    assert(rect.y + rect.height <= size_px.height);
    return rect;
}

const Span = struct { first: u32, count: u32 };

fn centreSpan(start: f32, size: f32, scale: f32, limit: u32) ?Span {
    assert(!std.math.isNan(start));
    assert(size >= 0);
    assert(scale > 0);
    const limit_f: f32 = @floatFromInt(limit);
    const first = std.math.clamp(@ceil(start * scale - 0.5), 0, limit_f);
    const end = std.math.clamp(@floor((start + size) * scale - 0.5) + 1, 0, limit_f);
    if (end <= first) return null;
    const span = Span{ .first = @intFromFloat(first), .count = @intFromFloat(end - first) };
    assert(span.count > 0);
    assert(span.first + span.count <= limit);
    return span;
}

test "centreSpan keeps exactly the pixels whose centres lie in the clip" {
    try std.testing.expectEqual(Span{ .first = 2, .count = 3 }, centreSpan(2, 3, 1, 100).?);
    try std.testing.expectEqual(Span{ .first = 2, .count = 3 }, centreSpan(2.5, 2, 1, 100).?);
    try std.testing.expectEqual(Span{ .first = 3, .count = 1 }, centreSpan(2.51, 1.98, 1, 100).?);
    try std.testing.expectEqual(null, centreSpan(2.6, 0.3, 1, 100));
    try std.testing.expectEqual(null, centreSpan(3, 0, 1, 100));
    try std.testing.expectEqual(Span{ .first = 1, .count = 4 }, centreSpan(1, 2, 1.5, 100).?);
    const unbounded = packed_mod.clip_unbounded;
    try std.testing.expectEqual(
        Span{ .first = 0, .count = 640 },
        centreSpan(unbounded[0], unbounded[2], 2, 640).?,
    );
    try std.testing.expectEqual(null, centreSpan(700, 10, 1, 640));
    try std.testing.expectEqual(null, centreSpan(-20, 10, 1, 640));
}

test "clipRect is null when either axis keeps no pixel centre" {
    const size_px = backend.SizePx{ .width = 200, .height = 100 };
    try std.testing.expectEqual(null, clipRect(.{ 10, 120, 50, 10 }, 1, 1, size_px));
    try std.testing.expectEqual(
        backend.RectPx{ .x = 20, .y = 15, .width = 100, .height = 30 },
        clipRect(.{ 10, 10, 50, 20 }, 2, 1.5, size_px).?,
    );
}
