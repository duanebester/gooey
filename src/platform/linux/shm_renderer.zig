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
//! - The CPU renderer's raster scratch and atlases (`cpu.Renderer.initInPlace`).
//!
//! `ShmRenderer` is a contract `Renderer` (`backend.verifyRenderer`): the host
//! feeds atlas records through `uploadAtlas`, sizes it with `resize`, and
//! draws with `draw`. A window larger than the budget renders at a reduced
//! device scale the host chooses (`backend.Viewport.fitLogical`), and the
//! compositor scales the buffer to the window's logical size. `wl_buffer`
//! protocol objects are recreated when a slot is next drawn at a new size;
//! they describe a region of the existing pool and own no Gooey memory.
//!
//! ## Pacing
//!
//! Each slot is busy from `attach` until the compositor's `release`. With two
//! slots, the window's frame callback pacing leaves one free in steady state,
//! and the host draws only once one is free (`hasFreeSlot`). If both are busy
//! anyway the frame is skipped and logged once.

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland.zig");
const backend = @import("../../core/backend.zig");
const limits_mod = @import("../../core/limits.zig");
const PackedFrame = @import("../../core/packed_frame.zig").PackedFrame;
const cpu = @import("../cpu/renderer.zig");

const assert = std.debug.assert;

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

/// What `initInPlace` takes as `Surface.native`: the compositor's `wl_shm`
/// and the window's surface, both of which must outlive the renderer.
pub const NativeSurface = struct {
    shm: *wayland.Shm,
    surface: *wayland.Surface,
};

pub const ShmRenderer = struct {
    surface: ?*wayland.Surface = null,
    pool: ?*wayland.ShmPool = null,
    pool_fd: posix.fd_t = -1,
    pool_memory: []align(std.heap.page_size_min) u8 = &.{},
    /// Bytes per slot: the budget's largest frame, rounded up to a page.
    slot_bytes: usize = 0,
    slots: [buffer_count]Slot = @splat(.{}),
    /// Valid while `pool` is set.
    renderer: cpu.Renderer = undefined,
    /// The framebuffer size of the last `resize` (or init), which `draw`
    /// asserts. Zero on either axis while the window has no extent.
    size_px: backend.SizePx = .{ .width = 0, .height = 0 },
    window_limits: limits_mod.WindowLimits = undefined,

    /// Primitive counts of the last presented frame.
    last_stats: cpu.RenderStats = .{},
    /// Frames skipped because the compositor still held every slot.
    frames_deferred: u64 = 0,
    /// A skipped frame was logged and no frame has been drawn since.
    skip_logged: bool = false,

    const Self = @This();

    comptime {
        backend.verifyRenderer(Self);
    }

    /// Reserve the raster scratch, the atlases, and the shared-memory pool for
    /// the budget's largest frame, and size the first frame. `surface.native`
    /// points at a `NativeSurface`.
    pub fn initInPlace(
        self: *Self,
        surface: *const backend.Surface,
        limits: *const backend.RenderLimits,
    ) !void {
        assert(self.pool == null);
        assert(surface.size_px.width > 0);
        assert(surface.size_px.height > 0);
        const native: *const NativeSurface = @ptrCast(@alignCast(surface.native.?));

        try self.renderer.initInPlace(limits);
        errdefer self.renderer.deinit();

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

        const pool = wayland.shmCreatePool(native.shm, fd, @intCast(pool_bytes)) orelse
            return error.ShmPoolCreateFailed;

        self.surface = native.surface;
        self.pool = pool;
        self.pool_fd = fd;
        self.pool_memory = memory;
        self.slot_bytes = slot_bytes;
        self.window_limits = limits.window;
        self.resize(surface.size_px);
        assert(self.pool_memory.len == pool_bytes);
        assert(std.meta.eql(self.size_px, surface.size_px));
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
        self.renderer.deinit();
        assert(self.pool == null);
    }

    /// Copy an atlas region into the CPU renderer's atlas. Drawing is
    /// synchronous, so no earlier frame still reads it.
    pub fn uploadAtlas(
        self: *Self,
        kind: backend.AtlasKind,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) void {
        assert(self.pool != null);
        assert(pixels.len > 0);
        self.renderer.uploadAtlas(kind, dirty, pixels);
    }

    /// Size the next frames at `size_px` device pixels, within the budget.
    /// Slot buffers follow when each slot is next drawn.
    pub fn resize(self: *Self, size_px: backend.SizePx) void {
        assert(self.pool != null);
        assert(size_px.width <= self.window_limits.framebuffer_width_max);
        assert(size_px.height <= self.window_limits.framebuffer_height_max);
        self.size_px = size_px;
    }

    pub fn capabilities(self: *const Self) backend.Capabilities {
        assert(self.pool != null);
        assert(self.slot_bytes > 0);
        return self.renderer.capabilities();
    }

    /// Deliver the compositor's buffer releases on `queue` (null: the default
    /// queue). A thread that draws on its own queue routes them there, so the
    /// slots it reads are written only on that thread. Slot buffers made
    /// later inherit the pool's queue; existing ones move with it.
    pub fn setEventQueue(self: *Self, queue: ?*wayland.EventQueue) void {
        assert(self.pool != null);
        wayland.wl_proxy_set_queue(@ptrCast(self.pool.?), queue);
        for (self.slots) |slot| {
            if (slot.buffer) |buffer| wayland.wl_proxy_set_queue(@ptrCast(buffer), queue);
        }
        assert(self.slots.len == buffer_count);
    }

    /// A slot the compositor has released, so `draw` will present.
    pub fn hasFreeSlot(self: *const Self) bool {
        return self.freeSlotIndex() != null;
    }

    /// Draw `frame` into a free slot and commit it. A zero-size viewport
    /// presents nothing; uploads already landed in `uploadAtlas`. When the
    /// compositor holds every slot the frame is skipped and logged once.
    pub fn draw(
        self: *Self,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
        clear: backend.Color,
    ) void {
        assert(self.pool != null);
        assert(std.meta.eql(viewport.size_px, self.size_px));
        if (self.size_px.width == 0 or self.size_px.height == 0) return;
        const index = self.freeSlotIndex() orelse {
            self.frames_deferred += 1;
            if (!self.skip_logged) {
                std.log.warn("wl_shm: frame {d} skipped: the compositor holds every buffer", .{
                    frame.frame_number,
                });
            }
            self.skip_logged = true;
            return;
        };
        self.skip_logged = false;
        const slot = &self.slots[index];
        self.prepareSlot(slot, index);

        const offset = index * self.slot_bytes;
        const pixel_count = @as(usize, self.size_px.width) * self.size_px.height;
        assert(pixel_count * bytes_per_pixel <= self.slot_bytes);
        const pixel_bytes = self.pool_memory[offset..][0 .. pixel_count * bytes_per_pixel];
        const target = cpu.raster.Target{
            .pixels = @alignCast(std.mem.bytesAsSlice(u32, pixel_bytes)),
            .width = self.size_px.width,
            .height = self.size_px.height,
            .stride = self.size_px.width,
        };
        self.last_stats = self.renderer.draw(
            target,
            frame,
            .{ .scale_factor = viewport.scale_factor },
            clear,
        );

        const surface = self.surface.?;
        wayland.surfaceAttach(surface, slot.buffer, 0, 0);
        wayland.surfaceDamageBuffer(surface, 0, 0, @intCast(slot.width), @intCast(slot.height));
        wayland.surfaceCommit(surface);
        slot.busy = true;
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
            if (slot.width == self.size_px.width and slot.height == self.size_px.height) return;
        }
        if (slot.buffer) |old| wayland.bufferDestroy(old);
        slot.* = .{};

        // libwayland returns null only when it cannot allocate the proxy, and
        // a frame without a buffer cannot be presented at all.
        const buffer = wayland.shmPoolCreateBuffer(
            self.pool.?,
            @intCast(index * self.slot_bytes),
            @intCast(self.size_px.width),
            @intCast(self.size_px.height),
            @intCast(self.size_px.width * bytes_per_pixel),
            wayland.WL_SHM_FORMAT_XRGB8888,
        ) orelse std.debug.panic(
            "wl_shm_pool.create_buffer failed for slot {d} at {d}x{d}: libwayland is out of memory",
            .{ index, self.size_px.width, self.size_px.height },
        );
        if (!wayland.bufferAddListener(buffer, &buffer_listener, slot)) {
            std.debug.panic("wl_buffer.add_listener failed for slot {d}", .{index});
        }
        slot.* = .{ .buffer = buffer, .width = self.size_px.width, .height = self.size_px.height };
        assert(@as(usize, slot.width) * slot.height * bytes_per_pixel <= self.slot_bytes);
    }
};
