//! Hand-written Win32 bindings for the Windows backend.
//!
//! Only the subset of `kernel32` and `user32` the backend calls. Declared by
//! hand for the same reasons as `linux/vulkan.zig`: there are no C headers to
//! import, Gooey takes no package dependencies (CLAUDE.md §12), and the tree
//! type-checks from any host. Win32 never changes the layout of a released
//! struct or the value of a released constant, so the declarations below stay
//! correct once they match the SDK headers. The comptime block at the end pins
//! the 64-bit layouts so an edit cannot drift.
//!
//! Naming follows the SDK (`CreateWindowExW`, `WM_SIZE`) rather than Gooey's
//! style, so each declaration can be checked against Microsoft's documentation
//! by searching for its exact name.

const std = @import("std");
const assert = std.debug.assert;

// =============================================================================
// Scalar and handle types
// =============================================================================

pub const BOOL = i32;
pub const ATOM = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LPCWSTR = [*:0]const u16;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const HINSTANCE = *opaque {};
pub const HWND = *opaque {};
pub const HCURSOR = *opaque {};
pub const HICON = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};

pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

// =============================================================================
// Structures
// =============================================================================

pub const POINT = extern struct {
    x: i32,
    y: i32,
};

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: u32,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32,
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32,
};

// =============================================================================
// Constants
// =============================================================================

// Window class styles.
pub const CS_VREDRAW: u32 = 0x0001;
pub const CS_HREDRAW: u32 = 0x0002;
pub const CS_OWNDC: u32 = 0x0020;

// Window styles.
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF_0000;
pub const WS_EX_APPWINDOW: u32 = 0x0004_0000;
pub const CW_USEDEFAULT: i32 = std.math.minInt(i32);

// `ShowWindow` commands.
pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;

// `SetWindowPos` flags.
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;

// `GetWindowLongPtrW` indices.
pub const GWLP_USERDATA: i32 = -21;

// `PeekMessageW` and `MsgWaitForMultipleObjectsEx`.
pub const PM_REMOVE: u32 = 0x0001;
pub const QS_ALLINPUT: u32 = 0x04FF;
pub const MWMO_INPUTAVAILABLE: u32 = 0x0004;
pub const WAIT_FAILED: u32 = 0xFFFF_FFFF;

// `WM_SIZE` request types.
pub const SIZE_MINIMIZED: usize = 1;

// `WM_SETCURSOR` hit-test code for the client area.
pub const HTCLIENT: u16 = 1;

// `TrackMouseEvent` flags.
pub const TME_LEAVE: u32 = 0x0002;

// Stock cursors, passed to `LoadCursorW` as `MAKEINTRESOURCE` ordinals.
pub const IDC_ARROW: u16 = 32512;
pub const IDC_IBEAM: u16 = 32513;
pub const IDC_HAND: u16 = 32649;

// `SetProcessDpiAwarenessContext`. The context is a pseudo-handle: a small
// negative integer in a pointer-sized slot.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
pub const USER_DEFAULT_SCREEN_DPI: u32 = 96;

// `SystemParametersInfoW` actions.
pub const SPI_GETWORKAREA: u32 = 0x0030;

// `GetSystemMetrics` indices.
pub const SM_CXDOUBLECLK: i32 = 36;
pub const SM_CYDOUBLECLK: i32 = 37;

// One detent of a standard mouse wheel.
pub const WHEEL_DELTA: i32 = 120;

// Window messages.
pub const WM_CREATE: u32 = 0x0001;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_SETFOCUS: u32 = 0x0007;
pub const WM_KILLFOCUS: u32 = 0x0008;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_SETCURSOR: u32 = 0x0020;
pub const WM_GETMINMAXINFO: u32 = 0x0024;
pub const WM_NCCREATE: u32 = 0x0081;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_SYSKEYDOWN: u32 = 0x0104;
pub const WM_SYSKEYUP: u32 = 0x0105;
pub const WM_SYSCHAR: u32 = 0x0106;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_MBUTTONDOWN: u32 = 0x0207;
pub const WM_MBUTTONUP: u32 = 0x0208;
pub const WM_MOUSEWHEEL: u32 = 0x020A;
pub const WM_MOUSEHWHEEL: u32 = 0x020E;
pub const WM_MOUSELEAVE: u32 = 0x02A3;
pub const WM_DPICHANGED: u32 = 0x02E0;

// Virtual-key codes read through `GetKeyState`. The full translation table
// lives in `input.zig`.
pub const VK_SHIFT: i32 = 0x10;
pub const VK_CONTROL: i32 = 0x11;
pub const VK_MENU: i32 = 0x12;
pub const VK_LWIN: i32 = 0x5B;
pub const VK_RWIN: i32 = 0x5C;

// =============================================================================
// Functions
// =============================================================================

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(
    lpClassName: LPCWSTR,
    hInstance: HINSTANCE,
) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: u32,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(
    hWnd: HWND,
    Msg: u32,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: ?HWND,
    X: i32,
    Y: i32,
    cx: i32,
    cy: i32,
    uFlags: u32,
) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(
    hWnd: HWND,
    nIndex: i32,
    dwNewLong: isize,
) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;

pub extern "user32" fn PeekMessageW(
    lpMsg: *MSG,
    hWnd: ?HWND,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
    wRemoveMsg: u32,
) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    nCount: u32,
    pHandles: ?*const anyopaque,
    dwMilliseconds: u32,
    dwWakeMask: u32,
    dwFlags: u32,
) callconv(.winapi) u32;
pub extern "user32" fn GetMessageTime() callconv(.winapi) i32;

pub extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;
pub extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
pub extern "user32" fn AdjustWindowRectExForDpi(
    lpRect: *RECT,
    dwStyle: u32,
    bMenu: BOOL,
    dwExStyle: u32,
    dpi: u32,
) callconv(.winapi) BOOL;
pub extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.winapi) i32;
pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;

pub extern "user32" fn LoadCursorW(
    hInstance: ?HINSTANCE,
    lpCursorName: usize,
) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetCursor(hCursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;

// =============================================================================
// Parameter decoding
// =============================================================================

/// `LOWORD`: bits 0..15 of a message parameter.
pub fn loWord(value: usize) u16 {
    return @truncate(value);
}

/// `HIWORD`: bits 16..31 of a message parameter.
pub fn hiWord(value: usize) u16 {
    return @truncate(value >> 16);
}

/// `GET_X_LPARAM`: the signed client x coordinate. Signed because a captured
/// pointer outside the client area reports negative coordinates.
pub fn xFromLParam(lparam: LPARAM) i16 {
    return @bitCast(loWord(@bitCast(lparam)));
}

/// `GET_Y_LPARAM`: the signed client y coordinate.
pub fn yFromLParam(lparam: LPARAM) i16 {
    return @bitCast(hiWord(@bitCast(lparam)));
}

/// `GET_WHEEL_DELTA_WPARAM`: signed wheel rotation in `WHEEL_DELTA` units.
pub fn wheelDeltaFromWParam(wparam: WPARAM) i16 {
    return @bitCast(hiWord(wparam));
}

/// Whether `GetKeyState` reports the key as held: the high bit of the result.
pub fn isKeyDown(virtual_key: i32) bool {
    assert(virtual_key > 0);
    assert(virtual_key <= 0xFF);
    return GetKeyState(virtual_key) < 0;
}

comptime {
    // `x86_64-windows` only; see `docs/windows-port.md`. Every layout below
    // and every handle in `linux/vulkan.zig` assumes 64-bit pointers.
    assert(@sizeOf(usize) == 8);

    assert(@sizeOf(POINT) == 8);
    assert(@sizeOf(RECT) == 16);
    assert(@sizeOf(MSG) == 48);
    assert(@offsetOf(MSG, "pt") == 36);
    assert(@sizeOf(WNDCLASSEXW) == 80);
    assert(@offsetOf(WNDCLASSEXW, "lpszClassName") == 64);
    assert(@sizeOf(CREATESTRUCTW) == 80);
    assert(@offsetOf(CREATESTRUCTW, "dwExStyle") == 72);
    assert(@sizeOf(MINMAXINFO) == 40);
    assert(@sizeOf(TRACKMOUSEEVENT) == 24);
}

test "message parameter decoding keeps the sign of client coordinates" {
    // Methodology: pack the two 16-bit halves the way `MAKELPARAM` does and
    // check the boundary values, including coordinates left of and above the
    // client origin that a captured pointer reports.
    const negative: LPARAM = @bitCast(@as(usize, 0xFFFE_FFFF));
    try std.testing.expectEqual(@as(i16, -1), xFromLParam(negative));
    try std.testing.expectEqual(@as(i16, -2), yFromLParam(negative));

    const positive: LPARAM = (@as(LPARAM, 600) << 16) | 800;
    try std.testing.expectEqual(@as(i16, 800), xFromLParam(positive));
    try std.testing.expectEqual(@as(i16, 600), yFromLParam(positive));

    const wheel_down: WPARAM = @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16;
    try std.testing.expectEqual(@as(i16, -120), wheelDeltaFromWParam(wheel_down));
}
