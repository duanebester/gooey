const std = @import("std");
const vec2_mod = @import("../geometry/vec2.zig");
const limits = @import("../core/limits.zig");

const assert = std.debug.assert;

pub const Vec2 = vec2_mod.Vec2;

pub const IndexSlice = vec2_mod.IndexSlice;

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
    quad_to,
    quad_to_rel,
    smooth_quad_to,
    smooth_quad_to_rel,
    arc_to,
    arc_to_rel,
    close_path,
};

pub const CubicBez = struct {
    x0: f32,
    y0: f32,
    cx0: f32,
    cy0: f32,
    cx1: f32,
    cy1: f32,
    x1: f32,
    y1: f32,

    pub fn flatten(self: CubicBez, tolerance: f32, allocator: std.mem.Allocator, output: *std.ArrayList(Vec2)) !void {
        try self.flattenRecursive(tolerance, allocator, output, 0);
    }

    fn flattenRecursive(self: CubicBez, tolerance: f32, allocator: std.mem.Allocator, output: *std.ArrayList(Vec2), depth: u32) !void {
        if (depth > 16) {
            try output.append(allocator, Vec2.init(self.x1, self.y1));
            return;
        }

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

pub const QuadraticBez = struct {
    x0: f32,
    y0: f32,
    cx: f32,
    cy: f32,
    x1: f32,
    y1: f32,

    pub fn flatten(self: QuadraticBez, tolerance: f32, allocator: std.mem.Allocator, output: *std.ArrayList(Vec2)) !void {
        try self.flattenRecursive(tolerance, allocator, output, 0);
    }

    fn flattenRecursive(self: QuadraticBez, tolerance: f32, allocator: std.mem.Allocator, output: *std.ArrayList(Vec2), depth: u32) !void {
        if (depth > 16) {
            try output.append(allocator, Vec2.init(self.x1, self.y1));
            return;
        }

        const dx = self.x1 - self.x0;
        const dy = self.y1 - self.y0;
        const d = @abs((self.cx - self.x1) * dy - (self.cy - self.y1) * dx);
        const len_sq = dx * dx + dy * dy;

        if (d * d <= tolerance * tolerance * len_sq) {
            try output.append(allocator, Vec2.init(self.x1, self.y1));
            return;
        }

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

    const phi = x_rotation_deg * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1.0) {
        const sqrt_lambda = @sqrt(lambda);
        rx *= sqrt_lambda;
        ry *= sqrt_lambda;
    }

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

pub const SvgPath = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(PathCommand) = .empty,
    data: std.ArrayListUnmanaged(f32) = .empty,

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
        path.clear();
        try self.appendPath(path, src);
    }

    pub fn appendPath(self: *PathParser, path: *SvgPath, src: []const u8) !void {
        self.src = src;
        self.pos = 0;

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
                'Q' => try self.parseQuadTo(path, false),
                'q' => try self.parseQuadTo(path, true),
                'T' => try self.parseSmoothQuadTo(path, false),
                't' => try self.parseSmoothQuadTo(path, true),
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
        var has_digits = false;

        if (self.peek() == '-' or self.peek() == '+') {
            self.advance();
        }

        while (!self.atEnd()) {
            const c = self.peek();
            if (std.ascii.isDigit(c)) {
                has_digits = true;
                self.advance();
            } else if (c == '.' and !has_dot) {
                has_dot = true;
                self.advance();
            } else if ((c == '-' or c == '+') and has_digits) {
                break;
            } else {
                break;
            }
        }

        if (self.pos == start or !has_digits) return error.ExpectedNumber;
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

pub const SvgElementParser = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .src = "",
            .pos = 0,
        };
    }

    pub fn parse(self: *Self, path: *SvgPath, src: []const u8) !void {
        self.src = src;
        self.pos = 0;
        path.clear();

        self.skipWhitespace();
        if (self.atEnd()) return;

        if (self.peek() == '<') {
            while (!self.atEnd()) {
                self.skipWhitespace();
                if (self.atEnd()) break;

                if (self.peek() == '<') {
                    try self.parseElement(path);
                } else {
                    break;
                }
            }
        } else {
            var path_parser = PathParser.init(self.allocator);
            try path_parser.parse(path, src);
        }
    }

    fn parseElement(self: *Self, path: *SvgPath) !void {
        if (!self.consume('<')) return error.InvalidElement;

        self.skipWhitespace();

        const name_start = self.pos;
        while (!self.atEnd() and !std.ascii.isWhitespace(self.peek()) and self.peek() != '>' and self.peek() != '/') {
            self.advance();
        }
        const element_name = self.src[name_start..self.pos];

        if (std.mem.eql(u8, element_name, "circle")) {
            try self.parseCircle(path);
        } else if (std.mem.eql(u8, element_name, "ellipse")) {
            try self.parseEllipse(path);
        } else if (std.mem.eql(u8, element_name, "rect")) {
            try self.parseRect(path);
        } else if (std.mem.eql(u8, element_name, "line")) {
            try self.parseLine(path);
        } else if (std.mem.eql(u8, element_name, "polyline")) {
            try self.parsePolyline(path, false);
        } else if (std.mem.eql(u8, element_name, "polygon")) {
            try self.parsePolyline(path, true);
        } else if (std.mem.eql(u8, element_name, "path")) {
            try self.parsePath(path);
        } else {
            self.skipToElementEnd();
        }
    }

    fn parseCircle(self: *Self, path: *SvgPath) !void {
        var cx: f32 = 0;
        var cy: f32 = 0;
        var r: f32 = 0;

        while (!self.atEnd()) {
            self.skipWhitespace();
            const c = self.peek();
            if (c == '/' or c == '>') break;

            const attr = self.parseAttribute() orelse continue;
            if (std.mem.eql(u8, attr.name, "cx")) {
                cx = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "cy")) {
                cy = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "r")) {
                r = self.parseAttrFloat(attr.value);
            }
        }
        self.skipToElementEnd();

        if (r <= 0) return;

        try path.commands.append(self.allocator, .move_to);
        try path.data.appendSlice(self.allocator, &.{ cx + r, cy });

        try path.commands.append(self.allocator, .arc_to);
        try path.data.appendSlice(self.allocator, &.{ r, r, 0, 1, 1, cx - r, cy });

        try path.commands.append(self.allocator, .arc_to);
        try path.data.appendSlice(self.allocator, &.{ r, r, 0, 1, 1, cx + r, cy });

        try path.commands.append(self.allocator, .close_path);
    }

    fn parseEllipse(self: *Self, path: *SvgPath) !void {
        var cx: f32 = 0;
        var cy: f32 = 0;
        var rx: f32 = 0;
        var ry: f32 = 0;

        while (!self.atEnd()) {
            self.skipWhitespace();
            const c = self.peek();
            if (c == '/' or c == '>') break;

            const attr = self.parseAttribute() orelse continue;
            if (std.mem.eql(u8, attr.name, "cx")) {
                cx = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "cy")) {
                cy = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "rx")) {
                rx = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "ry")) {
                ry = self.parseAttrFloat(attr.value);
            }
        }
        self.skipToElementEnd();

        if (rx <= 0 or ry <= 0) return;

        try path.commands.append(self.allocator, .move_to);
        try path.data.appendSlice(self.allocator, &.{ cx + rx, cy });

        try path.commands.append(self.allocator, .arc_to);
        try path.data.appendSlice(self.allocator, &.{ rx, ry, 0, 1, 1, cx - rx, cy });

        try path.commands.append(self.allocator, .arc_to);
        try path.data.appendSlice(self.allocator, &.{ rx, ry, 0, 1, 1, cx + rx, cy });

        try path.commands.append(self.allocator, .close_path);
    }

    fn parseRect(self: *Self, path: *SvgPath) !void {
        var x: f32 = 0;
        var y: f32 = 0;
        var width: f32 = 0;
        var height: f32 = 0;
        var rx: f32 = 0;
        var ry: f32 = 0;

        while (!self.atEnd()) {
            self.skipWhitespace();
            const c = self.peek();
            if (c == '/' or c == '>') break;

            const attr = self.parseAttribute() orelse continue;
            if (std.mem.eql(u8, attr.name, "x")) {
                x = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "y")) {
                y = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "width")) {
                width = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "height")) {
                height = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "rx")) {
                rx = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "ry")) {
                ry = self.parseAttrFloat(attr.value);
            }
        }
        self.skipToElementEnd();

        if (width <= 0 or height <= 0) return;

        if (rx > 0 and ry == 0) ry = rx;
        if (ry > 0 and rx == 0) rx = ry;

        rx = @min(rx, width / 2);
        ry = @min(ry, height / 2);

        if (rx > 0 and ry > 0) {
            try path.commands.append(self.allocator, .move_to);
            try path.data.appendSlice(self.allocator, &.{ x + rx, y });

            try path.commands.append(self.allocator, .line_to);
            try path.data.appendSlice(self.allocator, &.{ x + width - rx, y });

            try path.commands.append(self.allocator, .arc_to);
            try path.data.appendSlice(self.allocator, &.{ rx, ry, 0, 0, 1, x + width, y + ry });

            try path.commands.append(self.allocator, .line_to);
            try path.data.appendSlice(self.allocator, &.{ x + width, y + height - ry });

            try path.commands.append(self.allocator, .arc_to);
            try path.data.appendSlice(self.allocator, &.{ rx, ry, 0, 0, 1, x + width - rx, y + height });

            try path.commands.append(self.allocator, .line_to);
            try path.data.appendSlice(self.allocator, &.{ x + rx, y + height });

            try path.commands.append(self.allocator, .arc_to);
            try path.data.appendSlice(self.allocator, &.{ rx, ry, 0, 0, 1, x, y + height - ry });

            try path.commands.append(self.allocator, .line_to);
            try path.data.appendSlice(self.allocator, &.{ x, y + ry });

            try path.commands.append(self.allocator, .arc_to);
            try path.data.appendSlice(self.allocator, &.{ rx, ry, 0, 0, 1, x + rx, y });

            try path.commands.append(self.allocator, .close_path);
        } else {
            try path.commands.append(self.allocator, .move_to);
            try path.data.appendSlice(self.allocator, &.{ x, y });

            try path.commands.append(self.allocator, .line_to);
            try path.data.appendSlice(self.allocator, &.{ x + width, y });

            try path.commands.append(self.allocator, .line_to);
            try path.data.appendSlice(self.allocator, &.{ x + width, y + height });

            try path.commands.append(self.allocator, .line_to);
            try path.data.appendSlice(self.allocator, &.{ x, y + height });

            try path.commands.append(self.allocator, .close_path);
        }
    }

    fn parseLine(self: *Self, path: *SvgPath) !void {
        var x1: f32 = 0;
        var y1: f32 = 0;
        var x2: f32 = 0;
        var y2: f32 = 0;

        while (!self.atEnd()) {
            self.skipWhitespace();
            const c = self.peek();
            if (c == '/' or c == '>') break;

            const attr = self.parseAttribute() orelse continue;
            if (std.mem.eql(u8, attr.name, "x1")) {
                x1 = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "y1")) {
                y1 = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "x2")) {
                x2 = self.parseAttrFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "y2")) {
                y2 = self.parseAttrFloat(attr.value);
            }
        }
        self.skipToElementEnd();

        try path.commands.append(self.allocator, .move_to);
        try path.data.appendSlice(self.allocator, &.{ x1, y1 });

        try path.commands.append(self.allocator, .line_to);
        try path.data.appendSlice(self.allocator, &.{ x2, y2 });
    }

    fn parsePolyline(self: *Self, path: *SvgPath, close: bool) !void {
        var points_str: []const u8 = "";

        while (!self.atEnd()) {
            self.skipWhitespace();
            const c = self.peek();
            if (c == '/' or c == '>') break;

            const attr = self.parseAttribute() orelse continue;
            if (std.mem.eql(u8, attr.name, "points")) {
                points_str = attr.value;
            }
        }
        self.skipToElementEnd();

        if (points_str.len == 0) return;

        var points_parser = PointsParser.init(points_str);
        var first = true;

        while (points_parser.nextPoint()) |pt| {
            if (first) {
                try path.commands.append(self.allocator, .move_to);
                first = false;
            } else {
                try path.commands.append(self.allocator, .line_to);
            }
            try path.data.appendSlice(self.allocator, &.{ pt.x, pt.y });
        }

        if (close and !first) {
            try path.commands.append(self.allocator, .close_path);
        }
    }

    fn parsePath(self: *Self, path: *SvgPath) !void {
        var d_attr: []const u8 = "";

        while (!self.atEnd()) {
            self.skipWhitespace();
            const c = self.peek();
            if (c == '/' or c == '>') break;

            const attr = self.parseAttribute() orelse continue;
            if (std.mem.eql(u8, attr.name, "d")) {
                d_attr = attr.value;
            }
        }
        self.skipToElementEnd();

        if (d_attr.len == 0) return;

        const cmd_count_before = path.commands.items.len;

        var path_parser = PathParser.init(self.allocator);
        path_parser.appendPath(path, d_attr) catch {};

        if (path.commands.items.len > cmd_count_before) {
            if (path.commands.items[cmd_count_before] == .move_to_rel) {
                path.commands.items[cmd_count_before] = .move_to;
            }
        }
    }

    const Attribute = struct {
        name: []const u8,
        value: []const u8,
    };

    fn parseAttribute(self: *Self) ?Attribute {
        self.skipWhitespace();

        const name_start = self.pos;
        while (!self.atEnd()) {
            const c = self.peek();
            if (c == '=' or std.ascii.isWhitespace(c) or c == '/' or c == '>') break;
            self.advance();
        }
        const name = self.src[name_start..self.pos];
        if (name.len == 0) return null;

        self.skipWhitespace();
        if (!self.consume('=')) return null;
        self.skipWhitespace();

        const quote = self.peek();
        if (quote != '"' and quote != '\'') return null;
        self.advance();

        const value_start = self.pos;
        while (!self.atEnd() and self.peek() != quote) {
            self.advance();
        }
        const value = self.src[value_start..self.pos];

        if (!self.atEnd()) self.advance();

        return .{ .name = name, .value = value };
    }

    fn parseAttrFloat(self: *Self, value: []const u8) f32 {
        _ = self;
        return std.fmt.parseFloat(f32, value) catch 0;
    }

    fn skipToElementEnd(self: *Self) void {
        while (!self.atEnd()) {
            const c = self.peek();
            self.advance();
            if (c == '>') break;
        }
    }

    fn skipWhitespace(self: *Self) void {
        while (!self.atEnd() and std.ascii.isWhitespace(self.peek())) {
            self.advance();
        }
    }

    fn consume(self: *Self, expected: u8) bool {
        if (self.atEnd() or self.peek() != expected) return false;
        self.advance();
        return true;
    }

    fn atEnd(self: *const Self) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *const Self) u8 {
        return self.src[self.pos];
    }

    fn advance(self: *Self) void {
        self.pos += 1;
    }
};

const PointsParser = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) PointsParser {
        return .{ .src = src, .pos = 0 };
    }

    fn nextPoint(self: *PointsParser) ?Vec2 {
        self.skipDelimiters();
        if (self.pos >= self.src.len) return null;

        const x = self.parseFloat() orelse return null;
        self.skipDelimiters();
        const y = self.parseFloat() orelse return null;

        return Vec2.init(x, y);
    }

    fn parseFloat(self: *PointsParser) ?f32 {
        self.skipDelimiters();
        if (self.pos >= self.src.len) return null;

        const start = self.pos;

        if (self.pos < self.src.len and self.src[self.pos] == '-') {
            self.pos += 1;
        }

        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
            self.pos += 1;
        }

        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                self.pos += 1;
            }
        }

        if (self.pos == start) return null;
        return std.fmt.parseFloat(f32, self.src[start..self.pos]) catch null;
    }

    fn skipDelimiters(self: *PointsParser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == ',' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }
};

pub fn flattenPath(
    allocator: std.mem.Allocator,
    path: *const SvgPath,
    tolerance: f32,
    points: *std.ArrayList(Vec2),
    polygons: *std.ArrayList(IndexSlice),
) !void {
    var cur_pt = Vec2.init(0, 0);
    var subpath_start_pt = Vec2.init(0, 0);
    var poly_start: u32 = @intCast(points.items.len);
    var data_idx: usize = 0;
    var last_control_pt = Vec2.init(0, 0);
    var last_was_curve = false;
    var last_was_quad = false;
    var current_subpath_closed = false;

    for (path.commands.items) |cmd| {
        var is_curve = false;
        var is_quad = false;

        switch (cmd) {
            .move_to => {
                if (points.items.len > poly_start + 1) {
                    try polygons.append(allocator, .{ .start = poly_start, .end = @intCast(points.items.len), .closed = current_subpath_closed });
                }
                cur_pt = Vec2.init(path.data.items[data_idx], path.data.items[data_idx + 1]);
                data_idx += 2;
                subpath_start_pt = cur_pt;
                poly_start = @intCast(points.items.len);
                current_subpath_closed = false;
                try points.append(allocator, cur_pt);
            },
            .move_to_rel => {
                if (points.items.len > poly_start + 1) {
                    try polygons.append(allocator, .{ .start = poly_start, .end = @intCast(points.items.len), .closed = current_subpath_closed });
                }
                cur_pt = cur_pt.add(Vec2.init(path.data.items[data_idx], path.data.items[data_idx + 1]));
                data_idx += 2;
                subpath_start_pt = cur_pt;
                poly_start = @intCast(points.items.len);
                current_subpath_closed = false;
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
                current_subpath_closed = true;
                cur_pt = subpath_start_pt;
                if (points.items.len > poly_start + 1) {
                    try polygons.append(allocator, .{ .start = poly_start, .end = @intCast(points.items.len), .closed = true });
                }
                poly_start = @intCast(points.items.len);
            },
        }
        last_was_curve = is_curve;
        last_was_quad = is_quad;
    }

    if (points.items.len > poly_start + 1) {
        try polygons.append(allocator, .{ .start = poly_start, .end = @intCast(points.items.len), .closed = current_subpath_closed });
    }
}

pub const RasterBudget = struct {
    path_bytes_max: u32,
    vertex_count_max: u32,

    pub const commands_per_byte: u32 = 1;
    pub const numbers_per_byte: u32 = 2;

    pub const ceiling: RasterBudget = .{
        .path_bytes_max = limits.MAX_SVG_PATH_BYTES,
        .vertex_count_max = limits.MAX_SVG_PATH_VERTEX_COUNT,
    };

    pub fn parseBytes(path_bytes: u32) u32 {
        assert(path_bytes <= limits.MAX_SVG_PATH_BYTES);
        const command_bytes = path_bytes * commands_per_byte * @sizeOf(PathCommand);
        return command_bytes + path_bytes * numbers_per_byte * @sizeOf(f32);
    }

    pub const path_data_number_bytes_max: u32 = 15;

    pub fn pathDataBytes(path_bytes: u32) u32 {
        assert(path_bytes <= limits.MAX_SVG_PATH_BYTES);
        const letter_bytes = path_bytes * commands_per_byte;
        return letter_bytes + path_bytes * numbers_per_byte * (1 + path_data_number_bytes_max);
    }

    pub fn flattenBytes(self: RasterBudget) u32 {
        assert(self.vertex_count_max > 0);
        assert(self.vertex_count_max <= limits.MAX_SVG_PATH_VERTEX_COUNT);
        const polygon_count_max = @divFloor(self.vertex_count_max, 2);
        return self.vertex_count_max * @sizeOf(Vec2) + polygon_count_max * @sizeOf(IndexSlice);
    }
};

const reserved_only: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = std.mem.Allocator.noAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    },
};

pub const BoundedError = error{
    EmptyPath,
    PathTooComplex,
};

pub fn parseBounded(
    scratch: std.mem.Allocator,
    path: *SvgPath,
    source: []const u8,
) BoundedError!void {
    assert(source.len <= limits.MAX_SVG_PATH_BYTES);
    assert(path.commands.capacity == 0);
    assert(path.data.capacity == 0);
    const length: u32 = @intCast(source.len);
    const command_count_max = length * RasterBudget.commands_per_byte;
    const number_count_max = length * RasterBudget.numbers_per_byte;
    path.commands.ensureTotalCapacityPrecise(scratch, command_count_max) catch
        return error.PathTooComplex;
    path.data.ensureTotalCapacityPrecise(scratch, number_count_max) catch
        return error.PathTooComplex;

    var parser = SvgElementParser.init(reserved_only);
    parser.parse(path, source) catch |err| {
        if (err == error.OutOfMemory) return error.PathTooComplex;
        return error.EmptyPath;
    };
    if (path.commands.items.len == 0) return error.EmptyPath;
    assert(path.commands.items.len <= command_count_max);
    assert(path.data.items.len <= number_count_max);
}

pub fn flattenBounded(
    scratch: std.mem.Allocator,
    path: *const SvgPath,
    tolerance: f32,
    points: *std.ArrayList(Vec2),
    polygons: *std.ArrayList(IndexSlice),
    budget: RasterBudget,
) BoundedError!void {
    assert(tolerance > 0);
    assert(points.capacity == 0);
    assert(polygons.capacity == 0);
    const polygon_count_max = @divFloor(budget.vertex_count_max, 2);
    points.ensureTotalCapacityPrecise(scratch, budget.vertex_count_max) catch
        return error.PathTooComplex;
    polygons.ensureTotalCapacityPrecise(scratch, polygon_count_max) catch
        return error.PathTooComplex;

    flattenPath(reserved_only, path, tolerance, points, polygons) catch
        return error.PathTooComplex;
    assert(points.items.len <= budget.vertex_count_max);
    assert(polygons.items.len <= polygon_count_max);
}

pub fn pathDataBounded(
    scratch: std.mem.Allocator,
    source: []const u8,
    buffer: []u8,
) BoundedError![]const u8 {
    assert(source.len <= limits.MAX_SVG_PATH_BYTES);
    assert(buffer.len == RasterBudget.pathDataBytes(@intCast(source.len)));
    var path = SvgPath.init(scratch);
    defer path.deinit();
    try parseBounded(scratch, &path, source);

    const commands = path.commands.items;
    const numbers = path.data.items;
    var number_index: usize = 0;
    var length: usize = 0;
    for (commands) |command| {
        const number_count = pathDataNumberCount(command);
        assert(number_index + number_count <= numbers.len);
        assert(length + 1 <= buffer.len);
        buffer[length] = pathDataLetter(command);
        length += 1;
        for (0..number_count) |position| {
            const number = numbers[number_index + position];
            const is_flag = pathDataIsFlag(command, position);
            length += pathDataWriteNumber(buffer[length..], number, is_flag);
        }
        number_index += number_count;
    }
    assert(number_index == numbers.len);
    assert(length <= buffer.len);
    return buffer[0..length];
}

fn pathDataWriteNumber(buffer: []u8, number: f32, is_flag: bool) usize {
    assert(buffer.len >= 2);
    buffer[0] = ' ';
    if (is_flag) {
        assert(number == 0 or number == 1);
        buffer[1] = if (number == 1) '1' else '0';
        return 2;
    }
    var digits: [std.fmt.float.min_buffer_size]u8 = undefined;
    assert(std.math.isFinite(number));
    const text = std.fmt.float.render(&digits, number, .{
        .mode = .scientific,
        .precision = null,
    }) catch unreachable;
    assert(text.len <= RasterBudget.path_data_number_bytes_max);
    assert(1 + text.len <= buffer.len);
    @memcpy(buffer[1..][0..text.len], text);
    return 1 + text.len;
}

fn pathDataIsFlag(command: PathCommand, position: usize) bool {
    assert(position < pathDataNumberCount(command));
    if (command == .arc_to or command == .arc_to_rel) return position == 3 or position == 4;
    return false;
}

fn pathDataLetter(command: PathCommand) u8 {
    return switch (command) {
        .move_to => 'M',
        .move_to_rel => 'm',
        .line_to => 'L',
        .line_to_rel => 'l',
        .horiz_line_to => 'H',
        .horiz_line_to_rel => 'h',
        .vert_line_to => 'V',
        .vert_line_to_rel => 'v',
        .curve_to => 'C',
        .curve_to_rel => 'c',
        .smooth_curve_to => 'S',
        .smooth_curve_to_rel => 's',
        .quad_to => 'Q',
        .quad_to_rel => 'q',
        .smooth_quad_to => 'T',
        .smooth_quad_to_rel => 't',
        .arc_to => 'A',
        .arc_to_rel => 'a',
        .close_path => 'Z',
    };
}

fn pathDataNumberCount(command: PathCommand) u8 {
    return switch (command) {
        .move_to, .move_to_rel, .line_to, .line_to_rel => 2,
        .smooth_quad_to, .smooth_quad_to_rel => 2,
        .horiz_line_to, .horiz_line_to_rel, .vert_line_to, .vert_line_to_rel => 1,
        .curve_to, .curve_to_rel => 6,
        .smooth_curve_to, .smooth_curve_to_rel, .quad_to, .quad_to_rel => 4,
        .arc_to, .arc_to_rel => 7,
        .close_path => 0,
    };
}

test "flattenBounded fills its vertex budget exactly and refuses one more" {
    const gpa = std.testing.allocator;
    const source = "<circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"M2 2q10 20 20 0\"/>";
    var path = SvgPath.init(gpa);
    defer path.deinit();
    try parseBounded(gpa, &path, source);

    const vertex_count = try testFlattenCount(&path, limits.MAX_SVG_PATH_VERTEX_COUNT);
    try std.testing.expect(vertex_count > 100);
    try std.testing.expectEqual(vertex_count, try testFlattenCount(&path, vertex_count));
    try std.testing.expectError(error.PathTooComplex, testFlattenCount(&path, vertex_count - 1));
}

fn testFlattenCount(path: *const SvgPath, vertex_count_max: u32) BoundedError!u32 {
    const gpa = std.testing.allocator;
    const budget = RasterBudget{
        .path_bytes_max = limits.MAX_SVG_PATH_BYTES,
        .vertex_count_max = vertex_count_max,
    };
    var points: std.ArrayList(Vec2) = .empty;
    defer points.deinit(gpa);
    var polygons: std.ArrayList(IndexSlice) = .empty;
    defer polygons.deinit(gpa);
    defer assert(points.capacity == vertex_count_max);
    try flattenBounded(gpa, path, 0.05, &points, &polygons, budget);
    return @intCast(points.items.len);
}

test "parseBounded rejects empty and unparsable paths without growing" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "   ", "<unknown/>" };
    for (sources) |source| {
        var path = SvgPath.init(gpa);
        defer path.deinit();
        try std.testing.expectError(error.EmptyPath, parseBounded(gpa, &path, source));
        try std.testing.expectEqual(source.len, path.commands.capacity);
    }
}

test "pathDataBounded writes element markup as the path data Path2D draws" {
    const gpa = std.testing.allocator;
    const source = "<path d=\"m14 12 4 4\"/><path d=\"M2 2a5 5 0 0 1 6.5 6z\"/>" ++
        "<line x1=\"1\" y1=\"2\" x2=\"3\" y2=\"4\"/>";
    var buffer: [RasterBudget.pathDataBytes(source.len)]u8 = undefined;
    try std.testing.expectEqualStrings(
        "M 1.4e1 1.2e1l 4e0 4e0M 2e0 2e0a 5e0 5e0 0e0 0 1 6.5e0 6e0ZM 1e0 2e0L 3e0 4e0",
        try pathDataBounded(gpa, source, &buffer),
    );
}

test "pathDataBounded keeps every command and number of a Lucide icon" {
    const gpa = std.testing.allocator;
    const source = "<circle cx=\"12\" cy=\"13\" r=\"8\"/><path d=\"M5 3 2 6\"/>" ++
        "<path d=\"m22 6-3-3\"/><path d=\"M6.38 18.7 4 21\"/><path d=\"M17.64 18.67 20 21\"/>" ++
        "<path d=\"m9 13 2 2 4-4\"/><rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" " ++
        "rx=\"2\" ry=\"2\"/><polyline points=\"11 3 11 11 14 8 17 11 17 3\"/>";
    var path = SvgPath.init(gpa);
    defer path.deinit();
    try parseBounded(gpa, &path, source);
    var buffer: [RasterBudget.pathDataBytes(source.len)]u8 = undefined;
    const path_data = try pathDataBounded(gpa, source, &buffer);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfAny(u8, path_data, "<=\""));

    var letter_count: usize = 0;
    var number_count: usize = 0;
    var index: usize = 0;
    while (index < path_data.len) {
        const byte = path_data[index];
        if (byte == ' ') {
            index += 1;
        } else if (std.mem.indexOfScalar(u8, "MmLlHhVvCcSsQqTtAaZz", byte) != null) {
            letter_count += 1;
            index += 1;
        } else {
            const end = std.mem.indexOfAnyPos(u8, path_data, index, " MmLlHhVvCcSsQqTtAaZz") orelse
                path_data.len;
            const number = try std.fmt.parseFloat(f32, path_data[index..end]);
            try std.testing.expect(number_count < path.data.items.len);
            const expected: u32 = @bitCast(path.data.items[number_count]);
            try std.testing.expectEqual(expected, @as(u32, @bitCast(number)));
            number_count += 1;
            index = end;
        }
    }
    try std.testing.expectEqual(path.commands.items.len, letter_count);
    try std.testing.expectEqual(path.data.items.len, number_count);
    try std.testing.expect(letter_count > 20);
}

test "pathDataBounded writes the longest f32 in path_data_number_bytes_max bytes" {
    const gpa = std.testing.allocator;
    const source = "M-0.00000000000000000000000000000000000100000075 0";
    var buffer: [RasterBudget.pathDataBytes(source.len)]u8 = undefined;
    const path_data = try pathDataBounded(gpa, source, &buffer);
    try std.testing.expectEqualStrings("M -1.00000075e-36 0e0", path_data);
    try std.testing.expectEqual(RasterBudget.path_data_number_bytes_max, "-1.00000075e-36".len);
}

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

    var points: std.ArrayList(Vec2) = .empty;
    defer points.deinit(allocator);
    var polygons: std.ArrayList(IndexSlice) = .empty;
    defer polygons.deinit(allocator);

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
    try std.testing.expectEqual(@as(f32, 5), path.data.items[2]);
    try std.testing.expectEqual(@as(f32, 5), path.data.items[3]);
}

test "flatten arc" {
    const allocator = std.testing.allocator;
    var points: std.ArrayList(Vec2) = .empty;
    defer points.deinit(allocator);

    try flattenArc(allocator, Vec2.init(0, 0), 50, 50, 0, false, true, Vec2.init(100, 0), 1.0, &points);

    try std.testing.expect(points.items.len >= 4);
    const last = points.items[points.items.len - 1];
    try std.testing.expect(@abs(last.x - 100) < 0.1);
    try std.testing.expect(@abs(last.y - 0) < 0.1);
}

test "parse lucide arrow path" {
    const allocator = std.testing.allocator;
    var parser = PathParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "m12 19-7-7 7-7");

    try std.testing.expectEqual(@as(usize, 3), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to_rel, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to_rel, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.line_to_rel, path.commands.items[2]);

    try std.testing.expectEqual(@as(usize, 6), path.data.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, -7), path.data.items[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -7), path.data.items[3], 0.01);
}

test "SvgElementParser parses raw path data" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "M10 20 L30 40 Z");

    try std.testing.expectEqual(@as(usize, 3), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[2]);
}

test "SvgElementParser parses circle element" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<circle cx=\"12\" cy=\"12\" r=\"10\"/>");

    try std.testing.expectEqual(@as(usize, 4), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[3]);

    try std.testing.expectApproxEqAbs(@as(f32, 22), path.data.items[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 12), path.data.items[1], 0.01);
}

test "SvgElementParser parses rect element" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<rect x=\"3\" y=\"3\" width=\"18\" height=\"18\"/>");

    try std.testing.expectEqual(@as(usize, 5), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[3]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[4]);
}

test "SvgElementParser parses rounded rect" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<rect x=\"3\" y=\"3\" width=\"18\" height=\"18\" rx=\"2\"/>");

    try std.testing.expectEqual(@as(usize, 10), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[9]);
}

test "SvgElementParser parses line element" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<line x1=\"12\" y1=\"5\" x2=\"12\" y2=\"19\"/>");

    try std.testing.expectEqual(@as(usize, 2), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[1]);

    try std.testing.expectApproxEqAbs(@as(f32, 12), path.data.items[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 5), path.data.items[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 12), path.data.items[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 19), path.data.items[3], 0.01);
}

test "SvgElementParser parses polyline element" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<polyline points=\"20 6 9 17 4 12\"/>");

    try std.testing.expectEqual(@as(usize, 3), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[2]);
}

test "SvgElementParser parses polygon element" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<polygon points=\"20 6 9 17 4 12\"/>");

    try std.testing.expectEqual(@as(usize, 4), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[3]);
}

test "SvgElementParser parses path element" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<path d=\"M5 12h14\"/>");

    try std.testing.expectEqual(@as(usize, 2), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.horiz_line_to_rel, path.commands.items[1]);
}

test "SvgElementParser parses multiple elements" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<path d=\"M5 12h14\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/>");

    try std.testing.expectEqual(@as(usize, 6), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.horiz_line_to_rel, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[3]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[4]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[5]);
}

test "SvgElementParser parses ellipse element" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<ellipse cx=\"12\" cy=\"12\" rx=\"10\" ry=\"5\"/>");

    try std.testing.expectEqual(@as(usize, 4), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[3]);

    try std.testing.expectApproxEqAbs(@as(f32, 22), path.data.items[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 12), path.data.items[1], 0.01);
}

test "SvgElementParser handles single quotes" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<circle cx='12' cy='12' r='10'/>");

    try std.testing.expectEqual(@as(usize, 4), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
}

test "SvgElementParser handles whitespace in elements" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "  <line  x1=\"0\"  y1=\"0\"  x2=\"10\"  y2=\"10\" />  ");

    try std.testing.expectEqual(@as(usize, 2), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[1]);
}

test "SvgElementParser parses multiple path elements (Lucide X icon)" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<path d=\"M18 6 6 18\"/><path d=\"m6 6 12 12\"/>");

    try std.testing.expectEqual(@as(usize, 4), path.commands.items.len);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.line_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.line_to_rel, path.commands.items[3]);

    try std.testing.expectEqual(@as(f32, 18), path.data.items[0]);
    try std.testing.expectEqual(@as(f32, 6), path.data.items[1]);
    try std.testing.expectEqual(@as(f32, 6), path.data.items[2]);
    try std.testing.expectEqual(@as(f32, 18), path.data.items[3]);
}

test "SvgElementParser parses circle + path (check_circle icon)" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"m9 12 2 2 4-4\"/>");

    try std.testing.expectEqual(@as(usize, 7), path.commands.items.len);

    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand.arc_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.close_path, path.commands.items[3]);

    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[4]);
    try std.testing.expectEqual(PathCommand.line_to_rel, path.commands.items[5]);
    try std.testing.expectEqual(PathCommand.line_to_rel, path.commands.items[6]);
}

test "SvgElementParser converts relative m to absolute M in second path (arrow_right)" {
    const allocator = std.testing.allocator;
    var parser = SvgElementParser.init(allocator);
    var path = SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, "<path d=\"M5 12h14\"/><path d=\"m12 5 7 7-7 7\"/>");

    try std.testing.expectEqual(@as(usize, 5), path.commands.items.len);

    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[0]);
    try std.testing.expectEqual(PathCommand.horiz_line_to_rel, path.commands.items[1]);

    try std.testing.expectEqual(PathCommand.move_to, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.line_to_rel, path.commands.items[3]);
    try std.testing.expectEqual(PathCommand.line_to_rel, path.commands.items[4]);

    try std.testing.expectEqual(@as(f32, 12), path.data.items[3]);
    try std.testing.expectEqual(@as(f32, 5), path.data.items[4]);
}
