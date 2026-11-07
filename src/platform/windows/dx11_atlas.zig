//! Atlas texture management for the DX11 renderer.
//!
//! Mirrors the API shape of `../linux/vk_atlas.zig` (MAX_ATLAS_DIMENSION,
//! AtlasFormat, AtlasResources with a `.view`, DirtyRegion, stageDirtyRegion,
//! ensureAtlasImage semantics) so `dx11_renderer.zig` is a structural twin of
//! `vk_renderer.zig` and `window.zig` can treat both identically.
//!
//! The Vulkan model (device-local image + shared staging buffer + command
//! buffer copies between barriers) collapses in D3D11 to the simpler
//! UpdateSubresource path: default-usage textures plus staged uploads through
//! a per-frame staging texture per atlas, with `CopySubresourceRegion`
//! restricting the GPU copy to the dirty rect. D3D11's implicit synchronization
//! (the runtime serializes default-texture writes against draws) replaces the
//! explicit barriers; the per-frame staging ring replaces the 144MB shared
//! staging buffer's FRAME_COUNT lanes.

const std = @import("std");
const d3d11 = @import("win32/graphics/direct3d11.zig");
const dxgi = @import("win32/graphics/dxgi.zig");

const FRAME_COUNT = @import("vk_types.zig").FRAME_COUNT;

// =============================================================================
// Limits (mirrors vk_atlas.zig, CLAUDE.md Rule #4)
// =============================================================================

/// Maximum atlas dimension in either axis. Same budget as the Vulkan backend.
pub const MAX_ATLAS_DIMENSION: u32 = 4096;

/// Staging size for the text atlas region (R8 = 1 byte/pixel): 16MB.
pub const TEXT_STAGING_BYTES: usize = MAX_ATLAS_DIMENSION * MAX_ATLAS_DIMENSION * 1;

/// Staging size for an RGBA atlas region (SVG or image): 64MB.
pub const RGBA_STAGING_BYTES: usize = MAX_ATLAS_DIMENSION * MAX_ATLAS_DIMENSION * 4;

/// Total staging footprint across all atlases: 16 + 64 + 64 = 144MB, matching
/// the Vulkan backend's shared staging buffer. Unlike Vulkan the footprint is
/// not allocated once up front — each atlas owns staging memory sized to its
/// actual dimensions (worst case the same 144MB).
pub const MAX_STAGING_BYTES: usize = TEXT_STAGING_BYTES + 2 * RGBA_STAGING_BYTES;

// =============================================================================
// Public Types
// =============================================================================

/// Pixel format for atlas textures. Determines DXGI format and byte stride.
pub const AtlasFormat = enum {
    /// Single-channel (text atlas): 1 byte per pixel, DXGI_FORMAT_R8_UNORM.
    r8,
    /// Four-channel (SVG/image atlas): 4 bytes per pixel, RGBA8_UNORM.
    rgba8,

    pub fn dxgiFormat(self: AtlasFormat) dxgi.common.DXGI_FORMAT {
        return switch (self) {
            .r8 => .R8_TYPELESS, // sampled as R8_UNORM SRV (see dx11_renderer)
            .rgba8 => .R8G8B8A8_UNORM,
        };
    }

    /// The SRV-viewable format for the texture. R8_TYPELESS textures are
    /// viewed as R8_UNORM so shaders sample raw coverage.
    pub fn srvFormat(self: AtlasFormat) dxgi.common.DXGI_FORMAT {
        return switch (self) {
            .r8 => .R8_UNORM,
            .rgba8 => .R8G8B8A8_UNORM,
        };
    }

    pub fn bytesPerPixel(self: AtlasFormat) u32 {
        return switch (self) {
            .r8 => 1,
            .rgba8 => 4,
        };
    }
};

/// All D3D11 resources for a single atlas texture. Field-for-field parallel
/// of `vk_atlas.AtlasResources` (`.view` is what `window.zig` polls and what
/// the scene renderer binds).
pub const AtlasResources = struct {
    texture: ?*d3d11.ID3D11Texture2D = null,
    staging: ?*d3d11.ID3D11Texture2D = null,
    view: ?*d3d11.ID3D11ShaderResourceView = null,
    width: u32 = 0,
    height: u32 = 0,
    generation: u32 = 0,

    /// Release staging memory when its owning resources go away. The
    /// renderer calls this after consuming the staged rows for a frame.
    pub fn destroy(self: *AtlasResources, device: *d3d11.ID3D11Device) void {
        _ = if (self.view) |v| v.IUnknown.Release();
        _ = if (self.texture) |t| t.IUnknown.Release();
        _ = if (self.staging) |s| s.IUnknown.Release();
        _ = device;
        self.* = .{};
    }
};

pub const AtlasError = error{
    AtlasTextureCreationFailed,
    AtlasViewCreationFailed,
    AtlasMapFailed,
};

/// Sub-region of an atlas that needs GPU upload.
/// Coordinates are in atlas pixels (not bytes). Identical to vk_atlas's.
pub const DirtyRegion = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

// =============================================================================
// Public API
// =============================================================================

/// Ensure an atlas texture (default + staging + SRV) exists at the given
/// dimensions. (Re)creates everything if dimensions changed or the texture
/// doesn't exist yet. Returns `true` if (re)created — caller must perform a
/// full upload. Mirrors `vk_atlas.ensureAtlasImage`.
pub fn ensureAtlasImage(
    resources: *AtlasResources,
    width: u32,
    height: u32,
    format: AtlasFormat,
    device: *d3d11.ID3D11Device,
) AtlasError!bool {
    std.debug.assert(width > 0 and width <= MAX_ATLAS_DIMENSION);
    std.debug.assert(height > 0 and height <= MAX_ATLAS_DIMENSION);

    const same_size = resources.width == width and
        resources.height == height and
        resources.texture != null;
    if (same_size) return false;

    resources.destroy(device);
    try createAtlasTexture(device, resources, width, height, format);
    return true;
}

/// Copy dirty atlas rows into the atlas's staging texture, tightly packed
/// from row 0 (each mapped row is `dirty.width * bpp` bytes; the copy maps
/// exactly that many rows). Mirrors `vk_atlas.stageDirtyRegion` semantics —
/// same source layout, same tightly-packed destination — but writes into a
/// D3D11 staging texture instead of a byte buffer.
///
/// `mapped_rows` points at the staging texture's row 0 as returned by Map;
/// `mapped_row_pitch` is the D3D11 row pitch (may exceed the tight stride;
/// rows beyond the tight stride are left untouched and never copied).
pub fn stageDirtyRegion(
    mapped_rows: [*]u8,
    mapped_row_pitch: u32,
    atlas_data: []const u8,
    atlas_width: u32,
    format: AtlasFormat,
    dirty: DirtyRegion,
) void {
    std.debug.assert(dirty.width > 0 and dirty.height > 0);
    std.debug.assert(dirty.x + dirty.width <= atlas_width);

    const bpp: usize = format.bytesPerPixel();
    const atlas_height: u32 = @intCast(atlas_data.len / (@as(usize, atlas_width) * bpp));
    std.debug.assert(dirty.y + dirty.height <= atlas_height);
    const row_bytes: usize = @as(usize, dirty.width) * bpp;
    const atlas_stride: usize = @as(usize, atlas_width) * bpp;
    std.debug.assert(mapped_row_pitch >= row_bytes);

    for (0..dirty.height) |row| {
        const src_y = @as(usize, dirty.y) + row;
        const src_offset = src_y * atlas_stride + @as(usize, dirty.x) * bpp;
        const dst_row = @as(usize, row) * mapped_row_pitch;
        @memcpy(mapped_rows[dst_row..][0..row_bytes], atlas_data[src_offset..][0..row_bytes]);
    }
}

/// Copy the staged dirty sub-region from the staging texture into the
/// default (GPU) texture. Mirrors `vk_atlas.recordPartialAtlasTransfer`
/// minus the explicit barriers: D3D11 orders CopySubresourceRegion against
/// subsequent draws on the immediate context.
pub fn recordPartialAtlasTransfer(
    context: *d3d11.ID3D11DeviceContext,
    texture: *d3d11.ID3D11Texture2D,
    staging: *d3d11.ID3D11Texture2D,
    dirty: DirtyRegion,
) void {
    std.debug.assert(dirty.width > 0 and dirty.height > 0);

    const box = d3d11.D3D11_BOX{
        .left = dirty.x,
        .top = dirty.y,
        .front = 0,
        .right = dirty.x + dirty.width,
        .bottom = dirty.y + dirty.height,
        .back = 1,
    };
    context.CopySubresourceRegion(
        @ptrCast(texture),
        0,
        dirty.x,
        dirty.y,
        0,
        @ptrCast(staging),
        0,
        &box,
    );
}

// =============================================================================
// Internal — Texture Creation
// =============================================================================

/// Create the default GPU texture + matching staging texture + SRV.
fn createAtlasTexture(
    device: *d3d11.ID3D11Device,
    resources: *AtlasResources,
    width: u32,
    height: u32,
    format: AtlasFormat,
) AtlasError!void {
    std.debug.assert(resources.texture == null); // Must be destroyed first

    const tex_desc = d3d11.D3D11_TEXTURE2D_DESC{
        .Width = width,
        .Height = height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = format.dxgiFormat(),
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = .{ .SHADER_RESOURCE = 1 },
        .CPUAccessFlags = .{},
        .MiscFlags = .{},
    };
    var texture: ?*d3d11.ID3D11Texture2D = null;
    if (device.CreateTexture2D(&tex_desc, null, (@ptrCast(&texture))) < 0 or texture == null) {
        return AtlasError.AtlasTextureCreationFailed;
    }
    resources.texture = texture;
    errdefer {
        _ = texture.?.IUnknown.Release();
        resources.texture = null;
    }

    // Staging twin with CPU write access. Map targets this; the tight dirty
    // rows are written here, then CopySubresourceRegion moves only the dirty
    // box to the GPU texture.
    var staging_desc = tex_desc;
    staging_desc.Usage = .STAGING;
    staging_desc.BindFlags = .{};
    staging_desc.CPUAccessFlags = .{ .WRITE = 1 };
    var staging: ?*d3d11.ID3D11Texture2D = null;
    if (device.CreateTexture2D(&staging_desc, null, (@ptrCast(&staging))) < 0 or staging == null) {
        return AtlasError.AtlasTextureCreationFailed;
    }
    resources.staging = staging;
    errdefer {
        _ = staging.?.IUnknown.Release();
        resources.staging = null;
    }

    const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
        .Format = format.srvFormat(),
        .ViewDimension = .@"11_SRV_DIMENSION_TEXTURE2D",
        .Anonymous = .{
            .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1 },
        },
    };
    var view: ?*d3d11.ID3D11ShaderResourceView = null;
    if (device.CreateShaderResourceView(@ptrCast(texture.?), &srv_desc, (@ptrCast(&view))) < 0 or view == null) {
        return AtlasError.AtlasViewCreationFailed;
    }
    resources.view = view;

    resources.width = width;
    resources.height = height;
}

// ===========================================================================
// Tests — pure staging/format logic, no D3D11 device. Run with
// `zig build test -Dgpu-backend=dx11`.
// ===========================================================================

const testing = std.testing;

test "atlas formats map to the expected DXGI views and strides" {
    try testing.expectEqual(dxgi.common.DXGI_FORMAT.R8_TYPELESS, AtlasFormat.r8.dxgiFormat());
    try testing.expectEqual(dxgi.common.DXGI_FORMAT.R8_UNORM, AtlasFormat.r8.srvFormat());
    try testing.expectEqual(dxgi.common.DXGI_FORMAT.R8G8B8A8_UNORM, AtlasFormat.rgba8.dxgiFormat());
    try testing.expectEqual(dxgi.common.DXGI_FORMAT.R8G8B8A8_UNORM, AtlasFormat.rgba8.srvFormat());
    try testing.expectEqual(@as(u32, 1), AtlasFormat.r8.bytesPerPixel());
    try testing.expectEqual(@as(u32, 4), AtlasFormat.rgba8.bytesPerPixel());
}

test "stageDirtyRegion copies exactly the dirty rows, tightly packed" {
    // 8x8 single-channel atlas, each pixel holding its linear index.
    const width: u32 = 8;
    var atlas: [64]u8 = undefined;
    for (&atlas, 0..) |*px, i| px.* = @intCast(i);

    // Destination staging buffer with padded row pitch; sentinel fill so the
    // test can prove nothing outside the copied rows was touched.
    const pitch: u32 = 16;
    var staging: [3 * 16]u8 = @splat(0xAA);

    stageDirtyRegion(&staging, pitch, &atlas, width, .r8, .{ .x = 2, .y = 3, .width = 4, .height = 2 });

    // Row 0 of staging = atlas row 3, columns 2..5 → values 26..29.
    try testing.expectEqualSlices(u8, &[_]u8{ 26, 27, 28, 29 }, staging[0..4]);
    // Row 1 of staging (at pitch 16) = atlas row 4, columns 2..5 → 34..37.
    try testing.expectEqualSlices(u8, &[_]u8{ 34, 35, 36, 37 }, staging[16..20]);
    // Tail of each staged row (pitch padding) keeps its sentinel.
    try testing.expectEqual(@as(u8, 0xAA), staging[4]);
    try testing.expectEqual(@as(u8, 0xAA), staging[20]);
    // Rows beyond the dirty height are untouched.
    try testing.expectEqual(@as(u8, 0xAA), staging[32]);
}
