const std = @import("std");
const limits_mod = @import("limits.zig");
const geometry = @import("../geometry/geometry.zig");

const assert = std.debug.assert;

pub const name_bytes_max: u32 = 48;

pub const Source = struct {
    msl: ?[]const u8 = null,
};

pub const Backend = enum {
    metal,
    vulkan,
    d3d11,
    cpu,
    eve,
    webgpu,

    pub fn sourceField(comptime self: Backend) ?[]const u8 {
        return switch (self) {
            .metal => "msl",
            .vulkan, .d3d11, .cpu, .eve, .webgpu => null,
        };
    }
};

pub const Spec = struct {
    name: []const u8,
    params_size: u32,
    animated: bool,
    source: Source,
};

pub const Fill = struct {
    spec: *const Spec,
    params: [limits_mod.MAX_SHADER_PARAMS_BYTES]u8 align(limits_mod.shader_params_alignment),

    pub fn paramsBytes(self: *const Fill) []const u8 {
        assert(self.spec.params_size > 0);
        assert(self.spec.params_size <= self.params.len);
        return self.params[0..self.spec.params_size];
    }
};

pub const Options = struct {
    name: []const u8,
    Params: type,
    animated: bool = false,
    source: Source,
};

pub fn Shader(comptime options: Options) type {
    comptime checkOptions(options);
    return struct {
        pub const Params = options.Params;
        pub const spec: Spec = .{
            .name = options.name,
            .params_size = @sizeOf(options.Params),
            .animated = options.animated,
            .source = options.source,
        };

        pub fn fill(params: Params) Fill {
            var result: Fill = .{ .spec = &spec, .params = @splat(0) };
            const bytes = std.mem.asBytes(&params);
            comptime assert(bytes.len <= result.params.len);
            @memcpy(result.params[0..bytes.len], bytes);
            assert(result.paramsBytes().len == @sizeOf(Params));
            return result;
        }
    };
}

fn checkOptions(comptime options: Options) void {
    const prefix = "gooey.Shader \"" ++ options.name ++ "\": ";
    checkName(options.name);
    const info = @typeInfo(options.Params);
    if (info != .@"struct" or info.@"struct".layout != .@"extern") {
        @compileError(prefix ++ "Params must be an extern struct");
    }
    const size = @sizeOf(options.Params);
    if (size == 0 or size % limits_mod.shader_params_alignment != 0) {
        @compileError(std.fmt.comptimePrint(prefix ++ "Params is {d} bytes; it must be a " ++
            "nonzero multiple of {d} (pad it explicitly)", .{
            size,
            limits_mod.shader_params_alignment,
        }));
    }
    if (size > limits_mod.MAX_SHADER_PARAMS_BYTES) {
        @compileError(std.fmt.comptimePrint(prefix ++ "Params is {d} bytes, above the " ++
            "framework ceiling MAX_SHADER_PARAMS_BYTES {d}", .{
            size,
            limits_mod.MAX_SHADER_PARAMS_BYTES,
        }));
    }
    if (@alignOf(options.Params) > limits_mod.shader_params_alignment) {
        @compileError(prefix ++ "Params needs alignment above 16");
    }
    const source_fields = @typeInfo(Source).@"struct".field_names;
    var present: u32 = 0;
    for (source_fields) |field| {
        if (@field(options.source, field) != null) present += 1;
    }
    if (present == 0) @compileError(prefix ++ "source has no backend sources");
}

fn checkName(comptime name: []const u8) void {
    if (name.len == 0 or name.len > name_bytes_max) {
        @compileError(std.fmt.comptimePrint("gooey.Shader: name \"{s}\" must be 1 to {d} " ++
            "bytes", .{ name, name_bytes_max }));
    }
    if (!std.ascii.isLower(name[0])) {
        @compileError("gooey.Shader: name \"" ++ name ++ "\" must start with a-z");
    }
    for (name) |byte| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_';
        if (!valid) {
            @compileError("gooey.Shader: name \"" ++ name ++ "\" may hold only a-z, 0-9 " ++
                "and _");
        }
    }
}

pub fn specList(comptime types: []const type) []const *const Spec {
    comptime {
        var specs: [types.len]*const Spec = undefined;
        for (types, 0..) |T, index| {
            if (!@hasDecl(T, "spec") or @TypeOf(T.spec) != Spec) {
                @compileError("gooey.App: shaders[" ++ std.fmt.comptimePrint("{d}", .{index}) ++
                    "] is not a gooey.Shader type");
            }
            specs[index] = &T.spec;
        }
        const result = specs;
        return &result;
    }
}

pub fn checkList(comptime types: []const type, comptime paint: *const limits_mod.PaintLimits) void {
    comptime {
        if (types.len > paint.shader_count_max) {
            @compileError(std.fmt.comptimePrint("gooey.App: {d} shaders declared, above " ++
                "ResourceLimits.paint.shader_count_max {d}", .{
                types.len,
                paint.shader_count_max,
            }));
        }
        const specs = specList(types);
        for (specs, 0..) |spec, index| {
            if (spec.params_size > paint.shader_params_bytes_max) {
                @compileError(std.fmt.comptimePrint("gooey.App: shader \"{s}\"'s Params is " ++
                    "{d} bytes, above ResourceLimits.paint.shader_params_bytes_max {d}", .{
                    spec.name,
                    spec.params_size,
                    paint.shader_params_bytes_max,
                }));
            }
            for (specs[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.name, spec.name)) {
                    @compileError("gooey.App: shader name \"" ++ spec.name ++ "\" is " ++
                        "declared twice");
                }
            }
        }
    }
}

pub fn requireSources(comptime types: []const type, comptime backend: Backend) void {
    comptime {
        for (specList(types)) |spec| {
            const present = if (backend.sourceField()) |field|
                @field(spec.source, field) != null
            else
                false;
            if (!present) {
                @compileError("gooey.App: shader \"" ++ spec.name ++ "\" has no source for " ++
                    "the " ++ @tagName(backend) ++ " backend" ++ if (backend.sourceField()) |f|
                    " (set .source." ++ f ++ ")"
                else
                    ", which does not draw custom shaders yet");
            }
        }
    }
}

pub const time_period_s: u32 = 3_600;

pub fn timeSeconds(now_ns: u64) f32 {
    const period_ns = @as(u64, time_period_s) * std.time.ns_per_s;
    const wrapped_ns = now_ns % period_ns;
    assert(wrapped_ns < period_ns);
    const exact: f32 = @floatCast(@as(f64, @floatFromInt(wrapped_ns)) / std.time.ns_per_s);
    const period: f32 = @floatFromInt(time_period_s);
    const seconds = @min(exact, std.math.nextAfter(f32, period, 0));
    assert(seconds >= 0);
    assert(seconds < period);
    return seconds;
}

pub const LinearGradient = Shader(.{
    .name = "linear_gradient",
    .Params = LinearGradientParams,
    .source = .{ .msl = @embedFile("shaders/linear_gradient.metal") },
});

pub const LinearGradientParams = extern struct {
    start: [4]f32,
    end: [4]f32,
    direction: [2]f32,
    interpolation: u32,
    _pad: u32 = 0,
};

pub const GradientInterpolation = enum(u32) {
    srgb = 0,
    oklab = 1,
};

pub const Gradient = struct {
    start: geometry.Color,
    end: geometry.Color,
    angle_degrees: f32 = 0,
    interpolation: GradientInterpolation = .srgb,
};

pub fn linearGradient(gradient: Gradient) Fill {
    assert(std.math.isFinite(gradient.angle_degrees));
    assert(gradient.start.a >= 0 and gradient.end.a >= 0);
    const radians = std.math.degreesToRadians(gradient.angle_degrees);
    const s = gradient.start;
    const e = gradient.end;
    return LinearGradient.fill(.{
        .start = .{ s.r, s.g, s.b, s.a },
        .end = .{ e.r, e.g, e.b, e.a },
        .direction = .{ @cos(radians), @sin(radians) },
        .interpolation = @backingInt(gradient.interpolation),
    });
}

comptime {
    assert(@sizeOf(LinearGradientParams) == 48);
    assert(@offsetOf(LinearGradientParams, "end") == 16);
    assert(@offsetOf(LinearGradientParams, "direction") == 32);
    assert(@offsetOf(LinearGradientParams, "interpolation") == 40);
    assert(@offsetOf(LinearGradientParams, "_pad") == 44);
    assert(@backingInt(GradientInterpolation.srgb) == 0);
    assert(@sizeOf(Fill) == limits_mod.MAX_SHADER_PARAMS_BYTES + 16);
}

test "Shader.fill copies Params into the first params_size bytes and zeroes the rest" {
    const fill = linearGradient(.{
        .start = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
        .end = .{ .r = 0, .g = 0, .b = 1, .a = 0.5 },
        .angle_degrees = 90,
    });
    try std.testing.expectEqual(&LinearGradient.spec, fill.spec);
    try std.testing.expectEqual(@as(usize, 48), fill.paramsBytes().len);
    const params = std.mem.bytesAsValue(LinearGradientParams, fill.params[0..48]);
    try std.testing.expectEqual(@as(f32, 0.5), params.end[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 1), params.direction[1], 1e-6);
    for (fill.params[48..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "linearGradient stores interpolation at offset 40, defaults to srgb, zeroes its pad" {
    const stops: Gradient = .{
        .start = .{ .r = 1, .g = 1, .b = 0, .a = 1 },
        .end = .{ .r = 0, .g = 0, .b = 1, .a = 1 },
    };
    var oklab = stops;
    oklab.interpolation = .oklab;
    const fills = [2]Fill{ linearGradient(stops), linearGradient(oklab) };
    for (fills[0].params[40..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const interpolation = std.mem.readInt(u32, fills[1].params[40..44], .little);
    try std.testing.expectEqual(@as(u32, 1), interpolation);
    for (fills[1].params[44..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualSlices(u8, fills[0].params[0..40], fills[1].params[0..40]);
}

test "timeSeconds wraps at the period boundary" {
    const period_ns = @as(u64, time_period_s) * std.time.ns_per_s;
    try std.testing.expectEqual(@as(f32, 0), timeSeconds(0));
    try std.testing.expectEqual(@as(f32, 0), timeSeconds(period_ns));
    try std.testing.expectEqual(@as(f32, 1.5), timeSeconds(period_ns + 1_500_000_000));
    try std.testing.expect(timeSeconds(period_ns - 1) > 3_599.9);
    try std.testing.expect(timeSeconds(period_ns - 1) < 3_600);
}
