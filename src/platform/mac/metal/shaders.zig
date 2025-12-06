//! Metal Shader definitions and vertex data

const Vertex = @import("renderer.zig").Vertex;

/// Metal Shading Language source for basic triangle rendering
pub const triangle_shader =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VertexIn {
    \\    float2 position [[attribute(0)]];
    \\    float4 color [[attribute(1)]];
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float4 color;
    \\};
    \\
    \\vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    \\    VertexOut out;
    \\    out.position = float4(in.position, 0.0, 1.0);
    \\    out.color = in.color;
    \\    return out;
    \\}
    \\
    \\fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    \\    return in.color;
    \\}
;

/// Triangle vertices with RGB colors at each corner
pub const triangle_vertices = [_]Vertex{
    // Top vertex - Red
    .{ .position = .{ 0.0, 0.5 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } },
    // Bottom left - Green
    .{ .position = .{ -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } },
    // Bottom right - Blue
    .{ .position = .{ 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } },
};
