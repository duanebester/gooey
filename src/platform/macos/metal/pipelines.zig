//! Pipeline Setup - Metal pipeline state creation for quads, shadows, and MSAA
//!
//! This module handles the creation and configuration of Metal render pipelines.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const quad_shader = @import("quad.zig");
const shadow_shader = @import("shadow.zig");

/// Create MSAA texture for multi-sample anti-aliasing
pub fn createMSAATexture(
    device: objc.Object,
    width: f64,
    height: f64,
    scale_factor: f64,
    sample_count: u32,
    unified_memory: bool,
) !objc.Object {
    const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse
        return error.ClassNotFound;

    const desc = MTLTextureDescriptor.msgSend(
        objc.Object,
        "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        .{
            @intFromEnum(mtl.MTLPixelFormat.bgra8unorm),
            @as(c_ulong, @intFromFloat(width * scale_factor)),
            @as(c_ulong, @intFromFloat(height * scale_factor)),
            false,
        },
    );

    desc.msgSend(void, "setTextureType:", .{@intFromEnum(mtl.MTLTextureType.type_2d_multisample)});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    const usage = mtl.MTLTextureUsage.render_target_only;
    desc.msgSend(void, "setUsage:", .{@as(c_ulong, @bitCast(usage))});

    // Use memoryless on unified memory (Apple Silicon)
    const storage_mode: mtl.MTLStorageMode = if (unified_memory)
        .memoryless
    else
        .private;

    desc.msgSend(void, "setStorageMode:", .{@intFromEnum(storage_mode)});

    const texture_ptr = device.msgSend(?*anyopaque, "newTextureWithDescriptor:", .{desc.value});
    if (texture_ptr == null) {
        return error.MSAATextureCreationFailed;
    }
    return objc.Object.fromId(texture_ptr);
}

/// Setup shadow rendering pipeline
pub fn setupShadowPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{shadow_shader.shadow_shader_source.ptr},
    );

    var compile_error: ?*anyopaque = null;
    const library_ptr = device.msgSend(
        ?*anyopaque,
        "newLibraryWithSource:options:error:",
        .{ source_str.value, @as(?*anyopaque, null), &compile_error },
    );
    if (library_ptr == null) {
        if (compile_error) |err| {
            const err_obj = objc.Object.fromId(err);
            const desc = err_obj.msgSend(objc.Object, "localizedDescription", .{});
            const cstr = desc.msgSend([*:0]const u8, "UTF8String", .{});
            std.debug.print("Shadow shader compilation error: {s}\n", .{cstr});
        }
        return error.ShaderCompilationFailed;
    }

    const library = objc.Object.fromId(library_ptr);
    defer library.msgSend(void, "release", .{});

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"shadow_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"shadow_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }
    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.msgSend(void, "release", .{});
    defer fragment_fn.msgSend(void, "release", .{});

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer desc.msgSend(void, "release", .{});

    desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
    configureBlending(attachment0);

    const pipeline_ptr = device.msgSend(
        ?*anyopaque,
        "newRenderPipelineStateWithDescriptor:error:",
        .{ desc.value, @as(?*anyopaque, null) },
    );
    if (pipeline_ptr == null) {
        return error.PipelineCreationFailed;
    }

    std.debug.print("Shadow pipeline created successfully\n", .{});
    return objc.Object.fromId(pipeline_ptr);
}

/// Setup quad rendering pipeline
pub fn setupQuadPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{quad_shader.quad_shader_source.ptr},
    );

    const library_ptr = device.msgSend(
        ?*anyopaque,
        "newLibraryWithSource:options:error:",
        .{ source_str.value, @as(?*anyopaque, null), @as(?*anyopaque, null) },
    );
    if (library_ptr == null) {
        return error.ShaderCompilationFailed;
    }
    const library = objc.Object.fromId(library_ptr);
    defer library.msgSend(void, "release", .{});

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"quad_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"quad_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }
    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.msgSend(void, "release", .{});
    defer fragment_fn.msgSend(void, "release", .{});

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const pipeline_desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});

    pipeline_desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    pipeline_desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    pipeline_desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    const color_attachments = pipeline_desc.msgSend(objc.Object, "colorAttachments", .{});
    const color_attachment_0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
    configureBlending(color_attachment_0);

    const pipeline_ptr = device.msgSend(
        ?*anyopaque,
        "newRenderPipelineStateWithDescriptor:error:",
        .{ pipeline_desc.value, @as(?*anyopaque, null) },
    );
    if (pipeline_ptr == null) {
        return error.PipelineCreationFailed;
    }
    return objc.Object.fromId(pipeline_ptr);
}

/// Create unit vertex buffer for quad/shadow rendering
pub fn createUnitVertexBuffer(device: objc.Object, unified_memory: bool) !objc.Object {
    const buffer_storage: mtl.MTLResourceOptions = if (unified_memory)
        .{ .storage_mode = .shared }
    else
        .{ .storage_mode = .managed };

    const buffer_ptr = device.msgSend(
        ?*anyopaque,
        "newBufferWithBytes:length:options:",
        .{
            @as(*const anyopaque, @ptrCast(&quad_shader.unit_vertices)),
            @as(c_ulong, @sizeOf(@TypeOf(quad_shader.unit_vertices))),
            @as(c_ulong, @bitCast(buffer_storage)),
        },
    );
    if (buffer_ptr == null) {
        return error.BufferCreationFailed;
    }
    return objc.Object.fromId(buffer_ptr);
}

/// Configure standard alpha blending on a color attachment
fn configureBlending(attachment: objc.Object) void {
    attachment.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});
    attachment.msgSend(void, "setBlendingEnabled:", .{true});
    attachment.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.source_alpha)});
    attachment.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attachment.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
    attachment.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
}

/// Setup unified quad+shadow rendering pipeline
pub fn setupUnifiedPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const unified_shader = @import("../../unified.zig");
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{unified_shader.unified_shader_source.ptr},
    );

    var compile_error: ?*anyopaque = null;
    const library_ptr = device.msgSend(
        ?*anyopaque,
        "newLibraryWithSource:options:error:",
        .{ source_str.value, @as(?*anyopaque, null), &compile_error },
    );
    if (library_ptr == null) {
        if (compile_error) |err| {
            const err_obj = objc.Object.fromId(err);
            const desc = err_obj.msgSend(objc.Object, "localizedDescription", .{});
            const cstr = desc.msgSend([*:0]const u8, "UTF8String", .{});
            std.debug.print("Unified shader compilation error: {s}\n", .{cstr});
        }
        return error.ShaderCompilationFailed;
    }

    const library = objc.Object.fromId(library_ptr);
    defer library.msgSend(void, "release", .{});

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"unified_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"unified_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }
    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.msgSend(void, "release", .{});
    defer fragment_fn.msgSend(void, "release", .{});

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer desc.msgSend(void, "release", .{});

    desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
    configureBlending(attachment0);

    const pipeline_ptr = device.msgSend(
        ?*anyopaque,
        "newRenderPipelineStateWithDescriptor:error:",
        .{ desc.value, @as(?*anyopaque, null) },
    );
    if (pipeline_ptr == null) {
        return error.PipelineCreationFailed;
    }

    std.debug.print("Unified pipeline created successfully\n", .{});
    return objc.Object.fromId(pipeline_ptr);
}
