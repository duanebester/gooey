//! Backend contracts of the 0.4.0 core (contract §9), verified at comptime.
//!
//! The `Renderer` contract is one set of signatures every renderer satisfies,
//! checked with `contract.verifyFn` (complete function types), so a
//! renderer that drifts fails to compile with the offending declaration's
//! name instead of silently losing a feature.
//!
//! `PackedFrame` is the four-kind packed frame (`packed_frame.zig`): the pack stage
//! turns paint records into it, and every renderer on the contract draws it.
//! Renderers not yet on the contract draw a 0.3.1 `Scene` their host fills
//! from it (`pack_legacy.zig`) until phase 6 deletes the scene.

const std = @import("std");
const contract = @import("../platform/contract.zig");
const geometry = @import("../geometry/geometry.zig");
const packed_mod = @import("packed_frame.zig");
const limits_mod = @import("limits.zig");
const atlas_uploads = @import("../text/atlas_uploads.zig");

const assert = std.debug.assert;

/// Renderer input produced by the pack stage. See the file comment.
pub const PackedFrame = packed_mod.PackedFrame;

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

/// What `draw` renders into: the framebuffer extent and its scale. Packed
/// positions are logical pixels; a renderer maps `size_px / scale_factor`
/// logical pixels onto the framebuffer.
pub const Viewport = struct {
    size_px: SizePx,
    /// Device pixels per logical pixel.
    scale_factor: f32,

    /// The framebuffer a frame of `width` x `height` logical pixels needs,
    /// rounded to whole device pixels.
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
/// gated by `checkCapabilities` before every draw; it is never silently
/// dropped.
pub const Capabilities = struct {
    meshes: bool,
};

/// Verify `Renderer` against contract §9:
///
/// - `initInPlace` reserves everything the renderer will use for `limits`:
///   instance and geometry buffers at the scene limits, atlas textures at the
///   atlas limits, and nothing window-sized past `limits.window`. It takes no
///   allocator. A device that cannot hold the budget is an init error.
/// - `uploadAtlas` copies `pixels`, tightly packed rows of `dirty.width`
///   pixels (1 byte for `.glyph`, 4 bytes RGBA for the others), before it
///   returns. The region reaches the texture on the GPU timeline after every
///   draw submitted earlier and before the next `draw` samples it; it is
///   never a CPU write into a texture an in-flight frame may sample, because
///   the atlas may reuse a region such a frame still reads.
/// - `draw` renders every draw of the packed frame in order into a
///   framebuffer of `viewport.size_px`, cleared to `clear`, and presents it.
///   Instances within a draw composite in index order; a backend may merge
///   adjacent draws only if it keeps that order. Each draw writes only pixels
///   whose centres lie inside its clip rectangle, inclusive of its edges; a
///   clip with zero width or height writes nothing, and pack emits no draw
///   with one. The unbounded clip (±1e9) is clamped to the framebuffer in
///   float before any conversion to integer pixels, which it overflows above
///   scale 2.147. The frame is read only during the call.
/// - Colours are straight RGBA, sRGB-encoded, blended in gamma space into a
///   UNORM (not sRGB) framebuffer, as 0.3.1 drew on Metal and Vulkan.
/// - `draw` asserts `viewport.size_px` equals the last `resize` (or init). A
///   zero-size viewport (a minimised window) draws and presents nothing, but
///   pending atlas uploads still reach the GPU. An operating failure (no
///   drawable) skips the frame and is logged once; it is never a silent drop
///   of part of a frame.
/// - `resize` happens before a `draw` at a new size, and asserts the size is
///   within `limits.window`; it reuses reserved storage.
/// - `capabilities` reports features a renderer lacks; hosts call
///   `checkCapabilities` before every `draw`, which fails fast on a frame the
///   renderer cannot draw.
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

/// Fail fast when `frame` holds what `capabilities` says the renderer cannot
/// draw. Hosts call this before every `draw`: a missing feature stops the app
/// with its name, never drops part of a frame (CLAUDE.md §2).
pub fn checkCapabilities(capabilities: Capabilities, frame: *const PackedFrame) void {
    assert(frame.mesh_count <= frame.meshes.len);
    assert(frame.clip_count >= 1);
    if (frame.mesh_count > 0 and !capabilities.meshes) {
        std.debug.panic("Packed frame {d} holds {d} meshes, but its renderer reports " ++
            "Capabilities.meshes = false. Draw paths, polylines, and point clouds only on " ++
            "renderers that support meshes.", .{ frame.frame_number, frame.mesh_count });
    }
}

/// Hand `renderer` every atlas record its window has not uploaded, through
/// `uploadAtlas`, and mark them uploaded. Call on the render side before
/// `draw`; the journal stays locked only while the renderer copies.
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
