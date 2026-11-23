const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland.zig");
const backend = @import("../../core/backend.zig");
const limits_mod = @import("../../core/limits.zig");
const PackedFrame = @import("../../core/packed_frame.zig").PackedFrame;
const cpu = @import("../cpu/renderer.zig");

const assert = std.debug.assert;

pub const buffer_count: u32 = limits_mod.MIN_FRAMES_IN_FLIGHT;

const bytes_per_pixel: u32 = 4;

comptime {
    const ceiling = limits_mod.WindowLimits.ceiling;
    const slot_bytes_max = ceiling.framebufferPixelCountMax() * bytes_per_pixel;
    assert(slot_bytes_max * buffer_count <= std.math.maxInt(i32));
}

const buffer_listener = wayland.BufferListener{ .release = Slot.release };

const Slot = struct {
    buffer: ?*wayland.Buffer = null,
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

pub const NativeSurface = struct {
    shm: *wayland.Shm,
    surface: *wayland.Surface,
};

pub const ShmRenderer = struct {
    surface: ?*wayland.Surface = null,
    pool: ?*wayland.ShmPool = null,
    pool_fd: posix.fd_t = -1,
    pool_memory: []align(std.heap.page_size_min) u8 = &.{},
    slot_bytes: usize = 0,
    slots: [buffer_count]Slot = @splat(.{}),
    renderer: cpu.Renderer = undefined,
    size_px: backend.SizePx = .{ .width = 0, .height = 0 },
    window_limits: limits_mod.WindowLimits = undefined,

    last_stats: cpu.RenderStats = .{},
    frames_deferred: u64 = 0,
    skip_logged: bool = false,

    const Self = @This();

    comptime {
        backend.verifyRenderer(Self);
    }

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

    pub fn setEventQueue(self: *Self, queue: ?*wayland.EventQueue) void {
        assert(self.pool != null);
        wayland.wl_proxy_set_queue(@ptrCast(self.pool.?), queue);
        for (self.slots) |slot| {
            if (slot.buffer) |buffer| wayland.wl_proxy_set_queue(@ptrCast(buffer), queue);
        }
        assert(self.slots.len == buffer_count);
    }

    pub fn hasFreeSlot(self: *const Self) bool {
        return self.freeSlotIndex() != null;
    }

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

    fn prepareSlot(self: *Self, slot: *Slot, index: usize) void {
        assert(!slot.busy);
        assert(index < buffer_count);
        if (slot.buffer != null) {
            if (slot.width == self.size_px.width and slot.height == self.size_px.height) return;
        }
        if (slot.buffer) |old| wayland.bufferDestroy(old);
        slot.* = .{};

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
