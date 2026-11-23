const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const reservation = @import("../../core/reservation.zig");

const assert = std.debug.assert;

pub const ram_g: u32 = 0x000000;
pub const ram_g_size: u32 = 1024 * 1024;
pub const ram_dl: u32 = 0x300000;
pub const ram_dl_size: u32 = 8 * 1024;
pub const display_list_words_max: u32 = ram_dl_size / 4;
const address_space_size: u32 = 0x40_0000;
const reg_id: u32 = 0x302000;
const reg_frequency: u32 = 0x30200C;
const reg_hsize: u32 = 0x302034;
const reg_vsize: u32 = 0x302048;
const reg_dlswap: u32 = 0x302054;
const reg_pclk: u32 = 0x302070;
pub const reg_ctouch_touch0_xy: u32 = 0x302124;
pub const reg_underrun: u32 = 0x30260C;
const reg_id_value: u8 = 0x7C;
const dlswap_frame: u32 = 2;
pub const touch_none: u32 = 0x8000_8000;

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
    assert(builtin.cpu.arch.endian() == .little);
    assert(ram_dl + ram_dl_size <= address_space_size);
    assert(reg_ctouch_touch0_xy + 4 <= address_space_size);
}

const SPI_IOC_MESSAGE_1: u32 = 0x4020_6B00;
const SPI_IOC_WR_MODE: u32 = 0x4001_6B01;

pub const spi_hz_min: u32 = 1_000_000;
pub const spi_hz_max: u32 = 30_000_000;
const spidev_bufsiz_default: u32 = 4096;
const spidev_bufsiz_reserve: u32 = 512;
const message_bytes_max: u32 = 64 * 1024;
const message_bytes_min: u32 = 512;
const swap_wait_ns_max: u64 = 100 * std.time.ns_per_ms;
const swap_poll_count_max: u32 = 200;
pub const sim_panel_width: u32 = 1024;
pub const sim_panel_height: u32 = 600;
const sim_frame_ns: u64 = 16_733_000;

pub const Touch = struct {
    x: i16,
    y: i16,
};

pub const Error = error{ EveSpiTransferFailed, EveSwapTimeout };

pub const Chip = struct {
    fd: posix.fd_t = -1,
    speed_hz: u32 = spi_hz_min,
    panel_width: u32 = 0,
    panel_height: u32 = 0,
    message: []u8 = &.{},
    sim_memory: []u8 = &.{},
    sim_dump_path: ?[*:0]const u8 = null,
    sim_swap_due_ns: u64 = 0,
    bytes_written: u64 = 0,

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
        const bufsiz = readSpidevBufsiz();
        try self.attach(@min(bufsiz - spidev_bufsiz_reserve, message_bytes_max));
        assert(self.fd >= 0);
    }

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

    fn attach(self: *Chip, message_len: u32) !void {
        assert(message_len >= message_bytes_min);
        assert(self.message.len == 0);
        var small: [4]u8 = undefined;
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

    pub fn takeBytesWritten(self: *Chip) u64 {
        assert(self.fd >= 0 or self.isSimulated());
        const bytes = self.bytes_written;
        self.bytes_written = 0;
        return bytes;
    }

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

    pub fn waitForSwap(self: *Chip) Error!u64 {
        assert(self.fd >= 0 or self.isSimulated());
        assert(self.panel_width > 0);
        const started = nowNanoseconds();
        var poll_count: u32 = 0;
        while (try self.read32(reg_dlswap) != 0) {
            poll_count += 1;
            if (poll_count > swap_poll_count_max) return error.EveSwapTimeout;
            if (nowNanoseconds() - started > swap_wait_ns_max) return error.EveSwapTimeout;
            const pause = linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = linux.nanosleep(&pause, null);
        }
        const waited = nowNanoseconds() - started;
        assert(poll_count <= swap_poll_count_max);
        return waited;
    }

    pub fn swapDisplayList(self: *Chip, words: []const u32) Error!void {
        assert(words.len > 0);
        assert(words.len <= display_list_words_max);
        assert(words[words.len - 1] == 0);
        try self.writeMemory(ram_dl, std.mem.sliceAsBytes(words));
        try self.write32(reg_dlswap, dlswap_frame);
    }

    pub fn readUnderruns(self: *Chip) Error!u32 {
        assert(self.fd >= 0 or self.isSimulated());
        assert(reg_underrun % 4 == 0);
        return self.read32(reg_underrun);
    }

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

    fn read(self: *Chip, address: u32, out: []u8) Error!void {
        assert(address < address_space_size);
        assert(out.len > 0);
        assert(out.len <= 4);
        var tx: [8]u8 = @splat(0);
        var rx: [8]u8 = undefined;
        tx[0] = @intCast(address >> 16);
        tx[1] = @truncate(address >> 8);
        tx[2] = @truncate(address);
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

    fn simulateTransfer(self: *Chip, tx: []const u8, rx: ?[]u8) void {
        assert(tx.len >= 3);
        assert(self.sim_memory.len == address_space_size);
        const address = (@as(u32, tx[0] & 0x3F) << 16) | (@as(u32, tx[1]) << 8) | tx[2];
        if (tx[0] & 0x80 == 0) {
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
    while (written < bytes.len) {
        const count = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (count <= 0) return false;
        written += @intCast(count);
    }
    return true;
}

pub fn nowNanoseconds() u64 {
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

const testing = std.testing;

test "a simulated swap loads the list into RAM_DL and completes at the next refresh" {
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
    try testing.expectEqual(@as(u64, 12 + 4), chip.takeBytesWritten());
}

test "touch reads the signed contact position, and none without contact" {
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
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    var data: [10_000]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 7);
    try chip.writeMemory(0x1000, &data);
    try testing.expectEqualSlices(u8, &data, chip.sim_memory[0x1000..][0..data.len]);
}
