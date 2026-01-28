//! Path Builder API
//!
//! Programmatic path construction using a fluent builder pattern.
//! Converts to meshes for GPU rendering via existing SVG infrastructure.
//!
//! ## Usage
//! ```zig
//! var path = Path.init();
//! path.moveTo(0, 0)
//!     .lineTo(100, 0)
//!     .lineTo(100, 100)
//!     .lineTo(0, 100)
//!     .closePath();
//!
//! const mesh = try path.toMesh(allocator, 0.5);
//! try scene.insertPathWithMesh(mesh, 0, 0, Hsla.red);
//! ```

const std = @import("std");
const builtin = @import("builtin");
const triangulator = @import("../core/triangulator.zig");
const path_mesh = @import("path_mesh.zig");
const mesh_pool = @import("mesh_pool.zig");
const stroke_mod = @import("../core/stroke.zig");

const Vec2 = triangulator.Vec2;
const FixedArray = triangulator.FixedArray;
const PathMesh = path_mesh.PathMesh;
const MeshPool = mesh_pool.MeshPool;
const MeshRef = mesh_pool.MeshRef;

// Re-export stroke types for public API
pub const LineCap = stroke_mod.LineCap;
pub const LineJoin = stroke_mod.LineJoin;
pub const StrokeStyle = stroke_mod.StrokeStyle;

// =============================================================================
// Constants (static allocation per CLAUDE.md)
// =============================================================================

/// Maximum path commands per path
pub const MAX_PATH_COMMANDS: u32 = 2048;
/// Maximum data floats (commands like cubicTo need 6 floats)
pub const MAX_PATH_DATA: u32 = MAX_PATH_COMMANDS * 8;
/// Maximum subpaths (each moveTo starts a new subpath)
pub const MAX_SUBPATHS: u32 = 64;

// =============================================================================
// Command Types
// =============================================================================

/// Path command types (matches SVG semantics)
pub const Command = enum(u8) {
    /// Move to absolute position, starts new subpath
    move_to,
    /// Line to absolute position
    line_to,
    /// Quadratic Bézier curve (1 control point)
    quad_to,
    /// Cubic Bézier curve (2 control points)
    cubic_to,
    /// Elliptical arc
    arc_to,
    /// Close current subpath (line back to subpath start)
    close_path,
};

// =============================================================================
// Errors
// =============================================================================

pub const PathError = error{
    TooManyCommands,
    TooManyDataFloats,
    TooManySubpaths,
    EmptyPath,
    NoCurrentPoint,
    OutOfMemory,
} || path_mesh.PathMeshError || stroke_mod.StrokeError;

// =============================================================================
// Path Builder
// =============================================================================

pub const Path = struct {
    /// Command sequence
    commands: FixedArray(Command, MAX_PATH_COMMANDS),
    /// Float data for commands (coordinates, control points)
    data: FixedArray(f32, MAX_PATH_DATA),
    /// Subpath start indices (for closePath)
    subpath_starts: FixedArray(u32, MAX_SUBPATHS),
    /// Current point (for relative operations and closePath)
    current: Vec2,
    /// Start of current subpath (for closePath)
    subpath_start: Vec2,
    /// Whether we have a valid current point
    has_current: bool,

    const Self = @This();

    /// Initialize empty path builder
    pub fn init() Self {
        return .{
            .commands = .{},
            .data = .{},
            .subpath_starts = .{},
            .current = .{ .x = 0, .y = 0 },
            .subpath_start = .{ .x = 0, .y = 0 },
            .has_current = false,
        };
    }

    /// Reset path for reuse
    pub fn reset(self: *Self) void {
        self.commands.len = 0;
        self.data.len = 0;
        self.subpath_starts.len = 0;
        self.current = .{ .x = 0, .y = 0 };
        self.subpath_start = .{ .x = 0, .y = 0 };
        self.has_current = false;
    }

    // =========================================================================
    // Builder Methods (fluent API)
    // =========================================================================

    /// Move to absolute position, starting a new subpath
    pub fn moveTo(self: *Self, x: f32, y: f32) *Self {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(self.commands.len < MAX_PATH_COMMANDS);

        if (self.commands.len >= MAX_PATH_COMMANDS or self.data.len + 2 > MAX_PATH_DATA) {
            return self; // Fail silently to maintain fluent API
        }

        self.commands.appendAssumeCapacity(.move_to);
        self.data.appendAssumeCapacity(x);
        self.data.appendAssumeCapacity(y);

        self.current = .{ .x = x, .y = y };
        self.subpath_start = self.current;
        self.has_current = true;

        // Track subpath start for polygon generation
        if (self.subpath_starts.len < MAX_SUBPATHS) {
            self.subpath_starts.appendAssumeCapacity(@intCast(self.data.len - 2));
        }

        return self;
    }

    /// Line to absolute position
    pub fn lineTo(self: *Self, x: f32, y: f32) *Self {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

        // Implicit moveTo if no current point (matches SVG behavior)
        if (!self.has_current) {
            return self.moveTo(x, y);
        }

        if (self.commands.len >= MAX_PATH_COMMANDS or self.data.len + 2 > MAX_PATH_DATA) {
            return self;
        }

        self.commands.appendAssumeCapacity(.line_to);
        self.data.appendAssumeCapacity(x);
        self.data.appendAssumeCapacity(y);

        self.current = .{ .x = x, .y = y };
        return self;
    }

    /// Quadratic Bézier curve to (x, y) with control point (cx, cy)
    pub fn quadTo(self: *Self, cx: f32, cy: f32, x: f32, y: f32) *Self {
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

        if (!self.has_current) {
            return self.moveTo(x, y);
        }

        if (self.commands.len >= MAX_PATH_COMMANDS or self.data.len + 4 > MAX_PATH_DATA) {
            return self;
        }

        self.commands.appendAssumeCapacity(.quad_to);
        self.data.appendAssumeCapacity(cx);
        self.data.appendAssumeCapacity(cy);
        self.data.appendAssumeCapacity(x);
        self.data.appendAssumeCapacity(y);

        self.current = .{ .x = x, .y = y };
        return self;
    }

    /// Cubic Bézier curve to (x, y) with control points (cx1, cy1) and (cx2, cy2)
    pub fn cubicTo(
        self: *Self,
        cx1: f32,
        cy1: f32,
        cx2: f32,
        cy2: f32,
        x: f32,
        y: f32,
    ) *Self {
        std.debug.assert(!std.math.isNan(cx1) and !std.math.isNan(cy1));
        std.debug.assert(!std.math.isNan(cx2) and !std.math.isNan(cy2));

        if (!self.has_current) {
            return self.moveTo(x, y);
        }

        if (self.commands.len >= MAX_PATH_COMMANDS or self.data.len + 6 > MAX_PATH_DATA) {
            return self;
        }

        self.commands.appendAssumeCapacity(.cubic_to);
        self.data.appendAssumeCapacity(cx1);
        self.data.appendAssumeCapacity(cy1);
        self.data.appendAssumeCapacity(cx2);
        self.data.appendAssumeCapacity(cy2);
        self.data.appendAssumeCapacity(x);
        self.data.appendAssumeCapacity(y);

        self.current = .{ .x = x, .y = y };
        return self;
    }

    /// Elliptical arc to (x, y) with radii (rx, ry)
    pub fn arcTo(
        self: *Self,
        rx: f32,
        ry: f32,
        x_rotation_deg: f32,
        large_arc: bool,
        sweep: bool,
        x: f32,
        y: f32,
    ) *Self {
        std.debug.assert(!std.math.isNan(rx) and !std.math.isNan(ry));
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

        if (!self.has_current) {
            return self.moveTo(x, y);
        }

        if (self.commands.len >= MAX_PATH_COMMANDS or self.data.len + 7 > MAX_PATH_DATA) {
            return self;
        }

        self.commands.appendAssumeCapacity(.arc_to);
        self.data.appendAssumeCapacity(rx);
        self.data.appendAssumeCapacity(ry);
        self.data.appendAssumeCapacity(x_rotation_deg);
        self.data.appendAssumeCapacity(if (large_arc) 1.0 else 0.0);
        self.data.appendAssumeCapacity(if (sweep) 1.0 else 0.0);
        self.data.appendAssumeCapacity(x);
        self.data.appendAssumeCapacity(y);

        self.current = .{ .x = x, .y = y };
        return self;
    }

    /// Close current subpath with a line back to subpath start
    pub fn closePath(self: *Self) *Self {
        if (!self.has_current) {
            return self;
        }

        if (self.commands.len >= MAX_PATH_COMMANDS) {
            return self;
        }

        self.commands.appendAssumeCapacity(.close_path);
        self.current = self.subpath_start;

        return self;
    }

    // =========================================================================
    // Convenience Shape Methods
    // =========================================================================

    /// Add a rectangle to the path
    pub fn rect(self: *Self, x: f32, y: f32, width: f32, height: f32) *Self {
        std.debug.assert(width >= 0 and height >= 0);
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

        return self
            .moveTo(x, y)
            .lineTo(x + width, y)
            .lineTo(x + width, y + height)
            .lineTo(x, y + height)
            .closePath();
    }

    /// Add a rounded rectangle to the path
    pub fn roundedRect(self: *Self, x: f32, y: f32, w: f32, h: f32, r: f32) *Self {
        std.debug.assert(w >= 0 and h >= 0 and r >= 0);
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

        const radius = @min(r, @min(w / 2, h / 2));

        if (radius <= 0.01) {
            return self.rect(x, y, w, h);
        }

        // Start at top-left after corner
        _ = self.moveTo(x + radius, y);
        // Top edge
        _ = self.lineTo(x + w - radius, y);
        // Top-right corner
        _ = self.arcTo(radius, radius, 0, false, true, x + w, y + radius);
        // Right edge
        _ = self.lineTo(x + w, y + h - radius);
        // Bottom-right corner
        _ = self.arcTo(radius, radius, 0, false, true, x + w - radius, y + h);
        // Bottom edge
        _ = self.lineTo(x + radius, y + h);
        // Bottom-left corner
        _ = self.arcTo(radius, radius, 0, false, true, x, y + h - radius);
        // Left edge
        _ = self.lineTo(x, y + radius);
        // Top-left corner
        _ = self.arcTo(radius, radius, 0, false, true, x + radius, y);
        _ = self.closePath();

        return self;
    }

    /// Add a circle to the path
    pub fn circle(self: *Self, cx: f32, cy: f32, r: f32) *Self {
        std.debug.assert(r >= 0);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        // Two arcs make a circle
        _ = self.moveTo(cx + r, cy);
        _ = self.arcTo(r, r, 0, true, true, cx - r, cy);
        _ = self.arcTo(r, r, 0, true, true, cx + r, cy);
        _ = self.closePath();

        return self;
    }

    /// Add an ellipse to the path
    pub fn ellipse(self: *Self, cx: f32, cy: f32, rx: f32, ry: f32) *Self {
        std.debug.assert(rx >= 0 and ry >= 0);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        _ = self.moveTo(cx + rx, cy);
        _ = self.arcTo(rx, ry, 0, true, true, cx - rx, cy);
        _ = self.arcTo(rx, ry, 0, true, true, cx + rx, cy);
        _ = self.closePath();

        return self;
    }

    /// Add a circle with explicit segment count (for LOD control)
    /// Use this when you need precise control over vertex count.
    pub fn circleWithSegments(self: *Self, cx: f32, cy: f32, r: f32, segments: u8) *Self {
        std.debug.assert(r >= 0);
        std.debug.assert(segments >= 3);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        const delta = std.math.tau / @as(f32, @floatFromInt(segments));

        _ = self.moveTo(cx + r, cy);
        for (1..segments) |i| {
            const angle = delta * @as(f32, @floatFromInt(i));
            _ = self.lineTo(cx + r * @cos(angle), cy + r * @sin(angle));
        }
        return self.closePath();
    }

    /// Add a circle with automatic LOD based on screen size
    /// `pixels_per_unit` is the scale factor (e.g., from DrawContext.scale)
    /// Small circles get fewer segments, large circles remain smooth.
    pub fn circleAdaptive(self: *Self, cx: f32, cy: f32, r: f32, pixels_per_unit: f32) *Self {
        std.debug.assert(r >= 0);
        std.debug.assert(pixels_per_unit > 0);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        const screen_radius = r * pixels_per_unit;

        // Segment count based on screen coverage
        // Tiny circles can be squares, large ones need smoothness
        const segments: u8 = if (screen_radius < 2) 4 // Tiny: square is fine
            else if (screen_radius < 8) 6 // Small: hexagon
            else if (screen_radius < 32) 12 // Medium
            else if (screen_radius < 128) 24 // Large
            else 32; // Very large

        return self.circleWithSegments(cx, cy, r, segments);
    }

    /// Add an ellipse with explicit segment count (for LOD control)
    pub fn ellipseWithSegments(self: *Self, cx: f32, cy: f32, rx: f32, ry: f32, segments: u8) *Self {
        std.debug.assert(rx >= 0 and ry >= 0);
        std.debug.assert(segments >= 3);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        const delta = std.math.tau / @as(f32, @floatFromInt(segments));

        _ = self.moveTo(cx + rx, cy);
        for (1..segments) |i| {
            const angle = delta * @as(f32, @floatFromInt(i));
            _ = self.lineTo(cx + rx * @cos(angle), cy + ry * @sin(angle));
        }
        return self.closePath();
    }

    /// Add an ellipse with automatic LOD based on screen size
    pub fn ellipseAdaptive(self: *Self, cx: f32, cy: f32, rx: f32, ry: f32, pixels_per_unit: f32) *Self {
        std.debug.assert(rx >= 0 and ry >= 0);
        std.debug.assert(pixels_per_unit > 0);
        std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

        // Use the larger radius for LOD calculation
        const max_radius = @max(rx, ry);
        const screen_radius = max_radius * pixels_per_unit;

        const segments: u8 = if (screen_radius < 2) 4 else if (screen_radius < 8) 6 else if (screen_radius < 32) 12 else if (screen_radius < 128) 24 else 32;

        return self.ellipseWithSegments(cx, cy, rx, ry, segments);
    }

    // =========================================================================
    // Mesh Conversion
    // =========================================================================

    /// Convert path to mesh for GPU rendering
    /// Uses temporary allocator for flattening, result is self-contained
    pub fn toMesh(self: *const Self, allocator: std.mem.Allocator, tolerance: f32) PathError!PathMesh {
        std.debug.assert(tolerance > 0);

        if (self.commands.len == 0) {
            return error.EmptyPath;
        }

        // Flatten curves to line segments
        var points: std.ArrayList(Vec2) = .{};
        defer points.deinit(allocator);

        var polygons: std.ArrayList(triangulator.IndexSlice) = .{};
        defer polygons.deinit(allocator);

        try self.flatten(allocator, tolerance, &points, &polygons);

        if (points.items.len < 3 or polygons.items.len == 0) {
            return error.EmptyPath;
        }

        // Convert to PathMesh via triangulator
        return PathMesh.fromFlattenedPath(points.items, polygons.items);
    }

    /// Convert path to cached mesh (returns existing if already cached)
    pub fn toCachedMesh(
        self: *const Self,
        pool: *MeshPool,
        allocator: std.mem.Allocator,
        tolerance: f32,
    ) PathError!MeshRef {
        const h = self.hash();

        // Check cache
        if (pool.hasPersistent(h)) {
            // Return existing reference
            const hashes = pool.persistent_hashes[0..pool.persistent_count];
            for (hashes, 0..) |stored_hash, i| {
                if (stored_hash == h) {
                    return MeshRef{ .persistent = @intCast(i) };
                }
            }
        }

        // Cache miss - create mesh
        const mesh = try self.toMesh(allocator, tolerance);

        return pool.getOrCreatePersistent(mesh, h) catch |e| switch (e) {
            error.PersistentPoolFull => error.TooManyCommands,
            error.OutOfMemory => error.TooManyCommands,
            else => error.TooManyCommands,
        };
    }

    // =========================================================================
    // Hashing
    // =========================================================================

    /// Convert path to stroked mesh (stroke becomes filled polygon)
    ///
    /// Expands the path's stroke into a thick polygon that can be rendered
    /// as a fill. Supports line caps, line joins, and miter limits.
    ///
    /// `allocator` — Temporary allocator for flattening
    /// `width` — Stroke width in pixels
    /// `cap` — Line cap style (butt, round, square)
    /// `join` — Line join style (miter, round, bevel)
    /// `tolerance` — Curve flattening tolerance
    pub fn toStrokeMesh(
        self: *const Self,
        allocator: std.mem.Allocator,
        width: f32,
        cap: LineCap,
        join: LineJoin,
        tolerance: f32,
    ) PathError!PathMesh {
        std.debug.assert(width > 0);
        std.debug.assert(tolerance > 0);

        if (self.commands.len == 0) {
            return error.EmptyPath;
        }

        // Flatten curves to line segments (using stroke-aware version that keeps 2-point lines)
        var points: std.ArrayList(Vec2) = .{};
        defer points.deinit(allocator);

        var polygons: std.ArrayList(triangulator.IndexSlice) = .{};
        defer polygons.deinit(allocator);

        try self.flattenForStroke(allocator, tolerance, &points, &polygons);

        if (points.items.len < 2 or polygons.items.len == 0) {
            return error.EmptyPath;
        }

        // Process each subpath with direct triangulation
        for (polygons.items) |poly| {
            const poly_points = points.items[poly.start..poly.end];
            if (poly_points.len < 2) continue;

            // Determine if path is closed (first point == last point within epsilon)
            const first = poly_points[0];
            const last = poly_points[poly_points.len - 1];
            const eps: f32 = 1e-4;
            const is_closed = @abs(last.x - first.x) < eps and @abs(last.y - first.y) < eps;

            // For closed paths, remove the duplicate endpoint to avoid degenerate
            // segment normals (computing normal from a point to itself)
            const stroke_points = if (is_closed and poly_points.len > 2)
                poly_points[0 .. poly_points.len - 1]
            else
                poly_points;

            if (stroke_points.len < 2) continue;

            // Use direct triangulation for all strokes (bypasses ear-clipper)
            // This handles both open and closed paths correctly, avoiding
            // ear-clipper failures on concave/self-intersecting stroke polygons
            const triangles = try stroke_mod.expandStrokeToTriangles(
                stroke_points,
                width,
                cap,
                join,
                4.0, // miter limit
                is_closed,
            );
            return PathMesh.fromStrokeTriangles(triangles);
        }

        // No valid subpaths found
        return error.EmptyPath;
    }

    /// Convert path to stroked mesh with default style
    pub fn toStrokeMeshSimple(
        self: *const Self,
        allocator: std.mem.Allocator,
        width: f32,
        tolerance: f32,
    ) PathError!PathMesh {
        return self.toStrokeMesh(allocator, width, .butt, .miter, tolerance);
    }

    /// Compute hash for cache lookup (FNV-1a)
    pub fn hash(self: *const Self) u64 {
        std.debug.assert(self.commands.len > 0);

        const fnv_offset: u64 = 0xcbf29ce484222325;
        const fnv_prime: u64 = 0x100000001b3;

        var h: u64 = fnv_offset;

        // Hash commands
        for (self.commands.constSlice()) |cmd| {
            h ^= @intFromEnum(cmd);
            h *%= fnv_prime;
        }

        // Hash data floats
        const data_bytes: []const u8 = @as(
            [*]const u8,
            @ptrCast(self.data.buffer[0..self.data.len].ptr),
        )[0 .. self.data.len * @sizeOf(f32)];

        for (data_bytes) |byte| {
            h ^= byte;
            h *%= fnv_prime;
        }

        return if (h == 0) 1 else h;
    }

    // =========================================================================
    // Query Methods
    // =========================================================================

    /// Check if path is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.commands.len == 0;
    }

    /// Number of commands in path
    pub fn commandCount(self: *const Self) usize {
        return self.commands.len;
    }

    /// Debug dump path contents (only in Debug mode)
    pub fn debugDump(self: *const Self) void {
        if (builtin.mode != .Debug) return;

        std.log.debug("Path dump: {} commands, {} data floats", .{ self.commands.len, self.data.len });

        var data_idx: usize = 0;
        for (self.commands.constSlice(), 0..) |cmd, i| {
            switch (cmd) {
                .move_to => {
                    const x = self.data.get(data_idx);
                    const y = self.data.get(data_idx + 1);
                    std.log.debug("  [{:2}] moveTo({d:.2}, {d:.2})", .{ i, x, y });
                    data_idx += 2;
                },
                .line_to => {
                    const x = self.data.get(data_idx);
                    const y = self.data.get(data_idx + 1);
                    std.log.debug("  [{:2}] lineTo({d:.2}, {d:.2})", .{ i, x, y });
                    data_idx += 2;
                },
                .quad_to => {
                    const cx = self.data.get(data_idx);
                    const cy = self.data.get(data_idx + 1);
                    const x = self.data.get(data_idx + 2);
                    const y = self.data.get(data_idx + 3);
                    std.log.debug("  [{:2}] quadTo({d:.2}, {d:.2}, {d:.2}, {d:.2})", .{ i, cx, cy, x, y });
                    data_idx += 4;
                },
                .cubic_to => {
                    const cx1 = self.data.get(data_idx);
                    const cy1 = self.data.get(data_idx + 1);
                    const cx2 = self.data.get(data_idx + 2);
                    const cy2 = self.data.get(data_idx + 3);
                    const x = self.data.get(data_idx + 4);
                    const y = self.data.get(data_idx + 5);
                    std.log.debug("  [{:2}] cubicTo({d:.2}, {d:.2}, {d:.2}, {d:.2}, {d:.2}, {d:.2})", .{ i, cx1, cy1, cx2, cy2, x, y });
                    data_idx += 6;
                },
                .arc_to => {
                    const rx = self.data.get(data_idx);
                    const ry = self.data.get(data_idx + 1);
                    const x_rot = self.data.get(data_idx + 2);
                    const large = self.data.get(data_idx + 3);
                    const sweep = self.data.get(data_idx + 4);
                    const x = self.data.get(data_idx + 5);
                    const y = self.data.get(data_idx + 6);
                    std.log.debug("  [{:2}] arcTo({d:.2}, {d:.2}, rot={d:.2}, large={d:.1}, sweep={d:.1}, {d:.2}, {d:.2})", .{ i, rx, ry, x_rot, large, sweep, x, y });
                    data_idx += 7;
                },
                .close_path => {
                    std.log.debug("  [{:2}] closePath()", .{i});
                },
            }
        }
    }

    // =========================================================================
    // Internal: Curve Flattening
    // =========================================================================

    /// Flatten all curves to line segments
    fn flatten(
        self: *const Self,
        allocator: std.mem.Allocator,
        tolerance: f32,
        points: *std.ArrayList(Vec2),
        polygons: *std.ArrayList(triangulator.IndexSlice),
    ) !void {
        std.debug.assert(tolerance > 0);
        // Note: caller (toMesh) validates commands.len > 0

        var cur = Vec2{ .x = 0, .y = 0 };
        var poly_start: u32 = 0;
        var data_idx: usize = 0;

        for (self.commands.constSlice()) |cmd| {
            switch (cmd) {
                .move_to => {
                    // Close previous polygon if any
                    if (points.items.len > poly_start + 1) {
                        try polygons.append(allocator, .{
                            .start = poly_start,
                            .end = @intCast(points.items.len),
                        });
                    }

                    cur.x = self.data.get(data_idx);
                    cur.y = self.data.get(data_idx + 1);
                    data_idx += 2;

                    poly_start = @intCast(points.items.len);
                    try points.append(allocator, cur);
                },
                .line_to => {
                    cur.x = self.data.get(data_idx);
                    cur.y = self.data.get(data_idx + 1);
                    data_idx += 2;
                    try points.append(allocator, cur);
                },
                .quad_to => {
                    const cx = self.data.get(data_idx);
                    const cy = self.data.get(data_idx + 1);
                    const x = self.data.get(data_idx + 2);
                    const y = self.data.get(data_idx + 3);
                    data_idx += 4;

                    try flattenQuadratic(allocator, cur, cx, cy, x, y, tolerance, points);
                    cur = .{ .x = x, .y = y };
                },
                .cubic_to => {
                    const cx1 = self.data.get(data_idx);
                    const cy1 = self.data.get(data_idx + 1);
                    const cx2 = self.data.get(data_idx + 2);
                    const cy2 = self.data.get(data_idx + 3);
                    const x = self.data.get(data_idx + 4);
                    const y = self.data.get(data_idx + 5);
                    data_idx += 6;

                    try flattenCubic(allocator, cur, cx1, cy1, cx2, cy2, x, y, tolerance, points);
                    cur = .{ .x = x, .y = y };
                },
                .arc_to => {
                    const rx = self.data.get(data_idx);
                    const ry = self.data.get(data_idx + 1);
                    const x_rot = self.data.get(data_idx + 2);
                    const large = self.data.get(data_idx + 3) > 0.5;
                    const sweep = self.data.get(data_idx + 4) > 0.5;
                    const x = self.data.get(data_idx + 5);
                    const y = self.data.get(data_idx + 6);
                    data_idx += 7;

                    try flattenArcSegment(allocator, cur, rx, ry, x_rot, large, sweep, x, y, tolerance, points);
                    cur = .{ .x = x, .y = y };
                },
                .close_path => {
                    // No action needed - polygon will be closed automatically
                },
            }
        }

        // Final polygon - remove duplicate closing point if present
        if (points.items.len > poly_start + 2) {
            // Check if last point equals first point (closed path duplicate)
            const first = points.items[poly_start];
            const last = points.items[points.items.len - 1];
            const eps: f32 = 1e-6;
            if (@abs(last.x - first.x) < eps and @abs(last.y - first.y) < eps) {
                // Remove duplicate closing point by shrinking the list
                points.items.len -= 1;
            }
        }

        if (points.items.len > poly_start + 2) {
            try polygons.append(allocator, .{
                .start = poly_start,
                .end = @intCast(points.items.len),
            });
        }
    }

    /// Flatten all curves to line segments (stroke version - keeps 2-point lines)
    /// Unlike flatten(), this version outputs subpaths with 2+ points for stroke operations.
    fn flattenForStroke(
        self: *const Self,
        allocator: std.mem.Allocator,
        tolerance: f32,
        points: *std.ArrayList(Vec2),
        polygons: *std.ArrayList(triangulator.IndexSlice),
    ) !void {
        std.debug.assert(tolerance > 0);

        var cur = Vec2{ .x = 0, .y = 0 };
        var poly_start: u32 = 0;
        var data_idx: usize = 0;

        for (self.commands.constSlice()) |cmd| {
            switch (cmd) {
                .move_to => {
                    // Close previous subpath if it has at least 2 points
                    if (points.items.len > poly_start + 1) {
                        try polygons.append(allocator, .{
                            .start = poly_start,
                            .end = @intCast(points.items.len),
                        });
                    }

                    cur.x = self.data.get(data_idx);
                    cur.y = self.data.get(data_idx + 1);
                    data_idx += 2;

                    poly_start = @intCast(points.items.len);
                    try points.append(allocator, cur);
                },
                .line_to => {
                    cur.x = self.data.get(data_idx);
                    cur.y = self.data.get(data_idx + 1);
                    data_idx += 2;
                    try points.append(allocator, cur);
                },
                .quad_to => {
                    const cx = self.data.get(data_idx);
                    const cy = self.data.get(data_idx + 1);
                    const x = self.data.get(data_idx + 2);
                    const y = self.data.get(data_idx + 3);
                    data_idx += 4;

                    try flattenQuadratic(allocator, cur, cx, cy, x, y, tolerance, points);
                    cur = .{ .x = x, .y = y };
                },
                .cubic_to => {
                    const cx1 = self.data.get(data_idx);
                    const cy1 = self.data.get(data_idx + 1);
                    const cx2 = self.data.get(data_idx + 2);
                    const cy2 = self.data.get(data_idx + 3);
                    const x = self.data.get(data_idx + 4);
                    const y = self.data.get(data_idx + 5);
                    data_idx += 6;

                    try flattenCubic(allocator, cur, cx1, cy1, cx2, cy2, x, y, tolerance, points);
                    cur = .{ .x = x, .y = y };
                },
                .arc_to => {
                    const rx = self.data.get(data_idx);
                    const ry = self.data.get(data_idx + 1);
                    const x_rot = self.data.get(data_idx + 2);
                    const large = self.data.get(data_idx + 3) > 0.5;
                    const sweep = self.data.get(data_idx + 4) > 0.5;
                    const x = self.data.get(data_idx + 5);
                    const y = self.data.get(data_idx + 6);
                    data_idx += 7;

                    try flattenArcSegment(allocator, cur, rx, ry, x_rot, large, sweep, x, y, tolerance, points);
                    cur = .{ .x = x, .y = y };
                },
                .close_path => {
                    // No action needed - polygon will be closed automatically
                },
            }
        }

        // Final subpath - for strokes we include 2+ point subpaths
        if (points.items.len > poly_start + 1) {
            try polygons.append(allocator, .{
                .start = poly_start,
                .end = @intCast(points.items.len),
            });
        }
    }
};

// =============================================================================
// Curve Flattening (recursive subdivision)
// =============================================================================

/// Flatten quadratic Bézier curve
fn flattenQuadratic(
    allocator: std.mem.Allocator,
    start: Vec2,
    cx: f32,
    cy: f32,
    x: f32,
    y: f32,
    tolerance: f32,
    output: *std.ArrayList(Vec2),
) !void {
    std.debug.assert(tolerance > 0);
    std.debug.assert(!std.math.isNan(cx) and !std.math.isNan(cy));

    const end = Vec2{ .x = x, .y = y };
    const ctrl = Vec2{ .x = cx, .y = cy };

    try flattenQuadRecursive(allocator, start, ctrl, end, tolerance, 0, output);
}

fn flattenQuadRecursive(
    allocator: std.mem.Allocator,
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
    tolerance: f32,
    depth: u32,
    output: *std.ArrayList(Vec2),
) !void {
    const max_depth: u32 = 16;
    if (depth >= max_depth) {
        try output.append(allocator, p2);
        return;
    }

    // Check flatness using midpoint deviation
    const mid_x = (p0.x + 2 * p1.x + p2.x) / 4.0;
    const mid_y = (p0.y + 2 * p1.y + p2.y) / 4.0;
    const chord_mid_x = (p0.x + p2.x) / 2.0;
    const chord_mid_y = (p0.y + p2.y) / 2.0;

    const dx = mid_x - chord_mid_x;
    const dy = mid_y - chord_mid_y;
    const dist_sq = dx * dx + dy * dy;

    if (dist_sq <= tolerance * tolerance) {
        try output.append(allocator, p2);
        return;
    }

    // Subdivide at t=0.5
    const p01 = Vec2{ .x = (p0.x + p1.x) / 2, .y = (p0.y + p1.y) / 2 };
    const p12 = Vec2{ .x = (p1.x + p2.x) / 2, .y = (p1.y + p2.y) / 2 };
    const p012 = Vec2{ .x = (p01.x + p12.x) / 2, .y = (p01.y + p12.y) / 2 };

    try flattenQuadRecursive(allocator, p0, p01, p012, tolerance, depth + 1, output);
    try flattenQuadRecursive(allocator, p012, p12, p2, tolerance, depth + 1, output);
}

/// Flatten cubic Bézier curve
fn flattenCubic(
    allocator: std.mem.Allocator,
    start: Vec2,
    cx1: f32,
    cy1: f32,
    cx2: f32,
    cy2: f32,
    x: f32,
    y: f32,
    tolerance: f32,
    output: *std.ArrayList(Vec2),
) !void {
    std.debug.assert(tolerance > 0);
    std.debug.assert(!std.math.isNan(cx1) and !std.math.isNan(cy1));

    const c1 = Vec2{ .x = cx1, .y = cy1 };
    const c2 = Vec2{ .x = cx2, .y = cy2 };
    const end = Vec2{ .x = x, .y = y };

    try flattenCubicRecursive(allocator, start, c1, c2, end, tolerance, 0, output);
}

fn flattenCubicRecursive(
    allocator: std.mem.Allocator,
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
    tolerance: f32,
    depth: u32,
    output: *std.ArrayList(Vec2),
) !void {
    const max_depth: u32 = 16;
    if (depth >= max_depth) {
        try output.append(allocator, p3);
        return;
    }

    // Check flatness - distance from control points to chord
    const dx = p3.x - p0.x;
    const dy = p3.y - p0.y;
    const len_sq = dx * dx + dy * dy;

    if (len_sq < 0.0001) {
        try output.append(allocator, p3);
        return;
    }

    const len = @sqrt(len_sq);
    const nx = -dy / len;
    const ny = dx / len;

    const d1 = @abs((p1.x - p0.x) * nx + (p1.y - p0.y) * ny);
    const d2 = @abs((p2.x - p0.x) * nx + (p2.y - p0.y) * ny);
    const max_dist = @max(d1, d2);

    if (max_dist <= tolerance) {
        try output.append(allocator, p3);
        return;
    }

    // Subdivide at t=0.5 using de Casteljau
    const p01 = Vec2{ .x = (p0.x + p1.x) / 2, .y = (p0.y + p1.y) / 2 };
    const p12 = Vec2{ .x = (p1.x + p2.x) / 2, .y = (p1.y + p2.y) / 2 };
    const p23 = Vec2{ .x = (p2.x + p3.x) / 2, .y = (p2.y + p3.y) / 2 };
    const p012 = Vec2{ .x = (p01.x + p12.x) / 2, .y = (p01.y + p12.y) / 2 };
    const p123 = Vec2{ .x = (p12.x + p23.x) / 2, .y = (p12.y + p23.y) / 2 };
    const p0123 = Vec2{ .x = (p012.x + p123.x) / 2, .y = (p012.y + p123.y) / 2 };

    try flattenCubicRecursive(allocator, p0, p01, p012, p0123, tolerance, depth + 1, output);
    try flattenCubicRecursive(allocator, p0123, p123, p23, p3, tolerance, depth + 1, output);
}

/// Flatten elliptical arc
fn flattenArcSegment(
    allocator: std.mem.Allocator,
    start: Vec2,
    rx_in: f32,
    ry_in: f32,
    x_rotation_deg: f32,
    large_arc: bool,
    sweep: bool,
    x: f32,
    y: f32,
    tolerance: f32,
    output: *std.ArrayList(Vec2),
) !void {
    std.debug.assert(tolerance > 0);
    std.debug.assert(!std.math.isNan(rx_in) and !std.math.isNan(ry_in));

    const end = Vec2{ .x = x, .y = y };

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

        try output.append(allocator, .{ .x = px, .y = py });
    }
}

// =============================================================================
// Tests
// =============================================================================

test "Path builder rectangle" {
    var path = Path.init();
    _ = path.rect(0, 0, 100, 50);

    try std.testing.expectEqual(@as(usize, 5), path.commandCount());
    try std.testing.expect(!path.isEmpty());
}

test "Path builder fluent API" {
    var path = Path.init();
    _ = path
        .moveTo(0, 0)
        .lineTo(100, 0)
        .lineTo(100, 100)
        .lineTo(0, 100)
        .closePath();

    try std.testing.expectEqual(@as(usize, 5), path.commandCount());
}

test "Path builder circle" {
    var path = Path.init();
    _ = path.circle(50, 50, 25);

    // moveTo + 2 arcTo + closePath
    try std.testing.expectEqual(@as(usize, 4), path.commandCount());
}

test "Path builder quadTo" {
    var path = Path.init();
    _ = path
        .moveTo(0, 0)
        .quadTo(50, 100, 100, 0)
        .closePath();

    try std.testing.expectEqual(@as(usize, 3), path.commandCount());
}

test "Path builder cubicTo" {
    var path = Path.init();
    _ = path
        .moveTo(0, 0)
        .cubicTo(25, 50, 75, 50, 100, 0)
        .closePath();

    try std.testing.expectEqual(@as(usize, 3), path.commandCount());
}

test "Path builder reset" {
    var path = Path.init();
    _ = path.rect(0, 0, 100, 100);
    try std.testing.expect(!path.isEmpty());

    path.reset();
    try std.testing.expect(path.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), path.commandCount());
}

test "Path hash consistency" {
    var path1 = Path.init();
    _ = path1.rect(0, 0, 100, 100);

    var path2 = Path.init();
    _ = path2.rect(0, 0, 100, 100);

    try std.testing.expectEqual(path1.hash(), path2.hash());

    // Different path should have different hash
    var path3 = Path.init();
    _ = path3.rect(0, 0, 200, 100);
    try std.testing.expect(path1.hash() != path3.hash());
}

test "Path hash non-zero" {
    var path = Path.init();
    _ = path.rect(0, 0, 100, 100);

    try std.testing.expect(path.hash() != 0);
}

test "Path toMesh rectangle" {
    var path = Path.init();
    _ = path.rect(0, 0, 100, 100);

    const mesh = try path.toMesh(std.testing.allocator, 0.5);

    // Rectangle = 4 vertices, 2 triangles = 6 indices
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), mesh.indices.len);
}

test "Path toMesh with curves" {
    var path = Path.init();
    _ = path
        .moveTo(0, 0)
        .quadTo(50, 100, 100, 0)
        .lineTo(100, 50)
        .lineTo(0, 50)
        .closePath();

    const mesh = try path.toMesh(std.testing.allocator, 1.0);

    // Should have more vertices due to curve flattening
    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 3);
}

test "Path roundedRect" {
    var path = Path.init();
    _ = path.roundedRect(0, 0, 100, 50, 10);

    // Should have many commands for the arcs
    try std.testing.expect(path.commandCount() > 4);
}

test "Path roundedRect zero radius is rect" {
    var path1 = Path.init();
    _ = path1.roundedRect(0, 0, 100, 50, 0);

    var path2 = Path.init();
    _ = path2.rect(0, 0, 100, 50);

    // Same number of commands
    try std.testing.expectEqual(path1.commandCount(), path2.commandCount());
}

test "Path ellipse" {
    var path = Path.init();
    _ = path.ellipse(50, 50, 30, 20);

    try std.testing.expectEqual(@as(usize, 4), path.commandCount());
}

test "Path empty check" {
    var path = Path.init();
    try std.testing.expect(path.isEmpty());

    _ = path.moveTo(0, 0);
    try std.testing.expect(!path.isEmpty());
}

test "flattenQuadratic produces points" {
    var points: std.ArrayList(Vec2) = .{};
    defer points.deinit(std.testing.allocator);

    const start = Vec2{ .x = 0, .y = 0 };
    try flattenQuadratic(std.testing.allocator, start, 50, 100, 100, 0, 1.0, &points);

    // Should have multiple points from subdivision
    try std.testing.expect(points.items.len > 0);
}

test "flattenCubic produces points" {
    var points: std.ArrayList(Vec2) = .{};
    defer points.deinit(std.testing.allocator);

    const start = Vec2{ .x = 0, .y = 0 };
    try flattenCubic(std.testing.allocator, start, 25, 50, 75, 50, 100, 0, 1.0, &points);

    try std.testing.expect(points.items.len > 0);
}

test "flattenArcSegment produces points" {
    var points: std.ArrayList(Vec2) = .{};
    defer points.deinit(std.testing.allocator);

    const start = Vec2{ .x = 100, .y = 50 };
    try flattenArcSegment(std.testing.allocator, start, 50, 50, 0, false, true, 50, 100, 1.0, &points);

    try std.testing.expect(points.items.len > 0);
}

test "Path star shape" {
    var path = Path.init();
    // 5-pointed star
    const outer_r: f32 = 50;
    const inner_r: f32 = 20;
    const cx: f32 = 50;
    const cy: f32 = 50;

    var first = true;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 5.0 - std.math.pi / 2.0;
        const r = if (i % 2 == 0) outer_r else inner_r;
        const x = cx + r * @cos(angle);
        const y = cy + r * @sin(angle);

        if (first) {
            _ = path.moveTo(x, y);
            first = false;
        } else {
            _ = path.lineTo(x, y);
        }
    }
    _ = path.closePath();

    const mesh = try path.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 10), mesh.vertices.len);
    // 10-gon = 8 triangles = 24 indices
    try std.testing.expectEqual(@as(usize, 24), mesh.indices.len);
}

// =============================================================================
// Stroke Mesh Tests (Phase 4)
// =============================================================================

test "toStrokeMesh simple line" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(100, 0);

    const mesh = try path.toStrokeMesh(std.testing.allocator, 10.0, .butt, .miter, 0.5);

    // Stroked line should produce a rectangle-like polygon
    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 6);
}

test "toStrokeMesh with square cap" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(100, 0);

    const mesh = try path.toStrokeMesh(std.testing.allocator, 10.0, .square, .miter, 0.5);

    // Square cap: still 4 vertices (extended rectangle)
    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 6);
}

test "toStrokeMesh diagonal line" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(100, 100);

    const mesh = try path.toStrokeMesh(std.testing.allocator, 8.0, .butt, .miter, 0.5);

    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 6);
}

test "toStrokeMeshSimple convenience function" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(100, 100);

    const mesh = try path.toStrokeMeshSimple(std.testing.allocator, 8.0, 0.5);

    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 6);
}

test "toStrokeMesh empty path error" {
    var path = Path.init();

    const result = path.toStrokeMesh(std.testing.allocator, 10.0, .butt, .miter, 0.5);
    try std.testing.expectError(error.EmptyPath, result);
}

// Complex stroke tests - these now work with direct triangulation (bypasses ear-clipper)

test "toStrokeMesh open path with corner miter join" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(50, 0).lineTo(50, 50);

    const mesh = try path.toStrokeMesh(std.testing.allocator, 10.0, .butt, .miter, 0.5);

    // Multi-segment open path should produce valid triangles
    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 6);
    try std.testing.expect(mesh.indices.len % 3 == 0);
}

test "toStrokeMesh open path with corner bevel join" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(50, 0).lineTo(50, 50);

    const mesh = try path.toStrokeMesh(std.testing.allocator, 10.0, .butt, .bevel, 0.5);

    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 6);
    try std.testing.expect(mesh.indices.len % 3 == 0);
}

test "toStrokeMesh open path with corner round join" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(50, 0).lineTo(50, 50);

    const mesh = try path.toStrokeMesh(std.testing.allocator, 10.0, .round, .round, 0.5);

    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 6);
    try std.testing.expect(mesh.indices.len % 3 == 0);
}

test "toStrokeMesh zigzag path with multiple corners" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(20, 0).lineTo(20, 20).lineTo(40, 20).lineTo(40, 40);

    const mesh = try path.toStrokeMesh(std.testing.allocator, 6.0, .butt, .miter, 0.5);

    // 4 segments = more complex, should still triangulate
    try std.testing.expect(mesh.vertices.len >= 4);
    try std.testing.expect(mesh.indices.len >= 6);
    try std.testing.expect(mesh.indices.len % 3 == 0);
}

test "toStrokeMesh closed triangle stroke" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(100, 0).lineTo(50, 86).closePath();

    const mesh = try path.toStrokeMesh(std.testing.allocator, 8.0, .butt, .miter, 0.5);

    // Closed path forms a ring, should triangulate correctly
    try std.testing.expect(mesh.vertices.len >= 6);
    try std.testing.expect(mesh.indices.len >= 9);
    try std.testing.expect(mesh.indices.len % 3 == 0);
}

test "toStrokeMesh closed rectangle stroke" {
    var path = Path.init();
    _ = path.moveTo(0, 0).lineTo(100, 0).lineTo(100, 50).lineTo(0, 50).closePath();

    const mesh = try path.toStrokeMesh(std.testing.allocator, 4.0, .butt, .miter, 0.5);

    try std.testing.expect(mesh.vertices.len >= 8);
    try std.testing.expect(mesh.indices.len >= 12);
    try std.testing.expect(mesh.indices.len % 3 == 0);
}

// =============================================================================
// Additional Comprehensive Tests (migrated from path_test.zig)
// =============================================================================

test "moveTo sets current point" {
    var p = Path.init();
    _ = p.moveTo(50, 75);

    try std.testing.expect(p.has_current);
    try std.testing.expectEqual(@as(f32, 50), p.current.x);
    try std.testing.expectEqual(@as(f32, 75), p.current.y);
}

test "lineTo after moveTo works" {
    var p = Path.init();
    _ = p.moveTo(0, 0);
    _ = p.lineTo(100, 100);

    try std.testing.expect(p.has_current);
    try std.testing.expectEqual(@as(usize, 2), p.commandCount());
    try std.testing.expectEqual(@as(f32, 100), p.current.x);
    try std.testing.expectEqual(@as(f32, 100), p.current.y);
}

test "multiple subpaths" {
    var p = Path.init();
    _ = p
        .moveTo(0, 0)
        .lineTo(100, 0)
        .lineTo(100, 100)
        .closePath()
        .moveTo(200, 200)
        .lineTo(300, 200)
        .lineTo(300, 300)
        .closePath();

    // 2 moveTo + 4 lineTo + 2 closePath = 8 commands
    try std.testing.expectEqual(@as(usize, 8), p.commandCount());
}

test "closePath returns to subpath start" {
    var p = Path.init();
    _ = p
        .moveTo(10, 20)
        .lineTo(100, 20)
        .lineTo(100, 100)
        .closePath();

    try std.testing.expectEqual(@as(f32, 10), p.current.x);
    try std.testing.expectEqual(@as(f32, 20), p.current.y);
}

test "arcTo adds arc command" {
    var p = Path.init();
    _ = p
        .moveTo(100, 50)
        .arcTo(50, 50, 0, false, true, 50, 100);

    try std.testing.expectEqual(@as(usize, 2), p.commandCount());
    // moveTo uses 2 floats, arcTo uses 7 floats
    try std.testing.expectEqual(@as(usize, 9), p.data.len);
}

test "roundedRect clamps radius to half dimensions" {
    var p = Path.init();
    // Radius 100 is larger than half of width (50) and height (25)
    _ = p.roundedRect(0, 0, 100, 50, 100);

    // Should still produce valid path
    try std.testing.expect(p.commandCount() > 4);
}

test "toMesh produces valid triangle mesh" {
    var p = Path.init();
    _ = p.rect(0, 0, 100, 100);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);

    // Verify triangle indices are valid
    try std.testing.expect(mesh.indices.len % 3 == 0);

    // Verify all indices reference valid vertices
    for (mesh.indices.constSlice()) |idx| {
        try std.testing.expect(idx < mesh.vertices.len);
    }
}

test "toMesh bounds are correct" {
    var p = Path.init();
    _ = p.rect(10, 20, 80, 60);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);

    try std.testing.expectApproxEqAbs(@as(f32, 10), mesh.bounds.origin.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), mesh.bounds.origin.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), mesh.bounds.size.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), mesh.bounds.size.height, 0.01);
}

test "toMesh UV coordinates are normalized" {
    var p = Path.init();
    _ = p.rect(0, 0, 100, 100);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);

    for (mesh.vertices.constSlice()) |v| {
        try std.testing.expect(v.u >= 0 and v.u <= 1);
        try std.testing.expect(v.v >= 0 and v.v <= 1);
    }
}

test "toMesh empty path returns error" {
    var p = Path.init();
    const result = p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectError(error.EmptyPath, result);
}

test "toMesh tolerance affects vertex count" {
    var p1 = Path.init();
    _ = p1.circle(50, 50, 50);

    var p2 = Path.init();
    _ = p2.circle(50, 50, 50);

    const coarse_mesh = try p1.toMesh(std.testing.allocator, 10.0);
    const fine_mesh = try p2.toMesh(std.testing.allocator, 2.0);

    // Finer tolerance should produce more vertices
    try std.testing.expect(fine_mesh.vertices.len >= coarse_mesh.vertices.len);
}

test "hash differs for different command sequences" {
    var p1 = Path.init();
    _ = p1.rect(0, 0, 100, 100);

    var p2 = Path.init();
    _ = p2.circle(50, 50, 50);

    try std.testing.expect(p1.hash() != p2.hash());
}

test "toCachedMesh returns same ref for same path" {
    var p = Path.init();
    _ = p.rect(0, 0, 100, 100);

    var pool = MeshPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref1 = try p.toCachedMesh(&pool, std.testing.allocator, 0.5);
    const ref2 = try p.toCachedMesh(&pool, std.testing.allocator, 0.5);

    try std.testing.expectEqual(ref1.index(), ref2.index());
    try std.testing.expect(ref1.isPersistent());
}

test "toCachedMesh different paths get different refs" {
    var p1 = Path.init();
    _ = p1.rect(0, 0, 100, 100);

    var p2 = Path.init();
    _ = p2.rect(0, 0, 200, 200);

    var pool = MeshPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref1 = try p1.toCachedMesh(&pool, std.testing.allocator, 0.5);
    const ref2 = try p2.toCachedMesh(&pool, std.testing.allocator, 0.5);

    try std.testing.expect(ref1.index() != ref2.index());
}

test "pentagon produces correct triangles" {
    var p = Path.init();
    const cx: f32 = 50;
    const cy: f32 = 50;
    const r: f32 = 40;

    // Build pentagon
    var first = true;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / 5.0 - std.math.pi / 2.0;
        const x = cx + r * @cos(angle);
        const y = cy + r * @sin(angle);

        if (first) {
            _ = p.moveTo(x, y);
            first = false;
        } else {
            _ = p.lineTo(x, y);
        }
    }
    _ = p.closePath();

    const mesh = try p.toMesh(std.testing.allocator, 0.5);

    // Pentagon = 5 vertices, 3 triangles = 9 indices
    try std.testing.expectEqual(@as(usize, 5), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 9), mesh.indices.len);
}

test "concave L-shape triangulates correctly" {
    var p = Path.init();
    _ = p
        .moveTo(0, 0)
        .lineTo(100, 0)
        .lineTo(100, 50)
        .lineTo(50, 50)
        .lineTo(50, 100)
        .lineTo(0, 100)
        .closePath();

    const mesh = try p.toMesh(std.testing.allocator, 0.5);

    // 6 vertices, 4 triangles = 12 indices
    try std.testing.expectEqual(@as(usize, 6), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 12), mesh.indices.len);
}

test "arrow shape" {
    var p = Path.init();
    _ = p
        .moveTo(50, 0)
        .lineTo(100, 50)
        .lineTo(70, 50)
        .lineTo(70, 100)
        .lineTo(30, 100)
        .lineTo(30, 50)
        .lineTo(0, 50)
        .closePath();

    const mesh = try p.toMesh(std.testing.allocator, 0.5);

    // 7 vertices, 5 triangles = 15 indices
    try std.testing.expectEqual(@as(usize, 7), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 15), mesh.indices.len);
}

test "curved triangle with quadTo" {
    var p = Path.init();
    // Simple curved triangle - one curved edge, two straight edges
    _ = p.moveTo(0, 0);
    _ = p.quadTo(50, -30, 100, 0); // Curved top edge bulging up
    _ = p.lineTo(50, 80); // Straight to bottom point
    _ = p.closePath();

    const mesh = try p.toMesh(std.testing.allocator, 1.0);

    // Should have more vertices than a plain triangle due to curve flattening
    try std.testing.expect(mesh.vertices.len > 3);
    try std.testing.expect(mesh.indices.len >= 3);
}

test "path can be reused after reset" {
    var p = Path.init();
    _ = p.rect(0, 0, 100, 100);

    const mesh1 = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 4), mesh1.vertices.len);

    p.reset();
    _ = p.circle(50, 50, 50);

    const mesh2 = try p.toMesh(std.testing.allocator, 5.0);
    try std.testing.expect(mesh2.vertices.len > 4); // Circle has more vertices
}

test "very small shape" {
    var p = Path.init();
    _ = p.rect(0, 0, 0.001, 0.001);

    const mesh = try p.toMesh(std.testing.allocator, 0.0001);
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
}

test "negative coordinates" {
    var p = Path.init();
    _ = p.rect(-100, -50, 200, 100);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectApproxEqAbs(@as(f32, -100), mesh.bounds.origin.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -50), mesh.bounds.origin.y, 0.01);
}

test "large coordinates" {
    var p = Path.init();
    _ = p.rect(10000, 20000, 5000, 3000);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
}

test "degenerate arc handled gracefully" {
    var p = Path.init();
    _ = p
        .moveTo(0, 0)
        .arcTo(0.0001, 0.0001, 0, false, true, 100, 0) // Very small radii
        .lineTo(100, 50) // Add more points to make valid polygon
        .lineTo(0, 50)
        .closePath();

    // Should not crash, degenerate arc is handled
    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expect(mesh.vertices.len >= 3);
}

test "long fluent chain" {
    var p = Path.init();

    // Build a complex shape with many commands
    _ = p.moveTo(0, 0);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const x = @as(f32, @floatFromInt(i % 10)) * 10;
        const y = @as(f32, @floatFromInt(i / 10)) * 10;
        _ = p.lineTo(x, y);
    }
    _ = p.closePath();

    try std.testing.expectEqual(@as(usize, 102), p.commandCount());
}

// =============================================================================
// Adaptive Circle LOD Tests (P3)
// =============================================================================

test "circleWithSegments produces correct vertex count" {
    var p = Path.init();
    _ = p.circleWithSegments(50, 50, 20, 6); // Hexagon

    // moveTo + 5 lineTo + close = 7 commands
    try std.testing.expectEqual(@as(usize, 7), p.commandCount());

    // Mesh should have 6 vertices (hexagon)
    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 6), mesh.vertices.len);
}

test "circleWithSegments minimum 3 segments" {
    var p = Path.init();
    _ = p.circleWithSegments(0, 0, 10, 3); // Triangle

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 3), mesh.vertices.len);
}

test "circleAdaptive tiny radius uses 4 segments" {
    var p = Path.init();
    // radius 1 * scale 1 = 1 pixel screen radius -> 4 segments (square)
    _ = p.circleAdaptive(0, 0, 1, 1.0);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
}

test "circleAdaptive small radius uses 6 segments" {
    var p = Path.init();
    // radius 5 * scale 1 = 5 pixel screen radius -> 6 segments (hexagon)
    _ = p.circleAdaptive(0, 0, 5, 1.0);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 6), mesh.vertices.len);
}

test "circleAdaptive medium radius uses 12 segments" {
    var p = Path.init();
    // radius 20 * scale 1 = 20 pixel screen radius -> 12 segments
    _ = p.circleAdaptive(0, 0, 20, 1.0);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 12), mesh.vertices.len);
}

test "circleAdaptive large radius uses 24 segments" {
    var p = Path.init();
    // radius 64 * scale 1 = 64 pixel screen radius -> 24 segments
    _ = p.circleAdaptive(0, 0, 64, 1.0);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 24), mesh.vertices.len);
}

test "circleAdaptive very large radius uses 32 segments" {
    var p = Path.init();
    // radius 200 * scale 1 = 200 pixel screen radius -> 32 segments
    _ = p.circleAdaptive(0, 0, 200, 1.0);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 32), mesh.vertices.len);
}

test "circleAdaptive scale affects LOD" {
    // Same radius, different scales should produce different segment counts
    var p1 = Path.init();
    _ = p1.circleAdaptive(0, 0, 10, 0.5); // 10 * 0.5 = 5 px -> 6 segments
    const mesh1 = try p1.toMesh(std.testing.allocator, 0.5);

    var p2 = Path.init();
    _ = p2.circleAdaptive(0, 0, 10, 4.0); // 10 * 4 = 40 px -> 24 segments (>= 32)
    const mesh2 = try p2.toMesh(std.testing.allocator, 0.5);

    try std.testing.expectEqual(@as(usize, 6), mesh1.vertices.len);
    try std.testing.expectEqual(@as(usize, 24), mesh2.vertices.len);
}

test "ellipseWithSegments produces correct shape" {
    var p = Path.init();
    _ = p.ellipseWithSegments(50, 50, 30, 20, 8); // Octagon-ish ellipse

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 8), mesh.vertices.len);
}

test "ellipseAdaptive uses larger radius for LOD" {
    var p = Path.init();
    // rx=50, ry=10 -> max_radius=50 * scale 1 = 50 px -> 24 segments (>= 32)
    _ = p.ellipseAdaptive(0, 0, 50, 10, 1.0);

    const mesh = try p.toMesh(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(usize, 24), mesh.vertices.len);
}
