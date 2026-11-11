//! Render pass helpers: the single-sample pass over a drawable, its encoder,
//! its viewport, and the present.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const mtl = @import("api.zig");
const geometry = @import("../../../geometry/geometry.zig");
const backend = @import("../../../core/backend.zig");

/// Configuration for a single-sample render pass (`pipelines.sample_count`).
pub const SimpleRenderPassConfig = struct {
    texture: objc.Object,
    clear_color: ?geometry.Color = null,
    load_action: mtl.MTLLoadAction = .dont_care,
    store_action: mtl.MTLStoreAction = .store,
};

/// Create a single-sample render pass descriptor that draws into `texture`.
pub fn createSimpleRenderPass(config: SimpleRenderPassConfig) ?objc.Object {
    assert(config.texture.value != null);
    if (config.load_action == .clear) assert(config.clear_color != null);
    const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor") orelse return null;
    const render_pass = MTLRenderPassDescriptor.msgSend(objc.Object, "renderPassDescriptor", .{});

    const color_attachments = render_pass.msgSend(objc.Object, "colorAttachments", .{});
    const color_attachment_0 = color_attachments.msgSend(
        objc.Object,
        "objectAtIndexedSubscript:",
        .{@as(c_ulong, 0)},
    );

    color_attachment_0.msgSend(void, "setTexture:", .{config.texture.value});
    color_attachment_0.msgSend(void, "setLoadAction:", .{@backingInt(config.load_action)});
    color_attachment_0.msgSend(void, "setStoreAction:", .{@backingInt(config.store_action)});

    if (config.clear_color) |color| {
        color_attachment_0.msgSend(void, "setClearColor:", .{mtl.MTLClearColor.fromColor(color)});
    }

    return render_pass;
}

/// Create a render command encoder from a render pass
pub fn createEncoder(command_buffer: objc.Object, render_pass: objc.Object) ?objc.Object {
    assert(command_buffer.value != null);
    assert(render_pass.value != null);
    const encoder_ptr = command_buffer.msgSend(
        ?*anyopaque,
        "renderCommandEncoderWithDescriptor:",
        .{render_pass.value},
    );
    if (encoder_ptr == null) return null;
    return objc.Object.fromId(encoder_ptr);
}

/// Get the next drawable from a layer
pub fn getNextDrawable(layer: objc.Object) ?struct { drawable: objc.Object, texture: objc.Object } {
    assert(layer.value != null);
    const drawable_ptr = layer.msgSend(?*anyopaque, "nextDrawable", .{});
    if (drawable_ptr == null) return null;
    const drawable = objc.Object.fromId(drawable_ptr);

    const texture_ptr = drawable.msgSend(?*anyopaque, "texture", .{});
    if (texture_ptr == null) return null;
    const texture = objc.Object.fromId(texture_ptr);

    return .{ .drawable = drawable, .texture = texture };
}

/// Map the render pass onto the whole framebuffer of `size_px`.
pub fn setViewport(encoder: objc.Object, size_px: backend.SizePx) void {
    assert(size_px.width > 0);
    assert(size_px.height > 0);
    const viewport = mtl.MTLViewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(size_px.width),
        .height = @floatFromInt(size_px.height),
        .znear = 0,
        .zfar = 1,
    };
    encoder.msgSend(void, "setViewport:", .{viewport});
}

/// Finish encoding, schedule the present, and commit.
pub fn finishAndPresent(
    encoder: objc.Object,
    command_buffer: objc.Object,
    drawable: objc.Object,
) void {
    assert(command_buffer.value != null);
    assert(drawable.value != null);
    encoder.msgSend(void, "endEncoding", .{});
    command_buffer.msgSend(void, "presentDrawable:", .{drawable.value});
    command_buffer.msgSend(void, "commit", .{});
}
