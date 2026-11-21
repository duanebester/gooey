const std = @import("std");
const builtin = @import("builtin");
const limits = @import("../core/limits.zig");
const vec2_mod = @import("vec2.zig");
const fixed_array_mod = @import("../core/fixed_array.zig");

const Vec2 = vec2_mod.Vec2;
const FixedArray = fixed_array_mod.FixedArray;

pub const MAX_STROKE_INPUT = limits.MAX_STROKE_INPUT;
pub const MAX_STROKE_OUTPUT = limits.MAX_STROKE_OUTPUT;
pub const ROUND_SEGMENTS = limits.ROUND_SEGMENTS;

pub const LineCap = enum(u8) {
    butt,
    round,
    square,
};

pub const LineJoin = enum(u8) {
    miter,
    round,
    bevel,
};

pub const StrokeStyle = struct {
    width: f32 = 1.0,
    cap: LineCap = .butt,
    join: LineJoin = .miter,
    miter_limit: f32 = 4.0,
};

pub const ExpandedStroke = struct {
    /// Outline polygon of the stroke, CCW winding.
    points: FixedArray(Vec2, MAX_STROKE_OUTPUT),
    closed: bool,
};

pub const MAX_STROKE_TRIANGLES = limits.MAX_STROKE_TRIANGLES;
pub const MAX_STROKE_INDICES = limits.MAX_STROKE_INDICES;

pub const StrokeTriangles = struct {
    vertices: FixedArray(Vec2, MAX_STROKE_OUTPUT),
    indices: FixedArray(u32, MAX_STROKE_INDICES),
};

pub const StrokeError = error{
    TooManyInputPoints,
    TooManyOutputPoints,
    DegeneratePath,
};

/// Expands a polyline into a thick outline polygon: start cap, left offsets
/// forward, end cap, right offsets reversed — one continuous polygon for
/// triangulation.
pub fn expandStroke(
    points: []const Vec2,
    width: f32,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f32,
    closed: bool,
) StrokeError!ExpandedStroke {
    std.debug.assert(width > 0);
    std.debug.assert(miter_limit > 0);

    if (points.len > MAX_STROKE_INPUT) return error.TooManyInputPoints;
    if (points.len < 2) return error.DegeneratePath;

    const half_width = width * 0.5;
    const n = points.len;

    var result = ExpandedStroke{
        .points = .{},
        .closed = closed,
    };

    if (n == 2) {
        return expandSingleSegment(points[0], points[1], half_width, cap, closed);
    }

    var left_offsets: FixedArray(Vec2, MAX_STROKE_OUTPUT / 2) = .{};
    var right_offsets: FixedArray(Vec2, MAX_STROKE_OUTPUT / 2) = .{};

    try generateOffsetPoints(
        points,
        half_width,
        join,
        miter_limit,
        closed,
        &left_offsets,
        &right_offsets,
    );

    if (!closed) {
        try addStartCap(&result.points, points[0], points[1], half_width, cap);
    }

    for (left_offsets.constSlice()) |pt| {
        try appendPoint(&result.points, pt);
    }

    if (!closed) {
        try addEndCap(&result.points, points[n - 2], points[n - 1], half_width, cap);
    }
    // Closed paths get no end cap; the polygon closes naturally, but this can
    // leave a small visual gap at the closure (the ear-clipper handles the
    // resulting concave ring). Generating triangles directly as a quad-strip
    // would fix it.

    var i: usize = right_offsets.len;
    while (i > 0) {
        i -= 1;
        try appendPoint(&result.points, right_offsets.get(i));
    }

    return result;
}

/// Expands stroke directly to triangles, bypassing the ear-clipper: more
/// reliable for closed paths, which create concave ring polygons.
pub fn expandStrokeToTriangles(
    points: []const Vec2,
    width: f32,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f32,
    closed: bool,
) StrokeError!StrokeTriangles {
    std.debug.assert(width > 0);
    std.debug.assert(miter_limit > 0);

    if (points.len > MAX_STROKE_INPUT) return error.TooManyInputPoints;
    if (points.len < 2) return error.DegeneratePath;

    const half_width = width * 0.5;
    const n = points.len;

    var result = StrokeTriangles{
        .vertices = .{},
        .indices = .{},
    };

    if (n == 2) {
        return expandSingleSegmentToTriangles(points[0], points[1], half_width, cap);
    }

    var left_offsets: FixedArray(Vec2, MAX_STROKE_OUTPUT / 2) = .{};
    var right_offsets: FixedArray(Vec2, MAX_STROKE_OUTPUT / 2) = .{};

    try generateOffsetPoints(
        points,
        half_width,
        join,
        miter_limit,
        closed,
        &left_offsets,
        &right_offsets,
    );

    const left_start: u32 = 0;
    for (left_offsets.constSlice()) |pt| {
        if (result.vertices.len >= MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
        result.vertices.appendAssumeCapacity(pt);
    }
    const right_start: u32 = @intCast(result.vertices.len);
    for (right_offsets.constSlice()) |pt| {
        if (result.vertices.len >= MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
        result.vertices.appendAssumeCapacity(pt);
    }

    const num_offsets: u32 = @intCast(left_offsets.len);

    const seg_count: u32 = if (closed) num_offsets else num_offsets - 1;
    for (0..seg_count) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const next_i: u32 = if (i + 1 >= num_offsets) 0 else i + 1;

        const l0 = left_start + i;
        const l1 = left_start + next_i;
        const r0 = right_start + i;
        const r1 = right_start + next_i;

        if (result.indices.len + 6 > MAX_STROKE_INDICES) return error.TooManyOutputPoints;
        result.indices.appendAssumeCapacity(l0);
        result.indices.appendAssumeCapacity(l1);
        result.indices.appendAssumeCapacity(r1);

        result.indices.appendAssumeCapacity(l0);
        result.indices.appendAssumeCapacity(r1);
        result.indices.appendAssumeCapacity(r0);
    }

    if (!closed) {
        try addCapTriangles(&result, points[0], points[1], half_width, cap, true, left_start, right_start);
        try addCapTriangles(&result, points[n - 2], points[n - 1], half_width, cap, false, left_start + num_offsets - 1, right_start + num_offsets - 1);
    }

    return result;
}

fn expandSingleSegmentToTriangles(
    p0: Vec2,
    p1: Vec2,
    half_width: f32,
    cap: LineCap,
) StrokeError!StrokeTriangles {
    std.debug.assert(half_width > 0);

    var result = StrokeTriangles{
        .vertices = .{},
        .indices = .{},
    };

    const dir = p1.sub(p0).normalize();
    const normal = dir.perp();
    const offset = normal.scale(half_width);

    const left0 = p0.add(offset);
    const left1 = p1.add(offset);
    const right0 = p0.sub(offset);
    const right1 = p1.sub(offset);

    switch (cap) {
        .butt => {
            result.vertices.appendAssumeCapacity(left0);
            result.vertices.appendAssumeCapacity(left1);
            result.vertices.appendAssumeCapacity(right1);
            result.vertices.appendAssumeCapacity(right0);

            result.indices.appendAssumeCapacity(0);
            result.indices.appendAssumeCapacity(1);
            result.indices.appendAssumeCapacity(2);
            result.indices.appendAssumeCapacity(0);
            result.indices.appendAssumeCapacity(2);
            result.indices.appendAssumeCapacity(3);
        },
        .square => {
            const back = dir.scale(-half_width);
            const fwd = dir.scale(half_width);

            result.vertices.appendAssumeCapacity(left0.add(back));
            result.vertices.appendAssumeCapacity(left1.add(fwd));
            result.vertices.appendAssumeCapacity(right1.add(fwd));
            result.vertices.appendAssumeCapacity(right0.add(back));

            result.indices.appendAssumeCapacity(0);
            result.indices.appendAssumeCapacity(1);
            result.indices.appendAssumeCapacity(2);
            result.indices.appendAssumeCapacity(0);
            result.indices.appendAssumeCapacity(2);
            result.indices.appendAssumeCapacity(3);
        },
        .round => {
            const base_idx: u32 = @intCast(result.vertices.len);

            result.vertices.appendAssumeCapacity(left0);
            result.vertices.appendAssumeCapacity(left1);
            result.vertices.appendAssumeCapacity(right1);
            result.vertices.appendAssumeCapacity(right0);

            result.indices.appendAssumeCapacity(base_idx + 0);
            result.indices.appendAssumeCapacity(base_idx + 1);
            result.indices.appendAssumeCapacity(base_idx + 2);
            result.indices.appendAssumeCapacity(base_idx + 0);
            result.indices.appendAssumeCapacity(base_idx + 2);
            result.indices.appendAssumeCapacity(base_idx + 3);

            try addSemicircleTriangles(&result, p0, offset, dir.negate());
            try addSemicircleTriangles(&result, p1, offset.negate(), dir);
        },
    }

    return result;
}

fn addCapTriangles(
    result: *StrokeTriangles,
    p0: Vec2,
    p1: Vec2,
    half_width: f32,
    cap: LineCap,
    is_start: bool,
    left_idx: u32,
    right_idx: u32,
) StrokeError!void {
    switch (cap) {
        .butt => {},
        .square => {
            const dir = p1.sub(p0).normalize();
            const normal = dir.perp();
            const offset = normal.scale(half_width);
            const ext = if (is_start) dir.scale(-half_width) else dir.scale(half_width);
            const base_pt = if (is_start) p0 else p1;

            const base_idx: u32 = @intCast(result.vertices.len);
            const left_ext = base_pt.add(offset).add(ext);
            const right_ext = base_pt.sub(offset).add(ext);

            if (result.vertices.len + 2 > MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
            result.vertices.appendAssumeCapacity(left_ext);
            result.vertices.appendAssumeCapacity(right_ext);

            if (result.indices.len + 6 > MAX_STROKE_INDICES) return error.TooManyOutputPoints;
            if (is_start) {
                result.indices.appendAssumeCapacity(base_idx);
                result.indices.appendAssumeCapacity(left_idx);
                result.indices.appendAssumeCapacity(right_idx);
                result.indices.appendAssumeCapacity(base_idx);
                result.indices.appendAssumeCapacity(right_idx);
                result.indices.appendAssumeCapacity(base_idx + 1);
            } else {
                result.indices.appendAssumeCapacity(left_idx);
                result.indices.appendAssumeCapacity(base_idx);
                result.indices.appendAssumeCapacity(base_idx + 1);
                result.indices.appendAssumeCapacity(left_idx);
                result.indices.appendAssumeCapacity(base_idx + 1);
                result.indices.appendAssumeCapacity(right_idx);
            }
        },
        .round => {
            const dir = p1.sub(p0).normalize();
            const normal = dir.perp();
            const offset = normal.scale(half_width);
            const cap_dir = if (is_start) dir.negate() else dir;
            const base_pt = if (is_start) p0 else p1;
            const cap_offset = if (is_start) offset else offset.negate();

            try addSemicircleTriangles(result, base_pt, cap_offset, cap_dir);
        },
    }
}

fn addSemicircleTriangles(
    result: *StrokeTriangles,
    center: Vec2,
    start_offset: Vec2,
    direction: Vec2,
) StrokeError!void {
    const center_idx: u32 = @intCast(result.vertices.len);
    if (result.vertices.len >= MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
    result.vertices.appendAssumeCapacity(center);

    var prev_idx: u32 = @intCast(result.vertices.len);
    if (result.vertices.len >= MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
    result.vertices.appendAssumeCapacity(center.add(start_offset));

    const segments = ROUND_SEGMENTS;

    const cross = start_offset.x * direction.y - start_offset.y * direction.x;
    const sweep_sign: f32 = if (cross >= 0) 1.0 else -1.0;
    const step_angle = sweep_sign * std.math.pi / @as(f32, @floatFromInt(segments));

    const cos_step = @cos(step_angle);
    const sin_step = @sin(step_angle);

    var offset = start_offset;
    for (1..segments + 1) |_| {
        const rx = offset.x * cos_step - offset.y * sin_step;
        const ry = offset.x * sin_step + offset.y * cos_step;
        offset = Vec2{ .x = rx, .y = ry };

        const curr_idx: u32 = @intCast(result.vertices.len);
        if (result.vertices.len >= MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
        result.vertices.appendAssumeCapacity(center.add(offset));

        if (result.indices.len + 3 > MAX_STROKE_INDICES) return error.TooManyOutputPoints;
        result.indices.appendAssumeCapacity(center_idx);
        result.indices.appendAssumeCapacity(prev_idx);
        result.indices.appendAssumeCapacity(curr_idx);

        prev_idx = curr_idx;
    }
}

fn expandSingleSegment(
    p0: Vec2,
    p1: Vec2,
    half_width: f32,
    cap: LineCap,
    closed: bool,
) StrokeError!ExpandedStroke {
    std.debug.assert(half_width > 0);

    var result = ExpandedStroke{
        .points = .{},
        .closed = closed,
    };

    const dir = p1.sub(p0).normalize();
    const normal = dir.perp();
    const offset = normal.scale(half_width);

    const left0 = p0.add(offset);
    const left1 = p1.add(offset);
    const right0 = p0.sub(offset);
    const right1 = p1.sub(offset);

    switch (cap) {
        .butt => {
            try appendPoint(&result.points, left0);
            try appendPoint(&result.points, left1);
            try appendPoint(&result.points, right1);
            try appendPoint(&result.points, right0);
        },
        .square => {
            const back = dir.scale(-half_width);
            const fwd = dir.scale(half_width);

            try appendPoint(&result.points, left0.add(back));
            try appendPoint(&result.points, left1.add(fwd));
            try appendPoint(&result.points, right1.add(fwd));
            try appendPoint(&result.points, right0.add(back));
        },
        .round => {
            try addSemicircle(&result.points, p0, offset, dir.negate(), ROUND_SEGMENTS);
            try appendPoint(&result.points, left1);
            try addSemicircle(&result.points, p1, offset.negate(), dir, ROUND_SEGMENTS);
            try appendPoint(&result.points, right0);
        },
    }

    return result;
}

fn generateOffsetPoints(
    points: []const Vec2,
    half_width: f32,
    join: LineJoin,
    miter_limit: f32,
    closed: bool,
    left_offsets: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2),
    right_offsets: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2),
) StrokeError!void {
    std.debug.assert(points.len >= 2);
    std.debug.assert(half_width > 0);

    const n = points.len;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const curr = points[i];

        const has_prev = (i > 0) or closed;
        const has_next = (i < n - 1) or closed;

        if (!has_prev and !has_next) {
            // Unreachable with n >= 2; kept defensive.
            continue;
        }

        var prev_normal: Vec2 = undefined;
        var next_normal: Vec2 = undefined;

        if (has_prev) {
            const prev_idx = if (i > 0) i - 1 else n - 1;
            const prev = points[prev_idx];
            prev_normal = segmentNormal(prev, curr);
        }

        if (has_next) {
            const next_idx = if (i < n - 1) i + 1 else 0;
            const next = points[next_idx];
            next_normal = segmentNormal(curr, next);
        }

        if (!has_prev) {
            const offset = next_normal.scale(half_width);
            try appendPointToHalf(left_offsets, curr.add(offset));
            try appendPointToHalf(right_offsets, curr.sub(offset));
            continue;
        }

        if (!has_next) {
            const offset = prev_normal.scale(half_width);
            try appendPointToHalf(left_offsets, curr.add(offset));
            try appendPointToHalf(right_offsets, curr.sub(offset));
            continue;
        }

        try addJoinPoints(
            left_offsets,
            right_offsets,
            curr,
            prev_normal,
            next_normal,
            half_width,
            join,
            miter_limit,
        );
    }
}

fn addJoinPoints(
    left_offsets: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2),
    right_offsets: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2),
    point: Vec2,
    prev_normal: Vec2,
    next_normal: Vec2,
    half_width: f32,
    join: LineJoin,
    miter_limit: f32,
) StrokeError!void {
    std.debug.assert(half_width > 0);
    std.debug.assert(miter_limit > 0);

    const cross = prev_normal.cross(next_normal);
    const dot = prev_normal.dot(next_normal);

    if (@abs(cross) < 1e-6 and dot > 0.9) {
        const avg = prev_normal.add(next_normal).normalize();
        try appendPointToHalf(left_offsets, point.add(avg.scale(half_width)));
        try appendPointToHalf(right_offsets, point.sub(avg.scale(half_width)));
        return;
    }

    const is_left_turn = cross > 0;

    const avg_normal = prev_normal.add(next_normal).normalize();
    const inner_dot = prev_normal.dot(avg_normal);
    const inner_scale = if (@abs(inner_dot) > 0.1)
        std.math.clamp(half_width / inner_dot, half_width * 0.5, half_width * 2.0)
    else
        half_width;

    const prev_offset = prev_normal.scale(half_width);
    const next_offset = next_normal.scale(half_width);

    if (is_left_turn) {
        try addOuterJoin(left_offsets, point, prev_offset, next_offset, join, miter_limit, half_width);
        try appendPointToHalf(right_offsets, point.sub(avg_normal.scale(inner_scale)));
    } else {
        try appendPointToHalf(left_offsets, point.add(avg_normal.scale(inner_scale)));
        try addOuterJoin(right_offsets, point, prev_offset.negate(), next_offset.negate(), join, miter_limit, half_width);
    }
}

fn addOuterJoin(
    side: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2),
    point: Vec2,
    prev_offset: Vec2,
    next_offset: Vec2,
    join: LineJoin,
    miter_limit: f32,
    half_width: f32,
) StrokeError!void {
    switch (join) {
        .bevel => {
            try appendPointToHalf(side, point.add(prev_offset));
            try appendPointToHalf(side, point.add(next_offset));
        },
        .round => {
            try addArcToHalf(side, point, prev_offset, next_offset, ROUND_SEGMENTS);
        },
        .miter => {
            const miter_dir = prev_offset.add(next_offset).normalize();
            const miter_dot = prev_offset.normalize().dot(miter_dir);

            if (@abs(miter_dot) < 0.1) {
                try appendPointToHalf(side, point.add(prev_offset));
                try appendPointToHalf(side, point.add(next_offset));
                return;
            }

            const miter_len = half_width / miter_dot;

            if (@abs(miter_len) / half_width > miter_limit) {
                try appendPointToHalf(side, point.add(prev_offset));
                try appendPointToHalf(side, point.add(next_offset));
            } else {
                try appendPointToHalf(side, point.add(miter_dir.scale(miter_len)));
            }
        },
    }
}

fn addStartCap(
    result: *FixedArray(Vec2, MAX_STROKE_OUTPUT),
    p0: Vec2,
    p1: Vec2,
    half_width: f32,
    cap: LineCap,
) StrokeError!void {
    std.debug.assert(half_width > 0);

    const dir = p1.sub(p0).normalize();
    const normal = dir.perp();
    const offset = normal.scale(half_width);

    switch (cap) {
        .butt => {
            try appendPoint(result, p0.add(offset));
        },
        .square => {
            const back = dir.scale(-half_width);
            try appendPoint(result, p0.add(back).sub(offset));
            try appendPoint(result, p0.add(back).add(offset));
        },
        .round => {
            try addSemicircle(result, p0, offset.negate(), dir.negate(), ROUND_SEGMENTS);
        },
    }
}

fn addEndCap(
    result: *FixedArray(Vec2, MAX_STROKE_OUTPUT),
    p0: Vec2,
    p1: Vec2,
    half_width: f32,
    cap: LineCap,
) StrokeError!void {
    std.debug.assert(half_width > 0);

    const dir = p1.sub(p0).normalize();
    const normal = dir.perp();
    const offset = normal.scale(half_width);

    switch (cap) {
        .butt => {
            try appendPoint(result, p1.sub(offset));
        },
        .square => {
            const fwd = dir.scale(half_width);
            try appendPoint(result, p1.add(fwd).add(offset));
            try appendPoint(result, p1.add(fwd).sub(offset));
        },
        .round => {
            try addSemicircle(result, p1, offset, dir, ROUND_SEGMENTS);
        },
    }
}

/// Unit normal of p0→p1 pointing left of the direction.
fn segmentNormal(p0: Vec2, p1: Vec2) Vec2 {
    std.debug.assert(!std.math.isNan(p0.x) and !std.math.isNan(p1.x));

    return p1.sub(p0).normalize().perp();
}

fn addSemicircle(
    result: *FixedArray(Vec2, MAX_STROKE_OUTPUT),
    center: Vec2,
    start_offset: Vec2,
    direction: Vec2,
    segments: u32,
) StrokeError!void {
    std.debug.assert(segments > 0);

    const cross = start_offset.x * direction.y - start_offset.y * direction.x;
    const sweep_sign: f32 = if (cross >= 0) 1.0 else -1.0;
    const step_angle = sweep_sign * std.math.pi / @as(f32, @floatFromInt(segments));

    const cos_step = @cos(step_angle);
    const sin_step = @sin(step_angle);

    var offset = start_offset;
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        try appendPoint(result, center.add(offset));
        const rx = offset.x * cos_step - offset.y * sin_step;
        const ry = offset.x * sin_step + offset.y * cos_step;
        offset = Vec2{ .x = rx, .y = ry };
    }
}

fn addArcToHalf(
    side: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2),
    center: Vec2,
    from_offset: Vec2,
    to_offset: Vec2,
    segments: u32,
) StrokeError!void {
    std.debug.assert(segments > 0);

    // atan2(cross, dot) gives the signed angle of the shorter arc.
    const cross = from_offset.x * to_offset.y - from_offset.y * to_offset.x;
    const dot = from_offset.x * to_offset.x + from_offset.y * to_offset.y;
    const angle_diff = std.math.atan2(cross, dot);

    const step_angle = angle_diff / @as(f32, @floatFromInt(segments));

    const cos_step = @cos(step_angle);
    const sin_step = @sin(step_angle);

    var offset = from_offset;
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        try appendPointToHalf(side, center.add(offset));
        const rx = offset.x * cos_step - offset.y * sin_step;
        const ry = offset.x * sin_step + offset.y * cos_step;
        offset = Vec2{ .x = rx, .y = ry };
    }
}

fn appendPoint(buf: *FixedArray(Vec2, MAX_STROKE_OUTPUT), pt: Vec2) StrokeError!void {
    if (buf.len >= MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
    buf.appendAssumeCapacity(pt);
}

fn appendPointToHalf(buf: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2), pt: Vec2) StrokeError!void {
    if (buf.len >= MAX_STROKE_OUTPUT / 2) return error.TooManyOutputPoints;
    buf.appendAssumeCapacity(pt);
}

test "expandStroke simple line butt cap" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
    };

    const result = try expandStroke(&points, 10.0, .butt, .miter, 4.0, false);

    try std.testing.expectEqual(@as(usize, 4), result.points.len);
    try std.testing.expect(!result.closed);
}

test "expandStroke simple line round cap" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
    };

    const result = try expandStroke(&points, 10.0, .round, .miter, 4.0, false);

    try std.testing.expect(result.points.len > 4);
}

test "expandStroke simple line square cap" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
    };

    const result = try expandStroke(&points, 10.0, .square, .miter, 4.0, false);

    try std.testing.expectEqual(@as(usize, 4), result.points.len);
}

test "expandStroke with corner miter join" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 50, .y = 50 },
    };

    const result = try expandStroke(&points, 10.0, .butt, .miter, 4.0, false);

    try std.testing.expect(result.points.len >= 5);
}

test "expandStroke with corner bevel join" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 50, .y = 50 },
    };

    const result = try expandStroke(&points, 10.0, .butt, .bevel, 4.0, false);

    try std.testing.expect(result.points.len >= 6);
}

test "expandStroke with corner round join" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 50, .y = 50 },
    };

    const result = try expandStroke(&points, 10.0, .butt, .round, 4.0, false);

    try std.testing.expect(result.points.len >= 6);
}

test "expandStroke closed path" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 50, .y = 50 },
        .{ .x = 0, .y = 50 },
    };

    const result = try expandStroke(&points, 10.0, .butt, .miter, 4.0, true);

    try std.testing.expect(result.closed);
    try std.testing.expect(result.points.len >= 4);
}

test "expandStroke degenerate path error" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
    };

    const result = expandStroke(&points, 10.0, .butt, .miter, 4.0, false);
    try std.testing.expectError(error.DegeneratePath, result);
}

test "segmentNormal correctness" {
    const n1 = segmentNormal(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), n1.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), n1.y, 1e-6);

    const n2 = segmentNormal(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 10 });
    try std.testing.expectApproxEqAbs(@as(f32, -1), n2.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), n2.y, 1e-6);
}

test "normalize handles zero vector" {
    const zero = Vec2{ .x = 0, .y = 0 };
    const n = zero.normalize();
    try std.testing.expect(!std.math.isNan(n.x));
    try std.testing.expect(!std.math.isNan(n.y));
}

test "miter limit fallback to bevel" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 49, .y = 5 },
    };

    const result = try expandStroke(&points, 10.0, .butt, .miter, 1.0, false);
    try std.testing.expect(result.points.len >= 5);
}

test "single segment creates valid polygon" {
    const points = [_]Vec2{
        .{ .x = 10, .y = 10 },
        .{ .x = 90, .y = 10 },
    };

    const result = try expandStroke(&points, 20.0, .butt, .miter, 4.0, false);

    try std.testing.expectEqual(@as(usize, 4), result.points.len);

    const p0 = result.points.get(0);
    const p1 = result.points.get(1);
    const p2 = result.points.get(2);
    const p3 = result.points.get(3);

    const d01 = p1.sub(p0);
    const d32 = p2.sub(p3);
    const dot = d01.dot(d32);
    try std.testing.expect(dot > 0);
}
