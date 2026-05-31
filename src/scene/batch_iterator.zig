//! BatchIterator - yields primitive batches in draw order.
//!
//! Merges the scene's per-type sorted primitive arrays into a single draw-order
//! stream, yielding contiguous runs of the same primitive type. Coalescing
//! consecutive same-type primitives minimizes GPU pipeline switches. Iteration
//! performs zero allocations (batches are slices into the existing scene arrays)
//! and is O(n), visiting each primitive exactly once.

const std = @import("std");
const scene_mod = @import("scene.zig");
const SvgInstance = @import("svg_instance.zig").SvgInstance;
const ImageInstance = @import("image_instance.zig").ImageInstance;
const PathInstance = @import("path_instance.zig").PathInstance;
const Polyline = @import("polyline.zig").Polyline;
const PointCloud = @import("point_cloud.zig").PointCloud;
const ColoredPointCloud = @import("colored_point_cloud.zig").ColoredPointCloud;

pub const PrimitiveKind = enum(u8) {
    shadow,
    quad,
    glyph,
    svg,
    image,
    path,
    polyline,
    point_cloud,
    colored_point_cloud,
};

pub const PrimitiveBatch = union(PrimitiveKind) {
    shadow: []const scene_mod.Shadow,
    quad: []const scene_mod.Quad,
    glyph: []const scene_mod.GlyphInstance,
    svg: []const SvgInstance,
    image: []const ImageInstance,
    path: []const PathInstance,
    polyline: []const Polyline,
    point_cloud: []const PointCloud,
    colored_point_cloud: []const ColoredPointCloud,

    pub fn len(self: PrimitiveBatch) usize {
        return switch (self) {
            .shadow => |s| s.len,
            .quad => |q| q.len,
            .glyph => |g| g.len,
            .svg => |sv| sv.len,
            .image => |img| img.len,
            .path => |p| p.len,
            .polyline => |pl| pl.len,
            .point_cloud => |pc| pc.len,
            .colored_point_cloud => |cpc| cpc.len,
        };
    }
};

pub const BatchIterator = struct {
    shadows: []const scene_mod.Shadow,
    quads: []const scene_mod.Quad,
    glyphs: []const scene_mod.GlyphInstance,
    svgs: []const SvgInstance,
    images: []const ImageInstance,
    paths: []const PathInstance,
    polylines: []const Polyline,
    point_clouds: []const PointCloud,
    colored_point_clouds: []const ColoredPointCloud,

    shadow_idx: usize = 0,
    quad_idx: usize = 0,
    glyph_idx: usize = 0,
    svg_idx: usize = 0,
    image_idx: usize = 0,
    path_idx: usize = 0,
    polyline_idx: usize = 0,
    point_cloud_idx: usize = 0,
    colored_point_cloud_idx: usize = 0,

    const Self = @This();

    pub fn init(scene: *const scene_mod.Scene) Self {
        return .{
            .shadows = scene.getShadows(),
            .quads = scene.getQuads(),
            .glyphs = scene.getGlyphs(),
            .svgs = scene.getSvgInstances(),
            .images = scene.getImages(),
            .paths = scene.getPathInstances(),
            .polylines = scene.getPolylines(),
            .point_clouds = scene.getPointClouds(),
            .colored_point_clouds = scene.getColoredPointClouds(),
        };
    }

    /// Get the next batch of primitives to render
    pub fn next(self: *Self) ?PrimitiveBatch {
        // Draw-order priority for ties (lowest first), matching GPUI's fixed
        // type order: shadow < quad < glyph < svg < image < path < polyline <
        // point_cloud < colored_point_cloud. The arrays are in this order so the
        // strict `<` below lets the earliest kind win an equal-order tie.
        const orders = [_]?scene_mod.DrawOrder{
            self.peekOrder(.shadow),
            self.peekOrder(.quad),
            self.peekOrder(.glyph),
            self.peekOrder(.svg),
            self.peekOrder(.image),
            self.peekOrder(.path),
            self.peekOrder(.polyline),
            self.peekOrder(.point_cloud),
            self.peekOrder(.colored_point_cloud),
        };
        const kinds = [_]PrimitiveKind{
            .shadow, .quad,     .glyph,       .svg,                 .image,
            .path,   .polyline, .point_cloud, .colored_point_cloud,
        };

        // Single pass finds both the minimum order (which kind to emit) and the
        // second-smallest order across all other types (the threshold at which
        // the batch must stop). Folding the threshold into the min scan avoids a
        // second 8-way `minOfOrders` pass per `next()` call. `batch_threshold`
        // tracks the two smallest orders with multiplicity, so it equals the
        // minimum order among every type except the chosen `min_kind`.
        var min_kind: ?PrimitiveKind = null;
        var min_order: scene_mod.DrawOrder = std.math.maxInt(scene_mod.DrawOrder);
        var batch_threshold: scene_mod.DrawOrder = std.math.maxInt(scene_mod.DrawOrder);

        inline for (orders, kinds) |maybe_order, kind| {
            if (maybe_order) |order| {
                if (order < min_order) {
                    batch_threshold = min_order; // previous min is now the runner-up
                    min_order = order;
                    min_kind = kind;
                } else if (order < batch_threshold) {
                    batch_threshold = order;
                }
            }
        }

        const kind = min_kind orelse return null;

        // Consume all consecutive primitives of this type until another type's
        // order would interleave (i.e. `order >= batch_threshold`).
        return switch (kind) {
            inline else => |comptime_kind| self.consumeBatch(comptime_kind, batch_threshold),
        };
    }

    /// Peek at the order of the next primitive of a given type
    fn peekOrder(self: *const Self, kind: PrimitiveKind) ?scene_mod.DrawOrder {
        return switch (kind) {
            .shadow => if (self.shadow_idx < self.shadows.len) self.shadows[self.shadow_idx].order else null,
            .quad => if (self.quad_idx < self.quads.len) self.quads[self.quad_idx].order else null,
            .glyph => if (self.glyph_idx < self.glyphs.len) self.glyphs[self.glyph_idx].order else null,
            .svg => if (self.svg_idx < self.svgs.len) self.svgs[self.svg_idx].order else null,
            .image => if (self.image_idx < self.images.len) self.images[self.image_idx].order else null,
            .path => if (self.path_idx < self.paths.len) self.paths[self.path_idx].order else null,
            .polyline => if (self.polyline_idx < self.polylines.len) self.polylines[self.polyline_idx].order else null,
            .point_cloud => if (self.point_cloud_idx < self.point_clouds.len) self.point_clouds[self.point_cloud_idx].order else null,
            .colored_point_cloud => if (self.colored_point_cloud_idx < self.colored_point_clouds.len) self.colored_point_clouds[self.colored_point_cloud_idx].order else null,
        };
    }

    /// Consume primitives of a given kind until another type has a lower order.
    /// Returns a batch slice of the consumed primitives.
    fn consumeBatch(self: *Self, comptime kind: PrimitiveKind, other_min: scene_mod.DrawOrder) PrimitiveBatch {
        return switch (kind) {
            .shadow => blk: {
                const start = self.shadow_idx;
                while (self.shadow_idx < self.shadows.len and
                    self.shadows[self.shadow_idx].order < other_min)
                {
                    self.shadow_idx += 1;
                }
                // Must consume at least one (we were called because this type had min order)
                if (self.shadow_idx == start) self.shadow_idx += 1;
                break :blk .{ .shadow = self.shadows[start..self.shadow_idx] };
            },
            .quad => blk: {
                const start = self.quad_idx;
                while (self.quad_idx < self.quads.len and
                    self.quads[self.quad_idx].order < other_min)
                {
                    self.quad_idx += 1;
                }
                if (self.quad_idx == start) self.quad_idx += 1;
                break :blk .{ .quad = self.quads[start..self.quad_idx] };
            },
            .glyph => blk: {
                const start = self.glyph_idx;
                while (self.glyph_idx < self.glyphs.len and
                    self.glyphs[self.glyph_idx].order < other_min)
                {
                    self.glyph_idx += 1;
                }
                if (self.glyph_idx == start) self.glyph_idx += 1;
                break :blk .{ .glyph = self.glyphs[start..self.glyph_idx] };
            },
            .svg => blk: {
                const start = self.svg_idx;
                while (self.svg_idx < self.svgs.len and
                    self.svgs[self.svg_idx].order < other_min)
                {
                    self.svg_idx += 1;
                }
                if (self.svg_idx == start) self.svg_idx += 1;
                break :blk .{ .svg = self.svgs[start..self.svg_idx] };
            },
            .image => blk: {
                const start = self.image_idx;
                while (self.image_idx < self.images.len and
                    self.images[self.image_idx].order < other_min)
                {
                    self.image_idx += 1;
                }
                if (self.image_idx == start) self.image_idx += 1;
                break :blk .{ .image = self.images[start..self.image_idx] };
            },
            .path => blk: {
                const start = self.path_idx;
                while (self.path_idx < self.paths.len and
                    self.paths[self.path_idx].order < other_min)
                {
                    self.path_idx += 1;
                }
                if (self.path_idx == start) self.path_idx += 1;
                break :blk .{ .path = self.paths[start..self.path_idx] };
            },
            .polyline => blk: {
                const start = self.polyline_idx;
                while (self.polyline_idx < self.polylines.len and
                    self.polylines[self.polyline_idx].order < other_min)
                {
                    self.polyline_idx += 1;
                }
                if (self.polyline_idx == start) self.polyline_idx += 1;
                break :blk .{ .polyline = self.polylines[start..self.polyline_idx] };
            },
            .point_cloud => blk: {
                const start = self.point_cloud_idx;
                while (self.point_cloud_idx < self.point_clouds.len and
                    self.point_clouds[self.point_cloud_idx].order < other_min)
                {
                    self.point_cloud_idx += 1;
                }
                if (self.point_cloud_idx == start) self.point_cloud_idx += 1;
                break :blk .{ .point_cloud = self.point_clouds[start..self.point_cloud_idx] };
            },
            .colored_point_cloud => blk: {
                const start = self.colored_point_cloud_idx;
                while (self.colored_point_cloud_idx < self.colored_point_clouds.len and
                    self.colored_point_clouds[self.colored_point_cloud_idx].order < other_min)
                {
                    self.colored_point_cloud_idx += 1;
                }
                if (self.colored_point_cloud_idx == start) self.colored_point_cloud_idx += 1;
                break :blk .{ .colored_point_cloud = self.colored_point_clouds[start..self.colored_point_cloud_idx] };
            },
        };
    }

    /// Check if iteration is complete
    pub fn done(self: *const Self) bool {
        return self.shadow_idx >= self.shadows.len and
            self.quad_idx >= self.quads.len and
            self.glyph_idx >= self.glyphs.len and
            self.svg_idx >= self.svgs.len and
            self.image_idx >= self.images.len and
            self.path_idx >= self.paths.len and
            self.polyline_idx >= self.polylines.len and
            self.point_cloud_idx >= self.point_clouds.len and
            self.colored_point_cloud_idx >= self.colored_point_clouds.len;
    }

    /// Reset iterator to beginning
    pub fn reset(self: *Self) void {
        self.shadow_idx = 0;
        self.quad_idx = 0;
        self.glyph_idx = 0;
        self.svg_idx = 0;
        self.image_idx = 0;
        self.path_idx = 0;
        self.polyline_idx = 0;
        self.point_cloud_idx = 0;
        self.colored_point_cloud_idx = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BatchIterator - empty scene" {
    var scene = scene_mod.Scene.init(std.testing.allocator);
    defer scene.deinit();

    var iter = BatchIterator.init(&scene);
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.done());
}

test "BatchIterator - single type" {
    var scene = scene_mod.Scene.init(std.testing.allocator);
    defer scene.deinit();

    // Insert 3 quads
    try scene.insertQuad(scene_mod.Quad.filled(0, 0, 100, 100, scene_mod.Hsla.red));
    try scene.insertQuad(scene_mod.Quad.filled(10, 10, 100, 100, scene_mod.Hsla.green));
    try scene.insertQuad(scene_mod.Quad.filled(20, 20, 100, 100, scene_mod.Hsla.blue));

    var iter = BatchIterator.init(&scene);

    // Should get all quads in one batch
    const batch = iter.next() orelse unreachable;
    try std.testing.expect(batch == .quad);
    try std.testing.expectEqual(@as(usize, 3), batch.quad.len);

    // No more batches
    try std.testing.expect(iter.next() == null);
}

test "BatchIterator - interleaved types" {
    var scene = scene_mod.Scene.init(std.testing.allocator);
    defer scene.deinit();

    // Insert: shadow(0), quad(1), glyph(2), quad(3)
    try scene.insertShadow(scene_mod.Shadow.drop(0, 0, 100, 100, 10));
    try scene.insertQuad(scene_mod.Quad.filled(0, 0, 100, 100, scene_mod.Hsla.red));
    try scene.insertGlyph(scene_mod.GlyphInstance.init(0, 0, 10, 10, 0, 0, 1, 1, scene_mod.Hsla.black));
    try scene.insertQuad(scene_mod.Quad.filled(10, 10, 100, 100, scene_mod.Hsla.green));

    var iter = BatchIterator.init(&scene);

    // Batch 1: shadow
    const batch1 = iter.next() orelse unreachable;
    try std.testing.expect(batch1 == .shadow);
    try std.testing.expectEqual(@as(usize, 1), batch1.shadow.len);

    // Batch 2: quad (only 1 because glyph comes next)
    const batch2 = iter.next() orelse unreachable;
    try std.testing.expect(batch2 == .quad);
    try std.testing.expectEqual(@as(usize, 1), batch2.quad.len);

    // Batch 3: glyph
    const batch3 = iter.next() orelse unreachable;
    try std.testing.expect(batch3 == .glyph);
    try std.testing.expectEqual(@as(usize, 1), batch3.glyph.len);

    // Batch 4: remaining quad
    const batch4 = iter.next() orelse unreachable;
    try std.testing.expect(batch4 == .quad);
    try std.testing.expectEqual(@as(usize, 1), batch4.quad.len);

    // Done
    try std.testing.expect(iter.next() == null);
}

test "BatchIterator - coalesces consecutive same type" {
    var scene = scene_mod.Scene.init(std.testing.allocator);
    defer scene.deinit();

    // Insert: quad(0), quad(1), quad(2), glyph(3), quad(4), quad(5)
    try scene.insertQuad(scene_mod.Quad.filled(0, 0, 100, 100, scene_mod.Hsla.red));
    try scene.insertQuad(scene_mod.Quad.filled(10, 10, 100, 100, scene_mod.Hsla.green));
    try scene.insertQuad(scene_mod.Quad.filled(20, 20, 100, 100, scene_mod.Hsla.blue));
    try scene.insertGlyph(scene_mod.GlyphInstance.init(0, 0, 10, 10, 0, 0, 1, 1, scene_mod.Hsla.black));
    try scene.insertQuad(scene_mod.Quad.filled(30, 30, 100, 100, scene_mod.Hsla.red));
    try scene.insertQuad(scene_mod.Quad.filled(40, 40, 100, 100, scene_mod.Hsla.green));

    var iter = BatchIterator.init(&scene);

    // Batch 1: 3 quads coalesced
    const batch1 = iter.next() orelse unreachable;
    try std.testing.expect(batch1 == .quad);
    try std.testing.expectEqual(@as(usize, 3), batch1.quad.len);

    // Batch 2: glyph
    const batch2 = iter.next() orelse unreachable;
    try std.testing.expect(batch2 == .glyph);
    try std.testing.expectEqual(@as(usize, 1), batch2.glyph.len);

    // Batch 3: 2 quads coalesced
    const batch3 = iter.next() orelse unreachable;
    try std.testing.expect(batch3 == .quad);
    try std.testing.expectEqual(@as(usize, 2), batch3.quad.len);

    // Done
    try std.testing.expect(iter.next() == null);
}
