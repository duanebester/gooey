//! Atlas uploads for the Direct3D 11 renderer, on the GPU timeline.
//!
//! The contract (§9) has `uploadAtlas` copy a record before it returns, and
//! has the region reach its texture after every draw submitted earlier and
//! before the next draw samples it, never by a CPU write into a texture an
//! in-flight frame may sample. Direct3D 11 has no buffer-to-texture copy, and
//! a staging texture would need a 2D packer with no tight bound for the
//! journal's mixed record sizes. So each frame in flight owns a fixed staging
//! buffer:
//!
//! 1. `stage` writes the record's descriptor and pixels into the frame's
//!    staging buffer, mapped from the first record of the frame until the
//!    flush.
//! 2. `flush`, at the start of the next `draw`, copies the used ranges into
//!    one default buffer with `CopySubresourceRegion` in the immediate context,
//!    then draws one pixel-exact quad per record into its atlas, bound as the
//!    render target (`shaders/upload.hlsl`). Both are ordered after earlier
//!    frames' draws and before this frame's.
//!
//! Staging set `n mod frame_count` was last copied from `frame_count` flushes
//! ago, which the swapchain's latency waitable has retired; were it not,
//! `Map(WRITE)` would wait for the copy rather than race it.
//!
//! Resource sketch (CLAUDE.md §7), `.standard`: `upload_bytes_frame_max` is
//! 1 MiB, so the journal holds at most 16,384 records (one per 64 B). Each
//! staging buffer and the default buffer hold 16,384 × 16 B of descriptors
//! and 1 MiB of pixels: 1.25 MiB each, 5 MiB with 3 frames in flight. A frame
//! with uploads costs one map, two copies, and one draw per atlas written; a
//! frame without them costs nothing.

const std = @import("std");
const d3d11 = @import("d3d11.zig");
const dx11_device = @import("dx11_device.zig");
const dx11_resources = @import("dx11_resources.zig");
const limits_mod = @import("../../core/limits.zig");
const backend = @import("../../core/backend.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.dx11);
const hex = dx11_device.hex;

/// The smallest record the journal stages (`atlas_uploads.record_bytes_min`),
/// which bounds the records of one frame by its byte budget.
const record_bytes_min: u32 = 64;
/// One record descriptor: four `u32` words (`shaders/upload.hlsl`).
const descriptor_bytes: u32 = 16;
/// Record pixels start on a word, as the shader reads whole words.
const pixel_alignment: u32 = 4;

/// The atlases, numbered as the kind in a record's last word.
pub const Slot = enum(u32) { glyph, svg, image };
pub const atlas_count: u32 = @typeInfo(Slot).@"enum".field_names.len;

/// An atlas as `flush` draws into it.
pub const Target = struct {
    view: *d3d11.ID3D11RenderTargetView,
    side_px: u32,
};

const vertex_dxbc = [atlas_count][]const u8{
    @embedFile("shaders/upload.vs_glyph.dxbc"),
    @embedFile("shaders/upload.vs_svg.dxbc"),
    @embedFile("shaders/upload.vs_image.dxbc"),
};

pub const Uploads = struct {
    /// CPU-written copies of `words`, one per frame in flight.
    staging: [limits_mod.MAX_FRAMES_IN_FLIGHT]*d3d11.ID3D11Buffer,
    staging_count: u32,
    staging_index: u32,
    /// The staging buffer mapped for this frame's records, or null.
    mapped: ?[*]u8,
    /// Descriptors, then pixels, as `upload.hlsl` reads them.
    words: *d3d11.ID3D11Buffer,
    words_view: *d3d11.ID3D11ShaderResourceView,
    vertex: [atlas_count]*d3d11.ID3D11VertexShader,
    layout: *d3d11.ID3D11InputLayout,
    pixel_r8: *d3d11.ID3D11PixelShader,
    pixel_rgba8: *d3d11.ID3D11PixelShader,
    record_count: u32,
    record_count_max: u32,
    /// Records staged this frame per atlas, so empty atlases draw nothing.
    record_counts: [atlas_count]u32,
    pixel_bytes: u32,
    pixel_bytes_max: u32,

    const Self = @This();

    /// Records one frame may stage: the journal's own bound.
    pub fn recordCountMax(atlas: *const limits_mod.AtlasLimits) u32 {
        assert(atlas.upload_bytes_frame_max >= record_bytes_min);
        const count = @divFloor(atlas.upload_bytes_frame_max, record_bytes_min);
        assert(count > 0);
        return count;
    }

    pub fn init(
        self: *Self,
        device: *const dx11_device.Device,
        atlas: *const limits_mod.AtlasLimits,
        frame_count: u32,
    ) dx11_resources.ResourceError!void {
        assert(frame_count > 0);
        assert(frame_count <= limits_mod.MAX_FRAMES_IN_FLIGHT);
        self.record_count_max = recordCountMax(atlas);
        self.pixel_bytes_max = std.mem.alignForward(u32, atlas.upload_bytes_frame_max, 4);
        const bytes = self.record_count_max * descriptor_bytes + self.pixel_bytes_max;
        assert(bytes <= dx11_resources.buffer_bytes_max);

        try self.initShaders(device);
        errdefer self.releaseShaders();
        try self.initWords(device, bytes);
        errdefer self.releaseWords();

        var created: u32 = 0;
        errdefer for (self.staging[0..created]) |buffer| buffer.release();
        while (created < frame_count) : (created += 1) {
            self.staging[created] = try createStaging(device, bytes);
        }
        self.staging_count = frame_count;
        self.staging_index = 0;
        self.mapped = null;
        self.record_count = 0;
        self.record_counts = @splat(0);
        self.pixel_bytes = 0;
        assert(created == frame_count);
    }

    pub fn deinit(self: *Self, context: *d3d11.ID3D11DeviceContext) void {
        assert(self.staging_count > 0);
        if (self.mapped != null) {
            context.vtable.Unmap(context, self.staging[self.staging_index].resource(), 0);
        }
        for (self.staging[0..self.staging_count]) |buffer| buffer.release();
        self.releaseWords();
        self.releaseShaders();
        self.* = undefined;
    }

    fn initShaders(self: *Self, device: *const dx11_device.Device) !void {
        var vertex_count: u32 = 0;
        errdefer for (self.vertex[0..vertex_count]) |shader| shader.release();
        for (vertex_dxbc) |bytecode| {
            self.vertex[vertex_count] = try dx11_resources.createVertexShader(device, bytecode);
            vertex_count += 1;
        }
        // Every upload vertex shader takes the same single input.
        self.layout = try dx11_resources.createInstanceLayout(device, vertex_dxbc[0]);
        errdefer self.layout.release();
        const r8 = @embedFile("shaders/upload.ps_r8.dxbc");
        self.pixel_r8 = try dx11_resources.createPixelShader(device, r8);
        errdefer self.pixel_r8.release();
        const rgba8 = @embedFile("shaders/upload.ps_rgba8.dxbc");
        self.pixel_rgba8 = try dx11_resources.createPixelShader(device, rgba8);
        assert(vertex_count == atlas_count);
    }

    fn releaseShaders(self: *Self) void {
        self.pixel_rgba8.release();
        self.pixel_r8.release();
        self.layout.release();
        for (self.vertex) |shader| shader.release();
    }

    fn initWords(self: *Self, device: *const dx11_device.Device, bytes: u32) !void {
        assert(bytes % 4 == 0);
        const desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = bytes,
            .Usage = d3d11.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = 0,
            .MiscFlags = d3d11.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
            .StructureByteStride = 4,
        };
        self.words = try dx11_resources.createBuffer(device, &desc, "atlas upload words");
        errdefer self.words.release();
        self.words_view = try dx11_resources.createView(
            device,
            self.words.resource(),
            "atlas upload words",
        );
    }

    fn releaseWords(self: *Self) void {
        self.words_view.release();
        self.words.release();
    }

    /// Copy one journal record into this frame's staging buffer. Returns
    /// false when the staging buffer cannot be mapped (the device is lost).
    pub fn stage(
        self: *Self,
        context: *d3d11.ID3D11DeviceContext,
        slot: Slot,
        side_px: u32,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) bool {
        assert(dirty.x + dirty.width <= side_px);
        assert(dirty.y + dirty.height <= side_px);
        assert(side_px <= std.math.maxInt(u16));
        const pixel_size: u32 = if (slot == .glyph) 1 else 4;
        assert(pixels.len == @as(usize, dirty.width) * dirty.height * pixel_size);
        const pixel_bytes = std.mem.alignForward(u32, @intCast(pixels.len), pixel_alignment);
        if (self.record_count == self.record_count_max) self.exhausted(pixels.len);
        if (pixel_bytes > self.pixel_bytes_max - self.pixel_bytes) self.exhausted(pixels.len);
        const target = self.mapped orelse self.map(context) orelse return false;
        const records_bytes = self.record_count_max * descriptor_bytes;
        const address = records_bytes + self.pixel_bytes;
        const descriptor = [4]u32{
            address,
            dirty.x | dirty.y << 16,
            dirty.width | dirty.height << 16,
            side_px | @backingInt(slot) << 16,
        };
        const descriptor_offset = self.record_count * descriptor_bytes;
        @memcpy(target[descriptor_offset..][0..descriptor_bytes], std.mem.asBytes(&descriptor));
        @memcpy(target[address..][0..pixels.len], pixels);
        self.record_count += 1;
        self.record_counts[@backingInt(slot)] += 1;
        self.pixel_bytes += pixel_bytes;
        assert(self.pixel_bytes <= self.pixel_bytes_max);
        return true;
    }

    /// Land this frame's staged records in their atlases, ahead of any draw
    /// recorded after it, and start the next frame's staging set. Leaves no
    /// render target bound. Does nothing when nothing was staged.
    pub fn flush(
        self: *Self,
        context: *d3d11.ID3D11DeviceContext,
        targets: *const [atlas_count]Target,
        instance_indices: *d3d11.ID3D11Buffer,
        rasterizer: *d3d11.ID3D11RasterizerState,
    ) void {
        if (self.record_count == 0) {
            assert(self.mapped == null);
            return;
        }
        assert(self.mapped != null);
        const staging = self.staging[self.staging_index].resource();
        context.vtable.Unmap(context, staging, 0);
        self.mapped = null;
        self.copyStaged(context, staging);

        // The atlases may still be bound for sampling from the last frame.
        const no_views = [_]?*d3d11.ID3D11ShaderResourceView{null};
        context.vtable.PSSetShaderResources(context, 3, 1, &no_views);
        const streams = [_]?*d3d11.ID3D11Buffer{instance_indices};
        const strides = [_]u32{@sizeOf(u32)};
        const offsets = [_]u32{0};
        context.vtable.IASetVertexBuffers(context, 0, 1, &streams, &strides, &offsets);
        context.vtable.IASetInputLayout(context, self.layout);
        context.vtable.IASetPrimitiveTopology(context, d3d11.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        const views = [_]?*d3d11.ID3D11ShaderResourceView{self.words_view};
        context.vtable.VSSetShaderResources(context, 0, 1, &views);
        context.vtable.PSSetShaderResources(context, 0, 1, &views);
        // Records replace atlas pixels; nothing blends.
        context.vtable.OMSetBlendState(context, null, null, 0xFFFF_FFFF);
        context.vtable.RSSetState(context, rasterizer);
        for (targets, 0..) |*target, index| {
            if (self.record_counts[index] == 0) continue;
            self.drawRecords(context, target, @fromBackingInt(@intCast(index)));
        }
        context.vtable.OMSetRenderTargets(context, 0, null, null);

        self.record_count = 0;
        self.record_counts = @splat(0);
        self.pixel_bytes = 0;
        self.staging_index = (self.staging_index + 1) % self.staging_count;
        assert(self.mapped == null);
    }

    /// Copy the used descriptors and pixels from `staging` into `words`.
    fn copyStaged(
        self: *const Self,
        context: *d3d11.ID3D11DeviceContext,
        staging: *d3d11.ID3D11Resource,
    ) void {
        assert(self.record_count > 0);
        assert(self.pixel_bytes > 0);
        const records_bytes = self.record_count_max * descriptor_bytes;
        const ranges = [_][2]u32{
            .{ 0, self.record_count * descriptor_bytes },
            .{ records_bytes, records_bytes + self.pixel_bytes },
        };
        for (ranges) |range| {
            const box = d3d11.D3D11_BOX{
                .left = range[0],
                .top = 0,
                .front = 0,
                .right = range[1],
                .bottom = 1,
                .back = 1,
            };
            const words = self.words.resource();
            const copy = context.vtable.CopySubresourceRegion;
            copy(context, words, 0, range[0], 0, 0, staging, 0, &box);
        }
    }

    /// Draw every staged record through `slot`'s vertex shader, which keeps
    /// only that atlas's, into `target`, in journal order.
    fn drawRecords(
        self: *const Self,
        context: *d3d11.ID3D11DeviceContext,
        target: *const Target,
        slot: Slot,
    ) void {
        assert(target.side_px > 0);
        assert(self.record_counts[@backingInt(slot)] > 0);
        const target_views = [_]?*d3d11.ID3D11RenderTargetView{target.view};
        context.vtable.OMSetRenderTargets(context, 1, &target_views, null);
        const side: f32 = @floatFromInt(target.side_px);
        const viewport = d3d11.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = side,
            .Height = side,
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        context.vtable.RSSetViewports(context, 1, (&viewport)[0..1]);
        const side_i: i32 = @intCast(target.side_px);
        const scissor = d3d11.D3D11_RECT{ .left = 0, .top = 0, .right = side_i, .bottom = side_i };
        context.vtable.RSSetScissorRects(context, 1, (&scissor)[0..1]);
        context.vtable.VSSetShader(context, self.vertex[@backingInt(slot)], null, 0);
        const pixel = if (slot == .glyph) self.pixel_r8 else self.pixel_rgba8;
        context.vtable.PSSetShader(context, pixel, null, 0);
        context.vtable.DrawInstanced(context, 6, self.record_count, 0, 0);
    }

    /// The journal never pends more than one frame's budget, so overflowing
    /// staging sized from the same budget is a programmer error.
    fn exhausted(self: *const Self, requested_bytes: usize) noreturn {
        std.debug.panic("dx11 atlas upload staging exhausted: {d} of {d} records and " ++
            "{d} of {d} bytes used, 1 record of {d} B requested. The journal stages at " ++
            "most AtlasLimits.upload_bytes_frame_max per frame.", .{
            self.record_count,
            self.record_count_max,
            self.pixel_bytes,
            self.pixel_bytes_max,
            requested_bytes,
        });
    }

    fn map(self: *Self, context: *d3d11.ID3D11DeviceContext) ?[*]u8 {
        assert(self.mapped == null);
        assert(self.record_count == 0);
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        const staging = self.staging[self.staging_index].resource();
        const result = context.vtable.Map(context, staging, 0, d3d11.D3D11_MAP_WRITE, 0, &mapped);
        if (!d3d11.succeeded(result)) {
            log.err("Map(atlas upload staging) failed: 0x{X:0>8}", .{hex(result)});
            return null;
        }
        assert(mapped.pData != null);
        self.mapped = @ptrCast(mapped.pData.?);
        return self.mapped;
    }
};

fn createStaging(
    device: *const dx11_device.Device,
    bytes: u32,
) dx11_resources.ResourceError!*d3d11.ID3D11Buffer {
    assert(bytes > 0);
    assert(bytes % 4 == 0);
    const desc = d3d11.D3D11_BUFFER_DESC{
        .ByteWidth = bytes,
        .Usage = d3d11.D3D11_USAGE_STAGING,
        .BindFlags = 0,
        .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
        .MiscFlags = 0,
        .StructureByteStride = 0,
    };
    return dx11_resources.createBuffer(device, &desc, "atlas upload staging");
}
