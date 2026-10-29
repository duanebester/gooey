//! Win32 input translation: one `WM_*` message in, at most one Gooey event out.
//!
//! Every window message that carries user input passes through
//! `Translator.translate`, and the window delivers the result in one place
//! (`Window.handleInput`). Phase 4 of 0.4.0 replaces that delivery with a
//! bounded `EventQueue`; keeping translation in one pure function means the
//! change touches one call rather than the window procedure
//! (`docs/windows-port.md`, seam 1).
//!
//! The translator holds no Win32 handles and calls no Win32 functions. State
//! the OS owns (modifier keys, message time, the pointer's last position) is
//! sampled by the caller into `Context`, so every rule here is testable on any
//! host.

const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("../../geometry/geometry.zig");
const input = @import("../../input/events.zig");
const win32 = @import("win32.zig");

const KeyCode = input.KeyCode;
const MouseButton = input.MouseButton;

/// Logical pixels scrolled per wheel detent. Matches the 15 units per detent
/// libinput reports on the Wayland backend, so a scroll view moves the same
/// distance per notch on both.
pub const wheel_detent_px: f64 = 15.0;

/// Longest UTF-8 encoding of one code point: the text buffer's capacity.
const text_bytes_max: u8 = 4;

/// One window message, as the window procedure receives it.
pub const Message = struct {
    id: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
};

/// OS state sampled by the caller for the message being translated.
pub const Context = struct {
    /// Device pixels per logical pixel; client coordinates divide by it.
    scale_factor: f64,
    modifiers: input.Modifiers,
    /// `GetMessageTime`, in milliseconds. Wraps after 49.7 days.
    time_ms: u32,
    /// Last known pointer position, in logical pixels. Wheel messages carry
    /// screen coordinates, so scroll events report this instead.
    pointer: geometry.Point(f64),
};

/// Thresholds for grouping presses into double and triple clicks, read from
/// the user's system settings once at platform initialization.
pub const ClickSettings = struct {
    time_ms_max: u32,
    /// Largest distance, in device pixels on each axis, between presses.
    distance_px_max: u32,
};

pub const Translator = struct {
    click_settings: ClickSettings,

    click_count: u32 = 0,
    click_time_ms: u32 = 0,
    click_x_px: i32 = 0,
    click_y_px: i32 = 0,
    click_button: ?MouseButton = null,

    /// Held button, so pointer motion reports drags against it.
    pressed_button: ?MouseButton = null,
    /// Whether the pointer was last seen inside the client area.
    pointer_inside: bool = false,

    /// The first half of a UTF-16 surrogate pair, awaiting its second half.
    high_surrogate: ?u16 = null,
    /// Storage for the `text_input` slice. Valid until the next translation.
    text_buffer: [text_bytes_max]u8 = undefined,

    pub fn init(click_settings: ClickSettings) Translator {
        assert(click_settings.time_ms_max > 0);
        assert(click_settings.distance_px_max > 0);
        return .{ .click_settings = click_settings };
    }

    /// Translate one message. Returns null for messages that carry no input,
    /// and for input that completes no event yet (half a surrogate pair).
    pub fn translate(
        self: *Translator,
        message: Message,
        context: *const Context,
    ) ?input.InputEvent {
        assert(context.scale_factor > 0);
        assert(self.click_count <= std.math.maxInt(u32) - 1);
        return switch (message.id) {
            win32.WM_MOUSEMOVE => self.pointerMoved(message.lparam, context),
            win32.WM_MOUSELEAVE => self.pointerLeft(context),
            win32.WM_LBUTTONDOWN => self.buttonDown(.left, message.lparam, context),
            win32.WM_RBUTTONDOWN => self.buttonDown(.right, message.lparam, context),
            win32.WM_MBUTTONDOWN => self.buttonDown(.middle, message.lparam, context),
            win32.WM_LBUTTONUP => self.buttonUp(.left, message.lparam, context),
            win32.WM_RBUTTONUP => self.buttonUp(.right, message.lparam, context),
            win32.WM_MBUTTONUP => self.buttonUp(.middle, message.lparam, context),
            win32.WM_MOUSEWHEEL => wheel(.vertical, message.wparam, context),
            win32.WM_MOUSEHWHEEL => wheel(.horizontal, message.wparam, context),
            win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => .{ .key_down = keyEvent(message, context) },
            win32.WM_KEYUP, win32.WM_SYSKEYUP => .{ .key_up = keyEvent(message, context) },
            win32.WM_CHAR => self.character(@truncate(message.wparam)),
            else => null,
        };
    }

    fn pointerMoved(
        self: *Translator,
        lparam: win32.LPARAM,
        context: *const Context,
    ) input.InputEvent {
        const mouse = input.MouseEvent{
            .position = logicalPosition(lparam, context.scale_factor),
            .button = self.pressed_button orelse .left,
            .click_count = 0,
            .modifiers = context.modifiers,
        };
        // The first motion after the pointer arrives reports the arrival; the
        // window arms `WM_MOUSELEAVE` tracking when it sees it.
        if (!self.pointer_inside) {
            self.pointer_inside = true;
            return .{ .mouse_entered = mouse };
        }
        if (self.pressed_button != null) return .{ .mouse_dragged = mouse };
        return .{ .mouse_moved = mouse };
    }

    fn pointerLeft(self: *Translator, context: *const Context) ?input.InputEvent {
        // Reported once per arrival, however many leave notifications follow.
        if (!self.pointer_inside) return null;
        self.pointer_inside = false;
        assert(!self.pointer_inside);
        return .{ .mouse_exited = .{
            .position = context.pointer,
            .button = self.pressed_button orelse .left,
            .click_count = 0,
            .modifiers = context.modifiers,
        } };
    }

    fn buttonDown(
        self: *Translator,
        button: MouseButton,
        lparam: win32.LPARAM,
        context: *const Context,
    ) input.InputEvent {
        const x_px: i32 = win32.xFromLParam(lparam);
        const y_px: i32 = win32.yFromLParam(lparam);
        self.click_count = self.nextClickCount(button, x_px, y_px, context.time_ms);
        self.click_time_ms = context.time_ms;
        self.click_x_px = x_px;
        self.click_y_px = y_px;
        self.click_button = button;
        self.pressed_button = button;
        assert(self.click_count >= 1);
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
        if (self.pressed_button == button) self.pressed_button = null;
        return .{ .mouse_up = .{
            .position = logicalPosition(lparam, context.scale_factor),
            .button = button,
            .click_count = @max(self.click_count, 1),
            .modifiers = context.modifiers,
        } };
    }

    /// The click count for a press: one more than the last press when it was
    /// the same button, soon enough, and close enough; otherwise one.
    fn nextClickCount(
        self: *const Translator,
        button: MouseButton,
        x_px: i32,
        y_px: i32,
        time_ms: u32,
    ) u32 {
        const previous = self.click_button orelse return 1;
        if (previous != button) return 1;
        // Wrapping subtraction: message time wraps every 49.7 days.
        if (time_ms -% self.click_time_ms > self.click_settings.time_ms_max) return 1;
        if (@abs(x_px - self.click_x_px) > self.click_settings.distance_px_max) return 1;
        if (@abs(y_px - self.click_y_px) > self.click_settings.distance_px_max) return 1;
        assert(self.click_count >= 1);
        return self.click_count + 1;
    }

    /// Assemble UTF-16 code units from `WM_CHAR` into UTF-8 text. Control
    /// characters are dropped: their keys already arrived as `key_down`.
    fn character(self: *Translator, unit: u16) ?input.InputEvent {
        const code_point: u21 = switch (unit) {
            0xD800...0xDBFF => {
                self.high_surrogate = unit;
                return null;
            },
            0xDC00...0xDFFF => blk: {
                // A low half without its high half is malformed; drop it.
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

        // Surrogates were consumed above, so every remaining value encodes.
        const length = std.unicode.utf8Encode(code_point, &self.text_buffer) catch unreachable;
        assert(length >= 1);
        assert(length <= text_bytes_max);
        return .{ .text_input = .{ .text = self.text_buffer[0..length] } };
    }
};

const WheelAxis = enum { vertical, horizontal };

fn wheel(axis: WheelAxis, wparam: win32.WPARAM, context: *const Context) input.InputEvent {
    const detents = @as(f64, @floatFromInt(win32.wheelDeltaFromWParam(wparam))) /
        @as(f64, @floatFromInt(win32.WHEEL_DELTA));
    // Windows reports a vertical wheel turned away from the user as positive;
    // Gooey's scroll delta grows toward the end of the content.
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

fn keyEvent(message: Message, context: *const Context) input.KeyEvent {
    assert(message.id == win32.WM_KEYDOWN or message.id == win32.WM_KEYUP or
        message.id == win32.WM_SYSKEYDOWN or message.id == win32.WM_SYSKEYUP);
    const flags: usize = @bitCast(message.lparam);
    // Bit 30: the key was already down. Always set on release, so only a
    // press can be a repeat.
    const was_down = flags & (1 << 30) != 0;
    const is_press = message.id == win32.WM_KEYDOWN or message.id == win32.WM_SYSKEYDOWN;
    return .{
        .key = keyCodeFromVirtualKey(@truncate(message.wparam), flags),
        .modifiers = context.modifiers,
        // Text arrives separately as `WM_CHAR`, after `TranslateMessage`.
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = is_press and was_down,
    };
}

fn logicalPosition(lparam: win32.LPARAM, scale_factor: f64) geometry.Point(f64) {
    assert(scale_factor > 0);
    const x_px: f64 = @floatFromInt(win32.xFromLParam(lparam));
    const y_px: f64 = @floatFromInt(win32.yFromLParam(lparam));
    return .{ .x = x_px / scale_factor, .y = y_px / scale_factor };
}

// =============================================================================
// Virtual-key translation
// =============================================================================

/// Bit 24 of a key message's flags: the key is on the extended block, which
/// separates right Ctrl, right Alt, and keypad Enter from their twins.
const flag_extended: usize = 1 << 24;
/// The scan code, bits 16..23. Right Shift is the only way to tell it apart.
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

/// Map a Win32 virtual-key code (`VK_*`) and its message flags to Gooey's
/// positional key code. Unmapped keys become `.unknown`.
pub fn keyCodeFromVirtualKey(virtual_key: u8, flags: usize) KeyCode {
    const extended = flags & flag_extended != 0;
    return switch (virtual_key) {
        'A'...'Z' => letter_keys[virtual_key - 'A'],
        '0'...'9' => digit_keys[virtual_key - '0'],
        0x60...0x69 => keypad_digit_keys[virtual_key - 0x60], // VK_NUMPAD0..9
        0x70...0x83 => function_keys[virtual_key - 0x70], // VK_F1..F20
        0x08 => .delete, // VK_BACK
        0x09 => .tab,
        0x0D => if (extended) .keypad_enter else .@"return",
        0x10 => if (@as(u8, @truncate(flags >> scan_code_shift)) == scan_code_right_shift)
            .right_shift
        else
            .shift,
        0x11 => if (extended) .right_control else .control,
        0x12 => if (extended) .right_option else .option, // VK_MENU
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
        0x5B => .command, // VK_LWIN
        0x5C => .right_command, // VK_RWIN
        0x6A => .keypad_multiply,
        0x6B => .keypad_plus,
        0x6D => .keypad_minus,
        0x6E => .keypad_decimal,
        0x6F => .keypad_divide,
        0x90 => .keypad_clear, // VK_NUMLOCK, at the keypad-clear position
        0xBA => .semicolon, // VK_OEM_1
        0xBB => .equal, // VK_OEM_PLUS
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash, // VK_OEM_2
        0xC0 => .grave, // VK_OEM_3
        0xDB => .left_bracket, // VK_OEM_4
        0xDC => .backslash, // VK_OEM_5
        0xDD => .right_bracket, // VK_OEM_6
        0xDE => .quote, // VK_OEM_7
        else => .unknown,
    };
}

// =============================================================================
// Tests
// =============================================================================

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

test "pointer motion reports arrival once, then motion, then drags" {
    var translator = Translator.init(test_settings);
    const context = testContext(0);
    const move = Message{ .id = win32.WM_MOUSEMOVE, .wparam = 0, .lparam = pointLParam(40, 60) };

    const entered = translator.translate(move, &context).?;
    try testing.expectEqual(@as(f64, 20), entered.mouse_entered.position.x);
    try testing.expectEqual(@as(f64, 30), entered.mouse_entered.position.y);
    try testing.expect(translator.translate(move, &context).? == .mouse_moved);

    const press = Message{ .id = win32.WM_LBUTTONDOWN, .wparam = 0, .lparam = pointLParam(40, 60) };
    _ = translator.translate(press, &context).?;
    try testing.expect(translator.translate(move, &context).? == .mouse_dragged);

    const leave = Message{ .id = win32.WM_MOUSELEAVE, .wparam = 0, .lparam = 0 };
    try testing.expect(translator.translate(leave, &context).? == .mouse_exited);
    // Negative space: a second leave without an arrival reports nothing.
    try testing.expect(translator.translate(leave, &context) == null);
}

fn pressClickCount(translator: *Translator, message: Message, time_ms: u32) u32 {
    assert(message.id == win32.WM_LBUTTONDOWN or message.id == win32.WM_RBUTTONDOWN);
    const event = translator.translate(message, &testContext(time_ms)).?;
    return event.mouse_down.click_count;
}

test "click counting honours button, time, and distance thresholds" {
    // Methodology: press at the exact time and distance thresholds (still a
    // multi-click), then one past each threshold in turn (the count resets).
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

    // Message time wraps; a press just after the wrap still groups.
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

    const ascii = translator.translate(char.message('a'), &context).?.text_input.text;
    try testing.expectEqualStrings("a", ascii);
    const latin = translator.translate(char.message(0xE9), &context).?.text_input.text;
    try testing.expectEqualStrings("\u{E9}", latin);

    // U+1F600 is D83D DE00 in UTF-16.
    try testing.expect(translator.translate(char.message(0xD83D), &context) == null);
    const emoji = translator.translate(char.message(0xDE00), &context).?.text_input.text;
    try testing.expectEqualStrings("\u{1F600}", emoji);

    // Negative space: an unpaired low half, backspace, and DEL produce nothing.
    try testing.expect(translator.translate(char.message(0xDE00), &context) == null);
    try testing.expect(translator.translate(char.message(0x08), &context) == null);
    try testing.expect(translator.translate(char.message(0x7F), &context) == null);
}

test "virtual keys map to positional key codes" {
    try testing.expectEqual(KeyCode.a, keyCodeFromVirtualKey('A', 0));
    try testing.expectEqual(KeyCode.z, keyCodeFromVirtualKey('Z', 0));
    try testing.expectEqual(KeyCode.@"0", keyCodeFromVirtualKey('0', 0));
    try testing.expectEqual(KeyCode.keypad_9, keyCodeFromVirtualKey(0x69, 0));
    try testing.expectEqual(KeyCode.f1, keyCodeFromVirtualKey(0x70, 0));
    try testing.expectEqual(KeyCode.f20, keyCodeFromVirtualKey(0x83, 0));

    // Twins split by the extended flag and the scan code.
    try testing.expectEqual(KeyCode.@"return", keyCodeFromVirtualKey(0x0D, 0));
    try testing.expectEqual(KeyCode.keypad_enter, keyCodeFromVirtualKey(0x0D, flag_extended));
    try testing.expectEqual(KeyCode.control, keyCodeFromVirtualKey(0x11, 0));
    try testing.expectEqual(KeyCode.right_control, keyCodeFromVirtualKey(0x11, flag_extended));
    const left_shift_flags: usize = 0x2A << scan_code_shift;
    const right_shift_flags: usize = 0x36 << scan_code_shift;
    try testing.expectEqual(KeyCode.shift, keyCodeFromVirtualKey(0x10, left_shift_flags));
    try testing.expectEqual(KeyCode.right_shift, keyCodeFromVirtualKey(0x10, right_shift_flags));

    // Negative space: one past each range, and an unassigned code.
    try testing.expectEqual(KeyCode.unknown, keyCodeFromVirtualKey(0x84, 0)); // VK_F21
    // 'Z' + 1 is VK_LWIN, so the letter range is bounded from below instead.
    try testing.expectEqual(KeyCode.unknown, keyCodeFromVirtualKey('A' - 1, 0));
    try testing.expectEqual(KeyCode.unknown, keyCodeFromVirtualKey('9' + 1, 0));
    try testing.expectEqual(KeyCode.unknown, keyCodeFromVirtualKey(0xFF, 0));
}

test "wheel detents scroll toward the content end when turned toward the user" {
    var translator = Translator.init(test_settings);
    const toward_user: win32.WPARAM = @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16;
    const message = Message{ .id = win32.WM_MOUSEWHEEL, .wparam = toward_user, .lparam = 0 };
    const scroll = translator.translate(message, &testContext(0)).?.scroll;
    try testing.expectEqual(wheel_detent_px, scroll.delta.y);
    try testing.expectEqual(@as(f64, 0), scroll.delta.x);
    try testing.expectEqual(@as(f64, 10), scroll.position.x);
}

test "key repeat is reported only for presses" {
    var translator = Translator.init(test_settings);
    const held: win32.LPARAM = 1 << 30;
    const press = Message{ .id = win32.WM_KEYDOWN, .wparam = 'A', .lparam = held };
    const release = Message{ .id = win32.WM_KEYUP, .wparam = 'A', .lparam = held };
    try testing.expect(translator.translate(press, &testContext(0)).?.key_down.is_repeat);
    try testing.expect(!translator.translate(release, &testContext(0)).?.key_up.is_repeat);
}
