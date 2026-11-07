//! Semantic-analysis smoke check for the vendored D3D11/DXGI binding closure.
//! Run with `zig build-obj -fno-emit-bin -target x86_64-windows-gnu
//! src/platform/windows/win32/mod.zig` from the repo root, or
//! `zig test src/platform/windows/win32/mod.zig --test-no-exec`.
//!
//! This file is a plain (non-test) root so the generated files' own `test`
//! blocks are not executed: the check only needs every `@import` in the
//! closure to resolve.

const d3d11 = @import("graphics/direct3d11.zig");
const dxgi = @import("graphics/dxgi.zig");
const fxc = @import("graphics/direct3d/fxc.zig");
const win32 = @import("mod.zig");

comptime {
    _ = d3d11.D3D11CreateDevice;
    _ = d3d11.ID3D11Device;
    _ = d3d11.ID3D11DeviceContext;
    _ = d3d11.ID3D11Buffer;
    _ = d3d11.ID3D11Texture2D;
    _ = dxgi.CreateDXGIFactory1;
    _ = dxgi.IDXGIFactory2;
    _ = dxgi.IDXGISwapChain1;
    _ = dxgi.DXGI_ERROR_DEVICE_REMOVED;
    _ = fxc.pD3DCompile;
    _ = win32.foundation.HWND;
    _ = win32.ui.windows_and_messaging.CreateWindowExW;
    _ = win32.ui.hi_dpi.GetDpiForWindow;
    _ = win32.system.com.IUnknown;
    _ = win32.zig.Guid;
}
