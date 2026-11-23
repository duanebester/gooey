const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const mtl = @import("api.zig");
const shaders = @import("shaders.zig");
const limits = @import("../../../core/limits.zig");
const packed_frame = @import("../../../core/packed_frame.zig");

const Pipeline = packed_frame.Pipeline;

pub const frame_count_max: u32 = limits.MAX_FRAMES_IN_FLIGHT;

pub const sample_count: u32 = 1;

pub const pipeline_count = @typeInfo(Pipeline).@"enum".field_names.len;

const Blend = enum { straight, premultiplied };

const Spec = struct {
    vertex: [:0]const u8,
    fragment: [:0]const u8,
    blend: Blend,
};

const specs = std.EnumArray(Pipeline, Spec).init(.{
    .quad = .{ .vertex = "quad_vertex", .fragment = "quad_fragment", .blend = .straight },
    .glyph = .{ .vertex = "text_vertex", .fragment = "text_fragment", .blend = .straight },
    .svg = .{ .vertex = "svg_vertex", .fragment = "svg_fragment", .blend = .premultiplied },
    .image = .{ .vertex = "image_vertex", .fragment = "image_fragment", .blend = .straight },
    .triangles = .{
        .vertex = "triangle_vertex",
        .fragment = "triangle_fragment",
        .blend = .premultiplied,
    },
    .strip_expanded = .{
        .vertex = "polyline_vertex",
        .fragment = "polyline_fragment",
        .blend = .premultiplied,
    },
    .point_instanced = .{
        .vertex = "point_vertex",
        .fragment = "point_fragment",
        .blend = .premultiplied,
    },
});

pub const Pipelines = struct {
    states: [pipeline_count]objc.Object,

    pub fn init(device: objc.Object) !Pipelines {
        assert(device.value != null);
        const library = try compileLibrary(device);
        defer library.release();

        var result: Pipelines = .{ .states = undefined };
        var created: u32 = 0;
        errdefer for (result.states[0..created]) |pipeline_state| pipeline_state.release();
        while (created < pipeline_count) : (created += 1) {
            const pipeline: Pipeline = @fromBackingInt(@intCast(created));
            result.states[created] = try createState(device, library, specs.get(pipeline));
        }
        assert(created == pipeline_count);
        return result;
    }

    pub fn deinit(self: *Pipelines) void {
        assert(self.states.len == pipeline_count);
        for (self.states) |pipeline_state| pipeline_state.release();
        self.* = undefined;
    }

    pub fn state(self: *const Pipelines, pipeline: Pipeline) objc.Object {
        const index = @backingInt(pipeline);
        assert(index < pipeline_count);
        return self.states[index];
    }
};

fn nsString(text: [:0]const u8) objc.Object {
    assert(text.len > 0);
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{text.ptr});
}

fn compileLibrary(device: objc.Object) !objc.Object {
    assert(shaders.source.len > 0);
    var compile_error: ?*anyopaque = null;
    const library_ptr = device.msgSend(?*anyopaque, "newLibraryWithSource:options:error:", .{
        nsString(shaders.source).value,
        @as(?*anyopaque, null),
        &compile_error,
    }) orelse {
        if (compile_error) |err| {
            const failure = objc.Object.fromId(err);
            const description = failure.msgSend(objc.Object, "localizedDescription", .{});
            const text = description.msgSend([*:0]const u8, "UTF8String", .{});
            std.log.err("Metal shader library failed to compile: {s}", .{text});
        }
        return error.ShaderCompilationFailed;
    };
    return objc.Object.fromId(library_ptr);
}

fn createState(device: objc.Object, library: objc.Object, spec: Spec) !objc.Object {
    assert(spec.vertex.len > 0);
    assert(spec.fragment.len > 0);
    const vertex_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{
        nsString(spec.vertex).value,
    }) orelse return error.ShaderFunctionNotFound;
    const vertex_fn = objc.Object.fromId(vertex_ptr);
    defer vertex_fn.release();
    const fragment_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{
        nsString(spec.fragment).value,
    }) orelse return error.ShaderFunctionNotFound;
    const fragment_fn = objc.Object.fromId(fragment_ptr);
    defer fragment_fn.release();

    const Descriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const descriptor = Descriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer descriptor.release();
    descriptor.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    descriptor.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    descriptor.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});
    const attachments = descriptor.msgSend(objc.Object, "colorAttachments", .{});
    const attachment = attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{
        @as(c_ulong, 0),
    });
    configureBlending(attachment, spec.blend);

    const state_ptr = device.msgSend(?*anyopaque, "newRenderPipelineStateWithDescriptor:error:", .{
        descriptor.value,
        @as(?*anyopaque, null),
    }) orelse {
        std.log.err("Metal pipeline {s}/{s} could not be created.", .{
            spec.vertex,
            spec.fragment,
        });
        return error.PipelineCreationFailed;
    };
    return objc.Object.fromId(state_ptr);
}

fn configureBlending(attachment: objc.Object, blend: Blend) void {
    assert(attachment.value != null);
    const source_rgb: mtl.MTLBlendFactor = switch (blend) {
        .straight => .source_alpha,
        .premultiplied => .one,
    };
    const one_minus_source_alpha = @backingInt(mtl.MTLBlendFactor.one_minus_source_alpha);
    attachment.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.bgra8unorm)});
    attachment.msgSend(void, "setBlendingEnabled:", .{true});
    attachment.msgSend(void, "setSourceRGBBlendFactor:", .{@backingInt(source_rgb)});
    attachment.msgSend(void, "setDestinationRGBBlendFactor:", .{one_minus_source_alpha});
    attachment.msgSend(void, "setSourceAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attachment.msgSend(void, "setDestinationAlphaBlendFactor:", .{one_minus_source_alpha});
}

pub const FrameBuffers = struct {
    buffers: [frame_count_max]objc.Object,
    count: u32,

    pub fn at(self: *const FrameBuffers, frame_index: u32) objc.Object {
        assert(self.count <= frame_count_max);
        assert(frame_index < self.count);
        return self.buffers[frame_index];
    }

    pub fn release(self: *const FrameBuffers) void {
        assert(self.count <= frame_count_max);
        for (self.buffers[0..self.count]) |buffer| buffer.release();
    }
};

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
            "Metal buffer '{s}' needs {d} B per frame (ResourceLimits), above " ++
                "the device's maxBufferLength of {d} B.",
            .{ name, size_bytes, length_max },
        );
        return error.BufferTooLarge;
    }
    const options: mtl.MTLResourceOptions = .{
        .cpu_cache_mode = .write_combined,
        .storage_mode = .shared,
        .hazard_tracking_mode = .default,
    };

    var result: FrameBuffers = .{ .buffers = undefined, .count = 0 };
    errdefer result.release();

    while (result.count < frame_count) : (result.count += 1) {
        const buffer_ptr = device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
            @as(c_ulong, size_bytes),
            @as(c_ulong, @bitCast(options)),
        }) orelse return error.BufferCreationFailed;
        result.buffers[result.count] = objc.Object.fromId(buffer_ptr);
        assert(result.buffers[result.count].msgSend(c_ulong, "length", .{}) == size_bytes);
    }
    assert(result.count == frame_count);
    return result;
}

pub fn frameBufferContents(comptime T: type, buffer: objc.Object) [*]T {
    const contents = buffer.msgSend(*anyopaque, "contents", .{});
    assert(@intFromPtr(contents) % @alignOf(T) == 0);
    return @ptrCast(@alignCast(contents));
}
