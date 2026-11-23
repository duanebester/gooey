
#ifndef GOOEY_COMMON_HLSL
#define GOOEY_COMMON_HLSL

struct Quad {
    float4 bounds;
    float4 fill;
    float4 border_color;
    float4 corners;
    float4 border_widths;
    float2 offset;
    float blur;
    float pad;
};

struct Sprite {
    float4 bounds;
    float4 uv;
    float4 tint;
    float4 secondary;
    float4 corners;
    float grayscale;
    float opacity;
    float2 pad;
};

struct Mesh {
    float4 fill;
    uint first;
    uint count;
    float width;
    uint edge_first;
};

cbuffer Viewport : register(b0) {
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
