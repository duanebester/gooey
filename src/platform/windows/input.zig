const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("../../geometry/geometry.zig");
const input = @import("../../input/events.zig");
const win32 = @import("win32.zig");

const KeyCode = input.KeyCode;
const MouseButton = input.MouseButton;

pub const wheel_detent_px: f64 = 15.0;

const text_bytes_max: u8 = 4;

pub const Message = struct {
    id: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
};

pub const Context = struct {
    scale_factor: f64,
    modifiers: input.Modifiers,
    time_ms: u32,
    pointer: geometry.Point(f64),
};

pub const mouse_button_count: u32 = @typeInfo(MouseButton).@"enum".field_names.len;

const button_bits_all: u8 = @intCast(win32.MK_LBUTTON | win32.MK_RBUTTON | win32.MK_MBUTTON);

pub const key_code_count_max: u32 = input.held_key_count_max;

const KeySet = input.HeldKeys;

pub const message_event_count_max: u32 = 1;

comptime {
    assert(mouse_button_count == 3);
    assert(@popCount(button_bits_all) == mouse_button_count);
    @setEvalBranchQuota(4096);
    for (std.enums.values(KeyCode)) |key| {
        if (key != .unknown) assert(@backingInt(key) < key_code_count_max);
    }
}

pub const CaptureAction = enum { none, set, release };

pub const PointerActions = struct {
    capture: CaptureAction,
    track_leave: bool,

    pub const none = PointerActions{ .capture = .none, .track_leave = false };
};

pub const ClickSettings = struct {
    time_ms_max: u32,
    distance_px_max: u32,
};

pub const Translator = struct {
    click_settings: ClickSettings,

    click_count: u32 = 0,
    click_time_ms: u32 = 0,
    click_x_px: i32 = 0,
    click_y_px: i32 = 0,
    click_button: ?MouseButton = null,

    buttons_held: u8 = 0,
    pointer_inside: bool = false,
    keys_held: KeySet = .empty,

    high_surrogate: ?u16 = null,
    text_buffer: [text_bytes_max]u8 = undefined,

    pub fn init(click_settings: ClickSettings) Translator {
        assert(click_settings.time_ms_max > 0);
        assert(click_settings.distance_px_max > 0);
        return .{ .click_settings = click_settings };
    }

    pub fn translate(
        self: *Translator,
        message: *const Message,
        context: *const Context,
    ) ?input.InputEvent {
        assert(context.scale_factor > 0);
        assert(self.click_count <= std.math.maxInt(u32) - 1);
        assert(self.buttons_held & ~button_bits_all == 0);
        return switch (message.id) {
            win32.WM_MOUSEMOVE => self.pointerMoved(message, context),
            win32.WM_MOUSELEAVE => self.pointerLeft(context),
            win32.WM_CAPTURECHANGED => self.captureLost(context),
            win32.WM_KILLFOCUS => self.focusLost(context),
            win32.WM_LBUTTONDOWN => self.buttonDown(.left, message.lparam, context),
            win32.WM_RBUTTONDOWN => self.buttonDown(.right, message.lparam, context),
            win32.WM_MBUTTONDOWN => self.buttonDown(.middle, message.lparam, context),
            win32.WM_LBUTTONUP => self.buttonUp(.left, message.lparam, context),
            win32.WM_RBUTTONUP => self.buttonUp(.right, message.lparam, context),
            win32.WM_MBUTTONUP => self.buttonUp(.middle, message.lparam, context),
            win32.WM_MOUSEWHEEL => wheel(.vertical, message.wparam, context),
            win32.WM_MOUSEHWHEEL => wheel(.horizontal, message.wparam, context),
            win32.WM_KEYDOWN,
            win32.WM_SYSKEYDOWN,
            win32.WM_KEYUP,
            win32.WM_SYSKEYUP,
            => keyMessage(self, message, context),
            win32.WM_CHAR => self.character(@truncate(message.wparam)),
            else => null,
        };
    }

    pub fn pointerActions(
        self: *const Translator,
        message_id: u32,
        event: input.InputEvent,
    ) PointerActions {
        assert(self.buttons_held & ~button_bits_all == 0);
        switch (event) {
            .mouse_entered => {
                assert(self.pointer_inside);
                assert(self.buttons_held == 0);
                return .{ .capture = .none, .track_leave = true };
            },
            .mouse_down => {
                assert(self.buttons_held != 0);
                return .{ .capture = .set, .track_leave = false };
            },
            .pointer_cancelled => {
                assert(self.buttons_held == 0);
                const lost = message_id == win32.WM_CAPTURECHANGED;
                return .{
                    .capture = if (lost) .none else .release,
                    .track_leave = self.pointer_inside,
                };
            },
            .focus_lost => |lost| {
                assert(self.buttons_held == 0);
                assert(message_id == win32.WM_KILLFOCUS);
                if (!lost.pointer_cancelled) return PointerActions.none;
                return .{ .capture = .release, .track_leave = self.pointer_inside };
            },
            .mouse_up => {
                if (self.buttons_held != 0) return PointerActions.none;
                const lost = message_id == win32.WM_CAPTURECHANGED;
                return .{
                    .capture = if (lost) .none else .release,
                    .track_leave = self.pointer_inside,
                };
            },
            else => return PointerActions.none,
        }
    }

    fn pointerMoved(
        self: *Translator,
        message: *const Message,
        context: *const Context,
    ) input.InputEvent {
        assert(message.id == win32.WM_MOUSEMOVE);
        assert(context.scale_factor > 0);
        const position = logicalPosition(message.lparam, context.scale_factor);
        const released = self.buttons_held & ~buttonBitsFromWParam(message.wparam);
        if (buttonFirst(released)) |button| {
            return self.buttonReleased(button, position, context);
        }
        const mouse = input.MouseEvent{
            .position = position,
            .button = buttonFirst(self.buttons_held) orelse .left,
            .click_count = 0,
            .modifiers = context.modifiers,
        };
        if (self.buttons_held != 0) return .{ .mouse_dragged = mouse };
        if (self.pointer_inside) return .{ .mouse_moved = mouse };
        self.pointer_inside = true;
        return .{ .mouse_entered = mouse };
    }

    fn pointerLeft(self: *Translator, context: *const Context) ?input.InputEvent {
        assert(std.math.isFinite(context.pointer.x));
        if (!self.pointer_inside) return null;
        self.pointer_inside = false;
        assert(!self.pointer_inside);
        return .{ .mouse_exited = .{
            .position = context.pointer,
            .button = buttonFirst(self.buttons_held) orelse .left,
            .click_count = 0,
            .modifiers = context.modifiers,
        } };
    }

    fn captureLost(self: *Translator, context: *const Context) ?input.InputEvent {
        assert(std.math.isFinite(context.pointer.x));
        if (self.buttons_held == 0) return null;
        self.buttons_held = 0;
        self.click_button = null;
        assert(self.buttons_held == 0);
        return .pointer_cancelled;
    }

    fn focusLost(self: *Translator, context: *const Context) ?input.InputEvent {
        assert(context.scale_factor > 0);
        self.high_surrogate = null;
        self.click_button = null;
        const lost = input.FocusLostEvent{
            .pointer_cancelled = self.buttons_held != 0,
            .keys_held = self.keys_held,
        };
        self.buttons_held = 0;
        self.keys_held = .empty;
        assert(self.keys_held.count() == 0);
        if (!lost.pointer_cancelled and lost.keys_held.count() == 0) return null;
        return .{ .focus_lost = lost };
    }

    fn buttonDown(
        self: *Translator,
        button: MouseButton,
        lparam: win32.LPARAM,
        context: *const Context,
    ) input.InputEvent {
        assert(context.scale_factor > 0);
        const point = win32.POINT{ .x = win32.xFromLParam(lparam), .y = win32.yFromLParam(lparam) };
        self.click_count = self.nextClickCount(button, point, context.time_ms);
        self.click_time_ms = context.time_ms;
        self.click_x_px = point.x;
        self.click_y_px = point.y;
        self.click_button = button;
        self.buttons_held |= buttonBit(button);
        assert(self.click_count >= 1);
        assert(self.buttons_held & buttonBit(button) != 0);
        return .{ .mouse_down = .{
            .position = logicalPosition(lparam, context.scale_factor),
            .button = button,
            .click_count = self.click_count,
            .modifiers = context.modifiers,
        } };
    }

    fn buttonUp(
        self: *Translator,
        button: MouseButton,
        lparam: win32.LPARAM,
        context: *const Context,
    ) input.InputEvent {
        assert(context.scale_factor > 0);
        const position = logicalPosition(lparam, context.scale_factor);
        const event = self.buttonReleased(button, position, context);
        assert(event.mouse_up.button == button);
        return event;
    }

    fn buttonReleased(
        self: *Translator,
        button: MouseButton,
        position: geometry.Point(f64),
        context: *const Context,
    ) input.InputEvent {
        assert(std.math.isFinite(position.x));
        assert(std.math.isFinite(position.y));
        self.buttons_held &= ~buttonBit(button);
        assert(self.buttons_held & buttonBit(button) == 0);
        return .{ .mouse_up = .{
            .position = position,
            .button = button,
            .click_count = @max(self.click_count, 1),
            .modifiers = context.modifiers,
        } };
    }

    fn nextClickCount(
        self: *const Translator,
        button: MouseButton,
        point: win32.POINT,
        time_ms: u32,
    ) u32 {
        assert(self.click_settings.time_ms_max > 0);
        assert(self.click_settings.distance_px_max > 0);
        const previous = self.click_button orelse return 1;
        if (previous != button) return 1;
        if (time_ms -% self.click_time_ms > self.click_settings.time_ms_max) return 1;
        if (@abs(point.x - self.click_x_px) > self.click_settings.distance_px_max) return 1;
        if (@abs(point.y - self.click_y_px) > self.click_settings.distance_px_max) return 1;
        assert(self.click_count >= 1);
        return self.click_count + 1;
    }

    fn character(self: *Translator, unit: u16) ?input.InputEvent {
        if (self.high_surrogate) |high| {
            assert(high >= 0xD800);
            assert(high <= 0xDBFF);
        }
        const code_point: u21 = switch (unit) {
            0xD800...0xDBFF => {
                self.high_surrogate = unit;
                return null;
            },
            0xDC00...0xDFFF => blk: {
                const high = self.high_surrogate orelse return null;
                self.high_surrogate = null;
                const high_bits: u21 = high - 0xD800;
                const low_bits: u21 = unit - 0xDC00;
                break :blk 0x10000 + (high_bits << 10) + low_bits;
            },
            else => unit,
        };
        self.high_surrogate = null;
        if (code_point < 0x20 or code_point == 0x7F) return null;

        assert(code_point < 0xD800 or code_point > 0xDFFF);
        const length = std.unicode.utf8Encode(code_point, &self.text_buffer) catch unreachable;
        assert(length >= 1);
        assert(length <= text_bytes_max);
        return .{ .text_input = .{ .text = self.text_buffer[0..length] } };
    }
};

const WheelAxis = enum { vertical, horizontal };

fn wheel(axis: WheelAxis, wparam: win32.WPARAM, context: *const Context) input.InputEvent {
    assert(std.math.isFinite(context.pointer.x));
    assert(std.math.isFinite(context.pointer.y));
    const detents = @as(f64, @floatFromInt(win32.wheelDeltaFromWParam(wparam))) /
        @as(f64, @floatFromInt(win32.WHEEL_DELTA));
    const delta: geometry.Point(f64) = switch (axis) {
        .vertical => .{ .x = 0, .y = -detents * wheel_detent_px },
        .horizontal => .{ .x = detents * wheel_detent_px, .y = 0 },
    };
    return .{ .scroll = .{
        .position = context.pointer,
        .delta = delta,
        .modifiers = context.modifiers,
    } };
}

const virtual_key_ime_processed: u8 = 0xE5;

fn keyMessage(
    translator: *Translator,
    message: *const Message,
    context: *const Context,
) ?input.InputEvent {
    assert(translator.keys_held.count() <= key_code_count_max);
    const virtual_key: u8 = @truncate(message.wparam);
    if (virtual_key == virtual_key_ime_processed) return null;
    const is_press = message.id == win32.WM_KEYDOWN or message.id == win32.WM_SYSKEYDOWN;
    const event = keyEvent(message, context);
    if (event.key != .unknown) {
        const key_value: usize = @backingInt(event.key);
        assert(key_value < key_code_count_max);
        translator.keys_held.setValue(key_value, is_press);
    }
    if (is_press) return .{ .key_down = event };
    return .{ .key_up = event };
}

fn keyEvent(message: *const Message, context: *const Context) input.KeyEvent {
    assert(message.id == win32.WM_KEYDOWN or message.id == win32.WM_KEYUP or
        message.id == win32.WM_SYSKEYDOWN or message.id == win32.WM_SYSKEYUP);
    assert(message.wparam <= std.math.maxInt(u8));
    const flags: usize = @bitCast(message.lparam);
    const was_down = flags & (1 << 30) != 0;
    const is_press = message.id == win32.WM_KEYDOWN or message.id == win32.WM_SYSKEYDOWN;
    return .{
        .key = keyCodeFromVirtualKey(@truncate(message.wparam), flags),
        .modifiers = context.modifiers,
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = is_press and was_down,
    };
}

fn logicalPosition(lparam: win32.LPARAM, scale_factor: f64) geometry.Point(f64) {
    assert(scale_factor > 0);
    const point = win32.POINT{ .x = win32.xFromLParam(lparam), .y = win32.yFromLParam(lparam) };
    assert(point.x >= std.math.minInt(i16));
    assert(point.x <= std.math.maxInt(i16));
    return logicalFromDevice(point, scale_factor);
}

pub fn logicalFromDevice(point: win32.POINT, scale_factor: f64) geometry.Point(f64) {
    assert(scale_factor > 0);
    assert(std.math.isFinite(scale_factor));
    const x: f64 = @floatFromInt(point.x);
    const y: f64 = @floatFromInt(point.y);
    return .{ .x = x / scale_factor, .y = y / scale_factor };
}

fn buttonBit(button: MouseButton) u8 {
    const bit: u8 = switch (button) {
        .left => @intCast(win32.MK_LBUTTON),
        .right => @intCast(win32.MK_RBUTTON),
        .middle => @intCast(win32.MK_MBUTTON),
    };
    assert(@popCount(bit) == 1);
    assert(bit & button_bits_all == bit);
    return bit;
}

fn buttonBitsFromWParam(wparam: win32.WPARAM) u8 {
    const bits: u8 = @intCast(wparam & button_bits_all);
    assert(bits & ~button_bits_all == 0);
    return bits;
}

fn buttonFirst(bits: u8) ?MouseButton {
    assert(bits & ~button_bits_all == 0);
    const order = [mouse_button_count]MouseButton{ .left, .right, .middle };
    for (order) |button| {
        if (bits & buttonBit(button) != 0) return button;
    }
    assert(bits == 0);
    return null;
}

const flag_alt_down: usize = 1 << 29;

pub fn systemKeyUsesDefault(message: *const Message) bool {
    assert(message.id == win32.WM_SYSKEYDOWN or message.id == win32.WM_SYSKEYUP or
        message.id == win32.WM_SYSCHAR);
    assert(message.wparam <= std.math.maxInt(u16));
    if (message.id == win32.WM_SYSCHAR) return message.wparam == ' ';

    const flags: usize = @bitCast(message.lparam);
    if (flags & flag_alt_down == 0) return false;
    const virtual_key: u8 = @truncate(message.wparam);
    const virtual_key_f4: u8 = @intCast(win32.VK_F4);
    const virtual_key_space: u8 = @intCast(win32.VK_SPACE);
    return virtual_key == virtual_key_f4 or virtual_key == virtual_key_space;
}

const flag_extended: usize = 1 << 24;
const scan_code_shift = 16;
const scan_code_right_shift: u8 = 0x36;

const letter_keys = [26]KeyCode{
    .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
    .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
};
const digit_keys = [10]KeyCode{
    .@"0", .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9",
};
const keypad_digit_keys = [10]KeyCode{
    .keypad_0, .keypad_1, .keypad_2, .keypad_3, .keypad_4,
    .keypad_5, .keypad_6, .keypad_7, .keypad_8, .keypad_9,
};
const function_keys = [20]KeyCode{
    .f1,  .f2,  .f3,  .f4,  .f5,  .f6,  .f7,  .f8,  .f9,  .f10,
    .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
};

pub fn keyCodeFromVirtualKey(virtual_key: u8, flags: usize) KeyCode {
    const extended = flags & flag_extended != 0;
    return switch (virtual_key) {
        'A'...'Z' => letter_keys[virtual_key - 'A'],
        '0'...'9' => digit_keys[virtual_key - '0'],
        0x60...0x69 => keypad_digit_keys[virtual_key - 0x60],
        0x70...0x83 => function_keys[virtual_key - 0x70],
        0x08 => .delete,
        0x09 => .tab,
        0x0D => if (extended) .keypad_enter else .@"return",
        0x10 => if (@as(u8, @truncate(flags >> scan_code_shift)) == scan_code_right_shift)
            .right_shift
        else
            .shift,
        0x11 => if (extended) .right_control else .control,
        0x12 => if (extended) .right_option else .option,
        0x14 => .caps_lock,
        0x1B => .escape,
        0x20 => .space,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        0x2E => .forward_delete,
        0x5B => .command,
        0x5C => .right_command,
        0x6A => .keypad_multiply,
        0x6B => .keypad_plus,
        0x6D => .keypad_minus,
        0x6E => .keypad_decimal,
        0x6F => .keypad_divide,
        0x90 => .keypad_clear,
        0xBA => .semicolon,
        0xBB => .equal,
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash,
        0xC0 => .grave,
        0xDB => .left_bracket,
        0xDC => .backslash,
        0xDD => .right_bracket,
        0xDE => .quote,
        else => .unknown,
    };
}

const testing = std.testing;

const test_settings = ClickSettings{ .time_ms_max = 500, .distance_px_max = 4 };

fn testContext(time_ms: u32) Context {
    return .{
        .scale_factor = 2.0,
        .modifiers = .{},
        .time_ms = time_ms,
        .pointer = .{ .x = 10, .y = 20 },
    };
}

fn pointLParam(x_px: i16, y_px: i16) win32.LPARAM {
    const x_bits: u16 = @bitCast(x_px);
    const y_bits: u16 = @bitCast(y_px);
    return @bitCast((@as(usize, y_bits) << 16) | x_bits);
}

fn mouseMessage(id: u32, key_state: usize, x_px: i16, y_px: i16) Message {
    return .{ .id = id, .wparam = key_state, .lparam = pointLParam(x_px, y_px) };
}

const leave_message = Message{ .id = win32.WM_MOUSELEAVE, .wparam = 0, .lparam = 0 };
const capture_lost_message = Message{ .id = win32.WM_CAPTURECHANGED, .wparam = 0, .lparam = 0 };

const Step = struct { event: input.InputEvent, actions: PointerActions };

fn step(translator: *Translator, message: Message) ?Step {
    const event = translator.translate(&message, &testContext(0)) orelse return null;
    return .{ .event = event, .actions = translator.pointerActions(message.id, event) };
}

fn expectActions(actual: PointerActions, capture: CaptureAction, track_leave: bool) !void {
    try testing.expectEqual(capture, actual.capture);
    try testing.expectEqual(track_leave, actual.track_leave);
}

test "pointer motion reports arrival once, then motion, then drags" {
    var translator = Translator.init(test_settings);
    const context = testContext(0);
    const move = mouseMessage(win32.WM_MOUSEMOVE, 0, 40, 60);

    const entered = step(&translator, move).?;
    try testing.expectEqual(@as(f64, 20), entered.event.mouse_entered.position.x);
    try testing.expectEqual(@as(f64, 30), entered.event.mouse_entered.position.y);
    try expectActions(entered.actions, .none, true);
    try testing.expect(translator.translate(&move, &context).? == .mouse_moved);

    const press = mouseMessage(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 40, 60);
    _ = translator.translate(&press, &context).?;
    const drag = mouseMessage(win32.WM_MOUSEMOVE, win32.MK_LBUTTON, 40, 60);
    try testing.expect(translator.translate(&drag, &context).? == .mouse_dragged);

    try testing.expect(translator.translate(&leave_message, &context).? == .mouse_exited);
    try testing.expect(translator.translate(&leave_message, &context) == null);
}

test "held buttons are a set and capture is released only after the last" {
    const left_bit = win32.MK_LBUTTON;
    const both_bits = win32.MK_LBUTTON | win32.MK_RBUTTON;
    var translator = Translator.init(test_settings);
    _ = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 10, 10)).?;

    const left_down = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, left_bit, 10, 10)).?;
    try expectActions(left_down.actions, .set, false);
    const right_down = step(&translator, mouseMessage(win32.WM_RBUTTONDOWN, both_bits, 10, 10)).?;
    try testing.expectEqual(MouseButton.right, right_down.event.mouse_down.button);
    try expectActions(right_down.actions, .set, false);

    const right_up = step(&translator, mouseMessage(win32.WM_RBUTTONUP, left_bit, 10, 10)).?;
    try testing.expectEqual(MouseButton.right, right_up.event.mouse_up.button);
    try expectActions(right_up.actions, .none, false);
    const drag = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, left_bit, 12, 10)).?;
    try testing.expectEqual(MouseButton.left, drag.event.mouse_dragged.button);

    const left_up = step(&translator, mouseMessage(win32.WM_LBUTTONUP, 0, 12, 10)).?;
    try testing.expectEqual(MouseButton.left, left_up.event.mouse_up.button);
    try expectActions(left_up.actions, .release, true);
    try testing.expectEqual(@as(u8, 0), translator.buttons_held);
    const free = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 14, 10)).?;
    try testing.expect(free.event == .mouse_moved);
}

test "all three buttons fill the held set and release in any order" {
    var translator = Translator.init(test_settings);
    _ = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 0, 0)).?;
    _ = step(&translator, mouseMessage(win32.WM_MBUTTONDOWN, 0, 0, 0)).?;
    _ = step(&translator, mouseMessage(win32.WM_RBUTTONDOWN, 0, 0, 0)).?;
    try testing.expectEqual(button_bits_all, translator.buttons_held);

    const releases = [_]u32{ win32.WM_MBUTTONUP, win32.WM_LBUTTONUP, win32.WM_RBUTTONUP };
    const remaining = [_]u8{ 0x03, 0x02, 0x00 };
    for (releases, remaining) |release, bits| {
        const up = step(&translator, mouseMessage(release, button_bits_all, 0, 0)).?;
        try testing.expectEqual(bits, translator.buttons_held);
        const capture: CaptureAction = if (bits == 0) .release else .none;
        try testing.expectEqual(capture, up.actions.capture);
    }
}

test "capture loss cancels the gesture once, without ReleaseCapture" {
    var translator = Translator.init(test_settings);
    const both_bits = win32.MK_LBUTTON | win32.MK_RBUTTON;
    _ = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 10, 10)).?;
    _ = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 10, 10)).?;
    _ = step(&translator, mouseMessage(win32.WM_RBUTTONDOWN, both_bits, 10, 10)).?;

    const cancelled = step(&translator, capture_lost_message).?;
    try testing.expect(cancelled.event == .pointer_cancelled);
    try expectActions(cancelled.actions, .none, true);
    try testing.expectEqual(@as(u8, 0), translator.buttons_held);
    try testing.expect(step(&translator, capture_lost_message) == null);

    const free = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 11, 10)).?;
    try testing.expect(free.event == .mouse_moved);
}

test "capture changes with no held button produce nothing" {
    var translator = Translator.init(test_settings);
    try testing.expect(step(&translator, capture_lost_message) == null);

    _ = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 4, 4)).?;
    const up = step(&translator, mouseMessage(win32.WM_LBUTTONUP, 0, 4, 4)).?;
    try testing.expectEqual(CaptureAction.release, up.actions.capture);
    try testing.expect(step(&translator, capture_lost_message) == null);
}

test "a captured drag outside the client stays a drag; release outside then re-enter" {
    var translator = Translator.init(test_settings);
    const held = win32.MK_LBUTTON;
    _ = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 10, 10)).?;
    _ = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, held, 10, 10)).?;

    for ([_]i16{ -20, -40, -60 }) |x_px| {
        const drag = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, held, x_px, 10)).?;
        const x: f64 = @floatFromInt(x_px);
        try testing.expectEqual(x / 2, drag.event.mouse_dragged.position.x);
        try expectActions(drag.actions, .none, false);
    }
    const up = step(&translator, mouseMessage(win32.WM_LBUTTONUP, 0, -60, 10)).?;
    try expectActions(up.actions, .release, true);

    try testing.expect(step(&translator, leave_message).?.event == .mouse_exited);
    const back = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 10, 10)).?;
    try testing.expect(back.event == .mouse_entered);
    try expectActions(back.actions, .none, true);
}

test "a leave during a captured drag reports one exit and the arrival after release" {
    var translator = Translator.init(test_settings);
    const held = win32.MK_LBUTTON;
    _ = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 10, 10)).?;
    _ = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, held, 10, 10)).?;

    try testing.expect(step(&translator, leave_message).?.event == .mouse_exited);
    try testing.expect(step(&translator, leave_message) == null);
    const outside = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, held, -30, 10)).?;
    try testing.expect(outside.event == .mouse_dragged);
    const inside = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, held, 20, 10)).?;
    try testing.expect(inside.event == .mouse_dragged);

    const up = step(&translator, mouseMessage(win32.WM_LBUTTONUP, 0, 20, 10)).?;
    try expectActions(up.actions, .release, false);
    const arrival = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 21, 10)).?;
    try testing.expect(arrival.event == .mouse_entered);
    try expectActions(arrival.actions, .none, true);
    try testing.expect(step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 22, 10)).?.event ==
        .mouse_moved);
}

test "motion reports a release the window never saw, one button at a time" {
    var translator = Translator.init(test_settings);
    _ = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 10, 10)).?;
    _ = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 10, 10)).?;
    _ = step(&translator, mouseMessage(win32.WM_MBUTTONDOWN, win32.MK_MBUTTON, 10, 10)).?;

    const first = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 30, 10)).?;
    try testing.expectEqual(MouseButton.left, first.event.mouse_up.button);
    try testing.expectEqual(@as(f64, 15), first.event.mouse_up.position.x);
    try expectActions(first.actions, .none, false);
    const second = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 30, 10)).?;
    try testing.expectEqual(MouseButton.middle, second.event.mouse_up.button);
    try expectActions(second.actions, .release, true);
    try testing.expect(step(&translator, mouseMessage(win32.WM_MOUSEMOVE, 0, 30, 10)).?.event ==
        .mouse_moved);
}

test "key state never adds a button the window did not see pressed" {
    var translator = Translator.init(test_settings);
    const held = win32.MK_LBUTTON | win32.MK_RBUTTON | win32.MK_MBUTTON;
    const arrival = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, held, 10, 10)).?;
    try testing.expect(arrival.event == .mouse_entered);
    const motion = step(&translator, mouseMessage(win32.WM_MOUSEMOVE, held, 11, 10)).?;
    try testing.expect(motion.event == .mouse_moved);
    try testing.expectEqual(@as(u8, 0), translator.buttons_held);
}

fn systemKey(id: u32, virtual_key: u8, alt_down: bool) Message {
    const flags: usize = if (alt_down) flag_alt_down else 0;
    return .{ .id = id, .wparam = virtual_key, .lparam = @bitCast(flags) };
}

test "only Alt+F4 and Alt+Space reach DefWindowProcW" {
    const f4: u8 = @intCast(win32.VK_F4);
    const f10: u8 = @intCast(win32.VK_F10);
    const space: u8 = @intCast(win32.VK_SPACE);
    const alt: u8 = @intCast(win32.VK_MENU);
    for ([_]u32{ win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP }) |id| {
        try testing.expect(systemKeyUsesDefault(&systemKey(id, f4, true)));
        try testing.expect(systemKeyUsesDefault(&systemKey(id, space, true)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, alt, true)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, alt, false)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, f10, false)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, f10, true)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, 'A', true)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, f4, false)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, space, false)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, f4 - 1, true)));
        try testing.expect(!systemKeyUsesDefault(&systemKey(id, f4 + 1, true)));
    }

    try testing.expect(systemKeyUsesDefault(&systemKey(win32.WM_SYSCHAR, ' ', true)));
    try testing.expect(!systemKeyUsesDefault(&systemKey(win32.WM_SYSCHAR, 'a', true)));
    try testing.expect(!systemKeyUsesDefault(&systemKey(win32.WM_SYSCHAR, ' ' + 1, true)));
}

test "system keys are delivered as key events with Alt" {
    var translator = Translator.init(test_settings);
    var context = testContext(0);
    context.modifiers.alt = true;
    const press = translator.translate(&systemKey(win32.WM_SYSKEYDOWN, 'F', true), &context).?;
    try testing.expectEqual(KeyCode.f, press.key_down.key);
    try testing.expect(press.key_down.modifiers.alt);
    const release = translator.translate(&systemKey(win32.WM_SYSKEYUP, 'F', true), &context).?;
    try testing.expectEqual(KeyCode.f, release.key_up.key);
    try testing.expect(translator.translate(&systemKey(win32.WM_SYSCHAR, 'f', true), &context) ==
        null);
}

fn pressClickCount(translator: *Translator, message: Message, time_ms: u32) u32 {
    assert(message.id == win32.WM_LBUTTONDOWN or message.id == win32.WM_RBUTTONDOWN);
    const event = translator.translate(&message, &testContext(time_ms)).?;
    return event.mouse_down.click_count;
}

test "click counting honours button, time, and distance thresholds" {
    var translator = Translator.init(test_settings);
    const point = pointLParam(100, 100);
    const left = Message{ .id = win32.WM_LBUTTONDOWN, .wparam = 0, .lparam = point };
    const right = Message{ .id = win32.WM_RBUTTONDOWN, .wparam = 0, .lparam = point };
    const near_point = pointLParam(104, 100);
    const far_point = pointLParam(109, 100);
    const near = Message{ .id = win32.WM_LBUTTONDOWN, .wparam = 0, .lparam = near_point };
    const far = Message{ .id = win32.WM_LBUTTONDOWN, .wparam = 0, .lparam = far_point };

    try testing.expectEqual(@as(u32, 1), pressClickCount(&translator, left, 1000));
    try testing.expectEqual(@as(u32, 2), pressClickCount(&translator, left, 1500));
    try testing.expectEqual(@as(u32, 3), pressClickCount(&translator, near, 1600));
    try testing.expectEqual(@as(u32, 1), pressClickCount(&translator, far, 1700));
    try testing.expectEqual(@as(u32, 1), pressClickCount(&translator, far, 2201));
    try testing.expectEqual(@as(u32, 1), pressClickCount(&translator, right, 2202));

    var wrapping = Translator.init(test_settings);
    try testing.expectEqual(@as(u32, 1), pressClickCount(&wrapping, left, 0xFFFF_FFF0));
    try testing.expectEqual(@as(u32, 2), pressClickCount(&wrapping, left, 10));
}

test "WM_CHAR assembles surrogate pairs and drops control characters" {
    var translator = Translator.init(test_settings);
    const context = testContext(0);
    const char = struct {
        fn message(unit: u16) Message {
            return .{ .id = win32.WM_CHAR, .wparam = unit, .lparam = 0 };
        }
    };

    const ascii = translator.translate(&char.message('a'), &context).?.text_input.text;
    try testing.expectEqualStrings("a", ascii);
    const latin = translator.translate(&char.message(0xE9), &context).?.text_input.text;
    try testing.expectEqualStrings("\u{E9}", latin);

    try testing.expect(translator.translate(&char.message(0xD83D), &context) == null);
    const emoji = translator.translate(&char.message(0xDE00), &context).?.text_input.text;
    try testing.expectEqualStrings("\u{1F600}", emoji);

    try testing.expect(translator.translate(&char.message(0xDE00), &context) == null);
    try testing.expect(translator.translate(&char.message(0x08), &context) == null);
    try testing.expect(translator.translate(&char.message(0x7F), &context) == null);
}

test "virtual keys map to positional key codes" {
    try testing.expectEqual(KeyCode.a, keyCodeFromVirtualKey('A', 0));
    try testing.expectEqual(KeyCode.z, keyCodeFromVirtualKey('Z', 0));
    try testing.expectEqual(KeyCode.@"0", keyCodeFromVirtualKey('0', 0));
    try testing.expectEqual(KeyCode.keypad_9, keyCodeFromVirtualKey(0x69, 0));
    try testing.expectEqual(KeyCode.f1, keyCodeFromVirtualKey(0x70, 0));
    try testing.expectEqual(KeyCode.f20, keyCodeFromVirtualKey(0x83, 0));

    try testing.expectEqual(KeyCode.@"return", keyCodeFromVirtualKey(0x0D, 0));
    try testing.expectEqual(KeyCode.keypad_enter, keyCodeFromVirtualKey(0x0D, flag_extended));
    try testing.expectEqual(KeyCode.control, keyCodeFromVirtualKey(0x11, 0));
    try testing.expectEqual(KeyCode.right_control, keyCodeFromVirtualKey(0x11, flag_extended));
    const left_shift_flags: usize = 0x2A << scan_code_shift;
    const right_shift_flags: usize = 0x36 << scan_code_shift;
    try testing.expectEqual(KeyCode.shift, keyCodeFromVirtualKey(0x10, left_shift_flags));
    try testing.expectEqual(KeyCode.right_shift, keyCodeFromVirtualKey(0x10, right_shift_flags));

    try testing.expectEqual(KeyCode.unknown, keyCodeFromVirtualKey(0x84, 0));
    try testing.expectEqual(KeyCode.unknown, keyCodeFromVirtualKey('A' - 1, 0));
    try testing.expectEqual(KeyCode.unknown, keyCodeFromVirtualKey('9' + 1, 0));
    try testing.expectEqual(KeyCode.unknown, keyCodeFromVirtualKey(0xFF, 0));
}

test "wheel detents scroll toward the content end when turned toward the user" {
    var translator = Translator.init(test_settings);
    const toward_user: win32.WPARAM = @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16;
    const message = Message{ .id = win32.WM_MOUSEWHEEL, .wparam = toward_user, .lparam = 0 };
    const scroll = translator.translate(&message, &testContext(0)).?.scroll;
    try testing.expectEqual(wheel_detent_px, scroll.delta.y);
    try testing.expectEqual(@as(f64, 0), scroll.delta.x);
    try testing.expectEqual(@as(f64, 10), scroll.position.x);
    try testing.expectEqual(@as(f64, 20), scroll.position.y);
}

test "device to logical conversion keeps negative client positions" {
    const point = logicalFromDevice(.{ .x = -30, .y = 45 }, 1.5);
    try testing.expectEqual(@as(f64, -20), point.x);
    try testing.expectEqual(@as(f64, 30), point.y);
    const corner = win32.POINT{ .x = std.math.minInt(i16), .y = std.math.maxInt(i16) };
    const extreme = logicalFromDevice(corner, 1.0);
    try testing.expectEqual(@as(f64, -32768), extreme.x);
    try testing.expectEqual(@as(f64, 32767), extreme.y);
}

test "keys the IME consumed produce no key events" {
    var translator = Translator.init(test_settings);
    const context = testContext(0);
    const processed: win32.WPARAM = virtual_key_ime_processed;
    const press = Message{ .id = win32.WM_KEYDOWN, .wparam = processed, .lparam = 0 };
    const release = Message{ .id = win32.WM_KEYUP, .wparam = processed, .lparam = 0 };
    try testing.expect(translator.translate(&press, &context) == null);
    try testing.expect(translator.translate(&release, &context) == null);

    const before = Message{ .id = win32.WM_KEYDOWN, .wparam = processed - 1, .lparam = 0 };
    const after = Message{ .id = win32.WM_KEYUP, .wparam = processed + 1, .lparam = 0 };
    try testing.expect(translator.translate(&before, &context).? == .key_down);
    try testing.expect(translator.translate(&after, &context).? == .key_up);
}

test "key repeat is reported only for presses" {
    var translator = Translator.init(test_settings);
    const held: win32.LPARAM = 1 << 30;
    const press = Message{ .id = win32.WM_KEYDOWN, .wparam = 'A', .lparam = held };
    const release = Message{ .id = win32.WM_KEYUP, .wparam = 'A', .lparam = held };
    try testing.expect(translator.translate(&press, &testContext(0)).?.key_down.is_repeat);
    try testing.expect(!translator.translate(&release, &testContext(0)).?.key_up.is_repeat);
}

test "focus loss reports the held button and keys in one event" {
    var translator = Translator.init(test_settings);
    const context = testContext(0);
    const focus_lost = Message{ .id = win32.WM_KILLFOCUS, .wparam = 0, .lparam = 0 };
    const shift_flags: win32.LPARAM = 0x2A << scan_code_shift;
    const shift = Message{ .id = win32.WM_KEYDOWN, .wparam = 0x10, .lparam = shift_flags };
    const letter = Message{ .id = win32.WM_KEYDOWN, .wparam = 'A', .lparam = 0 };
    _ = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 4, 4)).?;
    _ = translator.translate(&shift, &context).?;
    _ = translator.translate(&letter, &context).?;
    try testing.expectEqual(@as(usize, 2), translator.keys_held.count());

    const lost = step(&translator, focus_lost).?;
    try testing.expect(lost.event.focus_lost.pointer_cancelled);
    try expectActions(lost.actions, .release, false);
    const keys = lost.event.focus_lost.keys_held;
    try testing.expectEqual(@as(usize, 2), keys.count());
    try testing.expect(keys.isSet(@backingInt(KeyCode.a)));
    try testing.expect(keys.isSet(@backingInt(KeyCode.shift)));
    try testing.expect(translator.translate(&focus_lost, &context) == null);
    try testing.expectEqual(@as(u8, 0), translator.buttons_held);
    try testing.expectEqual(@as(usize, 0), translator.keys_held.count());
}

test "focus loss with every key held stays within message_event_count_max" {
    var translator = Translator.init(test_settings);
    const context = testContext(0);
    var expected: KeySet = .empty;
    var virtual_key: u32 = 0;
    while (virtual_key < 256) : (virtual_key += 1) {
        const press = Message{ .id = win32.WM_KEYDOWN, .wparam = virtual_key, .lparam = 0 };
        const event = translator.translate(&press, &context) orelse continue;
        if (event.key_down.key != .unknown) expected.set(@backingInt(event.key_down.key));
    }
    _ = step(&translator, mouseMessage(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 4, 4)).?;
    _ = step(&translator, mouseMessage(win32.WM_RBUTTONDOWN, win32.MK_RBUTTON, 4, 4)).?;
    try testing.expect(expected.count() > 64);

    const focus_lost = Message{ .id = win32.WM_KILLFOCUS, .wparam = 0, .lparam = 0 };
    const event = translator.translate(&focus_lost, &context).?;
    try testing.expect(event.focus_lost.pointer_cancelled);
    try testing.expect(event.focus_lost.keys_held.eql(expected));
    comptime assert(message_event_count_max == 1);
    try testing.expect(translator.translate(&focus_lost, &context) == null);
}

test "focus loss with nothing held reports nothing and resets click and text state" {
    var translator = Translator.init(test_settings);
    const context = testContext(0);
    const focus_lost = Message{ .id = win32.WM_KILLFOCUS, .wparam = 0, .lparam = 0 };
    const press = mouseMessage(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 4, 4);
    const release = mouseMessage(win32.WM_LBUTTONUP, 0, 4, 4);
    try testing.expectEqual(@as(u32, 1), pressClickCount(&translator, press, 100));
    _ = translator.translate(&release, &context).?;
    const high = Message{ .id = win32.WM_CHAR, .wparam = 0xD83D, .lparam = 0 };
    try testing.expect(translator.translate(&high, &context) == null);

    try testing.expect(translator.translate(&focus_lost, &context) == null);
    try testing.expectEqual(@as(u32, 1), pressClickCount(&translator, press, 150));
    const low = Message{ .id = win32.WM_CHAR, .wparam = 0xDE00, .lparam = 0 };
    try testing.expect(translator.translate(&low, &context) == null);
}

test "a key released normally is not released again on focus loss" {
    var translator = Translator.init(test_settings);
    const context = testContext(0);
    const press = Message{ .id = win32.WM_KEYDOWN, .wparam = 'A', .lparam = 0 };
    const release = Message{ .id = win32.WM_KEYUP, .wparam = 'A', .lparam = 0 };
    _ = translator.translate(&press, &context).?;
    _ = translator.translate(&release, &context).?;
    try testing.expectEqual(@as(usize, 0), translator.keys_held.count());
    const focus_lost = Message{ .id = win32.WM_KILLFOCUS, .wparam = 0, .lparam = 0 };
    try testing.expect(translator.translate(&focus_lost, &context) == null);
}
