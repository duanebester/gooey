//! The Direct3D 11 device behind the DirectX 11 renderer, with a WARP fallback.
//!
//! `create` asks for a hardware device at feature level 11_1 or 11_0 and, when
//! no driver provides one (a VM without GPU passthrough, a Remote Desktop
//! session, a machine with only a basic display driver), falls back to WARP,
//! Microsoft's software rasterizer that ships with every supported Windows
//! release. Feature level 11_0 is the floor because the shaders read instance
//! data from structured buffers in the vertex stage, a shader model 5 feature.
//!
//! The device and its immediate context are created on the main thread during
//! window initialization, then owned by the render thread once the core host
//! binds the window, so they are never used from two threads at once. The
//! device is not created single-threaded because creation and use happen on
//! different threads, which `D3D11_CREATE_DEVICE_SINGLETHREADED` forbids.

const std = @import("std");
const d3d11 = @import("d3d11.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.dx11);

/// Which devices `create` may return.
pub const DriverPreference = enum {
    /// A hardware device, or WARP when none can be created.
    hardware_then_warp,
    /// WARP only: deterministic output on every machine, for tests.
    warp,
};

/// The kind of device `create` returned.
pub const Driver = enum { hardware, warp };

pub const Device = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
    driver: Driver,
    feature_level: u32,

    pub const CreateError = error{Dx11DeviceUnavailable};

    /// Feature levels requested, best first. 11_1 adds nothing the renderer
    /// needs but lets the runtime pick the newer level where it exists.
    const feature_levels = [_]u32{ d3d11.D3D_FEATURE_LEVEL_11_1, d3d11.D3D_FEATURE_LEVEL_11_0 };

    pub fn create(preference: DriverPreference) CreateError!Device {
        if (preference == .hardware_then_warp) {
            if (createDriver(.hardware)) |device| return device;
            log.warn("no hardware Direct3D 11 device at feature level 11_0; using WARP", .{});
        }
        const device = createDriver(.warp) orelse return error.Dx11DeviceUnavailable;
        assert(device.driver == .warp);
        return device;
    }

    pub fn release(self: *Device) void {
        assert(self.feature_level >= d3d11.D3D_FEATURE_LEVEL_11_0);
        // Unbinds everything, so no view or buffer outlives the device in
        // the context's state.
        self.context.vtable.ClearState(self.context);
        self.context.vtable.Flush(self.context);
        self.context.release();
        self.device.release();
        self.* = undefined;
    }

    /// The DXGI factory that created the device's adapter. A swapchain must
    /// come from it, or `CreateSwapChainForHwnd` rejects the device. The
    /// caller releases the factory.
    pub fn factory(self: *const Device) ?*d3d11.IDXGIFactory2 {
        assert(self.feature_level >= d3d11.D3D_FEATURE_LEVEL_11_0);
        const adapter = self.queryAdapter() orelse return null;
        defer adapter.release();

        var factory_raw: ?*anyopaque = null;
        const result = adapter.vtable.GetParent(adapter, &d3d11.IID_IDXGIFactory2, &factory_raw);
        if (!d3d11.succeeded(result)) {
            log.err("IDXGIAdapter::GetParent(IDXGIFactory2) failed: 0x{X:0>8}", .{hex(result)});
            return null;
        }
        assert(factory_raw != null);
        return @ptrCast(@alignCast(factory_raw.?));
    }

    /// The device's adapter; the caller releases it.
    fn queryAdapter(self: *const Device) ?*d3d11.IDXGIAdapter {
        var dxgi_raw: ?*anyopaque = null;
        const query = self.device.vtable.QueryInterface(
            self.device,
            &d3d11.IID_IDXGIDevice,
            &dxgi_raw,
        );
        if (!d3d11.succeeded(query)) {
            log.err("ID3D11Device::QueryInterface(IDXGIDevice) failed: 0x{X:0>8}", .{hex(query)});
            return null;
        }
        const dxgi_device: *d3d11.IDXGIDevice = @ptrCast(@alignCast(dxgi_raw.?));
        defer dxgi_device.release();

        var result_adapter: ?*d3d11.IDXGIAdapter = null;
        const result = dxgi_device.vtable.GetAdapter(dxgi_device, &result_adapter);
        if (!d3d11.succeeded(result)) {
            log.err("IDXGIDevice::GetAdapter failed: 0x{X:0>8}", .{hex(result)});
            return null;
        }
        assert(result_adapter != null);
        return result_adapter;
    }

    /// Log the adapter's name and memory once, so a report shows which GPU
    /// (or WARP) drew the frames.
    pub fn logAdapter(self: *const Device) void {
        const device_adapter = self.queryAdapter() orelse return;
        defer device_adapter.release();

        var desc: d3d11.DXGI_ADAPTER_DESC = undefined;
        if (!d3d11.succeeded(device_adapter.vtable.GetDesc(device_adapter, &desc))) return;
        const name_units = std.mem.indexOfScalar(u16, &desc.Description, 0) orelse
            desc.Description.len;
        log.info("Direct3D 11 {s} device, feature level {X}: {f} ({d} MiB dedicated)", .{
            @tagName(self.driver),
            self.feature_level,
            std.unicode.fmtUtf16Le(desc.Description[0..name_units]),
            desc.DedicatedVideoMemory >> 20,
        });
    }
};

fn createDriver(driver: Driver) ?Device {
    const driver_type = switch (driver) {
        .hardware => d3d11.D3D_DRIVER_TYPE_HARDWARE,
        .warp => d3d11.D3D_DRIVER_TYPE_WARP,
    };
    var device: ?*d3d11.ID3D11Device = null;
    var context: ?*d3d11.ID3D11DeviceContext = null;
    var feature_level: u32 = 0;
    const result = d3d11.D3D11CreateDevice(
        null,
        driver_type,
        null,
        d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        &Device.feature_levels,
        Device.feature_levels.len,
        d3d11.D3D11_SDK_VERSION,
        &device,
        &feature_level,
        &context,
    );
    if (!d3d11.succeeded(result)) {
        log.info("D3D11CreateDevice({s}) failed: 0x{X:0>8}", .{ @tagName(driver), hex(result) });
        return null;
    }
    assert(device != null);
    assert(context != null);
    // The runtime returns only a requested level.
    assert(feature_level >= d3d11.D3D_FEATURE_LEVEL_11_0);
    return .{
        .device = device.?,
        .context = context.?,
        .driver = driver,
        .feature_level = feature_level,
    };
}

/// An `HRESULT` as the unsigned value Microsoft's documentation lists.
pub fn hex(result: d3d11.HRESULT) u32 {
    return @bitCast(result);
}
