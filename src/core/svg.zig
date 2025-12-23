//! SVG Path Parsing and Primitives
//!
//! Parses SVG path data into a format suitable for tessellation and GPU rendering.
//! Adapted from cosmic graphics for the gooey rendering pipeline.

const std = @import("std");
const scene = @import("scene.zig");

/// 2D Vector for path operations
pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Vec2, s: f32) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn cross(self: Vec2, other: Vec2) f32 {
        return self.x * other.y - self.y * other.x;
    }

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

/// SVG Path Commands
pub const PathCommand = enum(u8) {
    move_to,
    move_to_rel,
    line_to,
    line_to_rel,
    horiz_line_to,
    horiz_line_to_rel,
    vert_line_to,
    vert_line_to_rel,
    curve_to,
    curve_to_rel,
    smooth_curve_to,
    smooth_curve_to_rel,
    // Quadratic Bezier curves
    quad_to,
    quad_to_rel,
    smooth_quad_to,
    smooth_quad_to_rel,
    // Arc commands
    arc_to,
    arc_to_rel,
    close_path,
};

/// Cubic Bezier curve for path flattening
pub const CubicBez = struct {
    x0: f32,
    y0: f32,
    cx0: f32,
    cy0: f32,
    cx1: f32,
    cy1: f32,
    x1: f32,
    y1: f32,

    /// Flatten cubic bezier to line segments using de Casteljau subdivision
    pub fn flatten(self: CubicBez, tolerance: f32, allocator: std.mem.Allocator, output: *std.ArrayList(Vec2)) !void {
        try self.flattenRecursive(tolerance, allocator, output, 0);
    }

    fn flattenRecursive(self: CubicBez, tolerance: f32, allocator: std.mem.Allocator, output: *std.ArrayList(Vec2), depth: u32) !void {
        // Limit recursion depth
        if (depth > 16) {
            try output.append(allocator, Vec2.init(self.x1, self.y1));
            return;
        }

        // Check if curve is flat enough
        const dx = self.x1 - self.x0;
        const dy = self.y1 - self.y0;
        const d1 = @abs((self.cx0 - self.x1) * dy - (self.cy0 - self.y1) * dx);
        const d2 = @abs((self.cx1 - self.x1) * dy - (self.cy1 - self.y1) * dx);

        const flatness = (d1 + d2) * (d1 + d2);
        const tol_sq = tolerance * tolerance * (dx * dx + dy * dy);

        if (flatness <= tol_sq) {
            try output.append(allocator, Vec2.init(self.x1, self.y1));
            return;
        }

        // Subdivide at t=0.5 using de Casteljau
        const mid_x01 = (self.x0 + self.cx0) * 0.5;
        const mid_y01 = (self.y0 + self.cy0) * 0.5;
        const mid_x12 = (self.cx0 + self.cx1) * 0.5;
        const mid_y12 = (self.cy0 + self.cy1) * 0.5;
        const mid_x23 = (self.cx1 + self.x1) * 0.5;
        const mid_y23 = (self.cy1 + self.y1) * 0.5;

        const mid_x012 = (mid_x01 + mid_x12) * 0.5;
        const mid_y012 = (mid_y01 + mid_y12) * 0.5;
        const mid_x123 = (mid_x12 + mid_x23) * 0.5;
        const mid_y123 = (mid_y12 + mid_y23) * 0.5;

        const mid_x = (mid_x012 + mid_x123) * 0.5;
        const mid_y = (mid_y012 + mid_y123) * 0.5;

        const left = CubicBez{
            .x0 = self.x0,
            .y0 = self.y0,
            .cx0 = mid_x01,
            .cy0 = mid_y01,
            .cx1 = mid_x012,
            .cy1 = mid_y012,
            .x1 = mid_x,
            .y1 = mid_y,
        };
        const right = CubicBez{
            .x0 = mid_x,
            .y0 = mid_y,
            .cx0 = mid_x123,
            .cy0 = mid_y123,
            .cx1 = mid_x23,
            .cy1 = mid_y23,
            .x1 = self.x1,
            .y1 = self.y1,
        };

        try left.flattenRecursive(tolerance, allocator, output, depth + 1);
        try right.flattenRecursive(tolerance, allocator, output, depth + 1);
    }
};

/// Quadratic Bezier curve for path flattening
pub const QuadraticBez = struct {
    x0: f32,
    y0: f32,
    cx: f32,
    cy: f32,
    x1: f32,
    y1: f32,

    /// Flatten quadratic bezier to line segments using de Casteljau subdivision
    pub fn flatten(self: QuadraticBez, tolerance: f32, allocator: std.mem.Allocator, output: *std.ArrayList(Vec2)) !void {
        try self.flattenRecursive(tolerance, allocator, output, 0);
    }

    fn flattenRecursive(self: QuadraticBez, tolerance: f32, allocator: std.mem.Allocator, output: *std.ArrayList(Vec2), depth: u32) !void {
        if (depth > 16) {
            try output.append(allocator, Vec2.init(self.x1, self.y1));
            return;
        }

        // Check flatness: distance from control point to line
        const dx = self.x1 - self.x0;
        const dy = self.y1 - self.y0;
        const d = @abs((self.cx - self.x1) * dy - (self.cy - self.y1) * dx);
        const len_sq = dx * dx + dy * dy;

        if (d * d <= tolerance * tolerance * len_sq) {
            try output.append(allocator, Vec2.init(self.x1, self.y1));
            return;
        }

        // Subdivide at t=0.5
        const mid_x01 = (self.x0 + self.cx) * 0.5;
        const mid_y01 = (self.y0 + self.cy) * 0.5;
        const mid_x12 = (self.cx + self.x1) * 0.5;
        const mid_y12 = (self.cy + self.y1) * 0.5;
        const mid_x = (mid_x01 + mid_x12) * 0.5;
        const mid_y = (mid_y01 + mid_y12) * 0.5;

        const left = QuadraticBez{ .x0 = self.x0, .y0 = self.y0, .cx = mid_x01, .cy = mid_y01, .x1 = mid_x, .y1 = mid_y };
        const right = QuadraticBez{ .x0 = mid_x, .y0 = mid_y, .cx = mid_x12, .cy = mid_y12, .x1 = self.x1, .y1 = self.y1 };

        try left.flattenRecursive(tolerance, allocator, output, depth + 1);
        try right.flattenRecursive(tolerance, allocator, output, depth + 1);
    }
};

/// Flatten an elliptical arc to line segments
/// SVG arc parameters: rx, ry, x_rotation (degrees), large_arc, sweep, end_x, end_y
pub fn flattenArc(
    allocator: std.mem.Allocator,
    start: Vec2,
    rx_in: f32,
    ry_in: f32,
    x_rotation_deg: f32,
    large_arc: bool,
    sweep: bool,
    end: Vec2,
    tolerance: f32,
    output: *std.ArrayList(Vec2),
) !void {
    // Handle degenerate cases
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);

    if (rx < 0.001 or ry < 0.001) {
        try output.append(allocator, end);
        return;
    }

    const dx = (start.x - end.x) / 2.0;
    const dy = (start.y - end.y) / 2.0;

    if (@abs(dx) < 0.001 and @abs(dy) < 0.001) {
        return;
    }

    // Convert rotation to radians
    const phi = x_rotation_deg * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    // Transform to unit circle space
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    // Correct radii if necessary (SVG spec F.6.6)
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1.0) {
        const sqrt_lambda = @sqrt(lambda);
        rx *= sqrt_lambda;
        ry *= sqrt_lambda;
    }

    // Compute center point (SVG spec F.6.5)
    const rx_sq = rx * rx;
    const ry_sq = ry * ry;
    const x1p_sq = x1p * x1p;
    const y1p_sq = y1p * y1p;

    var sq = (rx_sq * ry_sq - rx_sq * y1p_sq - ry_sq * x1p_sq) / (rx_sq * y1p_sq + ry_sq * x1p_sq);
    if (sq < 0) sq = 0;
    var coef = @sqrt(sq);
    if (large_arc == sweep) coef = -coef;

    const cxp = coef * rx * y1p / ry;
    const cyp = -coef * ry * x1p / rx;

    const cx = cos_phi * cxp - sin_phi * cyp + (start.x + end.x) / 2.0;
    const cy = sin_phi * cxp + cos_phi * cyp + (start.y + end.y) / 2.0;

    // Compute start and end angles
    const ux = (x1p - cxp) / rx;
    const uy = (y1p - cyp) / ry;
    const vx = (-x1p - cxp) / rx;
    const vy = (-y1p - cyp) / ry;

    const n = @sqrt(ux * ux + uy * uy);
    var theta1 = std.math.acos(std.math.clamp(ux / n, -1.0, 1.0));
    if (uy < 0) theta1 = -theta1;

    const dot = ux * vx + uy * vy;
    const det = ux * vy - uy * vx;
    const n2 = @sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    var dtheta = std.math.acos(std.math.clamp(dot / n2, -1.0, 1.0));
    if (det < 0) dtheta = -dtheta;

    if (sweep and dtheta < 0) dtheta += 2.0 * std.math.pi;
    if (!sweep and dtheta > 0) dtheta -= 2.0 * std.math.pi;

    // Flatten arc to line segments
    const num_segments: u32 = @max(4, @as(u32, @intFromFloat(@ceil(@abs(dtheta) / (std.math.pi / 8.0) * @max(rx, ry) / tolerance))));
    const step = dtheta / @as(f32, @floatFromInt(num_segments));

    var i: u32 = 1;
    while (i <= num_segments) : (i += 1) {
        const theta = theta1 + step * @as(f32, @floatFromInt(i));
        const cos_t = @cos(theta);
        const sin_t = @sin(theta);

        const px = cos_phi * rx * cos_t - sin_phi * ry * sin_t + cx;
        const py = sin_phi * rx * cos_t + cos_phi * ry * sin_t + cy;

        try output.append(allocator, Vec2.init(px, py));
    }
}

/// Polygon slice for tessellation
pub const IndexSlice = struct {
    start: u32,
    end: u32,
};

/// Parsed SVG Path - ready for flattening/tessellation
pub const SvgPath = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(PathCommand) = .{},
    data: std.ArrayListUnmanaged(f32) = .{},

    pub fn init(allocator: std.mem.Allocator) SvgPath {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SvgPath) void {
        self.commands.deinit(self.allocator);
        self.data.deinit(self.allocator);
    }

    pub fn clear(self: *SvgPath) void {
        self.commands.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
    }
};

/// SVG Path Parser
pub const PathParser = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    const delimiters = " ,\r\n\t";

    pub fn init(allocator: std.mem.Allocator) PathParser {
        return .{
            .allocator = allocator,
            .src = "",
            .pos = 0,
        };
    }

    pub fn parse(self: *PathParser, path: *SvgPath, src: []const u8) !void {
        self.src = src;
        self.pos = 0;
        path.clear();

        while (!self.atEnd()) {
            self.skipDelimiters();
            if (self.atEnd()) break;

            const ch = self.peek();
            if (!std.ascii.isAlphabetic(ch)) {
                return error.InvalidPathCommand;
            }
            self.advance();

            switch (ch) {
                'M' => try self.parseMoveTo(path, false),
                'm' => try self.parseMoveTo(path, true),
                'L' => try self.parseLineTo(path, false),
                'l' => try self.parseLineTo(path, true),
                'H' => try self.parseHorzLineTo(path, false),
                'h' => try self.parseHorzLineTo(path, true),
                'V' => try self.parseVertLineTo(path, false),
                'v' => try self.parseVertLineTo(path, true),
                'C' => try self.parseCurveTo(path, false),
                'c' => try self.parseCurveTo(path, true),
                'S' => try self.parseSmoothCurveTo(path, false),
                's' => try self.parseSmoothCurveTo(path, true),
                // Quadratic Bezier
                'Q' => try self.parseQuadTo(path, false),
                'q' => try self.parseQuadTo(path, true),
                'T' => try self.parseSmoothQuadTo(path, false),
                't' => try self.parseSmoothQuadTo(path, true),
                // Arc
                'A' => try self.parseArcTo(path, false),
                'a' => try self.parseArcTo(path, true),
                'Z', 'z' => try path.commands.append(self.allocator, .close_path),
                else => return error.UnsupportedPathCommand,
            }
        }
    }

    fn parseMoveTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        const x = try self.parseFloat();
        const y = try self.parseFloat();
        try path.commands.append(self.allocator, if (relative) .move_to_rel else .move_to);
        try path.data.append(self.allocator, x);
        try path.data.append(self.allocator, y);

        // Subsequent coordinates are implicit LineTo
        while (self.hasMoreNumbers()) {
            const lx = try self.parseFloat();
            const ly = try self.parseFloat();
            try path.commands.append(self.allocator, if (relative) .line_to_rel else .line_to);
            try path.data.append(self.allocator, lx);
            try path.data.append(self.allocator, ly);
        }
    }

    fn parseLineTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        while (self.hasMoreNumbers()) {
            const x = try self.parseFloat();
            const y = try self.parseFloat();
            try path.commands.append(self.allocator, if (relative) .line_to_rel else .line_to);
            try path.data.append(self.allocator, x);
            try path.data.append(self.allocator, y);
        }
    }

    fn parseHorzLineTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        const x = try self.parseFloat();
        try path.commands.append(self.allocator, if (relative) .horiz_line_to_rel else .horiz_line_to);
        try path.data.append(self.allocator, x);
    }

    fn parseVertLineTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        const y = try self.parseFloat();
        try path.commands.append(self.allocator, if (relative) .vert_line_to_rel else .vert_line_to);
        try path.data.append(self.allocator, y);
    }

    fn parseCurveTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        while (self.hasMoreNumbers()) {
            const cx0 = try self.parseFloat();
            const cy0 = try self.parseFloat();
            const cx1 = try self.parseFloat();
            const cy1 = try self.parseFloat();
            const x = try self.parseFloat();
            const y = try self.parseFloat();
            try path.commands.append(self.allocator, if (relative) .curve_to_rel else .curve_to);
            try path.data.appendSlice(self.allocator, &.{ cx0, cy0, cx1, cy1, x, y });
        }
    }

    fn parseSmoothCurveTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        while (self.hasMoreNumbers()) {
            const cx1 = try self.parseFloat();
            const cy1 = try self.parseFloat();
            const x = try self.parseFloat();
            const y = try self.parseFloat();
            try path.commands.append(self.allocator, if (relative) .smooth_curve_to_rel else .smooth_curve_to);
            try path.data.appendSlice(self.allocator, &.{ cx1, cy1, x, y });
        }
    }

    fn parseQuadTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        while (self.hasMoreNumbers()) {
            const cx = try self.parseFloat();
            const cy = try self.parseFloat();
            const x = try self.parseFloat();
            const y = try self.parseFloat();
            try path.commands.append(self.allocator, if (relative) .quad_to_rel else .quad_to);
            try path.data.appendSlice(self.allocator, &.{ cx, cy, x, y });
        }
    }

    fn parseSmoothQuadTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        while (self.hasMoreNumbers()) {
            const x = try self.parseFloat();
            const y = try self.parseFloat();
            try path.commands.append(self.allocator, if (relative) .smooth_quad_to_rel else .smooth_quad_to);
            try path.data.appendSlice(self.allocator, &.{ x, y });
        }
    }

    fn parseArcTo(self: *PathParser, path: *SvgPath, relative: bool) !void {
        while (self.hasMoreNumbers()) {
            const rx = try self.parseFloat();
            const ry = try self.parseFloat();
            const x_rotation = try self.parseFloat();
            const large_arc = try self.parseFlag();
            const sweep = try self.parseFlag();
            const x = try self.parseFloat();
            const y = try self.parseFloat();
            try path.commands.append(self.allocator, if (relative) .arc_to_rel else .arc_to);
            // Pack flags as 0/1 floats for uniform data storage
            try path.data.appendSlice(self.allocator, &.{
                rx,
                ry,
                x_rotation,
                if (large_arc) @as(f32, 1.0) else @as(f32, 0.0),
                if (sweep) @as(f32, 1.0) else @as(f32, 0.0),
                x,
                y,
            });
        }
    }

    fn parseFlag(self: *PathParser) !bool {
        self.skipDelimiters();
        if (self.atEnd()) return error.UnexpectedEndOfPath;
        const c = self.peek();
        self.advance();
        return c == '1';
    }

    fn parseFloat(self: *PathParser) !f32 {
        self.skipDelimiters();
        if (self.atEnd()) return error.UnexpectedEndOfPath;

        const start = self.pos;
        var has_dot = false;

        // Handle negative sign
        if (self.peek() == '-') {
            self.advance();
        }

        while (!self.atEnd()) {
            const c = self.peek();
            if (std.ascii.isDigit(c)) {
                self.advance();
            } else if (c == '.' and !has_dot) {
                has_dot = true;
                self.advance();
            } else {
                break;
            }
        }

        if (self.pos == start) return error.ExpectedNumber;
        return std.fmt.parseFloat(f32, self.src[start..self.pos]) catch error.InvalidNumber;
    }

    fn hasMoreNumbers(self: *PathParser) bool {
        self.skipDelimiters();
        if (self.atEnd()) return false;
        const c = self.peek();
        return std.ascii.isDigit(c) or c == '-' or c == '.';
    }

    fn skipDelimiters(self: *PathParser) void {
        while (!self.atEnd() and std.mem.indexOfScalar(u8, delimiters, self.peek()) != null) {
            self.advance();
        }
    }

    fn atEnd(self: *PathParser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *PathParser) u8 {
        return self.src[self.pos];
    }

    fn advance(self: *PathParser) void {
        self.pos += 1;
    }
};

/// Flatten an SVG path into polygons (lists of Vec2 points)
pub fn flattenPath(
    allocator: std.mem.Allocator,
    path: *const SvgPath,
    tolerance: f32,
    points: *std.ArrayList(Vec2),
    polygons: *std.ArrayList(IndexSlice),
) !void {
    var cur_pt = Vec2.init(0, 0);
    var poly_start: u32 = @intCast(points.items.len);
    var data_idx: usize = 0;
    var last_control_pt = Vec2.init(0, 0);
    var last_was_curve = false;
    var last_was_quad = false;

    for (path.commands.items) |cmd| {
        var is_curve = false;
        var is_quad = false;

        switch (cmd) {
            .move_to => {
                // Close previous polygon if any
                if (points.items.len > poly_start + 1) {
                    try polygons.append(allocator, .{ .start = poly_start, .end = @intCast(points.items.len) });
                }
                cur_pt = Vec2.init(path.data.items[data_idx], path.data.items[data_idx + 1]);
                data_idx += 2;
                poly_start = @intCast(points.items.len);
                try points.append(allocator, cur_pt);
            },
            .move_to_rel => {
                if (points.items.len > poly_start + 1) {
                    try polygons.append(allocator, .{ .start = poly_start, .end = @intCast(points.items.len) });
                }
                cur_pt = cur_pt.add(Vec2.init(path.data.items[data_idx], path.data.items[data_idx + 1]));
                data_idx += 2;
                poly_start = @intCast(points.items.len);
                try points.append(allocator, cur_pt);
            },
            .line_to => {
                cur_pt = Vec2.init(path.data.items[data_idx], path.data.items[data_idx + 1]);
                data_idx += 2;
                try points.append(allocator, cur_pt);
            },
            .line_to_rel => {
                cur_pt = cur_pt.add(Vec2.init(path.data.items[data_idx], path.data.items[data_idx + 1]));
                data_idx += 2;
                try points.append(allocator, cur_pt);
            },
            .horiz_line_to => {
                cur_pt.x = path.data.items[data_idx];
                data_idx += 1;
                try points.append(allocator, cur_pt);
            },
            .horiz_line_to_rel => {
                cur_pt.x += path.data.items[data_idx];
                data_idx += 1;
                try points.append(allocator, cur_pt);
            },
            .vert_line_to => {
                cur_pt.y = path.data.items[data_idx];
                data_idx += 1;
                try points.append(allocator, cur_pt);
            },
            .vert_line_to_rel => {
                cur_pt.y += path.data.items[data_idx];
                data_idx += 1;
                try points.append(allocator, cur_pt);
            },
            .curve_to => {
                const cx0 = path.data.items[data_idx];
                const cy0 = path.data.items[data_idx + 1];
                const cx1 = path.data.items[data_idx + 2];
                const cy1 = path.data.items[data_idx + 3];
                const x = path.data.items[data_idx + 4];
                const y = path.data.items[data_idx + 5];
                data_idx += 6;

                const bez = CubicBez{
                    .x0 = cur_pt.x,
                    .y0 = cur_pt.y,
                    .cx0 = cx0,
                    .cy0 = cy0,
                    .cx1 = cx1,
                    .cy1 = cy1,
                    .x1 = x,
                    .y1 = y,
                };
                try bez.flatten(tolerance, allocator, points);
                last_control_pt = Vec2.init(cx1, cy1);
                cur_pt = Vec2.init(x, y);
                is_curve = true;
            },
            .curve_to_rel => {
                const cx0 = cur_pt.x + path.data.items[data_idx];
                const cy0 = cur_pt.y + path.data.items[data_idx + 1];
                const cx1 = cur_pt.x + path.data.items[data_idx + 2];
                const cy1 = cur_pt.y + path.data.items[data_idx + 3];
                const x = cur_pt.x + path.data.items[data_idx + 4];
                const y = cur_pt.y + path.data.items[data_idx + 5];
                data_idx += 6;

                const bez = CubicBez{
                    .x0 = cur_pt.x,
                    .y0 = cur_pt.y,
                    .cx0 = cx0,
                    .cy0 = cy0,
                    .cx1 = cx1,
                    .cy1 = cy1,
                    .x1 = x,
                    .y1 = y,
                };
                try bez.flatten(tolerance, allocator, points);
                last_control_pt = Vec2.init(cx1, cy1);
                cur_pt = Vec2.init(x, y);
                is_curve = true;
            },
            .smooth_curve_to => {
                var cx0: f32 = cur_pt.x;
                var cy0: f32 = cur_pt.y;
                if (last_was_curve) {
                    cx0 = cur_pt.x + (cur_pt.x - last_control_pt.x);
                    cy0 = cur_pt.y + (cur_pt.y - last_control_pt.y);
                }
                const cx1 = path.data.items[data_idx];
                const cy1 = path.data.items[data_idx + 1];
                const x = path.data.items[data_idx + 2];
                const y = path.data.items[data_idx + 3];
                data_idx += 4;

                const bez = CubicBez{
                    .x0 = cur_pt.x,
                    .y0 = cur_pt.y,
                    .cx0 = cx0,
                    .cy0 = cy0,
                    .cx1 = cx1,
                    .cy1 = cy1,
                    .x1 = x,
                    .y1 = y,
                };
                try bez.flatten(tolerance, allocator, points);
                last_control_pt = Vec2.init(cx1, cy1);
                cur_pt = Vec2.init(x, y);
                is_curve = true;
            },
            .smooth_curve_to_rel => {
                var cx0: f32 = cur_pt.x;
                var cy0: f32 = cur_pt.y;
                if (last_was_curve) {
                    cx0 = cur_pt.x + (cur_pt.x - last_control_pt.x);
                    cy0 = cur_pt.y + (cur_pt.y - last_control_pt.y);
                }
                const cx1 = cur_pt.x + path.data.items[data_idx];
                const cy1 = cur_pt.y + path.data.items[data_idx + 1];
                const x = cur_pt.x + path.data.items[data_idx + 2];
                const y = cur_pt.y + path.data.items[data_idx + 3];
                data_idx += 4;

                const bez = CubicBez{
                    .x0 = cur_pt.x,
                    .y0 = cur_pt.y,
                    .cx0 = cx0,
                    .cy0 = cy0,
                    .cx1 = cx1,
                    .cy1 = cy1,
                    .x1 = x,
                    .y1 = y,
                };
                try bez.flatten(tolerance, allocator, points);
                last_control_pt = Vec2.init(cx1, cy1);
                cur_pt = Vec2.init(x, y);
                is_curve = true;
            },
            .quad_to => {
                const cx = path.data.items[data_idx];
                const cy = path.data.items[data_idx + 1];
                const x = path.data.items[data_idx + 2];
                const y = path.data.items[data_idx + 3];
                data_idx += 4;

                const quad = QuadraticBez{
                    .x0 = cur_pt.x,
                    .y0 = cur_pt.y,
                    .cx = cx,
                    .cy = cy,
                    .x1 = x,
                    .y1 = y,
                };
                try quad.flatten(tolerance, allocator, points);
                last_control_pt = Vec2.init(cx, cy);
                cur_pt = Vec2.init(x, y);
                is_quad = true;
            },
            .quad_to_rel => {
                const cx = cur_pt.x + path.data.items[data_idx];
                const cy = cur_pt.y + path.data.items[data_idx + 1];
                const x = cur_pt.x + path.data.items[data_idx + 2];
                const y = cur_pt.y + path.data.items[data_idx + 3];
                data_idx += 4;

                const quad = QuadraticBez{
                    .x0 = cur_pt.x,
                    .y0 = cur_pt.y,
                    .cx = cx,
                    .cy = cy,
                    .x1 = x,
                    .y1 = y,
                };
                try quad.flatten(tolerance, allocator, points);
                last_control_pt = Vec2.init(cx, cy);
                cur_pt = Vec2.init(x, y);
                is_quad = true;
            },
            .smooth_quad_to => {
                var cx = cur_pt.x;
                var cy = cur_pt.y;
                if (last_was_quad) {
                    cx = cur_pt.x + (cur_pt.x - last_control_pt.x);
                    cy = cur_pt.y + (cur_pt.y - last_control_pt.y);
                }
                const x = path.data.items[data_idx];
                const y = path.data.items[data_idx + 1];
                data_idx += 2;

                const quad = QuadraticBez{
                    .x0 = cur_pt.x,
                    .y0 = cur_pt.y,
                    .cx = cx,
                    .cy = cy,
                    .x1 = x,
                    .y1 = y,
                };
                try quad.flatten(tolerance, allocator, points);
                last_control_pt = Vec2.init(cx, cy);
                cur_pt = Vec2.init(x, y);
                is_quad = true;
            },
            .smooth_quad_to_rel => {
                var cx = cur_pt.x;
                var cy = cur_pt.y;
                if (last_was_quad) {
                    cx = cur_pt.x + (cur_pt.x - last_control_pt.x);
                    cy = cur_pt.y + (cur_pt.y - last_control_pt.y);
                }
                const x = cur_pt.x + path.data.items[data_idx];
                const y = cur_pt.y + path.data.items[data_idx + 1];
                data_idx += 2;

                const quad = QuadraticBez{
                    .x0 = cur_pt.x,
                    .y0 = cur_pt.y,
                    .cx = cx,
                    .cy = cy,
                    .x1 = x,
                    .y1 = y,
                };
                try quad.flatten(tolerance, allocator, points);
                last_control_pt = Vec2.init(cx, cy);
                cur_pt = Vec2.init(x, y);
                is_quad = true;
            },
            .arc_to => {
                const rx = path.data.items[data_idx];
                const ry = path.data.items[data_idx + 1];
                const x_rot = path.data.items[data_idx + 2];
                const large_arc = path.data.items[data_idx + 3] > 0.5;
                const sweep = path.data.items[data_idx + 4] > 0.5;
                const x = path.data.items[data_idx + 5];
                const y = path.data.items[data_idx + 6];
                data_idx += 7;

                try flattenArc(allocator, cur_pt, rx, ry, x_rot, large_arc, sweep, Vec2.init(x, y), tolerance, points);
                cur_pt = Vec2.init(x, y);
            },
            .arc_to_rel => {
                const rx = path.data.items[data_idx];
                const ry = path.data.items[data_idx + 1];
                const x_rot = path.data.items[data_idx + 2];
                const large_arc = path.data.items[data_idx + 3] > 0.5;
                const sweep = path.data.items[data_idx + 4] > 0.5;
                const x = cur_pt.x + path.data.items[data_idx + 5];
                const y = cur_pt.y + path.data.items[data_idx + 6];
                data_idx += 7;

                try flattenArc(allocator, cur_pt, rx, ry, x_rot, large_arc, sweep, Vec2.init(x, y), tolerance, points);
                cur_pt = Vec2.init(x, y);
            },
            .close_path => {
                // Close path is implicit for fill operations
            },
        }
        last_was_curve = is_curve;
        last_was_quad = is_quad;
    }

    // Final polygon
    if (points.items.len > poly_start + 1) {
        try polygons.append(allocator, .{ .start = poly_start, .end = @intCast(points.items.len) });
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parse simple path" {
    const allocator = std.testing.allocator;
    var parser = PathParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "M10 20 L30 40 Z");

    try std.testing.expectEqual(@as(usize, 3), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[2]);
}

test "flatten simple triangle" {
    const allocator = std.testing.allocator;
    var parser = PathParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "M0 0 L100 0 L50 100 Z");

    var points = std.ArrayList(Vec2).init(allocator);
    defer points.deinit();
    var polygons = std.ArrayList(IndexSlice).init(allocator);
    defer polygons.deinit();

    try flattenPath(allocator, &path, 0.5, &points, &polygons);

    try std.testing.expectEqual(@as(usize, 1), polygons.items.len);
    try std.testing.expectEqual(@as(usize, 3), points.items.len);
}

test "parse quadratic bezier" {
    const allocator = std.testing.allocator;
    var parser = PathParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "M0 0 Q50 100 100 0");

    try std.testing.expectEqual(@as(usize, 2), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.quad_to, path.commands.items[1]);
}

test "parse smooth quadratic" {
    const allocator = std.testing.allocator;
    var parser = PathParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "M0 0 Q25 50 50 0 T100 0");

    try std.testing.expectEqual(@as(usize, 3), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.smooth_quad_to, path.commands.items[2]);
}

test "parse arc command" {
    const allocator = std.testing.allocator;
    var parser = PathParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "M10 10 A5 5 0 0 1 20 20");

    try std.testing.expectEqual(@as(usize, 2), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[1]);
    // Check arc data: rx, ry, rotation, large_arc, sweep, x, y
    try std.testing.expectEqual(@as(f32, 5), path.data.items[2]); // rx
    try std.testing.expectEqual(@as(f32, 5), path.data.items[3]); // ry
}

test "flatten arc" {
    const allocator = std.testing.allocator;
    var points = std.ArrayList(Vec2).init(allocator);
    defer points.deinit();

    // Semi-circle arc
    try flattenArc(allocator, Vec2.init(0, 0), 50, 50, 0, false, true, Vec2.init(100, 0), 1.0, &points);

    // Should have generated multiple points
    try std.testing.expect(points.items.len >= 4);
    // End point should be close to target
    const last = points.items[points.items.len - 1];
    try std.testing.expect(@abs(last.x - 100) < 0.1);
    try std.testing.expect(@abs(last.y - 0) < 0.1);
}
