const std = @import("std");
const contract = @import("../platform/contract.zig");
const geometry = @import("../geometry/geometry.zig");
const packed_mod = @import("packed_frame.zig");
const limits_mod = @import("limits.zig");
const atlas_uploads = @import("../text/atlas_uploads.zig");
const shader_mod = @import("shader.zig");

const assert = std.debug.assert;

pub const PackedFrame = packed_mod.PackedFrame;

pub const Color = geometry.Color;

pub const AtlasKind = enum(u8) { glyph, glyph_color, svg, image };

pub const RectPx = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const SizePx = struct {
    width: u32,
    height: u32,
};

pub const Viewport = struct {
    size_px: SizePx,
    scale_factor: f32,

    pub fn fromLogical(width: f32, height: f32, scale_factor: f32) Viewport {
        assert(scale_factor > 0);
        assert(width >= 0);
        assert(height >= 0);
        const width_px = @round(width * scale_factor);
        const height_px = @round(height * scale_factor);
        assert(width_px < 4_294_967_296.0);
        assert(height_px < 4_294_967_296.0);
        return .{
            .size_px = .{ .width = @intFromFloat(width_px), .height = @intFromFloat(height_px) },
            .scale_factor = scale_factor,
        };
    }

    pub fn fitLogical(
        width: f32,
        height: f32,
        scale_factor: f32,
        window: *const limits_mod.WindowLimits,
    ) Viewport {
        assert(width > 0);
        assert(height > 0);
        assert(scale_factor > 0);
        const width_max: f32 = @floatFromInt(window.framebuffer_width_max);
        const height_max: f32 = @floatFromInt(window.framebuffer_height_max);
        const scale = @min(scale_factor, width_max / width, height_max / height);
        var viewport = fromLogical(width, height, scale);
        viewport.size_px = .{
            .width = std.math.clamp(viewport.size_px.width, 1, window.framebuffer_width_max),
            .height = std.math.clamp(viewport.size_px.height, 1, window.framebuffer_height_max),
        };
        assert(viewport.scale_factor <= scale_factor);
        assert(viewport.size_px.width <= window.framebuffer_width_max);
        return viewport;
    }
};

pub const Surface = struct {
    native: ?*anyopaque,
    size_px: SizePx,
    scale_factor: f32,
};

pub const RenderLimits = struct {
    window: limits_mod.WindowLimits,
    paint: limits_mod.PaintLimits,
    frame: limits_mod.FrameLimits,
    atlas: limits_mod.AtlasLimits,
    /// The app's declared shaders, at most `paint.shader_count_max`. A renderer that
    /// draws custom fills compiles one pipeline per entry at init.
    shaders: []const *const shader_mod.Spec,

    pub fn fromResourceLimits(resource_limits: *const limits_mod.ResourceLimits) RenderLimits {
        assert(resource_limits.check() == null);
        const result = RenderLimits{
            .window = resource_limits.window,
            .paint = resource_limits.paint,
            .frame = resource_limits.frame,
            .atlas = resource_limits.atlas,
            .shaders = &.{},
        };
        assert(result.window.framebuffer_width_max > 0);
        return result;
    }
};

pub const Capabilities = struct {
    meshes: bool,
    /// Draws `.custom` pipelines with the shaders from `RenderLimits.shaders`.
    custom_shaders: bool,
};

pub fn verifyRenderer(comptime Renderer: type) void {
    comptime {
        contract.verifyFn(Renderer, "initInPlace", .{
            .params = &.{ *Renderer, *const Surface, *const RenderLimits },
            .returns = void,
            .errors = .required,
        });
        contract.verifyFn(Renderer, "uploadAtlas", .{
            .params = &.{ *Renderer, AtlasKind, RectPx, []const u8 },
            .returns = void,
        });
        contract.verifyFn(Renderer, "draw", .{
            .params = &.{ *Renderer, *const PackedFrame, Viewport, Color },
            .returns = void,
        });
        contract.verifyFn(Renderer, "resize", .{
            .params = &.{ *Renderer, SizePx },
            .returns = void,
        });
        contract.verifyFn(Renderer, "capabilities", .{
            .params = &.{*const Renderer},
            .returns = Capabilities,
        });
        contract.verifyFn(Renderer, "deinit", .{
            .params = &.{*Renderer},
            .returns = void,
        });
    }
}

pub fn checkCapabilities(capabilities: Capabilities, frame: *const PackedFrame) void {
    assert(frame.mesh_count <= frame.meshes.len);
    assert(frame.clip_count >= 1);
    if (frame.mesh_count > 0 and !capabilities.meshes) {
        std.debug.panic("Packed frame {d} holds {d} meshes, but its renderer reports " ++
            "Capabilities.meshes = false. Draw paths, polylines, and point clouds only on " ++
            "renderers that support meshes.", .{ frame.frame_number, frame.mesh_count });
    }
    if (frame.custom_count > 0 and !capabilities.custom_shaders) {
        std.debug.panic("Packed frame {d} holds {d} custom-shader fills, but its renderer " ++
            "reports Capabilities.custom_shaders = false. Custom fills draw on Metal only.", .{
            frame.frame_number,
            frame.custom_count,
        });
    }
}

pub fn uploadPendingAtlases(
    renderer: anytype,
    uploads: *atlas_uploads.AtlasUploads,
    key: usize,
) void {
    assert(key != 0);
    const pending = uploads.consumeBegin(key);
    defer uploads.consumeEnd(key);
    for (pending.records) |record| {
        const byte_count = record.byteCount();
        assert(record.offset + byte_count <= pending.bytes.len);
        const kind: AtlasKind = switch (record.kind) {
            .text => .glyph,
            .svg => .svg,
            .image => .image,
        };
        renderer.uploadAtlas(kind, .{
            .x = record.x,
            .y = record.y,
            .width = record.width,
            .height = record.height,
        }, pending.bytes[record.offset..][0..byte_count]);
    }
}

test "RenderLimits carries the profile's window budget" {
    const render_limits = RenderLimits.fromResourceLimits(&limits_mod.ResourceLimits.nano);
    try std.testing.expectEqual(
        limits_mod.WindowLimits.nano.framebuffer_width_max,
        render_limits.window.framebuffer_width_max,
    );
}

test "fitLogical keeps the scale within the budget and lowers it past" {
    const window = limits_mod.WindowLimits{
        .framebuffer_width_max = 2000,
        .framebuffer_height_max = 900,
    };
    const fits = Viewport.fitLogical(1000, 450, 2, &window);
    try std.testing.expectEqual(@as(f32, 2), fits.scale_factor);
    try std.testing.expectEqual(SizePx{ .width = 2000, .height = 900 }, fits.size_px);
    const past = Viewport.fitLogical(1000, 451, 2, &window);
    try std.testing.expect(past.scale_factor < 2);
    try std.testing.expectEqual(@as(u32, 900), past.size_px.height);
    try std.testing.expectEqual(@as(u32, 1996), past.size_px.width);
    const fractional = Viewport.fitLogical(667.333, 400, 1.5, &window);
    try std.testing.expectEqual(SizePx{ .width = 1001, .height = 600 }, fractional.size_px);
}
