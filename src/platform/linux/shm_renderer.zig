//! ShmRenderer - CPU rendering presented through Wayland shared memory.
//!
//! Selected with `-Dlinux-backend=wayland_cpu`. The Wayland window, input,
//! clipboard, and IME paths are the same as the Vulkan build; only the
//! renderer differs. Frames are rasterized by `platform/cpu/renderer.zig`
//! straight into a `wl_shm` buffer, so there is no extra copy and no GPU,
//! Vulkan loader, or driver involved. This is the path for machines without a
//! usable Vulkan driver: virtual machines, servers, and low-end hardware.
//!
//! ## Memory (CLAUDE.md §2)
//!
//! One `memfd` sized for `buffer_count` frames at the framework ceiling of
//! `framebuffer_width_max` x `framebuffer_height_max` is created and mapped
//! during initialization and never resized. A frame touches only the first
//! `width * height * 4` bytes of its slot, so resident memory follows the
//! window size even though the mapping is sized for the ceiling. A window
//! larger than the ceiling renders at a reduced effective scale instead of
//! failing; the compositor scales that buffer to the window's logical size.
//!
//! `wl_buffer` protocol objects are recreated when a slot is next drawn at a
//! new size. They describe a region of the existing pool and own no Gooey
//! memory.
//!
//! ## Pacing
//!
//! Each slot is busy from `attach` until the compositor's `release`. With two
//! slots, the window's frame callback pacing leaves one free in steady state.
//! If both are busy the frame is skipped and reported to the caller, which
//! keeps the redraw request pending for the next callback.

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland.zig");
const geometry = @import("../../core/geometry.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const cpu = @import("../cpu/renderer.zig");

const assert = std.debug.assert;
const Atlas = text_mod.Atlas;

/// Framework ceiling for one frame, in physical pixels (4K UHD).
pub const framebuffer_width_max: u32 = 3840;
pub const framebuffer_height_max: u32 = 2160;

/// One slot the compositor may still be reading, one being drawn.
pub const buffer_count: u32 = 2;

const bytes_per_pixel: u32 = 4;
const slot_bytes: usize = @as(usize, framebuffer_width_max) * framebuffer_height_max *
    bytes_per_pixel;
const pool_bytes: usize = slot_bytes * buffer_count;

comptime {
    // `wl_shm.create_pool` and `create_buffer` take signed 32-bit sizes.
    assert(pool_bytes <= std.math.maxInt(i32));
    assert(slot_bytes % std.heap.page_size_min == 0);
}

const buffer_listener = wayland.BufferListener{ .release = Slot.release };

const Slot = struct {
    buffer: ?*wayland.Buffer = null,
    /// Attached and not yet released by the compositor.
    busy: bool = false,
    width: u32 = 0,
    height: u32 = 0,

    fn release(data: ?*anyopaque, buffer: *wayland.Buffer) callconv(.c) void {
        const slot: *Slot = @ptrCast(@alignCast(data));
        assert(slot.buffer == buffer);
        assert(slot.busy);
        slot.busy = false;
    }
};

pub const ShmRenderer = struct {
    surface: ?*wayland.Surface = null,
    pool: ?*wayland.ShmPool = null,
    pool_fd: posix.fd_t = -1,
    pool_memory: []align(std.heap.page_size_min) u8 = &.{},
    slots: [buffer_count]Slot = @splat(.{}),

    /// Size of the frame being drawn, in physical pixels.
    width_px: u32 = 0,
    height_px: u32 = 0,
    /// Device pixels per logical pixel actually used. Equals the window's
    /// scale factor unless the window exceeds the framebuffer ceiling.
    effective_scale: f32 = 1.0,

    clear_color: geometry.Color = geometry.Color.rgba(0.1, 0.1, 0.12, 1.0),
    text_atlas: ?*const Atlas = null,
    svg_atlas: ?*const Atlas = null,
    image_atlas: ?*const Atlas = null,

    /// Primitive counts of the last presented frame.
    last_stats: cpu.RenderStats = .{},
    /// Frames skipped because the compositor still held every slot.
    frames_skipped: u64 = 0,

    const Self = @This();

    /// Create and map the shared-memory pool, then size the first frame.
    pub fn initWithSurface(
        self: *Self,
        shm: *wayland.Shm,
        surface: *wayland.Surface,
        logical_width: u32,
        logical_height: u32,
        scale_factor: f64,
    ) !void {
        assert(self.pool == null);
        assert(logical_width > 0 and logical_height > 0);

        const fd = try posix.memfd_create("gooey-shm", std.os.linux.MFD.CLOEXEC);
        errdefer _ = std.c.close(fd);

        if (std.c.ftruncate(fd, @intCast(pool_bytes)) != 0) return error.ShmResizeFailed;
        const memory = try posix.mmap(
            null,
            pool_bytes,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(memory);

        const pool = wayland.shmCreatePool(shm, fd, @intCast(pool_bytes)) orelse
            return error.ShmPoolCreateFailed;

        self.surface = surface;
        self.pool = pool;
        self.pool_fd = fd;
        self.pool_memory = memory;
        self.resize(logical_width, logical_height, scale_factor);
        assert(self.pool_memory.len == pool_bytes);
        assert(self.width_px > 0 and self.height_px > 0);
    }

    pub fn deinit(self: *Self) void {
        assert(self.pool_memory.len == 0 or self.pool_memory.len == pool_bytes);
        for (&self.slots) |*slot| {
            if (slot.buffer) |buffer| wayland.bufferDestroy(buffer);
            slot.* = .{};
        }
        if (self.pool) |pool| wayland.shmPoolDestroy(pool);
        self.pool = null;
        if (self.pool_memory.len > 0) posix.munmap(self.pool_memory);
        self.pool_memory = &.{};
        if (self.pool_fd >= 0) _ = std.c.close(self.pool_fd);
        self.pool_fd = -1;
        assert(self.pool == null);
    }

    /// Size the next frame for a window of the given logical size.
    pub fn resize(self: *Self, logical_width: u32, logical_height: u32, scale_factor: f64) void {
        assert(logical_width > 0 and logical_height > 0);
        assert(scale_factor > 0);
        const width_f: f64 = @floatFromInt(logical_width);
        const height_f: f64 = @floatFromInt(logical_height);
        const ceiling_scale = @min(
            @as(f64, @floatFromInt(framebuffer_width_max)) / width_f,
            @as(f64, @floatFromInt(framebuffer_height_max)) / height_f,
        );
        const scale = @min(scale_factor, ceiling_scale, cpu.scale_factor_max);
        // Truncate like the Vulkan swapchain extent so both backends agree.
        self.width_px = @max(1, @as(u32, @intFromFloat(width_f * scale)));
        self.height_px = @max(1, @as(u32, @intFromFloat(height_f * scale)));
        self.effective_scale = @floatCast(scale);
        assert(self.width_px <= framebuffer_width_max);
        assert(self.height_px <= framebuffer_height_max);
    }

    pub fn setClearColor(self: *Self, color: geometry.Color) void {
        assert(!std.math.isNan(color.a));
        assert(color.a >= 0 and color.a <= 1);
        self.clear_color = color;
    }

    /// Atlases are sampled in place each frame, so publishing them is only a
    /// pointer store; there is no upload to stage.
    pub fn setAtlases(
        self: *Self,
        text_atlas: ?*const Atlas,
        svg_atlas: ?*const Atlas,
        image_atlas: ?*const Atlas,
    ) void {
        if (text_atlas) |atlas| assert(atlas.format == .grayscale);
        if (svg_atlas) |atlas| assert(atlas.format == .rgba);
        self.text_atlas = text_atlas;
        self.svg_atlas = svg_atlas;
        self.image_atlas = image_atlas;
    }

    /// Draw `scene` into a free slot and commit it. Returns false when every
    /// slot is still held by the compositor and the frame was skipped.
    pub fn render(self: *Self, scene: *const scene_mod.Scene) bool {
        assert(self.pool != null);
        assert(self.width_px > 0 and self.height_px > 0);
        const index = self.freeSlotIndex() orelse {
            self.frames_skipped += 1;
            return false;
        };
        const slot = &self.slots[index];
        if (!self.prepareSlot(slot, index)) return false;

        const offset = index * slot_bytes;
        const pixel_count = @as(usize, self.width_px) * self.height_px;
        const pixel_bytes = self.pool_memory[offset..][0 .. pixel_count * bytes_per_pixel];
        const target = cpu.raster.Target{
            .pixels = @alignCast(std.mem.bytesAsSlice(u32, pixel_bytes)),
            .width = self.width_px,
            .height = self.height_px,
            .stride = self.width_px,
        };
        self.last_stats = cpu.renderScene(target, scene, &.{
            .scale_factor = self.effective_scale,
            .clear_color = self.clear_color,
            .text_atlas = self.text_atlas,
            .svg_atlas = self.svg_atlas,
            .image_atlas = self.image_atlas,
        });

        const surface = self.surface.?;
        wayland.surfaceAttach(surface, slot.buffer, 0, 0);
        wayland.surfaceDamageBuffer(surface, 0, 0, @intCast(slot.width), @intCast(slot.height));
        wayland.surfaceCommit(surface);
        slot.busy = true;
        return true;
    }

    fn freeSlotIndex(self: *const Self) ?usize {
        assert(self.slots.len == buffer_count);
        for (self.slots, 0..) |slot, index| {
            if (!slot.busy) return index;
        }
        return null;
    }

    /// Make the slot's `wl_buffer` match the current frame size. The slot is
    /// free, so the compositor holds no reference to its old buffer.
    fn prepareSlot(self: *Self, slot: *Slot, index: usize) bool {
        assert(!slot.busy);
        assert(index < buffer_count);
        if (slot.buffer != null and slot.width == self.width_px and slot.height == self.height_px) {
            return true;
        }
        if (slot.buffer) |old| wayland.bufferDestroy(old);
        slot.* = .{};

        const buffer = wayland.shmPoolCreateBuffer(
            self.pool.?,
            @intCast(index * slot_bytes),
            @intCast(self.width_px),
            @intCast(self.height_px),
            @intCast(self.width_px * bytes_per_pixel),
            wayland.WL_SHM_FORMAT_XRGB8888,
        ) orelse return false;
        _ = wayland.bufferAddListener(buffer, &buffer_listener, slot);
        slot.* = .{ .buffer = buffer, .width = self.width_px, .height = self.height_px };
        assert(slot.width * slot.height * bytes_per_pixel <= slot_bytes);
        return true;
    }
};
