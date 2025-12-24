//! BatchIterator - Yields primitive batches in draw order
//!
//! Merges sorted arrays of different primitive types, yielding
//! contiguous runs of same-type primitives for efficient rendering.
//!
//! ## Usage
//! ```
//! var iter = BatchIterator.init(scene);
//! while (iter.next()) |batch| {
//!     switch (batch) {
//!         .shadow => |shadows| drawShadowBatch(shadows),
//!         .quad => |quads| drawQuadBatch(quads),
//!         .glyph => |glyphs| drawGlyphBatch(glyphs),
//!         .svg => |svgs| drawSvgBatch(svgs),
//!     }
//! }
//! ```
//!
//! ## Performance
//! - No allocations - uses slices into existing scene arrays
//! - O(n) total work - each primitive visited once
//! - Coalesces consecutive same-type primitives to minimize pipeline switches

const std = @import("std");
const scene_mod = @import("scene.zig");
const SvgInstance = @import("svg_instance.zig").SvgInstance;
const ImageInstance = @import("image_instance.zig").ImageInstance;

pub const PrimitiveKind = enum(u8) {
    shadow,
    quad,
    glyph,
    svg,
    image,
};

pub const PrimitiveBatch = union(PrimitiveKind) {
    shadow: []const scene_mod.Shadow,
    quad: []const scene_mod.Quad,
    glyph: []const scene_mod.GlyphInstance,
    svg: []const SvgInstance,
    image: []const ImageInstance,

    pub fn len(self: PrimitiveBatch) usize {
        return switch (self) {
            .shadow => |s| s.len,
            .quad => |q| q.len,
            .glyph => |g| g.len,
            .svg => |sv| sv.len,
            .image => |img| img.len,
        };
    }
};

pub const BatchIterator = struct {
    shadows: []const scene_mod.Shadow,
    quads: []const scene_mod.Quad,
    glyphs: []const scene_mod.GlyphInstance,
    svgs: []const SvgInstance,
    images: []const ImageInstance,

    shadow_idx: usize = 0,
    quad_idx: usize = 0,
    glyph_idx: usize = 0,
    svg_idx: usize = 0,
    image_idx: usize = 0,

    const Self = @This();

    pub fn init(scene: *const scene_mod.Scene) Self {
        return .{
            .shadows = scene.getShadows(),
            .quads = scene.getQuads(),
            .glyphs = scene.getGlyphs(),
            .svgs = scene.getSvgInstances(),
            .images = scene.getImages(),
        };
    }

    /// Get the next batch of primitives to render
    pub fn next(self: *Self) ?PrimitiveBatch {
        // Get the current order for each type (null if exhausted)
        const shadow_order = self.peekOrder(.shadow);
        const quad_order = self.peekOrder(.quad);
        const glyph_order = self.peekOrder(.glyph);
        const svg_order = self.peekOrder(.svg);
        const image_order = self.peekOrder(.image);

        // Find minimum order (with tie-breaking by kind priority: shadow < quad < glyph < svg < image)
        var min_kind: ?PrimitiveKind = null;
        var min_order: scene_mod.DrawOrder = std.math.maxInt(scene_mod.DrawOrder);

        if (shadow_order) |order| {
            if (order < min_order) {
                min_order = order;
                min_kind = .shadow;
            }
        }
        if (quad_order) |order| {
            if (order < min_order) {
                min_order = order;
                min_kind = .quad;
            }
        }
        if (glyph_order) |order| {
            if (order < min_order) {
                min_order = order;
                min_kind = .glyph;
            }
        }
        if (svg_order) |order| {
            if (order < min_order) {
                min_order = order;
                min_kind = .svg;
            }
        }
        if (image_order) |order| {
            if (order < min_order) {
                min_order = order;
                min_kind = .image;
            }
        }

        const kind = min_kind orelse return null;

        // Consume all consecutive primitives of this type until we hit
        // a primitive of another type with a lower order
        return switch (kind) {
            .shadow => self.consumeShadows(quad_order, glyph_order, svg_order, image_order),
            .quad => self.consumeQuads(shadow_order, glyph_order, svg_order, image_order),
            .glyph => self.consumeGlyphs(shadow_order, quad_order, svg_order, image_order),
            .svg => self.consumeSvgs(shadow_order, quad_order, glyph_order, image_order),
            .image => self.consumeImages(shadow_order, quad_order, glyph_order, svg_order),
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
        };
    }

    /// Consume shadows until another type has a lower order
    fn consumeShadows(
        self: *Self,
        quad_order: ?scene_mod.DrawOrder,
        glyph_order: ?scene_mod.DrawOrder,
        svg_order: ?scene_mod.DrawOrder,
        image_order: ?scene_mod.DrawOrder,
    ) PrimitiveBatch {
        const start = self.shadow_idx;

        // Find the minimum order of OTHER types
        var other_min: scene_mod.DrawOrder = std.math.maxInt(scene_mod.DrawOrder);
        if (quad_order) |o| other_min = @min(other_min, o);
        if (glyph_order) |o| other_min = @min(other_min, o);
        if (svg_order) |o| other_min = @min(other_min, o);
        if (image_order) |o| other_min = @min(other_min, o);

        // Consume shadows while their order < other_min
        while (self.shadow_idx < self.shadows.len and
            self.shadows[self.shadow_idx].order < other_min)
        {
            self.shadow_idx += 1;
        }

        // Must consume at least one (we were called because shadow had min order)
        if (self.shadow_idx == start) self.shadow_idx += 1;

        return .{ .shadow = self.shadows[start..self.shadow_idx] };
    }

    /// Consume quads until another type has a lower order
    fn consumeQuads(
        self: *Self,
        shadow_order: ?scene_mod.DrawOrder,
        glyph_order: ?scene_mod.DrawOrder,
        svg_order: ?scene_mod.DrawOrder,
        image_order: ?scene_mod.DrawOrder,
    ) PrimitiveBatch {
        const start = self.quad_idx;

        var other_min: scene_mod.DrawOrder = std.math.maxInt(scene_mod.DrawOrder);
        if (shadow_order) |o| other_min = @min(other_min, o);
        if (glyph_order) |o| other_min = @min(other_min, o);
        if (svg_order) |o| other_min = @min(other_min, o);
        if (image_order) |o| other_min = @min(other_min, o);

        while (self.quad_idx < self.quads.len and
            self.quads[self.quad_idx].order < other_min)
        {
            self.quad_idx += 1;
        }

        if (self.quad_idx == start) self.quad_idx += 1;

        return .{ .quad = self.quads[start..self.quad_idx] };
    }

    /// Consume glyphs until another type has a lower order
    fn consumeGlyphs(
        self: *Self,
        shadow_order: ?scene_mod.DrawOrder,
        quad_order: ?scene_mod.DrawOrder,
        svg_order: ?scene_mod.DrawOrder,
        image_order: ?scene_mod.DrawOrder,
    ) PrimitiveBatch {
        const start = self.glyph_idx;

        var other_min: scene_mod.DrawOrder = std.math.maxInt(scene_mod.DrawOrder);
        if (shadow_order) |o| other_min = @min(other_min, o);
        if (quad_order) |o| other_min = @min(other_min, o);
        if (svg_order) |o| other_min = @min(other_min, o);
        if (image_order) |o| other_min = @min(other_min, o);

        while (self.glyph_idx < self.glyphs.len and
            self.glyphs[self.glyph_idx].order < other_min)
        {
            self.glyph_idx += 1;
        }

        if (self.glyph_idx == start) self.glyph_idx += 1;

        return .{ .glyph = self.glyphs[start..self.glyph_idx] };
    }

    /// Consume SVGs until another type has a lower order
    fn consumeSvgs(
        self: *Self,
        shadow_order: ?scene_mod.DrawOrder,
        quad_order: ?scene_mod.DrawOrder,
        glyph_order: ?scene_mod.DrawOrder,
        image_order: ?scene_mod.DrawOrder,
    ) PrimitiveBatch {
        const start = self.svg_idx;

        var other_min: scene_mod.DrawOrder = std.math.maxInt(scene_mod.DrawOrder);
        if (shadow_order) |o| other_min = @min(other_min, o);
        if (quad_order) |o| other_min = @min(other_min, o);
        if (glyph_order) |o| other_min = @min(other_min, o);
        if (image_order) |o| other_min = @min(other_min, o);

        while (self.svg_idx < self.svgs.len and
            self.svgs[self.svg_idx].order < other_min)
        {
            self.svg_idx += 1;
        }

        if (self.svg_idx == start) self.svg_idx += 1;

        return .{ .svg = self.svgs[start..self.svg_idx] };
    }

    /// Consume images until another type has a lower order
    fn consumeImages(
        self: *Self,
        shadow_order: ?scene_mod.DrawOrder,
        quad_order: ?scene_mod.DrawOrder,
        glyph_order: ?scene_mod.DrawOrder,
        svg_order: ?scene_mod.DrawOrder,
    ) PrimitiveBatch {
        const start = self.image_idx;

        var other_min: scene_mod.DrawOrder = std.math.maxInt(scene_mod.DrawOrder);
        if (shadow_order) |o| other_min = @min(other_min, o);
        if (quad_order) |o| other_min = @min(other_min, o);
        if (glyph_order) |o| other_min = @min(other_min, o);
        if (svg_order) |o| other_min = @min(other_min, o);

        while (self.image_idx < self.images.len and
            self.images[self.image_idx].order < other_min)
        {
            self.image_idx += 1;
        }

        if (self.image_idx == start) self.image_idx += 1;

        return .{ .image = self.images[start..self.image_idx] };
    }

    /// Check if iteration is complete
    pub fn done(self: *const Self) bool {
        return self.shadow_idx >= self.shadows.len and
            self.quad_idx >= self.quads.len and
            self.glyph_idx >= self.glyphs.len and
            self.svg_idx >= self.svgs.len and
            self.image_idx >= self.images.len;
    }

    /// Reset iterator to beginning
    pub fn reset(self: *Self) void {
        self.shadow_idx = 0;
        self.quad_idx = 0;
        self.glyph_idx = 0;
        self.svg_idx = 0;
        self.image_idx = 0;
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
