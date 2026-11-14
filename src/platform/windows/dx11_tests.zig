//! Tests for the DirectX 11 renderer: its device, swapchain, and resources,
//! and packed frames drawn through a headless renderer.
//!
//! Methodology: every test runs on a WARP device, Microsoft's software
//! rasterizer, so the results are the same on every Windows machine with or
//! without a GPU. Results are read back through a staging texture and compared
//! byte for byte, with asymmetric values so a swapped channel, a transposed
//! coordinate, or an off-by-one edge produces a different byte.

const std = @import("std");
const d3d11 = @import("d3d11.zig");
const win32 = @import("win32.zig");
const dx11_device = @import("dx11_device.zig");
const dx11_swapchain = @import("dx11_swapchain.zig");
const dx11_resources = @import("dx11_resources.zig");
const dx11_renderer = @import("dx11_renderer.zig");
const limits_mod = @import("../../core/limits.zig");
const backend = @import("../../core/backend.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const geometry = @import("../../geometry/geometry.zig");

const testing = std.testing;
const Device = dx11_device.Device;

/// A texture the GPU renders into or the tests upload to, and a staging twin
/// that reads it back.
const Readback = struct {
    staging: *d3d11.ID3D11Texture2D,
    width_px: u32,
    height_px: u32,
    format: u32,

    fn create(device: *const Device, width_px: u32, height_px: u32, format: u32) !Readback {
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = width_px,
            .Height = height_px,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d11.D3D11_USAGE_STAGING,
            .BindFlags = 0,
            .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_READ,
            .MiscFlags = 0,
        };
        var staging: ?*d3d11.ID3D11Texture2D = null;
        const result = device.device.vtable.CreateTexture2D(device.device, &desc, null, &staging);
        try testing.expect(d3d11.succeeded(result));
        return .{
            .staging = staging.?,
            .width_px = width_px,
            .height_px = height_px,
            .format = format,
        };
    }

    fn release(self: *Readback) void {
        self.staging.release();
    }

    /// Copy `source` into the staging texture and copy its rows, tightly
    /// packed, into `out`.
    fn read(
        self: *const Readback,
        device: *const Device,
        source: *d3d11.ID3D11Texture2D,
        bytes_per_pixel: u32,
        out: []u8,
    ) !void {
        const row_bytes = self.width_px * bytes_per_pixel;
        try testing.expectEqual(@as(usize, row_bytes) * self.height_px, out.len);
        const context = device.context;
        context.vtable.CopyResource(context, self.staging.resource(), source.resource());
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        const target = self.staging.resource();
        const result = context.vtable.Map(context, target, 0, d3d11.D3D11_MAP_READ, 0, &mapped);
        try testing.expect(d3d11.succeeded(result));
        defer context.vtable.Unmap(context, target, 0);
        try testing.expect(mapped.RowPitch >= row_bytes);
        const rows: [*]const u8 = @ptrCast(mapped.pData.?);
        var row: u32 = 0;
        while (row < self.height_px) : (row += 1) {
            const source_row = rows[@as(usize, row) * mapped.RowPitch ..][0..row_bytes];
            @memcpy(out[@as(usize, row) * row_bytes ..][0..row_bytes], source_row);
        }
    }
};

fn createRenderTarget(device: *const Device, side_px: u32) !*d3d11.ID3D11Texture2D {
    const desc = d3d11.D3D11_TEXTURE2D_DESC{
        .Width = side_px,
        .Height = side_px,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = dx11_swapchain.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = d3d11.D3D11_USAGE_DEFAULT,
        .BindFlags = d3d11.D3D11_BIND_RENDER_TARGET,
        .CPUAccessFlags = 0,
        .MiscFlags = 0,
    };
    var texture: ?*d3d11.ID3D11Texture2D = null;
    const result = device.device.vtable.CreateTexture2D(device.device, &desc, null, &texture);
    try testing.expect(d3d11.succeeded(result));
    return texture.?;
}

test "WARP clears an offscreen target to the requested colour" {
    var device = try Device.create(.warp);
    defer device.release();
    try testing.expectEqual(dx11_device.Driver.warp, device.driver);
    try testing.expect(device.feature_level >= d3d11.D3D_FEATURE_LEVEL_11_0);

    const side_px: u32 = 4;
    const texture = try createRenderTarget(&device, side_px);
    defer texture.release();
    var view: ?*d3d11.ID3D11RenderTargetView = null;
    const vtable = device.device.vtable;
    try testing.expect(d3d11.succeeded(vtable.CreateRenderTargetView(
        device.device,
        texture.resource(),
        null,
        &view,
    )));
    defer view.?.release();

    // Distinct channels: a BGRA/RGBA swap or a dropped alpha changes bytes.
    const clear = [4]f32{ 0.25, 0.5, 0.75, 1.0 };
    device.context.vtable.ClearRenderTargetView(device.context, view.?, &clear);

    var readback = try Readback.create(&device, side_px, side_px, dx11_swapchain.format);
    defer readback.release();
    var pixels: [side_px * side_px * 4]u8 = undefined;
    try readback.read(&device, texture, 4, &pixels);
    // B8G8R8A8 in memory order; UNORM rounds 0.25 * 255 = 63.75 to 64.
    var index: usize = 0;
    while (index < pixels.len) : (index += 4) {
        try testing.expectEqualSlices(u8, &.{ 191, 128, 64, 255 }, pixels[index..][0..4]);
    }
}

test "a swapchain on a hidden window resizes and presents" {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const instance = win32.GetModuleHandleW(null) orelse return error.NoModule;
    const hwnd = win32.CreateWindowExW(
        0,
        class,
        class,
        0,
        0,
        0,
        160,
        120,
        null,
        null,
        instance,
        null,
    ) orelse
        return error.WindowCreationFailed;
    defer _ = win32.DestroyWindow(hwnd);

    var device = try Device.create(.warp);
    defer device.release();
    var swapchain = try dx11_swapchain.Swapchain.create(&device, hwnd, .{
        .width_px = 64,
        .height_px = 48,
        .buffer_count = 3,
    });
    defer swapchain.release();
    try testing.expect(swapchain.usable());

    try testing.expect(swapchain.resize(&device, 33, 17));
    try testing.expectEqual(@as(u32, 33), swapchain.width_px);
    try testing.expectEqual(@as(u32, 17), swapchain.height_px);

    var frame: u32 = 0;
    while (frame < 4) : (frame += 1) {
        swapchain.waitForFrame();
        const clear = [4]f32{ 0, 0, 0, 1 };
        const context = device.context;
        context.vtable.ClearRenderTargetView(context, swapchain.target_view.?, &clear);
        const result = swapchain.present();
        // A hidden window may be reported occluded; it is never lost on WARP.
        try testing.expect(result != .device_lost);
    }
}

/// A headless WARP renderer, a square render target it draws into, and a
/// packed frame the tests fill by hand, as pack would.
const Harness = struct {
    renderer: dx11_renderer.Dx11Renderer,
    texture: *d3d11.ID3D11Texture2D,
    view: *d3d11.ID3D11RenderTargetView,
    readback: Readback,
    frame: packed_mod.PackedFrame,

    const side_px: u32 = 16;
    const pixel_bytes = side_px * side_px * 4;

    fn init(self: *Harness) !void {
        const resource_limits = &limits_mod.ResourceLimits.nano;
        const limits = backend.RenderLimits.fromResourceLimits(resource_limits);
        try self.renderer.initInPlaceWithDriver(&.{
            .native = null,
            .size_px = .{ .width = side_px, .height = side_px },
            .scale_factor = 1,
        }, &limits, .warp);
        errdefer self.renderer.deinit();
        try testing.expect(self.renderer.swapchain == null);

        const device = &self.renderer.device;
        self.texture = try createRenderTarget(device, side_px);
        errdefer self.texture.release();
        var view: ?*d3d11.ID3D11RenderTargetView = null;
        try testing.expect(d3d11.succeeded(device.device.vtable.CreateRenderTargetView(
            device.device,
            self.texture.resource(),
            null,
            &view,
        )));
        self.view = view.?;
        errdefer self.view.release();
        self.readback = try Readback.create(device, side_px, side_px, dx11_swapchain.format);
        errdefer self.readback.release();
        try self.frame.initInPlace(&.{
            .paint = resource_limits.paint,
            .paint_record_count_max = 16,
        });
    }

    fn deinit(self: *Harness) void {
        self.frame.deinit();
        self.readback.release();
        self.view.release();
        self.texture.release();
        self.renderer.deinit();
    }

    /// Render the frame cleared to opaque black and read it back as BGRA.
    fn render(self: *Harness, scale_factor: f32, pixels: *[pixel_bytes]u8) !void {
        const viewport = backend.Viewport{
            .size_px = .{ .width = side_px, .height = side_px },
            .scale_factor = scale_factor,
        };
        const black = geometry.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
        try testing.expect(self.renderer.encode(self.view, &self.frame, viewport, black));
        try self.readback.read(&self.renderer.device, self.texture, 4, pixels);
    }

    fn pushClip(self: *Harness, clip: packed_mod.Rect) u32 {
        const index = self.frame.clip_count;
        self.frame.clips[index] = clip;
        self.frame.clip_count += 1;
        return index;
    }

    fn pushDraw(self: *Harness, draw: packed_mod.Draw) void {
        self.frame.draws[self.frame.draw_count] = draw;
        self.frame.draw_count += 1;
    }

    fn pushQuad(self: *Harness, bounds: packed_mod.Rect, fill: packed_mod.Rgba) void {
        self.frame.quads[self.frame.quad_count] = .{
            .bounds = bounds,
            .fill = fill,
            .border_color = .{ 0, 0, 0, 0 },
            .corners = .{ 0, 0, 0, 0 },
            .border_widths = .{ 0, 0, 0, 0 },
            .blur = 0,
            .offset = .{ 0, 0 },
        };
        self.frame.quad_count += 1;
        self.countPool(.quads);
    }

    fn pushMesh(self: *Harness, mesh: packed_mod.Mesh, pool: packed_mod.Pool) void {
        self.frame.meshes[self.frame.mesh_count] = mesh;
        self.frame.mesh_count += 1;
        self.countPool(pool);
    }

    fn pushSprite(self: *Harness, sprite: packed_mod.Sprite) void {
        self.frame.sprites[self.frame.sprite_count] = sprite;
        self.frame.sprite_count += 1;
        self.countPool(.glyphs);
    }

    /// Pack counts each instance against its pool; the frame's lists check
    /// those counts against the instance counts.
    fn countPool(self: *Harness, pool: packed_mod.Pool) void {
        self.frame.counts[@backingInt(pool)] += 1;
    }
};

/// The BGRA bytes of pixel (`x`, `y`).
fn pixelAt(pixels: []const u8, x: usize, y: usize) [4]u8 {
    return pixels[(y * Harness.side_px + x) * 4 ..][0..4].*;
}

/// Each channel within one step of the expected byte: WARP and the shaders'
/// float maths may round either way.
fn expectPixel(expected: [4]u8, actual: [4]u8) !void {
    for (expected, actual) |want, got| {
        try testing.expect(@abs(@as(i16, want) - @as(i16, got)) <= 1);
    }
}

const clip_none = packed_mod.clip_none;

const bgra_black = [4]u8{ 0, 0, 0, 255 };
const bgra_red = [4]u8{ 0, 0, 255, 255 };
const bgra_green = [4]u8{ 0, 255, 0, 255 };
const bgra_blue = [4]u8{ 255, 0, 0, 255 };

test "quads land at their pixel rectangles from their own draw ranges" {
    // Red near the top left and blue lower right, unequal sizes, in separate
    // draws: a missing Y flip mirrors red to the bottom, and a draw that
    // ignored its first instance would draw red twice and blue never.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.frame.reset(1, &.{});
    harness.pushQuad(.{ 2, 1, 4, 3 }, .{ 1, 0, 0, 1 });
    harness.pushQuad(.{ 9, 8, 5, 6 }, .{ 0, 0, 1, 1 });
    harness.pushDraw(.{ .pipeline = .quad, .clip = clip_none, .first = 0, .count = 1 });
    harness.pushDraw(.{ .pipeline = .quad, .clip = clip_none, .first = 1, .count = 1 });

    var pixels: [Harness.pixel_bytes]u8 = undefined;
    try harness.render(1, &pixels);
    for (0..Harness.side_px) |y| {
        for (0..Harness.side_px) |x| {
            // Centres half a pixel inside an edge are covered and half a
            // pixel outside are not: the analytic fade spans one pixel.
            const in_red = x >= 2 and x < 6 and y >= 1 and y < 4;
            const in_blue = x >= 9 and x < 14 and y >= 8 and y < 14;
            const expected = if (in_red) bgra_red else if (in_blue) bgra_blue else bgra_black;
            try expectPixel(expected, pixelAt(&pixels, x, y));
        }
    }
}

test "a draw writes exactly the pixel centres inside its clip, edges included" {
    // At scale 1.5 the clip (2, 1, 3, 4) spans device x 3.0 to 7.5 and y 1.5
    // to 7.5, so the centres 3.5 to 7.5 across and 1.5 to 7.5 down are
    // inside, three of them exactly on an edge. A later full-viewport draw
    // in the unbounded clip proves the scissor is restored.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.frame.reset(1, &.{});
    const clip = harness.pushClip(.{ 2, 1, 3, 4 });
    harness.pushQuad(.{ -1, -1, 18, 18 }, .{ 0, 1, 0, 1 });
    harness.pushQuad(.{ -1, 7.5, 18, 3 }, .{ 1, 0, 0, 1 });
    harness.pushDraw(.{ .pipeline = .quad, .clip = clip, .first = 0, .count = 1 });
    harness.pushDraw(.{ .pipeline = .quad, .clip = clip_none, .first = 1, .count = 1 });

    var pixels: [Harness.pixel_bytes]u8 = undefined;
    try harness.render(1.5, &pixels);
    for (0..Harness.side_px) |y| {
        for (0..Harness.side_px) |x| {
            const in_clip = x >= 3 and x <= 7 and y >= 1 and y <= 7;
            // The red band spans device y 11.25 to 15.75. The quad fade spans
            // one logical pixel, so rows 11 and 15 are partly covered.
            if (y == 11 or y == 15) continue;
            const in_band = y >= 12 and y < 15;
            const expected = if (in_clip) bgra_green else if (in_band) bgra_red else bgra_black;
            try expectPixel(expected, pixelAt(&pixels, x, y));
        }
    }
}

test "scissorRect rounds clip edges to pixel centres and clamps to the viewport" {
    const viewport = backend.Viewport{
        .size_px = .{ .width = 30, .height = 20 },
        .scale_factor = 1.5,
    };
    // Exact centres are inside: 3.0 * 1.5 - 0.5 = 4.0 keeps pixel 4.
    const inside = dx11_renderer.scissorRect(.{ 2, 3, 4, 2 }, viewport);
    try testing.expectEqual(@as(i32, 3), inside.left);
    try testing.expectEqual(@as(i32, 4), inside.top);
    try testing.expectEqual(@as(i32, 9), inside.right);
    try testing.expectEqual(@as(i32, 8), inside.bottom);
    // The unbounded clip is the whole framebuffer.
    const all = dx11_renderer.scissorRect(packed_mod.clip_unbounded, viewport);
    const whole = d3d11.D3D11_RECT{ .left = 0, .top = 0, .right = 30, .bottom = 20 };
    try testing.expectEqual(whole, all);
    // A clip narrower than a pixel between two centres holds none.
    const empty = dx11_renderer.scissorRect(.{ 1.1, 1.1, 0.2, 0.2 }, viewport);
    try testing.expect(empty.right <= empty.left);
    try testing.expect(empty.bottom <= empty.top);
}

test "a glyph sprite samples the coverage uploadAtlas copied into the glyph atlas" {
    // A 3x2 coverage record at atlas (8, 8), mapped texel for texel onto a
    // sprite at (5, 4): a transposed record or a wrong uv corner moves the
    // half-coverage column. The surrounding texels are zeroed first, since a
    // new atlas is undefined.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const zeroes: [6 * 5]u8 = @splat(0);
    harness.renderer.uploadAtlas(.glyph, .{ .x = 7, .y = 7, .width = 6, .height = 5 }, &zeroes);
    const coverage = [_]u8{ 255, 255, 128, 255, 255, 128 };
    harness.renderer.uploadAtlas(.glyph, .{ .x = 8, .y = 8, .width = 3, .height = 2 }, &coverage);
    // `encode` lands both records before the sprite samples them.

    const side: f32 = @floatFromInt(harness.renderer.atlases.glyph.side_px);
    harness.frame.reset(1, &.{});
    harness.pushSprite(.{
        .bounds = .{ 5, 4, 3, 2 },
        .uv = .{ 8 / side, 8 / side, 11 / side, 10 / side },
        .tint = .{ 1, 1, 1, 1 },
        .secondary = .{ 0, 0, 0, 0 },
        .corners = .{ 0, 0, 0, 0 },
        .grayscale = 0,
        .opacity = 1,
    });
    harness.pushDraw(.{ .pipeline = .glyph, .clip = clip_none, .first = 0, .count = 1 });

    var pixels: [Harness.pixel_bytes]u8 = undefined;
    try harness.render(1, &pixels);
    for (0..Harness.side_px) |y| {
        for (0..Harness.side_px) |x| {
            const inside = x >= 5 and x < 8 and y >= 4 and y < 6;
            const value: u8 = if (!inside) 0 else if (x == 7) 128 else 255;
            try expectPixel(.{ value, value, value, 255 }, pixelAt(&pixels, x, y));
        }
    }
}
test "triangle, strip, and point meshes cover their shapes with one-pixel fades" {
    // Three meshes, one per topology, each in its own draw and colour. The
    // triangle's three edges fade, so the pixel whose centre lies on its
    // hypotenuse is half covered; the strip and the point are checked well
    // inside and well outside their edges.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const points = [_]packed_mod.MeshPoint{
        .{ .x = 1, .y = 1 },  .{ .x = 9, .y = 1 },   .{ .x = 1, .y = 9 },
        .{ .x = 2, .y = 13 }, .{ .x = 14, .y = 13 }, .{ .x = 12, .y = 5 },
    };
    harness.frame.reset(1, &points);
    const fade_all: packed_mod.EdgeModes = 1 | (1 << 2) | (1 << 4);
    harness.frame.edge_modes[0] = fade_all;
    harness.frame.triangle_count = 1;
    const green = packed_mod.Rgba{ 0, 1, 0, 1 };
    const blue = packed_mod.Rgba{ 0, 0, 1, 1 };
    const red = packed_mod.Rgba{ 1, 0, 0, 1 };
    const Mesh = packed_mod.Mesh;
    const triangle = Mesh{ .fill = green, .first = 0, .count = 3, .width = 0, .edge_first = 0 };
    const strip = Mesh{ .fill = blue, .first = 3, .count = 2, .width = 2, .edge_first = 0 };
    const point = Mesh{ .fill = red, .first = 5, .count = 1, .width = 2, .edge_first = 0 };
    harness.pushMesh(triangle, .triangle_meshes);
    harness.pushMesh(strip, .polylines);
    harness.pushMesh(point, .point_clouds);
    harness.pushDraw(.{ .pipeline = .triangles, .clip = clip_none, .first = 0, .count = 1 });
    harness.pushDraw(.{ .pipeline = .strip_expanded, .clip = clip_none, .first = 1, .count = 1 });
    harness.pushDraw(.{ .pipeline = .point_instanced, .clip = clip_none, .first = 2, .count = 1 });

    var pixels: [Harness.pixel_bytes]u8 = undefined;
    try harness.render(1, &pixels);
    // Triangle: inside, half covered on the hypotenuse, and outside.
    try expectPixel(bgra_green, pixelAt(&pixels, 2, 2));
    try expectPixel(bgra_green, pixelAt(&pixels, 4, 4));
    try expectPixel(.{ 0, 128, 0, 255 }, pixelAt(&pixels, 5, 4));
    try expectPixel(bgra_black, pixelAt(&pixels, 0, 0));
    try expectPixel(bgra_black, pixelAt(&pixels, 7, 7));
    // Strip: rows 12 and 13 from x 2 through 13, both caps faded.
    for (2..14) |x| {
        try expectPixel(bgra_blue, pixelAt(&pixels, x, 12));
        try expectPixel(bgra_blue, pixelAt(&pixels, x, 13));
    }
    try expectPixel(bgra_black, pixelAt(&pixels, 8, 10));
    try expectPixel(bgra_black, pixelAt(&pixels, 8, 15));
    try expectPixel(bgra_black, pixelAt(&pixels, 15, 13));
    // Point: the four pixels around its centre, and nothing three away.
    try expectPixel(bgra_red, pixelAt(&pixels, 11, 4));
    try expectPixel(bgra_red, pixelAt(&pixels, 12, 5));
    try expectPixel(bgra_black, pixelAt(&pixels, 12, 8));
    try expectPixel(bgra_black, pixelAt(&pixels, 15, 5));
}

test "meshVertexCount expands each topology" {
    try testing.expectEqual(@as(u32, 21), dx11_renderer.meshVertexCount(.triangles, 3));
    try testing.expectEqual(@as(u32, 42), dx11_renderer.meshVertexCount(.triangles, 6));
    // A polyline of n points has n - 1 segments of six vertices.
    try testing.expectEqual(@as(u32, 0), dx11_renderer.meshVertexCount(.strip_expanded, 1));
    try testing.expectEqual(@as(u32, 12), dx11_renderer.meshVertexCount(.strip_expanded, 3));
    try testing.expectEqual(@as(u32, 18), dx11_renderer.meshVertexCount(.point_instanced, 3));
}

/// Read the top left `side_px` square of `atlas` back, tightly packed.
fn readAtlas(
    renderer: *dx11_renderer.Dx11Renderer,
    atlas: *const dx11_resources.Atlas,
    side_px: u32,
    out: []u8,
) !void {
    const format: u32 = switch (atlas.format) {
        .r8 => d3d11.DXGI_FORMAT_R8_UNORM,
        .rgba8 => d3d11.DXGI_FORMAT_R8G8B8A8_UNORM,
    };
    const bytes_per_pixel = atlas.format.bytesPerPixel();
    const whole = try testing.allocator.alloc(u8, atlas.side_px * atlas.side_px * bytes_per_pixel);
    defer testing.allocator.free(whole);
    var readback = try Readback.create(&renderer.device, atlas.side_px, atlas.side_px, format);
    defer readback.release();
    try readback.read(&renderer.device, atlas.texture, bytes_per_pixel, whole);
    const row_bytes = side_px * bytes_per_pixel;
    for (0..side_px) |row| {
        const source = whole[row * atlas.side_px * bytes_per_pixel ..][0..row_bytes];
        @memcpy(out[row * row_bytes ..][0..row_bytes], source);
    }
}

test "uploads land in their regions even when the draw presents nothing" {
    // Records for the R8 glyph atlas and the RGBA image atlas, staged and then
    // drawn at a zero-size viewport (a minimised window), which presents
    // nothing but must still land them. Each record is wider than tall and
    // ends short of its zeroed square's edge, so a transposed record, a wrong
    // row stride, a swapped channel, or a misread byte lane moves bytes.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const renderer = &harness.renderer;
    const glyph_zeroes: [8 * 8]u8 = @splat(0);
    renderer.uploadAtlas(.glyph, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, &glyph_zeroes);
    const coverage = [_]u8{ 1, 2, 3, 4, 5, 6 };
    renderer.uploadAtlas(.glyph, .{ .x = 4, .y = 5, .width = 3, .height = 2 }, &coverage);
    const image_zeroes: [4 * 4 * 4]u8 = @splat(0);
    renderer.uploadAtlas(.image, .{ .x = 0, .y = 0, .width = 4, .height = 4 }, &image_zeroes);
    const rgba = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    renderer.uploadAtlas(.image, .{ .x = 1, .y = 2, .width = 2, .height = 1 }, &rgba);

    const empty = backend.SizePx{ .width = 0, .height = 0 };
    renderer.resize(empty);
    harness.frame.reset(1, &.{});
    const black = geometry.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    renderer.draw(&harness.frame, .{ .size_px = empty, .scale_factor = 1 }, black);
    try testing.expectEqual(@as(u32, 0), renderer.uploads.record_count);

    var glyph: [8 * 8]u8 = undefined;
    try readAtlas(renderer, &renderer.atlases.glyph, 8, &glyph);
    for (glyph, 0..) |value, index| {
        const x = index % 8;
        const y = index / 8;
        const inside = x >= 4 and x < 7 and y >= 5 and y < 7;
        const expected: u8 = if (inside) coverage[(y - 5) * 3 + (x - 4)] else 0;
        try testing.expectEqual(expected, value);
    }
    var image: [4 * 4 * 4]u8 = undefined;
    try readAtlas(renderer, &renderer.atlases.image, 4, &image);
    for (0..4) |y| {
        for (0..4) |x| {
            const actual = image[(y * 4 + x) * 4 ..][0..4];
            const expected: [4]u8 = if (y == 2 and x >= 1 and x < 3)
                rgba[(x - 1) * 4 ..][0..4].*
            else
                .{ 0, 0, 0, 0 };
            try testing.expectEqualSlices(u8, &expected, actual);
        }
    }
}

test "an upload reaches its atlas after the draws submitted before it" {
    // One glyph texel drawn into target A, then replaced by a second upload
    // and drawn into target B, with nothing read back in between. Were the
    // second record written into the atlas before the GPU ran the first
    // frame's draw, A would show the second value too.
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const renderer = &harness.renderer;
    const second = try createRenderTarget(&renderer.device, Harness.side_px);
    defer second.release();
    var second_view: ?*d3d11.ID3D11RenderTargetView = null;
    try testing.expect(d3d11.succeeded(renderer.device.device.vtable.CreateRenderTargetView(
        renderer.device.device,
        second.resource(),
        null,
        &second_view,
    )));
    defer second_view.?.release();

    const side: f32 = @floatFromInt(renderer.atlases.glyph.side_px);
    harness.frame.reset(1, &.{});
    harness.pushSprite(.{
        .bounds = .{ 2, 3, 1, 1 },
        .uv = .{ 8 / side, 8 / side, 9 / side, 9 / side },
        .tint = .{ 1, 1, 1, 1 },
        .secondary = .{ 0, 0, 0, 0 },
        .corners = .{ 0, 0, 0, 0 },
        .grayscale = 0,
        .opacity = 1,
    });
    harness.pushDraw(.{ .pipeline = .glyph, .clip = clip_none, .first = 0, .count = 1 });
    const viewport = backend.Viewport{
        .size_px = .{ .width = Harness.side_px, .height = Harness.side_px },
        .scale_factor = 1,
    };
    const black = geometry.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    const region = backend.RectPx{ .x = 7, .y = 7, .width = 3, .height = 3 };
    const first_texels = [_]u8{ 0, 0, 0, 0, 255, 0, 0, 0, 0 };
    renderer.uploadAtlas(.glyph, region, &first_texels);
    try testing.expect(renderer.encode(harness.view, &harness.frame, viewport, black));
    const second_texels = [_]u8{ 0, 0, 0, 0, 64, 0, 0, 0, 0 };
    renderer.uploadAtlas(.glyph, region, &second_texels);
    try testing.expect(renderer.encode(second_view.?, &harness.frame, viewport, black));

    var pixels: [Harness.pixel_bytes]u8 = undefined;
    try harness.readback.read(&renderer.device, harness.texture, 4, &pixels);
    try expectPixel(.{ 255, 255, 255, 255 }, pixelAt(&pixels, 2, 3));
    try harness.readback.read(&renderer.device, second, 4, &pixels);
    try expectPixel(.{ 64, 64, 64, 255 }, pixelAt(&pixels, 2, 3));
    try expectPixel(bgra_black, pixelAt(&pixels, 3, 3));
}
