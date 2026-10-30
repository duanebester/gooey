//! Backend contracts of the 0.4.0 core (contract §9), verified at comptime.
//!
//! The `Renderer` contract is one set of signatures every renderer satisfies,
//! checked with `contract.verifyFn` exactly like the platform contract, so a
//! renderer that drifts fails to compile with the offending declaration's
//! name instead of silently losing a feature.
//!
//! `PackedFrame` is the 0.3.1 `Scene` until phase 5: the pack stage turns
//! paint records into the input the existing Metal, Vulkan, and web renderers
//! already draw. Only this alias changes when the four-kind Scene lands.

const std = @import("std");
const contract = @import("../platform/contract.zig");
const geometry = @import("../geometry/geometry.zig");
const scene_mod = @import("../scene/mod.zig");
const limits_mod = @import("limits.zig");

const assert = std.debug.assert;

/// Renderer input produced by the pack stage. See the file comment.
pub const PackedFrame = scene_mod.Scene;

pub const Color = geometry.Color;

/// The atlas a sprite samples and `uploadAtlas` writes.
pub const AtlasKind = enum(u8) { glyph, glyph_color, svg, image };

/// A rectangle in device pixels within an atlas or a framebuffer.
pub const RectPx = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Framebuffer extent in device pixels.
pub const SizePx = struct {
    width: u32,
    height: u32,
};

/// What `draw` renders into: the framebuffer extent and its scale.
pub const Viewport = struct {
    size_px: SizePx,
    /// Device pixels per logical pixel.
    scale_factor: f32,
};

/// The surface a renderer draws to. `native` is the platform object (a
/// `CAMetalLayer`, a `VkSurfaceKHR`, a canvas), or null for headless.
pub const Surface = struct {
    native: ?*anyopaque,
    size_px: SizePx,
    scale_factor: f32,
};

/// The slice of `ResourceLimits` a renderer reserves against.
pub const RenderLimits = struct {
    window: limits_mod.WindowLimits,
    scene: limits_mod.SceneLimits,
    frame: limits_mod.FrameLimits,
    atlas: limits_mod.AtlasLimits,

    pub fn fromResourceLimits(resource_limits: *const limits_mod.ResourceLimits) RenderLimits {
        assert(resource_limits.check() == null);
        const result = RenderLimits{
            .window = resource_limits.window,
            .scene = resource_limits.scene,
            .frame = resource_limits.frame,
            .atlas = resource_limits.atlas,
        };
        assert(result.window.framebuffer_width_max > 0);
        return result;
    }
};

/// What a renderer can draw. A feature a renderer lacks is reported here and
/// gated by the caller; it is never silently dropped.
pub const Capabilities = struct {
    post_process: bool,
    custom_shaders: bool,
    meshes: bool,
};

/// Verify `Renderer` against contract §9.
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

test "RenderLimits carries the profile's window budget" {
    const render_limits = RenderLimits.fromResourceLimits(&limits_mod.ResourceLimits.nano);
    try std.testing.expectEqual(
        limits_mod.WindowLimits.nano.framebuffer_width_max,
        render_limits.window.framebuffer_width_max,
    );
}
