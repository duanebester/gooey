//! The Metal renderer on the `Renderer` contract (contract §9): it draws the
//! packed frame (`packed_frame.zig`) into a `CAMetalLayer`.
//!
//! A frame is one command buffer. It begins at the first `uploadAtlas` or
//! `draw` after the previous present: that call waits for the frame slot's
//! previous reader (`frame_slots.zig`) and creates the command buffer.
//! Uploads stage their pixels in the slot and encode blits; `draw` copies the
//! packed instance arrays into the slot, encodes one render pass over the
//! draws, presents, and commits. The packed frame is read only during `draw`.
//!
//! Performance sketch (CLAUDE.md §7): reservations are `frame_slots.zig`'s
//! (8.4 MiB at `.standard`), `atlas_textures.zig`'s (9 MiB), and seven
//! pipeline states. Per frame: one command buffer, at most one blit pass,
//! one render pass, the copies `frame_slots.zig` lists, and the draw calls
//! `encode.zig` lists. Window-sized storage is the layer's drawables, at most
//! `in_flight_count` of `limits.window`; nothing is recreated on resize.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");

const backend = @import("../../../core/backend.zig");
const packed_frame = @import("../../../core/packed_frame.zig");
const geometry = @import("../../../geometry/geometry.zig");
const limits_mod = @import("../../../core/limits.zig");
const mtl = @import("api.zig");
const pipelines_mod = @import("pipelines.zig");
const render_pass = @import("render_pass.zig");
const encode = @import("encode.zig");
const atlas_textures = @import("atlas_textures.zig");
const frame_slots = @import("frame_slots.zig");

pub const Renderer = struct {
    device: objc.Object,
    command_queue: objc.Object,
    layer: objc.Object,
    pipelines: pipelines_mod.Pipelines,
    atlas: atlas_textures.AtlasTextures,
    slots: frame_slots.FrameSlots,
    /// The frame being encoded (retained), from its first upload or draw
    /// until it is committed; null between frames.
    command_buffer: ?objc.Object,
    /// The open blit pass of this frame's atlas uploads.
    blit: ?objc.Object,
    staging_used_bytes: u32,
    size_px: backend.SizePx,
    limits: backend.RenderLimits,
    frame_skip_logged: bool,
    /// The drawable the last `draw` presented, not retained (it lives until
    /// the caller's autorelease pool drains); null when it presented none.
    /// The frame trace reads its `presentedTime` (`-Dframe-trace`).
    last_drawable: ?objc.Object,

    const Self = @This();

    comptime {
        backend.verifyRenderer(Self);
    }

    /// `surface.native` is the window's `CAMetalLayer`. Every buffer and
    /// texture is created here at `render_limits`; the layer keeps exactly
    /// `in_flight_count` drawables.
    pub noinline fn initInPlace(
        self: *Self,
        surface: *const backend.Surface,
        render_limits: *const backend.RenderLimits,
    ) !void {
        assert(surface.scale_factor > 0);
        assert(render_limits.paint.check() == null);
        const native = surface.native orelse return error.SurfaceMissing;
        try checkSize(surface.size_px, &render_limits.window);
        const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse
            return error.MetalNotAvailable;
        const device = objc.Object.fromId(device_ptr);
        errdefer device.release();
        const queue_ptr = device.msgSend(?*anyopaque, "newCommandQueue", .{}) orelse
            return error.CommandQueueCreationFailed;
        const command_queue = objc.Object.fromId(queue_ptr);
        errdefer command_queue.release();
        const layer = objc.Object.fromId(native);
        configureLayer(layer, device, surface.size_px, render_limits.frame.in_flight_count);

        self.pipelines = try pipelines_mod.Pipelines.init(device);
        errdefer self.pipelines.deinit();
        self.atlas = try atlas_textures.AtlasTextures.init(device, &render_limits.atlas);
        errdefer self.atlas.deinit();
        try self.slots.init(device, render_limits);
        self.device = device;
        self.command_queue = command_queue;
        self.layer = layer;
        self.command_buffer = null;
        self.blit = null;
        self.staging_used_bytes = 0;
        self.size_px = surface.size_px;
        self.limits = render_limits.*;
        self.frame_skip_logged = false;
        self.last_drawable = null;
        assert(self.slots.count == render_limits.frame.in_flight_count);
    }

    /// Finish any frame begun by uploads alone, wait for the GPU, release.
    pub fn deinit(self: *Self) void {
        assert(self.device.value != null);
        if (self.command_buffer != null) self.commitWithoutDrawing();
        assert(self.command_buffer == null);
        self.slots.deinit();
        self.atlas.deinit();
        self.pipelines.deinit();
        self.command_queue.release();
        self.device.release();
        self.* = undefined;
    }

    pub fn capabilities(self: *const Self) backend.Capabilities {
        assert(self.device.value != null);
        assert(self.slots.count > 0);
        return .{ .meshes = true };
    }

    pub fn resize(self: *Self, size_px: backend.SizePx) void {
        assert(size_px.width <= self.limits.window.framebuffer_width_max);
        assert(size_px.height <= self.limits.window.framebuffer_height_max);
        self.size_px = size_px;
        self.layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = @floatFromInt(size_px.width),
            .height = @floatFromInt(size_px.height),
        }});
    }

    /// Stage `pixels` in this frame's slot and encode their blit into the
    /// atlas texture. The staging is the journal's per-frame byte budget,
    /// which every frame's uploads fit by construction.
    pub fn uploadAtlas(
        self: *Self,
        kind: backend.AtlasKind,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) void {
        const byte_count = @as(u64, dirty.width) * dirty.height *
            atlas_textures.AtlasTextures.bytesPerPixel(kind);
        assert(pixels.len == byte_count);
        assert(byte_count > 0);
        const command_buffer = self.beginFrame();
        // Every record starts 4-byte aligned, as in the journal.
        const offset = std.mem.alignForward(u64, self.staging_used_bytes, 4);
        const capacity = self.slots.capacity.staging_bytes;
        if (offset + byte_count > capacity) {
            std.debug.panic("Metal atlas staging exhausted: capacity {d} B " ++
                "(ResourceLimits.atlas.upload_bytes_frame_max), {d} B in use, {d} B " ++
                "requested for the {t} atlas.", .{ capacity, offset, byte_count, kind });
        }
        const staging = self.slots.stagingBuffer();
        const target = pipelines_mod.frameBufferContents(u8, staging);
        @memcpy(target[offset..][0..pixels.len], pixels);
        self.staging_used_bytes = @intCast(offset + byte_count);
        const blit = self.blit orelse self.beginBlit(command_buffer);
        self.atlas.encodeCopy(blit, staging, .{
            .kind = kind,
            .dirty = dirty,
            .offset = @intCast(offset),
        });
    }

    /// Render every draw of `frame` into the next drawable, cleared to
    /// `clear`, and present it. With no drawable the frame is skipped,
    /// logged once, and its atlas uploads still reach the GPU.
    pub fn draw(
        self: *Self,
        frame: *const backend.PackedFrame,
        viewport: backend.Viewport,
        clear: geometry.Color,
    ) void {
        assert(viewport.scale_factor > 0);
        assert(viewport.size_px.width == self.size_px.width);
        assert(viewport.size_px.height == self.size_px.height);
        self.last_drawable = null;
        const command_buffer = self.beginFrame();
        self.endBlit();
        // A minimized window has nothing to draw into; its uploads still land.
        if (viewport.size_px.width == 0 or viewport.size_px.height == 0) {
            self.commitWithoutDrawing();
            return;
        }
        self.slots.copyFrame(frame);
        const pass = self.beginPass(command_buffer, clear) orelse {
            self.logFrameSkipped(frame.frame_number);
            self.commitWithoutDrawing();
            return;
        };
        render_pass.setViewport(pass.encoder, viewport.size_px);
        self.bindFrame(pass.encoder, viewport);
        encode.encodeDraws(pass.encoder, frame, &self.pipelines);
        render_pass.finishAndPresent(pass.encoder, command_buffer, pass.drawable);
        self.last_drawable = pass.drawable;
        self.retireFrame(command_buffer);
    }

    fn bindFrame(self: *const Self, encoder: objc.Object, viewport: backend.Viewport) void {
        assert(viewport.size_px.width > 0);
        assert(viewport.size_px.height > 0);
        const index = self.slots.index;
        const scale = viewport.scale_factor;
        encode.bindFrame(encoder, .{
            .quads = self.slots.quads.at(index),
            .sprites = self.slots.sprites.at(index),
            .points = self.slots.points.at(index),
            .edge_modes = self.slots.edge_modes.at(index),
            .textures = .{ self.atlas.glyph, self.atlas.svg, self.atlas.image },
            .viewport_logical = .{
                @as(f32, @floatFromInt(viewport.size_px.width)) / scale,
                @as(f32, @floatFromInt(viewport.size_px.height)) / scale,
            },
        });
    }

    /// The open frame's command buffer, or a new one once the slot it will
    /// write is free.
    fn beginFrame(self: *Self) objc.Object {
        if (self.command_buffer) |command_buffer| return command_buffer;
        assert(self.blit == null);
        self.slots.acquire();
        // Retained: the frame can outlive the caller's autorelease pool.
        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{})
            .msgSend(objc.Object, "retain", .{});
        self.command_buffer = command_buffer;
        self.staging_used_bytes = 0;
        assert(self.command_buffer != null);
        return command_buffer;
    }

    fn beginBlit(self: *Self, command_buffer: objc.Object) objc.Object {
        assert(self.blit == null);
        const blit_ptr = command_buffer.msgSend(?*anyopaque, "blitCommandEncoder", .{}) orelse
            std.debug.panic("Metal blitCommandEncoder failed for an atlas upload.", .{});
        const blit = objc.Object.fromId(blit_ptr);
        self.blit = blit;
        return blit;
    }

    fn endBlit(self: *Self) void {
        const blit = self.blit orelse return;
        assert(self.command_buffer != null);
        blit.msgSend(void, "endEncoding", .{});
        self.blit = null;
    }

    const Pass = struct { encoder: objc.Object, drawable: objc.Object };

    /// The render pass over the next drawable, or null when the layer has
    /// none to give (an operating failure: the frame is skipped).
    fn beginPass(self: *Self, command_buffer: objc.Object, clear: geometry.Color) ?Pass {
        assert(self.blit == null);
        assert(self.command_buffer != null);
        const drawable = render_pass.getNextDrawable(self.layer) orelse return null;
        const descriptor = render_pass.createSimpleRenderPass(.{
            .texture = drawable.texture,
            .clear_color = clear,
            .load_action = .clear,
            .store_action = .store,
        }) orelse return null;
        const encoder = render_pass.createEncoder(command_buffer, descriptor) orelse return null;
        return .{ .encoder = encoder, .drawable = drawable.drawable };
    }

    /// Commit the open frame with only its uploads, so no staged record is
    /// lost when nothing is drawn.
    fn commitWithoutDrawing(self: *Self) void {
        const command_buffer = self.command_buffer.?;
        self.endBlit();
        command_buffer.msgSend(void, "commit", .{});
        self.retireFrame(command_buffer);
    }

    fn retireFrame(self: *Self, command_buffer: objc.Object) void {
        assert(self.blit == null);
        assert(self.command_buffer.?.value == command_buffer.value);
        self.slots.retire(command_buffer);
        self.command_buffer = null;
    }

    fn logFrameSkipped(self: *Self, frame_number: u64) void {
        assert(self.command_buffer != null);
        if (self.frame_skip_logged) return;
        self.frame_skip_logged = true;
        std.log.err("Metal frame {d} not drawn: the layer gave no drawable. " ++
            "Later skipped frames are not logged.", .{frame_number});
    }
};

fn checkSize(size_px: backend.SizePx, window: *const limits_mod.WindowLimits) !void {
    assert(window.framebuffer_width_max > 0);
    assert(window.framebuffer_height_max > 0);
    if (size_px.width > window.framebuffer_width_max) return error.WindowTooLarge;
    if (size_px.height > window.framebuffer_height_max) return error.WindowTooLarge;
}

/// Bind `layer` to `device`, size its drawables, and cap them at the budget's
/// frames in flight. CAMetalLayer accepts 2 or 3, the range
/// `FrameLimits.check` enforces; two at `nano` and `small` drop one
/// window-sized surface.
fn configureLayer(
    layer: objc.Object,
    device: objc.Object,
    size_px: backend.SizePx,
    frame_count: u32,
) void {
    assert(frame_count >= 2);
    assert(frame_count <= 3);
    layer.msgSend(void, "setDevice:", .{device.value});
    layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
        .width = @floatFromInt(size_px.width),
        .height = @floatFromInt(size_px.height),
    }});
    layer.msgSend(void, "setMaximumDrawableCount:", .{@as(c_ulong, frame_count)});
    const drawable_count_max = layer.msgSend(c_ulong, "maximumDrawableCount", .{});
    assert(drawable_count_max == frame_count);
}
