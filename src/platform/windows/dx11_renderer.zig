//! DX11 renderer — D3D11 twin of `vk_renderer.VulkanRenderer`.
//!
//! Same public surface (so `window.zig` call sites are backend-agnostic and
//! the comptime `gpu_backend` switch can pick either): `init`, `deinit`,
//! `initWithWin32Surface`, `resize`, `setClearColor`, `stageTextAtlas`,
//! `stageSvgAtlas`, `stageImageAtlas`, `render(scene)`, plus the
//! `svg_atlas`/`image_atlas` fields `window.zig` polls directly.
//!
//! Pipeline model (mirroring the Vulkan render pass):
//!   MSAA 4x render target (RTV) — clear — batched draws — resolve —
//!   CopyResource to the FLIP_DISCARD backbuffer — Present(1).
//! Instance data flows through per-frame dynamic constant/structured buffers
//! sized from `InstanceCapacity.bufferBytes()` exactly like the Vulkan
//! storage buffers. Atlas uploads use the per-atlas staging textures from
//! `dx11_atlas.zig`. The Y-flip the NDC difference requires lives in the
//! HLSL vertex shaders, not here.
//!
//! Everything shader-logic-side is shared with the Vulkan backend: scene
//! consumption (`dx11_scene_renderer.zig` ← `batch_iterator`), GPU instance
//! structs (`vk_types.zig`), and the unified primitive conversion
//! (`unified.zig`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const d3d11 = @import("win32/graphics/direct3d11.zig");
const dxgi = @import("win32/graphics/dxgi.zig");
const fxc = @import("win32/graphics/direct3d/fxc.zig");
const win32 = @import("win32/mod.zig");
const dx11_atlas = @import("dx11_atlas.zig");
const scene_renderer = @import("dx11_scene_renderer.zig");
const interface_verify = @import("../../core/interface_verify.zig");
const geometry = @import("../../core/geometry.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../scene/mod.zig");
const Scene = scene_mod.Scene;
const SceneLimits = @import("../../core/limits.zig").SceneLimits;

const vk_types = @import("vk_types.zig");
const Uniforms = vk_types.Uniforms;
const InstanceCapacity = vk_types.InstanceCapacity;
const FRAME_COUNT = vk_types.FRAME_COUNT;

const dx11_foundation = @import("win32/foundation.zig");
const d3d_common = @import("win32/graphics/direct3d.zig");

/// Triple-buffered to match the Vulkan backend's FRAME_COUNT.
const BACK_BUFFER_COUNT: u32 = FRAME_COUNT;

// Embedded HLSL sources, compiled with D3DCompile at init. Editing
// guidance at the top of each file; GLSL twins live in
// src/platform/linux/shaders. At file scope so the regression tests below
// can assert on the source text.
const unified_hlsl: []const u8 = @embedFile("shaders/hlsl/unified.hlsl");
const text_hlsl: []const u8 = @embedFile("shaders/hlsl/text.hlsl");
const svg_hlsl: []const u8 = @embedFile("shaders/hlsl/svg.hlsl");
const image_hlsl: []const u8 = @embedFile("shaders/hlsl/image.hlsl");

/// MSAA sample count for the scene target. 4x matches the Vulkan render
/// pass default (`VK_SAMPLE_COUNT_4_BIT`); D3D11 guarantees 4x support for
/// every render-target-capable format.
const MSAA_SAMPLE_COUNT: u32 = 4;

// =============================================================================
// Dx11Renderer
// =============================================================================

pub const Dx11Renderer = struct {
    // Compile-time interface verification (same contract as VulkanRenderer)
    comptime {
        interface_verify.verifyRendererInterface(@This());
    }

    allocator: Allocator,

    // Core D3D11 objects
    device: ?*d3d11.ID3D11Device = null,
    context: ?*d3d11.ID3D11DeviceContext = null,
    factory: ?*dxgi.IDXGIFactory2 = null,
    swap_chain: ?*dxgi.IDXGISwapChain1 = null,

    // Swapchain
    backbuffer_rtv: ?*d3d11.ID3D11RenderTargetView = null,
    /// Backbuffer as a texture — the resolve destination for
    /// ResolveSubresource (GetBuffer hands us an IDXGISurface; QI it).
    backbuffer_texture: ?*d3d11.ID3D11Texture2D = null,
    swapchain_width: u32 = 0,
    swapchain_height: u32 = 0,

    // MSAA scene target (4x), resolved into the backbuffer every frame —
    // the D3D11 counterpart of the Vulkan MSAA attachment + resolve.
    msaa_texture: ?*d3d11.ID3D11Texture2D = null,
    msaa_rtv: ?*d3d11.ID3D11RenderTargetView = null,

    // Scale factor for HiDPI
    scale_factor: f64 = 1.0,

    // Framebuffer clear color, republished by `Window.renderFrame` from
    // `Window.getClearColor()` before every frame. Same default as Vulkan.
    clear_color: geometry.Color = geometry.Color.rgba(0.1, 0.1, 0.12, 1.0),

    // Shaders (per-kind VS/PS + input layouts; SV_VertexID quads, no VBs)
    unified_vs: ?*d3d11.ID3D11VertexShader = null,
    unified_ps: ?*d3d11.ID3D11PixelShader = null,
    unified_layout: ?*d3d11.ID3D11InputLayout = null,
    text_vs: ?*d3d11.ID3D11VertexShader = null,
    text_ps: ?*d3d11.ID3D11PixelShader = null,
    text_layout: ?*d3d11.ID3D11InputLayout = null,
    svg_vs: ?*d3d11.ID3D11VertexShader = null,
    svg_ps: ?*d3d11.ID3D11PixelShader = null,
    svg_layout: ?*d3d11.ID3D11InputLayout = null,
    image_vs: ?*d3d11.ID3D11VertexShader = null,
    image_ps: ?*d3d11.ID3D11PixelShader = null,
    image_layout: ?*d3d11.ID3D11InputLayout = null,

    // Blend states
    standard_blend: ?*d3d11.ID3D11BlendState = null,
    premultiplied_blend: ?*d3d11.ID3D11BlendState = null,

    // Sampler shared by the three atlas textures (linear, clamp — mirrors
    // vk_descriptors' shared sampler)
    atlas_sampler: ?*d3d11.ID3D11SamplerState = null,

    // Rasterizer state (cull-none to match the Vulkan pipelines)
    rasterizer: ?*d3d11.ID3D11RasterizerState = null,

    current_frame: u32 = 0,

    // Per-frame resources: instance buffers + uniform buffer. Triple-buffered
    // so CPU can write frame N+1 while GPU reads frame N (same as Vulkan).
    frames: [FRAME_COUNT]FrameResources = @splat(.{}),

    // Atlas textures (text=R8, SVG/image=RGBA8)
    text_atlas: dx11_atlas.AtlasResources = .{},
    svg_atlas: dx11_atlas.AtlasResources = .{},
    image_atlas: dx11_atlas.AtlasResources = .{},

    // Pending atlas uploads — populated by stageXxxAtlas(), consumed by render().
    // Stores data pointers valid for the duration of renderFrame().
    pending_text: PendingUpload = .{},
    pending_svg: PendingUpload = .{},
    pending_image: PendingUpload = .{},

    // Per-frame instance buffer capacities, from the window's `ResourceLimits.scene`.
    // Set once in `initWithWin32Surface` before any buffer is created; read-only
    // afterwards (buffers never grow). Meaningful only while `initialized`.
    instance_capacity: InstanceCapacity = undefined,

    /// Set when the device is lost: subsequent frames are skipped until the
    /// window recreates the renderer. Minimal device-lost handling (log +
    /// skip), matching gpui's skip_draws semantics without full rebuild.
    device_lost: bool = false,

    initialized: bool = false,

    // Mapped instance buffer pointers for the current frame, refreshed in
    // render() before drawScene and unmapped after. (The Vulkan renderer
    // hands drawScene persistently-mapped storage buffers; D3D11 DYNAMIC
    // buffers must be mapped per frame, so the pointers live here.)
    mapped_primitive: ?*anyopaque = null,
    mapped_glyph: ?*anyopaque = null,
    mapped_svg: ?*anyopaque = null,
    mapped_image: ?*anyopaque = null,

    /// Viewport size the shaders divide positions by: LOGICAL pixels,
    /// matching vk_renderer.updateUniformBuffer (physical size only sets
    /// the raster viewport). Updated at init and by the window on resize.
    uniform_viewport_width: f32 = 800,
    uniform_viewport_height: f32 = 600,

    /// Per-frame SRVs over each slot's structured buffers (t0). Binding frame
    /// 0's views while writing frame N's buffers delivers stale rows; each
    /// slot gets its own view set, bound by `render` before drawScene.
    frame_srvs: [FRAME_COUNT]FrameSRVs = @splat(.{}),

    const Self = @This();

    /// Atlas type identifier for upload routing.
    const AtlasKind = enum { text, svg, image };

    /// Per-frame instance buffers. DYNAMIC usage + WRITE_DISCARD mapping —
    /// the D3D11 equivalent of the Vulkan host-visible storage buffers.
    const FrameResources = struct {
        uniform_buffer: ?*d3d11.ID3D11Buffer = null,
        // b1 DrawBase: rewritten by submitScene before every draw.
        draw_base_buffer: ?*d3d11.ID3D11Buffer = null,
        primitive_buffer: ?*d3d11.ID3D11Buffer = null,
        glyph_buffer: ?*d3d11.ID3D11Buffer = null,
        svg_buffer: ?*d3d11.ID3D11Buffer = null,
        image_buffer: ?*d3d11.ID3D11Buffer = null,
    };

    const PendingUpload = struct {
        data: []const u8 = &.{},
        width: u32 = 0,
        height: u32 = 0,
        format: dx11_atlas.AtlasFormat = .r8,
        dirty: ?dx11_atlas.DirtyRegion = null,
        active: bool = false,
    };

    /// Shader-resource views over one slot's instance buffers (t0).
    const FrameSRVs = struct {
        primitive: ?*d3d11.ID3D11ShaderResourceView = null,
        glyph: ?*d3d11.ID3D11ShaderResourceView = null,
        svg: ?*d3d11.ID3D11ShaderResourceView = null,
        image: ?*d3d11.ID3D11ShaderResourceView = null,
    };

    const MAX_ATLAS_TRANSFERS = 3;

    const AtlasTransferRecord = struct {
        resources: *dx11_atlas.AtlasResources,
        dirty: dx11_atlas.DirtyRegion,
    };

    const InitError = error{
        NoDxgiFactory,
        NoAdapter,
        DeviceCreationFailed,
        SwapchainCreationFailed,
        BackbufferFailed,
        MsaaTargetFailed,
        ShaderCompilerMissing,
        ShaderCompileFailed,
        ShaderObjectFailed,
        ObjectCreationFailed,
    };

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (!self.initialized) return;

        self.destroyFrameSRVs();
        self.destroyFrameResources();
        self.text_atlas.destroy(self.device.?);
        self.svg_atlas.destroy(self.device.?);
        self.image_atlas.destroy(self.device.?);
        self.destroyShaders();
        self.destroyRenderTarget();

        _ = if (self.swap_chain) |sc| sc.IUnknown.Release();
        self.swap_chain = null;
        _ = if (self.factory) |f| f.IUnknown.Release();
        self.factory = null;
        _ = if (self.context) |c| c.IUnknown.Release();
        self.context = null;
        _ = if (self.device) |d| d.IUnknown.Release();
        self.device = null;

        self.initialized = false;
    }

    /// Release every per-frame dynamic buffer. Called by `deinit` and by the
    /// init error path once frame buffers exist.
    fn destroyFrameResources(self: *Self) void {
        for (&self.frames) |*frame| {
            if (frame.uniform_buffer) |b| _ = b.IUnknown.Release();
            frame.uniform_buffer = null;
            if (frame.draw_base_buffer) |b| _ = b.IUnknown.Release();
            frame.draw_base_buffer = null;
            if (frame.primitive_buffer) |b| _ = b.IUnknown.Release();
            frame.primitive_buffer = null;
            if (frame.glyph_buffer) |b| _ = b.IUnknown.Release();
            frame.glyph_buffer = null;
            if (frame.svg_buffer) |b| _ = b.IUnknown.Release();
            frame.svg_buffer = null;
            if (frame.image_buffer) |b| _ = b.IUnknown.Release();
            frame.image_buffer = null;
        }
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn initWithWin32Surface(
        self: *Self,
        hinstance: *anyopaque,
        hwnd: *anyopaque,
        width: u32,
        height: u32,
        scale_factor: f64,
        scene_limits: *const SceneLimits,
    ) !void {
        _ = hinstance;
        std.debug.assert(!self.initialized);
        std.debug.assert(scene_limits.check() == null);

        // Every per-frame instance buffer is sized from the window's budget here,
        // once, before the first frame (CLAUDE.md §2).
        self.instance_capacity = InstanceCapacity.fromSceneLimits(scene_limits);

        // Store scale factor
        self.scale_factor = scale_factor;

        // gooey's win32.HWND is ?*anyopaque; the vendored bindings declare
        // their own opaque HWND. Cast once at the boundary.
        const hwnd_handle: dx11_foundation.HWND = @ptrCast(hwnd);

        // ---- DXGI factory ----
        var factory: *dxgi.IDXGIFactory2 = undefined;
        {
            var raw: *anyopaque = undefined;
            const hr = dxgi.CreateDXGIFactory1(dxgi.IID_IDXGIFactory2, &raw);
            if (hr < 0) return InitError.NoDxgiFactory;
            factory = @ptrCast(@alignCast(raw));
        }
        self.factory = factory;
        errdefer {
            _ = self.factory.?.IUnknown.Release();
            self.factory = null;
        }

        // ---- Adapter (prefer discrete, like the Vulkan device pick) ----
        const adapter: ?*dxgi.IDXGIAdapter1 = pickDiscreteAdapter(factory);
        errdefer if (adapter) |a| {
            _ = a.IUnknown.Release();
        };

        // ---- D3D11 device (feature level 11_1, fallback 11_0) ----
        {
            const levels = [_]d3d_common.D3D_FEATURE_LEVEL{
                d3d_common.D3D_FEATURE_LEVEL_11_1,
                d3d_common.D3D_FEATURE_LEVEL_11_0,
            };
            var feature_level: d3d_common.D3D_FEATURE_LEVEL = undefined;
            const adapter_for_device: ?*dxgi.IDXGIAdapter = if (adapter) |a| @ptrCast(a) else null;
            const driver_type: d3d_common.D3D_DRIVER_TYPE = if (adapter != null)
                // With an explicit adapter the driver type must be UNKNOWN.
                d3d_common.D3D_DRIVER_TYPE_UNKNOWN
            else
                d3d_common.D3D_DRIVER_TYPE_HARDWARE;
            var device_out: *d3d11.ID3D11Device = undefined;
            var context_out: *d3d11.ID3D11DeviceContext = undefined;
            const hr = d3d11.D3D11CreateDevice(
                adapter_for_device,
                driver_type,
                null,
                .{ .BGRA_SUPPORT = 1 },
                &levels,
                levels.len,
                d3d11.D3D11_SDK_VERSION,
                &device_out,
                &feature_level,
                &context_out,
            );
            if (hr < 0) return InitError.DeviceCreationFailed;
            self.device = device_out;
            self.context = context_out;
            std.log.info("DX11: device created, feature level 0x{X:0>4}", .{@backingInt(feature_level)});
        }
        errdefer {
            _ = if (self.context) |c| c.IUnknown.Release();
            self.context = null;
            _ = if (self.device) |d| d.IUnknown.Release();
            self.device = null;
        }

        // ---- Swap chain (FLIP_DISCARD, 3 buffers, B8G8R8A8) ----
        {
            const physical_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale_factor);
            const physical_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale_factor);
            const desc = dxgi.DXGI_SWAP_CHAIN_DESC1{
                .Width = @max(physical_width, 1),
                .Height = @max(physical_height, 1),
                .Format = .B8G8R8A8_UNORM,
                .Stereo = 0,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT,
                .BufferCount = BACK_BUFFER_COUNT,
                .Scaling = .STRETCH,
                .SwapEffect = .FLIP_DISCARD,
                .AlphaMode = .IGNORE,
                .Flags = 0,
            };
            var swap_chain: *dxgi.IDXGISwapChain1 = undefined;
            const hr = factory.CreateSwapChainForHwnd(
                @ptrCast(self.device.?),
                hwnd_handle,
                &desc,
                null,
                null,
                &swap_chain,
            );
            if (hr < 0) return InitError.SwapchainCreationFailed;
            self.swap_chain = swap_chain;
            self.swapchain_width = @max(physical_width, 1);
            self.swapchain_height = @max(physical_height, 1);
        }
        errdefer {
            _ = self.swap_chain.?.IUnknown.Release();
            self.swap_chain = null;
        }

        // Render target chain: backbuffer RTV + MSAA scene target
        try self.createRenderTarget();

        // ---- Shaders ----
        try self.createShaders();

        // ---- Sampler (linear, clamp, non-mips — mirrors vk_descriptors) ----
        {
            const desc = d3d11.D3D11_SAMPLER_DESC{
                .Filter = .MIN_MAG_MIP_LINEAR,
                .AddressU = .CLAMP,
                .AddressV = .CLAMP,
                .AddressW = .CLAMP,
                .MipLODBias = 0,
                .MaxAnisotropy = 1,
                .ComparisonFunc = .NEVER,
                .BorderColor = .{ 0, 0, 0, 0 },
                .MinLOD = 0,
                .MaxLOD = d3d11.D3D11_FLOAT32_MAX,
            };
            var sampler: ?*d3d11.ID3D11SamplerState = null;
            if (self.device.?.CreateSamplerState(&desc, (@ptrCast(&sampler))) < 0 or sampler == null) {
                return InitError.ObjectCreationFailed;
            }
            self.atlas_sampler = sampler;
        }

        // ---- Rasterizer (cull none, no scissor) ----
        {
            const desc = d3d11.D3D11_RASTERIZER_DESC{
                .FillMode = .SOLID,
                .CullMode = .NONE,
                .FrontCounterClockwise = 0,
                .DepthBias = 0,
                .DepthBiasClamp = 0,
                .SlopeScaledDepthBias = 0,
                .DepthClipEnable = 0,
                .ScissorEnable = 0,
                .MultisampleEnable = 1,
                .AntialiasedLineEnable = 0,
            };
            var rs: ?*d3d11.ID3D11RasterizerState = null;
            if (self.device.?.CreateRasterizerState(&desc, (@ptrCast(&rs))) < 0 or rs == null) {
                return InitError.ObjectCreationFailed;
            }
            self.rasterizer = rs;
        }

        // ---- Per-frame instance buffers ----
        for (&self.frames) |*frame| {
            try self.createFrameBuffers(frame);
        }
        try self.createFrameSRVs();

        // Viewport the shaders divide by: logical pixels (Vulkan's
        // updateUniformBuffer receives logical width/height too).
        self.uniform_viewport_width = @floatFromInt(width);
        self.uniform_viewport_height = @floatFromInt(height);

        // Log adapter name for backend A/B comparison
        if (adapter) |a| {
            var desc: dxgi.DXGI_ADAPTER_DESC1 = undefined;
            if (a.GetDesc1(&desc) >= 0) {
                const name_len = std.mem.indexOfScalar(u16, &desc.Description, 0) orelse desc.Description.len;
                const name = std.unicode.utf16LeToUtf8Alloc(self.allocator, desc.Description[0..name_len]) catch "";
                defer if (name.len > 0) self.allocator.free(@constCast(name));
                std.log.info("DX11: adapter = {s}, {d} MiB VRAM", .{
                    name,
                    desc.DedicatedVideoMemory / (1024 * 1024),
                });
            }
            _ = a.IUnknown.Release();
        }

        self.initialized = true;
    }

    fn pickDiscreteAdapter(factory: *dxgi.IDXGIFactory2) ?*dxgi.IDXGIAdapter1 {
        var best: ?*dxgi.IDXGIAdapter1 = null;
        var best_vram: usize = 0;
        var first: ?*dxgi.IDXGIAdapter1 = null;
        var index: u32 = 0;
        while (true) : (index += 1) {
            var adapter: *dxgi.IDXGIAdapter1 = undefined;
            if (factory.IDXGIFactory1.EnumAdapters1(index, &adapter) < 0) break;
            var desc: dxgi.DXGI_ADAPTER_DESC1 = undefined;
            if (adapter.GetDesc1(&desc) >= 0) {
                // Skip software (WARP) adapters: DXGI_ADAPTER_FLAG_SOFTWARE = 2
                if (desc.Flags & 2 == 0) {
                    if (first == null) first = adapter;
                    if (desc.DedicatedVideoMemory > best_vram) {
                        _ = if (best) |b| b.IUnknown.Release();
                        best = adapter;
                        best_vram = desc.DedicatedVideoMemory;
                        continue;
                    }
                }
            }
            _ = adapter.IUnknown.Release();
        }
        if (best != null and first != best) {
            _ = if (first) |f| f.IUnknown.Release();
        }
        return best;
    }

    // =========================================================================
    // Render target management (backbuffer RTV + MSAA target)
    // =========================================================================

    fn createRenderTarget(self: *Self) InitError!void {
        const device = self.device.?;

        // Backbuffer → texture + RTV. The RTV must be created on the QI'd
        // ID3D11Texture2D, not on the IDXGISurface — d3d11 API functions
        // validate the d3d11 interface pointer statically and reject a DXGI
        // interface pointer with E_INVALIDARG even though the COM object is
        // the same.
        var bb_texture: *d3d11.ID3D11Texture2D = undefined;
        {
            const hr = self.swap_chain.?.IDXGISwapChain.GetBuffer(
                0,
                d3d11.IID_ID3D11Texture2D,
                @ptrCast(&bb_texture),
            );
            if (hr < 0) return InitError.BackbufferFailed;
        }
        self.backbuffer_texture = bb_texture;
        errdefer {
            _ = self.backbuffer_texture.?.IUnknown.Release();
            self.backbuffer_texture = null;
        }
        var rtv: ?*d3d11.ID3D11RenderTargetView = null;
        const rtv_hr = device.CreateRenderTargetView(@ptrCast(bb_texture), null, (@ptrCast(&rtv)));
        if (rtv_hr < 0 or rtv == null) {
            std.log.err("DX11: CreateRenderTargetView failed (hr=0x{X:0>8})", .{@as(u32, @bitCast(rtv_hr))});
            return InitError.BackbufferFailed;
        }
        self.backbuffer_rtv = rtv;
        errdefer {
            _ = self.backbuffer_rtv.?.IUnknown.Release();
            self.backbuffer_rtv = null;
        }

        // MSAA scene target — 4x, matching the Vulkan render pass resolve
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = self.swapchain_width,
            .Height = self.swapchain_height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = .B8G8R8A8_TYPELESS,
            .SampleDesc = .{ .Count = MSAA_SAMPLE_COUNT, .Quality = 0 },
            .Usage = .DEFAULT,
            .BindFlags = .{ .RENDER_TARGET = 1 },
            .CPUAccessFlags = .{},
            .MiscFlags = .{},
        };
        var msaa: ?*d3d11.ID3D11Texture2D = null;
        if (device.CreateTexture2D(&desc, null, (@ptrCast(&msaa))) < 0 or msaa == null) {
            return InitError.MsaaTargetFailed;
        }
        self.msaa_texture = msaa;
        errdefer {
            _ = self.msaa_texture.?.IUnknown.Release();
            self.msaa_texture = null;
        }

        const msaa_rtv_desc = d3d11.D3D11_RENDER_TARGET_VIEW_DESC{
            .Format = .B8G8R8A8_UNORM,
            .ViewDimension = .TEXTURE2DMS,
            .Anonymous = .{ .Texture2DMS = .{ .UnusedField_NothingToDefine = 0 } },
        };
        var msaa_rtv: ?*d3d11.ID3D11RenderTargetView = null;
        if (device.CreateRenderTargetView(@ptrCast(msaa.?), &msaa_rtv_desc, (@ptrCast(&msaa_rtv))) < 0 or msaa_rtv == null) {
            return InitError.MsaaTargetFailed;
        }
        self.msaa_rtv = msaa_rtv;
    }

    fn destroyRenderTarget(self: *Self) void {
        _ = if (self.msaa_rtv) |v| v.IUnknown.Release();
        self.msaa_rtv = null;
        _ = if (self.msaa_texture) |t| t.IUnknown.Release();
        self.msaa_texture = null;
        _ = if (self.backbuffer_rtv) |v| v.IUnknown.Release();
        self.backbuffer_rtv = null;
        _ = if (self.backbuffer_texture) |t| t.IUnknown.Release();
        self.backbuffer_texture = null;
    }

    // =========================================================================
    // Shaders
    // =========================================================================

    const CompiledShader = struct {
        vs: ?*d3d11.ID3D11VertexShader = null,
        ps: ?*d3d11.ID3D11PixelShader = null,
        vs_blob: ?*d3d_common.ID3DBlob = null,
        layout: ?*d3d11.ID3D11InputLayout = null,
    };

    /// Compile one HLSL file's vs_main/ps_main and create the device objects.
    fn compileShaders(
        self: *Self,
        source: []const u8,
        name: [:0]const u8,
    ) InitError!CompiledShader {
        const device = self.device.?;
        const d3d_compile = try loadD3DCompile();
        var out = CompiledShader{};

        // VS first (its bytecode also feeds the input layout)
        var vs_blob: ?*d3d_common.ID3DBlob = null;
        var err_blob: ?*d3d_common.ID3DBlob = null;
        var hr = d3d_compile(
            source.ptr,
            source.len,
            name.ptr,
            null,
            null,
            "vs_main",
            "vs_5_0",
            d3d11_compile_flags,
            0,
            (@ptrCast(&vs_blob)),
            (@ptrCast(&err_blob)),
        );
        if (hr < 0) {
            logCompileError(name, "vs_main", err_blob);
            return InitError.ShaderCompileFailed;
        }
        out.vs_blob = vs_blob;

        const vs_code: [*]const u8 = @ptrCast(vs_blob.?.GetBufferPointer());
        const vs_size: usize = vs_blob.?.GetBufferSize();
        var vs_out: *d3d11.ID3D11VertexShader = undefined;
        hr = device.CreateVertexShader(vs_code, vs_size, null, &vs_out);
        out.vs = vs_out;
        if (hr < 0 or out.vs == null) return InitError.ShaderObjectFailed;

        // Input layout: no vertex buffers exist (SV_VertexID quads), but D3D11
        // still requires a layout handle bound with the VS.
        const layout_desc = [_]d3d11.D3D11_INPUT_ELEMENT_DESC{};
        var layout_out: *d3d11.ID3D11InputLayout = undefined;
        hr = device.CreateInputLayout(
            &layout_desc,
            0,
            vs_code,
            vs_size,
            &layout_out,
        );
        out.layout = layout_out;
        if (hr < 0 or out.layout == null) return InitError.ShaderObjectFailed;

        // PS
        var ps_blob: ?*d3d_common.ID3DBlob = null;
        err_blob = null;
        hr = d3d_compile(
            source.ptr,
            source.len,
            name.ptr,
            null,
            null,
            "ps_main",
            "ps_5_0",
            d3d11_compile_flags,
            0,
            (@ptrCast(&ps_blob)),
            (@ptrCast(&err_blob)),
        );
        if (hr < 0) {
            logCompileError(name, "ps_main", err_blob);
            return InitError.ShaderCompileFailed;
        }
        defer {
            if (ps_blob) |b| _ = b.IUnknown.Release();
        }

        var ps_out: *d3d11.ID3D11PixelShader = undefined;
        hr = device.CreatePixelShader(
            @ptrCast(ps_blob.?.GetBufferPointer()),
            ps_blob.?.GetBufferSize(),
            null,
            &ps_out,
        );
        out.ps = ps_out;
        if (hr < 0 or out.ps == null) return InitError.ShaderObjectFailed;

        return out;
    }

    const d3d11_compile_flags: u32 = fxc.D3DCOMPILE_ENABLE_STRICTNESS |
        fxc.D3DCOMPILE_OPTIMIZATION_LEVEL3;

    // ---------------------------------------------------------------------------
    // Runtime shader-compiler loader. The mingw toolchain has no d3dcompiler
    // import library under a consistent name, and importing the Windows SDK's
    // would reintroduce an SDK dependency; d3dcompiler_47.dll is a guaranteed
    // system component (Windows 8.1+), so GetProcAddress keeps the zero-SDK
    // model intact. Signature mirrors fxc.D3DCompile.
    // ---------------------------------------------------------------------------
    const D3DCompileProc = *const fn (
        pSrcData: ?*const anyopaque,
        SrcDataSize: usize,
        pSourceName: ?[*:0]const u8,
        pDefines: ?*const d3d_common.D3D_SHADER_MACRO,
        pInclude: ?*d3d_common.ID3DInclude,
        pEntrypoint: ?[*:0]const u8,
        pTarget: ?[*:0]const u8,
        Flags1: u32,
        Flags2: u32,
        ppCode: ?*?*d3d_common.ID3DBlob,
        ppErrorMsgs: ?*?*d3d_common.ID3DBlob,
    ) callconv(.winapi) dx11_foundation.HRESULT;

    var d3d_compile_proc: ?D3DCompileProc = null;

    fn loadD3DCompile() InitError!D3DCompileProc {
        if (d3d_compile_proc) |proc| return proc;
        const module = win32.LoadLibraryA("d3dcompiler_47.dll");
        const raw = win32.GetProcAddress(module, "D3DCompile") orelse {
            std.log.err("DX11: d3dcompiler_47.dll!D3DCompile not found", .{});
            return InitError.ShaderCompilerMissing;
        };
        const proc: D3DCompileProc = @ptrCast(@alignCast(raw));
        d3d_compile_proc = proc;
        return proc;
    }

    fn logCompileError(name: [:0]const u8, entry: [:0]const u8, err_blob: ?*d3d_common.ID3DBlob) void {
        if (err_blob) |blob| {
            const msg_len = blob.GetBufferSize();
            const msg: [*]const u8 = @ptrCast(blob.GetBufferPointer());
            std.log.err("DX11 shader compile failed ({s} / {s}):{s}", .{
                name,
                entry,
                msg[0..msg_len],
            });
        }
    }

    fn createShaders(self: *Self) InitError!void {
        const unified_shaders = try self.compileShaders(unified_hlsl, "unified.hlsl");
        self.unified_vs = unified_shaders.vs;
        self.unified_ps = unified_shaders.ps;
        self.unified_layout = unified_shaders.layout;

        const text = try self.compileShaders(text_hlsl, "text.hlsl");
        self.text_vs = text.vs;
        self.text_ps = text.ps;
        self.text_layout = text.layout;

        const svg = try self.compileShaders(svg_hlsl, "svg.hlsl");
        self.svg_vs = svg.vs;
        self.svg_ps = svg.ps;
        self.svg_layout = svg.layout;

        const image = try self.compileShaders(image_hlsl, "image.hlsl");
        self.image_vs = image.vs;
        self.image_ps = image.ps;
        self.image_layout = image.layout;

        // Blend states
        const blend_target = d3d11.D3D11_RENDER_TARGET_BLEND_DESC{
            .BlendEnable = 1,
            .SrcBlend = .SRC_ALPHA,
            .DestBlend = .INV_SRC_ALPHA,
            .BlendOp = .ADD,
            .SrcBlendAlpha = .ONE,
            .DestBlendAlpha = .INV_SRC_ALPHA,
            .BlendOpAlpha = .ADD,
            .RenderTargetWriteMask = 0xF,
        };
        {
            var desc = std.mem.zeroInit(d3d11.D3D11_BLEND_DESC, .{});
            // Independent blend is unnecessary: one target, same state.
            desc.RenderTarget[0] = blend_target;
            var blend: ?*d3d11.ID3D11BlendState = null;
            if (self.device.?.CreateBlendState(&desc, (@ptrCast(&blend))) < 0 or blend == null) {
                return InitError.ObjectCreationFailed;
            }
            self.standard_blend = blend;
        }
        {
            // SVG outputs pre-multiplied color (src=ONE) — mirrors vk_pipelines
            var desc = std.mem.zeroInit(d3d11.D3D11_BLEND_DESC, .{});
            desc.RenderTarget[0] = blend_target;
            desc.RenderTarget[0].SrcBlend = .ONE;
            var blend: ?*d3d11.ID3D11BlendState = null;
            if (self.device.?.CreateBlendState(&desc, (@ptrCast(&blend))) < 0 or blend == null) {
                return InitError.ObjectCreationFailed;
            }
            self.premultiplied_blend = blend;
        }
    }

    fn destroyShaders(self: *Self) void {
        _ = if (self.unified_vs) |s| s.IUnknown.Release();
        _ = if (self.unified_ps) |s| s.IUnknown.Release();
        _ = if (self.unified_layout) |l| l.IUnknown.Release();
        _ = if (self.text_vs) |s| s.IUnknown.Release();
        _ = if (self.text_ps) |s| s.IUnknown.Release();
        _ = if (self.text_layout) |l| l.IUnknown.Release();
        _ = if (self.svg_vs) |s| s.IUnknown.Release();
        _ = if (self.svg_ps) |s| s.IUnknown.Release();
        _ = if (self.svg_layout) |l| l.IUnknown.Release();
        _ = if (self.image_vs) |s| s.IUnknown.Release();
        _ = if (self.image_ps) |s| s.IUnknown.Release();
        _ = if (self.image_layout) |l| l.IUnknown.Release();
        _ = if (self.standard_blend) |b| b.IUnknown.Release();
        _ = if (self.premultiplied_blend) |b| b.IUnknown.Release();
        _ = if (self.atlas_sampler) |s| s.IUnknown.Release();
        _ = if (self.rasterizer) |r| r.IUnknown.Release();
        self.unified_vs = null;
        self.unified_ps = null;
        self.unified_layout = null;
        self.text_vs = null;
        self.text_ps = null;
        self.text_layout = null;
        self.svg_vs = null;
        self.svg_ps = null;
        self.svg_layout = null;
        self.image_vs = null;
        self.image_ps = null;
        self.image_layout = null;
        self.standard_blend = null;
        self.premultiplied_blend = null;
        self.atlas_sampler = null;
        self.rasterizer = null;
    }

    // =========================================================================
    // Per-frame buffers
    // =========================================================================

    fn createFrameBuffers(self: *Self, frame: *FrameResources) !void {
        frame.uniform_buffer = try self.createConstantBuffer();
        frame.draw_base_buffer = try self.createConstantBuffer();
        // Structured buffers carry their element stride in the descriptor:
        // primitive = unified.Primitive (128B), glyph/svg/image = vk_types.
        frame.primitive_buffer = try self.createStructuredBuffer(@intCast(self.instance_capacity.bufferBytes(.primitives)), @sizeOf(unified.Primitive));
        frame.glyph_buffer = try self.createStructuredBuffer(@intCast(self.instance_capacity.bufferBytes(.glyphs)), @sizeOf(vk_types.GpuGlyph));
        frame.svg_buffer = try self.createStructuredBuffer(@intCast(self.instance_capacity.bufferBytes(.svgs)), @sizeOf(vk_types.GpuSvg));
        frame.image_buffer = try self.createStructuredBuffer(@intCast(self.instance_capacity.bufferBytes(.images)), @sizeOf(vk_types.GpuImage));
    }

    fn createConstantBuffer(self: *Self) !*d3d11.ID3D11Buffer {
        const desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = @sizeOf(Uniforms),
            .Usage = .DYNAMIC,
            .BindFlags = .{ .CONSTANT_BUFFER = 1 },
            .CPUAccessFlags = .{ .WRITE = 1 },
            .MiscFlags = .{},
            .StructureByteStride = 0,
        };
        var buffer: ?*d3d11.ID3D11Buffer = null;
        if (self.device.?.CreateBuffer(&desc, null, (@ptrCast(&buffer))) < 0 or buffer == null) {
            return error.BufferCreationFailed;
        }
        return buffer.?;
    }

    fn createStructuredBuffer(self: *Self, byte_width: u32, stride: u32) !*d3d11.ID3D11Buffer {
        const desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = byte_width,
            .Usage = .DYNAMIC,
            .BindFlags = .{ .SHADER_RESOURCE = 1 },
            .CPUAccessFlags = .{ .WRITE = 1 },
            .MiscFlags = .{ .BUFFER_STRUCTURED = 1 },
            .StructureByteStride = stride,
        };
        var buffer: ?*d3d11.ID3D11Buffer = null;
        if (self.device.?.CreateBuffer(&desc, null, (@ptrCast(&buffer))) < 0 or buffer == null) {
            return error.BufferCreationFailed;
        }
        return buffer.?;
    }

    /// Per-frame SRVs over every slot's structured buffers (t0). Each slot's
    /// views always read exactly the buffers that slot's WRITE_DISCARD map
    /// replaced, so no slot can observe another's stale rows.
    fn createFrameSRVs(self: *Self) !void {
        for (&self.frame_srvs, 0..) |*srvs, i| {
            const frame = &self.frames[i];
            srvs.primitive = try self.createBufferSRV(frame.primitive_buffer.?);
            srvs.glyph = try self.createBufferSRV(frame.glyph_buffer.?);
            srvs.svg = try self.createBufferSRV(frame.svg_buffer.?);
            srvs.image = try self.createBufferSRV(frame.image_buffer.?);
        }
    }

    fn createBufferSRV(self: *Self, buffer: *d3d11.ID3D11Buffer) !*d3d11.ID3D11ShaderResourceView {
        // Structured buffers: format UNKNOWN + BufferEx view. NumElements is
        // required (no "0 = all" semantics on BufferEx) — derive it from the
        // buffer's own descriptor so the view always covers the full storage.
        var buf_desc: d3d11.D3D11_BUFFER_DESC = undefined;
        buffer.GetDesc(&buf_desc);
        std.debug.assert(buf_desc.StructureByteStride > 0);
        const element_count = buf_desc.ByteWidth / buf_desc.StructureByteStride;

        var desc: d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC = undefined;
        desc.Format = .UNKNOWN;
        desc.ViewDimension = d3d_common.D3D_SRV_DIMENSION_BUFFEREX;
        desc.Anonymous = .{ .BufferEx = .{ .FirstElement = 0, .NumElements = element_count, .Flags = 0 } };
        var view: ?*d3d11.ID3D11ShaderResourceView = null;
        if (self.device.?.CreateShaderResourceView(@ptrCast(buffer), &desc, (@ptrCast(&view))) < 0 or view == null) {
            return error.SRVCreationFailed;
        }
        return view.?;
    }

    fn destroyFrameSRVs(self: *Self) void {
        for (&self.frame_srvs) |*srvs| {
            _ = if (srvs.primitive) |v| v.IUnknown.Release();
            _ = if (srvs.glyph) |v| v.IUnknown.Release();
            _ = if (srvs.svg) |v| v.IUnknown.Release();
            _ = if (srvs.image) |v| v.IUnknown.Release();
            srvs.* = .{};
        }
    }

    /// Map a frame's dynamic buffer for CPU writes. WRITE_DISCARD discards
    /// the previous contents, matching the Vulkan per-frame full rewrite.
    fn mapFrameBuffer(self: *Self, buffer: *d3d11.ID3D11Buffer) ?[*]u8 {
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr = self.context.?.Map(@ptrCast(buffer), 0, .WRITE_DISCARD, 0, &mapped);
        if (hr < 0) return null;
        return @ptrCast(mapped.pData);
    }

    // =========================================================================
    // Resize
    // =========================================================================

    /// Set the color the target is cleared with. Recorded into the next
    /// frame rather than applied immediately: frames in flight must keep the
    /// clear they were drawn with (mirrors VulkanRenderer.setClearColor).
    pub fn setClearColor(self: *Self, color: geometry.Color) void {
        std.debug.assert(color.a >= 0.0);
        std.debug.assert(color.a <= 1.0);
        self.clear_color = color;
    }

    /// Resize the renderer (recreates the swapchain-sized targets).
    /// width/height are logical pixels, scale_factor converts to physical.
    pub fn resize(self: *Self, width: u32, height: u32, scale_factor: f64) void {
        if (!self.initialized) return;
        if (width == 0 or height == 0) return;

        self.scale_factor = scale_factor;

        // The shaders divide positions by the LOGICAL viewport (matches
        // vk_renderer.updateUniformBuffer); the physical size only sets the
        // raster viewport via the swapchain.
        self.uniform_viewport_width = @floatFromInt(width);
        self.uniform_viewport_height = @floatFromInt(height);

        const physical_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale_factor);
        const physical_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale_factor);
        if (physical_width == self.swapchain_width and physical_height == self.swapchain_height) {
            return;
        }

        self.recreateTargets(physical_width, physical_height) catch |err| {
            std.debug.print("DX11: failed to recreate targets on resize: {}\n", .{err});
        };
    }

    fn recreateTargets(self: *Self, width: u32, height: u32) !void {
        // Release render-target-bound views before ResizeBuffers (required).
        self.destroyRenderTarget();

        const new_width: u32 = @max(width, 1);
        const new_height: u32 = @max(height, 1);
        const hr = self.swap_chain.?.IDXGISwapChain.ResizeBuffers(
            BACK_BUFFER_COUNT,
            new_width,
            new_height,
            .B8G8R8A8_UNORM,
            0,
        );
        if (hr < 0) return error.ResizeBuffersFailed;
        self.swapchain_width = new_width;
        self.swapchain_height = new_height;

        try self.createRenderTarget();
    }

    // =========================================================================
    // Atlas Upload — per-atlas staging textures
    //
    // Flow mirrors the Vulkan renderer: stageXxxAtlas() stores data pointers
    // → render() consumes them. Vulkan's shared 144MB staging buffer +
    // command-buffer copies become per-atlas STAGING textures: Map(WRITE) →
    // write tight dirty rows → Unmap → CopySubresourceRegion (dirty box).
    // D3D11 runtime sync replaces the explicit barriers.
    // =========================================================================

    /// Notify renderer that the text atlas has new data. Call before render().
    /// The data pointer must remain valid until render() returns.
    pub fn stageTextAtlas(self: *Self, data: []const u8, width: u32, height: u32, dirty: ?dx11_atlas.DirtyRegion) void {
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height));
        std.debug.assert(width > 0 and height > 0);
        self.pending_text = .{ .data = data, .width = width, .height = height, .format = .r8, .dirty = dirty, .active = true };
    }

    /// Notify renderer that the SVG atlas has new data. Call before render().
    pub fn stageSvgAtlas(self: *Self, data: []const u8, width: u32, height: u32, dirty: ?dx11_atlas.DirtyRegion) void {
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height) * 4);
        std.debug.assert(width > 0 and height > 0);
        self.pending_svg = .{ .data = data, .width = width, .height = height, .format = .rgba8, .dirty = dirty, .active = true };
    }

    /// Notify renderer that the image atlas has new data. Call before render().
    pub fn stageImageAtlas(self: *Self, data: []const u8, width: u32, height: u32, dirty: ?dx11_atlas.DirtyRegion) void {
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height) * 4);
        std.debug.assert(width > 0 and height > 0);
        self.pending_image = .{ .data = data, .width = width, .height = height, .format = .rgba8, .dirty = dirty, .active = true };
    }

    fn processAtlasUploads(self: *Self, transfers: *[MAX_ATLAS_TRANSFERS]AtlasTransferRecord, count: *u32) void {
        self.processSingleUpload(&self.pending_text, &self.text_atlas, transfers, count);
        self.processSingleUpload(&self.pending_svg, &self.svg_atlas, transfers, count);
        self.processSingleUpload(&self.pending_image, &self.image_atlas, transfers, count);
    }

    fn processSingleUpload(
        self: *Self,
        pending: *PendingUpload,
        resources: *dx11_atlas.AtlasResources,
        transfers: *[MAX_ATLAS_TRANSFERS]AtlasTransferRecord,
        count: *u32,
    ) void {
        if (!pending.active) return;
        defer pending.active = false;

        std.debug.assert(pending.width > 0 and pending.height > 0);
        std.debug.assert(count.* < MAX_ATLAS_TRANSFERS);

        // (Re)create the atlas texture if dimensions changed or it doesn't exist
        const image_recreated = dx11_atlas.ensureAtlasImage(
            resources,
            pending.width,
            pending.height,
            pending.format,
            self.device.?,
        ) catch |err| {
            std.log.err("DX11: atlas texture creation failed: {}", .{err});
            return;
        };

        // Full upload on (re)creation to initialize the entire texture;
        // dirty-rect-only otherwise. Skip if no dirty region and no resize.
        const dirty: dx11_atlas.DirtyRegion = if (image_recreated)
            .{ .x = 0, .y = 0, .width = pending.width, .height = pending.height }
        else
            (pending.dirty orelse return);

        // Write the dirty rows into the atlas's staging texture
        const context = self.context.?;
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        const map_hr = context.Map(@ptrCast(resources.staging.?), 0, .WRITE, 0, &mapped);
        if (map_hr < 0) {
            std.log.err("DX11: atlas staging Map failed (hr=0x{X:0>8})", .{@as(u32, @bitCast(map_hr))});
            return;
        }
        dx11_atlas.stageDirtyRegion(
            @ptrCast(mapped.pData),
            mapped.RowPitch,
            pending.data,
            pending.width,
            pending.format,
            dirty,
        );
        context.Unmap(@ptrCast(resources.staging.?), 0);

        transfers[count.*] = .{ .resources = resources, .dirty = dirty };
        count.* += 1;
    }

    fn recordAtlasTransfers(self: *Self, transfers: []const AtlasTransferRecord) void {
        for (transfers) |t| {
            dx11_atlas.recordPartialAtlasTransfer(
                self.context.?,
                t.resources.texture.?,
                t.resources.staging.?,
                t.dirty,
            );
        }
    }

    // =========================================================================
    // Render
    // =========================================================================

    /// Render a frame: atlas uploads + batched draws + resolve + present.
    pub fn render(self: *Self, scene: *const Scene) void {
        if (!self.initialized) return;
        if (self.device_lost) return; // skip until the window recreates us
        assertSceneFitsCapacity(&scene.limits, &self.instance_capacity);

        const context = self.context.?;
        const frame = &self.frames[self.current_frame];

        // ---- Atlas uploads ----
        var transfer_count: u32 = 0;
        var transfers: [MAX_ATLAS_TRANSFERS]AtlasTransferRecord = undefined;
        self.processAtlasUploads(&transfers, &transfer_count);
        self.recordAtlasTransfers(transfers[0..transfer_count]);

        // ---- Instance buffers: map + let fillScene fill ----
        // WRITE_DISCARD per frame mirrors the Vulkan per-frame storage
        // buffer rewrite. The mapped pointers are handed to fillScene. The
        // buffers must be UNMAPPED before the Draw calls run: D3D11 silently
        // drops draws whose SRVs reference a mapped resource, which showed
        // up as a blank window when the fill and submit ran interleaved.
        self.mapped_primitive = self.mapFrameBuffer(frame.primitive_buffer.?);
        self.mapped_glyph = self.mapFrameBuffer(frame.glyph_buffer.?);
        self.mapped_svg = self.mapFrameBuffer(frame.svg_buffer.?);
        self.mapped_image = self.mapFrameBuffer(frame.image_buffer.?);

        // ---- Uniforms (16B, logical pixels — same as Vulkan's UBO) ----
        if (self.mapFrameBuffer(frame.uniform_buffer.?)) |ptr| {
            const dest: *Uniforms = @ptrCast(@alignCast(ptr));
            dest.* = .{
                .viewport_width = self.uniform_viewport_width,
                .viewport_height = self.uniform_viewport_height,
            };
            context.Unmap(@ptrCast(frame.uniform_buffer.?), 0);
        }

        // ---- Bind target + global state ----
        const viewport = d3d11.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(self.swapchain_width),
            .Height = @floatFromInt(self.swapchain_height),
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        const viewports = [_]d3d11.D3D11_VIEWPORT{viewport};
        context.RSSetViewports(1, &viewports);
        context.RSSetState(self.rasterizer.?);
        var rtvs = [_]?*d3d11.ID3D11RenderTargetView{self.msaa_rtv.?};
        context.OMSetRenderTargets(1, &rtvs, null);
        const clear = self.clear_color;
        const clear_rgba = [4]f32{ clear.r, clear.g, clear.b, clear.a };
        context.ClearRenderTargetView(self.msaa_rtv.?, @ptrCast(&clear_rgba));

        // Primitive topology: triangle list, no vertex buffers (SV_VertexID)
        context.IASetPrimitiveTopology(d3d_common.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        // ---- Fill: walk the scene, write instance rows while mapped ----
        const fills = scene_renderer.FillResources{
            .primitive_mapped = self.mapped_primitive,
            .glyph_mapped = self.mapped_glyph,
            .svg_mapped = self.mapped_svg,
            .image_mapped = self.mapped_image,
            .capacity = self.instance_capacity,
            .frame = scene.frame_count_finished,
        };
        const submits = scene_renderer.fillScene(scene, fills);

        // ---- Unmap before submitting: mapped SRVs void every draw ----
        context.Unmap(@ptrCast(frame.primitive_buffer.?), 0);
        context.Unmap(@ptrCast(frame.glyph_buffer.?), 0);
        context.Unmap(@ptrCast(frame.svg_buffer.?), 0);
        context.Unmap(@ptrCast(frame.image_buffer.?), 0);
        self.mapped_primitive = null;
        self.mapped_glyph = null;
        self.mapped_svg = null;
        self.mapped_image = null;

        // ---- Submit: draw what fillScene recorded ----
        // This slot's own SRVs — the WRITE_DISCARD map replaced exactly the
        // buffers they view.
        const srvs = &self.frame_srvs[self.current_frame];
        const pipelines = scene_renderer.Pipelines{
            .unified_vs = self.unified_vs,
            .unified_ps = self.unified_ps,
            .text_vs = self.text_vs,
            .text_ps = self.text_ps,
            .svg_vs = self.svg_vs,
            .svg_ps = self.svg_ps,
            .image_vs = self.image_vs,
            .image_ps = self.image_ps,
            .unified_layout = self.unified_layout,
            .text_layout = self.text_layout,
            .svg_layout = self.svg_layout,
            .image_layout = self.image_layout,
            .standard_blend = self.standard_blend,
            .premultiplied_blend = self.premultiplied_blend,
            .uniform_buffer = frame.uniform_buffer,
            .base_buffer = frame.draw_base_buffer,
            .primitive_srv = srvs.primitive,
            .glyph_srv = srvs.glyph,
            .svg_srv = srvs.svg,
            .image_srv = srvs.image,
            .atlas_view = self.text_atlas.view,
            .svg_atlas_view = self.svg_atlas.view,
            .image_atlas_view = self.image_atlas.view,
            .atlas_sampler = self.atlas_sampler,
        };
        _ = scene_renderer.submitScene(context, submits, pipelines);

        // ---- Resolve MSAA → backbuffer → present ----
        context.ResolveSubresource(
            @ptrCast(self.backbuffer_texture.?),
            0,
            @ptrCast(self.msaa_texture.?),
            0,
            .B8G8R8A8_UNORM,
        );
        const present_hr = self.swap_chain.?.IDXGISwapChain.Present(1, 0); // vsync interval 1
        if (present_hr < 0) {
            const hr_u: u32 = @bitCast(present_hr);
            // Device-removed errors stop drawing (gpui-style skip_draws; full
            // rebuild out of scope). Other errors are logged and tolerated.
            if (hr_u == @as(u32, @bitCast(dxgi.DXGI_ERROR_DEVICE_REMOVED)) or
                hr_u == @as(u32, @bitCast(dxgi.DXGI_ERROR_DEVICE_HUNG)) or
                hr_u == @as(u32, @bitCast(dxgi.DXGI_ERROR_DEVICE_RESET)))
            {
                std.log.err("DX11: device lost (hr=0x{X:0>8}); skipping frames", .{hr_u});
                self.device_lost = true;
            } else {
                std.debug.print("DX11: Present failed (hr=0x{X:0>8})\n", .{hr_u});
            }
        }

        self.current_frame = (self.current_frame + 1) % FRAME_COUNT;
    }

    /// The renderer never truncates a frame, so the scene it draws must not be
    /// able to outgrow the buffers sized at init: the window's scenes and its
    /// renderer share one budget. A larger scene budget is a programmer error.
    fn assertSceneFitsCapacity(
        scene_limits: *const SceneLimits,
        capacity: *const InstanceCapacity,
    ) void {
        std.debug.assert(scene_limits.unifiedPrimitiveCountMax() <= capacity.primitive_count_max);
        std.debug.assert(scene_limits.glyph_count_frame_max <= capacity.glyph_count_max);
        std.debug.assert(scene_limits.svg_count_frame_max <= capacity.svg_count_max);
        std.debug.assert(scene_limits.image_count_frame_max <= capacity.image_count_max);
    }
};

// ===========================================================================
// Tests — pure logic and regression guards, no D3D11 device required. They
// run with `zig build test -Dgpu-backend=dx11` (the comptime backend switch
// in window.zig only compiles this file for the dx11 branch).
// ===========================================================================

const testing = std.testing;

test "uniform block stays 16 bytes (matches vk_types.Uniforms layout)" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Uniforms));
}

test "PS input signatures keep SV_Position (driver VS→PS register remap bug)" {
    // Without SV_Position in the PS input signature, this driver wires
    // TEXCOORD0 to the wrong register and every varying reads back as 0.
    // The compiler keeps a declared-but-unused SV_Position, so the fix is a
    // bare declaration in each PSIn. If someone removes it, this fails.
    inline for (.{ unified_hlsl, text_hlsl, svg_hlsl, image_hlsl }) |src| {
        const psin_pos = std.mem.indexOf(u8, src, "struct PSIn").?;
        const block_end = std.mem.indexOfPos(u8, src, psin_pos, "};").?;
        const block = src[psin_pos..block_end];
        try testing.expect(std.mem.indexOf(u8, block, "SV_Position") != null);
    }
}

test "vertex shaders offset instance rows via b1 base_iid" {
    // SV_VertexID does not include the draw's StartVertexLocation on all
    // drivers, so batch ranges must arrive through the DrawBase cbuffer and
    // draws must start at vertex 0. Guards both halves of that contract.
    inline for (.{ unified_hlsl, text_hlsl, svg_hlsl, image_hlsl }) |src| {
        try testing.expect(std.mem.indexOf(u8, src, "base_iid + vertex_index / 6") != null);
        try testing.expect(std.mem.indexOf(u8, src, "cbuffer DrawBase : register(b1)") != null);
    }
}

test "vendor COM struct layouts match the D3D11 SDK sizes" {
    // Key descriptors the renderer builds by hand; a layout drift here
    // corrupts every Create* call silently.
    try testing.expectEqual(@as(usize, 24), @sizeOf(d3d11.D3D11_BUFFER_DESC));
    try testing.expectEqual(@as(usize, 44), @sizeOf(d3d11.D3D11_TEXTURE2D_DESC));
    try testing.expectEqual(@as(usize, 24), @sizeOf(d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC));
    try testing.expectEqual(@as(usize, 24), @sizeOf(d3d11.D3D11_VIEWPORT));
    try testing.expectEqual(@as(usize, 16), @sizeOf(d3d11.D3D11_MAPPED_SUBRESOURCE));
}

test {
    // Pull in sibling files' test decls. Test collection only reaches files
    // through imports the test build actually analyzes; dx11_scene_renderer's
    // fill/record layer is referenced lazily (only from render paths tests
    // never call), so without this bridge its tests never run.
    _ = scene_renderer;
    _ = dx11_atlas;
}
