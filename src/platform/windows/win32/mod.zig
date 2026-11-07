//! Windows API bindings for the Gooey platform layer.
//!
//! This is a curated subset of the generated marlersoft win32-zig package
//! (`win32-25.0.28-preview`, fingerprint `0xb50ba1d115697e99`): only the
//! modules the windowing, input, and D3D11/DXGI paths use are vendored, with
//! their relative imports left intact. See `README.md` for provenance, the file
//! list, and the dependency-exception record.
//!
//! `zig.zig` is the generator's own helper root (`Guid`, `typedConst`,
//! `FAILED`, …), not a Gooey module. The `pub const` block below is a flat
//! re-export map onto the generated namespaces; it contains no hand-written
//! bindings. The few adaptations are type-level only:
//! - Handles are re-exported as optionals because Gooey uses `null` for an
//!   uncreated window, matching the generated functions' `?HWND` returns.
//! - `VK_*` constants are converted from the generated `VIRTUAL_KEY` enum to
//!   integer virtual-key codes, which is how the input translator uses them.
//! - A handful of Win32 SDK numeric constants the generator omits are defined
//!   at the bottom; these are values, not bindings.

pub const foundation = @import("foundation.zig");
pub const security = @import("security.zig");
pub const zig = @import("zig.zig");
pub const wam = @import("ui/windows_and_messaging.zig");
pub const hidpi = @import("ui/hi_dpi.zig");
pub const kbm = @import("ui/input/keyboard_and_mouse.zig");
pub const gdi = @import("graphics/gdi.zig");
pub const dwm = @import("graphics/dwm.zig");
pub const syslib = @import("system/library_loader.zig");
pub const threading = @import("system/threading.zig");

pub const graphics = struct {
    pub const gdi = @import("graphics/gdi.zig");
    pub const dwm = @import("graphics/dwm.zig");
    pub const direct3d = @import("graphics/direct3d.zig");
    pub const direct3d10 = @import("graphics/direct3d10.zig");
    pub const direct3d11 = @import("graphics/direct3d11.zig");
    pub const dxgi = @import("graphics/dxgi.zig");
    pub const dxgi_common = @import("graphics/dxgi/common.zig");
    pub const fxc = @import("graphics/direct3d/fxc.zig");
    pub const dxc = @import("graphics/direct3d/dxc.zig");
};

pub const system = struct {
    pub const com = @import("system/com.zig");
    pub const diagnostics = @import("system/diagnostics.zig");
    pub const kernel = @import("system/kernel.zig");
    pub const library_loader = @import("system/library_loader.zig");
    pub const power = @import("system/power.zig");
    pub const system_information = @import("system/system_information.zig");
    pub const system_services = @import("system/system_services.zig");
    pub const threading = @import("system/threading.zig");
};

pub const ui = struct {
    pub const windows_and_messaging = @import("ui/windows_and_messaging.zig");
    pub const hi_dpi = @import("ui/hi_dpi.zig");
    pub const shell = @import("ui/shell.zig");
    pub const controls = @import("ui/controls.zig");
    pub const text_services = @import("ui/text_services.zig");
    pub const keyboard_and_mouse = @import("ui/input/keyboard_and_mouse.zig");
};

// =============================================================================
// Flat re-exports
// =============================================================================
// The platform files use a flat `win32.*` namespace. Every entry below points
// straight at a generated declaration; no binding is redefined here.

pub const AdjustWindowRectEx = wam.AdjustWindowRectEx;
pub const BeginPaint = gdi.BeginPaint;
pub const BringWindowToTop = wam.BringWindowToTop;
pub const CREATESTRUCTW = wam.CREATESTRUCTW;
pub const CW_USEDEFAULT = wam.CW_USEDEFAULT;
pub const CreateWindowExW = wam.CreateWindowExW;
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = hidpi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2;
pub const DefWindowProcW = wam.DefWindowProcW;
pub const DestroyWindow = wam.DestroyWindow;
pub const DispatchMessageW = wam.DispatchMessageW;
pub const DwmFlush = dwm.DwmFlush;
pub const EndPaint = gdi.EndPaint;
pub const GWLP_USERDATA = wam.GWLP_USERDATA;
pub const GetClientRect = wam.GetClientRect;
pub const GetDpiForSystem = hidpi.GetDpiForSystem;
pub const GetDpiForWindow = hidpi.GetDpiForWindow;
pub const GetKeyState = kbm.GetKeyState;
pub const GetModuleHandleW = syslib.GetModuleHandleW;
pub const GetProcAddress = syslib.GetProcAddress;
pub const GetSystemMetrics = wam.GetSystemMetrics;
pub const GetWindowLongPtrW = wam.GetWindowLongPtrW;
pub const GetWindowRect = wam.GetWindowRect;
pub const HCURSOR = ?wam.HCURSOR;
pub const HINSTANCE = ?foundation.HINSTANCE;
pub const HTCLIENT = wam.HTCLIENT;
pub const HWND = ?foundation.HWND;
pub const IDC_ARROW = wam.IDC_ARROW;
pub const IDC_HAND = wam.IDC_HAND;
pub const IDC_IBEAM = wam.IDC_IBEAM;
pub const KillTimer = wam.KillTimer;
pub const LPARAM = foundation.LPARAM;
pub const LRESULT = foundation.LRESULT;
pub const LoadCursorW = wam.LoadCursorW;
pub const LoadLibraryA = syslib.LoadLibraryA;
pub const MINMAXINFO = wam.MINMAXINFO;
pub const MSG = wam.MSG;
pub const MWMO_INPUTAVAILABLE = wam.MWMO_INPUTAVAILABLE;
pub const MsgWaitForMultipleObjectsEx = wam.MsgWaitForMultipleObjectsEx;
pub const PAINTSTRUCT = gdi.PAINTSTRUCT;
pub const PM_REMOVE = wam.PM_REMOVE;
pub const POINT = foundation.POINT;
pub const PeekMessageW = wam.PeekMessageW;
pub const PostQuitMessage = wam.PostQuitMessage;
pub const QS_ALLINPUT = wam.QS_ALLINPUT;
pub const RECT = foundation.RECT;
pub const RegisterClassExW = wam.RegisterClassExW;
pub const ReleaseCapture = kbm.ReleaseCapture;
pub const SM_CXSCREEN = wam.SM_CXSCREEN;
pub const SM_CYSCREEN = wam.SM_CYSCREEN;
pub const SPI_GETWORKAREA = wam.SPI_GETWORKAREA;
pub const SW_SHOW = wam.SW_SHOW;
pub const S_OK = foundation.S_OK;
pub const ScreenToClient = gdi.ScreenToClient;
pub const SetCapture = kbm.SetCapture;
pub const SetCursor = wam.SetCursor;
pub const SetFocus = kbm.SetFocus;
pub const SetForegroundWindow = wam.SetForegroundWindow;
pub const SetProcessDPIAware = wam.SetProcessDPIAware;
pub const SetProcessDpiAwarenessContext = hidpi.SetProcessDpiAwarenessContext;
pub const SetTimer = wam.SetTimer;
pub const SetWindowLongPtrW = wam.SetWindowLongPtrW;
pub const SetWindowPos = wam.SetWindowPos;
pub const SetWindowTextW = wam.SetWindowTextW;
pub const ShowWindow = wam.ShowWindow;
pub const Sleep = threading.Sleep;
pub const SystemParametersInfoW = wam.SystemParametersInfoW;
pub const TME_LEAVE = kbm.TME_LEAVE;
pub const TRACKMOUSEEVENT = kbm.TRACKMOUSEEVENT;
pub const TrackMouseEvent = kbm.TrackMouseEvent;
pub const TranslateMessage = wam.TranslateMessage;
pub const USER_DEFAULT_SCREEN_DPI = wam.USER_DEFAULT_SCREEN_DPI;
pub const UpdateWindow = gdi.UpdateWindow;
pub const VK_ADD = @backingInt(kbm.VK_ADD);
pub const VK_BACK = @backingInt(kbm.VK_BACK);
pub const VK_CAPITAL = @backingInt(kbm.VK_CAPITAL);
pub const VK_CLEAR = @backingInt(kbm.VK_CLEAR);
pub const VK_CONTROL = @backingInt(kbm.VK_CONTROL);
pub const VK_DECIMAL = @backingInt(kbm.VK_DECIMAL);
pub const VK_DELETE = @backingInt(kbm.VK_DELETE);
pub const VK_DIVIDE = @backingInt(kbm.VK_DIVIDE);
pub const VK_DOWN = @backingInt(kbm.VK_DOWN);
pub const VK_END = @backingInt(kbm.VK_END);
pub const VK_ESCAPE = @backingInt(kbm.VK_ESCAPE);
pub const VK_F1 = @backingInt(kbm.VK_F1);
pub const VK_F24 = @backingInt(kbm.VK_F24);
pub const VK_HOME = @backingInt(kbm.VK_HOME);
pub const VK_LCONTROL = @backingInt(kbm.VK_LCONTROL);
pub const VK_LEFT = @backingInt(kbm.VK_LEFT);
pub const VK_LMENU = @backingInt(kbm.VK_LMENU);
pub const VK_LSHIFT = @backingInt(kbm.VK_LSHIFT);
pub const VK_LWIN = @backingInt(kbm.VK_LWIN);
pub const VK_MENU = @backingInt(kbm.VK_MENU);
pub const VK_MULTIPLY = @backingInt(kbm.VK_MULTIPLY);
pub const VK_NEXT = @backingInt(kbm.VK_NEXT);
pub const VK_NUMPAD0 = @backingInt(kbm.VK_NUMPAD0);
pub const VK_OEM_1 = @backingInt(kbm.VK_OEM_1);
pub const VK_OEM_2 = @backingInt(kbm.VK_OEM_2);
pub const VK_OEM_3 = @backingInt(kbm.VK_OEM_3);
pub const VK_OEM_4 = @backingInt(kbm.VK_OEM_4);
pub const VK_OEM_5 = @backingInt(kbm.VK_OEM_5);
pub const VK_OEM_6 = @backingInt(kbm.VK_OEM_6);
pub const VK_OEM_7 = @backingInt(kbm.VK_OEM_7);
pub const VK_OEM_COMMA = @backingInt(kbm.VK_OEM_COMMA);
pub const VK_OEM_MINUS = @backingInt(kbm.VK_OEM_MINUS);
pub const VK_OEM_PERIOD = @backingInt(kbm.VK_OEM_PERIOD);
pub const VK_OEM_PLUS = @backingInt(kbm.VK_OEM_PLUS);
pub const VK_PRIOR = @backingInt(kbm.VK_PRIOR);
pub const VK_RCONTROL = @backingInt(kbm.VK_RCONTROL);
pub const VK_RETURN = @backingInt(kbm.VK_RETURN);
pub const VK_RIGHT = @backingInt(kbm.VK_RIGHT);
pub const VK_RMENU = @backingInt(kbm.VK_RMENU);
pub const VK_RSHIFT = @backingInt(kbm.VK_RSHIFT);
pub const VK_RWIN = @backingInt(kbm.VK_RWIN);
pub const VK_SHIFT = @backingInt(kbm.VK_SHIFT);
pub const VK_SNAPSHOT = @backingInt(kbm.VK_SNAPSHOT);
pub const VK_SPACE = @backingInt(kbm.VK_SPACE);
pub const VK_SUBTRACT = @backingInt(kbm.VK_SUBTRACT);
pub const VK_TAB = @backingInt(kbm.VK_TAB);
pub const VK_UP = @backingInt(kbm.VK_UP);
pub const WM_CHAR = wam.WM_CHAR;
pub const WM_CLOSE = wam.WM_CLOSE;
pub const WM_DESTROY = wam.WM_DESTROY;
pub const WM_DPICHANGED = wam.WM_DPICHANGED;
pub const WM_ERASEBKGND = wam.WM_ERASEBKGND;
pub const WM_GETMINMAXINFO = wam.WM_GETMINMAXINFO;
pub const WM_KEYDOWN = wam.WM_KEYDOWN;
pub const WM_KEYUP = wam.WM_KEYUP;
pub const WM_KILLFOCUS = wam.WM_KILLFOCUS;
pub const WM_LBUTTONDOWN = wam.WM_LBUTTONDOWN;
pub const WM_LBUTTONUP = wam.WM_LBUTTONUP;
pub const WM_MBUTTONDOWN = wam.WM_MBUTTONDOWN;
pub const WM_MBUTTONUP = wam.WM_MBUTTONUP;
pub const WM_MOUSEHWHEEL = wam.WM_MOUSEHWHEEL;
pub const WM_MOUSEMOVE = wam.WM_MOUSEMOVE;
pub const WM_MOUSEWHEEL = wam.WM_MOUSEWHEEL;
pub const WM_NCCREATE = wam.WM_NCCREATE;
pub const WM_PAINT = wam.WM_PAINT;
pub const WM_QUIT = wam.WM_QUIT;
pub const WM_RBUTTONDOWN = wam.WM_RBUTTONDOWN;
pub const WM_RBUTTONUP = wam.WM_RBUTTONUP;
pub const WM_SETCURSOR = wam.WM_SETCURSOR;
pub const WM_SETFOCUS = wam.WM_SETFOCUS;
pub const WM_SIZE = wam.WM_SIZE;
pub const WM_SYSKEYDOWN = wam.WM_SYSKEYDOWN;
pub const WM_SYSKEYUP = wam.WM_SYSKEYUP;
pub const WM_TIMER = wam.WM_TIMER;
pub const WNDCLASSEXW = wam.WNDCLASSEXW;
pub const WPARAM = foundation.WPARAM;
pub const WS_EX_APPWINDOW = wam.WS_EX_APPWINDOW;
pub const WS_OVERLAPPEDWINDOW = wam.WS_OVERLAPPEDWINDOW;

// Win32 SDK constants the generator does not emit (it exposes typed flag
// structs and named messages instead). These are plain numeric values, not
// bindings.
pub const UINT = u32;
pub const INFINITE: u32 = 0xFFFFFFFF;
pub const MK_CONTROL: u32 = 0x0008;
pub const MK_SHIFT: u32 = 0x0004;
pub const WM_MOUSELEAVE: u32 = 0x02A3;
pub const TIMER_RENDER_ID: usize = 1;

test {
    @import("std").testing.refAllDecls(@This());
}
