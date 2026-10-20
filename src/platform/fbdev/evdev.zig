//! evdev input for the fbdev backend: keyboards, mice, and touchscreens read
//! straight from `/dev/input/event*` with no display server or libinput.
//!
//! Devices are discovered once during initialization by probing their
//! capability bits; hot-plugged devices are not picked up. Raw kernel events
//! are turned into Gooey `InputEvent`s by `Translator`, a pure state machine
//! that accumulates each device's packet and emits events at `SYN_REPORT`, so
//! motion, buttons, and touch contacts from one packet are reported together
//! and in that order.
//!
//! Key codes are the same evdev codes Wayland delivers, so key mapping and
//! the built-in US layout come from `linux/input.zig`.
//!
//! ## Bounds
//!
//! - At most `device_count_max` devices are opened, from the first
//!   `device_scan_max` event nodes.
//! - Each read takes at most `raw_batch_max` events per device, and one raw
//!   event produces at most `Batch.capacity` Gooey events.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const input = @import("../../input/events.zig");
const linux_input = @import("../linux/input.zig");

const assert = std.debug.assert;
const evdev_keys = linux_input.evdev;

pub const device_scan_max: u32 = 32;
pub const device_count_max: u32 = 16;
pub const raw_batch_max: u32 = 64;

/// Scroll distance reported per wheel detent, in logical pixels. Matches the
/// value libinput gives Wayland compositors for one detent.
pub const scroll_per_detent: f64 = 15.0;

// Event types and codes from <linux/input-event-codes.h>.
const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_REL: u16 = 0x02;
const EV_ABS: u16 = 0x03;
const SYN_REPORT: u16 = 0;
const SYN_DROPPED: u16 = 3;
const REL_X: u16 = 0x00;
const REL_Y: u16 = 0x01;
const REL_HWHEEL: u16 = 0x06;
const REL_WHEEL: u16 = 0x08;
const ABS_X: u16 = 0x00;
const ABS_Y: u16 = 0x01;
const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;
const BTN_MIDDLE: u16 = 0x112;
const BTN_TOUCH: u16 = 0x14a;
/// Codes below this are keyboard keys; at and above it are buttons.
const BTN_MISC: u16 = 0x100;

const key_bit_bytes: usize = 0x300 / 8;

/// `struct input_event`. The kernel declares the timestamp as two
/// `__kernel_ulong_t`, which is `unsigned long` on every Linux ABI.
pub const RawEvent = extern struct {
    seconds: c_ulong,
    microseconds: c_ulong,
    type: u16,
    code: u16,
    value: i32,
};

/// `struct input_absinfo`.
const AbsInfo = extern struct {
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
};

comptime {
    assert(@sizeOf(RawEvent) == 2 * @sizeOf(c_ulong) + 8);
    assert(@sizeOf(AbsInfo) == 24);
}

/// `_IOC(dir, 'E', nr, size)`, valid on x86 and Arm.
fn evdevIoctl(direction: u32, number: u32, size: u32) u32 {
    assert(direction <= 3);
    assert(size < (1 << 14));
    return (direction << 30) | (size << 16) | (@as(u32, 'E') << 8) | number;
}

fn eviocgbit(event_type: u32, size: u32) u32 {
    return evdevIoctl(2, 0x20 + event_type, size);
}

fn eviocgabs(axis: u32) u32 {
    return evdevIoctl(2, 0x40 + axis, @sizeOf(AbsInfo));
}

const EVIOCGRAB: u32 = 0x4004_4590;

/// What a device can report.
pub const Capabilities = struct {
    keyboard: bool = false,
    relative_pointer: bool = false,
    /// Absolute axes with a left button: tablets and virtual-machine pointers.
    absolute_pointer: bool = false,
    /// Absolute axes with `BTN_TOUCH`: touchscreens.
    touch: bool = false,

    pub fn any(self: Capabilities) bool {
        return self.keyboard or self.relative_pointer or self.absolute_pointer or self.touch;
    }

    pub fn moves_pointer(self: Capabilities) bool {
        return self.relative_pointer or self.absolute_pointer;
    }
};

pub const AxisRange = struct {
    minimum: i32 = 0,
    maximum: i32 = 1,
};

/// Values of one device's packet, accumulated until `SYN_REPORT`.
const Packet = struct {
    relative_x: i32 = 0,
    relative_y: i32 = 0,
    wheel_x: i32 = 0,
    wheel_y: i32 = 0,
    absolute_x: ?i32 = null,
    absolute_y: ?i32 = null,
    /// Bit per button (`button_bits`) pressed or released in this packet.
    pressed: u8 = 0,
    released: u8 = 0,
    touch: enum { unchanged, down, up } = .unchanged,
};

pub const Device = struct {
    fd: posix.fd_t,
    capabilities: Capabilities,
    x_range: AxisRange = .{},
    y_range: AxisRange = .{},
    packet: Packet = .{},
};

// =============================================================================
// Translation
// =============================================================================

/// Gooey events produced by one raw event, with storage for the one-byte
/// strings `text_input` events point at.
pub const Batch = struct {
    events: [capacity]input.InputEvent = undefined,
    text: [capacity][1]u8 = undefined,
    count: u32 = 0,

    /// A `SYN_REPORT` emits at most one motion, three buttons, one touch
    /// change, and one scroll; a key emits a key event, a modifier change,
    /// and a character.
    pub const capacity: u32 = 8;

    fn push(self: *Batch, event: input.InputEvent) void {
        assert(self.count < capacity);
        self.events[self.count] = event;
        self.count += 1;
    }

    fn pushText(self: *Batch, char: u8) void {
        assert(self.count < capacity);
        self.text[self.count] = .{char};
        self.push(linux_input.textInputEvent(&self.text[self.count]));
    }

    pub fn slice(self: *const Batch) []const input.InputEvent {
        assert(self.count <= capacity);
        return self.events[0..self.count];
    }
};

const button_bits = [_]struct { code: u16, bit: u8 }{
    .{ .code = BTN_LEFT, .bit = 1 },
    .{ .code = BTN_RIGHT, .bit = 2 },
    .{ .code = BTN_MIDDLE, .bit = 4 },
};

const modifier_keys = [_]struct { code: u32, bit: u8 }{
    .{ .code = 42, .bit = 1 << 0 }, // KEY_LEFTSHIFT
    .{ .code = 54, .bit = 1 << 1 }, // KEY_RIGHTSHIFT
    .{ .code = 29, .bit = 1 << 2 }, // KEY_LEFTCTRL
    .{ .code = 97, .bit = 1 << 3 }, // KEY_RIGHTCTRL
    .{ .code = 56, .bit = 1 << 4 }, // KEY_LEFTALT
    .{ .code = 100, .bit = 1 << 5 }, // KEY_RIGHTALT
    .{ .code = 125, .bit = 1 << 6 }, // KEY_LEFTMETA
    .{ .code = 126, .bit = 1 << 7 }, // KEY_RIGHTMETA
};

/// Pointer, button, and modifier state shared by every device, in logical
/// pixels of the screen.
pub const Translator = struct {
    screen_width: f64,
    screen_height: f64,
    /// Device pixels per logical pixel; relative motion arrives in device
    /// pixels.
    scale_factor: f64,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    buttons: u8 = 0,
    modifiers: u8 = 0,
    touch_active: bool = false,
    click_tracker: linux_input.ClickTracker = .{},

    pub fn init(screen_width: f64, screen_height: f64, scale_factor: f64) Translator {
        assert(screen_width > 0 and screen_height > 0);
        assert(scale_factor > 0);
        return .{
            .screen_width = screen_width,
            .screen_height = screen_height,
            .scale_factor = scale_factor,
            .pointer_x = screen_width * 0.5,
            .pointer_y = screen_height * 0.5,
        };
    }

    pub fn currentModifiers(self: *const Translator) input.Modifiers {
        return linux_input.modifiersFromFlags(
            self.modifiers & 0b0000_0011 != 0,
            self.modifiers & 0b0000_1100 != 0,
            self.modifiers & 0b0011_0000 != 0,
            self.modifiers & 0b1100_0000 != 0,
        );
    }

    /// Translate one raw event from `device`, appending any results to `out`.
    pub fn feed(self: *Translator, device: *Device, raw: RawEvent, out: *Batch) void {
        assert(device.capabilities.any());
        assert(out.count == 0);
        const packet = &device.packet;
        switch (raw.type) {
            EV_KEY => {
                if (raw.code < BTN_MISC) return self.feedKey(raw.code, raw.value, out);
                if (raw.code == BTN_TOUCH) {
                    packet.touch = if (raw.value != 0) .down else .up;
                    return;
                }
                for (button_bits) |button| {
                    if (raw.code != button.code) continue;
                    if (raw.value == 0) packet.released |= button.bit;
                    if (raw.value == 1) packet.pressed |= button.bit;
                }
            },
            EV_REL => switch (raw.code) {
                REL_X => packet.relative_x +|= raw.value,
                REL_Y => packet.relative_y +|= raw.value,
                REL_HWHEEL => packet.wheel_x +|= raw.value,
                REL_WHEEL => packet.wheel_y +|= raw.value,
                else => {},
            },
            EV_ABS => switch (raw.code) {
                ABS_X => packet.absolute_x = raw.value,
                ABS_Y => packet.absolute_y = raw.value,
                else => {},
            },
            EV_SYN => switch (raw.code) {
                SYN_REPORT => self.flushPacket(device, timeMilliseconds(raw), out),
                // The kernel dropped events: the partial packet is unusable.
                SYN_DROPPED => packet.* = .{},
                else => {},
            },
            else => {},
        }
    }

    fn feedKey(self: *Translator, code: u16, value: i32, out: *Batch) void {
        assert(code < BTN_MISC);
        assert(out.count == 0);
        const key: u32 = code;
        for (modifier_keys) |modifier| {
            if (modifier.code != key) continue;
            if (value == 0) self.modifiers &= ~modifier.bit else self.modifiers |= modifier.bit;
            out.push(linux_input.modifiersChangedEvent(self.currentModifiers()));
            return;
        }
        const modifiers = self.currentModifiers();
        if (value == 0) {
            out.push(linux_input.keyUpEvent(key, modifiers));
            return;
        }
        // Value 2 is the kernel's own autorepeat.
        out.push(linux_input.keyDownEvent(key, modifiers, value == 2));
        if (modifiers.ctrl or modifiers.alt or modifiers.cmd) return;
        if (linux_input.evdevKeyToChar(key, modifiers.shift)) |char| out.pushText(char);
    }

    fn flushPacket(self: *Translator, device: *Device, time_ms: u32, out: *Batch) void {
        assert(out.count == 0);
        assert(device.capabilities.any());
        const packet = device.packet;
        device.packet = .{};
        const modifiers = self.currentModifiers();

        if (self.applyMotion(device, &packet)) {
            if (self.touch_active and packet.touch != .down) {
                out.push(linux_input.touchMovedEvent(0, self.pointer_x, self.pointer_y));
            } else if (device.capabilities.moves_pointer()) {
                out.push(self.motionEvent(modifiers));
            }
        }
        for (button_bits) |button| {
            if (packet.pressed & button.bit != 0) {
                self.buttons |= button.bit;
                const count = self.click_tracker.recordClick(
                    time_ms,
                    self.pointer_x,
                    self.pointer_y,
                    button.code,
                );
                out.push(linux_input.mouseDownEvent(self.pointer_x, self.pointer_y, button.code, count, modifiers));
            }
            if (packet.released & button.bit != 0) {
                self.buttons &= ~button.bit;
                out.push(linux_input.mouseUpEvent(self.pointer_x, self.pointer_y, button.code, modifiers));
            }
        }
        self.applyTouch(packet.touch, out);
        if (packet.wheel_x != 0 or packet.wheel_y != 0) {
            // Wayland axis values grow rightward and downward; a positive
            // `REL_WHEEL` is a turn away from the user, which scrolls up.
            const delta_x = @as(f64, @floatFromInt(packet.wheel_x)) * scroll_per_detent;
            const delta_y = -@as(f64, @floatFromInt(packet.wheel_y)) * scroll_per_detent;
            out.push(linux_input.scrollEvent(self.pointer_x, self.pointer_y, delta_x, delta_y, modifiers));
        }
    }

    /// Update the pointer from a packet. Returns true when it moved.
    fn applyMotion(self: *Translator, device: *const Device, packet: *const Packet) bool {
        assert(self.scale_factor > 0);
        assert(self.screen_width > 0 and self.screen_height > 0);
        const previous_x = self.pointer_x;
        const previous_y = self.pointer_y;
        if (packet.absolute_x) |raw| self.pointer_x = mapAxis(raw, device.x_range, self.screen_width);
        if (packet.absolute_y) |raw| self.pointer_y = mapAxis(raw, device.y_range, self.screen_height);
        if (packet.relative_x != 0 or packet.relative_y != 0) {
            const dx = @as(f64, @floatFromInt(packet.relative_x)) / self.scale_factor;
            const dy = @as(f64, @floatFromInt(packet.relative_y)) / self.scale_factor;
            self.pointer_x = std.math.clamp(self.pointer_x + dx, 0, self.screen_width - 1);
            self.pointer_y = std.math.clamp(self.pointer_y + dy, 0, self.screen_height - 1);
        }
        return self.pointer_x != previous_x or self.pointer_y != previous_y;
    }

    fn applyTouch(self: *Translator, change: @FieldType(Packet, "touch"), out: *Batch) void {
        assert(out.count < Batch.capacity);
        assert(self.screen_width > 0);
        switch (change) {
            .unchanged => {},
            .down => {
                self.touch_active = true;
                out.push(linux_input.touchDownEvent(0, self.pointer_x, self.pointer_y));
            },
            .up => {
                if (!self.touch_active) return;
                self.touch_active = false;
                out.push(linux_input.touchUpEvent(0, self.pointer_x, self.pointer_y));
            },
        }
    }

    fn motionEvent(self: *const Translator, modifiers: input.Modifiers) input.InputEvent {
        assert(self.pointer_x >= 0 and self.pointer_y >= 0);
        assert(self.buttons <= 0b111);
        if (self.buttons == 0) return linux_input.mouseMovedEvent(self.pointer_x, self.pointer_y, modifiers);
        const button: input.MouseButton = if (self.buttons & 1 != 0)
            .left
        else if (self.buttons & 2 != 0) .right else .middle;
        return linux_input.mouseDraggedEvent(self.pointer_x, self.pointer_y, button, modifiers);
    }
};

/// Map a raw absolute axis value onto `[0, extent)` logical pixels.
fn mapAxis(raw: i32, range: AxisRange, extent: f64) f64 {
    assert(range.maximum > range.minimum);
    assert(extent > 0);
    const span: f64 = @floatFromInt(@as(i64, range.maximum) - range.minimum);
    const offset: f64 = @floatFromInt(@as(i64, raw) - range.minimum);
    return std.math.clamp(offset / span * extent, 0, extent - 1);
}

fn timeMilliseconds(raw: RawEvent) u32 {
    assert(raw.microseconds < 1_000_000);
    const ms = @as(u64, raw.seconds) * 1000 + @as(u64, raw.microseconds) / 1000;
    // Truncation wraps every 49 days; `ClickTracker` subtracts with wrapping.
    return @truncate(ms);
}

// =============================================================================
// Devices
// =============================================================================

/// Every input device the backend reads.
pub const DeviceSet = struct {
    devices: [device_count_max]Device = undefined,
    count: u32 = 0,

    /// Open every usable `/dev/input/event*` node. Nodes that cannot be
    /// opened (permissions) or report nothing useful are skipped; a device
    /// with no input at all is a valid, if unusual, configuration.
    pub fn openAll(self: *DeviceSet, grab: bool) void {
        assert(self.count == 0);
        var index: u32 = 0;
        while (index < device_scan_max and self.count < device_count_max) : (index += 1) {
            var path_buffer: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buffer, "/dev/input/event{d}", .{index}, 0) catch unreachable;
            if (openDevice(path, grab)) |device| {
                self.devices[self.count] = device;
                self.count += 1;
            }
        }
        assert(self.count <= device_count_max);
    }

    pub fn closeAll(self: *DeviceSet) void {
        assert(self.count <= device_count_max);
        for (self.devices[0..self.count]) |device| _ = std.c.close(device.fd);
        self.count = 0;
    }

    pub fn slice(self: *DeviceSet) []Device {
        assert(self.count <= device_count_max);
        return self.devices[0..self.count];
    }

    /// True when any device moves an on-screen pointer, which then needs a
    /// drawn cursor.
    pub fn hasPointer(self: *const DeviceSet) bool {
        for (self.devices[0..self.count]) |device| {
            if (device.capabilities.moves_pointer()) return true;
        }
        return false;
    }
};

fn openDevice(path: [:0]const u8, grab: bool) ?Device {
    assert(path.len > 0);
    const fd = posix.openatZ(posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, 0) catch return null;
    var device = Device{ .fd = fd, .capabilities = probeCapabilities(fd) };
    if (!device.capabilities.any()) {
        _ = std.c.close(fd);
        return null;
    }
    if (device.capabilities.absolute_pointer or device.capabilities.touch) {
        device.x_range = probeAxis(fd, ABS_X) orelse {
            _ = std.c.close(fd);
            return null;
        };
        device.y_range = probeAxis(fd, ABS_Y) orelse {
            _ = std.c.close(fd);
            return null;
        };
    }
    // An exclusive grab keeps keystrokes from also reaching the virtual
    // console underneath. A refusal (another grabber) leaves shared access.
    if (grab) _ = linux.ioctl(fd, EVIOCGRAB, 1);
    return device;
}

fn probeCapabilities(fd: posix.fd_t) Capabilities {
    assert(fd >= 0);
    var types: [4]u8 = @splat(0);
    var keys: [key_bit_bytes]u8 = @splat(0);
    var relative: [2]u8 = @splat(0);
    var absolute: [8]u8 = @splat(0);
    if (!queryBits(fd, 0, &types)) return .{};
    if (hasBit(&types, EV_KEY)) _ = queryBits(fd, EV_KEY, &keys);
    if (hasBit(&types, EV_REL)) _ = queryBits(fd, EV_REL, &relative);
    if (hasBit(&types, EV_ABS)) _ = queryBits(fd, EV_ABS, &absolute);

    const has_axes = hasBit(&absolute, ABS_X) and hasBit(&absolute, ABS_Y);
    return .{
        .keyboard = hasBit(&keys, @intCast(evdev_keys.KEY_A)) and hasBit(&keys, @intCast(evdev_keys.KEY_Z)),
        .relative_pointer = hasBit(&relative, REL_X) and hasBit(&relative, REL_Y),
        .absolute_pointer = has_axes and !hasBit(&keys, BTN_TOUCH) and hasBit(&keys, BTN_LEFT),
        .touch = has_axes and hasBit(&keys, BTN_TOUCH),
    };
}

fn queryBits(fd: posix.fd_t, event_type: u16, bits: []u8) bool {
    assert(fd >= 0);
    assert(bits.len > 0);
    const rc = linux.ioctl(fd, eviocgbit(event_type, @intCast(bits.len)), @intFromPtr(bits.ptr));
    return linux.errno(rc) == .SUCCESS;
}

fn hasBit(bits: []const u8, bit: u16) bool {
    assert(bits.len > 0);
    if (bit / 8 >= bits.len) return false;
    return bits[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
}

fn probeAxis(fd: posix.fd_t, axis: u16) ?AxisRange {
    assert(fd >= 0);
    assert(axis == ABS_X or axis == ABS_Y);
    var info: AbsInfo = undefined;
    const rc = linux.ioctl(fd, eviocgabs(axis), @intFromPtr(&info));
    if (linux.errno(rc) != .SUCCESS) return null;
    if (info.maximum <= info.minimum) return null;
    return .{ .minimum = info.minimum, .maximum = info.maximum };
}

/// Read up to `raw_batch_max` pending events from a non-blocking device.
/// Returns an empty slice when nothing is pending or the device failed.
pub fn readEvents(device: *const Device, buffer: *[raw_batch_max]RawEvent) []const RawEvent {
    assert(device.fd >= 0);
    assert(buffer.len == raw_batch_max);
    const bytes = std.mem.sliceAsBytes(buffer);
    const count = posix.read(device.fd, bytes) catch return buffer[0..0];
    // The kernel only ever returns whole events.
    assert(count % @sizeOf(RawEvent) == 0);
    return buffer[0 .. count / @sizeOf(RawEvent)];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn testEvent(event_type: u16, code: u16, value: i32) RawEvent {
    return .{ .seconds = 1, .microseconds = 0, .type = event_type, .code = code, .value = value };
}

/// Feeds `events` one at a time and flattens the translated events into
/// `out`. Each raw event gets its own caller-owned batch because `text_input`
/// slices point into their batch and must outlive this call.
fn feedAll(
    translator: *Translator,
    device: *Device,
    events: []const RawEvent,
    batches: []Batch,
    out: []input.InputEvent,
) u32 {
    assert(events.len <= batches.len);
    var total: u32 = 0;
    for (events, batches[0..events.len]) |event, *batch| {
        batch.* = .{};
        translator.feed(device, event, batch);
        for (batch.slice()) |translated| {
            assert(total < out.len);
            out[total] = translated;
            total += 1;
        }
    }
    return total;
}

test "relative packet reports motion before the button pressed in it" {
    // Goal: motion and a press in one packet must arrive as move-then-down at
    // the new position, and relative motion is divided by the scale factor.
    var translator = Translator.init(400, 300, 2);
    var device = Device{ .fd = 0, .capabilities = .{ .relative_pointer = true } };
    var events: [8]input.InputEvent = undefined;
    var batches: [8]Batch = undefined;
    const count = feedAll(&translator, &device, &.{
        testEvent(EV_REL, REL_X, 20),
        testEvent(EV_REL, REL_Y, -10),
        testEvent(EV_KEY, BTN_LEFT, 1),
        testEvent(EV_SYN, SYN_REPORT, 0),
    }, &batches, &events);
    try testing.expectEqual(@as(u32, 2), count);
    try testing.expectEqual(@as(f64, 210), events[0].mouse_moved.position.x);
    try testing.expectEqual(@as(f64, 145), events[0].mouse_moved.position.y);
    try testing.expectEqual(input.MouseButton.left, events[1].mouse_down.button);
    try testing.expectEqual(@as(f64, 210), events[1].mouse_down.position.x);
}

test "motion with a button held is a drag and the pointer stays on screen" {
    // Goal: held-button motion must be `mouse_dragged`, and motion past the
    // edge must clamp to the last pixel instead of leaving the screen.
    var translator = Translator.init(100, 100, 1);
    var device = Device{ .fd = 0, .capabilities = .{ .relative_pointer = true } };
    var events: [8]input.InputEvent = undefined;
    var batches: [8]Batch = undefined;
    const count = feedAll(&translator, &device, &.{
        testEvent(EV_KEY, BTN_RIGHT, 1),
        testEvent(EV_SYN, SYN_REPORT, 0),
        testEvent(EV_REL, REL_X, 500),
        testEvent(EV_SYN, SYN_REPORT, 0),
    }, &batches, &events);
    try testing.expectEqual(@as(u32, 2), count);
    try testing.expectEqual(input.MouseButton.right, events[1].mouse_dragged.button);
    try testing.expectEqual(@as(f64, 99), events[1].mouse_dragged.position.x);
}

test "touchscreen maps its axis range and reports down, move, up" {
    // Goal: a touch contact maps raw axis values onto the logical screen and
    // produces touch events, not mouse events, in contact order.
    var translator = Translator.init(800, 480, 1);
    var device = Device{
        .fd = 0,
        .capabilities = .{ .touch = true },
        .x_range = .{ .minimum = 0, .maximum = 4000 },
        .y_range = .{ .minimum = 0, .maximum = 4000 },
    };
    var events: [8]input.InputEvent = undefined;
    var batches: [8]Batch = undefined;
    const count = feedAll(&translator, &device, &.{
        testEvent(EV_ABS, ABS_X, 1000),
        testEvent(EV_ABS, ABS_Y, 2000),
        testEvent(EV_KEY, BTN_TOUCH, 1),
        testEvent(EV_SYN, SYN_REPORT, 0),
        testEvent(EV_ABS, ABS_X, 2000),
        testEvent(EV_SYN, SYN_REPORT, 0),
        testEvent(EV_KEY, BTN_TOUCH, 0),
        testEvent(EV_SYN, SYN_REPORT, 0),
    }, &batches, &events);
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expectEqual(@as(f64, 200), events[0].touch_down.position.x);
    try testing.expectEqual(@as(f64, 240), events[0].touch_down.position.y);
    try testing.expectEqual(@as(f64, 400), events[1].touch_moved.position.x);
    try testing.expectEqual(@as(f64, 400), events[2].touch_up.position.x);
}

test "shifted key produces an uppercase character; ctrl suppresses text" {
    // Goal: modifiers come from either side's key, shift changes the
    // character, and a ctrl chord is a shortcut with no `text_input`.
    var translator = Translator.init(100, 100, 1);
    var device = Device{ .fd = 0, .capabilities = .{ .keyboard = true } };
    var events: [8]input.InputEvent = undefined;
    var batches: [8]Batch = undefined;
    const key_a: u16 = @intCast(evdev_keys.KEY_A);
    var count = feedAll(&translator, &device, &.{
        testEvent(EV_KEY, 54, 1), // KEY_RIGHTSHIFT
        testEvent(EV_KEY, key_a, 1),
    }, &batches, &events);
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expect(events[0].modifiers_changed.shift);
    try testing.expect(events[1].key_down.modifiers.shift);
    try testing.expectEqualStrings("A", events[2].text_input.text);

    count = feedAll(&translator, &device, &.{
        testEvent(EV_KEY, 54, 0),
        testEvent(EV_KEY, 29, 1), // KEY_LEFTCTRL
        testEvent(EV_KEY, key_a, 2),
    }, &batches, &events);
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expect(events[2].key_down.modifiers.ctrl);
    try testing.expect(events[2].key_down.is_repeat);
}

test "wheel detents become Wayland-signed scroll deltas" {
    // Goal: a wheel turned away from the user scrolls up, i.e. a negative
    // delta, matching what the Wayland backend passes through.
    var translator = Translator.init(100, 100, 1);
    var device = Device{ .fd = 0, .capabilities = .{ .relative_pointer = true } };
    var events: [8]input.InputEvent = undefined;
    var batches: [8]Batch = undefined;
    const count = feedAll(&translator, &device, &.{
        testEvent(EV_REL, REL_WHEEL, 2),
        testEvent(EV_SYN, SYN_REPORT, 0),
    }, &batches, &events);
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(f64, -30), events[0].scroll.delta.y);
}
