//! Per-frame GPU storage for the Metal renderer: one slot per frame in
//! flight, each holding the frame's copy of the packed instance arrays and
//! its atlas staging, all created at init from `RenderLimits` and never
//! replaced.
//!
//! In-flight safety: a slot is reused only after the command buffer that
//! last read it has completed (`acquire` waits on it), so no reasoning about
//! drawable counts is needed, and atlas uploads, which write a slot before
//! its frame has a drawable, are covered too.
//!
//! Resource sketch (CLAUDE.md §7), per slot, from the packed frame's
//! capacities (`packed_frame.zig`): quads and shadows × 96 B, sprites × 96 B,
//! mesh points × 8 B, triangles × 4 B of edge modes, and
//! `upload_bytes_frame_max` of staging. `.standard` (three slots): 4,608 ×
//! 96 + 9,472 × 96 + 65,536 × 8 + 5,461 × 4 + 1 MiB = 2,946,388 B per slot,
//! 8.4 MiB per window. Per frame: one memcpy of each array's used prefix
//! (typical frames a few KiB, the `.standard` worst case 1.9 MB) and the
//! uploads' bytes. Nothing allocates after init.

const std = @import("std");
const assert = std.debug.assert;

const objc = @import("objc");
const pipelines = @import("pipelines.zig");
const packed_frame = @import("../../../core/packed_frame.zig");
const backend = @import("../../../core/backend.zig");

const FrameBuffers = pipelines.FrameBuffers;
const Quad = packed_frame.Quad;
const Sprite = packed_frame.Sprite;
const MeshPoint = packed_frame.MeshPoint;
const EdgeModes = packed_frame.EdgeModes;

/// What one slot holds, in elements (`staging_bytes` in bytes).
pub const Capacity = struct {
    quads: u32,
    sprites: u32,
    points: u32,
    triangles: u32,
    staging_bytes: u32,

    pub fn fromLimits(limits: *const backend.RenderLimits) Capacity {
        assert(limits.scene.check() == null);
        assert(limits.atlas.upload_bytes_frame_max > 0);
        const scene = &limits.scene;
        return .{
            .quads = packed_frame.quadCapacity(scene),
            .sprites = packed_frame.spriteCapacity(scene),
            .points = @max(packed_frame.meshPointCapacity(scene), 1),
            .triangles = packed_frame.triangleCapacity(scene),
            .staging_bytes = limits.atlas.upload_bytes_frame_max,
        };
    }

    /// Bytes of one slot.
    pub fn slotBytes(self: *const Capacity) u64 {
        const bytes = @as(u64, self.quads) * @sizeOf(packed_frame.Quad) +
            @as(u64, self.sprites) * @sizeOf(packed_frame.Sprite) +
            @as(u64, self.points) * @sizeOf(packed_frame.MeshPoint) +
            @as(u64, self.triangles) * @sizeOf(packed_frame.EdgeModes) +
            self.staging_bytes;
        assert(bytes > self.staging_bytes);
        return bytes;
    }
};

pub const FrameSlots = struct {
    quads: FrameBuffers,
    sprites: FrameBuffers,
    points: FrameBuffers,
    edge_modes: FrameBuffers,
    staging: FrameBuffers,
    /// The committed command buffer that last read each slot (retained), or
    /// null once it has completed.
    command_buffers: [pipelines.frame_count_max]?objc.Object,
    capacity: Capacity,
    count: u32,
    index: u32,

    const Self = @This();

    pub fn init(self: *Self, device: objc.Object, limits: *const backend.RenderLimits) !void {
        const count = limits.frame.in_flight_count;
        assert(count <= pipelines.frame_count_max);
        const capacity = Capacity.fromLimits(limits);
        try checkWorkingSet(device, capacity.slotBytes() * count, count);
        const create = pipelines.createFrameBuffers;
        self.quads = try create(device, arrayBytes(Quad, capacity.quads), "quads", count);
        errdefer self.quads.release();
        self.sprites = try create(device, arrayBytes(Sprite, capacity.sprites), "sprites", count);
        errdefer self.sprites.release();
        const point_bytes = arrayBytes(MeshPoint, capacity.points);
        self.points = try create(device, point_bytes, "mesh_points", count);
        errdefer self.points.release();
        const edge_bytes = arrayBytes(EdgeModes, capacity.triangles);
        self.edge_modes = try create(device, edge_bytes, "edge_modes", count);
        errdefer self.edge_modes.release();
        self.staging = try create(device, capacity.staging_bytes, "atlas_staging", count);
        self.command_buffers = @splat(null);
        self.capacity = capacity;
        self.count = count;
        self.index = 0;
        assert(self.staging.count == count);
    }

    /// Wait for every frame in flight, then release the slots.
    pub fn deinit(self: *Self) void {
        assert(self.count <= pipelines.frame_count_max);
        for (self.command_buffers[0..self.count]) |*slot| waitAndRelease(slot);
        self.staging.release();
        self.edge_modes.release();
        self.points.release();
        self.sprites.release();
        self.quads.release();
        self.* = undefined;
    }

    /// Make the current slot writable: wait for the frame that last read it.
    pub fn acquire(self: *Self) void {
        assert(self.index < self.count);
        waitAndRelease(&self.command_buffers[self.index]);
        assert(self.command_buffers[self.index] == null);
    }

    /// Hand the current slot to `command_buffer`, committed and retained by
    /// the caller, and move to the next slot.
    pub fn retire(self: *Self, command_buffer: objc.Object) void {
        assert(self.index < self.count);
        assert(self.command_buffers[self.index] == null);
        self.command_buffers[self.index] = command_buffer;
        self.index = (self.index + 1) % self.count;
    }

    /// Copy the frame's instances into the current slot.
    pub fn copyFrame(self: *const Self, frame: *const packed_frame.PackedFrame) void {
        assert(self.command_buffers[self.index] == null);
        const index = self.index;
        const capacity = &self.capacity;
        copyInto(Quad, self.quads.at(index), capacity.quads, frame.quadList());
        copyInto(Sprite, self.sprites.at(index), capacity.sprites, frame.spriteList());
        copyInto(MeshPoint, self.points.at(index), capacity.points, frame.mesh_points);
        copyInto(EdgeModes, self.edge_modes.at(index), capacity.triangles, frame.edgeModeList());
    }

    pub fn stagingBuffer(self: *const Self) objc.Object {
        assert(self.command_buffers[self.index] == null);
        return self.staging.at(self.index);
    }
};

fn arrayBytes(comptime T: type, count: u32) u64 {
    assert(count > 0);
    return @as(u64, count) * @sizeOf(T);
}

/// The packed frame is reserved at the same limits as this renderer, so a
/// count past capacity means the two budgets disagree: a programmer error.
fn copyInto(comptime T: type, buffer: objc.Object, capacity: u32, source: []const T) void {
    assert(capacity > 0);
    assert(buffer.value != null);
    if (source.len > capacity) {
        std.debug.panic("Metal frame slot for {s} holds {d}, the frame has {d}: the " ++
            "renderer's RenderLimits and the window's packed frame disagree.", .{
            @typeName(T),
            capacity,
            source.len,
        });
    }
    const target = pipelines.frameBufferContents(T, buffer);
    @memcpy(target[0..source.len], source);
}

fn waitAndRelease(slot: *?objc.Object) void {
    const command_buffer = slot.* orelse return;
    assert(command_buffer.value != null);
    command_buffer.msgSend(void, "waitUntilCompleted", .{});
    command_buffer.release();
    slot.* = null;
    assert(slot.* == null);
}

/// Fail init when one window's slots exceed the device's recommended working
/// set. `createFrameBuffers` checks each buffer against `maxBufferLength`
/// only, which on Apple silicon is a large fraction of system memory.
fn checkWorkingSet(device: objc.Object, reservation_bytes: u64, frame_count: u32) !void {
    assert(reservation_bytes > 0);
    assert(frame_count > 0);
    const working_set_bytes_max: u64 = device.msgSend(u64, "recommendedMaxWorkingSetSize", .{});
    if (reservation_bytes <= working_set_bytes_max) return;
    std.log.err(
        "Metal frame reservation of {d} B per window ({d} frames in flight, " ++
            "ResourceLimits.scene and .atlas) exceeds the device's " ++
            "recommendedMaxWorkingSetSize of {d} B.",
        .{ reservation_bytes, frame_count, working_set_bytes_max },
    );
    return error.FrameReservationExceedsWorkingSet;
}
