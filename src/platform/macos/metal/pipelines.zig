//! Pipeline Setup - Metal pipeline state creation for quads and shadows
//!
//! This module handles the creation and configuration of Metal render pipelines.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const mtl = @import("api.zig");
const quad_shader = @import("quad.zig");
const shadow_shader = @import("shadow.zig");
const limits = @import("../../../core/limits.zig");

/// Most frames in flight any budget may declare. Per-frame Metal buffers are
/// declared at this size and created for the window budget's
/// `ResourceLimits.frame.in_flight_count`. The in-flight proof is the one
/// documented on `UnifiedPrimitiveRing`: the renderer sets the layer's
/// `maximumDrawableCount` to that same count at init.
pub const frame_count_max: u32 = limits.MAX_FRAMES_IN_FLIGHT;

/// Samples per pixel of every render target and pipeline. Metal draws one
/// sample per pixel, like Vulkan: quads, glyphs, SVGs, images and points fade
/// their edges in the fragment shader, and path triangles and polylines
/// compute analytic edge coverage (`mesh_edges.zig`). Without an MSAA target
/// nothing window-sized is allocated or recreated on resize (CLAUDE.md §2).
pub const sample_count: u32 = 1;

/// One shared buffer per frame in flight, created once in `init` and rotated
/// with `nextIndex`. Entries past `count` are never created or read.
pub const FrameBuffers = struct {
    buffers: [frame_count_max]objc.Object,
    count: u32,

    /// The buffer of frame slot `frame_index`.
    pub fn at(self: *const FrameBuffers, frame_index: u32) objc.Object {
        assert(self.count <= frame_count_max);
        assert(frame_index < self.count);
        return self.buffers[frame_index];
    }

    /// The slot after `frame_index`, wrapping at the budget's frame count.
    pub fn nextIndex(self: *const FrameBuffers, frame_index: u32) u32 {
        assert(self.count >= limits.MIN_FRAMES_IN_FLIGHT);
        assert(frame_index < self.count);
        return (frame_index + 1) % self.count;
    }

    pub fn release(self: *const FrameBuffers) void {
        assert(self.count <= frame_count_max);
        for (self.buffers[0..self.count]) |buffer| buffer.release();
    }
};

/// Create one shared buffer of `size_bytes` per frame in flight. Mesh and
/// instance pipelines call this only from `init`, with sizes derived from
/// `ResourceLimits.scene` and `frame_count` from `ResourceLimits.frame`, and
/// never replace the buffers. A budget the device cannot hold fails here,
/// naming the buffer, rather than at draw time.
pub fn createFrameBuffers(
    device: objc.Object,
    size_bytes: u64,
    name: []const u8,
    frame_count: u32,
) !FrameBuffers {
    assert(size_bytes > 0);
    assert(name.len > 0);
    assert(frame_count >= limits.MIN_FRAMES_IN_FLIGHT);
    assert(frame_count <= frame_count_max);
    const length_max: u64 = device.msgSend(c_ulong, "maxBufferLength", .{});
    if (size_bytes > length_max) {
        std.log.err(
            "Metal buffer '{s}' needs {d} B per frame (ResourceLimits.scene), above " ++
                "the device's maxBufferLength of {d} B.",
            .{ name, size_bytes, length_max },
        );
        return error.BufferTooLarge;
    }

    var result: FrameBuffers = .{ .buffers = undefined, .count = 0 };
    errdefer result.release();

    while (result.count < frame_count) : (result.count += 1) {
        // Fresh shared buffers are zero-filled; draws read only the prefix written
        // in the same frame, so no stale bytes from an earlier frame are exposed.
        const buffer_ptr = device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
            @as(c_ulong, size_bytes),
            @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
        }) orelse return error.BufferCreationFailed;
        result.buffers[result.count] = objc.Object.fromId(buffer_ptr);
        assert(result.buffers[result.count].msgSend(c_ulong, "length", .{}) == size_bytes);
    }
    assert(result.count == frame_count);
    return result;
}

/// CPU-visible base address of a buffer made by `createFrameBuffers`, as `[*]T`.
pub fn frameBufferContents(comptime T: type, buffer: objc.Object) [*]T {
    const contents = buffer.msgSend(*anyopaque, "contents", .{});
    assert(@intFromPtr(contents) % @alignOf(T) == 0);
    return @ptrCast(@alignCast(contents));
}

/// Setup shadow rendering pipeline
pub fn setupShadowPipeline(device: objc.Object) !objc.Object {
    assert(device.value != null);
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
    defer library.release();

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"shadow_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"shadow_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }
    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.release();
    defer fragment_fn.release();

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer desc.release();

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
pub fn setupQuadPipeline(device: objc.Object) !objc.Object {
    assert(device.value != null);
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
    defer library.release();

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"quad_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"quad_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }
    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.release();
    defer fragment_fn.release();

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
    attachment.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.bgra8unorm)});
    attachment.msgSend(void, "setBlendingEnabled:", .{true});
    attachment.msgSend(void, "setSourceRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.source_alpha)});
    attachment.msgSend(void, "setDestinationRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attachment.msgSend(void, "setSourceAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attachment.msgSend(void, "setDestinationAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});
}

/// Setup unified quad+shadow rendering pipeline
pub fn setupUnifiedPipeline(device: objc.Object) !objc.Object {
    assert(device.value != null);
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
    defer library.release();

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"unified_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"unified_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }
    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.release();
    defer fragment_fn.release();

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer desc.release();

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
