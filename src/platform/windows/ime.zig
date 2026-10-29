//! Win32 IME composition through IMM32.
//!
//! Gooey draws composition text inline, as the text widgets' preedit, so the
//! window hides the IME's own composition window (`WM_IME_SETCONTEXT`) and
//! keeps its candidate list. `WM_IME_COMPOSITION` is read here and delivered
//! as the shared `text_input` (committed text) and `composition` (preedit)
//! events, the same pair the Wayland and macOS backends produce. The caret
//! rectangle the runtime publishes each frame through `setImeCursorRect`
//! places the candidate list; phase 4 of 0.4.0 moves that rectangle to
//! `Query.imeCursorRect` without changing anything in this file.
//!
//! ## Memory (CLAUDE.md section 2)
//!
//! Strings are read into a fixed per-window `[units_max]u16` and encoded into
//! fixed `[bytes_max]u8` buffers, both reserved when the window is created.
//! `ImmGetCompositionStringW` is asked for the size first, so a string that
//! exceeds `units_max` is detected before anything is copied; the window
//! then applies the overload policy described at `readString`.
//!
//! ## Resource sketch
//!
//! One composition update costs two IMM calls per string read (size, then
//! copy), at most `units_max` UTF-16 units decoded, and at most two events.
//! Updates arrive at typing rate, a few per second, so the cost is negligible
//! next to the frame they schedule. Resident storage per window is
//! 2 * `units_max` + 2 * `bytes_max` bytes: 8 KiB at the limits below.

const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("../../geometry/geometry.zig");
const win32 = @import("win32.zig");

/// Longest composition or result string read, in UTF-16 units. Generous next
/// to the IMEs' own composition limits, which are a few hundred characters.
pub const units_max: u32 = 1024;

/// A UTF-16 unit encodes to at most three UTF-8 bytes: a BMP scalar takes up
/// to three, a surrogate pair takes four for its two units, and an unpaired
/// surrogate becomes U+FFFD, which takes three.
const utf8_bytes_per_unit_max: u32 = 3;

/// UTF-8 capacity that holds any `units_max` UTF-16 units.
pub const bytes_max: u32 = units_max * utf8_bytes_per_unit_max;

// =============================================================================
// IMM32 bindings
// =============================================================================

/// An input context. Borrowed from the window by `ImmGetContext` and returned
/// with `ImmReleaseContext`.
pub const HIMC = *opaque {};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32,
    ptCurrentPos: win32.POINT,
    rcArea: win32.RECT,
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: u32,
    dwStyle: u32,
    ptCurrentPos: win32.POINT,
    rcArea: win32.RECT,
};

// `WM_IME_COMPOSITION` flags and `ImmGetCompositionStringW` indices, as in
// `imm.h`.
pub const GCS_COMPREADSTR: u32 = 0x0001;
pub const GCS_COMPREADATTR: u32 = 0x0002;
pub const GCS_COMPREADCLAUSE: u32 = 0x0004;
pub const GCS_COMPSTR: u32 = 0x0008;
pub const GCS_COMPATTR: u32 = 0x0010;
pub const GCS_COMPCLAUSE: u32 = 0x0020;
pub const GCS_CURSORPOS: u32 = 0x0080;
pub const GCS_DELTASTART: u32 = 0x0100;
pub const GCS_RESULTREADSTR: u32 = 0x0200;
pub const GCS_RESULTREADCLAUSE: u32 = 0x0400;
pub const GCS_RESULTSTR: u32 = 0x0800;
pub const GCS_RESULTCLAUSE: u32 = 0x1000;

// `WM_IME_COMPOSITION` modifiers of `GCS_COMPSTR` (Korean IMEs). They
// describe how to show the string, not which strings changed.
pub const CS_INSERTCHAR: u32 = 0x2000;
pub const CS_NOMOVECARET: u32 = 0x4000;

/// Every flag that reports a composition or result change. A message with
/// none of them is a cancellation.
const composition_flags_all: u32 = GCS_COMPREADSTR | GCS_COMPREADATTR | GCS_COMPREADCLAUSE |
    GCS_COMPSTR | GCS_COMPATTR | GCS_COMPCLAUSE | GCS_CURSORPOS | GCS_DELTASTART |
    GCS_RESULTREADSTR | GCS_RESULTREADCLAUSE | GCS_RESULTSTR | GCS_RESULTCLAUSE;

// `WM_IME_SETCONTEXT` flag that asks the default IME window to draw the
// composition string itself.
pub const ISC_SHOWUICOMPOSITIONWINDOW: usize = 0x8000_0000;

// `COMPOSITIONFORM` and `CANDIDATEFORM` styles.
pub const CFS_POINT: u32 = 0x0002;
pub const CFS_EXCLUDE: u32 = 0x0080;

// `ImmGetCompositionStringW` error results.
const IMM_ERROR_NODATA: i32 = -1;
const IMM_ERROR_GENERAL: i32 = -2;

pub extern "imm32" fn ImmGetContext(hWnd: win32.HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hWnd: win32.HWND, hIMC: HIMC) callconv(.winapi) win32.BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(
    hIMC: HIMC,
    dwIndex: u32,
    lpBuf: ?*anyopaque,
    dwBufLen: u32,
) callconv(.winapi) i32;
pub extern "imm32" fn ImmSetCompositionWindow(
    hIMC: HIMC,
    lpCompForm: *const COMPOSITIONFORM,
) callconv(.winapi) win32.BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(
    hIMC: HIMC,
    lpCandidate: *const CANDIDATEFORM,
) callconv(.winapi) win32.BOOL;

comptime {
    assert(@sizeOf(COMPOSITIONFORM) == 28);
    assert(@offsetOf(COMPOSITIONFORM, "rcArea") == 12);
    assert(@sizeOf(CANDIDATEFORM) == 32);
    assert(@offsetOf(CANDIDATEFORM, "rcArea") == 16);
    // `ImmGetCompositionStringW` takes the buffer size in bytes as a `u32`.
    assert(units_max * @sizeOf(u16) <= std.math.maxInt(u32));
    // Twelve distinct `GCS_*` bits; 0x0040 is unassigned.
    assert(@popCount(composition_flags_all) == 12);
    assert(composition_flags_all == 0x1FBF);
    assert(composition_flags_all & (CS_INSERTCHAR | CS_NOMOVECARET) == 0);
}

// =============================================================================
// Composition messages
// =============================================================================

/// Which strings one `WM_IME_COMPOSITION` changed.
pub const Changes = struct {
    result: bool,
    preedit: bool,
    /// No composition flag at all (`lParam` 0 in practice): the IME cancelled
    /// the composition. A message that changes only the cursor, attributes,
    /// clauses, or reading string is not a cancellation; the preedit stays.
    cancelled: bool,

    pub fn fromLParam(lparam: win32.LPARAM) Changes {
        const flags: usize = @bitCast(lparam);
        const changes = Changes{
            .result = flags & GCS_RESULTSTR != 0,
            .preedit = flags & GCS_COMPSTR != 0,
            .cancelled = flags & composition_flags_all == 0,
        };
        if (changes.cancelled) assert(!changes.result);
        if (changes.cancelled) assert(!changes.preedit);
        return changes;
    }
};

/// Read the composition (`GCS_COMPSTR`) or result (`GCS_RESULTSTR`) string
/// into `units`. Returns null, after logging, when the IME reports an error
/// or the string exceeds `units_max`. The caller owns the overload policy:
/// a result that does not fit goes to `DefWindowProcW`, which delivers it as
/// `WM_CHAR` without loss; a preedit that does not fit keeps the last one.
pub fn readString(context: HIMC, index: u32, units: *[units_max]u16) ?[]const u16 {
    assert(index == GCS_COMPSTR or index == GCS_RESULTSTR);
    assert(@intFromPtr(context) != 0);
    const name = if (index == GCS_COMPSTR) "composition" else "result";

    // A null buffer asks for the size in bytes without copying.
    const size_result = ImmGetCompositionStringW(context, index, null, 0);
    if (size_result == IMM_ERROR_NODATA) return units[0..0];
    if (size_result < 0) {
        std.log.warn("windows: IME {s} string unavailable (error {d})", .{ name, size_result });
        return null;
    }
    const size_bytes: u32 = @intCast(size_result);
    if (size_bytes % 2 != 0) {
        std.log.warn("windows: IME {s} string has odd size {d} bytes", .{ name, size_bytes });
        return null;
    }
    const count = @divExact(size_bytes, 2);
    if (count > units_max) {
        std.log.err("windows: IME {s} string of {d} UTF-16 units exceeds units_max ({d})", .{
            name,
            count,
            units_max,
        });
        return null;
    }
    if (count == 0) return units[0..0];

    const copied = ImmGetCompositionStringW(context, index, units, size_bytes);
    if (copied != size_result) {
        std.log.warn("windows: IME {s} string read {d} of {d} bytes", .{
            name,
            copied,
            size_result,
        });
        return null;
    }
    assert(count >= 1);
    assert(count <= units_max);
    return units[0..count];
}

/// Encode IME UTF-16 as UTF-8 into `target` and return the byte count. An
/// unpaired surrogate becomes U+FFFD, as on paste, so a misbehaving IME still
/// yields valid UTF-8 for the text widgets.
pub fn utf8FromUtf16(target: *[bytes_max]u8, units: []const u16) u32 {
    assert(units.len <= units_max);
    const units_count: u32 = @intCast(units.len);
    var index: u32 = 0;
    var count: u32 = 0;
    while (index < units_count) {
        // Invariant: every unit consumed so far wrote at most three bytes,
        // so the remaining units always fit in the remaining space.
        assert(count <= utf8_bytes_per_unit_max * index);
        assert(utf8_bytes_per_unit_max * (units_count - index) <= bytes_max - count);
        const decoded = decodeUnit(units, index);
        // `decodeUnit` yields only scalar values, and the invariant above
        // leaves at least three bytes per remaining unit, so encoding cannot
        // fail.
        const length = std.unicode.utf8Encode(decoded.code_point, target[count..]) catch
            unreachable;
        assert(length <= utf8_bytes_per_unit_max * decoded.units);
        count += length;
        index += decoded.units;
    }
    assert(index == units_count);
    assert(count <= bytes_max);
    return count;
}

const Decoded = struct {
    code_point: u21,
    /// UTF-16 units consumed: two for a surrogate pair, otherwise one.
    units: u32,
};

fn decodeUnit(units: []const u16, index: usize) Decoded {
    assert(index < units.len);
    const unit = units[index];
    const replacement = Decoded{ .code_point = std.unicode.replacement_character, .units = 1 };
    if (isLowSurrogate(unit)) return replacement;
    if (!isHighSurrogate(unit)) return .{ .code_point = unit, .units = 1 };

    const following_index = index + 1;
    if (following_index < units.len) {
        const following = units[following_index];
        if (isLowSurrogate(following)) {
            const high_bits: u21 = unit - 0xD800;
            const low_bits: u21 = following - 0xDC00;
            return .{ .code_point = 0x1_0000 + (high_bits << 10) + low_bits, .units = 2 };
        }
    }
    return replacement;
}

fn isHighSurrogate(unit: u16) bool {
    return unit >= 0xD800 and unit <= 0xDBFF;
}

fn isLowSurrogate(unit: u16) bool {
    return unit >= 0xDC00 and unit <= 0xDFFF;
}

// =============================================================================
// Candidate placement
// =============================================================================

/// The IMM forms that place the candidate list for one caret.
pub const Placement = struct {
    composition: COMPOSITIONFORM,
    candidate: CANDIDATEFORM,

    /// Forms for a caret in logical client coordinates. The candidate list
    /// must not cover the caret (`CFS_EXCLUDE`). The hidden composition
    /// window is placed at the caret's bottom-left, because some IMEs place
    /// their candidates relative to it rather than to the candidate form.
    pub fn fromCaret(caret: geometry.RectF, scale_factor: f64) Placement {
        assert(scale_factor > 0);
        assert(caret.size.width >= 0);
        assert(caret.size.height >= 0);
        const area = win32.RECT{
            .left = devicePixels(caret.origin.x, scale_factor),
            .top = devicePixels(caret.origin.y, scale_factor),
            .right = devicePixels(caret.origin.x + caret.size.width, scale_factor),
            .bottom = devicePixels(caret.origin.y + caret.size.height, scale_factor),
        };
        assert(area.left <= area.right);
        assert(area.top <= area.bottom);
        return .{
            .composition = .{
                .dwStyle = CFS_POINT,
                .ptCurrentPos = .{ .x = area.left, .y = area.bottom },
                .rcArea = area,
            },
            .candidate = .{
                .dwIndex = 0,
                .dwStyle = CFS_EXCLUDE,
                .ptCurrentPos = .{ .x = area.left, .y = area.bottom },
                .rcArea = area,
            },
        };
    }
};

/// A logical coordinate in device pixels, saturated to the `i32` range so an
/// off-screen caret cannot overflow the conversion.
fn devicePixels(logical: f32, scale_factor: f64) i32 {
    assert(std.math.isFinite(logical));
    assert(scale_factor > 0);
    const device = @round(@as(f64, logical) * scale_factor);
    return std.math.lossyCast(i32, device);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn testEncode(target: *[bytes_max]u8, units: []const u16) []const u8 {
    return target[0..utf8FromUtf16(target, units)];
}

test "composition flags report result, preedit, and cancellation" {
    const both = Changes.fromLParam(@intCast(GCS_RESULTSTR | GCS_COMPSTR));
    try testing.expect(both.result);
    try testing.expect(both.preedit);
    try testing.expect(!both.cancelled);

    const preedit = Changes.fromLParam(@intCast(GCS_COMPSTR | GCS_CURSORPOS));
    try testing.expect(!preedit.result);
    try testing.expect(preedit.preedit);
    try testing.expect(!preedit.cancelled);

    const korean = Changes.fromLParam(@intCast(GCS_COMPSTR | CS_INSERTCHAR | CS_NOMOVECARET));
    try testing.expect(korean.preedit);
    try testing.expect(!korean.cancelled);

    // Negative space: no flags is a cancellation, not an update.
    const cancelled = Changes.fromLParam(0);
    try testing.expect(!cancelled.result);
    try testing.expect(!cancelled.preedit);
    try testing.expect(cancelled.cancelled);
}

test "every composition flag alone keeps the preedit; anything else cancels" {
    // Methodology: each `GCS_*` bit by itself, such as a cursor or clause
    // move, changes neither string and must not cancel. Then the bits that
    // carry no change (the unassigned 0x0040, the `CS_*` modifiers, and
    // everything above `GCS_RESULTCLAUSE`) each count as no flag at all.
    const flags = [_]u32{
        GCS_COMPREADSTR,      GCS_COMPREADATTR, GCS_COMPREADCLAUSE, GCS_COMPATTR,
        GCS_COMPCLAUSE,       GCS_CURSORPOS,    GCS_DELTASTART,     GCS_RESULTREADSTR,
        GCS_RESULTREADCLAUSE, GCS_RESULTCLAUSE,
    };
    for (flags) |flag| {
        const changes = Changes.fromLParam(@intCast(flag));
        try testing.expect(!changes.cancelled);
        try testing.expect(!changes.result);
        try testing.expect(!changes.preedit);
    }
    const no_change = [_]u32{ 0x0040, CS_INSERTCHAR, CS_NOMOVECARET, 0x8000 };
    for (no_change) |flag| {
        try testing.expect(Changes.fromLParam(@intCast(flag)).cancelled);
    }
}

test "UTF-16 composition text encodes as UTF-8 with U+FFFD for unpaired surrogates" {
    var target: [bytes_max]u8 = undefined;
    const text = "a\u{E9}\u{65E5}\u{672C}\u{1F389}";
    const units = std.unicode.utf8ToUtf16LeStringLiteral(text);
    try testing.expectEqualStrings(text, testEncode(&target, units));
    try testing.expectEqualStrings("", testEncode(&target, &.{}));

    // A lone low half, a high half before a non-surrogate, and a high half at
    // the end each become one U+FFFD; the neighbours survive.
    const ill_formed = [_]u16{ 0xDC00, 'x', 0xD800, 'y', 0xD800 };
    try testing.expectEqualStrings(
        "\u{FFFD}x\u{FFFD}y\u{FFFD}",
        testEncode(&target, &ill_formed),
    );
}

test "a full buffer of the widest units fits the UTF-8 capacity exactly" {
    // Methodology: U+FFFF and an unpaired surrogate each take three UTF-8
    // bytes for one unit, the worst case `bytes_max` is sized for. A buffer
    // of `units_max` of them must fill the target exactly.
    var target: [bytes_max]u8 = undefined;
    var units: [units_max]u16 = undefined;
    for (&units, 0..) |*unit, index| unit.* = if (index % 2 == 0) 0xFFFF else 0xDC00;
    try testing.expectEqual(bytes_max, utf8FromUtf16(&target, &units));

    // A buffer of surrogate pairs takes only two bytes per unit.
    for (&units, 0..) |*unit, index| unit.* = if (index % 2 == 0) 0xD83C else 0xDF89;
    try testing.expectEqual(units_max * 2, utf8FromUtf16(&target, &units));
}

test "placement scales the caret to device pixels and excludes it" {
    const caret = geometry.RectF.init(10, 20, 1.5, 16);
    const placement = Placement.fromCaret(caret, 1.5);
    const area = placement.candidate.rcArea;
    try testing.expectEqual(@as(i32, 15), area.left);
    try testing.expectEqual(@as(i32, 30), area.top);
    try testing.expectEqual(@as(i32, 17), area.right); // 17.25 rounds down.
    try testing.expectEqual(@as(i32, 54), area.bottom);
    try testing.expectEqual(CFS_EXCLUDE, placement.candidate.dwStyle);
    try testing.expectEqual(CFS_POINT, placement.composition.dwStyle);
    try testing.expectEqual(@as(i32, 54), placement.composition.ptCurrentPos.y);

    // An off-screen caret saturates rather than overflowing.
    const far = Placement.fromCaret(geometry.RectF.init(3e9, -3e9, 0, 0), 2.0);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), far.candidate.rcArea.left);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), far.candidate.rcArea.top);
}
