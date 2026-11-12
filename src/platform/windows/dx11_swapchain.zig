//! The flip-model swapchain the DirectX 11 renderer presents a window through.
//!
//! `DXGI_SWAP_EFFECT_FLIP_DISCARD` hands each back buffer to DWM without a
//! copy, which is what lets a windowed app present at the display's rate with
//! the latency of an exclusive one. The swapchain holds one back buffer per
//! frame in flight (`ResourceLimits.frame.in_flight_count`), and its frame
//! latency waitable limits the frames queued ahead of the display to one fewer
//! than that, so the render thread blocks before building a frame the display
//! cannot take yet instead of inside `Present`.
//!
//! Memory (CLAUDE.md §2 and §7): the back buffers are driver memory, sized to
//! the client area, which `Window` keeps within `ResourceLimits.window`
//! (`WM_GETMINMAXINFO`). At `.standard` the worst case is 3 × 3840 × 2400 × 4 B
//! = 105 MiB of video memory at full size; the extent follows the window.
//! `resize` replaces them through `ResizeBuffers`, as the Vulkan renderer
//! replaces its swapchain, and Gooey holds no storage for them besides one
//! render target view.

const std = @import("std");
const d3d11 = @import("d3d11.zig");
const win32 = @import("win32.zig");
const dx11_device = @import("dx11_device.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.dx11);
const hex = dx11_device.hex;

/// DXGI's flip model takes between 2 and 16 back buffers.
pub const buffer_count_min: u32 = 2;
pub const buffer_count_max: u32 = 16;

/// Longest the render thread waits for the display to take a frame. A
/// display that has not taken one in a second has stopped (the session is
/// locked, or the monitor slept); the frame is drawn anyway rather than the
/// thread hanging, and `Present` then blocks or reports occlusion.
const frame_wait_ms_max: u32 = 1_000;

/// The swapchain's format: 8-bit BGRA, which every flip-model swapchain and
/// every WARP and hardware device accept. UNORM, not sRGB: packed colours are
/// sRGB-encoded and blended in gamma space (contract §9), like the Vulkan
/// renderer's `B8G8R8A8_UNORM`, so the hardware must not encode them again.
pub const format: u32 = d3d11.DXGI_FORMAT_B8G8R8A8_UNORM;

/// The latency waitable must be requested at creation and again on every
/// `ResizeBuffers`, or the call fails.
const swapchain_flags: u32 = d3d11.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

pub const PresentResult = enum {
    /// Queued for the display.
    presented,
    /// The window is fully covered; nothing was shown, and the next frame
    /// may still be.
    occluded,
    /// The GPU was removed or reset; only a new device draws again.
    device_lost,
};

pub const Swapchain = struct {
    swapchain: *d3d11.IDXGISwapChain2,
    latency_waitable: d3d11.HANDLE,
    /// View of back buffer 0. With the flip model the runtime rotates the
    /// buffers behind it, so one view serves every frame. Null after a
    /// failed `resize`, until one succeeds.
    target_view: ?*d3d11.ID3D11RenderTargetView,
    width_px: u32,
    height_px: u32,
    buffer_count: u32,

    pub const CreateError = error{Dx11SwapchainUnavailable};

    pub const Options = struct {
        width_px: u32,
        height_px: u32,
        buffer_count: u32,
    };

    pub fn create(
        device: *const dx11_device.Device,
        hwnd: win32.HWND,
        options: Options,
    ) CreateError!Swapchain {
        assert(options.width_px > 0);
        assert(options.height_px > 0);
        assert(options.buffer_count >= buffer_count_min);
        assert(options.buffer_count <= buffer_count_max);
        const factory = device.factory() orelse return error.Dx11SwapchainUnavailable;
        defer factory.release();

        const swapchain = createForWindow(device, factory, hwnd, &options) orelse
            return error.Dx11SwapchainUnavailable;
        errdefer swapchain.release();

        // The latency must be set before the waitable is first used: the
        // default of 1 would leave a frame in flight idle at `.standard`.
        const latency = options.buffer_count - 1;
        const latency_result = swapchain.vtable.SetMaximumFrameLatency(swapchain, latency);
        if (!d3d11.succeeded(latency_result)) {
            log.err("SetMaximumFrameLatency({d}) failed: 0x{X:0>8}", .{
                latency,
                hex(latency_result),
            });
            return error.Dx11SwapchainUnavailable;
        }
        const waitable = swapchain.vtable.GetFrameLatencyWaitableObject(swapchain) orelse {
            log.err("GetFrameLatencyWaitableObject returned no handle", .{});
            return error.Dx11SwapchainUnavailable;
        };
        errdefer _ = win32.CloseHandle(waitable);

        const view = createTargetView(device, swapchain) orelse
            return error.Dx11SwapchainUnavailable;
        return .{
            .swapchain = swapchain,
            .latency_waitable = waitable,
            .target_view = view,
            .width_px = options.width_px,
            .height_px = options.height_px,
            .buffer_count = options.buffer_count,
        };
    }

    pub fn release(self: *Swapchain) void {
        assert(self.buffer_count >= buffer_count_min);
        if (self.target_view) |view| view.release();
        _ = win32.CloseHandle(self.latency_waitable);
        self.swapchain.release();
        self.* = undefined;
    }

    /// Whether the swapchain holds a render target; a failed `resize` leaves
    /// none until a later one succeeds.
    pub fn usable(self: *const Swapchain) bool {
        assert(self.width_px > 0);
        return self.target_view != null;
    }

    /// Resize the back buffers to the client area. Every view of them must be
    /// released first, and the context must not still bind one. Returns
    /// whether the swapchain is usable afterwards.
    pub fn resize(
        self: *Swapchain,
        device: *const dx11_device.Device,
        width_px: u32,
        height_px: u32,
    ) bool {
        assert(width_px > 0);
        assert(height_px > 0);
        if (self.target_view) |view| view.release();
        self.target_view = null;
        device.context.vtable.OMSetRenderTargets(device.context, 0, null, null);
        // Releases the runtime's deferred references to the old buffers.
        device.context.vtable.Flush(device.context);

        const result = self.swapchain.vtable.ResizeBuffers(
            self.swapchain,
            self.buffer_count,
            width_px,
            height_px,
            format,
            swapchain_flags,
        );
        if (!d3d11.succeeded(result)) {
            log.err("ResizeBuffers({d}x{d}) failed: 0x{X:0>8}", .{
                width_px,
                height_px,
                hex(result),
            });
            return false;
        }
        self.width_px = width_px;
        self.height_px = height_px;
        self.target_view = createTargetView(device, self.swapchain);
        return self.target_view != null;
    }

    /// Block until the display can take another frame, so the frame is built
    /// as late as possible and `Present` does not block.
    pub fn waitForFrame(self: *const Swapchain) void {
        assert(self.buffer_count >= buffer_count_min);
        const handles = [_]win32.HANDLE{self.latency_waitable};
        const result = win32.WaitForMultipleObjects(1, &handles, win32.FALSE, frame_wait_ms_max);
        if (result == win32.WAIT_OBJECT_0) return;
        if (result == win32.WAIT_TIMEOUT) {
            log.warn("display took no frame for {d} ms; drawing anyway", .{frame_wait_ms_max});
            return;
        }
        log.err("waiting on the frame latency object failed (error {d})", .{
            win32.GetLastError(),
        });
    }

    /// Queue the frame for the next vertical blank.
    pub fn present(self: *const Swapchain) PresentResult {
        assert(self.target_view != null);
        const result = self.swapchain.vtable.Present(self.swapchain, 1, 0);
        if (result == d3d11.DXGI_STATUS_OCCLUDED) return .occluded;
        if (d3d11.succeeded(result)) return .presented;
        if (d3d11.deviceLost(result)) return .device_lost;
        // Every other failure is an invalid call: a Gooey bug.
        std.debug.panic("IDXGISwapChain::Present failed: 0x{X:0>8}", .{hex(result)});
    }
};

fn createForWindow(
    device: *const dx11_device.Device,
    factory: *d3d11.IDXGIFactory2,
    hwnd: win32.HWND,
    options: *const Swapchain.Options,
) ?*d3d11.IDXGISwapChain2 {
    assert(options.buffer_count >= buffer_count_min);
    const desc = d3d11.DXGI_SWAP_CHAIN_DESC1{
        .Width = options.width_px,
        .Height = options.height_px,
        .Format = format,
        .Stereo = win32.FALSE,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = d3d11.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = options.buffer_count,
        // The swapchain always matches the client area, so nothing scales;
        // `NONE` also keeps DWM from stretching a stale frame during resize.
        .Scaling = d3d11.DXGI_SCALING_NONE,
        .SwapEffect = d3d11.DXGI_SWAP_EFFECT_FLIP_DISCARD,
        .AlphaMode = d3d11.DXGI_ALPHA_MODE_IGNORE,
        .Flags = swapchain_flags,
    };
    var swapchain1: ?*d3d11.IDXGISwapChain2 = null;
    const result = factory.vtable.CreateSwapChainForHwnd(
        factory,
        device.device,
        hwnd,
        &desc,
        null,
        null,
        &swapchain1,
    );
    if (!d3d11.succeeded(result)) {
        log.err("CreateSwapChainForHwnd failed: 0x{X:0>8}", .{hex(result)});
        return null;
    }
    // Only the `IDXGISwapChain1` prefix of the vtable is valid until the
    // query below returns the full interface.
    const base = swapchain1.?;
    defer base.release();

    const association = factory.vtable.MakeWindowAssociation(
        factory,
        hwnd,
        d3d11.DXGI_MWA_NO_ALT_ENTER,
    );
    if (!d3d11.succeeded(association)) {
        log.warn("MakeWindowAssociation failed: 0x{X:0>8}", .{hex(association)});
    }

    var swapchain2: ?*anyopaque = null;
    const query = base.vtable.QueryInterface(base, &d3d11.IID_IDXGISwapChain2, &swapchain2);
    if (!d3d11.succeeded(query)) {
        // DXGI 1.3 is part of Windows 8.1, below Gooey's floor.
        log.err("IDXGISwapChain2 unavailable: 0x{X:0>8}", .{hex(query)});
        return null;
    }
    return @ptrCast(@alignCast(swapchain2.?));
}

fn createTargetView(
    device: *const dx11_device.Device,
    swapchain: *d3d11.IDXGISwapChain2,
) ?*d3d11.ID3D11RenderTargetView {
    var buffer_raw: ?*anyopaque = null;
    const texture_iid = &d3d11.IID_ID3D11Texture2D;
    const result = swapchain.vtable.GetBuffer(swapchain, 0, texture_iid, &buffer_raw);
    if (!d3d11.succeeded(result)) {
        log.err("IDXGISwapChain::GetBuffer failed: 0x{X:0>8}", .{hex(result)});
        return null;
    }
    const buffer: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(buffer_raw.?));
    defer buffer.release();

    var view: ?*d3d11.ID3D11RenderTargetView = null;
    const view_result = device.device.vtable.CreateRenderTargetView(
        device.device,
        buffer.resource(),
        null,
        &view,
    );
    if (!d3d11.succeeded(view_result)) {
        log.err("CreateRenderTargetView(back buffer) failed: 0x{X:0>8}", .{hex(view_result)});
        return null;
    }
    assert(view != null);
    return view;
}
