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
//! Everything is reserved while the window initializes, from the app's
//! `ResourceLimits`, and never resized:
//!
//! - One `memfd` holding `buffer_count` frames of
//!   `window.framebuffer_width_max` x `window.framebuffer_height_max` pixels,
//!   mapped once. A frame touches only the first `width * height * 4` bytes
//!   of its slot, so resident memory follows the window size although the
//!   mapping is sized for the budget (63.3 MiB of mapping at `.standard`).
//! - The CPU renderer's raster scratch (`cpu.Renderer.initInPlace`).
//!
//! A window larger than the budget renders at a reduced device scale, logged
//! once per transition, and the compositor scales the buffer to the window's
//! logical size. `wl_buffer` protocol objects are recreated when a slot is
//! next drawn at a new size; they describe a region of the existing pool and
//! own no Gooey memory.
//!
//! ## Pacing
//!
//! Each slot is busy from `attach` until the compositor's `release`. With two
//! slots, the window's frame callback pacing leaves one free in steady state.
//! If both are busy the frame is not drawn and the caller keeps its redraw
//! request pending for the next frame callback.

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland.zig");
const geometry = @import("../../core/geometry.zig");
const limits_mod = @import("../../core/limits.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const cpu = @import("../cpu/renderer.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Atlas = text_mod.Atlas;

/// One slot the compositor may still be reading, one being drawn. The CPU
/// renderer draws synchronously and has no GPU frames in flight, so it keeps
/// the minimum presentation depth at every rung; `ResourceLimits.frame` sizes
/// the GPU renderers' rings (see `FrameLimits`).
pub const buffer_count: u32 = limits_mod.MIN_FRAMES_IN_FLIGHT;

const bytes_per_pixel: u32 = 4;

comptime {
    // `wl_shm.create_pool` and `create_buffer` take signed 32-bit sizes, so
    // the pool must fit at the framework's largest window budget.
    const ceiling = limits_mod.WindowLimits.ceiling;
    const slot_bytes_max = ceiling.framebufferPixelCountMax() * bytes_per_pixel;
    assert(slot_bytes_max * buffer_count <= std.math.maxInt(i32));
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
    gpa: Allocator = undefined,
    surface: ?*wayland.Surface = null,
    pool: ?*wayland.ShmPool = null,
    pool_fd: posix.fd_t = -1,
    pool_memory: []align(std.heap.page_size_min) u8 = &.{},
    /// Bytes per slot: the budget's largest frame, rounded up to a page.
    slot_bytes: usize = 0,
    slots: [buffer_count]Slot = @splat(.{}),
    /// Valid while `pool` is set.
    renderer: cpu.Renderer = undefined,

    /// Size of the frame being drawn, in physical pixels.
    width_px: u32 = 0,
    height_px: u32 = 0,
    /// Device pixels per logical pixel actually used. Equals the window's
    /// scale factor unless the window exceeds the framebuffer budget.
    effective_scale: f32 = 1.0,
    /// The current size renders below the window's scale factor.
    downscaled: bool = false,

    clear_color: geometry.Color = geometry.Color.rgba(0.1, 0.1, 0.12, 1.0),

    /// Primitive counts of the last presented frame.
    last_stats: cpu.RenderStats = .{},
    /// Frames deferred because the compositor still held every slot.
    frames_deferred: u64 = 0,

    const Self = @This();

    /// Reserve the raster scratch and the shared-memory pool for the budget's
    /// largest frame, then size the first frame.
    pub fn initWithSurface(
        self: *Self,
        gpa: Allocator,
        shm: *wayland.Shm,
        surface: *wayland.Surface,
        logical_width: u32,
        logical_height: u32,
        scale_factor: f64,
        limits: *const limits_mod.ResourceLimits,
    ) !void {
        assert(self.pool == null);
        assert(logical_width > 0);
        assert(logical_height > 0);
        assert(limits.check() == null);

        try self.renderer.initInPlace(gpa, limits);
        errdefer self.renderer.deinit(gpa);

        const pixel_count_max = limits.window.framebufferPixelCountMax();
        const slot_bytes = std.mem.alignForward(
            usize,
            @intCast(pixel_count_max * bytes_per_pixel),
            std.heap.page_size_min,
        );
        const pool_bytes = slot_bytes * buffer_count;
        assert(pool_bytes <= std.math.maxInt(i32));

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

        self.gpa = gpa;
        self.surface = surface;
        self.pool = pool;
        self.pool_fd = fd;
        self.pool_memory = memory;
        self.slot_bytes = slot_bytes;
        self.resize(logical_width, logical_height, scale_factor);
        assert(self.pool_memory.len == pool_bytes);
        assert(self.width_px > 0);
        assert(self.height_px > 0);
    }

    pub fn deinit(self: *Self) void {
        assert(self.pool_memory.len == self.slot_bytes * buffer_count);
        if (self.pool == null) return;
        for (&self.slots) |*slot| {
            if (slot.buffer) |buffer| wayland.bufferDestroy(buffer);
            slot.* = .{};
        }
        wayland.shmPoolDestroy(self.pool.?);
        self.pool = null;
        posix.munmap(self.pool_memory);
        self.pool_memory = &.{};
        self.slot_bytes = 0;
        _ = std.c.close(self.pool_fd);
        self.pool_fd = -1;
        self.renderer.deinit(self.gpa);
        assert(self.pool == null);
    }

    /// Size the next frame for a window of the given logical size.
    pub fn resize(self: *Self, logical_width: u32, logical_height: u32, scale_factor: f64) void {
        assert(logical_width > 0);
        assert(logical_height > 0);
        assert(scale_factor > 0);
        const width_max = self.renderer.width_max;
        const height_max = self.renderer.height_max;
        const width_f: f64 = @floatFromInt(logical_width);
        const height_f: f64 = @floatFromInt(logical_height);
        const budget_scale = @min(
            @as(f64, @floatFromInt(width_max)) / width_f,
            @as(f64, @floatFromInt(height_max)) / height_f,
        );
        const scale = @min(scale_factor, budget_scale, cpu.scale_factor_max);
        // Truncate like the Vulkan swapchain extent so both backends agree.
        self.width_px = @max(1, @as(u32, @intFromFloat(width_f * scale)));
        self.height_px = @max(1, @as(u32, @intFromFloat(height_f * scale)));
        self.effective_scale = @floatCast(scale);
        const downscaled = scale < scale_factor;
        if (downscaled and !self.downscaled) {
            std.log.warn(
                "wl_shm: a {d}x{d} window at scale {d} exceeds ResourceLimits.window " ++
                    "({d}x{d} px, scale at most {d}); rendering at scale {d}",
                .{
                    logical_width, logical_height,       scale_factor, width_max,
                    height_max,    cpu.scale_factor_max, scale,
                },
            );
        }
        self.downscaled = downscaled;
        assert(self.width_px <= width_max);
        assert(self.height_px <= height_max);
    }

    pub fn setClearColor(self: *Self, color: geometry.Color) void {
        assert(!std.math.isNan(color.a));
        assert(color.a >= 0);
        assert(color.a <= 1);
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
        assert(self.pool != null);
        self.renderer.bindAtlases(.{ .text = text_atlas, .svg = svg_atlas, .image = image_atlas });
    }

    /// Draw `scene` into a free slot and commit it. Returns false when every
    /// slot is still held by the compositor and the frame was not drawn.
    pub fn render(self: *Self, scene: *const scene_mod.Scene) bool {
        assert(self.pool != null);
        assert(self.width_px > 0);
        assert(self.height_px > 0);
        const index = self.freeSlotIndex() orelse {
            self.frames_deferred += 1;
            return false;
        };
        const slot = &self.slots[index];
        self.prepareSlot(slot, index);

        const offset = index * self.slot_bytes;
        const pixel_count = @as(usize, self.width_px) * self.height_px;
        assert(pixel_count * bytes_per_pixel <= self.slot_bytes);
        const pixel_bytes = self.pool_memory[offset..][0 .. pixel_count * bytes_per_pixel];
        const target = cpu.raster.Target{
            .pixels = @alignCast(std.mem.bytesAsSlice(u32, pixel_bytes)),
            .width = self.width_px,
            .height = self.height_px,
            .stride = self.width_px,
        };
        self.last_stats = self.renderer.draw(
            target,
            scene,
            .{ .scale_factor = self.effective_scale },
            self.clear_color,
        );

        const surface = self.surface.?;
        wayland.surfaceAttach(surface, slot.buffer, 0, 0);
        wayland.surfaceDamageBuffer(surface, 0, 0, @intCast(slot.width), @intCast(slot.height));
        wayland.surfaceCommit(surface);
        slot.busy = true;
        return true;
    }

    fn freeSlotIndex(self: *const Self) ?usize {
        assert(self.slots.len == buffer_count);
        assert(self.pool != null);
        for (self.slots, 0..) |slot, index| {
            if (!slot.busy) return index;
        }
        return null;
    }

    /// Make the slot's `wl_buffer` match the current frame size. The slot is
    /// free, so the compositor holds no reference to its old buffer.
    fn prepareSlot(self: *Self, slot: *Slot, index: usize) void {
        assert(!slot.busy);
        assert(index < buffer_count);
        if (slot.buffer != null) {
            if (slot.width == self.width_px and slot.height == self.height_px) return;
        }
        if (slot.buffer) |old| wayland.bufferDestroy(old);
        slot.* = .{};

        // libwayland returns null only when it cannot allocate the proxy, and
        // a frame without a buffer cannot be presented at all.
        const buffer = wayland.shmPoolCreateBuffer(
            self.pool.?,
            @intCast(index * self.slot_bytes),
            @intCast(self.width_px),
            @intCast(self.height_px),
            @intCast(self.width_px * bytes_per_pixel),
            wayland.WL_SHM_FORMAT_XRGB8888,
        ) orelse std.debug.panic(
            "wl_shm_pool.create_buffer failed for slot {d} at {d}x{d}: libwayland is out of memory",
            .{ index, self.width_px, self.height_px },
        );
        if (!wayland.bufferAddListener(buffer, &buffer_listener, slot)) {
            std.debug.panic("wl_buffer.add_listener failed for slot {d}", .{index});
        }
        slot.* = .{ .buffer = buffer, .width = self.width_px, .height = self.height_px };
        assert(@as(usize, slot.width) * slot.height * bytes_per_pixel <= self.slot_bytes);
    }
};
