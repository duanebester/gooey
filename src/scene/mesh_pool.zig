//! MeshPool - Two-tier mesh caching for optimal performance
//!
//! Tier 1: Persistent meshes (icons, static shapes) - cached by hash
//! Tier 2: Per-frame scratch (dynamic paths, animations) - reset each frame
//!
//! Usage patterns:
//! - Icons/static UI: Hash the SVG path string, use getOrCreatePersistent()
//! - Charts/animations: Use allocateFrame(), it auto-clears each frame
//! - Canvas callback paths: Always frame-local (user rebuilds each frame anyway)
//!
//! NOTE: MeshPool uses heap allocation for mesh storage (~88MB total) to avoid
//! stack overflow. Per CLAUDE.md, structs >50KB must be heap-allocated.

const std = @import("std");
const PathMesh = @import("path_mesh.zig").PathMesh;

// =============================================================================
// Constants (static allocation per CLAUDE.md)
// =============================================================================

/// Maximum persistent meshes (icons, static shapes)
pub const MAX_PERSISTENT_MESHES: u32 = 512;
/// Maximum per-frame meshes (dynamic paths)
pub const MAX_FRAME_MESHES: u32 = 256;

// =============================================================================
// Errors
// =============================================================================

pub const MeshPoolError = error{
    PersistentPoolFull,
    FramePoolFull,
    OutOfMemory,
};

// =============================================================================
// MeshRef - Reference to a mesh in either pool
// =============================================================================

pub const MeshRef = union(enum) {
    /// Reference to persistent mesh (cached across frames)
    persistent: u16,
    /// Reference to frame-local mesh (reset each frame)
    frame: u16,

    const Self = @This();

    /// Get the index regardless of pool type
    pub fn index(self: Self) u16 {
        return switch (self) {
            .persistent => |i| i,
            .frame => |i| i,
        };
    }

    /// Check if this is a persistent reference
    pub fn isPersistent(self: Self) bool {
        return switch (self) {
            .persistent => true,
            .frame => false,
        };
    }

    /// Check if this is a frame-local reference
    pub fn isFrame(self: Self) bool {
        return switch (self) {
            .persistent => false,
            .frame => true,
        };
    }

    /// Convert to u32 for GPU buffer (type in high bit, index in low bits)
    pub fn toGpuRef(self: Self) struct { ref_type: u32, ref_index: u32 } {
        return switch (self) {
            .persistent => |i| .{ .ref_type = 0, .ref_index = i },
            .frame => |i| .{ .ref_type = 1, .ref_index = i },
        };
    }
};

// =============================================================================
// MeshPool - Two-tier caching system (heap-allocated)
// =============================================================================

pub const MeshPool = struct {
    allocator: std.mem.Allocator,

    // Tier 1: Persistent meshes (icons, static shapes) - heap allocated
    persistent: ?[]PathMesh,
    persistent_hashes: [MAX_PERSISTENT_MESHES]u64,
    persistent_count: u32,

    // Tier 2: Per-frame scratch (dynamic paths, animations) - heap allocated
    frame_meshes: ?[]PathMesh,
    frame_count: u32,

    const Self = @This();

    /// Initialize empty mesh pool with lazy allocation
    /// Mesh arrays are allocated on first use to avoid upfront ~88MB allocation
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .persistent = null,
            .persistent_hashes = [_]u64{0} ** MAX_PERSISTENT_MESHES,
            .persistent_count = 0,
            .frame_meshes = null,
            .frame_count = 0,
        };
    }

    /// Free all allocated memory
    pub fn deinit(self: *Self) void {
        if (self.persistent) |p| {
            self.allocator.free(p);
            self.persistent = null;
        }
        if (self.frame_meshes) |f| {
            self.allocator.free(f);
            self.frame_meshes = null;
        }
        self.persistent_count = 0;
        self.frame_count = 0;
    }

    /// Ensure persistent mesh array is allocated
    fn ensurePersistentAllocated(self: *Self) MeshPoolError!void {
        if (self.persistent == null) {
            self.persistent = self.allocator.alloc(PathMesh, MAX_PERSISTENT_MESHES) catch {
                return error.OutOfMemory;
            };
        }
    }

    /// Ensure frame mesh array is allocated
    fn ensureFrameAllocated(self: *Self) MeshPoolError!void {
        if (self.frame_meshes == null) {
            self.frame_meshes = self.allocator.alloc(PathMesh, MAX_FRAME_MESHES) catch {
                return error.OutOfMemory;
            };
        }
    }

    /// Get or create persistent mesh (for static paths like icons)
    /// Hash should be computed from path data for cache lookup
    pub fn getOrCreatePersistent(
        self: *Self,
        mesh: PathMesh,
        hash: u64,
    ) MeshPoolError!MeshRef {
        // Assertions at API boundary
        std.debug.assert(hash != 0); // 0 is reserved for empty slot
        std.debug.assert(!mesh.isEmpty());

        // Check cache first
        for (self.persistent_hashes[0..self.persistent_count], 0..) |h, i| {
            if (h == hash) {
                return MeshRef{ .persistent = @intCast(i) };
            }
        }

        // Cache miss - store new mesh
        if (self.persistent_count >= MAX_PERSISTENT_MESHES) {
            return error.PersistentPoolFull;
        }

        // Lazy allocation of persistent array
        try self.ensurePersistentAllocated();

        const idx = self.persistent_count;
        self.persistent.?[idx] = mesh;
        self.persistent_hashes[idx] = hash;
        self.persistent_count += 1;

        return MeshRef{ .persistent = @intCast(idx) };
    }

    /// Allocate frame-local mesh (reset each frame)
    /// Use for dynamic paths that change every frame
    pub fn allocateFrame(self: *Self, mesh: PathMesh) MeshPoolError!MeshRef {
        std.debug.assert(!mesh.isEmpty());

        if (self.frame_count >= MAX_FRAME_MESHES) {
            return error.FramePoolFull;
        }

        // Lazy allocation of frame array
        try self.ensureFrameAllocated();

        const idx = self.frame_count;
        self.frame_meshes.?[idx] = mesh;
        self.frame_count += 1;

        return MeshRef{ .frame = @intCast(idx) };
    }

    /// Get mesh by reference
    pub fn getMesh(self: *const Self, ref: MeshRef) *const PathMesh {
        return switch (ref) {
            .persistent => |i| {
                std.debug.assert(i < self.persistent_count);
                std.debug.assert(self.persistent != null);
                return &self.persistent.?[i];
            },
            .frame => |i| {
                std.debug.assert(i < self.frame_count);
                std.debug.assert(self.frame_meshes != null);
                return &self.frame_meshes.?[i];
            },
        };
    }

    /// Get mutable mesh by reference
    pub fn getMeshMut(self: *Self, ref: MeshRef) *PathMesh {
        return switch (ref) {
            .persistent => |i| {
                std.debug.assert(i < self.persistent_count);
                std.debug.assert(self.persistent != null);
                return &self.persistent.?[i];
            },
            .frame => |i| {
                std.debug.assert(i < self.frame_count);
                std.debug.assert(self.frame_meshes != null);
                return &self.frame_meshes.?[i];
            },
        };
    }

    /// Call at frame start to reset scratch allocator
    pub fn resetFrame(self: *Self) void {
        self.frame_count = 0;
    }

    /// Clear persistent cache (e.g., on theme change or memory pressure)
    pub fn clearPersistent(self: *Self) void {
        self.persistent_count = 0;
        @memset(&self.persistent_hashes, 0);
    }

    /// Clear everything (persistent + frame)
    pub fn clearAll(self: *Self) void {
        self.clearPersistent();
        self.resetFrame();
    }

    /// Check if a hash exists in persistent cache
    pub fn hasPersistent(self: *const Self, hash: u64) bool {
        std.debug.assert(hash != 0);
        for (self.persistent_hashes[0..self.persistent_count]) |h| {
            if (h == hash) return true;
        }
        return false;
    }

    /// Get statistics for debugging
    pub fn getStats(self: *const Self) struct {
        persistent_count: u32,
        persistent_capacity: u32,
        frame_count: u32,
        frame_capacity: u32,
        persistent_allocated: bool,
        frame_allocated: bool,
    } {
        return .{
            .persistent_count = self.persistent_count,
            .persistent_capacity = MAX_PERSISTENT_MESHES,
            .frame_count = self.frame_count,
            .frame_capacity = MAX_FRAME_MESHES,
            .persistent_allocated = self.persistent != null,
            .frame_allocated = self.frame_meshes != null,
        };
    }
};

// =============================================================================
// Hash Helpers
// =============================================================================

/// Compute hash from path data for cache lookup
/// Uses FNV-1a hash algorithm
pub fn hashPath(data: []const u8) u64 {
    std.debug.assert(data.len > 0);

    const fnv_offset: u64 = 0xcbf29ce484222325;
    const fnv_prime: u64 = 0x100000001b3;

    var hash: u64 = fnv_offset;
    for (data) |byte| {
        hash ^= byte;
        hash *%= fnv_prime;
    }

    // Ensure non-zero (0 is reserved)
    return if (hash == 0) 1 else hash;
}

/// Compute hash from vertex positions (for runtime-generated paths)
pub fn hashVertices(vertices: []const f32) u64 {
    const bytes: []const u8 = @as([*]const u8, @ptrCast(vertices.ptr))[0 .. vertices.len * @sizeOf(f32)];
    return hashPath(bytes);
}

// =============================================================================
// Tests
// =============================================================================

test "MeshRef toGpuRef" {
    const persistent_ref = MeshRef{ .persistent = 42 };
    const gpu_ref = persistent_ref.toGpuRef();
    try std.testing.expectEqual(@as(u32, 0), gpu_ref.ref_type);
    try std.testing.expectEqual(@as(u32, 42), gpu_ref.ref_index);

    const frame_ref = MeshRef{ .frame = 7 };
    const gpu_ref2 = frame_ref.toGpuRef();
    try std.testing.expectEqual(@as(u32, 1), gpu_ref2.ref_type);
    try std.testing.expectEqual(@as(u32, 7), gpu_ref2.ref_index);
}

test "MeshPool persistent caching" {
    const triangulator = @import("../core/triangulator.zig");

    var pool = MeshPool.init(std.testing.allocator);
    defer pool.deinit();

    // Create a simple mesh
    const triangle = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0.5, .y = 1 },
    };
    const mesh = try PathMesh.fromConvexPolygon(&triangle);

    const hash: u64 = 12345;
    const ref1 = try pool.getOrCreatePersistent(mesh, hash);
    try std.testing.expect(ref1.isPersistent());

    // Same hash should return same ref (cache hit)
    const ref2 = try pool.getOrCreatePersistent(mesh, hash);
    try std.testing.expectEqual(ref1.index(), ref2.index());

    // Different hash should return different ref
    const ref3 = try pool.getOrCreatePersistent(mesh, 54321);
    try std.testing.expect(ref3.index() != ref1.index());
}

test "MeshPool frame allocation" {
    const triangulator = @import("../core/triangulator.zig");

    var pool = MeshPool.init(std.testing.allocator);
    defer pool.deinit();

    const triangle = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0.5, .y = 1 },
    };
    const mesh = try PathMesh.fromConvexPolygon(&triangle);

    const ref1 = try pool.allocateFrame(mesh);
    try std.testing.expect(ref1.isFrame());
    try std.testing.expectEqual(@as(u16, 0), ref1.index());

    const ref2 = try pool.allocateFrame(mesh);
    try std.testing.expectEqual(@as(u16, 1), ref2.index());

    // Reset should clear frame allocations
    pool.resetFrame();
    try std.testing.expectEqual(@as(u32, 0), pool.frame_count);

    // Should be able to allocate again from index 0
    const ref3 = try pool.allocateFrame(mesh);
    try std.testing.expectEqual(@as(u16, 0), ref3.index());
}

test "MeshPool hasPersistent" {
    const triangulator = @import("../core/triangulator.zig");

    var pool = MeshPool.init(std.testing.allocator);
    defer pool.deinit();

    const triangle = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0.5, .y = 1 },
    };
    const mesh = try PathMesh.fromConvexPolygon(&triangle);

    const hash: u64 = 99999;
    try std.testing.expect(!pool.hasPersistent(hash));

    _ = try pool.getOrCreatePersistent(mesh, hash);
    try std.testing.expect(pool.hasPersistent(hash));

    pool.clearPersistent();
    try std.testing.expect(!pool.hasPersistent(hash));
}

test "hashPath produces non-zero values" {
    const hash1 = hashPath("hello");
    try std.testing.expect(hash1 != 0);

    const hash2 = hashPath("world");
    try std.testing.expect(hash2 != 0);
    try std.testing.expect(hash1 != hash2);

    // Same input should produce same hash
    const hash3 = hashPath("hello");
    try std.testing.expectEqual(hash1, hash3);
}

test "MeshPool lazy allocation" {
    var pool = MeshPool.init(std.testing.allocator);
    defer pool.deinit();

    // Initially, nothing should be allocated
    const stats1 = pool.getStats();
    try std.testing.expect(!stats1.persistent_allocated);
    try std.testing.expect(!stats1.frame_allocated);

    // After using persistent, only persistent should be allocated
    const triangulator = @import("../core/triangulator.zig");
    const triangle = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0.5, .y = 1 },
    };
    const mesh = try PathMesh.fromConvexPolygon(&triangle);

    _ = try pool.getOrCreatePersistent(mesh, 12345);
    const stats2 = pool.getStats();
    try std.testing.expect(stats2.persistent_allocated);
    try std.testing.expect(!stats2.frame_allocated);

    // After using frame, both should be allocated
    _ = try pool.allocateFrame(mesh);
    const stats3 = pool.getStats();
    try std.testing.expect(stats3.persistent_allocated);
    try std.testing.expect(stats3.frame_allocated);
}
