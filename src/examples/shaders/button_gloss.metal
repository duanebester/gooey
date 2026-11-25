struct Params {
    float hover;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

float4 shade(ShadeInput in, constant Params& p) {
    float h = saturate(p.hover);
    float2 uv = in.uv;
    float3 ink = mix(float3(0.105, 0.27, 0.35), float3(0.045, 0.13, 0.22), uv.y);
    float diagonal = uv.x + 0.24 * uv.y;
    float band = 1.0 - smoothstep(0.02, 0.19, abs(diagonal - mix(-0.16, 0.97, h)));
    float glow = 1.0 - smoothstep(0.0, 0.46, length((uv - float2(0.65, 0.87))));
    float rim = 1.0 - smoothstep(0.0, 0.20, uv.y);
    ink += float3(0.12, 0.26, 0.31) * (band * h + rim * (0.20 + 0.30 * h));
    ink += float3(0.02, 0.20, 0.26) * glow * h;
    return float4(ink, 1.0);
}
