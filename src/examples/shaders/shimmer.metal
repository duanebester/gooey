// Skeleton-loader shimmer: a soft highlight band sweeps left to right across the
// element once every 1 / speed seconds.
struct Params {
    float4 base;
    float4 highlight;
    float speed;
    float band_width;
    float2 _pad;
};

float4 shade(ShadeInput in, constant Params& p) {
    float center = fract(in.time * p.speed) * (1.0 + 2.0 * p.band_width) - p.band_width;
    float distance = abs(in.uv.x - center) / max(p.band_width, 1e-4);
    float glow = 1.0 - smoothstep(0.0, 1.0, distance);
    return mix(p.base, p.highlight, glow);
}
