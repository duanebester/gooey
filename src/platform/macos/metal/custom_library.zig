const std = @import("std");
const assert = std.debug.assert;
const shaders = @import("shaders.zig");
const shader_mod = @import("../../../core/shader.zig");
const limits_mod = @import("../../../core/limits.zig");

pub const Options = struct {
    shaders: []const *const shader_mod.Spec,
    params_stride: u32,
};

const stride_format = "constant uint custom_params_stride = {d};\n";

const wrapper_format =
    \\
    \\}}
    \\#line 1 "{s}.gooey_wrapper.metal"
    \\static_assert(sizeof(user_{s}::Params) == {d},
    \\    "{s}: the MSL Params size differs from the Zig Params size");
    \\fragment float4 custom_fragment_{s}(
    \\    CustomOut in [[stage_in]],
    \\    constant float4 &clip [[buffer(0)]],
    \\    constant uchar *params [[buffer(1)]],
    \\    constant ShadeFrame &shade_frame [[buffer(2)]]
    \\) {{
    \\    float2 pixel = float2(length(float2(dfdx(in.local.x), dfdy(in.local.x))),
    \\                          length(float2(dfdx(in.local.y), dfdy(in.local.y))));
    \\    if (outside_clip(in.screen_pos, clip)) discard_fragment();
    \\    float alpha = custom_coverage(in, pixel) * in.opacity;
    \\    if (alpha <= 0.0) discard_fragment();
    \\    constant user_{s}::Params &p = *reinterpret_cast<constant user_{s}::Params *>(
    \\        params + in.params_index * custom_params_stride);
    \\    float4 color = user_{s}::shade(custom_shade_input(in, shade_frame), p);
    \\    return float4(color.rgb, color.a * alpha);
    \\}}
    \\
    \\
;

const head_format = "namespace user_{s} {{\n#line 1 \"{s}.metal\"\n";

const name_uses_max: u32 = 9;
const digits_max: u32 = 20;

pub fn sourceBytesMax(options: *const Options) u64 {
    assert(options.shaders.len <= limits_mod.MAX_SHADERS);
    var bytes: u64 = shaders.source.len + shaders.custom_prelude.len + stride_format.len +
        digits_max;
    for (options.shaders) |spec| {
        const msl = spec.source.msl orelse unreachable;
        bytes += msl.len + head_format.len + wrapper_format.len +
            name_uses_max * shader_mod.name_bytes_max + 2 * digits_max;
    }
    assert(bytes > shaders.source.len);
    return bytes;
}

pub fn write(buffer: []u8, options: *const Options) []const u8 {
    assert(buffer.len >= sourceBytesMax(options));
    assert(options.params_stride % limits_mod.shader_params_alignment == 0);
    var writer = std.Io.Writer.fixed(buffer);
    writeAll(&writer, options) catch unreachable;
    const written = writer.buffered();
    assert(written.len > shaders.source.len);
    assert(written.len <= buffer.len);
    return written;
}

fn writeAll(writer: *std.Io.Writer, options: *const Options) std.Io.Writer.Error!void {
    try writer.writeAll(shaders.source);
    try writer.writeAll(shaders.custom_prelude);
    try writer.print(stride_format, .{options.params_stride});
    for (options.shaders) |spec| {
        assert(spec.name.len <= shader_mod.name_bytes_max);
        assert(spec.params_size <= options.params_stride);
        const name = spec.name;
        try writer.print(head_format, .{ name, name });
        try writer.writeAll(spec.source.msl orelse unreachable);
        try writer.print(wrapper_format, .{
            name, name, spec.params_size, name, name, name, name, name,
        });
    }
}

pub fn fragmentName(buffer: []u8, spec: *const shader_mod.Spec) [:0]const u8 {
    assert(buffer.len > "custom_fragment_".len + spec.name.len);
    const name = std.fmt.bufPrintSentinel(buffer, "custom_fragment_{s}", .{spec.name}, 0) catch
        unreachable;
    assert(name.len > spec.name.len);
    return name;
}

test "the assembled library gives each shader its own #line segments and fits the bound" {
    const options = Options{
        .shaders = &.{&shader_mod.LinearGradient.spec},
        .params_stride = 64,
    };
    const buffer = try std.testing.allocator.alloc(u8, @intCast(sourceBytesMax(&options)));
    defer std.testing.allocator.free(buffer);
    const source = write(buffer, &options);
    try std.testing.expect(std.mem.startsWith(u8, source, shaders.source));
    const user = std.mem.indexOf(u8, source, "#line 1 \"linear_gradient.metal\"\n").?;
    const wrapper_line = "#line 1 \"linear_gradient.gooey_wrapper.metal\"";
    const wrapper = std.mem.indexOf(u8, source, wrapper_line).?;
    try std.testing.expect(user < wrapper);
    try std.testing.expect(std.mem.indexOf(u8, source[user..wrapper], "float4 shade(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "== 48,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "custom_params_stride = 64;") != null);
}
