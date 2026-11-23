const std = @import("std");
const d3d11 = @import("d3d11.zig");
const win32 = @import("win32.zig");
const dx11_device = @import("dx11_device.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.dx11);
const hex = dx11_device.hex;

pub const buffer_count_min: u32 = 2;
pub const buffer_count_max: u32 = 16;

const frame_wait_ms_max: u32 = 1_000;

pub const format: u32 = d3d11.DXGI_FORMAT_B8G8R8A8_UNORM;

const swapchain_flags: u32 = d3d11.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

pub const PresentResult = enum {
    presented,
    occluded,
    device_lost,
};

pub const Swapchain = struct {
    swapchain: *d3d11.IDXGISwapChain2,
    latency_waitable: d3d11.HANDLE,
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

    pub fn usable(self: *const Swapchain) bool {
        assert(self.width_px > 0);
        return self.target_view != null;
    }

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

    pub fn present(self: *const Swapchain) PresentResult {
        assert(self.target_view != null);
        const result = self.swapchain.vtable.Present(self.swapchain, 1, 0);
        if (result == d3d11.DXGI_STATUS_OCCLUDED) return .occluded;
        if (d3d11.succeeded(result)) return .presented;
        if (d3d11.deviceLost(result)) return .device_lost;
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
