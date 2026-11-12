//! Hand-written Direct3D 11 and DXGI bindings for the DirectX 11 renderer.
//!
//! Only the subset of `d3d11.dll` and `dxgi.dll` the renderer calls, declared
//! by hand for the same reasons as the WIC, DirectWrite, and UI Automation
//! bindings: Gooey takes no package dependencies (CLAUDE.md §12), and the tree
//! type-checks from any host. The import libraries come from the MinGW
//! definitions Zig bundles, so no Windows SDK is needed to link.
//!
//! Both APIs are COM. A method is found by its slot index alone, so each
//! vtable the renderer calls through lists every slot of its interface up to
//! the last one, in the order of `d3d11.h`, `dxgi.h`, `dxgi1_2.h`, and
//! `dxgi1_3.h`; slots the renderer never calls are typed `Slot`. The comptime
//! block at the end pins the slot of every called method and the size of
//! every complete vtable, so a missing or extra slot fails to compile.
//! Interfaces the renderer only creates, binds, and releases (views, shaders,
//! and state objects) declare only the three `IUnknown` slots, which every
//! COM vtable begins with; their pointers are never dereferenced past them.
//!
//! Released COM vtables and structures never change, so the declarations stay
//! correct once they match the headers. Names follow the SDK so each one can
//! be checked against Microsoft's documentation by name.

const std = @import("std");
const win32 = @import("win32.zig");
const assert = std.debug.assert;

// =============================================================================
// Scalar types and results
// =============================================================================

pub const HRESULT = i32;
pub const BOOL = win32.BOOL;
pub const HANDLE = win32.HANDLE;
pub const HWND = win32.HWND;

pub const S_OK: HRESULT = 0;
/// `Present`: the window is fully occluded; nothing was shown.
pub const DXGI_STATUS_OCCLUDED: HRESULT = 0x087A_0001;
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A_0005));
pub const DXGI_ERROR_DEVICE_HUNG: HRESULT = @bitCast(@as(u32, 0x887A_0006));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A_0007));
pub const DXGI_ERROR_UNSUPPORTED: HRESULT = @bitCast(@as(u32, 0x887A_0004));

/// `SUCCEEDED`: every non-negative `HRESULT` reports success.
pub fn succeeded(result: HRESULT) bool {
    return result >= 0;
}

/// Whether `result` reports a lost device, which only a new device recovers.
pub fn deviceLost(result: HRESULT) bool {
    if (result == DXGI_ERROR_DEVICE_REMOVED) return true;
    if (result == DXGI_ERROR_DEVICE_RESET) return true;
    return result == DXGI_ERROR_DEVICE_HUNG;
}

/// A vtable slot the renderer never calls. It only holds its place.
pub const Slot = *const anyopaque;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

// =============================================================================
// Interface identifiers
// =============================================================================

pub const IID_IDXGIDevice: GUID = .{
    .data1 = 0x54EC_77FA,
    .data2 = 0x1377,
    .data3 = 0x44E6,
    .data4 = .{ 0x8C, 0x32, 0x88, 0xFD, 0x5F, 0x44, 0xC8, 0x4C },
};

pub const IID_IDXGIFactory2: GUID = .{
    .data1 = 0x50C8_3A1C,
    .data2 = 0xE072,
    .data3 = 0x4C48,
    .data4 = .{ 0x87, 0xB0, 0x36, 0x30, 0xFA, 0x36, 0xA6, 0xD0 },
};

pub const IID_IDXGISwapChain2: GUID = .{
    .data1 = 0xA8BE_2AC4,
    .data2 = 0x199F,
    .data3 = 0x4946,
    .data4 = .{ 0xB3, 0x31, 0x79, 0x59, 0x9F, 0xB9, 0x8D, 0xE7 },
};

pub const IID_ID3D11Texture2D: GUID = .{
    .data1 = 0x6F15_AAF2,
    .data2 = 0xD208,
    .data3 = 0x4E89,
    .data4 = .{ 0x9A, 0xB4, 0x48, 0x95, 0x35, 0xD3, 0x4F, 0x9C },
};

// =============================================================================
// Enumerations and flags (C enums: 32 bits)
// =============================================================================

pub const D3D11_SDK_VERSION: u32 = 7;

pub const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
/// The Windows Advanced Rasterization Platform: Microsoft's software device,
/// present on every Windows release Gooey supports (VMs, RDP, no driver).
pub const D3D_DRIVER_TYPE_WARP: u32 = 5;

pub const D3D_FEATURE_LEVEL_11_0: u32 = 0xB000;
pub const D3D_FEATURE_LEVEL_11_1: u32 = 0xB100;

pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;

pub const DXGI_FORMAT_UNKNOWN: u32 = 0;
pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const DXGI_FORMAT_R32_UINT: u32 = 42;
pub const DXGI_FORMAT_R8_UNORM: u32 = 61;
pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;

pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SCALING_NONE: u32 = 1;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
pub const DXGI_ALPHA_MODE_IGNORE: u32 = 3;
pub const DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: u32 = 64;
/// `MakeWindowAssociation`: DXGI must not handle Alt+Enter; Gooey windows
/// have no exclusive fullscreen mode.
pub const DXGI_MWA_NO_ALT_ENTER: u32 = 0x2;

pub const D3D11_USAGE_DEFAULT: u32 = 0;
pub const D3D11_USAGE_IMMUTABLE: u32 = 1;
pub const D3D11_USAGE_DYNAMIC: u32 = 2;
pub const D3D11_USAGE_STAGING: u32 = 3;

pub const D3D11_BIND_VERTEX_BUFFER: u32 = 0x1;
pub const D3D11_BIND_INDEX_BUFFER: u32 = 0x2;
pub const D3D11_BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;
pub const D3D11_BIND_RENDER_TARGET: u32 = 0x20;

pub const D3D11_CPU_ACCESS_WRITE: u32 = 0x1_0000;
pub const D3D11_CPU_ACCESS_READ: u32 = 0x2_0000;

pub const D3D11_RESOURCE_MISC_BUFFER_STRUCTURED: u32 = 0x40;

pub const D3D11_MAP_READ: u32 = 1;
pub const D3D11_MAP_WRITE: u32 = 2;
pub const D3D11_MAP_WRITE_DISCARD: u32 = 4;

pub const D3D11_INPUT_PER_VERTEX_DATA: u32 = 0;
pub const D3D11_INPUT_PER_INSTANCE_DATA: u32 = 1;

pub const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST: u32 = 4;
pub const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: u32 = 5;

pub const D3D11_BLEND_ZERO: u32 = 1;
pub const D3D11_BLEND_ONE: u32 = 2;
pub const D3D11_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D11_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D11_BLEND_OP_ADD: u32 = 1;
pub const D3D11_COLOR_WRITE_ENABLE_ALL: u8 = 0xF;

pub const D3D11_FILL_SOLID: u32 = 3;
pub const D3D11_CULL_NONE: u32 = 1;

pub const D3D11_FILTER_MIN_MAG_MIP_LINEAR: u32 = 0x15;
pub const D3D11_TEXTURE_ADDRESS_CLAMP: u32 = 3;
pub const D3D11_COMPARISON_NEVER: u32 = 1;

/// Simultaneous render targets the output merger accepts; fixes the length
/// of `D3D11_BLEND_DESC.RenderTarget`.
pub const D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT: u32 = 8;

// =============================================================================
// Structures
// =============================================================================

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32,
    Quality: u32,
};

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: u32,
    Height: u32,
    Format: u32,
    Stereo: BOOL,
    SampleDesc: DXGI_SAMPLE_DESC,
    BufferUsage: u32,
    BufferCount: u32,
    Scaling: u32,
    SwapEffect: u32,
    AlphaMode: u32,
    Flags: u32,
};

pub const LUID = extern struct {
    LowPart: u32,
    HighPart: i32,
};

pub const DXGI_ADAPTER_DESC = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: LUID,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: u32,
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
    StructureByteStride: u32,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: u32,
    SampleDesc: DXGI_SAMPLE_DESC,
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
};

pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32,
    Format: u32,
    InputSlot: u32,
    AlignedByteOffset: u32,
    InputSlotClass: u32,
    InstanceDataStepRate: u32,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: u32,
    SysMemSlicePitch: u32,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque,
    RowPitch: u32,
    DepthPitch: u32,
};

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: f32,
    TopLeftY: f32,
    Width: f32,
    Height: f32,
    MinDepth: f32,
    MaxDepth: f32,
};

/// `D3D11_RECT` is the Win32 `RECT`: exclusive right and bottom edges.
pub const D3D11_RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Exclusive `right`, `bottom`, and `back` edges.
pub const D3D11_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL,
    SrcBlend: u32,
    DestBlend: u32,
    BlendOp: u32,
    SrcBlendAlpha: u32,
    DestBlendAlpha: u32,
    BlendOpAlpha: u32,
    RenderTargetWriteMask: u8,
};

pub const D3D11_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL,
    IndependentBlendEnable: BOOL,
    RenderTarget: [D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT]D3D11_RENDER_TARGET_BLEND_DESC,
};

pub const D3D11_RASTERIZER_DESC = extern struct {
    FillMode: u32,
    CullMode: u32,
    FrontCounterClockwise: BOOL,
    DepthBias: i32,
    DepthBiasClamp: f32,
    SlopeScaledDepthBias: f32,
    DepthClipEnable: BOOL,
    ScissorEnable: BOOL,
    MultisampleEnable: BOOL,
    AntialiasedLineEnable: BOOL,
};

pub const D3D11_SAMPLER_DESC = extern struct {
    Filter: u32,
    AddressU: u32,
    AddressV: u32,
    AddressW: u32,
    MipLODBias: f32,
    MaxAnisotropy: u32,
    ComparisonFunc: u32,
    BorderColor: [4]f32,
    MinLOD: f32,
    MaxLOD: f32,
};

// =============================================================================
// Release-only interfaces
// =============================================================================

/// An interface the renderer creates, binds, and releases but calls nothing
/// else on. `tag` makes each one a distinct type, so a pixel shader cannot be
/// bound where a vertex shader belongs.
fn ReleaseOnly(comptime tag: []const u8) type {
    return extern struct {
        vtable: *const VTable,

        const Interface = @This();

        pub const VTable = extern struct {
            QueryInterface: Slot,
            AddRef: Slot,
            Release: *const fn (*Interface) callconv(.winapi) u32,
        };

        pub const name = tag;

        pub fn release(self: *Interface) void {
            _ = self.vtable.Release(self);
        }
    };
}

pub const ID3D11ShaderResourceView = ReleaseOnly("ID3D11ShaderResourceView");
pub const ID3D11RenderTargetView = ReleaseOnly("ID3D11RenderTargetView");
pub const ID3D11VertexShader = ReleaseOnly("ID3D11VertexShader");
pub const ID3D11PixelShader = ReleaseOnly("ID3D11PixelShader");
pub const ID3D11BlendState = ReleaseOnly("ID3D11BlendState");
pub const ID3D11RasterizerState = ReleaseOnly("ID3D11RasterizerState");
pub const ID3D11SamplerState = ReleaseOnly("ID3D11SamplerState");
pub const ID3D11DepthStencilView = ReleaseOnly("ID3D11DepthStencilView");
pub const ID3D11ClassLinkage = ReleaseOnly("ID3D11ClassLinkage");
pub const ID3D11ClassInstance = ReleaseOnly("ID3D11ClassInstance");
pub const ID3D11InputLayout = ReleaseOnly("ID3D11InputLayout");
pub const IDXGIOutput = ReleaseOnly("IDXGIOutput");

/// Any `ID3D11Resource`: the parameter type of `Map`, `CopyResource`, and the
/// view constructors. Buffers and textures convert with `resource()`.
pub const ID3D11Resource = ReleaseOnly("ID3D11Resource");

/// `ID3D11Buffer` and `ID3D11Texture2D` are `ID3D11Resource`s; the renderer
/// calls only `Release` on them directly.
pub const ID3D11Buffer = extern struct {
    vtable: *const ID3D11Resource.VTable,

    pub fn resource(self: *ID3D11Buffer) *ID3D11Resource {
        return @ptrCast(self);
    }

    pub fn release(self: *ID3D11Buffer) void {
        self.resource().release();
    }
};

pub const ID3D11Texture2D = extern struct {
    vtable: *const ID3D11Resource.VTable,

    pub fn resource(self: *ID3D11Texture2D) *ID3D11Resource {
        return @ptrCast(self);
    }

    pub fn release(self: *ID3D11Texture2D) void {
        self.resource().release();
    }
};

// =============================================================================
// ID3D11Device
// =============================================================================

pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    const Self = ID3D11Device;

    pub const VTable = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Slot,
        Release: *const fn (*Self) callconv(.winapi) u32,
        CreateBuffer: *const fn (
            *Self,
            *const D3D11_BUFFER_DESC,
            ?*const D3D11_SUBRESOURCE_DATA,
            *?*ID3D11Buffer,
        ) callconv(.winapi) HRESULT,
        CreateTexture1D: Slot,
        CreateTexture2D: *const fn (
            *Self,
            *const D3D11_TEXTURE2D_DESC,
            ?*const D3D11_SUBRESOURCE_DATA,
            *?*ID3D11Texture2D,
        ) callconv(.winapi) HRESULT,
        CreateTexture3D: Slot,
        CreateShaderResourceView: *const fn (
            *Self,
            *ID3D11Resource,
            ?*const anyopaque, // D3D11_SHADER_RESOURCE_VIEW_DESC; null views it whole
            *?*ID3D11ShaderResourceView,
        ) callconv(.winapi) HRESULT,
        CreateUnorderedAccessView: Slot,
        CreateRenderTargetView: *const fn (
            *Self,
            *ID3D11Resource,
            ?*const anyopaque, // D3D11_RENDER_TARGET_VIEW_DESC; null views mip 0
            *?*ID3D11RenderTargetView,
        ) callconv(.winapi) HRESULT,
        CreateDepthStencilView: Slot,
        CreateInputLayout: *const fn (
            *Self,
            [*]const D3D11_INPUT_ELEMENT_DESC,
            u32,
            [*]const u8,
            usize,
            *?*ID3D11InputLayout,
        ) callconv(.winapi) HRESULT,
        CreateVertexShader: *const fn (
            *Self,
            [*]const u8,
            usize,
            ?*ID3D11ClassLinkage,
            *?*ID3D11VertexShader,
        ) callconv(.winapi) HRESULT,
        CreateGeometryShader: Slot,
        CreateGeometryShaderWithStreamOutput: Slot,
        CreatePixelShader: *const fn (
            *Self,
            [*]const u8,
            usize,
            ?*ID3D11ClassLinkage,
            *?*ID3D11PixelShader,
        ) callconv(.winapi) HRESULT,
        CreateHullShader: Slot,
        CreateDomainShader: Slot,
        CreateComputeShader: Slot,
        CreateClassLinkage: Slot,
        CreateBlendState: *const fn (
            *Self,
            *const D3D11_BLEND_DESC,
            *?*ID3D11BlendState,
        ) callconv(.winapi) HRESULT,
        CreateDepthStencilState: Slot,
        CreateRasterizerState: *const fn (
            *Self,
            *const D3D11_RASTERIZER_DESC,
            *?*ID3D11RasterizerState,
        ) callconv(.winapi) HRESULT,
        CreateSamplerState: *const fn (
            *Self,
            *const D3D11_SAMPLER_DESC,
            *?*ID3D11SamplerState,
        ) callconv(.winapi) HRESULT,
        CreateQuery: Slot,
        CreatePredicate: Slot,
        CreateCounter: Slot,
        CreateDeferredContext: Slot,
        OpenSharedResource: Slot,
        CheckFormatSupport: Slot,
        CheckMultisampleQualityLevels: Slot,
        CheckCounterInfo: Slot,
        CheckCounter: Slot,
        CheckFeatureSupport: Slot,
        GetPrivateData: Slot,
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
        GetFeatureLevel: *const fn (*Self) callconv(.winapi) u32,
        GetCreationFlags: Slot,
        GetDeviceRemovedReason: *const fn (*Self) callconv(.winapi) HRESULT,
        GetImmediateContext: Slot,
        SetExceptionMode: Slot,
        GetExceptionMode: Slot,
    };

    pub fn release(self: *Self) void {
        _ = self.vtable.Release(self);
    }
};

// =============================================================================
// ID3D11DeviceContext
// =============================================================================

pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    const Self = ID3D11DeviceContext;

    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*Self) callconv(.winapi) u32,
        // ID3D11DeviceChild
        GetDevice: Slot,
        GetPrivateData: Slot,
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
        // ID3D11DeviceContext
        VSSetConstantBuffers: *const fn (
            *Self,
            u32,
            u32,
            [*]const ?*ID3D11Buffer,
        ) callconv(.winapi) void,
        PSSetShaderResources: *const fn (
            *Self,
            u32,
            u32,
            [*]const ?*ID3D11ShaderResourceView,
        ) callconv(.winapi) void,
        PSSetShader: *const fn (
            *Self,
            ?*ID3D11PixelShader,
            ?[*]const ?*ID3D11ClassInstance,
            u32,
        ) callconv(.winapi) void,
        PSSetSamplers: *const fn (
            *Self,
            u32,
            u32,
            [*]const ?*ID3D11SamplerState,
        ) callconv(.winapi) void,
        VSSetShader: *const fn (
            *Self,
            ?*ID3D11VertexShader,
            ?[*]const ?*ID3D11ClassInstance,
            u32,
        ) callconv(.winapi) void,
        DrawIndexed: *const fn (*Self, u32, u32, i32) callconv(.winapi) void,
        Draw: *const fn (*Self, u32, u32) callconv(.winapi) void,
        Map: *const fn (
            *Self,
            *ID3D11Resource,
            u32,
            u32,
            u32,
            *D3D11_MAPPED_SUBRESOURCE,
        ) callconv(.winapi) HRESULT,
        Unmap: *const fn (*Self, *ID3D11Resource, u32) callconv(.winapi) void,
        PSSetConstantBuffers: *const fn (
            *Self,
            u32,
            u32,
            [*]const ?*ID3D11Buffer,
        ) callconv(.winapi) void,
        IASetInputLayout: *const fn (*Self, ?*ID3D11InputLayout) callconv(.winapi) void,
        IASetVertexBuffers: *const fn (
            *Self,
            u32,
            u32,
            [*]const ?*ID3D11Buffer,
            [*]const u32,
            [*]const u32,
        ) callconv(.winapi) void,
        IASetIndexBuffer: *const fn (*Self, ?*ID3D11Buffer, u32, u32) callconv(.winapi) void,
        DrawIndexedInstanced: Slot,
        DrawInstanced: *const fn (*Self, u32, u32, u32, u32) callconv(.winapi) void,
        GSSetConstantBuffers: Slot,
        GSSetShader: Slot,
        IASetPrimitiveTopology: *const fn (*Self, u32) callconv(.winapi) void,
        VSSetShaderResources: *const fn (
            *Self,
            u32,
            u32,
            [*]const ?*ID3D11ShaderResourceView,
        ) callconv(.winapi) void,
        VSSetSamplers: Slot,
        Begin: Slot,
        End: Slot,
        GetData: Slot,
        SetPredication: Slot,
        GSSetShaderResources: Slot,
        GSSetSamplers: Slot,
        OMSetRenderTargets: *const fn (
            *Self,
            u32,
            ?[*]const ?*ID3D11RenderTargetView,
            ?*ID3D11DepthStencilView,
        ) callconv(.winapi) void,
        OMSetRenderTargetsAndUnorderedAccessViews: Slot,
        OMSetBlendState: *const fn (
            *Self,
            ?*ID3D11BlendState,
            ?*const [4]f32,
            u32,
        ) callconv(.winapi) void,
        OMSetDepthStencilState: Slot,
        SOSetTargets: Slot,
        DrawAuto: Slot,
        DrawIndexedInstancedIndirect: Slot,
        DrawInstancedIndirect: Slot,
        Dispatch: Slot,
        DispatchIndirect: Slot,
        RSSetState: *const fn (*Self, ?*ID3D11RasterizerState) callconv(.winapi) void,
        RSSetViewports: *const fn (*Self, u32, [*]const D3D11_VIEWPORT) callconv(.winapi) void,
        RSSetScissorRects: *const fn (*Self, u32, [*]const D3D11_RECT) callconv(.winapi) void,
        CopySubresourceRegion: *const fn (
            *Self,
            *ID3D11Resource,
            u32,
            u32,
            u32,
            u32,
            *ID3D11Resource,
            u32,
            ?*const D3D11_BOX,
        ) callconv(.winapi) void,
        CopyResource: *const fn (*Self, *ID3D11Resource, *ID3D11Resource) callconv(.winapi) void,
        UpdateSubresource: *const fn (
            *Self,
            *ID3D11Resource,
            u32,
            ?*const D3D11_BOX,
            *const anyopaque,
            u32,
            u32,
        ) callconv(.winapi) void,
        CopyStructureCount: Slot,
        ClearRenderTargetView: *const fn (
            *Self,
            *ID3D11RenderTargetView,
            *const [4]f32,
        ) callconv(.winapi) void,
        // Every later slot up to `FinishCommandList` (index 114).
        rest: [ClearState_slot - ClearRenderTargetView_slot - 1]Slot,
        ClearState: *const fn (*Self) callconv(.winapi) void,
        Flush: *const fn (*Self) callconv(.winapi) void,
        GetType: Slot,
        GetContextFlags: Slot,
        FinishCommandList: Slot,
    };

    const ClearRenderTargetView_slot = 50;
    const ClearState_slot = 110;

    pub fn release(self: *Self) void {
        _ = self.vtable.Release(self);
    }
};

// =============================================================================
// DXGI
// =============================================================================

pub const IDXGIDevice = extern struct {
    vtable: *const VTable,

    const Self = IDXGIDevice;

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*Self) callconv(.winapi) u32,
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
        GetPrivateData: Slot,
        GetParent: Slot,
        GetAdapter: *const fn (*Self, *?*IDXGIAdapter) callconv(.winapi) HRESULT,
        CreateSurface: Slot,
        QueryResourceResidency: Slot,
        SetGPUThreadPriority: Slot,
        GetGPUThreadPriority: Slot,
    };

    pub fn release(self: *Self) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDXGIAdapter = extern struct {
    vtable: *const VTable,

    const Self = IDXGIAdapter;

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*Self) callconv(.winapi) u32,
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
        GetPrivateData: Slot,
        GetParent: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        EnumOutputs: Slot,
        GetDesc: *const fn (*Self, *DXGI_ADAPTER_DESC) callconv(.winapi) HRESULT,
        CheckInterfaceSupport: Slot,
    };

    pub fn release(self: *Self) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    const Self = IDXGIFactory2;

    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*Self) callconv(.winapi) u32,
        // IDXGIObject
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
        GetPrivateData: Slot,
        GetParent: Slot,
        // IDXGIFactory
        EnumAdapters: Slot,
        MakeWindowAssociation: *const fn (*Self, HWND, u32) callconv(.winapi) HRESULT,
        GetWindowAssociation: Slot,
        CreateSwapChain: Slot,
        CreateSoftwareAdapter: Slot,
        // IDXGIFactory1
        EnumAdapters1: Slot,
        IsCurrent: Slot,
        // IDXGIFactory2
        IsWindowedStereoEnabled: Slot,
        CreateSwapChainForHwnd: *const fn (
            *Self,
            *anyopaque, // IUnknown: the device
            HWND,
            *const DXGI_SWAP_CHAIN_DESC1,
            ?*const anyopaque, // DXGI_SWAP_CHAIN_FULLSCREEN_DESC; null is windowed
            ?*IDXGIOutput,
            *?*IDXGISwapChain2, // An IDXGISwapChain1; queried for 2 below.
        ) callconv(.winapi) HRESULT,
        CreateSwapChainForCoreWindow: Slot,
        GetSharedResourceAdapterLuid: Slot,
        RegisterStereoStatusWindow: Slot,
        RegisterStereoStatusEvent: Slot,
        UnregisterStereoStatus: Slot,
        RegisterOcclusionStatusWindow: Slot,
        RegisterOcclusionStatusEvent: Slot,
        UnregisterOcclusionStatus: Slot,
        CreateSwapChainForComposition: Slot,
    };

    pub fn release(self: *Self) void {
        _ = self.vtable.Release(self);
    }
};

/// Declared through `IDXGISwapChain2` (DXGI 1.3, Windows 8.1) for the frame
/// latency waitable. `CreateSwapChainForHwnd` returns an `IDXGISwapChain1`,
/// whose slots are this vtable's prefix; the renderer calls only those
/// through it before querying for `IDXGISwapChain2`.
pub const IDXGISwapChain2 = extern struct {
    vtable: *const VTable,

    const Self = IDXGISwapChain2;

    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Slot,
        Release: *const fn (*Self) callconv(.winapi) u32,
        // IDXGIObject
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
        GetPrivateData: Slot,
        GetParent: Slot,
        // IDXGIDeviceSubObject
        GetDevice: Slot,
        // IDXGISwapChain
        Present: *const fn (*Self, u32, u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*Self, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: Slot,
        GetFullscreenState: Slot,
        GetDesc: Slot,
        ResizeBuffers: *const fn (*Self, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT,
        ResizeTarget: Slot,
        GetContainingOutput: Slot,
        GetFrameStatistics: Slot,
        GetLastPresentCount: Slot,
        // IDXGISwapChain1
        GetDesc1: Slot,
        GetFullscreenDesc: Slot,
        GetHwnd: Slot,
        GetCoreWindow: Slot,
        Present1: Slot,
        IsTemporaryMonoSupported: Slot,
        GetRestrictToOutput: Slot,
        SetBackgroundColor: Slot,
        GetBackgroundColor: Slot,
        SetRotation: Slot,
        GetRotation: Slot,
        // IDXGISwapChain2
        SetSourceSize: Slot,
        GetSourceSize: Slot,
        SetMaximumFrameLatency: *const fn (*Self, u32) callconv(.winapi) HRESULT,
        GetMaximumFrameLatency: Slot,
        GetFrameLatencyWaitableObject: *const fn (*Self) callconv(.winapi) ?HANDLE,
        SetMatrixTransform: Slot,
        GetMatrixTransform: Slot,
    };

    pub fn release(self: *Self) void {
        _ = self.vtable.Release(self);
    }
};

// =============================================================================
// Functions
// =============================================================================

pub extern "d3d11" fn D3D11CreateDevice(
    pAdapter: ?*IDXGIAdapter,
    DriverType: u32,
    Software: ?*anyopaque,
    Flags: u32,
    pFeatureLevels: [*]const u32,
    FeatureLevels: u32,
    SDKVersion: u32,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: *u32,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

// =============================================================================
// Layout pins
// =============================================================================

fn assertSlot(comptime VTable: type, comptime name: []const u8, comptime slot: u32) void {
    assert(@offsetOf(VTable, name) == slot * @sizeOf(usize));
}

fn assertSlotCount(comptime VTable: type, comptime count: u32) void {
    assert(@sizeOf(VTable) == count * @sizeOf(usize));
}

comptime {
    // `x86_64-windows` only; see `docs/windows-port.md`.
    assert(@sizeOf(usize) == 8);

    // Sizes measured against the SDK headers on 64-bit targets.
    assert(@sizeOf(GUID) == 16);
    assert(@sizeOf(DXGI_SWAP_CHAIN_DESC1) == 48);
    assert(@sizeOf(DXGI_ADAPTER_DESC) == 304);
    assert(@sizeOf(D3D11_BUFFER_DESC) == 24);
    assert(@sizeOf(D3D11_TEXTURE2D_DESC) == 44);
    assert(@sizeOf(D3D11_INPUT_ELEMENT_DESC) == 32);
    assert(@sizeOf(D3D11_SUBRESOURCE_DATA) == 16);
    assert(@sizeOf(D3D11_MAPPED_SUBRESOURCE) == 16);
    assert(@sizeOf(D3D11_VIEWPORT) == 24);
    assert(@sizeOf(D3D11_RECT) == 16);
    assert(@sizeOf(D3D11_BOX) == 24);
    assert(@sizeOf(D3D11_RENDER_TARGET_BLEND_DESC) == 32);
    assert(@sizeOf(D3D11_BLEND_DESC) == 264);
    assert(@sizeOf(D3D11_RASTERIZER_DESC) == 40);
    assert(@sizeOf(D3D11_SAMPLER_DESC) == 52);

    assertSlot(ID3D11Device.VTable, "QueryInterface", 0);
    assertSlot(ID3D11Device.VTable, "Release", 2);
    assertSlot(ID3D11Device.VTable, "CreateBuffer", 3);
    assertSlot(ID3D11Device.VTable, "CreateTexture2D", 5);
    assertSlot(ID3D11Device.VTable, "CreateShaderResourceView", 7);
    assertSlot(ID3D11Device.VTable, "CreateRenderTargetView", 9);
    assertSlot(ID3D11Device.VTable, "CreateInputLayout", 11);
    assertSlot(ID3D11Device.VTable, "CreateVertexShader", 12);
    assertSlot(ID3D11Device.VTable, "CreatePixelShader", 15);
    assertSlot(ID3D11Device.VTable, "CreateBlendState", 20);
    assertSlot(ID3D11Device.VTable, "CreateRasterizerState", 22);
    assertSlot(ID3D11Device.VTable, "CreateSamplerState", 23);
    assertSlot(ID3D11Device.VTable, "GetFeatureLevel", 37);
    assertSlot(ID3D11Device.VTable, "GetDeviceRemovedReason", 39);
    assertSlotCount(ID3D11Device.VTable, 43);

    const Context = ID3D11DeviceContext.VTable;
    assertSlot(Context, "Release", 2);
    assertSlot(Context, "VSSetConstantBuffers", 7);
    assertSlot(Context, "PSSetShaderResources", 8);
    assertSlot(Context, "PSSetShader", 9);
    assertSlot(Context, "PSSetSamplers", 10);
    assertSlot(Context, "VSSetShader", 11);
    assertSlot(Context, "DrawIndexed", 12);
    assertSlot(Context, "Draw", 13);
    assertSlot(Context, "Map", 14);
    assertSlot(Context, "Unmap", 15);
    assertSlot(Context, "PSSetConstantBuffers", 16);
    assertSlot(Context, "IASetInputLayout", 17);
    assertSlot(Context, "IASetVertexBuffers", 18);
    assertSlot(Context, "IASetIndexBuffer", 19);
    assertSlot(Context, "DrawInstanced", 21);
    assertSlot(Context, "IASetPrimitiveTopology", 24);
    assertSlot(Context, "VSSetShaderResources", 25);
    assertSlot(Context, "OMSetRenderTargets", 33);
    assertSlot(Context, "OMSetBlendState", 35);
    assertSlot(Context, "RSSetState", 43);
    assertSlot(Context, "RSSetViewports", 44);
    assertSlot(Context, "RSSetScissorRects", 45);
    assertSlot(Context, "CopySubresourceRegion", 46);
    assertSlot(Context, "CopyResource", 47);
    assertSlot(Context, "UpdateSubresource", 48);
    assertSlot(Context, "ClearRenderTargetView", ID3D11DeviceContext.ClearRenderTargetView_slot);
    assertSlot(Context, "ClearState", ID3D11DeviceContext.ClearState_slot);
    assertSlot(Context, "Flush", 111);
    assertSlotCount(Context, 115);

    assertSlot(IDXGIDevice.VTable, "GetAdapter", 7);
    assertSlotCount(IDXGIDevice.VTable, 12);

    assertSlot(IDXGIAdapter.VTable, "GetParent", 6);
    assertSlot(IDXGIAdapter.VTable, "GetDesc", 8);
    assertSlotCount(IDXGIAdapter.VTable, 10);

    assertSlot(IDXGIFactory2.VTable, "MakeWindowAssociation", 8);
    assertSlot(IDXGIFactory2.VTable, "CreateSwapChainForHwnd", 15);
    assertSlotCount(IDXGIFactory2.VTable, 25);

    assertSlot(IDXGISwapChain2.VTable, "QueryInterface", 0);
    assertSlot(IDXGISwapChain2.VTable, "Present", 8);
    assertSlot(IDXGISwapChain2.VTable, "GetBuffer", 9);
    assertSlot(IDXGISwapChain2.VTable, "ResizeBuffers", 13);
    assertSlot(IDXGISwapChain2.VTable, "SetMaximumFrameLatency", 31);
    assertSlot(IDXGISwapChain2.VTable, "GetFrameLatencyWaitableObject", 33);
    assertSlotCount(IDXGISwapChain2.VTable, 36);

    // Distinct types: binding one release-only interface where another is
    // expected fails to compile.
    assert(ID3D11VertexShader != ID3D11PixelShader);
}
