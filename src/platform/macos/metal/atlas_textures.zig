//! Atlas textures for the Metal renderer.
//!
//! The glyph, SVG, and image atlas textures are created once at init at their
//! `AtlasLimits` sizes and never recreated (memory-budget decision 6). The
//! renderer keeps no CPU copy of atlas pixels (decision 8): each frame it copies
//! the records its window has not uploaded from the shared `AtlasUploads`
//! journal into this frame's staging buffer and encodes one blit pass that
//! writes them into the textures before the frame's render pass.
//!
//! Ordering: the blit runs in the same command buffer as the frame's draws, and
//! the textures use tracked hazards, so Metal orders it after every earlier
//! frame's reads and before this frame's reads. The atlas never reuses a region
//! until every renderer has uploaded the records written into it, so records in
//! one pass never overlap.
//!
//! Resource sketch (CLAUDE.md §7), `.standard`: private textures of 1 MiB (R8
//! 1024²) + 4 MiB + 4 MiB, plus `in_flight_count` × `upload_bytes_frame_max`
//! (3 × 1 MiB) of shared staging. Per frame: one memcpy of at most 1 MiB and at
//! most `upload_bytes_frame_max / 64` blit copies.

const std = @import("std");
const assert = std.debug.assert;

const objc = @import("objc");
const mtl = @import("api.zig");
const pipelines = @import("pipelines.zig");
const ResourceLimits = @import("../../../core/limits.zig").ResourceLimits;
const text_mod = @import("../../../text/mod.zig");
const AtlasUploads = text_mod.AtlasUploads;
const AtlasKind = text_mod.AtlasKind;

pub const AtlasTextures = struct {
    text: objc.Object,
    svg: objc.Object,
    image: objc.Object,
    /// One shared staging buffer per frame in flight.
    staging_buffers: pipelines.FrameBuffers,
    staging_bytes: u32,
    frame_index: u32,
    /// The journal this renderer consumes and its consumer key (`bind`).
    uploads: ?*AtlasUploads,
    key: usize,

    const Self = @This();

    pub fn init(device: objc.Object, resource_limits: *const ResourceLimits) !Self {
        assert(resource_limits.check() == null);
        const limits = &resource_limits.atlas;
        assert(limits.upload_bytes_frame_max > 0);
        const text = try createTexture(device, limits.text_size, .r8unorm);
        errdefer text.release();
        const svg = try createTexture(device, limits.svg_size, .rgba8unorm);
        errdefer svg.release();
        const image = try createTexture(device, limits.image_size, .rgba8unorm);
        errdefer image.release();
        const staging_buffers = try pipelines.createFrameBuffers(
            device,
            limits.upload_bytes_frame_max,
            "atlas_staging",
            resource_limits.frame.in_flight_count,
        );
        return .{
            .text = text,
            .svg = svg,
            .image = image,
            .staging_buffers = staging_buffers,
            .staging_bytes = limits.upload_bytes_frame_max,
            .frame_index = 0,
            .uploads = null,
            .key = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.staging_buffers.release();
        self.image.release();
        self.svg.release();
        self.text.release();
        self.* = undefined;
    }

    /// Bind the journal this renderer consumes, keyed by its platform window.
    pub fn bind(self: *Self, uploads: *AtlasUploads, key: usize) void {
        assert(key != 0);
        assert(uploads.storage == .gpu_upload);
        assert(uploads.bytes.len <= self.staging_bytes);
        self.uploads = uploads;
        self.key = key;
    }

    /// True when the bound journal holds records this renderer has not uploaded.
    pub fn hasPending(self: *const Self) bool {
        const uploads = self.uploads orelse return false;
        assert(self.key != 0);
        return uploads.hasPending(self.key);
    }

    /// Advance to the next frame-in-flight staging buffer. The ring's safety
    /// proof is `UnifiedPrimitiveRing`'s: at most `in_flight_count` frames in flight.
    pub fn nextFrame(self: *Self) void {
        self.frame_index = self.staging_buffers.nextIndex(self.frame_index);
    }

    /// Copy this window's pending records into the frame's staging buffer and
    /// encode their blits into `command_buffer`. Call after a drawable was
    /// acquired, so the command buffer is committed and no record is lost.
    pub fn encodeUploads(self: *Self, command_buffer: objc.Object) void {
        const uploads = self.uploads orelse return;
        assert(self.key != 0);
        const pending = uploads.consumeBegin(self.key);
        defer uploads.consumeEnd(self.key);
        if (pending.records.len == 0) return;

        const staging = self.staging_buffers.at(self.frame_index);
        assert(pending.bytes.len <= self.staging_bytes);
        const target = pipelines.frameBufferContents(u8, staging);
        @memcpy(target[0..pending.bytes.len], pending.bytes);

        const blit_ptr = command_buffer.msgSend(?*anyopaque, "blitCommandEncoder", .{}) orelse {
            std.debug.panic("Metal blitCommandEncoder failed with {d} atlas uploads pending.", .{
                pending.records.len,
            });
        };
        const blit = objc.Object.fromId(blit_ptr);
        for (pending.records) |record| {
            self.encodeCopy(blit, staging, record);
        }
        blit.msgSend(void, "endEncoding", .{});
    }

    fn encodeCopy(
        self: *const Self,
        blit: objc.Object,
        staging: objc.Object,
        record: text_mod.AtlasUpload,
    ) void {
        const texture = switch (record.kind) {
            .text => self.text,
            .svg => self.svg,
            .image => self.image,
        };
        const bytes_per_pixel = record.kind.bytesPerPixel();
        assert(record.offset % bytes_per_pixel == 0);
        assert(record.offset + record.byteCount() <= self.staging_bytes);
        const row_bytes = @as(c_ulong, record.width) * bytes_per_pixel;
        blit.msgSend(void, "copyFromBuffer:sourceOffset:sourceBytesPerRow:" ++
            "sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:" ++
            "destinationOrigin:", .{
            staging.value,
            @as(c_ulong, record.offset),
            row_bytes,
            row_bytes * record.height,
            mtl.MTLSize{ .width = record.width, .height = record.height, .depth = 1 },
            texture.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
            mtl.MTLOrigin{ .x = record.x, .y = record.y, .z = 0 },
        });
    }
};

/// A private, shader-read atlas texture. Its contents start undefined: every
/// uploaded item carries its own zero border and nothing else is sampled.
fn createTexture(device: objc.Object, size: u32, format: mtl.MTLPixelFormat) !objc.Object {
    assert(size > 0);
    assert(format == .r8unorm or format == .rgba8unorm);
    const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse
        return error.ClassNotFound;
    const descriptor = MTLTextureDescriptor.msgSend(
        objc.Object,
        "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        .{ @backingInt(format), @as(c_ulong, size), @as(c_ulong, size), false },
    );
    const usage = mtl.MTLTextureUsage.shader_read_only;
    descriptor.msgSend(void, "setUsage:", .{@as(c_ulong, @bitCast(usage))});
    descriptor.msgSend(void, "setStorageMode:", .{@backingInt(mtl.MTLStorageMode.private)});
    const texture_ptr = device.msgSend(?*anyopaque, "newTextureWithDescriptor:", .{
        descriptor.value,
    }) orelse return error.TextureCreationFailed;
    const texture = objc.Object.fromId(texture_ptr);
    assert(texture.msgSend(c_ulong, "width", .{}) == size);
    return texture;
}
