const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const mtl = @import("api.zig");
const shaders = @import("shaders.zig");
const limits = @import("../../../core/limits.zig");
const packed_frame = @import("../../../core/packed_frame.zig");
const reservation = @import("../../../core/reservation.zig");
const shader_mod = @import("../../../core/shader.zig");
const custom_library = @import("custom_library.zig");

const Pipeline = packed_frame.Pipeline;
const BuiltinPipeline = packed_frame.BuiltinPipeline;

pub const frame_count_max: u32 = limits.MAX_FRAMES_IN_FLIGHT;

pub const sample_count: u32 = 1;

pub const pipeline_count = packed_frame.builtin_pipeline_count;

pub const custom_count_max = limits.MAX_SHADERS;

const Blend = enum { straight, premultiplied };

const Spec = struct {
    vertex: [:0]const u8,
    fragment: [:0]const u8,
    blend: Blend,
};

const specs = std.EnumArray(BuiltinPipeline, Spec).init(.{
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

pub const Options = custom_library.Options;

/// Gooey's pipelines plus one per declared custom shader, from one library compiled at
/// init. Cold, that costs about 100 ms plus about 4.5 ms per shader on an M2 Max; the
/// Metal cache brings a relaunch to about 1.5 ms.
pub const Pipelines = struct {
    states: [pipeline_count]objc.Object,
    custom_states: [custom_count_max]objc.Object,
    custom_count: u32,

    pub fn init(device: objc.Object, options: *const Options) !Pipelines {
        assert(device.value != null);
        assert(options.shaders.len <= custom_count_max);
        const library = try compileLibrary(device, options);
        defer library.release();

        var result: Pipelines = .{
            .states = undefined,
            .custom_states = undefined,
            .custom_count = 0,
        };
        var created: u32 = 0;
        errdefer for (result.states[0..created]) |pipeline_state| pipeline_state.release();
        while (created < pipeline_count) : (created += 1) {
            const pipeline: BuiltinPipeline = @fromBackingInt(@intCast(created));
            result.states[created] = try createState(device, library, specs.get(pipeline));
        }
        errdefer for (result.custom_states[0..result.custom_count]) |state_| state_.release();
        for (options.shaders) |spec| {
            var name_buffer: [64]u8 = undefined;
            const fragment = custom_library.fragmentName(&name_buffer, spec);
            result.custom_states[result.custom_count] = try createState(device, library, .{
                .vertex = "custom_vertex",
                .fragment = fragment,
                .blend = .straight,
            });
            result.custom_count += 1;
        }
        assert(created == pipeline_count);
        assert(result.custom_count == options.shaders.len);
        return result;
    }

    pub fn deinit(self: *Pipelines) void {
        assert(self.custom_count <= custom_count_max);
        for (self.states) |pipeline_state| pipeline_state.release();
        for (self.custom_states[0..self.custom_count]) |pipeline_state| pipeline_state.release();
        self.* = undefined;
    }

    /// The state for a draw: a builtin pipeline, or the `.custom` draw's shader.
    pub fn state(self: *const Pipelines, pipeline: Pipeline, shader: u8) objc.Object {
        const index = @backingInt(pipeline);
        if (pipeline == .custom) {
            assert(shader < self.custom_count);
            return self.custom_states[shader];
        }
        assert(shader == 0);
        assert(index < pipeline_count);
        return self.states[index];
    }
};

fn nsString(text: [:0]const u8) objc.Object {
    assert(text.len > 0);
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{text.ptr});
}

/// Compile Gooey's source with every custom shader as one library. The assembled source
/// lives in a reservation released before init returns. A failed compile logs Metal's
/// message, whose `#line` file names point at the shader and its own lines.
fn compileLibrary(device: objc.Object, options: *const Options) !objc.Object {
    assert(shaders.source.len > 0);
    const bytes_max: u32 = @intCast(custom_library.sourceBytesMax(options));
    const buffer = try reservation.reserve(u8, bytes_max);
    const source = custom_library.write(buffer, options);
    defer reservation.release(u8, buffer, source.len);

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const text = NSString.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithBytes:length:encoding:",
        .{ @as(*const anyopaque, source.ptr), @as(c_ulong, source.len), ns_utf8_encoding },
    );
    defer text.release();
    var compile_error: ?*anyopaque = null;
    const library_ptr = device.msgSend(?*anyopaque, "newLibraryWithSource:options:error:", .{
        text.value,
        @as(?*anyopaque, null),
        &compile_error,
    }) orelse {
        logCompileError(compile_error, options.shaders.len);
        return error.ShaderCompilationFailed;
    };
    return objc.Object.fromId(library_ptr);
}

const ns_utf8_encoding: c_ulong = 4;

fn logCompileError(compile_error: ?*anyopaque, shader_count: usize) void {
    assert(shader_count <= custom_count_max);
    const failure = objc.Object.fromId(compile_error orelse {
        std.log.err("Metal shader library failed to compile with no NSError.", .{});
        return;
    });
    const description = failure.msgSend(objc.Object, "localizedDescription", .{});
    const text = description.msgSend([*:0]const u8, "UTF8String", .{});
    std.log.err("Metal shader library ({d} custom shaders) failed to compile. Errors in " ++
        "<name>.metal are in that shader's own MSL; <name>.gooey_wrapper.metal is the " ++
        "fill wrapper calling its shade(): {s}", .{ shader_count, text });
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

test "Pipelines.init compiles Gooey's library with the built-in custom shaders" {
    // Only a device compile catches MSL errors in a built-in shader; without this, a
    // broken shader would first fail at app init. Hosts without Metal skip.
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse return error.SkipZigTest;
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    var pipelines = try Pipelines.init(device, &.{
        .shaders = &.{&shader_mod.LinearGradient.spec},
        .params_stride = limits.MAX_SHADER_PARAMS_BYTES,
    });
    defer pipelines.deinit();
    try std.testing.expectEqual(@as(u32, 1), pipelines.custom_count);
    try std.testing.expect(pipelines.state(.custom, 0).value != null);
}
