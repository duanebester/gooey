//! Render Pass Utilities - Common render pass setup and CATransaction handling
//!
//! This module provides helpers for creating Metal render passes and managing
//! synchronous rendering with CATransaction for smooth resize handling.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const geometry = @import("../../../core/geometry.zig");

/// Configuration for creating a render pass
pub const RenderPassConfig = struct {
    msaa_texture: objc.Object,
    resolve_texture: objc.Object,
    clear_color: geometry.Color,
    load_action: mtl.MTLLoadAction = .clear,
    store_action: mtl.MTLStoreAction = .multisample_resolve,
};

/// Configuration for a simple (non-MSAA) render pass
pub const SimpleRenderPassConfig = struct {
    texture: objc.Object,
    clear_color: ?geometry.Color = null,
    load_action: mtl.MTLLoadAction = .dont_care,
    store_action: mtl.MTLStoreAction = .store,
};

/// Create a render pass descriptor with MSAA configuration
pub fn createRenderPass(config: RenderPassConfig) ?objc.Object {
    const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor") orelse return null;
    const render_pass = MTLRenderPassDescriptor.msgSend(objc.Object, "renderPassDescriptor", .{});

    const color_attachments = render_pass.msgSend(objc.Object, "colorAttachments", .{});
    const color_attachment_0 = color_attachments.msgSend(
        objc.Object,
        "objectAtIndexedSubscript:",
        .{@as(c_ulong, 0)},
    );

    color_attachment_0.msgSend(void, "setTexture:", .{config.msaa_texture.value});
    color_attachment_0.msgSend(void, "setResolveTexture:", .{config.resolve_texture.value});
    color_attachment_0.msgSend(void, "setLoadAction:", .{@intFromEnum(config.load_action)});
    color_attachment_0.msgSend(void, "setStoreAction:", .{@intFromEnum(config.store_action)});
    color_attachment_0.msgSend(void, "setClearColor:", .{mtl.MTLClearColor.fromColor(config.clear_color)});

    return render_pass;
}

/// Create a simple render pass descriptor (no MSAA)
pub fn createSimpleRenderPass(config: SimpleRenderPassConfig) ?objc.Object {
    const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor") orelse return null;
    const render_pass = MTLRenderPassDescriptor.msgSend(objc.Object, "renderPassDescriptor", .{});

    const color_attachments = render_pass.msgSend(objc.Object, "colorAttachments", .{});
    const color_attachment_0 = color_attachments.msgSend(
        objc.Object,
        "objectAtIndexedSubscript:",
        .{@as(c_ulong, 0)},
    );

    color_attachment_0.msgSend(void, "setTexture:", .{config.texture.value});
    color_attachment_0.msgSend(void, "setLoadAction:", .{@intFromEnum(config.load_action)});
    color_attachment_0.msgSend(void, "setStoreAction:", .{@intFromEnum(config.store_action)});

    if (config.clear_color) |color| {
        color_attachment_0.msgSend(void, "setClearColor:", .{mtl.MTLClearColor.fromColor(color)});
    }

    return render_pass;
}

/// Create a render command encoder from a render pass
pub fn createEncoder(command_buffer: objc.Object, render_pass: objc.Object) ?objc.Object {
    const encoder_ptr = command_buffer.msgSend(
        ?*anyopaque,
        "renderCommandEncoderWithDescriptor:",
        .{render_pass.value},
    );
    if (encoder_ptr == null) return null;
    return objc.Object.fromId(encoder_ptr);
}

/// RAII wrapper for CATransaction - ensures commit on scope exit
pub const CATransactionScope = struct {
    ca_class: objc.Class,

    pub fn begin() ?CATransactionScope {
        const CATransaction = objc.getClass("CATransaction") orelse return null;
        CATransaction.msgSend(void, "begin", .{});
        CATransaction.msgSend(void, "setDisableActions:", .{true});
        return .{ .ca_class = CATransaction };
    }

    pub fn commit(self: CATransactionScope) void {
        self.ca_class.msgSend(void, "commit", .{});
    }
};

/// Get the next drawable from a layer
pub fn getNextDrawable(layer: objc.Object) ?struct { drawable: objc.Object, texture: objc.Object } {
    const drawable_ptr = layer.msgSend(?*anyopaque, "nextDrawable", .{});
    if (drawable_ptr == null) return null;
    const drawable = objc.Object.fromId(drawable_ptr);

    const texture_ptr = drawable.msgSend(?*anyopaque, "texture", .{});
    if (texture_ptr == null) return null;
    const texture = objc.Object.fromId(texture_ptr);

    return .{ .drawable = drawable, .texture = texture };
}

/// Setup viewport on encoder
pub fn setViewport(encoder: objc.Object, width: f64, height: f64, scale_factor: f64) void {
    const viewport = mtl.MTLViewport{
        .x = 0,
        .y = 0,
        .width = width * scale_factor,
        .height = height * scale_factor,
        .znear = 0,
        .zfar = 1,
    };
    encoder.msgSend(void, "setViewport:", .{viewport});
}

/// Finish encoding and present (async)
pub fn finishAndPresent(encoder: objc.Object, command_buffer: objc.Object, drawable: objc.Object) void {
    encoder.msgSend(void, "endEncoding", .{});
    command_buffer.msgSend(void, "presentDrawable:", .{drawable.value});
    command_buffer.msgSend(void, "commit", .{});
}

/// Finish encoding and present synchronously (for live resize)
pub fn finishAndPresentSync(encoder: objc.Object, command_buffer: objc.Object, drawable: objc.Object) void {
    encoder.msgSend(void, "endEncoding", .{});
    command_buffer.msgSend(void, "commit", .{});
    command_buffer.msgSend(void, "waitUntilScheduled", .{});
    drawable.msgSend(void, "present", .{});
}

/// Finish encoding, commit, and wait for completion
pub fn finishAndWait(encoder: objc.Object, command_buffer: objc.Object) void {
    encoder.msgSend(void, "endEncoding", .{});
    command_buffer.msgSend(void, "commit", .{});
    command_buffer.msgSend(void, "waitUntilCompleted", .{});
}
