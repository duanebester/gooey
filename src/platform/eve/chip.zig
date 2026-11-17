//! Bridgetek EVE (BT81x) display controller over Linux spidev, or simulated.
//!
//! EVE is a display coprocessor, not a framebuffer: the panel scans out
//! whatever its display list draws. `display_list.zig` builds those lists;
//! this file moves bytes: memory writes, register reads, display list swaps
//! on vertical blank, and the capacitive touch engine's contact register.
//!
//! The chip must already be booted, configured for its panel, and scanning
//! out (`REG_PCLK` non-zero) before this opens it. Board bring-up (reset line,
//! clocks, panel timing, backlight limits) is board-specific and stays with
//! the board's own driver; nothing here writes the reset line, the clocks, or
//! the backlight registers.
//!
//! `openSimulated` replaces the hardware with a 1024x600, 59.76 Hz chip in
//! memory. Each display list swap can dump `RAM_G` (1 MiB) followed by
//! `RAM_DL` (8 KiB) to a file, which `eve_preview.py` renders to a PNG.
//!
//! ## Memory (CLAUDE.md §2)
//!
//! `open` reserves one SPI message buffer (at most `message_bytes_max`) and
//! `openSimulated` also the simulated address space (4 MiB), both from fresh
//! pages at initialization. Transfers allocate nothing.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const reservation = @import("../../core/reservation.zig");

const assert = std.debug.assert;

// Memory map and registers (BT81x, `EVE_GpuDefs.h`).
pub const ram_g: u32 = 0x000000;
pub const ram_g_size: u32 = 1024 * 1024;
pub const ram_dl: u32 = 0x300000;
pub const ram_dl_size: u32 = 8 * 1024;
/// Display list capacity in 32-bit commands.
pub const display_list_words_max: u32 = ram_dl_size / 4;
/// Size of the chip's address space the simulation covers.
const address_space_size: u32 = 0x40_0000;
const reg_id: u32 = 0x302000;
const reg_frequency: u32 = 0x30200C;
const reg_hsize: u32 = 0x302034;
const reg_vsize: u32 = 0x302048;
const reg_dlswap: u32 = 0x302054;
const reg_pclk: u32 = 0x302070;
pub const reg_ctouch_touch0_xy: u32 = 0x302124;
const reg_id_value: u8 = 0x7C;
const dlswap_frame: u32 = 2;
/// `REG_CTOUCH_TOUCH0_XY` with no contact.
pub const touch_none: u32 = 0x8000_8000;

/// `struct spi_ioc_transfer` from <linux/spi/spidev.h>. Its buffers are
/// `__u64` on every architecture, so the layout is the same on armv7.
const SpiTransfer = extern struct {
    tx_buf: u64,
    rx_buf: u64,
    len: u32,
    speed_hz: u32,
    delay_usecs: u16 = 0,
    bits_per_word: u8 = 8,
    cs_change: u8 = 0,
    tx_nbits: u8 = 0,
    rx_nbits: u8 = 0,
    word_delay_usecs: u8 = 0,
    pad: u8 = 0,
};

comptime {
    assert(@sizeOf(SpiTransfer) == 32);
    // Display lists and glyph cells are written in the host's byte order.
    assert(builtin.cpu.arch.endian() == .little);
    assert(ram_dl + ram_dl_size <= address_space_size);
    assert(reg_ctouch_touch0_xy + 4 <= address_space_size);
}

/// `SPI_IOC_MESSAGE(1)`: `_IOW('k', 0, char[32])`.
const SPI_IOC_MESSAGE_1: u32 = 0x4020_6B00;
/// `SPI_IOC_WR_MODE`: `_IOW('k', 1, __u8)`.
const SPI_IOC_WR_MODE: u32 = 0x4001_6B01;

/// Slowest SPI clock accepted; below it a display list misses its frame.
pub const spi_hz_min: u32 = 1_000_000;
/// BT81x SPI limit (`Tsclk` minimum 33.3 ns).
pub const spi_hz_max: u32 = 30_000_000;
/// Kernel default `spidev.bufsiz`, used when sysfs cannot be read.
const spidev_bufsiz_default: u32 = 4096;
/// Some kernels refuse messages close to `bufsiz`; keep the margin the
/// board's C and Python EVE drivers use.
const spidev_bufsiz_reserve: u32 = 512;
/// Largest message buffer reserved at initialization.
const message_bytes_max: u32 = 64 * 1024;
/// Smallest usable message: a 3-byte address and a useful payload.
const message_bytes_min: u32 = 512;
/// Longest wait for the previous display list to reach the screen. A panel
/// refreshes at least every 33 ms; anything longer means the chip stopped.
const swap_wait_ns_max: u64 = 100 * std.time.ns_per_ms;
/// Swap polls before `swap_wait_ns_max` must have passed: one per 1 ms sleep.
const swap_poll_count_max: u32 = 200;
pub const sim_panel_width: u32 = 1024;
pub const sim_panel_height: u32 = 600;
/// The RVT70's measured refresh: 59.76 Hz.
const sim_frame_ns: u64 = 16_733_000;

pub const Touch = struct {
    /// Panel pixel coordinates; may lie slightly outside the panel.
    x: i16,
    y: i16,
};

pub const Error = error{ EveSpiTransferFailed, EveSwapTimeout };

pub const Chip = struct {
    fd: posix.fd_t = -1,
    speed_hz: u32 = spi_hz_min,
    panel_width: u32 = 0,
    panel_height: u32 = 0,
    /// One SPI message: 3 address bytes plus payload.
    message: []u8 = &.{},
    /// Host simulation: the chip's address space; empty with real hardware.
    sim_memory: []u8 = &.{},
    sim_dump_path: ?[*:0]const u8 = null,
    /// When the simulated swap in flight reaches the screen.
    sim_swap_due_ns: u64 = 0,
    /// Payload bytes written since `takeBytesWritten`, without the 3-byte
    /// address each SPI message starts with.
    bytes_written: u64 = 0,

    /// Open the chip behind spidev node `path`, clocked at `speed_hz`.
    pub fn open(self: *Chip, path: [*:0]const u8, speed_hz: u32) !void {
        assert(self.fd < 0);
        assert(speed_hz >= spi_hz_min);
        assert(speed_hz <= spi_hz_max);
        const fd = try posix.openatZ(posix.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
        }, 0);
        errdefer _ = std.c.close(fd);
        var spi_mode: u8 = 0;
        if (linux.errno(linux.ioctl(fd, SPI_IOC_WR_MODE, @intFromPtr(&spi_mode))) != .SUCCESS) {
            return error.EveSpiSetupFailed;
        }
        self.* = .{ .fd = fd, .speed_hz = speed_hz };
        // Messages must fit spidev's bounce buffer.
        const bufsiz = readSpidevBufsiz();
        try self.attach(@min(bufsiz - spidev_bufsiz_reserve, message_bytes_max));
        assert(self.fd >= 0);
    }

    /// A chip that exists only in memory: register reads return a booted,
    /// scanning 1024x600 panel, and each display list swap dumps `RAM_G` and
    /// `RAM_DL` to `dump_path` (when given).
    pub fn openSimulated(self: *Chip, dump_path: ?[*:0]const u8) !void {
        assert(self.fd < 0);
        assert(self.sim_memory.len == 0);
        const memory = try reservation.reserveZeroed(u8, address_space_size);
        errdefer reservation.release(u8, memory, memory.len);
        self.* = .{ .sim_memory = memory, .sim_dump_path = dump_path, .speed_hz = spi_hz_max };
        memory[reg_id] = reg_id_value;
        std.mem.writeInt(u32, memory[reg_pclk..][0..4], 1, .little);
        std.mem.writeInt(u32, memory[reg_hsize..][0..4], sim_panel_width, .little);
        std.mem.writeInt(u32, memory[reg_vsize..][0..4], sim_panel_height, .little);
        std.mem.writeInt(u32, memory[reg_frequency..][0..4], 72_000_000, .little);
        std.mem.writeInt(u32, memory[reg_ctouch_touch0_xy..][0..4], touch_none, .little);
        try self.attach(spidev_bufsiz_default - spidev_bufsiz_reserve);
        assert(self.isSimulated());
    }

    /// Check that the chip runs and scans out, read the panel size, and
    /// reserve the message buffer.
    fn attach(self: *Chip, message_len: u32) !void {
        assert(message_len >= message_bytes_min);
        assert(self.message.len == 0);
        var small: [4]u8 = undefined;
        // Reads use a stack message, so they work before the buffer exists.
        try self.read(reg_id, small[0..1]);
        if (small[0] != reg_id_value) return error.EveNotRunning;
        if (try self.read32(reg_pclk) == 0) return error.EveNotScanningOut;
        self.panel_width = try self.read32(reg_hsize) & 0xFFF;
        self.panel_height = try self.read32(reg_vsize) & 0xFFF;
        if (self.panel_width == 0 or self.panel_height == 0) return error.EveNotScanningOut;
        self.message = try reservation.reserve(u8, message_len);
        std.log.info("eve: panel {d}x{d}, SPI {d} Hz{s}", .{
            self.panel_width,
            self.panel_height,
            self.speed_hz,
            if (self.isSimulated()) " (simulated)" else "",
        });
        assert(self.panel_width > 0);
        assert(self.panel_height > 0);
    }

    pub fn close(self: *Chip) void {
        assert(self.fd >= 0 or self.isSimulated());
        if (self.message.len > 0) reservation.release(u8, self.message, self.message.len);
        if (self.fd >= 0) _ = std.c.close(self.fd);
        if (self.isSimulated()) reservation.release(u8, self.sim_memory, self.sim_memory.len);
        self.* = .{};
        assert(!self.isSimulated());
    }

    pub fn isSimulated(self: *const Chip) bool {
        return self.sim_memory.len > 0;
    }

    /// The payload bytes written since the last call, for the per-frame SPI
    /// budget.
    pub fn takeBytesWritten(self: *Chip) u64 {
        assert(self.fd >= 0 or self.isSimulated());
        const bytes = self.bytes_written;
        self.bytes_written = 0;
        return bytes;
    }

    /// Write any amount of data to consecutive chip addresses.
    pub fn writeMemory(self: *Chip, address: u32, data: []const u8) Error!void {
        assert(data.len > 0);
        assert(address + data.len <= address_space_size);
        const chunk_max = self.message.len - 3;
        assert(chunk_max > 0);
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk = data[offset..][0..@min(chunk_max, data.len - offset)];
            try self.write(address + @as(u32, @intCast(offset)), chunk);
            offset += chunk.len;
        }
        assert(offset == data.len);
    }

    /// Wait until the last swapped display list is on screen, so the list
    /// before it, and every `RAM_G` byte only it drew, is free. Returns the
    /// nanoseconds waited.
    pub fn waitForSwap(self: *Chip) Error!u64 {
        assert(self.fd >= 0 or self.isSimulated());
        assert(self.panel_width > 0);
        const started = nowNanoseconds();
        var poll_count: u32 = 0;
        while (try self.read32(reg_dlswap) != 0) {
            poll_count += 1;
            if (poll_count > swap_poll_count_max) return error.EveSwapTimeout;
            if (nowNanoseconds() - started > swap_wait_ns_max) return error.EveSwapTimeout;
            // Each poll is an SPI read and a syscall; 1 ms keeps the cost low
            // and still leaves most of a 16 ms frame to load the next list.
            const pause = linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = linux.nanosleep(&pause, null);
        }
        const waited = nowNanoseconds() - started;
        assert(poll_count <= swap_poll_count_max);
        return waited;
    }

    /// Load `words` into `RAM_DL` and swap it in at the next vertical blank.
    /// The previous swap must have completed (`waitForSwap`).
    pub fn swapDisplayList(self: *Chip, words: []const u32) Error!void {
        assert(words.len > 0);
        assert(words.len <= display_list_words_max);
        assert(words[words.len - 1] == 0); // DISPLAY
        try self.writeMemory(ram_dl, std.mem.sliceAsBytes(words));
        try self.write32(reg_dlswap, dlswap_frame);
    }

    /// The current touch contact, or null when there is none.
    pub fn readTouch(self: *Chip) Error!?Touch {
        assert(self.fd >= 0 or self.isSimulated());
        const xy = try self.read32(reg_ctouch_touch0_xy);
        if (xy == touch_none) return null;
        return .{
            .x = @bitCast(@as(u16, @truncate(xy >> 16))),
            .y = @bitCast(@as(u16, @truncate(xy))),
        };
    }

    fn write(self: *Chip, address: u32, data: []const u8) Error!void {
        assert(address < address_space_size);
        assert(data.len + 3 <= self.message.len);
        self.message[0] = 0x80 | @as(u8, @intCast(address >> 16));
        self.message[1] = @truncate(address >> 8);
        self.message[2] = @truncate(address);
        @memcpy(self.message[3..][0..data.len], data);
        try self.transfer(self.message[0 .. data.len + 3], null);
        self.bytes_written += data.len;
    }

    fn write32(self: *Chip, address: u32, value: u32) Error!void {
        assert(address % 4 == 0);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.write(address, &bytes);
    }

    /// Read `out.len` bytes (at most 4) starting at `address`.
    fn read(self: *Chip, address: u32, out: []u8) Error!void {
        assert(address < address_space_size);
        assert(out.len > 0);
        assert(out.len <= 4);
        var tx: [8]u8 = @splat(0);
        var rx: [8]u8 = undefined;
        tx[0] = @intCast(address >> 16);
        tx[1] = @truncate(address >> 8);
        tx[2] = @truncate(address);
        // Byte 3 is the dummy byte; data follows it.
        try self.transfer(tx[0 .. 4 + out.len], rx[0 .. 4 + out.len]);
        @memcpy(out, rx[4..][0..out.len]);
    }

    fn read32(self: *Chip, address: u32) Error!u32 {
        assert(address % 4 == 0);
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn transfer(self: *Chip, tx: []const u8, rx: ?[]u8) Error!void {
        assert(tx.len > 0);
        if (rx) |buffer| assert(buffer.len == tx.len);
        if (self.isSimulated()) return self.simulateTransfer(tx, rx);
        var message = SpiTransfer{
            .tx_buf = @intFromPtr(tx.ptr),
            .rx_buf = if (rx) |buffer| @intFromPtr(buffer.ptr) else 0,
            .len = @intCast(tx.len),
            .speed_hz = self.speed_hz,
        };
        const rc = linux.ioctl(self.fd, SPI_IOC_MESSAGE_1, @intFromPtr(&message));
        if (linux.errno(rc) != .SUCCESS) return error.EveSpiTransferFailed;
    }

    /// Apply one SPI message to the simulated address space.
    fn simulateTransfer(self: *Chip, tx: []const u8, rx: ?[]u8) void {
        assert(tx.len >= 3);
        assert(self.sim_memory.len == address_space_size);
        const address = (@as(u32, tx[0] & 0x3F) << 16) | (@as(u32, tx[1]) << 8) | tx[2];
        if (tx[0] & 0x80 == 0) {
            // A requested swap completes at the next simulated refresh.
            if (nowNanoseconds() >= self.sim_swap_due_ns) {
                @memset(self.sim_memory[reg_dlswap..][0..4], 0);
            }
            const out = rx.?[4..];
            @memcpy(out, self.sim_memory[address..][0..out.len]);
            return;
        }
        const data = tx[3..];
        @memcpy(self.sim_memory[address..][0..data.len], data);
        if (address <= reg_dlswap and reg_dlswap < address + data.len) {
            self.sim_swap_due_ns = nowNanoseconds() + sim_frame_ns;
            if (self.sim_dump_path) |path| self.simulateDump(path);
        }
    }

    /// Write `RAM_G` then `RAM_DL` to `path`, as `eve_preview.py` reads them.
    fn simulateDump(self: *const Chip, path: [*:0]const u8) void {
        assert(self.sim_memory.len == address_space_size);
        const fd = posix.openatZ(posix.AT.FDCWD, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        }, 0o644) catch |err| {
            std.log.warn("eve: cannot write dump {s}: {t}", .{ path, err });
            return;
        };
        defer _ = std.c.close(fd);
        const regions = [_][]const u8{
            self.sim_memory[ram_g..][0..ram_g_size],
            self.sim_memory[ram_dl..][0..ram_dl_size],
        };
        for (regions) |region| {
            if (!writeAll(fd, region)) {
                std.log.warn("eve: dump {s} incomplete", .{path});
                return;
            }
        }
    }
};

fn writeAll(fd: posix.fd_t, bytes: []const u8) bool {
    assert(fd >= 0);
    assert(bytes.len > 0);
    var written: usize = 0;
    // Each write makes progress or fails; a regular file takes it in a few.
    while (written < bytes.len) {
        const count = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (count <= 0) return false;
        written += @intCast(count);
    }
    return true;
}

pub fn nowNanoseconds() u64 {
    // The callers carry no `Io`; the same process-lifetime single-threaded
    // `Io` the fbdev and Wayland hosts use.
    const io = std.Io.Threaded.global_single_threaded.io();
    const ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    assert(ns >= 0);
    return @intCast(ns);
}

fn readSpidevBufsiz() u32 {
    const fd = posix.openatZ(posix.AT.FDCWD, "/sys/module/spidev/parameters/bufsiz", .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0) catch return spidev_bufsiz_default;
    defer _ = std.c.close(fd);
    var text: [16]u8 = undefined;
    const count = posix.read(fd, &text) catch return spidev_bufsiz_default;
    const value = std.fmt.parseInt(u32, std.mem.trim(u8, text[0..count], " \n"), 10) catch
        return spidev_bufsiz_default;
    if (value < spidev_bufsiz_reserve + message_bytes_min) return spidev_bufsiz_default;
    assert(value > spidev_bufsiz_reserve);
    return value;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "a simulated swap loads the list into RAM_DL and completes at the next refresh" {
    // Goal: the swap protocol the renderer paces on. The first swap may go
    // at once; the second must wait most of a 16.7 ms refresh for it.
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    try testing.expectEqual(sim_panel_width, chip.panel_width);
    try testing.expectEqual(sim_panel_height, chip.panel_height);
    const words = [_]u32{ 0x02FF0000, 0x26000007, 0 };
    try testing.expect(try chip.waitForSwap() < std.time.ns_per_ms);
    try chip.swapDisplayList(&words);
    const loaded = chip.sim_memory[ram_dl..][0..12];
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&words), loaded);
    try testing.expect(try chip.waitForSwap() >= 10 * std.time.ns_per_ms);
    // Payload only: 12 list bytes and the 4-byte swap request.
    try testing.expectEqual(@as(u64, 12 + 4), chip.takeBytesWritten());
}

test "touch reads the signed contact position, and none without contact" {
    // X is the high half, Y the low half; -3 checks the sign extension.
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    try testing.expectEqual(@as(?Touch, null), try chip.readTouch());
    const y: u16 = @bitCast(@as(i16, -3));
    const xy = (@as(u32, 700) << 16) | y;
    std.mem.writeInt(u32, chip.sim_memory[reg_ctouch_touch0_xy..][0..4], xy, .little);
    try testing.expectEqual(@as(?Touch, .{ .x = 700, .y = -3 }), try chip.readTouch());
}

test "writes longer than one message split across consecutive addresses" {
    // The simulated message holds 3581 payload bytes; 10000 bytes must land
    // whole and in order.
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    var data: [10_000]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 7);
    try chip.writeMemory(0x1000, &data);
    try testing.expectEqualSlices(u8, &data, chip.sim_memory[0x1000..][0..data.len]);
}
