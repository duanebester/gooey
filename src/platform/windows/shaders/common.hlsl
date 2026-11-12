// Declarations every DirectX 11 shader shares: the packed frame's instance
// layouts (src/core/packed_frame.zig), the viewport, and the unit quad.
//
// Instance data is read from structured buffers by an absolute index. A
// non-indexed draw's SV_VertexID and SV_InstanceID both start at 0 whatever
// its start location, so the renderer binds an immutable buffer holding
// 0, 1, 2, ... as per-instance vertex data: the input assembler does apply
// StartInstanceLocation to it, and INSTANCE_INDEX arrives as the absolute
// index of the draw's quad, sprite, or mesh.
//
// Direct3D's NDC is Y-up and scene pixels are Y-down, so pixel_to_clip
// negates Y. Vulkan's NDC is Y-down and needs no flip.

#ifndef GOOEY_COMMON_HLSL
#define GOOEY_COMMON_HLSL

// 96 B; a shadow when blur > 0.
struct Quad {
    float4 bounds; // x, y, width, height
    float4 fill;
    float4 border_color;
    float4 corners; // top left, top right, bottom right, bottom left
    float4 border_widths; // top, right, bottom, left
    float2 offset; // A shadow's offset from bounds, at byte 80.
    float blur; // At byte 88.
    float pad;
};

// 96 B.
struct Sprite {
    float4 bounds;
    float4 uv; // left, top, right, bottom
    float4 tint;
    float4 secondary;
    float4 corners;
    float grayscale;
    float opacity;
    float2 pad;
};

// 32 B.
struct Mesh {
    float4 fill;
    uint first;
    uint count;
    float width;
    uint edge_first;
};

cbuffer Viewport : register(b0) {
    // Logical pixels the framebuffer spans: size_px / scale_factor.
    float2 viewport_size;
    float2 viewport_pad;
};

float2 unit_vertex(uint vid) {
    switch (vid) {
        case 0: return float2(0.0, 0.0);
        case 1: return float2(1.0, 0.0);
        case 2: return float2(0.0, 1.0);
        case 3: return float2(1.0, 0.0);
        case 4: return float2(1.0, 1.0);
        case 5: return float2(0.0, 1.0);
        default: return float2(0.0, 0.0);
    }
}

float4 pixel_to_clip(float2 pos) {
    float2 ndc = pos / viewport_size * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

#endif
