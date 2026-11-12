//! GPU objects the DirectX 11 renderer creates once, at initialization: the
//! atlas textures, the per-frame instance and uniform buffers, and the fixed
//! pipeline states. None is created, grown, or replaced after the window's
//! initialization boundary (CLAUDE.md §2); `deinit` is the only release.
//!
//! Instance buffers are `D3D11_USAGE_DYNAMIC` structured buffers, written
//! with `Map(WRITE_DISCARD)`, one set per frame in flight. Frame `n` writes
//! set `n mod frame_count`, which the GPU last read `frame_count` frames ago;
//! the swapchain's frame latency waitable keeps at most `frame_count - 1`
//! frames queued, so that read has retired before the map, and the driver
//! hands back the same memory instead of renaming the buffer.
//!
//! Atlas textures are `D3D11_USAGE_DEFAULT`, sized from `AtlasLimits`, and
//! written only on the GPU, by `dx11_uploads.zig` drawing the journal's
//! records into them as render targets, so Gooey keeps no CPU copy of atlas
//! pixels (memory budget decision 8).

const std = @import("std");
const d3d11 = @import("d3d11.zig");
const dx11_device = @import("dx11_device.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.dx11);
const hex = dx11_device.hex;

/// The largest texture side every feature level 11_0 device supports
/// (`D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION`).
pub const texture_side_px_max: u32 = 16_384;

/// The largest buffer every device accepts: the resource size limit is at
/// least `D3D11_REQ_RESOURCE_SIZE_IN_MEGABYTES_EXPRESSION_A_TERM`, 128 MiB.
pub const buffer_bytes_max: u32 = 128 << 20;

pub const ResourceError = error{Dx11ResourceCreationFailed};

pub const AtlasFormat = enum {
    /// One coverage byte per pixel: glyphs.
    r8,
    /// Straight RGBA, four bytes per pixel: SVG icons and images.
    rgba8,

    pub fn bytesPerPixel(self: AtlasFormat) u32 {
        return switch (self) {
            .r8 => 1,
            .rgba8 => 4,
        };
    }

    fn dxgiFormat(self: AtlasFormat) u32 {
        return switch (self) {
            .r8 => d3d11.DXGI_FORMAT_R8_UNORM,
            .rgba8 => d3d11.DXGI_FORMAT_R8G8B8A8_UNORM,
        };
    }
};

/// One square atlas texture, the view the pixel shaders sample it through,
/// and the render target view uploads draw into.
pub const Atlas = struct {
    texture: *d3d11.ID3D11Texture2D,
    view: *d3d11.ID3D11ShaderResourceView,
    target: *d3d11.ID3D11RenderTargetView,
    side_px: u32,
    format: AtlasFormat,

    pub fn create(
        device: *const dx11_device.Device,
        side_px: u32,
        format: AtlasFormat,
    ) ResourceError!Atlas {
        assert(side_px > 0);
        assert(side_px <= texture_side_px_max);
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = side_px,
            .Height = side_px,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = format.dxgiFormat(),
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d11.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE | d3d11.D3D11_BIND_RENDER_TARGET,
            .CPUAccessFlags = 0,
            .MiscFlags = 0,
        };
        var texture: ?*d3d11.ID3D11Texture2D = null;
        // No initial data, so the contents start undefined. The shaders
        // sample only placed items, which the journal writes with a zeroed
        // 1 px border, so no undefined texel is ever filtered in.
        const result = device.device.vtable.CreateTexture2D(device.device, &desc, null, &texture);
        if (!d3d11.succeeded(result)) {
            log.err("CreateTexture2D(atlas {d}x{d} {s}) failed: 0x{X:0>8}", .{
                side_px,
                side_px,
                @tagName(format),
                hex(result),
            });
            return error.Dx11ResourceCreationFailed;
        }
        errdefer texture.?.release();

        const view = try createView(device, texture.?.resource(), "atlas");
        errdefer view.release();

        var target: ?*d3d11.ID3D11RenderTargetView = null;
        const vtable = device.device.vtable;
        const target_result = vtable.CreateRenderTargetView(
            device.device,
            texture.?.resource(),
            null,
            &target,
        );
        if (!d3d11.succeeded(target_result)) {
            log.err("CreateRenderTargetView(atlas) failed: 0x{X:0>8}", .{hex(target_result)});
            return error.Dx11ResourceCreationFailed;
        }
        assert(target != null);
        return .{
            .texture = texture.?,
            .view = view,
            .target = target.?,
            .side_px = side_px,
            .format = format,
        };
    }

    pub fn release(self: *Atlas) void {
        assert(self.side_px > 0);
        self.target.release();
        self.view.release();
        self.texture.release();
        self.* = undefined;
    }
};

/// A dynamic structured buffer the vertex shaders index by instance, and its
/// view. `stride_bytes` must match the HLSL struct the shader reads.
pub const InstanceBuffer = struct {
    buffer: *d3d11.ID3D11Buffer,
    view: *d3d11.ID3D11ShaderResourceView,
    count_max: u32,
    stride_bytes: u32,

    pub const Options = struct {
        /// Names the pool in failure messages.
        name: []const u8,
        count_max: u32,
        stride_bytes: u32,
    };

    pub fn create(
        device: *const dx11_device.Device,
        options: Options,
    ) ResourceError!InstanceBuffer {
        assert(options.count_max > 0);
        // Structured buffer strides are multiples of 4 bytes, at most 2 KiB.
        assert(options.stride_bytes % 4 == 0);
        assert(options.stride_bytes <= 2048);
        // Every pool a valid `ResourceLimits` can request stays below the
        // floor, as for the Vulkan renderer's storage buffers, whose
        // guaranteed range is the same 2^27 bytes.
        const bytes = @as(u64, options.count_max) * options.stride_bytes;
        assert(bytes <= buffer_bytes_max);
        const desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = @intCast(bytes),
            .Usage = d3d11.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
            .MiscFlags = d3d11.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
            .StructureByteStride = options.stride_bytes,
        };
        const buffer = try createBuffer(device, &desc, options.name);
        errdefer buffer.release();

        const view = try createView(device, buffer.resource(), options.name);
        return .{
            .buffer = buffer,
            .view = view,
            .count_max = options.count_max,
            .stride_bytes = options.stride_bytes,
        };
    }

    pub fn release(self: *InstanceBuffer) void {
        assert(self.count_max > 0);
        self.view.release();
        self.buffer.release();
        self.* = undefined;
    }

    /// Replace the buffer's contents with `instances`, which must fit. The
    /// bytes past them are left as the driver hands them back; the shaders
    /// never index past the draw counts written with them.
    pub fn write(
        self: *const InstanceBuffer,
        context: *d3d11.ID3D11DeviceContext,
        instances: []const u8,
    ) bool {
        assert(instances.len % self.stride_bytes == 0);
        assert(instances.len <= @as(usize, self.count_max) * self.stride_bytes);
        if (instances.len == 0) return true;
        return mapWrite(context, self.buffer, instances);
    }
};

/// How many indices `createIndexSequence` writes per `UpdateSubresource`.
const index_chunk_count: u32 = 1024;

/// A vertex buffer holding `0, 1, ..., count - 1` as `u32`, written once,
/// bound as per-instance data so each shader receives the absolute index of
/// its instance (`shaders/common.hlsl`). Filled in chunks from the stack, so
/// it takes no allocator.
pub fn createIndexSequence(
    device: *const dx11_device.Device,
    count: u32,
) ResourceError!*d3d11.ID3D11Buffer {
    assert(count > 0);
    assert(count <= buffer_bytes_max / @sizeOf(u32));
    const desc = d3d11.D3D11_BUFFER_DESC{
        .ByteWidth = count * @sizeOf(u32),
        .Usage = d3d11.D3D11_USAGE_DEFAULT,
        .BindFlags = d3d11.D3D11_BIND_VERTEX_BUFFER,
        .CPUAccessFlags = 0,
        .MiscFlags = 0,
        .StructureByteStride = 0,
    };
    const buffer = try createBuffer(device, &desc, "instance indices");
    var chunk: [index_chunk_count]u32 = undefined;
    var written: u32 = 0;
    while (written < count) {
        const chunk_count = @min(index_chunk_count, count - written);
        for (chunk[0..chunk_count], 0..) |*value, offset| {
            value.* = written + @as(u32, @intCast(offset));
        }
        const box = d3d11.D3D11_BOX{
            .left = written * @sizeOf(u32),
            .top = 0,
            .front = 0,
            .right = (written + chunk_count) * @sizeOf(u32),
            .bottom = 1,
            .back = 1,
        };
        const context = device.context;
        context.vtable.UpdateSubresource(context, buffer.resource(), 0, &box, &chunk, 0, 0);
        written += chunk_count;
    }
    assert(written == count);
    return buffer;
}

/// The input layout of a vertex shader whose only vertex input is
/// `uint instance : INSTANCE_INDEX`, read per instance from slot 0.
pub fn createInstanceLayout(
    device: *const dx11_device.Device,
    vertex_bytecode: []const u8,
) ResourceError!*d3d11.ID3D11InputLayout {
    assert(std.mem.eql(u8, vertex_bytecode[0..4], "DXBC"));
    const elements = [_]d3d11.D3D11_INPUT_ELEMENT_DESC{.{
        .SemanticName = "INSTANCE_INDEX",
        .SemanticIndex = 0,
        .Format = d3d11.DXGI_FORMAT_R32_UINT,
        .InputSlot = 0,
        .AlignedByteOffset = 0,
        .InputSlotClass = d3d11.D3D11_INPUT_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    }};
    var layout: ?*d3d11.ID3D11InputLayout = null;
    const result = device.device.vtable.CreateInputLayout(
        device.device,
        &elements,
        elements.len,
        vertex_bytecode.ptr,
        vertex_bytecode.len,
        &layout,
    );
    if (!d3d11.succeeded(result)) {
        log.err("CreateInputLayout failed: 0x{X:0>8}", .{hex(result)});
        return error.Dx11ResourceCreationFailed;
    }
    assert(layout != null);
    return layout.?;
}

pub fn createVertexShader(
    device: *const dx11_device.Device,
    bytecode: []const u8,
) ResourceError!*d3d11.ID3D11VertexShader {
    assert(std.mem.eql(u8, bytecode[0..4], "DXBC"));
    var shader: ?*d3d11.ID3D11VertexShader = null;
    const vtable = device.device.vtable;
    const result = vtable.CreateVertexShader(
        device.device,
        bytecode.ptr,
        bytecode.len,
        null,
        &shader,
    );
    if (!d3d11.succeeded(result)) {
        log.err("CreateVertexShader failed: 0x{X:0>8}", .{hex(result)});
        return error.Dx11ResourceCreationFailed;
    }
    assert(shader != null);
    return shader.?;
}

pub fn createPixelShader(
    device: *const dx11_device.Device,
    bytecode: []const u8,
) ResourceError!*d3d11.ID3D11PixelShader {
    assert(std.mem.eql(u8, bytecode[0..4], "DXBC"));
    var shader: ?*d3d11.ID3D11PixelShader = null;
    const vtable = device.device.vtable;
    const result = vtable.CreatePixelShader(
        device.device,
        bytecode.ptr,
        bytecode.len,
        null,
        &shader,
    );
    if (!d3d11.succeeded(result)) {
        log.err("CreatePixelShader failed: 0x{X:0>8}", .{hex(result)});
        return error.Dx11ResourceCreationFailed;
    }
    assert(shader != null);
    return shader.?;
}

/// A 16-byte-aligned dynamic constant buffer, rewritten whole each frame.
pub fn createConstantBuffer(
    device: *const dx11_device.Device,
    bytes: u32,
) ResourceError!*d3d11.ID3D11Buffer {
    // Constant buffers are sized in 16-byte registers.
    assert(bytes % 16 == 0);
    assert(bytes > 0);
    const desc = d3d11.D3D11_BUFFER_DESC{
        .ByteWidth = bytes,
        .Usage = d3d11.D3D11_USAGE_DYNAMIC,
        .BindFlags = d3d11.D3D11_BIND_CONSTANT_BUFFER,
        .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
        .MiscFlags = 0,
        .StructureByteStride = 0,
    };
    return createBuffer(device, &desc, "uniforms");
}

/// Replace a dynamic buffer's contents with `bytes`. False when the map
/// fails, which happens only when the device is lost.
pub fn mapWrite(
    context: *d3d11.ID3D11DeviceContext,
    buffer: *d3d11.ID3D11Buffer,
    bytes: []const u8,
) bool {
    assert(bytes.len > 0);
    var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
    const target = buffer.resource();
    const discard = d3d11.D3D11_MAP_WRITE_DISCARD;
    const result = context.vtable.Map(context, target, 0, discard, 0, &mapped);
    if (!d3d11.succeeded(result)) {
        log.err("Map(WRITE_DISCARD) failed: 0x{X:0>8}", .{hex(result)});
        return false;
    }
    assert(mapped.pData != null);
    const target_bytes: [*]u8 = @ptrCast(mapped.pData.?);
    @memcpy(target_bytes[0..bytes.len], bytes);
    context.vtable.Unmap(context, target, 0);
    return true;
}

pub fn createBuffer(
    device: *const dx11_device.Device,
    desc: *const d3d11.D3D11_BUFFER_DESC,
    name: []const u8,
) ResourceError!*d3d11.ID3D11Buffer {
    assert(desc.ByteWidth > 0);
    var buffer: ?*d3d11.ID3D11Buffer = null;
    const result = device.device.vtable.CreateBuffer(device.device, desc, null, &buffer);
    if (!d3d11.succeeded(result)) {
        log.err("CreateBuffer('{s}', {d} B) failed: 0x{X:0>8}", .{
            name,
            desc.ByteWidth,
            hex(result),
        });
        return error.Dx11ResourceCreationFailed;
    }
    assert(buffer != null);
    return buffer.?;
}

pub fn createView(
    device: *const dx11_device.Device,
    resource: *d3d11.ID3D11Resource,
    name: []const u8,
) ResourceError!*d3d11.ID3D11ShaderResourceView {
    var view: ?*d3d11.ID3D11ShaderResourceView = null;
    // A null description views the whole resource: every element of a
    // structured buffer, or mip 0 of a texture.
    const vtable = device.device.vtable;
    const result = vtable.CreateShaderResourceView(device.device, resource, null, &view);
    if (!d3d11.succeeded(result)) {
        log.err("CreateShaderResourceView('{s}') failed: 0x{X:0>8}", .{ name, hex(result) });
        return error.Dx11ResourceCreationFailed;
    }
    assert(view != null);
    return view.?;
}

// =============================================================================
// Fixed pipeline state
// =============================================================================

/// Blend, rasterizer, and sampler state shared by every pipeline. Two blend
/// states, as in the Vulkan renderer's pipelines: straight alpha for quads,
/// glyphs, SVGs, and meshes, and premultiplied alpha for images.
pub const States = struct {
    blend_straight: *d3d11.ID3D11BlendState,
    blend_premultiplied: *d3d11.ID3D11BlendState,
    rasterizer: *d3d11.ID3D11RasterizerState,
    sampler: *d3d11.ID3D11SamplerState,

    pub fn create(device: *const dx11_device.Device) ResourceError!States {
        assert(device.feature_level >= d3d11.D3D_FEATURE_LEVEL_11_0);
        const blend_straight = try createBlend(device, d3d11.D3D11_BLEND_SRC_ALPHA);
        errdefer blend_straight.release();
        const blend_premultiplied = try createBlend(device, d3d11.D3D11_BLEND_ONE);
        errdefer blend_premultiplied.release();
        const rasterizer = try createRasterizer(device);
        errdefer rasterizer.release();
        const sampler = try createSampler(device);
        assert(blend_straight != blend_premultiplied);
        return .{
            .blend_straight = blend_straight,
            .blend_premultiplied = blend_premultiplied,
            .rasterizer = rasterizer,
            .sampler = sampler,
        };
    }

    pub fn release(self: *States) void {
        assert(self.blend_straight != self.blend_premultiplied);
        self.sampler.release();
        self.rasterizer.release();
        self.blend_premultiplied.release();
        self.blend_straight.release();
        self.* = undefined;
    }
};

/// Source-over blending with `source_color` as the colour's source factor:
/// `SRC_ALPHA` for straight colours, `ONE` for premultiplied ones. Alpha
/// always accumulates as `a + (1 - a) * dst`, matching `vk_pipelines`.
fn createBlend(
    device: *const dx11_device.Device,
    source_color: u32,
) ResourceError!*d3d11.ID3D11BlendState {
    assert(source_color == d3d11.D3D11_BLEND_SRC_ALPHA or source_color == d3d11.D3D11_BLEND_ONE);
    const disabled = std.mem.zeroes(d3d11.D3D11_RENDER_TARGET_BLEND_DESC);
    var desc = d3d11.D3D11_BLEND_DESC{
        .AlphaToCoverageEnable = 0,
        .IndependentBlendEnable = 0,
        .RenderTarget = @splat(disabled),
    };
    desc.RenderTarget[0] = .{
        .BlendEnable = 1,
        .SrcBlend = source_color,
        .DestBlend = d3d11.D3D11_BLEND_INV_SRC_ALPHA,
        .BlendOp = d3d11.D3D11_BLEND_OP_ADD,
        .SrcBlendAlpha = d3d11.D3D11_BLEND_ONE,
        .DestBlendAlpha = d3d11.D3D11_BLEND_INV_SRC_ALPHA,
        .BlendOpAlpha = d3d11.D3D11_BLEND_OP_ADD,
        .RenderTargetWriteMask = d3d11.D3D11_COLOR_WRITE_ENABLE_ALL,
    };
    var state: ?*d3d11.ID3D11BlendState = null;
    const result = device.device.vtable.CreateBlendState(device.device, &desc, &state);
    if (!d3d11.succeeded(result)) {
        log.err("CreateBlendState failed: 0x{X:0>8}", .{hex(result)});
        return error.Dx11ResourceCreationFailed;
    }
    assert(state != null);
    return state.?;
}

/// No culling (strips and quads are wound either way), scissor on for clips,
/// and no multisampling: edges are anti-aliased analytically in the pixel
/// shaders, as in the Vulkan and Metal renderers.
fn createRasterizer(device: *const dx11_device.Device) ResourceError!*d3d11.ID3D11RasterizerState {
    assert(device.feature_level >= d3d11.D3D_FEATURE_LEVEL_11_0);
    const desc = d3d11.D3D11_RASTERIZER_DESC{
        .FillMode = d3d11.D3D11_FILL_SOLID,
        .CullMode = d3d11.D3D11_CULL_NONE,
        .FrontCounterClockwise = 0,
        .DepthBias = 0,
        .DepthBiasClamp = 0,
        .SlopeScaledDepthBias = 0,
        .DepthClipEnable = 1,
        .ScissorEnable = 1,
        .MultisampleEnable = 0,
        .AntialiasedLineEnable = 0,
    };
    var state: ?*d3d11.ID3D11RasterizerState = null;
    const result = device.device.vtable.CreateRasterizerState(device.device, &desc, &state);
    if (!d3d11.succeeded(result)) {
        log.err("CreateRasterizerState failed: 0x{X:0>8}", .{hex(result)});
        return error.Dx11ResourceCreationFailed;
    }
    assert(state != null);
    return state.?;
}

/// Bilinear, clamped: the Vulkan renderer's shared atlas sampler.
fn createSampler(device: *const dx11_device.Device) ResourceError!*d3d11.ID3D11SamplerState {
    assert(device.feature_level >= d3d11.D3D_FEATURE_LEVEL_11_0);
    const desc = d3d11.D3D11_SAMPLER_DESC{
        .Filter = d3d11.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
        .AddressU = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
        .AddressV = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
        .AddressW = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = d3d11.D3D11_COMPARISON_NEVER,
        .BorderColor = @splat(0),
        .MinLOD = 0,
        .MaxLOD = 0,
    };
    var state: ?*d3d11.ID3D11SamplerState = null;
    const result = device.device.vtable.CreateSamplerState(device.device, &desc, &state);
    if (!d3d11.succeeded(result)) {
        log.err("CreateSamplerState failed: 0x{X:0>8}", .{hex(result)});
        return error.Dx11ResourceCreationFailed;
    }
    assert(state != null);
    return state.?;
}
