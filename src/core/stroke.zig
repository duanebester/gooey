//! Stroke Expansion — Convert stroked paths to filled polygons
//!
//! Converts a path's stroke into a thick polygon that can be triangulated
//! and rendered as a fill. Supports line caps, line joins, and miter limits.
//!
//! ## Usage
//! ```zig
//! const stroke = @import("stroke.zig");
//! const expanded = try stroke.expandStroke(
//!     points,
//!     2.0,      // stroke width
//!     .round,   // line cap
//!     .miter,   // line join
//!     4.0,      // miter limit
//! );
//! // expanded.points can be triangulated as a fill
//! ```

const std = @import("std");
const builtin = @import("builtin");
const triangulator = @import("triangulator.zig");

const Vec2 = triangulator.Vec2;
const FixedArray = triangulator.FixedArray;

// =============================================================================
// Constants (static allocation per CLAUDE.md)
// =============================================================================

/// Maximum input points for stroke expansion
pub const MAX_STROKE_INPUT: u32 = 512;
/// Maximum output points for stroke expansion
/// Kept small to avoid stack overflow (ExpandedStroke ~8KB at 1024 points)
/// For UI strokes, 1024 points is plenty (circles flatten to ~64 points)
pub const MAX_STROKE_OUTPUT: u32 = 1024;
/// Number of segments for round caps/joins (affects smoothness)
pub const ROUND_SEGMENTS: u32 = 8;

// =============================================================================
// Types
// =============================================================================

/// Line cap style — how stroke endpoints are rendered
pub const LineCap = enum(u8) {
    /// Square end exactly at path endpoint
    butt,
    /// Semicircle at path endpoint
    round,
    /// Square end extended by half stroke width
    square,
};

/// Line join style — how corners between segments are rendered
pub const LineJoin = enum(u8) {
    /// Sharp corner (limited by miter limit)
    miter,
    /// Circular arc at corner
    round,
    /// Flat cut at corner
    bevel,
};

/// Stroke style configuration
pub const StrokeStyle = struct {
    /// Stroke thickness in pixels
    width: f32 = 1.0,
    /// How line endpoints are rendered
    cap: LineCap = .butt,
    /// How corners are rendered
    join: LineJoin = .miter,
    /// Maximum miter length ratio (miter length / stroke width)
    /// When exceeded, falls back to bevel join
    miter_limit: f32 = 4.0,
};

/// Result of stroke expansion
pub const ExpandedStroke = struct {
    /// Points forming the stroke outline polygon (CCW winding)
    points: FixedArray(Vec2, MAX_STROKE_OUTPUT),
    /// Whether the stroke forms a closed loop
    closed: bool,
};

/// Maximum triangles for direct stroke triangulation
pub const MAX_STROKE_TRIANGLES: u32 = MAX_STROKE_OUTPUT;
/// Maximum indices (3 per triangle)
pub const MAX_STROKE_INDICES: u32 = MAX_STROKE_TRIANGLES * 3;

/// Result of direct stroke triangulation (bypasses ear-clipper)
pub const StrokeTriangles = struct {
    /// Vertex positions
    vertices: FixedArray(Vec2, MAX_STROKE_OUTPUT),
    /// Triangle indices (3 per triangle)
    indices: FixedArray(u32, MAX_STROKE_INDICES),
};

// =============================================================================
// Errors
// =============================================================================

pub const StrokeError = error{
    TooManyInputPoints,
    TooManyOutputPoints,
    DegeneratePath,
};

// =============================================================================
// Public API
// =============================================================================

/// Expand a stroke into a filled polygon outline
///
/// Takes a polyline (sequence of connected points) and expands it into
/// a thick polygon that represents the stroked path. The result can be
/// triangulated and rendered as a fill.
///
/// The output polygon is assembled as:
/// - Start cap (for open paths)
/// - Left side (all left offset points, forward)
/// - End cap (for open paths)
/// - Right side (all right offset points, backward)
///
/// This creates a single continuous polygon suitable for triangulation.
pub fn expandStroke(
    points: []const Vec2,
    width: f32,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f32,
    closed: bool,
) StrokeError!ExpandedStroke {
    // API boundary assertions
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

    // Special case: single line segment (2 points)
    if (n == 2) {
        return expandSingleSegment(points[0], points[1], half_width, cap, closed);
    }

    // Build left and right offset arrays
    var left_offsets: FixedArray(Vec2, MAX_STROKE_OUTPUT / 2) = .{};
    var right_offsets: FixedArray(Vec2, MAX_STROKE_OUTPUT / 2) = .{};

    // Generate offset points for each input point
    try generateOffsetPoints(
        points,
        half_width,
        join,
        miter_limit,
        closed,
        &left_offsets,
        &right_offsets,
    );

    // Assemble the final polygon
    if (!closed) {
        // Open path: start cap → left side → end cap → right side (reversed)
        try addStartCap(&result.points, points[0], points[1], half_width, cap);
    }

    // Add left side points
    for (left_offsets.constSlice()) |pt| {
        try appendPoint(&result.points, pt);
    }

    if (!closed) {
        // End cap for open paths
        try addEndCap(&result.points, points[n - 2], points[n - 1], half_width, cap);
    }
    // For closed paths, no end cap needed - the polygon closes naturally
    // Note: This may leave a small visual gap at the closure point due to
    // how the ear-clipper handles the resulting concave polygon. A future
    // improvement would be to generate triangles directly as a quad-strip.

    // Add right side points in reverse order
    var i: usize = right_offsets.len;
    while (i > 0) {
        i -= 1;
        try appendPoint(&result.points, right_offsets.get(i));
    }

    return result;
}

/// Expand stroke with default miter limit
pub fn expandStrokeSimple(
    points: []const Vec2,
    width: f32,
    cap: LineCap,
    join: LineJoin,
    closed: bool,
) StrokeError!ExpandedStroke {
    return expandStroke(points, width, cap, join, 4.0, closed);
}

/// Expand stroke directly to triangles (bypasses ear-clipper)
/// This is more reliable for closed paths which create concave ring polygons.
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

    // Special case: single line segment (2 points)
    if (n == 2) {
        return expandSingleSegmentToTriangles(points[0], points[1], half_width, cap);
    }

    // Build left and right offset arrays
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

    // Add all vertices (left then right)
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

    // Generate triangles for each segment as a quad
    const seg_count: u32 = if (closed) num_offsets else num_offsets - 1;
    for (0..seg_count) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const next_i: u32 = if (i + 1 >= num_offsets) 0 else i + 1;

        const l0 = left_start + i;
        const l1 = left_start + next_i;
        const r0 = right_start + i;
        const r1 = right_start + next_i;

        // Two triangles per quad: (l0, l1, r1) and (l0, r1, r0)
        if (result.indices.len + 6 > MAX_STROKE_INDICES) return error.TooManyOutputPoints;
        result.indices.appendAssumeCapacity(l0);
        result.indices.appendAssumeCapacity(l1);
        result.indices.appendAssumeCapacity(r1);

        result.indices.appendAssumeCapacity(l0);
        result.indices.appendAssumeCapacity(r1);
        result.indices.appendAssumeCapacity(r0);
    }

    // Add caps for open paths
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

    const dir = normalize(p1.sub(p0));
    const normal = Vec2{ .x = -dir.y, .y = dir.x };
    const offset = normal.scale(half_width);

    // Four corners of the basic rectangle
    const left0 = p0.add(offset);
    const left1 = p1.add(offset);
    const right0 = p0.sub(offset);
    const right1 = p1.sub(offset);

    switch (cap) {
        .butt => {
            // Simple rectangle: 4 vertices, 2 triangles
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
            // Extended rectangle
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
            // For round caps, create a fan at each end
            const base_idx: u32 = @intCast(result.vertices.len);

            // Add the four corners
            result.vertices.appendAssumeCapacity(left0);
            result.vertices.appendAssumeCapacity(left1);
            result.vertices.appendAssumeCapacity(right1);
            result.vertices.appendAssumeCapacity(right0);

            // Main rectangle
            result.indices.appendAssumeCapacity(base_idx + 0);
            result.indices.appendAssumeCapacity(base_idx + 1);
            result.indices.appendAssumeCapacity(base_idx + 2);
            result.indices.appendAssumeCapacity(base_idx + 0);
            result.indices.appendAssumeCapacity(base_idx + 2);
            result.indices.appendAssumeCapacity(base_idx + 3);

            // Start cap (semicircle at p0)
            try addSemicircleTriangles(&result, p0, offset, dir.scale(-1));
            // End cap (semicircle at p1)
            try addSemicircleTriangles(&result, p1, offset.scale(-1), dir);
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
        .butt => {
            // No additional geometry needed
        },
        .square => {
            // Add extended rectangle at the cap
            const dir = normalize(p1.sub(p0));
            const normal = Vec2{ .x = -dir.y, .y = dir.x };
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
                result.indices.appendAssumeCapacity(base_idx); // left_ext
                result.indices.appendAssumeCapacity(left_idx); // left corner
                result.indices.appendAssumeCapacity(right_idx); // right corner
                result.indices.appendAssumeCapacity(base_idx); // left_ext
                result.indices.appendAssumeCapacity(right_idx); // right corner
                result.indices.appendAssumeCapacity(base_idx + 1); // right_ext
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
            const dir = normalize(p1.sub(p0));
            const normal = Vec2{ .x = -dir.y, .y = dir.x };
            const offset = normal.scale(half_width);
            const cap_dir = if (is_start) dir.scale(-1) else dir;
            const base_pt = if (is_start) p0 else p1;
            const cap_offset = if (is_start) offset else offset.scale(-1);

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
    for (1..segments + 1) |i| {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi / @as(f32, @floatFromInt(segments));
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);

        // Rotate start_offset by angle around the direction axis
        const rotated = Vec2{
            .x = start_offset.x * cos_a + direction.x * sin_a * (start_offset.x * direction.x + start_offset.y * direction.y) / (direction.x * direction.x + direction.y * direction.y + 0.0001) - direction.y * sin_a,
            .y = start_offset.y * cos_a + direction.y * sin_a * (start_offset.x * direction.x + start_offset.y * direction.y) / (direction.x * direction.x + direction.y * direction.y + 0.0001) + direction.x * sin_a,
        };

        // Simpler rotation: interpolate between start_offset and -start_offset along the arc
        const end_offset = Vec2{ .x = -start_offset.x, .y = -start_offset.y };
        const interp = Vec2{
            .x = start_offset.x * cos_a + end_offset.x * (1 - cos_a) + direction.x * sin_a * @sqrt(start_offset.x * start_offset.x + start_offset.y * start_offset.y),
            .y = start_offset.y * cos_a + end_offset.y * (1 - cos_a) + direction.y * sin_a * @sqrt(start_offset.x * start_offset.x + start_offset.y * start_offset.y),
        };
        _ = rotated;

        const curr_idx: u32 = @intCast(result.vertices.len);
        if (result.vertices.len >= MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
        result.vertices.appendAssumeCapacity(center.add(interp));

        if (result.indices.len + 3 > MAX_STROKE_INDICES) return error.TooManyOutputPoints;
        result.indices.appendAssumeCapacity(center_idx);
        result.indices.appendAssumeCapacity(prev_idx);
        result.indices.appendAssumeCapacity(curr_idx);

        prev_idx = curr_idx;
    }
}

// =============================================================================
// Internal: Single segment expansion
// =============================================================================

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

    const dir = normalize(p1.sub(p0));
    const normal = Vec2{ .x = -dir.y, .y = dir.x };
    const offset = normal.scale(half_width);

    // Four corners of the basic rectangle
    const left0 = p0.add(offset);
    const left1 = p1.add(offset);
    const right0 = p0.sub(offset);
    const right1 = p1.sub(offset);

    switch (cap) {
        .butt => {
            // Simple rectangle: left0 → left1 → right1 → right0
            try appendPoint(&result.points, left0);
            try appendPoint(&result.points, left1);
            try appendPoint(&result.points, right1);
            try appendPoint(&result.points, right0);
        },
        .square => {
            // Extended rectangle
            const back = dir.scale(-half_width);
            const fwd = dir.scale(half_width);

            try appendPoint(&result.points, left0.add(back));
            try appendPoint(&result.points, left1.add(fwd));
            try appendPoint(&result.points, right1.add(fwd));
            try appendPoint(&result.points, right0.add(back));
        },
        .round => {
            // Start with back semicircle
            try addSemicircle(&result.points, p0, offset, dir.scale(-1), ROUND_SEGMENTS);
            // Top edge
            try appendPoint(&result.points, left1);
            // Front semicircle
            try addSemicircle(&result.points, p1, offset.scale(-1), dir, ROUND_SEGMENTS);
            // Bottom edge (back to start)
            try appendPoint(&result.points, right0);
        },
    }

    return result;
}

// =============================================================================
// Internal: Generate offset points
// =============================================================================

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

    // For each vertex, compute the offset points
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const curr = points[i];

        // Get adjacent segment directions
        const has_prev = (i > 0) or closed;
        const has_next = (i < n - 1) or closed;

        if (!has_prev and !has_next) {
            // Isolated point - shouldn't happen with n >= 2
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

        // First point of open path
        if (!has_prev) {
            const offset = next_normal.scale(half_width);
            try appendPointToHalf(left_offsets, curr.add(offset));
            try appendPointToHalf(right_offsets, curr.sub(offset));
            continue;
        }

        // Last point of open path
        if (!has_next) {
            const offset = prev_normal.scale(half_width);
            try appendPointToHalf(left_offsets, curr.add(offset));
            try appendPointToHalf(right_offsets, curr.sub(offset));
            continue;
        }

        // Interior point or closed path vertex - need to handle join
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

// =============================================================================
// Internal: Join handling
// =============================================================================

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

    // Calculate the turn direction
    const cross = prev_normal.cross(next_normal);
    const dot = prev_normal.dot(next_normal);

    // Near-collinear segments - just use average normal
    if (@abs(cross) < 1e-6 and dot > 0.9) {
        const avg = normalize(prev_normal.add(next_normal));
        try appendPointToHalf(left_offsets, point.add(avg.scale(half_width)));
        try appendPointToHalf(right_offsets, point.sub(avg.scale(half_width)));
        return;
    }

    // Determine which side is outer (needs the join)
    const is_left_turn = cross > 0;

    // For the inner side, compute the intersection point
    const avg_normal = normalize(prev_normal.add(next_normal));
    const inner_dot = prev_normal.dot(avg_normal);
    const inner_scale = if (@abs(inner_dot) > 0.1)
        std.math.clamp(half_width / inner_dot, half_width * 0.5, half_width * 2.0)
    else
        half_width;

    const prev_offset = prev_normal.scale(half_width);
    const next_offset = next_normal.scale(half_width);

    if (is_left_turn) {
        // Left turn: outer join on left, inner point on right
        try addOuterJoin(left_offsets, point, prev_offset, next_offset, join, miter_limit, half_width);
        try appendPointToHalf(right_offsets, point.sub(avg_normal.scale(inner_scale)));
    } else {
        // Right turn: outer join on right, inner point on left
        try appendPointToHalf(left_offsets, point.add(avg_normal.scale(inner_scale)));
        // For right side, we need to negate offsets
        try addOuterJoin(right_offsets, point, prev_offset.scale(-1), next_offset.scale(-1), join, miter_limit, half_width);
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
            // Calculate miter point
            const miter_dir = normalize(prev_offset.add(next_offset));
            const miter_dot = normalize(prev_offset).dot(miter_dir);

            if (@abs(miter_dot) < 0.1) {
                // Nearly 180° turn, use bevel
                try appendPointToHalf(side, point.add(prev_offset));
                try appendPointToHalf(side, point.add(next_offset));
                return;
            }

            const miter_len = half_width / miter_dot;

            // Check miter limit
            if (@abs(miter_len) / half_width > miter_limit) {
                // Exceed limit, fall back to bevel
                try appendPointToHalf(side, point.add(prev_offset));
                try appendPointToHalf(side, point.add(next_offset));
            } else {
                // Use miter
                try appendPointToHalf(side, point.add(miter_dir.scale(miter_len)));
            }
        },
    }
}

// =============================================================================
// Internal: Line caps
// =============================================================================

fn addStartCap(
    result: *FixedArray(Vec2, MAX_STROKE_OUTPUT),
    p0: Vec2,
    p1: Vec2,
    half_width: f32,
    cap: LineCap,
) StrokeError!void {
    std.debug.assert(half_width > 0);

    const dir = normalize(p1.sub(p0));
    const normal = Vec2{ .x = -dir.y, .y = dir.x };
    const offset = normal.scale(half_width);

    switch (cap) {
        .butt => {
            // Just the corner point (left side will continue from here)
            try appendPoint(result, p0.add(offset));
        },
        .square => {
            const back = dir.scale(-half_width);
            // Bottom-left corner of extended cap
            try appendPoint(result, p0.add(back).sub(offset));
            // Top-left corner
            try appendPoint(result, p0.add(back).add(offset));
        },
        .round => {
            // Semicircle from right side around to left side
            try addSemicircle(result, p0, offset.scale(-1), dir.scale(-1), ROUND_SEGMENTS);
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

    const dir = normalize(p1.sub(p0));
    const normal = Vec2{ .x = -dir.y, .y = dir.x };
    const offset = normal.scale(half_width);

    switch (cap) {
        .butt => {
            // Just the corner point (will connect to right side)
            try appendPoint(result, p1.sub(offset));
        },
        .square => {
            const fwd = dir.scale(half_width);
            // Top-right corner of extended cap
            try appendPoint(result, p1.add(fwd).add(offset));
            // Bottom-right corner
            try appendPoint(result, p1.add(fwd).sub(offset));
        },
        .round => {
            // Semicircle from left side around to right side
            try addSemicircle(result, p1, offset, dir, ROUND_SEGMENTS);
        },
    }
}

// =============================================================================
// Internal: Geometry helpers
// =============================================================================

/// Compute perpendicular normal for a line segment (unit length, pointing left)
fn segmentNormal(p0: Vec2, p1: Vec2) Vec2 {
    std.debug.assert(!std.math.isNan(p0.x) and !std.math.isNan(p1.x));

    const dir = normalize(p1.sub(p0));
    return Vec2{ .x = -dir.y, .y = dir.x };
}

/// Normalize a vector (handle zero-length gracefully)
fn normalize(v: Vec2) Vec2 {
    const len_sq = v.lengthSq();
    if (len_sq < 1e-12) {
        return Vec2{ .x = 1, .y = 0 }; // Default direction
    }
    const inv_len = 1.0 / @sqrt(len_sq);
    return v.scale(inv_len);
}

/// Add semicircle points (for round caps)
fn addSemicircle(
    result: *FixedArray(Vec2, MAX_STROKE_OUTPUT),
    center: Vec2,
    start_offset: Vec2,
    direction: Vec2,
    segments: u32,
) StrokeError!void {
    std.debug.assert(segments > 0);

    const start_angle = std.math.atan2(start_offset.y, start_offset.x);
    const radius = @sqrt(start_offset.lengthSq());

    // Determine which way to go (half circle in direction of 'direction')
    const dir_angle = std.math.atan2(direction.y, direction.x);
    var end_angle = dir_angle + std.math.pi / 2.0;

    // Ensure we go the right way (pi radians = semicircle)
    var angle_diff = end_angle - start_angle;
    while (angle_diff > std.math.pi) angle_diff -= 2.0 * std.math.pi;
    while (angle_diff < -std.math.pi) angle_diff += 2.0 * std.math.pi;

    // If angle_diff is negative, we need to go the other way
    if (@abs(angle_diff) < std.math.pi * 0.5) {
        end_angle = dir_angle - std.math.pi / 2.0;
        angle_diff = end_angle - start_angle;
        while (angle_diff > std.math.pi) angle_diff -= 2.0 * std.math.pi;
        while (angle_diff < -std.math.pi) angle_diff += 2.0 * std.math.pi;
    }

    // Add arc points
    const step = angle_diff / @as(f32, @floatFromInt(segments));
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        const angle = start_angle + step * @as(f32, @floatFromInt(i));
        const pt = Vec2{
            .x = center.x + radius * @cos(angle),
            .y = center.y + radius * @sin(angle),
        };
        try appendPoint(result, pt);
    }
}

/// Add arc points to half buffer (for round joins)
fn addArcToHalf(
    side: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2),
    center: Vec2,
    from_offset: Vec2,
    to_offset: Vec2,
    segments: u32,
) StrokeError!void {
    std.debug.assert(segments > 0);

    const from_angle = std.math.atan2(from_offset.y, from_offset.x);
    const to_angle = std.math.atan2(to_offset.y, to_offset.x);

    var angle_diff = to_angle - from_angle;
    // Take the shorter arc
    if (angle_diff > std.math.pi) angle_diff -= 2.0 * std.math.pi;
    if (angle_diff < -std.math.pi) angle_diff += 2.0 * std.math.pi;

    const radius = @sqrt(from_offset.lengthSq());
    const step = angle_diff / @as(f32, @floatFromInt(segments));

    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        const angle = from_angle + step * @as(f32, @floatFromInt(i));
        const pt = Vec2{
            .x = center.x + radius * @cos(angle),
            .y = center.y + radius * @sin(angle),
        };
        try appendPointToHalf(side, pt);
    }
}

/// Append point with bounds check
fn appendPoint(buf: *FixedArray(Vec2, MAX_STROKE_OUTPUT), pt: Vec2) StrokeError!void {
    if (buf.len >= MAX_STROKE_OUTPUT) return error.TooManyOutputPoints;
    buf.appendAssumeCapacity(pt);
}

/// Append point to half buffer with bounds check
fn appendPointToHalf(buf: *FixedArray(Vec2, MAX_STROKE_OUTPUT / 2), pt: Vec2) StrokeError!void {
    if (buf.len >= MAX_STROKE_OUTPUT / 2) return error.TooManyOutputPoints;
    buf.appendAssumeCapacity(pt);
}

// =============================================================================
// Tests
// =============================================================================

test "expandStroke simple line butt cap" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
    };

    const result = try expandStroke(&points, 10.0, .butt, .miter, 4.0, false);

    // Butt cap: should have 4 corners (rectangle)
    try std.testing.expectEqual(@as(usize, 4), result.points.len);
    try std.testing.expect(!result.closed);
}

test "expandStroke simple line round cap" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
    };

    const result = try expandStroke(&points, 10.0, .round, .miter, 4.0, false);

    // Round cap: should have more points for the semicircles
    try std.testing.expect(result.points.len > 4);
}

test "expandStroke simple line square cap" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
    };

    const result = try expandStroke(&points, 10.0, .square, .miter, 4.0, false);

    // Square cap: 4 corners of extended rectangle
    try std.testing.expectEqual(@as(usize, 4), result.points.len);
}

test "expandStroke with corner miter join" {
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 50, .y = 50 },
    };

    const result = try expandStroke(&points, 10.0, .butt, .miter, 4.0, false);

    // Should have points for both segments plus join
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

    // Round join should add arc points
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
    // Horizontal line: normal should point up (left of direction)
    const n1 = segmentNormal(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), n1.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), n1.y, 1e-6);

    // Vertical line: normal should point left
    const n2 = segmentNormal(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 10 });
    try std.testing.expectApproxEqAbs(@as(f32, -1), n2.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), n2.y, 1e-6);
}

test "normalize handles zero vector" {
    const zero = Vec2{ .x = 0, .y = 0 };
    const n = normalize(zero);
    // Should return a default direction, not NaN
    try std.testing.expect(!std.math.isNan(n.x));
    try std.testing.expect(!std.math.isNan(n.y));
}

test "miter limit fallback to bevel" {
    // Very sharp angle should exceed miter limit and fall back to bevel
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 49, .y = 5 }, // Very sharp turn
    };

    // With low miter limit, should fall back to bevel
    const result = try expandStroke(&points, 10.0, .butt, .miter, 1.0, false);
    try std.testing.expect(result.points.len >= 5);
}

test "single segment creates valid polygon" {
    const points = [_]Vec2{
        .{ .x = 10, .y = 10 },
        .{ .x = 90, .y = 10 },
    };

    const result = try expandStroke(&points, 20.0, .butt, .miter, 4.0, false);

    // Verify we got a proper rectangle
    try std.testing.expectEqual(@as(usize, 4), result.points.len);

    // Verify points form a valid polygon (not degenerate)
    const p0 = result.points.get(0);
    const p1 = result.points.get(1);
    const p2 = result.points.get(2);
    const p3 = result.points.get(3);

    // Check that opposite sides are roughly parallel (rectangle shape)
    const d01 = p1.sub(p0);
    const d32 = p2.sub(p3);
    const dot = d01.dot(d32);
    try std.testing.expect(dot > 0); // Same direction
}
