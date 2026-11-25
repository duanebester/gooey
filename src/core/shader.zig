//! Custom fill shaders: a fragment-only `shade` function per backend, drawn as a
//! packed-frame pipeline. Gooey supplies the vertex stage and applies the element's
//! rounded-rect coverage, clip, and opacity after the user's function, so a custom fill
//! behaves like `.background` everywhere except the color it computes.
//!
//! Declaration is comptime: `Shader` checks `Params` and the source table, `App` checks
//! the count and params size against `ResourceLimits.paint`, and each host's `main`
//! requires a source for its backend (`requireSources`). Pipelines compile at init.
const std = @import("std");
const limits_mod = @import("limits.zig");
const geometry = @import("../geometry/geometry.zig");

const assert = std.debug.assert;

pub const name_bytes_max: u32 = 48;

/// Per-backend shader sources. A backend that learns custom fills adds its field here;
/// an app that targets it and declares a shader without that field fails to compile.
pub const Source = struct {
    /// Metal Shading Language defining `struct Params` and
    /// `float4 shade(ShadeInput in, constant Params& p)`, returning straight-alpha color.
    msl: ?[]const u8 = null,
};

/// The backends a host can draw with, and the `Source` field each reads.
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

/// What the renderer needs about one declared shader. Apps refer to shaders by the
/// address of their `spec`, which is unique per `Shader` type.
pub const Spec = struct {
    name: []const u8,
    params_size: u32,
    animated: bool,
    source: Source,
};

/// A custom fill: the shader and its params bytes, ready for `Style.fill`.
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

/// Declare a custom fill shader. `Params` must be an `extern struct` whose size is a
/// nonzero multiple of 16 bytes and at most MAX_SHADER_PARAMS_BYTES, matching the MSL
/// `struct Params` member for member.
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

/// MSL namespaces and file names are built from the name: lowercase ASCII letters,
/// digits, and underscores, starting with a letter.
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

/// The app's shader list as specs, in declaration order: a shader's index is its
/// ShaderId in packed draws.
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

/// Comptime budget checks for `App.shaders`.
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

/// Fail compilation when a declared shader has no source for the host's backend.
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

/// Seconds since the window's clock started, wrapped at `time_period_s` so `f32` keeps
/// sub-millisecond precision. Shaders that need continuity across the wrap take their
/// own phase through Params.
pub const time_period_s: u32 = 3_600;

pub fn timeSeconds(now_ns: u64) f32 {
    const period_ns = @as(u64, time_period_s) * std.time.ns_per_s;
    const wrapped_ns = now_ns % period_ns;
    assert(wrapped_ns < period_ns);
    const exact: f32 = @floatCast(@as(f64, @floatFromInt(wrapped_ns)) / std.time.ns_per_s);
    // Rounding to f32 can carry the last nanoseconds of a period up to the period itself.
    const period: f32 = @floatFromInt(time_period_s);
    const seconds = @min(exact, std.math.nextAfter(f32, period, 0));
    assert(seconds >= 0);
    assert(seconds < period);
    return seconds;
}

/// The first built-in shader: a two-stop linear gradient along an angle, like CSS
/// `linear-gradient`. Stops are straight-alpha colors; both interpolation spaces mix them
/// premultiplied by alpha, as CSS Color 4 does, so fading to a transparent stop keeps the
/// other stop's color instead of darkening toward transparent black. Opaque stops mix
/// exactly as a straight mix does.
pub const LinearGradient = Shader(.{
    .name = "linear_gradient",
    .Params = LinearGradientParams,
    .source = .{ .msl = @embedFile("shaders/linear_gradient.metal") },
});

pub const LinearGradientParams = extern struct {
    start: [4]f32,
    end: [4]f32,
    /// Unit direction in element space: (1, 0) runs left to right, (0, 1) top to bottom.
    direction: [2]f32,
    /// `@intFromEnum` of a `GradientInterpolation`; MSL reads it as `uint`.
    interpolation: u32,
    _pad: u32 = 0,
};

/// How a gradient mixes its stops. `.srgb` mixes the sRGB-encoded stops, as CSS does for
/// legacy colors, and is the default. `.oklab` mixes in Ottosson's OKLab, so
/// complementary stops keep their lightness instead of dipping to a dull grey; colors
/// outside the sRGB gamut are clipped per channel in linear light. On an M2 Max a
/// fragment-bound OKLab gradient costs about 2.1x an sRGB one.
pub const GradientInterpolation = enum(u32) {
    srgb = 0,
    oklab = 1,
};

pub const Gradient = struct {
    start: geometry.Color,
    end: geometry.Color,
    /// Clockwise from "to right": 0 runs left to right, 90 top to bottom.
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

// The MSL `struct Params` in linear_gradient.metal declares these members at these offsets.
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
    // The default must be byte-identical to the layout before the field existed: offsets
    // 40-47 were zero padding, so srgb fills and goldens keep their bytes.
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
